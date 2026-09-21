# -*- coding: utf-8 -*-
"""deps.py — 可选依赖自检 + 一键安装（第八十二轮）。

宿主**核心零依赖**（单文件自带 pystray/pypdf 等纯 Python 包，见 AGENTS.md §12）。本模块只管**可选件**：
缺了只是对应功能降级（照样能打字），装上就多一项能力。三条硬规矩：

1. **绝不拖累启动/打字**：探测与安装都在后台线程；异常只记日志 + 气泡，核心功能不受影响。
2. **装到 wgime 自己的目录** = `DATA_DIR\\site\\pip`（`pip install --target`）+ 挂 `sys.path`：
   不污染用户 Python、绕开 Store Python 的 `%LOCALAPPDATA%` 虚拟化、与内嵌 zip（`site/thirdparty.zip`）同址、
   "卸载"就是删目录。**不用 `--user`、不写系统 site-packages**。
3. **首次启动只问一次**（缺省「否」），答案落 `DATA_DIR\\deps-state.txt`，之后不再打扰；重跑走启动编码 `deps`。

本模块**不 import 宿主任何模块**（便于懒装载与纯逻辑单测）；`DATA_DIR` 一律由调用方传入。
`probe(finder=...)` 与 `install(runner=...)` 都可注入 —— 回归测试靠它做到**完全不联网**。
"""
import importlib
import importlib.util
import os
import subprocess
import sys
import time

_CREATE_NO_WINDOW = 0x08000000

# 可选件清单（顺序 = 界面顺序）。
#   inst=True  -> 可勾选安装；inst=False -> 只报告（体积大 / 装完还要另外下模型）
SPECS = [
    {'key': 'pypdf', 'mod': 'pypdf', 'pkg': 'pypdf', 'inst': True,
     'label': 'PDF 工具', 'why': 'plugins/pdf.py 的 PDF 读写（分发单文件已内嵌，仅源码目录跑时会缺）'},
    {'key': 'psutil', 'mod': 'psutil', 'pkg': 'psutil', 'inst': True,
     'label': '进程列举', 'why': '插件管理器/清理工具的进程列表（缺则回退 taskkill，功能不变只是慢）'},
    {'key': 'cryptography', 'mod': 'cryptography', 'pkg': 'cryptography', 'inst': True,
     'label': '聊天加密', 'why': 'chat 插件的加密会话（缺则加密不可用，明文仍可用）'},
    {'key': 'argostranslate', 'mod': 'argostranslate', 'pkg': 'argostranslate', 'inst': True,
     'label': '离线翻译', 'why': 'wgtranslate 插件的离线机翻（缺则报错；首次用还需下语言包）'},
    {'key': 'faster_whisper', 'mod': 'faster_whisper', 'pkg': 'faster-whisper', 'inst': False,
     'label': '本地语音 whisper', 'why': 'voice_engine=whisper 的后端；几百 MB 且要另外准备模型，请照 §D8.2 手工装'},
    {'key': 'sherpa_onnx', 'mod': 'sherpa_onnx', 'pkg': 'sherpa-onnx', 'inst': False,
     'label': '本地语音 sherpa', 'why': 'voice_engine=sherpa（首选）的后端；要另外准备模型，请照 §D8.2 手工装'},
]


# ----------------------------------------------------------------------
# 私有安装目录（与内嵌 zip 同址）
# ----------------------------------------------------------------------
def site_dir(data_dir):
    """可选依赖的安装目录：`<DATA_DIR>/site/pip`（内嵌 zip 在 `<DATA_DIR>/site/thirdparty.zip`）。"""
    return os.path.join(data_dir, 'site', 'pip')


def ensure_site_on_path(data_dir):
    """把私有安装目录挂到 `sys.path` 最前面（存在才挂）。返回是否**本次新挂上**。

    挂在最前：用户自己装的版本优先于内嵌 zip / 宿主 site-packages。幂等 —— 已经在里面就不重复加。
    装了新包之后要 `importlib.invalidate_caches()`，否则 `find_spec` 会拿旧目录缓存（表现为"装好了还是缺"）。
    """
    d = site_dir(data_dir)
    if not os.path.isdir(d):
        return False
    if d in sys.path:
        return False
    sys.path.insert(0, d)
    try:
        importlib.invalidate_caches()
    except Exception:
        pass
    return True


