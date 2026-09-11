# -*- coding: utf-8 -*-
"""wgime-py plugins: plugins/*.txt parsing + step DSL executor + csharp dispatch.

文件格式 (与 WgIme 插件规范一致):
  code = xx / name = 名称 / desc = 说明  (头部)
  之后: 步骤 DSL 或 [csharp] ... [/csharp] 块
"""
import glob
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import winreg

import engine as engmod          # 用它的宽松 read_text (engine 不 import plugins, 无循环; dist 里 engine 先于 plugins 装载)


class Plugin(object):
    def __init__(self, path):
        self.path = path
        self.code = None
        self.name = None
        self.desc = ''
        self.version = ''
        self.author = ''
        self.requires = ''
        self.perm = 'low'     # 权限等级: low/network/run/registry/destructive
        self.kind = 'steps'      # 'steps' | 'csharp' | 'python'
        self.body = ''
        self.error = None


def parse_plugin(path):
    p = Plugin(path)
    try:
        text = engmod.read_text(path)          # 宽松解码 (用户可能用 ANSI 记事本另存)
    except OSError as e:
        p.error = str(e)
        return p
    m = re.search(r'(?s)\[csharp\]\s*(.*?)\[/csharp\]', text)
    if m:
        p.kind = 'csharp'
        p.body = m.group(1)
    mp = re.search(r'(?s)\[python\]\s*(.*?)\[/python\]', text)
    if mp:
        p.kind = 'python'                                # [python] 块: 纯 Python 代码 (替代 [csharp])
        p.body = mp.group(1)
    # 头部: code/name/desc (第一个非"键=值"非注释行起为步骤区)
    lines = text.split('\n')
    body_start = None
    for i, line in enumerate(lines):
        t = line.strip()
        if not t or t[0] in ';#':
            continue
        mm = re.match(r'^(code|name|desc|version|author|requires|perm)\s*[=:]\s*(.*)$', t, re.I)
        if mm:
            k = mm.group(1).lower()
            v = mm.group(2).strip()
            if k == 'code' and p.code is None:
                p.code = v.lower()
            elif k == 'name' and p.name is None:
                p.name = v
            elif k == 'desc':
                p.desc = v
            elif k == 'version':
                p.version = v
            elif k == 'author':
                p.author = v
            elif k == 'requires':
                p.requires = v
            elif k == 'perm':
                p.perm = v.lower()
            continue
        body_start = i
        break
    if p.kind == 'steps':
        p.body = '\n'.join(lines[body_start:]) if body_start is not None else ''
    if not p.code or not p.name:
        p.error = 'missing code/name'
    return p


def load_plugins(plugin_dir, data_dir):
    """返回 (plugins, disabled_codes). 禁用名单 = 小写文件名 (对齐 C# DisabledPlugins)."""
    plugins = []
    disabled = set()
    try:
        for l in engmod.read_text(os.path.join(data_dir, 'plugins-disabled.txt')).split('\n'):
            if l.strip():
                disabled.add(l.strip().lower())        # 统一小写, 文件名大小写不敏感
    except OSError:
        pass
    for path in sorted(glob.glob(os.path.join(plugin_dir, '*.txt'))):
        p = parse_plugin(path)
        if p.error:
            continue
        p.enabled = os.path.basename(p.path).lower() not in disabled    # 按文件名判定 (对齐 C#)
        plugins.append(p)
    return plugins, disabled


def save_disabled(data_dir, disabled):
    try:
        with open(os.path.join(data_dir, 'plugins-disabled.txt'), 'w', encoding='utf-8') as f:
            f.write('\n'.join(sorted(disabled)))
    except OSError:
        pass


# ---------- 插件 manifest / 权限 ----------
HIGH_PERM = ('network', 'run', 'registry', 'destructive')
PERM_LABEL = {'network': '联网', 'run': '执行命令', 'registry': '修改注册表', 'destructive': '删除文件/清理'}
DESTRUCTIVE_VERBS = ('file-del', 'reg-set', 'reg-del', 'kill')   # 数据破坏/系统级操作: 执行前强确认


