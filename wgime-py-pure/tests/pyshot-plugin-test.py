# -*- coding: utf-8 -*-
r"""PyShot 插件回归 (第八十九轮补: 单文件双模包装).

`plugins\PyShot.py` 是**一个文件** = 原程序(Qt 单文件版 480KB 生成物) + 薄包装: 整个程序体被
`build-wrap-qt-plugin.py` **缩进进** `_app_main()`, 所以模块级只剩清单 + 几个小函数 —— 装载器
(输入法启动时 exec) 拿到的零重依赖、零副作用; 界面只在 `run()` 拉起**独立进程**时才建。

为什么必须这么绕(而不是像别的插件那样模块级平铺): ①PySide6 不能内嵌进单文件发行版(规范 §12);
②原程序在模块级 `import PySide6.*` + 模块级 `ensure_deps()`(缺包自己 pip 装、装不上 `SystemExit`),
平铺当插件 ⇒ 拖慢输入法启动 / 当场联网装 200MB / 缺依赖时插件静默消失; ③Qt 与宿主 Tk 不能共用主线程事件循环。
`global` 序言那行是**承重的** —— 原程序里 11 处 `global _settings_cache/_current/_cache` 指向模块级缓存,
缩进进函数后若不声明, `_app_main` 的初始化会变成函数局部, 与嵌套函数里的 `global` 成了两个变量
(第 5 节 A/B 对照证明: 删掉那行 `current_language()` 当场 NameError)。

跑法: python wgime-py-pure\tests\pyshot-plugin-test.py
"""
import ast
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
PLUG = os.path.join(PURE, 'plugins')
PLUGF = os.path.join(PLUG, 'PyShot.py')
UG = os.path.join(HERE, 'undefined-globals.py')
GEN = os.path.join(PURE, 'build-wrap-qt-plugin.py')
TAIL_MARK = '# ---- 双模式 (3/3)'
PROLOGUE_RE = re.compile(r'(?m)^    global (.+)$')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-58s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def run(args, env=None, timeout=300, cwd=None):
    r = subprocess.run(args, capture_output=True, timeout=timeout, cwd=cwd or PLUG,
                       env=env if env is not None else os.environ)
    return (r.returncode, (r.stdout or b'').decode('utf-8', 'replace'),
            (r.stderr or b'').decode('utf-8', 'replace'))


