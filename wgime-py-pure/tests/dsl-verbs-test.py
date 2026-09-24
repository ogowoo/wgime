# -*- coding: utf-8 -*-
r"""步骤 DSL 动词回归 (第八十九轮补: 新增 `start` = 拉起**常驻**程序且不等它退出).

来由: DSL 和 tools.txt 按钮以前**启动不了常驻程序** —— `run`/`shell`/`shellx`/多行块都是
`subprocess.run(...)`(= 等进程结束; 超时 120s/300s/86400s), 拿它们启动一个不退出的托盘工具 =
调用线程干等到超时, 然后**子进程被杀**; 唯一不等的 `open` 又不能传参数、不能选解释器、还不隐藏窗口。
所以补一个 `start` 动词: `Popen` 不等 + `CREATE_NO_WINDOW` + 参数照传, 语义与 C# `ExecToolStep` 的
`start` 分支**逐条对齐**(§32: DSL 两侧不许漂移 —— 本测试第 5 节把这个"不许漂移"钉死)。

跑法: python wgime-py-pure\tests\dsl-verbs-test.py
"""
import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
ROOT = os.path.dirname(PURE)
PLUGMOD = os.path.join(PURE, 'plugins.py')
BAT = os.path.join(ROOT, 'wgime.bat')
SPEC = os.path.join(ROOT, 'docs', 'WGIME_插件规范.md')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


class _FakeSP(object):
    """只替换 plugins.py 里的 `subprocess` 名字(不动真模块), 用来钉住调用形态."""
    DEVNULL = subprocess.DEVNULL
    CREATE_NO_WINDOW = getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000)
    calls = {'popen': [], 'run': []}

    class _P(object):
        pid = 4242

    @classmethod
    def reset(cls):
        cls.calls = {'popen': [], 'run': []}

    @classmethod
    def Popen(cls, *a, **kw):
        cls.calls['popen'].append((a, kw))
        return cls._P()

    @classmethod
    def run(cls, *a, **kw):
        cls.calls['run'].append((a, kw))
        return type('R', (), {'stdout': '', 'stderr': '', 'returncode': 0})()


