# -*- coding: utf-8 -*-
"""build-wgime-pure.py — 把 wgime-py-pure 全部模块 + 插件 + 第三方库内联合成一个单文件 wgime-py.py.
原理:
  - 项目模块(win/hook/engine/...) 按依赖序 exec 进 sys.modules (真实 import 仍可用)
  - 插件源注册为 plug_*
  - 第三方库(我们用的包 + 它们的**声明依赖**, 纯 Python) 打包成 zip, 运行时解压到
    %LOCALAPPDATA%\\wgime-py\\site 并 zipimport —— 标准 import 机制, 包结构/相对导入天然正确
  - 最后把 main.py 源 exec 进 __main__
"""
import os
import io
import shutil
import sys
import base64
import zipfile
import importlib
import pkgutil
import importlib.util
import importlib.metadata

# stdout/stderr 一律 utf-8+replace: 被 PS 调用时默认是 cp1252, 脚本里任何中文提示都会
# UnicodeEncodeError 把**构建**打死(而且 build-package.ps1 还会"沿用旧产物"报成功) —— 第六十九轮踩到。
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

BASE = os.path.dirname(os.path.abspath(__file__))
MODULES = ['win', 'hook', 'bar', 'dot', 'wspy', 'engine', 'plugins', 'ui', 'tools', 'tray', 'voice']
# 第六十九轮: 加了 dot (状态提示点) —— 项目模块 10 -> 11 个。
OUT = os.path.join(BASE, 'dist', 'wgime-py.py')
os.makedirs(os.path.dirname(OUT), exist_ok=True)


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


modsrc = {m: read(os.path.join(BASE, m + '.py')) for m in MODULES}
# 插件不再内嵌进单文件: 全部作为外置 plugins\*.py 由 load_py_plugins 在运行时扫描加载.
# 保持 PLUGIN_SRC 为空 dict, 单文件体积更小, 插件改起来不用重打包.
plugsrc = {}
main_src = read(os.path.join(BASE, 'main.py'))


# ---- 第三方库收集: 包 + 它们的**声明依赖** (纯 Python; 排除 test 子包) ----
# 第六十九轮(用户机实测的真 bug): 光收我们 import 的那几个包**不够** —— pystray 的
# `_base.py`/`_win32.py` 里有 `from six.moves import queue`, METADATA 也写着 `Requires-Dist: six`,
# 但原来只嵌 pystray 自己。于是"构建机恰好装了 six"就一直没暴露: 单文件的 import 会**回退到宿主
# site-packages**, 干净机器(官方 Python 3.14, 没有 six)上 `import pystray` 直接 ImportError ->
# **托盘整个消失**(还弹一个"托盘图标没能创建", NIM_ADD=None)。同一类坑第四十二轮已经踩过一次
# (Pillow), 所以这次不只补 six: 依赖从 METADATA 自动收, 并加**构建期干净环境自检**(见下面
# verify_thirdparty_isolation) —— 漏嵌会在构建时就报错, 而不是等用户在干净机器上撞见。
# **不能内嵌的一律在这里登记 + 写清原因** (构建日志会打印出来, 免得以后有人以为"漏了")。
# 判据: C 扩展(.pyd/.so)与解释器 ABI 绑定, zipimport 加载不了 —— 我们构建机是 cp312, 用户机可能是
# cp314(实测那台就是 Program Files\Python314), 二进制嵌进去也白搭。这类依赖必须先"可用则可选、
# 不可用则明确降级", 不能崩。
_THIRD_SKIP = {
    'Pillow': 'C 扩展(_imaging.pyd) —— 托盘图标已在**构建期**渲染成 ICO 内嵌, 运行时不需要它',
    'comtypes': '第四十四轮起全项目 0 处 import(光标跟随 helper 改成纯 ctypes 源码), 不再内嵌',
    'uiautomation': '同上(它只依赖 comtypes; 进程内 UIA 已被 §17 明确禁止)',
    'psutil': 'C 扩展(_psutil_windows.pyd) —— plugins.py 里是可选路径, 缺了就回退 wmic',
    'cryptography': 'C 扩展(_rust.pyd) —— chat 插件加密的可选能力, 缺了给明确提示(见 plugins/chat.py)',
    'faster-whisper': 'C 扩展(ctranslate2) + 模型文件 —— 只有 voice_engine=whisper 才要, 由用户自己装',
    'argostranslate': 'C/纯 Python 混合 + 语言模型 —— wgtranslate 插件的可选离线翻译, 由用户自己装',
}


