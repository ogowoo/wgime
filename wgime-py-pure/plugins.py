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
        text = open(path, encoding='utf-8').read()
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
    """返回 (plugins, disabled_codes)"""
    plugins = []
    disabled = set()
    try:
        with open(os.path.join(data_dir, 'plugins-disabled.txt'), encoding='utf-8') as f:
            disabled = set(l.strip() for l in f if l.strip())
    except OSError:
        pass
    for path in sorted(glob.glob(os.path.join(plugin_dir, '*.txt'))):
        p = parse_plugin(path)
        if p.error:
            continue
        p.enabled = os.path.basename(p.path) not in disabled
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
def load_tools(path):
    """[tab 名] / [cols N] / [按钮名] / code = xx / 步骤行"""
    tabs = [{'name': '工具', 'cols': 2, 'buttons': []}]
    btn = None
    try:
        with open(path, encoding='utf-8') as f:
            for raw in f:
                t = raw.rstrip('\n')
                s = t.strip()
                if not s or s[0] in ';#':
                    continue
                if s.startswith('[tab ') and s.endswith(']'):
                    tabs.append({'name': s[5:-1].strip(), 'cols': 2, 'buttons': []})
                    btn = None
                    continue
                if s.startswith('[cols ') and s.endswith(']'):
                    try:
                        tabs[-1]['cols'] = max(1, min(6, int(s[6:-1].strip())))
                    except ValueError:
                        pass
                    continue
                if s.startswith('[') and s.endswith(']') and not re.match(r'^\[(shell|cmd|powershell|ps|shellx|psx|/shell|/powershell|/shellx|/psx)\]$', s, re.I):
                    btn = {'name': s[1:-1].strip(), 'code': None, 'steps': []}
                    tabs[-1]['buttons'].append(btn)
                    continue
                m = re.match(r'^code\s*=\s*(\S+)$', s, re.I)
                if m and btn is not None and not btn['steps']:
                    btn['code'] = m.group(1).lower()
                    continue
                if btn is not None:
                    btn['steps'].append(t)
    except OSError:
        pass
    return [t for t in tabs if t['buttons']]


# ---------- 步骤 DSL 执行器 ----------
def tokenize(s):
    """双引号 + %env% 展开"""
    s = os.path.expandvars(s)
    out = []
    cur = ''
    q = False
    for ch in s:
        if ch == '"':
            q = not q
        elif ch == ' ' and not q:
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


def run_steps(body, log, msgbox, confirm):
    """body: 步骤 DSL 文本. log(msg), msgbox(title,text), confirm(text)->bool"""
    lines = body.split('\n')
    i = 0
    fails = 0
    while i < len(lines):
        t = lines[i].strip()
        i += 1
        if not t or t[0] in ';#':
            continue
        # 多行脚本块
        bm = re.match(r'^\[(shell|cmd|powershell|ps|shellx|psx)\]\s*$', t, re.I)
        if bm:
            tag = bm.group(1).lower()
            block = []
            end_tag = {'shell': '[/shell]', 'cmd': '[/shell]', 'powershell': '[/powershell]', 'ps': '[/powershell]',
                       'shellx': '[/shellx]', 'psx': '[/psx]'}[tag]
            while i < len(lines) and lines[i].strip() != end_tag:
                block.append(lines[i])
                i += 1
            i += 1  # skip end tag
            try:
                _run_block(tag, '\n'.join(block), log)
            except Exception as e:
                fails += 1
                log('块执行失败: %s' % e)
            continue
        sp = t.find(' ')
        verb = (t[:sp] if sp > 0 else t).lower()
        arg = t[sp + 1:].strip() if sp > 0 else ''
        # ② 破坏性动词: 执行前确认 (用户拒绝则跳过该步并计入 fail)
        if verb in DESTRUCTIVE_VERBS and confirm and not confirm('插件要执行[%s] %s\n确定继续?' % (verb, arg[:50])):
            fails += 1
            log('确认被拒: %s' % verb)
            continue
        try:
            fails += _run_verb(verb, arg, log, msgbox, confirm)
        except Exception as e:
            fails += 1
            log('%s 失败: %s' % (verb, e))
    return fails


def _run_verb(verb, arg, log, msgbox, confirm):
    if verb == 'msg':
        msgbox('提示', os.path.expandvars(arg))
    elif verb == 'confirm':
        if not confirm(os.path.expandvars(arg)):
            raise RuntimeError('user-abort')
    elif verb == 'run':
        parts = tokenize(arg)
        if parts:
            r = subprocess.run(parts, capture_output=True, timeout=120)
            log('run %s -> %s' % (parts[0], r.returncode))
    elif verb == 'shell':
        r = subprocess.run('cmd /c ' + os.path.expandvars(arg), shell=True, capture_output=True, timeout=120)
        log('shell -> %s' % r.returncode)
    elif verb == 'shellx':
        subprocess.run('cmd /c ' + os.path.expandvars(arg), shell=True,
                       creationflags=subprocess.CREATE_NEW_CONSOLE, timeout=86400)
    elif verb == 'open':
        os.startfile(os.path.expandvars(arg))
    elif verb == 'kill':
        subprocess.run('taskkill /f /im "%s.exe"' % arg, shell=True, capture_output=True)
    elif verb == 'wait':
        time.sleep(int(arg) / 1000.0)
    elif verb == 'mkdir':
        os.makedirs(os.path.expandvars(arg), exist_ok=True)
    elif verb == 'file-del':
        target = os.path.expandvars(arg)
        if re.match(r'^[A-Za-z]:[\\/]?$', target):
            raise RuntimeError('refuse drive root')
        for p in glob.glob(target):
            try:
                if os.path.isdir(p):
                    shutil.rmtree(p, ignore_errors=True)
                else:
                    os.remove(p)
            except OSError as e:
                log('file-del skip %s: %s' % (p, e))
    elif verb == 'reg-set':
        parts = tokenize(arg)
        if len(parts) >= 4:
            hive, sub = parts[0].split('\\', 1)
            key = winreg.CreateKey(REG_HIVES[hive.upper()], sub)
            name = None if parts[1] == '-' else parts[1]
            typ = parts[2].lower()
            data = parts[3]
            if typ == 'dword':
                winreg.SetValueEx(key, name, 0, winreg.REG_DWORD, int(data, 0))
            elif typ == 'qword':
                winreg.SetValueEx(key, name, 0, winreg.REG_QWORD, int(data, 0))
            elif typ == 'expand':
                winreg.SetValueEx(key, name, 0, winreg.REG_EXPAND_SZ, data)
            elif typ == 'multi':
                winreg.SetValueEx(key, name, 0, winreg.REG_MULTI_SZ, data.split('|'))
            else:
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, data)
            winreg.CloseKey(key)
    elif verb == 'reg-del':
        parts = tokenize(arg)
        if parts:
            hive, sub = parts[0].split('\\', 1)
            if len(parts) > 1:
                key = winreg.OpenKey(REG_HIVES[hive.upper()], sub, 0, winreg.KEY_SET_VALUE)
                winreg.DeleteValue(key, None if parts[1] == '-' else parts[1])
                winreg.CloseKey(key)
            else:
                winreg.DeleteKey(REG_HIVES[hive.upper()], sub)
    else:
        log('未知动词: %s' % verb)
        return 1
    return 0


def _run_block(tag, content, log):
    visible = tag in ('shellx', 'psx')
    if tag in ('shell', 'cmd', 'shellx'):
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
            r = subprocess.run('%s "%s"' % (cmdline, path), shell=True, capture_output=True, timeout=300)
            log('block -> %s' % r.returncode)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