def plugin_meta(p):
    """统一读取插件 manifest, 兼容 .py 模块(属性) 与 .txt Plugin 对象(字段)."""
    if hasattr(p, 'CODE'):                       # .py 模块插件
        code = getattr(p, 'CODE', '')
        return {'code': code, 'name': getattr(p, 'NAME', code) or code,
                'desc': getattr(p, 'DESC', '') or '', 'version': str(getattr(p, 'VERSION', '') or ''),
                'author': str(getattr(p, 'AUTHOR', '') or ''), 'requires': str(getattr(p, 'REQUIRES', '') or ''),
                'perm': str(getattr(p, 'PERM', 'low') or 'low')}
    # .txt Plugin 对象
    return {'code': p.code or '', 'name': p.name or '', 'desc': p.desc or '',
            'version': str(getattr(p, 'version', '') or ''), 'author': str(getattr(p, 'author', '') or ''),
            'requires': str(getattr(p, 'requires', '') or ''), 'perm': str(getattr(p, 'perm', 'low') or 'low')}


def is_high_perm(meta):
    return meta.get('perm', 'low') in HIGH_PERM


# ---------- tools.txt (工具箱) ----------
_TOOL_BLOCK_TAGS = frozenset(
    ('shell', 'cmd', 'powershell', 'ps', 'shellx', 'cmdx', 'powershellx', 'psx',
     '/shell', '/cmd', '/powershell', '/ps', '/shellx', '/cmdx', '/powershellx', '/psx'))


def load_tools(path):
    """[tab 名] / [cols N] / [按钮名] (或 [button 名]) / code = xx / 步骤行

    对齐 C# LoadTools: 标签页**按需创建**(默认标签 "工具"), 空名字的标签页 = "?"; `[cols N]` 夹到 1-6;
    多行块开/闭标签不算按钮; `code` 行(大小写敏感前缀)取**第 3 个 token** 当编码, 可写在步骤之后;
    任何按钮之前的步骤行忽略; 空标签页也保留(C# 会显示成空页)。"""
    tabs = []
    btn = None

    def _cur():
        if not tabs:
            tabs.append({'name': '工具', 'cols': 2, 'buttons': []})
        return tabs[-1]

    try:
        for raw in engmod.read_text(path).split('\n'):
            t = raw.rstrip('\r\n')                     # 与 C# File.ReadAllLines 一致: 行尾 CR/LF 都不带进步骤文本
            s = t.strip()
            if not s or s[0] in ';#':
                continue
            if s.startswith('[') and s.endswith(']'):
                inner = s[1:-1].strip()
                if inner.lower() in _TOOL_BLOCK_TAGS:      # [shell]...[/powershellx] 等块标签不是按钮 (对齐 C#)
                    if btn is not None:
                        btn['steps'].append(t)
                    continue
                low = inner.lower()
                if low.startswith('tab '):                 # [tab 名]: 新标签页 (空名字 -> "?")
                    tabs.append({'name': inner[4:].strip() or '?', 'cols': 2, 'buttons': []})
                    btn = None
                    continue
                if low.startswith('cols '):                # [cols N]: 当前标签页的磁贴列数 (1-6)
                    try:
                        n = int(inner[5:].strip())
                    except ValueError:
                        n = None
                    if n is not None:
                        _cur()['cols'] = max(1, min(6, n))
                    continue
                if inner.startswith('button '):            # C# 也认 [button 名] 前缀
                    inner = inner[7:].strip()
                btn = {'name': inner or '?', 'code': None, 'steps': []}
                _cur()['buttons'].append(btn)
                continue
            # C#: `act != null && t.StartsWith("code")` (大小写敏感) 且 `ToolToks(t)[2]` 非空 -> 第 3 个 token 当编码
            # 例如 `code = xyz` / `codes = xyz` / `code = xyz 多余` 都算; `CODE = xyz`(大写) 不算, 会掉到步骤里
            if s.startswith('code') and btn is not None:
                ctoks = tokenize(s)
                if len(ctoks) >= 3 and ctoks[2]:
                    btn['code'] = ctoks[2].lower()
                continue
            if btn is not None:
                btn['steps'].append(t)
    except OSError:
        pass
    return tabs