def main():
    tmp = tempfile.mkdtemp(prefix='wg-pyshot-')
    try:
        return body(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def body(tmp):
    # ================= 1) 文件卫生 =================
    check('插件存在(原名 PyShot.py, 单文件)', os.path.isfile(PLUGF))
    if not os.path.isfile(PLUGF):
        return 1
    raw = open(PLUGF, 'rb').read()
    txt = raw.decode('utf-8')
    check('LF 行尾(0 CRLF)', raw.count(b'\r\n') == 0, 'CRLF=%d' % raw.count(b'\r\n'))
    check('UTF-8 无 BOM', not raw.startswith(b'\xef\xbb\xbf'))
    check('体量 ~513KB(原程序 480KB 全在里面)', len(raw) > 450 * 1024, '%d B' % len(raw))
    for k in ('CODE', 'NAME', 'DESC', 'VERSION', 'AUTHOR', 'PERM'):
        check('清单键 %s' % k, re.search(r'(?m)^%s\s*=\s*\S' % k, txt) is not None)
    check('双模式标记 STANDALONE = True', re.search(r'(?m)^STANDALONE\s*=\s*True\b', txt) is not None)
    check('清单 CODE = pyshot', re.search(r"(?m)^CODE\s*=\s*'pyshot'", txt) is not None)
    head = txt.find("if __name__ == '__main__':\n    import os as _os")
    hosts = txt.find('\nimport os\n')
    check('双模式文件头在第一个宿主 import 之前', 0 <= head < hosts)
    check('尾块有独立运行入口(测试钩子+STANDALONE-OK)', TAIL_MARK in txt and 'STANDALONE-OK' in txt)
    # 第八十九轮真事故的守门员: 同目录里**只许有一个**大小写不敏感等于 pyshot.py 的文件
    sibs = sorted(f for f in os.listdir(PLUG) if f.lower() in ('pyshot.py', '_pyshot_app.py'))
    check('没有残留的 pyshot.py/_pyshot_app.py(大小写覆盖事故的守门员)', sibs == ['PyShot.py'], repr(sibs))

    # ================= 2) 静态: 包装形状 =================
    tree = ast.parse(txt)
    apps = [x for x in tree.body if isinstance(x, ast.FunctionDef) and x.name == '_app_main']
    check('_app_main 只有一个且是模块级函数', len(apps) == 1)
    prologue = next((s for s in apps[0].body[:3] if isinstance(s, ast.Global)), None)
    gnames = sorted(prologue.names) if prologue is not None else []
    allg = sorted({x for nd in ast.walk(tree) if isinstance(nd, ast.Global) for x in nd.names})
    check('_app_main 有 global 序言且 = 全文件 global 名集合', bool(gnames) and gnames == allg,
          'prologue=%s all=%s' % (gnames, allg))
    check('三个模块级缓存名都在序言里',
          set(allg) == {'_settings_cache', '_current', '_cache'}, repr(allg))
    top = [l for l in txt.split('\n') if l[:1] not in (' ', '\t')]
    check('模块级没有任何 PySide6 import',
          not any(re.match(r'(import|from)\s+PySide6', l) for l in top),
          repr([l for l in top if 'PySide6' in l][:3]))
    check('模块级 import 只有 os/subprocess/sys',
          sorted(l.split()[1] for l in top if l.startswith('import ')) == ['os', 'subprocess', 'sys'],
          repr([l for l in top if l.startswith('import ')]))
    kalls = [nd for nd in tree.body if isinstance(nd, ast.Expr)
             and isinstance(nd.value, ast.Call)
             and getattr(nd.value.func, 'id', '') == '_app_main']
    check('模块级**没有**调用 _app_main()(装载零副作用)', not kalls)
    check('载荷的依赖自举被缩进进了函数(不在模块级)', '\n    if not ensure_deps():' in txt
          and '\nif not ensure_deps():' not in txt)
    check('载荷指纹: APP_VERSION = "2.16.1"', 'APP_VERSION = "2.16.1"' in txt)
    check('载荷指纹: class SnipperOverlay / act_copy 还在',
          'class SnipperOverlay' in txt and 'act_copy' in txt)

    # ================= 3) 装载纯净: 零重依赖(子进程里量, 不受本测试后续 import 影响) =================
    loader = os.path.join(tmp, 'load.py')
    with open(loader, 'w', encoding='utf-8', newline='') as f:
        f.write('# -*- coding: utf-8 -*-\n'
                'import importlib.util, json, os, sys, time\n'
                'P = sys.argv[1]\n'
                't0 = time.perf_counter()\n'
                'spec = importlib.util.spec_from_file_location("wg_pyshot_probe", P)\n'
                'm = importlib.util.module_from_spec(spec); sys.modules["wg_pyshot_probe"] = m\n'
                'spec.loader.exec_module(m)\n'
                'print("LOADINFO " + json.dumps({\n'
                '    "ms": round((time.perf_counter() - t0) * 1000),\n'
                '    "pyside": "PySide6" in sys.modules,\n'
                '    "code": m.CODE, "run": callable(m.run), "sa": bool(m.STANDALONE),\n'
                '    "ver": m.app_version(),\n'
                '    "self": os.path.abspath(m.spawn_argv()[-1]),\n'
                '    "tail": m.spawn_argv(["--check-deps"])[-1],\n'
                '    "skip": m.child_env(skip_deps=True).get("PYSHOT_SKIP_DEPS"),\n'
                '    "clean": "PYSHOT_SKIP_DEPS" not in m.child_env(),\n'
                '    "hint": ("PySide6" in m.missing_hint() and "deps" in m.missing_hint()),\n'
                '}, ensure_ascii=False))\n')
    rc, so, se = run([sys.executable, '-X', 'utf8', loader, PLUGF], timeout=180)
    check('装载子进程 rc=0', rc == 0, 'rc=%s err=%r' % (rc, se[-300:]))
    info = {}
    for l in so.split('\n'):
        if l.startswith('LOADINFO '):
            info = json.loads(l[len('LOADINFO '):])
    check('装载**不** import PySide6(输入法启动不被拖累)', info.get('pyside') is False, so.strip())
    check('装载 <2000ms(冷编译也算; 关键是上面那条)', (info.get('ms') or 99999) < 2000, str(info.get('ms')))
    check('契约: CODE=pyshot / run 可调用 / STANDALONE / 版本 2.16.1',
          info.get('code') == 'pyshot' and info.get('run') and info.get('sa')
          and info.get('ver') == '2.16.1', so.strip())
    check('spawn_argv 指向自己 + 透传额外参数',
          info.get('self') == os.path.abspath(PLUGF) and info.get('tail') == '--check-deps', so.strip())
    check('child_env(skip_deps) 设 PYSHOT_SKIP_DEPS, 干净时不设',
          info.get('skip') == '1' and info.get('clean') is True, so.strip())
    check('missing_hint 给 PySide6 + deps 两条线索', info.get('hint') is True, so.strip())

    # ---- 3b) 真宿主装载器收下它(把 main.py 里的 load_py_plugins 源码抠出来跑, 只喂它一个插件目录) ----
    main_src = open(os.path.join(PURE, 'main.py'), encoding='utf-8').read()
    mtree = ast.parse(main_src)
    lfn = next(nd for nd in mtree.body
               if isinstance(nd, ast.FunctionDef) and nd.name == 'load_py_plugins')
    pdir = os.path.join(tmp, 'load', 'plugins')
    os.makedirs(pdir, exist_ok=True)
    shutil.copyfile(PLUGF, os.path.join(pdir, 'PyShot.py'))
    lns = {'os': os, 'sys': sys, 'importlib': importlib, 'PLUGINS': [],
           'BASE': os.path.join(tmp, 'load'), 'APP_DIR': os.path.join(tmp, 'load'),
           'DATA_DIR': os.path.join(tmp, 'load'),
           '_dfn': lambda *a: None,                    # 装载器内部的 debug 日志出口
           'read_text': lambda p: open(p, encoding='utf-8-sig').read()}
    exec(compile(ast.get_source_segment(main_src, lfn), 'main.py:load_py_plugins', 'exec'), lns)
    lns['load_py_plugins']()
    codes = [getattr(m, 'CODE', None) for m in lns['PLUGINS']]
    check('真宿主装载器收下它(CODE + callable run 契约)', 'pyshot' in codes, repr(codes))
    check('真宿主装载器装载时**不** import PySide6', 'PySide6' not in sys.modules,
          str([k for k in sys.modules if k.startswith('PySide6')][:3]))

    # ================= 4) 子进程契约(假 Popen) =================
    mod = load_module(PLUGF, 'wg_pyshot_under_test')
    seen = {}

    class _FakePopen(object):
        pid = 4242

        def __init__(self, a, **kw):
            seen['argv'], seen['kw'] = a, kw

    pid = mod.spawn(popen=_FakePopen)
    check('spawn(假 Popen): 返回 pid', pid == 4242, repr(pid))
    check('spawn: CREATE_NO_WINDOW(0x08000000)', seen['kw'].get('creationflags') == 0x08000000,
          repr(seen['kw'].get('creationflags')))
    check('spawn: cwd = 插件目录', seen['kw'].get('cwd') == PLUG, repr(seen['kw'].get('cwd')))
    check('spawn: 三个标准流都不继承',
          seen['kw'].get('stdin') is subprocess.DEVNULL and seen['kw'].get('stdout') is subprocess.DEVNULL
          and seen['kw'].get('stderr') is subprocess.DEVNULL)
    check('spawn: argv[0] 是 pythonw(不弹黑框)或 python',
          os.path.basename(seen['argv'][0]).lower() in ('pythonw.exe', 'python.exe'), seen['argv'][0])
    check('app_version() 抠到 2.16.1', mod.app_version() == '2.16.1', repr(mod.app_version()))
    # run() 不许阻塞 Tk 主线程(气泡出口打桩, 别把测试输出弄花)
    mod._tip = lambda text: None
    saved = mod.pyside_available
    mod.pyside_available = lambda: False
    t0 = time.perf_counter()
    ok = mod.run()
    dt = (time.perf_counter() - t0) * 1000
    mod.pyside_available = saved
    check('run(): 缺 PySide6 时立刻返回 False(不阻塞)', ok is False and dt < 50, '%.0fms' % dt)
    mod.spawn = lambda *a, **k: 111
    check('run(): 有 PySide6 时拉起自己并返 True', mod.run() is True)

    # ================= 5) 包装语义: global 序言是承重的(A/B 对照, 真载荷) =================
    os.environ.setdefault('PYSHOT_SKIP_DEPS', '1')
    os.environ.setdefault('PYSHOT_NO_ALERT', '1')
    os.environ['PYSHOT_SESSION_DIR'] = os.path.join(tmp, 'sess')
    head, sep, tail = txt.partition(TAIL_MARK)
    probed = head + '    return locals()\n\n\n' + sep + tail      # 让 _app_main 交出整个命名空间
    argv_save = sys.argv

    def drive(src, tag):
        g = {'__name__': 'wg_pyshot_' + tag, '__file__': PLUGF}
        exec(compile(src, PLUGF, 'exec'), g)
        return g, g['_app_main']()          # __name__ 非 __main__ ⇒ 载荷入口块不跑

    try:
        sys.argv = ['wg-pyshot-plugin-test']
        g, ns = drive(probed, 'real')
        check('载荷体整体可执行(拿到 >300 个模块级名字)', len(ns) > 300, 'ns=%d' % len(ns))
        for nm in ('_settings_cache', '_current', '_cache'):
            check('%s 落在模块全局(序言生效)' % nm, nm in g and nm not in ns,
                  'in_g=%s in_ns=%s' % (nm in g, nm in ns))
        check('current_language() 可用(嵌套函数看到全局初始化值)',
              isinstance(ns['current_language'](), str), repr(ns['current_language']()))
        check('set_language(persist=False) 与其它函数共用同一份全局',
              ns['set_language']('en', False) == 'en' and g['_current'] == 'en', repr(g.get('_current')))
        check('_load_settings() 灌缓存且是同一份全局',
              isinstance(ns['_load_settings'](), dict) and isinstance(g['_settings_cache'], dict),
              type(g.get('_settings_cache')).__name__)
        check('方法体/类体也能看到模块级常量(tr/TABLE)',
              isinstance(ns['tr']('取消'), str) and ns['tr']('取消') != '', repr(ns['tr']('取消')))
        control = probed.replace(PROLOGUE_RE.search(probed).group(0) + '\n', '', 1)
        g2, ns2 = drive(control, 'control')
        check('对照: 删掉序言后三个缓存变成函数局部', '_settings_cache' in ns2 and '_settings_cache' not in g2,
              'in_g=%s in_ns=%s' % ('_settings_cache' in g2, '_settings_cache' in ns2))
        err = None
        try:
            ns2['current_language']()
        except NameError as ex:
            err = str(ex)
        check('对照: 删掉序言 current_language() 当场 NameError ⇒ 那行是承重的',
              err is not None, err or '(没抛错, 危险!)')
    finally:
        sys.argv = argv_save

    # ================= 6) 独立运行 =================
    # (a) 挡住 PySide6 ⇒ 走 SKIP 分支: rc=0, 不联网, 仍打标记(任何机器上都可跑)
    block = os.path.join(tmp, 'blocked.py')
    with open(block, 'w', encoding='utf-8', newline='') as f:
        f.write('# -*- coding: utf-8 -*-\n'
                'import os, runpy, sys\n'
                'class _Block:\n'
                '    def find_spec(self, name, path=None, target=None):\n'
                '        if name == "PySide6" or name.startswith("PySide6."):\n'
                '            raise ImportError("blocked PySide6 (test)")\n'
                '        return None\n'
                'sys.meta_path.insert(0, _Block())\n'
                'os.environ["WGIME_STANDALONE_AUTOEXIT_MS"] = "2500"\n'
                'sys.argv = [sys.argv[1], "--check-deps"]\n'
                'runpy.run_path(sys.argv[0], run_name="__main__")\n')
    env = dict(os.environ, WGIME_STANDALONE_AUTOEXIT_MS='2500', PYTHONIOENCODING='utf-8',
               LOCALAPPDATA=tmp)                      # 数据目录隔离, 绝不碰用户数据
    rc, so, se = run([sys.executable, '-X', 'utf8', block, PLUGF], env=env, timeout=240)
    check('缺 PySide6 时独立运行 rc=0(SKIP 分支兜住, 不红)', rc == 0,
          'rc=%s err=%r' % (rc, se[-300:]))
    check('缺 PySide6 时打印 STANDALONE-SKIP-DEPS + STANDALONE-OK',
          'STANDALONE-SKIP-DEPS' in so and 'STANDALONE-OK' in so, so.strip()[-200:])
    check('缺 PySide6 时没联网装包(无 pip 痕迹)', 'pip install' not in so + se, (so + se)[-200:])
    # (b) 真独立运行(测试钩子: 不出界面)
    rc, so, se = run([sys.executable, '-X', 'utf8', PLUGF], env=env, timeout=240)
    check('独立运行(测试钩子) rc=0', rc == 0, 'rc=%s err=%r' % (rc, se[-300:]))
    check('独立运行打印 STANDALONE-OK', 'STANDALONE-OK' in so, so.strip()[-160:])
    # (c) 真 --check-deps
    rc, so, se = run([sys.executable, '-X', 'utf8', PLUGF, '--check-deps'],
                     env=dict(os.environ, PYSHOT_NO_ALERT='1'), timeout=240)
    if 'PySide6' in so and 'PyShot 2.16.1' in so:
        check('--check-deps rc=0 且报出 PyShot 版本与 PySide6', rc == 0, 'rc=%s' % rc)
    else:
        print('  %-58s SKIP (本机没装 PySide6: %r)' % ('--check-deps 真机自检', so.strip()[-60:]))

    # ================= 7) undefined-globals 跳过名单 =================
    ug = open(UG, encoding='utf-8').read()
    m = re.search(r'SKIP_FILES = \{(.*?)\n\}', ug, re.S)
    entries = re.findall(r"r'([^']+)'", m.group(1)) if m else []
    check('undefined-globals 有 SKIP_FILES', m is not None)
    check('跳过名单只有 plugins\\PyShot.py', entries == [r'plugins\PyShot.py'], repr(entries))
    rc, so, se = run([sys.executable, '-X', 'utf8', UG], timeout=600)
    check('undefined-globals 全量扫描仍然 RESULT: OK', 'RESULT: OK' in so,
          so.strip().split('\n')[-1:])

    # ================= 8) 生成器回归: 合成一个"Qt 式单文件"走 wrap() =================
    fix_src = '''# -*- coding: utf-8 -*-
"""合成的 Qt 式单文件: 模块级 import + 模块级自举 + global 缓存 + 尾 __main__."""
import json
import os
import sys

CACHE = None
COUNT = [0]

print('IMPORT-SIDE-EFFECT')          # 模块级副作用: 包装后装载时**不该**跑

if os.environ.get('MINI_FAIL'):
    raise SystemExit(1)              # 模块级自举(模拟 ensure_deps 失败)


def set_cache(v):
    global CACHE
    CACHE = v
    COUNT[0] += 1


def get_cache():
    global CACHE
    return CACHE


class Thing:
    def label(self):
        return 'label:' + str(CACHE)      # 方法体引用模块级全局


def main():
    set_cache({'n': 1})
    return json.dumps([get_cache(), Thing().label(), COUNT[0]], ensure_ascii=False)


if __name__ == '__main__':
    print('OUT ' + main())
'''
    fix = os.path.join(tmp, 'mini_qt_app.py')
    with open(fix, 'w', encoding='utf-8', newline='') as f:
        f.write(fix_src)
    gen = load_module(GEN, 'wg_wrap_gen')
    wrapped, info = gen.wrap(fix_src, 'miniqt', '合成小程序', '生成器回归用')
    wpath = os.path.join(tmp, 'mini_wrapped.py')
    with open(wpath, 'w', encoding='utf-8', newline='') as f:
        f.write(wrapped)
    check('生成器 wrap(): 报告了 global 名集合', info.get('globals') == ['CACHE'], repr(info.get('globals')))
    check('生成器 wrap(): 生成物 global 序言含 CACHE',
          re.search(r'(?m)^    global CACHE$', wrapped) is not None)
    check('生成器 wrap(): 生成物体量 > 原文件(缩进变宽)', os.path.getsize(wpath) > len(fix_src))
    # 原程序: 当模块 import 就跑模块级副作用; 包装后: import 零副作用
    probe = os.path.join(tmp, 'probe_import.py')
    with open(probe, 'w', encoding='utf-8', newline='') as f:
        f.write('# -*- coding: utf-8 -*-\n'
                'import importlib.util, sys\n'
                'spec = importlib.util.spec_from_file_location("mini", sys.argv[1])\n'
                'm = importlib.util.module_from_spec(spec)\n'
                'sys.modules["mini"] = m\n'
                'spec.loader.exec_module(m)\n'
                'print("HAS_APP_MAIN %s" % hasattr(m, "_app_main"))\n')
    rc1, so1, _ = run([sys.executable, '-X', 'utf8', probe, fix], timeout=120)
    rc2, so2, _ = run([sys.executable, '-X', 'utf8', probe, wpath], timeout=120)
    check('原程序: 当模块 import 就喷模块级副作用(所以才不能直接当插件)',
          'IMPORT-SIDE-EFFECT' in so1, so1.strip())
    check('包装后: 当模块 import **零副作用**', 'IMPORT-SIDE-EFFECT' not in so2, so2.strip())
    check('包装后: 模块里只有 _app_main, 没有模块级 CACHE', 'HAS_APP_MAIN True' in so2, so2.strip())
    # 独立运行的**行为等价**: 原程序输出 == 包装后输出(只看 OUT 行)
    rc3, so3, se3 = run([sys.executable, '-X', 'utf8', fix], timeout=120)
    env4 = dict(os.environ, WGIME_STANDALONE_AUTOEXIT_MS='2500')
    rc4, so4, se4 = run([sys.executable, '-X', 'utf8', wpath], env=env4, timeout=120)
    outs = [l for l in so3.split('\n') if l.startswith('OUT ')]
    outw = [l for l in so4.split('\n') if l.startswith('OUT ')]
    check('原程序独立运行有 OUT 行', rc3 == 0 and len(outs) == 1, 'rc=%s %r' % (rc3, so3.strip()[-120:]))
    check('包装后独立运行输出**逐字相同**(global 语义等价)',
          rc4 == 0 and outw == outs, 'rc=%s %r vs %r' % (rc4, outw, outs))
    check('包装后独立运行也打 STANDALONE-OK', 'STANDALONE-OK' in so4, so4.strip()[-120:])
    check('生成器自带守卫: 输入=输出时拒绝', gen.main([fix, fix]) == 2)

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