def body(tmp):
    # ---------------- 1) 装载被测模块 ----------------
    sys.path.insert(0, PURE)
    spec = importlib.util.spec_from_file_location('wg_dsl_plug', PLUGMOD)
    plug = importlib.util.module_from_spec(spec)
    sys.modules['wg_dsl_plug'] = plug
    spec.loader.exec_module(plug)
    check('plugins.py 可装载', callable(plug.run_steps))
    logs = []

    def log(m):
        logs.append(str(m))

    def msgbox(t, m):
        logs.append('msgbox:%s' % m)

    def confirm(*a, **k):
        return True

    child = os.path.join(tmp, 'child.py')
    with open(child, 'w', encoding='utf-8', newline='') as f:
        f.write('# -*- coding: utf-8 -*-\n'
                'import sys, time\n'
                'time.sleep(float(sys.argv[1]))\n'
                'with open(sys.argv[2], "w", encoding="utf-8") as fh:\n'
                '    fh.write("|".join(sys.argv[3:]))\n')

    def step(text):
        del logs[:]
        t0 = time.perf_counter()
        r = plug.run_steps(text, log, msgbox, confirm)
        return r, (time.perf_counter() - t0), list(logs)

    py = sys.executable

    # ---------------- 2) start: 立即返回, 子进程真活下来 ----------------
    mark = os.path.join(tmp, 'marker-start.txt')
    r, dt, lg = step('start "%s" "%s" 1.2 "%s" "hello world"' % (py, child, mark))
    check('start: 那一步成功(rc=0)', r == 0, 'r=%s log=%r' % (r, lg))
    check('start: 立刻返回(不等子进程; 子进程要睡 1.2s)', dt < 0.9, '%.2fs' % dt)
    check('start: 返回时标记文件还没出现(说明真没等)', not os.path.exists(mark))
    check('start: 日志里有 started pid', any('started pid' in x for x in lg), repr(lg))
    ok = False
    for _ in range(80):                                   # 最多等 8s
        if os.path.exists(mark):
            ok = True
            break
        time.sleep(0.1)
    got = ''
    if ok:
        got = open(mark, encoding='utf-8').read()
    check('start: 子进程在后台跑完了(隔离出来自己活)', ok, 'marker=%r' % got)
    check('start: 参数原样传过去(带空格的引号参数算一个)', got == 'hello world', repr(got))

    # ---------------- 3) 对照: run 会等 ----------------
    mark2 = os.path.join(tmp, 'marker-run.txt')
    r2, dt2, lg2 = step('run "%s" "%s" 0.4 "%s"' % (py, child, mark2))
    check('run(对照): 那一步成功', r2 == 0, 'r=%s log=%r' % (r2, lg2))
    check('run(对照): 确实**等**了子进程(≥0.35s)', dt2 >= 0.35, '%.2fs' % dt2)
    check('run(对照): 等完标记文件已在', os.path.exists(mark2))

    # ---------------- 4) 出错要走"记一步失败", 且不能静默成功 ----------------
    r3, _, lg3 = step('start')
    check('start 缺程序名: 记一步失败', r3 == 1, 'r=%s log=%r' % (r3, lg3))
    check('start 缺程序名: 有明确原因', any('缺少程序名' in x for x in lg3), repr(lg3))
    r4, _, lg4 = step('start "Z:\\wg-nonexistent\\nope.exe"')
    check('start 找不到程序: 记一步失败', r4 == 1, 'r=%s log=%r' % (r4, lg4))
    check('start 找不到程序: 报出路径而不是静默', any('nope.exe' in x for x in lg4), repr(lg4))
    r5, _, lg5 = step('start\nmsg 后续步骤照跑')
    check('start 失败后**后续步骤照跑**(同 run_steps 语义)', r5 == 1 and any('msgbox:后续步骤照跑' in x for x in lg5),
          'r=%s log=%r' % (r5, lg5))

    # ---------------- 5) 调用形态(假 subprocess, 不动真模块) ----------------
    real = plug.subprocess
    os.environ['WG_DSL_TEST_EXE'] = 'x.exe'
    try:
        plug.subprocess = _FakeSP
        _FakeSP.reset()
        step('start "%WG_DSL_TEST_EXE%" a b %WG_DSL_TEST_EXE%')
        popen, runs = _FakeSP.calls['popen'], _FakeSP.calls['run']
        check('start 用 Popen(不是 run)', len(popen) == 1 and not runs,
              'popen=%d run=%d' % (len(popen), len(runs)))
        argv, kwargs = popen[0][0][0], popen[0][1]
        check('start: 三个标准流都指 DEVNULL(不继承 pythonw 的无效句柄)',
              kwargs.get('stdin') is subprocess.DEVNULL and kwargs.get('stdout') is subprocess.DEVNULL
              and kwargs.get('stderr') is subprocess.DEVNULL, repr(kwargs))
        check('start: 藏掉控制台窗口(CREATE_NO_WINDOW)',
              kwargs.get('creationflags') == _FakeSP.CREATE_NO_WINDOW, repr(kwargs.get('creationflags')))
        check('start: 只展开程序名里的 %VAR%, 参数原样(对齐 C# run/start)',
              list(argv) == ['x.exe', 'a', 'b', '%WG_DSL_TEST_EXE%'], repr(argv))
        _FakeSP.reset()
        step('run "%WG_DSL_TEST_EXE%" a')
        popen, runs = _FakeSP.calls['popen'], _FakeSP.calls['run']
        check('run(对照)仍走 subprocess.run(timeout=120)', len(runs) == 1 and not popen
              and runs[0][1].get('timeout') == 120, repr(runs[:1]))
    finally:
        plug.subprocess = real
        os.environ.pop('WG_DSL_TEST_EXE', None)

    # ---------------- 6) 两侧动词不许漂移(§32) ----------------
    src = open(PLUGMOD, encoding='utf-8').read()
    py_verbs = set(re.findall(r"(?:if|elif) verb == '([a-z\-]+)'", src))
    tags = re.search(r"_BLOCK_OPEN_RE = re\.compile\(r'\^\\\[\(([a-z|]+)\)", src)
    tagmap = {'shell': 'shell', 'cmd': 'shell', 'shellx': 'shellx', 'cmdx': 'shellx',
              'powershell': 'powershell', 'ps': 'powershell', 'powershellx': 'powershellx', 'psx': 'powershellx'}
    py_blocks = {tagmap[t] for t in (tags.group(1).split('|') if tags else [])}
    bat = open(BAT, encoding='utf-8', errors='replace').read()
    i = bat.index('static string ExecToolStep(')
    seg = bat[i:bat.index('void ShowTools()', i)]
    cs_raw = set(re.findall(r'\bv == "([a-z\-]+)"', seg))     # \b: 别把 `ov == "ok"` 也收进来
    csmap = {'shellblock': 'shell', 'psblock': 'powershell', 'shellblockx': 'shellx', 'psblockx': 'powershellx'}
    cs_verbs = {csmap.get(v, v) for v in cs_raw}
    check('P4: start 在 python 侧动词表里', 'start' in py_verbs, repr(sorted(py_verbs)))
    check('C#: start 在 ExecToolStep 里', 'start' in cs_raw, repr(sorted(cs_raw)))
    check('两侧动词集合**完全一致**(别名归一后; 不许单侧漂移)',
          py_verbs | py_blocks == cs_verbs,
          'py_only=%s cs_only=%s' % (sorted((py_verbs | py_blocks) - cs_verbs),
                                     sorted(cs_verbs - (py_verbs | py_blocks))))
    m = re.search(r'if \(v == "start"\) \{(.*?)\n            if \(v == ', seg, re.S)
    sbody = m.group(1) if m else ''
    check('C# start 分支存在且可定位', bool(sbody))
    check('C# start **不等**子进程(分支里没有 WaitForExit 调用; 注释里出现不算)',
          'Process.Start' in sbody and '.WaitForExit(' not in sbody, repr(sbody[-160:]))
    check('C# start 藏窗口(UseShellExecute=false + CreateNoWindow=true)',
          'UseShellExecute = false' in sbody and 'CreateNoWindow = true' in sbody)
    check('C# start 缺参也记失败(不静默成功)', 'missing program name' in sbody)
    check('C# start 报错带程序名(与 python 侧一致)', 'spi.FileName' in sbody)

    # ---------------- 7) 文档跟上 ----------------
    spec_txt = open(SPEC, encoding='utf-8', errors='replace').read()
    check('规范文档里有 start 动词(含"不等"的说明)',
          re.search(r'`start`', spec_txt) is not None and '不等' in spec_txt)

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


def main():
    tmp = tempfile.mkdtemp(prefix='wg-dsl-')
    try:
        return body(tmp)
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