# ---------- 步骤 DSL 执行器 ----------
# 多行脚本块的开/闭标签 (8 组别名, 与 C# ParseToolSteps 的 t == "[shell]" … 一一对应)
_BLOCK_OPEN_RE = re.compile(r'^\[(shell|cmd|powershell|ps|shellx|cmdx|powershellx|psx)\]\s*$', re.I)
_BLOCK_END = {'shell': '[/shell]', 'cmd': '[/cmd]', 'powershell': '[/powershell]', 'ps': '[/ps]',
              'shellx': '[/shellx]', 'cmdx': '[/cmdx]', 'powershellx': '[/powershellx]', 'psx': '[/psx]'}


def count_steps(body):
    """步骤数 (对齐 C# `ParseToolSteps` 得到的 `a.Steps.Count`, 插件管理器用来显示"正常 (N 步)"):
    多行块算 1 步(闭标签缺失则**整块丢弃**, 与 run_steps 的语义一致), 普通非注释行各算 1 步。"""
    lines = body.split('\n')
    i = 0
    n = 0
    while i < len(lines):
        t = lines[i].strip()
        i += 1
        if not t or t[0] in ';#':
            continue
        bm = _BLOCK_OPEN_RE.match(t)
        if bm:
            end_tag = _BLOCK_END[bm.group(1).lower()]
            while i < len(lines) and lines[i].strip() != end_tag:
                i += 1
            if i >= len(lines):
                continue                     # 未闭合: 整块丢弃, 不计步
            i += 1                           # 跳过闭标签
            n += 1
            continue
        n += 1
    return n


def tokenize(s):
    """空白切分 + 双引号分组, 不做 %env% 展开 (对齐 C# ToolToks; 展开只在各动词里按 C# 规则做).
    注意: C# 用 char.IsWhiteSpace, 所以 tab 也算分隔符; 未闭合的引号吃到行尾."""
    out = []
    cur = ''
    q = False
    for ch in s:
        if ch == '"':
            q = not q
        elif ch.isspace() and not q:
            if cur:
                out.append(cur)
                cur = ''
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


REG_HIVES = {'HKCU': winreg.HKEY_CURRENT_USER, 'HKLM': winreg.HKEY_LOCAL_MACHINE,
             'HKCR': winreg.HKEY_CLASSES_ROOT, 'HKU': winreg.HKEY_USERS, 'HKCC': winreg.HKEY_CURRENT_CONFIG}


class StepResult(int):
    """步骤执行结果 = 失败数 (int 直接用); .aborted 标记 confirm 被拒导致中止 (对齐 C# ExecToolStep 的 abort)."""

    def __new__(cls, fails, aborted=False):
        o = super().__new__(cls, fails)
        o.aborted = aborted
        return o


