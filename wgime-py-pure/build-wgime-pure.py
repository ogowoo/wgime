# -*- coding: utf-8 -*-
"""build-wgime-pure.py — 把 wgime-py-pure 全部模块 + 插件 + 第三方库内联合成一个单文件 wgime-py.py.
原理:
  - 项目模块(win/hook/engine/...) 按依赖序 exec 进 sys.modules (真实 import 仍可用)
  - 插件源注册为 plug_*
  - 第三方库(comtypes + uiautomation, 纯 Python) 打包成 zip, 运行时解压到
    %LOCALAPPDATA%\\wgime-py\\site 并 zipimport —— 标准 import 机制, 包结构/相对导入天然正确
  - 最后把 main.py 源 exec 进 __main__
"""
import os
import io
import base64
import zipfile
import importlib
import pkgutil
import importlib.util

BASE = os.path.dirname(os.path.abspath(__file__))
MODULES = ['win', 'hook', 'bar', 'wspy', 'engine', 'plugins', 'ui', 'tools', 'tray']
OUT = os.path.join(BASE, 'dist', 'wgime-py.py')
os.makedirs(os.path.dirname(OUT), exist_ok=True)


def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()


modsrc = {m: read(os.path.join(BASE, m + '.py')) for m in MODULES}
plugsrc = {}
pdir = os.path.join(BASE, 'plugins')
if os.path.isdir(pdir):
    for fn in sorted(os.listdir(pdir)):
        if fn.endswith('.py'):
            plugsrc[fn[:-3]] = read(os.path.join(pdir, fn))
main_src = read(os.path.join(BASE, 'main.py'))


# ---- 第三方库收集: comtypes + uiautomation (纯 Python; 排除 test 子包) ----
def collect_thirdparty(pkgnames):
    files = {}
    for pkgname in pkgnames:
        try:
            pkg = importlib.import_module(pkgname)
        except Exception:
            print('WARN: import %s failed, skipping' % pkgname)
            continue
        files[pkgname + '/__init__.py'] = read(pkg.__file__)
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
    return files


third_files = collect_thirdparty(['comtypes', 'uiautomation', 'pystray'])
buf = io.BytesIO()
with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel, src in sorted(third_files.items()):
        z.writestr(rel, src)
THIRD_ZIP_B64 = base64.b64encode(buf.getvalue()).decode('ascii')

out = []
out.append('# -*- coding: utf-8 -*-')
out.append('# WgIme-Pure 单文件版 (项目模块 + 插件 + comtypes/uiautomation 内嵌). 免安装, 零 .NET, 零 pip.')
out.append('import sys, types, os, base64')
out.append('MODULES = ' + repr(modsrc))
out.append('PLUGIN_SRC = ' + repr(plugsrc))
out.append('THIRD_ZIP_B64 = ' + repr(THIRD_ZIP_B64))
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
out.append('for _n in MODULES:')
out.append('    _load(_n, MODULES[_n])')
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