def _declared_deps(names):
    """从 METADATA 取**无条件**声明依赖 (带 marker 的平台/可选依赖一律不收: 我们只跑 Windows,
    且 extra 依赖属于插件的可选能力, 由用户自己 pip 装)。"""
    deps = []
    for nm in names:
        try:
            md = importlib.metadata.metadata(nm)
        except Exception:
            continue
        for req in (md.get_all('Requires-Dist') or []):
            if ';' in req:                    # `; extra == 'x'` / `; sys_platform == 'darwin'` ...
                continue
            name = req.split('[')[0].split('(')[0].split('>')[0].split('<')[0].split('=')[0].strip()
            if name and name not in deps:
                deps.append(name)
    return deps


def _closure(roots):
    """**传递闭包**: 依赖的依赖也要收 (第六十九轮只收了一层, 幸好 pystray->six 就一层)。"""
    seen, queue = [], list(roots)
    while queue:
        nm = queue.pop(0)
        if nm in seen:
            continue
        seen.append(nm)
        queue.extend(_declared_deps([nm]))
    return seen


def collect_thirdparty(pkgnames):
    want = []
    for nm in _closure(pkgnames):
        if nm in _THIRD_SKIP:
            print('skip third-party %-15s %s' % (nm, _THIRD_SKIP[nm]))
            continue
        if nm not in want:
            want.append(nm)
    print('third-party roots: %s' % ', '.join(pkgnames))
    print('third-party to embed: %s' % ', '.join(want))
    files = {}
    for pkgname in want:
        try:
            pkg = importlib.import_module(pkgname)
        except Exception as e:
            print('WARN: import %s failed, skipping (%r)' % (pkgname, e))
            continue
        origin = getattr(pkg, '__file__', None)
        if not origin:
            continue
        if getattr(pkg, '__path__', None):                     # 包
            files[pkgname + '/__init__.py'] = read(origin)
            for m in pkgutil.walk_packages(pkg.__path__, pkgname + '.'):
                if '.test' in m.name or m.name.endswith('.test'):
                    continue
                try:
                    spec = importlib.util.find_spec(m.name)
                except Exception:
                    continue
                if spec and spec.origin and spec.origin.endswith('.py'):
                    rel = m.name.replace('.', '/') + ('/__init__.py' if m.ispkg else '.py')
                    files[rel] = read(spec.origin)
        else:                                                  # 单模块 (six 就是 six.py)
            files[pkgname + '.py'] = read(origin)
    return files


# roots = 我们真正 import 的第三方; 其余靠**声明依赖的传递闭包**自动带出来(six 就是这么来的)
third_files = collect_thirdparty(['pystray'])
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel, src in sorted(third_files.items()):
        z.writestr(rel, src)
THIRD_ZIP_B64 = base64.b64encode(buf.getvalue()).decode('ascii')


# ---- 构建期自检: 内嵌的第三方必须能在"没有 site-packages"的干净解释器里 import 成功 ----
# 第六十九轮: 本机装了 six, 单文件却漏嵌 pystray 的依赖 -> 干净机器上托盘整个消失。用
# `python -S -E`(不加载 site-packages / 不读 PYTHON* 环境变量) + 只把这个 zip 挂到 sys.path
# 上 import 一遍, 就能在**构建时**复现"干净机器"的处境; 失败直接中止构建(绝不产出坏单文件)。
def verify_thirdparty_isolation(zip_bytes, top_names):
    import subprocess
    import tempfile
    tmp = tempfile.mkdtemp(prefix='wgime-third-')
    zp = os.path.join(tmp, 'thirdparty.zip')
    try:
        with open(zp, 'wb') as f:
            f.write(zip_bytes)
        tops = sorted({n.split('/')[0].replace('.py', '') for n in top_names})
        code = ('import sys; sys.path.insert(0, %r)\n' % zp
                + 'import ' + ', '.join(tops) + '\n'
                + 'print("THIRD-ISOLATION-OK " + ",".join(%r))' % tops)
        r = subprocess.run([sys.executable, '-S', '-E', '-c', code],
                           capture_output=True, encoding='utf-8', errors='replace')
        if r.returncode != 0:
            print('!! 内嵌第三方在干净环境里 import 失败 (缺依赖?):')
            print((r.stderr or r.stdout or '').strip()[-1200:])
            return False
        print('third-party isolation check: %s' % (r.stdout or '').strip())
        return True
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if not verify_thirdparty_isolation(buf.getvalue(), third_files.keys()):
    print('构建中止: 内嵌第三方不自足 (干净机器上会 ImportError)')
    sys.exit(1)

