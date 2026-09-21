# -*- coding: utf-8 -*-
r"""翻译插件"关窗即退 / 独立运行不留孤儿"回归 (第八十三轮).

**用户报的"翻译那个插件无法结束进程"的真因**: `plugins\wgtranslate.py` 文件尾曾经把两个入口**并列**写成
两个 `if __name__ == '__main__':` —— 子窗口进程 (`--wgime-translate-window`) 关窗后 `mainloop()` 返回,
会**继续往下落到**双模式尾块, 于是 `_standalone.standalone(run, NAME)` → `run()` → `_start_detached_window()`
**又起一个新窗口**: 关一次回来一次, 永远关不掉 (还每次多一个隐藏 Tk root)。
实测 (探针 `%TEMP%\wg-r83-translate-probe.ps1`): 优雅关窗后新进程的 parent = 刚被关掉的那个 pid。

**判据**:
  S 结构 (不依赖桌面): 文件里 `__name__ == '__main__'` 只出现**一次**; 子窗口分支与双模式分支互斥;
    独立运行走进程内的 `_run_standalone` (而不是会另起进程的 `run`);
  A 子窗口路径 (要桌面): 起 `python wgtranslate.py --wgime-translate-window` → 优雅关窗 (`taskkill /PID`,
    **不带 /F** = WM_CLOSE, 与用户点 ✕ 同一条路) → 原进程必须消失, 且 **6 秒内不得出现新进程**;
  B 独立运行 (要桌面): `WGIME_STANDALONE_AUTOEXIT_MS=2500 python wgtranslate.py` → 进程自己退 (rc 0)、
    stdout 有 `STANDALONE-OK`、**不留孤儿窗口**。

**安全**: 只统计与清理**本测试自己起的**进程 (先记 before 集合), 用户已经开着的翻译窗口一律不碰。
没桌面 (Tk 起不来) 时 A/B 整体 SKIP, 只跑 S, 退出码 0。
跑法: python wgime-py-pure\tests\translate-window-test.py
"""
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
SCRIPT = os.path.join(PURE, 'plugins', 'wgtranslate.py')
CHILD_ARG = '--wgime-translate-window'
PY = sys.executable