# ----------------------------------------------------------------------
# 探测
# ----------------------------------------------------------------------
def _default_finder(mod):
    """默认"装没装"判据：`importlib.util.find_spec`（**不 import**，不触发模块级副作用）。

    在单文件分发里第三方走 zipimport，find_spec 一样找得到；找不到/父包异常一律当"缺"。
    """
    try:
        return importlib.util.find_spec(mod) is not None
    except Exception:
        return False


def probe(data_dir=None, specs=None, finder=None):
    """逐项探测，返回 `[{..., 'present': bool, 'missing': bool}]`（原 SPECS 字段都会带上）。"""
    if data_dir:
        ensure_site_on_path(data_dir)
    finder = finder or _default_finder
    out = []
    for s in (specs if specs is not None else SPECS):
        d = dict(s)
        try:
            present = bool(finder(s['mod']))
        except Exception:
            present = False
        d['present'] = present
        d['missing'] = not present
        out.append(d)
    return out


def missing(items):
    return [i for i in items if i.get('missing')]


def installable(items):
    """可勾选安装的 pip 包名（只含 `inst=True` 且缺失的项）。"""
    return [i['pkg'] for i in items if i.get('missing') and i.get('inst')]


def report_only(items):
    """只报告、不代装的项（语音那类）。"""
    return [i for i in items if i.get('missing') and not i.get('inst')]


def text_report(items):
    """人话清单（确认框/窗口里用）。"""
    lines = []
    for i in missing(items):
        how = '可安装' if i.get('inst') else '只报告（请手工装）'
        lines.append('  · %s —— %s\n      [%s] pip install %s' % (i['label'], i['why'], how, i['pkg']))
    return '\n'.join(lines)


# ----------------------------------------------------------------------
# 安装
# ----------------------------------------------------------------------
def pip_argv(target, pkgs, python=None):
    """pip 命令行数组。**注意是 `--target`**（装进私有目录），不是 `--user`/系统 site-packages。"""
    py = python or sys.executable or 'python'
    return ([py, '-m', 'pip', 'install', '--upgrade', '--target', target,
             '--disable-pip-version-check', '--no-input', '--no-warn-script-location']
            + [p for p in pkgs if p])


def shell_command(target, pkgs, python=None):
    """给用户看的可复制命令（路径带空格要引号）。"""
    q = lambda s: ('"%s"' % s) if (' ' in s or '\t' in s) else s
    return ' '.join(q(a) for a in pip_argv(target, pkgs, python=python))


def _run_stream(cmd, on_line=None, timeout=1800):
    """跑 pip 并把输出逐行喂给 `on_line`（后台线程里调；返回 `(rc, 全文)`）。

    无控制台（pythonw）下必须收管道 + `CREATE_NO_WINDOW`；超时按**每行**检查（pip 一直在输出，
    卡在没输出的状态才会一直等，那种情况由调用方的线程兜着）。
    """
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         stdin=subprocess.DEVNULL, creationflags=_CREATE_NO_WINDOW)
    buf, rc, t0 = [], None, time.time()
    try:
        for raw in iter(p.stdout.readline, b''):
            line = raw.decode('utf-8', 'replace').rstrip('\r\n')
            buf.append(line)
            if on_line:
                try:
                    on_line(line)
                except Exception:
                    pass
            if timeout and time.time() - t0 > timeout:
                p.kill()
                buf.append('[timeout] 超过 %ds 未完成，已中止' % timeout)
                rc = -1
                break
        if rc is None:
            rc = p.wait()
    finally:
        try:
            p.stdout.close()
        except Exception:
            pass
    return rc, '\n'.join(buf)


