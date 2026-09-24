# -*- coding: utf-8 -*-
r"""PyShot 插件回归 (第八十九轮, 纯逻辑 + 安全的真机 `--check-deps`).

`plugins\pyshot.py` 是**薄包装**: 真正的 PyShot(Qt 程序, 480KB 生成物) 是 `plugins\_pyshot_app.py`
(`_` 开头 ⇒ 装载器跳过 —— 它有模块级 `import PySide6` 和模块级 `ensure_deps()`, 进了装载器就会在
**输入法启动时** exec/自装依赖/缺依赖时静默消失). 本测试钉住:

  1. 薄插件卫生: 存在 / LF / 无 BOM / 清单六键 / 双模式三块 / 契约(CODE + 可调用 run)
  2. **载荷不被装载**: 同一谓词下 `_pyshot_app.py` 被排除、`pyshot.py` 被包含
  3. **两文件共存且大小悬殊** —— 守"Windows 大小写不敏感, 别再把薄插件写成 `PyShot.py` 覆盖载荷"
  4. 载荷指纹(行数/版本/自举语句) —— 防被替换成别的东西
  5. 子进程契约: `spawn_argv()` 形状、`child_env()` 挂私有 site + 测试开关、`spawn(popen=假)` 的参数
  6. 真机: 载荷 `--check-deps` 与 `python pyshot.py --check-deps` 都 rc=0 且打印 STANDALONE-OK 标记
  7. undefined-globals 跳过名单**只有**它一个 (防名单悄悄膨胀)

跑法: python wgime-py-pure\tests\pyshot-plugin-test.py
"""
import importlib.util
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
PLUG = os.path.join(PURE, 'plugins')
THIN = os.path.join(PLUG, 'pyshot.py')
PAYLOAD = os.path.join(PLUG, '_pyshot_app.py')
UG = os.path.join(HERE, 'undefined-globals.py')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def main():
    # ---- 1) 薄插件卫生 ----
    check('薄插件存在', os.path.isfile(THIN))
    if not os.path.isfile(THIN):
        return 1
    raw = open(THIN, 'rb').read()
    txt = raw.decode('utf-8')
    check('薄插件: LF 行尾(0 CRLF)', raw.count(b'\r\n') == 0, 'CRLF=%d' % raw.count(b'\r\n'))
    check('薄插件: UTF-8 无 BOM', not raw.startswith(b'\xef\xbb\xbf'))
    for k in ('CODE', 'NAME', 'DESC', 'VERSION', 'AUTHOR', 'PERM'):
        check('清单键 %s' % k, re.search(r'(?m)^%s\s*=\s*\S' % k, txt) is not None)
    check('双模式标记 STANDALONE = True', re.search(r'(?m)^STANDALONE\s*=\s*True\b', txt) is not None)
    head = txt.find("if __name__ == '__main__':")
    hosts = [i for i in (txt.find('\nimport os'), txt.find('\nimport subprocess')) if i >= 0]
    check('文件头在第一个宿主 import 之前', 0 <= head < (min(hosts) if hosts else -1))
    check("别再用 PyShot.py 当薄插件名(注释里有告警)", '别再把本文件写成 `PyShot.py`' in txt)

    # ---- 2) 契约 ----
    sys.path.insert(0, PURE)
    spec = importlib.util.spec_from_file_location('wg_ext_pyshot_under_test', THIN)
    mod = importlib.util.module_from_spec(spec)
    sys.modules['wg_ext_pyshot_under_test'] = mod
    spec.loader.exec_module(mod)
    check('CODE 非空且为 str', isinstance(getattr(mod, 'CODE', None), str) and bool(mod.CODE))
    check('run() 可调用', callable(getattr(mod, 'run', None)))
    check("CODE 是 'pyshot'", mod.CODE == 'pyshot', repr(mod.CODE))

    # ---- 3) 载荷: 存在 / 不被装载 / 两文件共存 ----
    check('载荷存在', os.path.isfile(PAYLOAD))
    allpy = sorted(f for f in os.listdir(PLUG) if f.lower().endswith('.py'))
    loaded = [f for f in allpy if not f.startswith('_')]        # 宿主谓词的等价复现
    check('载荷被宿主谓词排除(`_` 开头)', os.path.basename(PAYLOAD) not in loaded)
    check('薄插件被宿主谓词包含', 'pyshot.py' in loaded)
    thin_sz, pay_sz = os.path.getsize(THIN), os.path.getsize(PAYLOAD)
    check('两文件共存且大小悬殊(薄 < 载荷/10)', pay_sz > thin_sz * 10, 'thin=%d payload=%d' % (thin_sz, pay_sz))

    # ---- 4) 载荷指纹 ----
    ptail = open(PAYLOAD, encoding='utf-8', errors='replace').read()
    plines = ptail.count('\n') + 1
    check('载荷行数 ~10733(生成物指纹)', plines == 10733, 'lines=%d' % plines)
    check('载荷含 APP_VERSION = "2.16.1"', 'APP_VERSION = "2.16.1"' in ptail)
    check('载荷含模块级依赖自举(所以才不能进装载器)', 'if not ensure_deps():' in ptail)
    check('payload_version() 抠到 2.16.1', mod.payload_version() == '2.16.1', repr(mod.payload_version()))

    # ---- 5) 子进程契约 ----
    argv = mod.spawn_argv(['--check-deps'])
    check('spawn_argv: 含 -X utf8 与载荷绝对路径',
          '-X' in argv and 'utf8' in argv and PAYLOAD in argv)
    check('spawn_argv: 额外参数透传', argv[-1] == '--check-deps')
    env = mod.child_env(skip_deps=True)
    check('child_env: 自动化时设 PYSHOT_SKIP_DEPS/NO_ALERT',
          env.get('PYSHOT_SKIP_DEPS') == '1' and env.get('PYSHOT_NO_ALERT') == '1')
    check('child_env: 不设这两个开关时保持干净',
          'PYSHOT_SKIP_DEPS' not in mod.child_env())
    seen = {}

    class _FakePopen(object):
        pid = 4242

        def __init__(self, a, **kw):
            seen['argv'], seen['kw'] = a, kw

    pid = mod.spawn(popen=_FakePopen)
    check('spawn(假 Popen): 返回 pid', pid == 4242)
    check('spawn: 用 CREATE_NO_WINDOW(0x08000000)',
          seen['kw'].get('creationflags') == 0x08000000, repr(seen['kw'].get('creationflags')))
    check('spawn: cwd = 插件目录(让载荷同目录定位)', seen['kw'].get('cwd') == PLUG)
    check('spawn: stdin/stdout/stderr 都不继承',
          seen['kw'].get('stdin') is subprocess.DEVNULL and seen['kw'].get('stdout') is subprocess.DEVNULL)
    check('missing_hint: 给出 PySide6 与 deps 两条线索',
          'PySide6' in mod.missing_hint() and 'deps' in mod.missing_hint())

    # ---- 6) 真机: 载荷自检 + 薄插件独立运行(都不出界面) ----
    r = subprocess.run(mod.spawn_argv(['--check-deps']), env=mod.child_env(skip_deps=True),
                       capture_output=True, timeout=120, cwd=PLUG)
    out = (r.stdout or b'').decode('utf-8', 'replace') + (r.stderr or b'').decode('utf-8', 'replace')
    check('载荷 --check-deps: rc=0', r.returncode == 0, 'rc=%s' % r.returncode)
    check('载荷 --check-deps: 报告里提到 PySide6', 'PySide6' in out, out[-160:].replace('\n', ' '))
    has_pyside = '缺失' not in out or '[OK]' in out
    print('       （本机 PySide6 状态: %s）' % ('已就绪' if '[OK]' in out else '缺失'))
    r2 = subprocess.run([sys.executable, '-X', 'utf8', THIN, '--check-deps'],
                        capture_output=True, timeout=120, cwd=PLUG,
                        env=dict(os.environ, PYSHOT_SKIP_DEPS='1', PYSHOT_NO_ALERT='1'))
    o2 = (r2.stdout or b'').decode('utf-8', 'replace')
    check('薄插件 --check-deps: rc=0', r2.returncode == 0, 'rc=%s' % r2.returncode)
    check('薄插件 --check-deps: 打印 STANDALONE-OK 标记', 'STANDALONE-OK' in o2, o2[-120:])
    check('薄插件独立运行(自动退出钩子)也走自检', has_pyside)     # 上面那条已覆盖真实分支

    # ---- 7) undefined-globals 跳过名单 ----
    ug = open(UG, encoding='utf-8').read()
    block = re.search(r'SKIP_FILES = \{(.*?)\n\}', ug, re.S)
    entries = re.findall(r"r'([^']+)'", block.group(1)) if block else []
    check('undefined-globals 有 SKIP_FILES', block is not None)
    check('跳过名单只有 _pyshot_app.py 一个', entries == [r'plugins\_pyshot_app.py'], repr(entries))
    r3 = subprocess.run([sys.executable, '-X', 'utf8', UG], capture_output=True, timeout=300)
    o3 = (r3.stdout or b'').decode('utf-8', 'replace')
    check('undefined-globals 全量扫描仍然 0', 'RESULT: OK' in o3, o3.strip().split('\n')[-1:])

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