# ---- 托盘图标预渲染成 ICO 内嵌 (第四十二轮) ----
# python 版的托盘以前要在**运行时**用 Pillow 画图标, 而宿主机不一定装了 Pillow (用户机器实测:
# 官方 Python 3.14 没装 Pillow -> `from PIL import ...` ImportError -> 托盘图标整个没有,
# 这就是"个别机器看不到托盘图标"). 现在构建时用 PIL 画好每个模式的图标 (N 模式 × 开/关 + 工具模式),
# 存成 ICO 内嵌进单文件; 运行时只写文件 + LoadImage, **不再需要宿主装 Pillow**。
# (模式数跟着 tray.MODE_CHARS 走: 第四十七轮加了「语音」= 5 模式 -> 11 个图标)
tray_icons = {}
try:
    sys.path.insert(0, BASE)
    import tray as _traymod
    for _m in range(len(_traymod.MODE_CHARS)):
        for _act, _sfx in ((True, 'a'), (False, 'i')):
            _b = io.BytesIO()
            _traymod._icon_img(_m, _act).save(_b, format='ICO', sizes=[(64, 64)])
            tray_icons['%d%s' % (_m, _sfx)] = base64.b64encode(_b.getvalue()).decode('ascii')
    _b = io.BytesIO()
    _traymod._tool_icon_img().save(_b, format='ICO', sizes=[(64, 64)])
    tray_icons['tool'] = base64.b64encode(_b.getvalue()).decode('ascii')
    print('tray icons embedded: %d (%.1f KB base64)'
          % (len(tray_icons), sum(len(v) for v in tray_icons.values()) / 1024.0))
except Exception as e:
    tray_icons = {}
    print('WARN: tray icon prerender failed (%r) - 单文件将回退到宿主 Pillow' % (e,))

