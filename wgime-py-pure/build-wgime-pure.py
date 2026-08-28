# -*- coding: utf-8 -*-
"""build-wgime-pure.py — 把 wgime-py-pure 全部模块 + 插件内联合成一个单文件 wgime-py.py.
原理: 各模块源按依赖序 exec 进 sys.modules (真实 import 仍可用), 插件源注册为 plug_*,
最后把 main.py 源 exec 进 __main__. 产出即仿 wgime.bat 的"单文件载荷"形态.
"""
import os
import pprint

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

out = []
out.append('# -*- coding: utf-8 -*-')
out.append('# WgIme-Pure 单文件版 (合并自 win/hook/bar/wspy/engine/plugins/tools + 插件). 免安装, 零 .NET.')
out.append('import sys, types')
out.append('import os')
out.append('MODULES = ' + repr(modsrc))
out.append('PLUGIN_SRC = ' + repr(plugsrc))
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