def _explain_failure(rc, log, python=None):
    """把 pip 的失败翻译成人话（判断顺序：缺 pip -> 网络 -> 其它）。"""
    py = python or sys.executable or 'python'
    low = (log or '').lower()
    if 'no module named pip' in low or 'pip is not' in low:
        return '这个 Python 没有 pip：先跑 `%s -m ensurepip --upgrade`（或换官方 Python 再试）' % py
    if ('could not find a version' in low or 'failed to establish' in low
            or 'connection' in low or 'timed out' in low or 'temporary failure' in low
            or 'ssl' in low or 'proxy' in low):
        return '网络不通或取不到包（核心功能不受影响，稍后再试或换镜像）'
    return 'pip 返回码 %s' % (rc,)


def install(pkgs, data_dir, on_line=None, runner=None, timeout=1800, python=None):
    """把 `pkgs` 装进私有目录。返回 `{ok, code, log, cmd, target, error}`。

    `runner(cmd, on_line, timeout) -> (rc, log)` 可注入（回归测试用假的，**不联网**）。
    **本函数不抛异常** —— 任何失败都从 `ok/error` 出来，调用方只管报给用户。
    """
    pkgs = [p for p in (pkgs or []) if p]
    target = site_dir(data_dir)
    if not pkgs:
        return {'ok': False, 'code': None, 'log': '', 'cmd': '', 'target': target,
                'error': '没有选中要安装的包'}
    try:
        os.makedirs(target, exist_ok=True)
    except OSError as ex:
        return {'ok': False, 'code': None, 'log': '', 'cmd': '', 'target': target,
                'error': '建安装目录失败: %r' % (ex,)}
    cmd = pip_argv(target, pkgs, python=python)
    runner = runner or _run_stream
    try:
        rc, log = runner(cmd, on_line, timeout)
    except Exception as ex:
        return {'ok': False, 'code': None, 'log': '', 'cmd': cmd, 'target': target,
                'error': 'pip 起不来: %r' % (ex,)}
    ok = (rc == 0)
    res = {'ok': ok, 'code': rc, 'log': log, 'cmd': cmd, 'target': target, 'error': ''}
    if ok:
        ensure_site_on_path(data_dir)          # 装了立刻能在本次进程里被发现
    else:
        res['error'] = _explain_failure(rc, log, python=python)
    return res


# ----------------------------------------------------------------------
# 状态文件（"首启只问一次"）
# ----------------------------------------------------------------------
def state_file(data_dir):
    return os.path.join(data_dir, 'deps-state.txt')


def read_state(data_dir):
    """读 `deps-state.txt`（`k=v` 逐行）。**按 '\\n' 切行后先 rstrip('\\r')** —— AGENTS §39。"""
    d = {}
    try:
        with open(state_file(data_dir), 'r', encoding='utf-8', errors='replace') as f:
            for ln in f:
                ln = ln.rstrip('\r\n')
                if not ln or ln.startswith('#') or '=' not in ln:
                    continue
                k, v = ln.split('=', 1)
                d[k.strip()] = v.strip()
    except OSError:
        pass
    return d


def write_state(data_dir, **kv):
    """合并写回（保留既有键）。行尾 LF —— 这是 wgime 自己的状态文件，不是用户手改的文本。"""
    d = read_state(data_dir)
    for k, v in kv.items():
        d[k] = str(v)
    try:
        os.makedirs(data_dir, exist_ok=True)
        with open(state_file(data_dir), 'w', encoding='utf-8', newline='\n') as f:
            for k in sorted(d):
                f.write('%s=%s\n' % (k, d[k]))
        return True
    except OSError:
        return False


def should_ask(data_dir):
    """首启才问：状态里没有 `asked=1` 就返回 True。"""
    return not read_state(data_dir).get('asked')


def mark_asked(data_dir, **kv):
    """记下"问过了"（无论用户选装还是跳过），之后不再打扰。"""
    return write_state(data_dir, asked=1, at=time.strftime('%Y-%m-%d %H:%M:%S'), **kv)


def note_installed(data_dir, pkgs):
    """记下装过的包（便于日志/排查；不参与判定）。"""
    old = [x for x in read_state(data_dir).get('installed', '').split(',') if x]
    for p in pkgs:
        if p not in old:
            old.append(p)
    return write_state(data_dir, installed=','.join(old))