out = []
out.append('# -*- coding: utf-8 -*-')
out.append('# WgIme-Pure 单文件版 (项目模块 + 第三方库[含声明依赖] 内嵌). 免安装, 零 .NET, 零 pip.')
out.append('import sys, types, os, base64')
out.append('MODULES = ' + repr(modsrc))
out.append('PLUGIN_SRC = ' + repr(plugsrc))
out.append('THIRD_ZIP_B64 = ' + repr(THIRD_ZIP_B64))
out.append('TRAY_ICONS = ' + repr(tray_icons) + '   # 预渲染托盘图标 (base64 ICO, 见 tray._embedded_icons)')
out.append('_la = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "wgime-py")')
out.append('try:')
out.append('    os.makedirs(_la, exist_ok=True)')
out.append('    _r = os.path.realpath(_la).lower()')
out.append('    _v = ("\\\\packages\\\\" in _r and "\\\\localcache\\\\" in _r)')
out.append('except Exception:')
out.append('    _v = False')
out.append('_base = os.path.join(os.path.expanduser("~"), "wgime-py") if _v else _la')
out.append('_third_dir = os.path.join(_base, "site")')
out.append('_third_zip = os.path.join(_third_dir, "thirdparty.zip")')
# 版本校验: 内嵌 zip 的 md5 与磁盘 zip 的 md5 不一致时强制重写(原子替换),
# 否则生产机 site 里残留的旧 thirdparty.zip 永不刷新 -> 旧 comtypes 一直报
# "Typelib different than module". 首次运行或单文件升级后, 这里保证 zip 跟上.
out.append('import hashlib as _hashlib')
out.append('try:')
out.append('    _zip_bytes = base64.b64decode(THIRD_ZIP_B64)')
out.append('    _need_write = (not os.path.exists(_third_zip))')
out.append('    if not _need_write:')
out.append('        with open(_third_zip, "rb") as _rf:')
out.append('            _need_write = (_hashlib.md5(_rf.read()).hexdigest() != _hashlib.md5(_zip_bytes).hexdigest())')
out.append('    if _need_write:')
out.append('        os.makedirs(_third_dir, exist_ok=True)')
out.append('        _tmp_zip = _third_zip + ".tmp"')
out.append('        with open(_tmp_zip, "wb") as _f:')
out.append('            _f.write(_zip_bytes)')
out.append('        os.replace(_tmp_zip, _third_zip)')
out.append('    if _third_zip not in sys.path:')
out.append('        sys.path.insert(0, _third_zip)')
out.append('except Exception:')
out.append('    pass')
out.append('def _load(name, src):')
out.append('    mod = types.ModuleType(name)')
out.append('    sys.modules[name] = mod')
out.append('    mod.__file__ = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")')
out.append('    exec(compile(src, name + ".py", "exec"), mod.__dict__)')
out.append('    return mod')
# 第四十轮: 只有 win/hook/engine 在"装键盘钩子"之前用得到, 其余模块改成"首次被 import 时才 exec"。
# 原来 9 个模块一律在启动时 exec, 实测合计 ~490ms (tray 121 / tools 107 / win 51 / plugins 48 /
# bar 46 / wspy 40 / engine 34 / hook 12 / ui 6) —— 其中 367ms 花在钩子根本用不到的 UI/插件/托盘
# 模块上(它们还要连带着 import tkinter/PIL/pystray), 白白把"按键进输入法"的时刻推后。
# 改成懒加载后钩子提前 ~0.35s 可用; 这些模块在真正 import 时才付各自的 exec 代价(那时主循环已经
# 在跑, 不影响"能不能打字")。
out.append('import threading as _threading')
out.append('_EAGER = ("win", "hook", "engine")   # 装钩子之前必须就绪的模块')
out.append('_PENDING = {}')
out.append('_lazy_lock = _threading.RLock()      # RLock: 模块 exec 期间可能再触发别的懒模块')
out.append('def _load_into(name, mod):')
out.append('    with _lazy_lock:')
out.append('        src = _PENDING.pop(name, None)')
out.append('        if src is None:')
out.append('            return')
out.append('        mod.__dict__.pop("__getattr__", None)   # 去掉懒加载器, 再 exec 真源码')
out.append('        exec(compile(src, name + ".py", "exec"), mod.__dict__)')
out.append('def _lazy(name):')
out.append('    mod = types.ModuleType(name)')
out.append('    mod.__file__ = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".py")')
out.append('    _PENDING[name] = MODULES[name]')
out.append('    def _getattr(attr, _n=name, _m=mod):')
out.append('        _load_into(_n, _m)')
out.append('        return getattr(_m, attr)')
out.append('    mod.__getattr__ = _getattr            # PEP 562 模块级 __getattr__')
out.append('    sys.modules[name] = mod')
out.append('    return mod')
out.append('for _n in MODULES:')
out.append('    if _n in _EAGER:')
out.append('        _load(_n, MODULES[_n])')
out.append('    else:')
out.append('        _lazy(_n)')
out.append('_EMBEDDED_PLUGINS = {}')
out.append('for _pn, _ps in PLUGIN_SRC.items():')
out.append('    _m = _load("plug_" + _pn, _ps)')
out.append('    _EMBEDDED_PLUGINS["plug_" + _pn] = _m')
out.append('_me = sys.modules["__main__"]')
out.append('exec(compile(' + repr(main_src) + ', "wgime-py.py", "exec"), _me.__dict__)')

with open(OUT, 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
print('built', OUT, '%.1f KB' % (os.path.getsize(OUT) / 1024))
print('third-party modules embedded:', len(third_files))