def run_steps(body, log, msgbox, confirm, on_step=None):
    """body: 步骤 DSL 文本. log(msg), msgbox(title,text), confirm(text)->bool.
    on_step(shown, fails_delta, step_lines) 每步结束后回调 (工具箱控制台 [ok]/[失败] 行; 对齐 C# RunAction).
    返回 StepResult(失败数, .aborted). 语义对齐 C# ExecToolStep: confirm 拒绝 = abort 中止本按钮全部后续步骤."""
    lines = body.split('\n')
    i = 0
    fails = 0
    aborted = False
    while i < len(lines):
        raw = lines[i].rstrip('\r')
        t = raw.strip()
        i += 1
        if not t or t[0] in ';#':
            continue
        step_lines = []

        def _slog(m, _sl=step_lines, _log=log):
            _sl.append(str(m))
            _log(m)

        def _done(shown, delta):
            if on_step:
                try:
                    on_step(shown, delta, step_lines)
                except Exception:
                    pass

        # 多行脚本块 (别名: shell/cmd, powershell/ps, shellx/cmdx, powershellx/psx; 闭标签与开标签同名)
        bm = _BLOCK_OPEN_RE.match(t)
        if bm:
            tag = bm.group(1).lower()
            # 控制台行标签对齐 C# ShowTools/RunAction: shell|cmd->[shell], shellx|cmdx->[shellx],
            # powershell|ps->[powershell], powershellx|psx->[psx]
            shown = '[%s] 多行脚本块' % ('shell' if tag in ('shell', 'cmd') else
                                        'shellx' if tag in ('shellx', 'cmdx') else
                                        'powershell' if tag in ('powershell', 'ps') else 'psx')
            block = []
            end_tag = _BLOCK_END[tag]
            while i < len(lines) and lines[i].strip() != end_tag:
                block.append(lines[i])
                i += 1
            if i >= len(lines):                      # 未找到闭标签: C# ParseToolSteps/LoadTools 会整块丢弃, 这里同样不执行
                _slog('块未闭合 (缺 %s), 已跳过' % end_tag)
                continue
            i += 1  # skip end tag
            try:
                _run_block(tag, '\n'.join(block), _slog)
                _done(shown, 0)
            except Exception as e:
                fails += 1
                _slog('块执行失败: %s' % e)
                _done(shown, 1)
            continue
        sp = t.find(' ')
        verb = (t[:sp] if sp > 0 else t).lower()
        arg = t[sp + 1:].strip() if sp > 0 else ''
        # 破坏性动词: 执行前确认 (拒绝则跳过该步并计 fail)
        if verb in DESTRUCTIVE_VERBS and confirm and not confirm('插件要执行[%s] %s\n确定继续?' % (verb, arg[:50])):
            fails += 1
            _slog('确认被拒: %s' % verb)
            _done(raw, 1)
            continue
        try:
            r = _run_verb(verb, arg, _slog, msgbox, confirm)
            if r == 'abort':
                aborted = True
                log('已取消')
                break
            fails += r
            _done(raw, r)
        except _UserAbort:
            aborted = True
            log('已取消')
            break
        except Exception as e:
            fails += 1
            _slog('%s 失败: %s' % (verb, e))
            _done(raw, 1)
    return StepResult(fails, aborted)


class _UserAbort(RuntimeError):
    """confirm 拒绝: 中止本按钮后续步骤 (对齐 C# confirm 返回 abort)."""


def _tool_rest(arg):
    return arg.strip()


def _tool_path(rest):
    s = rest.strip()
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return os.path.expandvars(s)


def _confirm_args(arg, confirm, msgbox):
    """confirm 文本 [| title=标题] [| buttons=yesno|okcancel|ok] [| default=1|2]; 拒绝 -> _UserAbort."""
    msg = arg
    title = 'WgIme'
    buttons = 'yesno'
    default_no = True
    pipe = arg.find('|')
    if pipe >= 0:
        msg = arg[:pipe].strip()
        for opt in arg[pipe + 1:].split('|'):
            eq = opt.find('=')
            if eq < 1:
                continue
            k = opt[:eq].strip().lower()
            v = opt[eq + 1:].strip()
            if k == 'title':
                title = v
            elif k == 'buttons':
                buttons = v
            elif k == 'default':
                default_no = v != '1'
    msg = os.path.expandvars(msg)
    if buttons == 'ok':
        msgbox(title, msg)                       # buttons=ok: 纯提示, 永不中止
        return
    # 对齐 C# ExecToolStep: title/buttons/default 三项都生效; 缺省按钮是"否"(MessageBoxDefaultButton.Button2,
    # 防误触), buttons=okcancel 走 OK/Cancel 语义 (OK/Yes = 继续)
    try:
        ok = confirm(msg, title, buttons, default_no)
    except TypeError:                            # 兼容只接受文本的旧回调(第三方/嵌入式调用)
        ok = confirm(msg)
    if not ok:
        raise _UserAbort()


def _run_hidden(cmdline, log):
    """隐藏子进程, 捕获 stdout/stderr 进日志 (对齐 C# RunHidden)."""
    r = subprocess.run(cmdline, shell=isinstance(cmdline, str), capture_output=True, text=True,
                       encoding='mbcs', errors='replace', timeout=120)
    if r.stdout and r.stdout.strip():
        log('  out: ' + r.stdout.strip())
    log('  exit %s' % r.returncode)
    return 0 if r.returncode == 0 else 1