fails, n = [], [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def proc_ids():
    """当前所有命令行里带 wgtranslate.py 的 python 进程 pid 集合 (用 PS/WMI, 拿得到命令行)。"""
    ps = ("Get-CimInstance Win32_Process -Filter \"Name like 'python%'\" | "
          "Where-Object { $_.CommandLine -and $_.CommandLine -match 'wgtranslate\\.py' } | "
          "Select-Object -ExpandProperty ProcessId")
    try:
        out = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', ps],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception:
        return set()
    return {int(x) for x in re.findall(r'\d+', out or '')}


def kill(pids):
    for pid in pids:
        subprocess.run(['taskkill', '/PID', str(pid), '/F'], capture_output=True)


def has_desktop():
    try:
        import tkinter
        r = tkinter.Tk()
        r.withdraw()
        r.destroy()
        return True
    except Exception:
        return False


# ---------------- S: 结构 (不依赖桌面, 用 AST 而不是正则: 注释/文档串里提到这行不算) ----------------
print('--- S. 入口结构 ---')
check('插件文件存在', os.path.exists(SCRIPT), SCRIPT)
src = open(SCRIPT, encoding='utf-8').read() if os.path.exists(SCRIPT) else ''
tree = None
try:
    import ast
    tree = ast.parse(src)
except Exception as ex:
    check('文件能被 ast 解析', False, repr(ex))


def _is_main_test(node):
    """`__name__ == '__main__'` —— 连同 `if __name__ == '__main__' and CHILD_ARG in sys.argv:` 这种
    BoolOp 守卫一起认出来 (修前那个 bug 的写法正是 BoolOp, 只看 Compare 会漏掉它)。"""
    return any(isinstance(x, ast.Compare) and isinstance(x.left, ast.Name) and x.left.id == '__name__'
               and any(isinstance(c, ast.Constant) and c.value == '__main__' for c in x.comparators)
               for x in ast.walk(node))


def _calls(node, name):
    return any(isinstance(x, ast.Call) and
               ((isinstance(x.func, ast.Name) and x.func.id == name) or
                (isinstance(x.func, ast.Attribute) and x.func.attr == name))
               for x in ast.walk(node))


if tree is not None:
    # 文件头那块 `if __name__ == '__main__':` 只修 sys.path (双模式约定第一条), 不算"入口分派";
    # 入口分派块 = 那个**调了** standalone()/ _window_main() 的顶层 __main__ 守卫。
    entries = [s for s in tree.body if isinstance(s, ast.If) and _is_main_test(s.test)
               and (_calls(s, 'standalone') or _calls(s, '_window_main'))]
    check("入口分派块只有一个 (子窗口与双模式互斥, 不 fall-through)", len(entries) == 1,
          'found %d 个 (并列两个 => 关窗后落到双模式尾块再起一个窗)' % len(entries))
    if len(entries) == 1:
        entry = entries[0]
        child = [s for s in entry.body if isinstance(s, ast.If) and 'CHILD_ARG' in ast.dump(s.test)]
        check('入口体内先判 CHILD_ARG 走子窗口', len(child) == 1 and _calls(child[0], '_window_main'),
              'body=%s' % [type(s).__name__ for s in entry.body])
        check('双模式尾块在 else 分支里 (不会 fall-through)',
              len(child) == 1 and any(_calls(s, 'standalone') for s in child[0].orelse),
              'orelse=%s' % ([type(s).__name__ for s in child[0].orelse] if child else 'no child branch'))
        check('独立运行走进程内的 _run_standalone (不是会另起进程的 run)',
              'standalone(_run_standalone, NAME)' in (ast.get_source_segment(src, entry) or ''))
    check('_run_standalone 建窗并返回窗口 (给 _standalone 看守)',
          re.search(r'def _run_standalone\(\):(.|\n)*?return root', src) is not None)


# ---------------- A/B: 真起进程 (要桌面) ----------------
if not has_desktop():
    print('--- A/B 跳过: 没有桌面 (Tk 起不来) ---')
else:
    before = proc_ids()
    print('--- A. 子窗口: 优雅关窗后不得重生 (before pids: %s) ---' % (sorted(before) or 'none'))
    p = subprocess.Popen([PY, SCRIPT, CHILD_ARG], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(4)
    alive = p.poll() is None
    check('子窗口进程起来了', alive, 'rc=%s (Tk 打不开?)' % (p.poll(),))
    mine = proc_ids() - before
    check('能按命令行找到这个窗口进程', bool(mine), '%s' % sorted(mine))

    if alive and mine:
        subprocess.run(['taskkill', '/PID', str(p.pid)], capture_output=True)   # 不带 /F = WM_CLOSE
        gone = False
        for _ in range(20):
            if p.poll() is not None:
                gone = True
                break
            time.sleep(0.25)
        check('优雅关窗后原进程退出', gone, 'pid=%s 还活着' % p.pid)
        leaked = set()
        for _ in range(24):                                  # 6 秒内不许冒出新进程
            leaked = proc_ids() - before - mine
            if leaked:
                break
            time.sleep(0.25)
        check('关窗后没有新进程 (不再是"关一次回来一次")', not leaked, 'respawned=%s' % sorted(leaked))
        kill(leaked | (proc_ids() - before))

    print('--- B. 独立运行: AUTOEXIT 到点自己退, 不留孤儿 ---')
    out = os.path.join(tempfile.gettempdir(), 'wg-translate-standalone.out')
    env = dict(os.environ, WGIME_STANDALONE_AUTOEXIT_MS='2500')
    with open(out, 'wb') as fo, open(out + '.err', 'wb') as fe:
        q = subprocess.Popen([PY, SCRIPT], stdout=fo, stderr=fe, stdin=subprocess.DEVNULL, env=env)
        try:
            rc = q.wait(timeout=40)
        except subprocess.TimeoutExpired:
            q.kill()
            rc = None
    text = open(out, encoding='utf-8', errors='replace').read() if os.path.exists(out) else ''
    check('独立运行退出码 0', rc == 0, 'rc=%s' % rc)
    check('独立运行打印 STANDALONE-OK', 'STANDALONE-OK' in text, repr(text[:80]))
    time.sleep(4)
    orphan = proc_ids() - before
    check('独立运行不留孤儿窗口', not orphan, 'orphan=%s' % sorted(orphan))
    kill(orphan)

print('')
if fails:
    print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
    sys.exit(1)
print('全部通过 (%d 项)' % n[0])