def _run_verb(verb, arg, log, msgbox, confirm):
    if verb == 'msg':
        msgbox('WgIme', arg)                         # C# msg: 气泡标题 WgIme, 原样显示不展开
    elif verb == 'confirm':
        _confirm_args(arg, confirm, msgbox)
    elif verb == 'run':
        parts = tokenize(arg)
        if not parts:
            raise RuntimeError('run 缺少程序名')      # C# tk[1] 越界 -> 记一步失败 (不能静默成功)
        parts[0] = os.path.expandvars(parts[0])  # C# 只展开程序名 (tk[1]), 参数原样
        return _run_hidden(parts, log)
    elif verb == 'shell':
        return _run_hidden('cmd /c ' + arg, log)     # cmd 自己展开 %env%, 对齐 C# (不预先展开)
    elif verb == 'shellx':
        subprocess.run('cmd /c ' + arg, shell=True,  # 同上: 交给 cmd 展开
                       creationflags=subprocess.CREATE_NEW_CONSOLE, timeout=86400)
    elif verb == 'open':
        os.startfile(_tool_path(arg))
    elif verb == 'kill':
        _toks = tokenize(arg)                    # C# 用 tk[1] (仅第一个 token), 不是整行 rest
        img = (_toks[0] if _toks else '').replace('"', '').replace('&', '').replace('|', '').replace('<', '').replace('>', '').replace('^', '')
        if not re.match(r'^[\w. -]+$', img):
            raise RuntimeError('bad image name: %s' % arg)
        # 按名杀全部实例并计数 (对齐 C# Process.GetProcessesByName)
        n = 0
        for proc in _list_procs_by_name(img):
            try:
                proc.kill()
                n += 1
            except Exception:
                pass
        log('  killed %d x %s' % (n, img))
    elif verb == 'wait':
        time.sleep(int(arg) / 1000.0)
    elif verb == 'mkdir':
        os.makedirs(_tool_path(arg), exist_ok=True)
    elif verb == 'file-del':
        return _file_del(arg, log)
    elif verb == 'reg-set':
        _reg_set(arg)
    elif verb == 'reg-del':
        _reg_del(arg)
    else:
        log('未知动词: %s' % verb)
        return 1
    return 0


def _list_procs_by_name(name):
    """按进程名(不含 .exe)列进程对象; 用 psutil 若无则 wmic 回退, 失败返回空."""
    try:
        import psutil
        out = []
        for p in psutil.process_iter(['name']):
            try:
                if p.info['name'] and p.info['name'].lower() == (name.lower() + '.exe'):
                    out.append(p)
            except Exception:
                pass
        return out
    except Exception:
        pass
    # 无 psutil: 用 taskkill (无法逐个计数, 记 1)
    class _P:
        def kill(self):
            subprocess.run(['taskkill', '/f', '/im', name + '.exe'], capture_output=True, timeout=60)
    return [_P()]


def _file_del(arg, log):
    """删文件/目录, 通配符; 拒删盘根/UNC 根; 锁定项跳过并记录; 计数 (对齐 C# file-del)."""
    spec = _tool_path(arg)
    base = re.split(r'[*?\[]', spec)[0].rstrip('\\/ ')
    if re.match(r'^[A-Za-z]:$', base) or re.match(r'^\\\\[^\\]+\\[^\\]+$', base):
        raise RuntimeError('refuse drive/UNC root')
    n = 0
    fail = 0
    skipped = []

    def _del(p, is_dir):
        nonlocal n, fail
        try:
            if is_dir:
                shutil.rmtree(p)
            else:
                os.remove(p)
            n += 1
        except OSError:
            fail += 1
            if len(skipped) < 8:
                skipped.append(p)

    if '*' in spec or '?' in spec:
        for pth in glob.glob(spec):
            _del(pth, os.path.isdir(pth))
    elif os.path.isdir(spec):
        _del(spec, True)
    elif os.path.exists(spec):
        _del(spec, False)
    for sk in skipped:
        log('  skip: ' + sk)
    log('  deleted %d%s' % (n, ', skipped %d (in use / locked)' % fail if fail else ''))
    return 0


def _reg_split(full):
    pth = full.replace('/', '\\')
    i = pth.find('\\')
    hive_name = (pth[:i] if i >= 0 else pth).upper()
    sub = pth[i + 1:] if i >= 0 else ''
    hive = REG_HIVES[hive_name]
    return hive, sub


def _reg_set(arg):
    parts = tokenize(arg)
    if len(parts) < 4:                               # C# tk[1..3] 越界 -> 记一步失败 (不能静默成功)
        raise RuntimeError('reg-set 参数不足, 需要: 键路径 值名 类型 数据')
    hive, sub = _reg_split(os.path.expandvars(parts[0]))
    name = None if parts[1] == '-' else parts[1]
    typ = parts[2].lower()
    data = ' '.join(parts[3:])
    with winreg.CreateKey(hive, sub) as key:
        if typ == 'dword':
            winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, int(data, 0))
        elif typ == 'qword':
            winreg.SetValueEx(key, name, 0, winreg.REG_QWORD, int(data, 0))
        elif typ == 'expand':
            winreg.SetValueEx(key, name, 0, winreg.REG_EXPAND_SZ, data)
        elif typ == 'multi':
            winreg.SetValueEx(key, name, 0, winreg.REG_MULTI_SZ, data.split('|'))
        elif typ == 'binary':                          # 对齐 C# binary(hex)
            hx = data.replace(' ', '').replace('-', '')
            winreg.SetValueEx(key, name, 0, winreg.REG_BINARY, bytes.fromhex(hx))
        else:
            winreg.SetValueEx(key, name, 0, winreg.REG_SZ, data)


def _reg_del(arg):
    parts = tokenize(arg)
    if not parts:                                    # C# tk[1] 越界 -> 记一步失败
        raise RuntimeError('reg-del 参数不足, 需要: 键路径 [值名]')
    hive, sub = _reg_split(os.path.expandvars(parts[0]))
    if len(parts) > 1:
        with winreg.OpenKey(hive, sub, 0, winreg.KEY_SET_VALUE) as key:
            winreg.DeleteValue(key, None if parts[1] == '-' else parts[1])
    else:
        _delete_subkey_tree(hive, sub)


def _delete_subkey_tree(hive, sub):
    """递归删子键树 (对齐 C# DeleteSubKeyTree)."""
    try:
        with winreg.OpenKey(hive, sub, 0, winreg.KEY_READ) as key:
            names = []
            i = 0
            while True:
                try:
                    names.append(winreg.EnumKey(key, i))
                    i += 1
                except OSError:
                    break
            for n in names:
                _delete_subkey_tree(key, n)
    except OSError:
        pass
    winreg.DeleteKey(hive, sub)


def _run_block(tag, content, log):
    """多行脚本块 (对齐 C# RunScriptBlock): shell/cmd->.cmd(ANSI), powershell/ps->.ps1(UTF-8 BOM+OutputEncoding),
    shellx/cmdx->可见 .cmd, powershellx/psx->可见 .ps1."""
    visible = tag in ('shellx', 'cmdx', 'powershellx', 'psx')
    if tag in ('shell', 'cmd', 'shellx', 'cmdx'):
        ext, cmdline = '.cmd', 'cmd /c'
        data = content.encode('mbcs', errors='replace')          # ANSI
    else:
        ext, cmdline = '.ps1', 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
        data = b'\xef\xbb\xbf' + content.encode('utf-8')         # UTF-8 BOM
    fd, path = tempfile.mkstemp(suffix=ext, prefix='wgpy-')
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
    try:
        if visible:
            cmd = 'cmd /c start "wgpy" /wait cmd /k "%s & echo. & echo [按任意键关闭] & pause>nul"' % path if ext == '.cmd' \
                else 'cmd /c start "wgpy" /wait cmd /k "%s %s & echo. & echo [按任意键关闭] & pause>nul"' % (cmdline, path)
            subprocess.run(cmd, shell=True, timeout=86400)
        else:
            r = subprocess.run('%s "%s"' % (cmdline, path), shell=True, capture_output=True, text=True,
                               encoding='mbcs', errors='replace', timeout=300)
            if r.stdout and r.stdout.strip():
                log('  out: ' + r.stdout.strip())
            log('block -> %s' % r.returncode)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
