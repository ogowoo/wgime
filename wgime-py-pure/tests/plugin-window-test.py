# -*- coding: utf-8 -*-
r"""插件管理器「结束窗口」回归 (第八十三轮).

**为什么有这个东西**: 有些插件的窗口活在**独立进程**里 —— `plugins\wgtranslate.py` 的宿主入口
`run()` 会 `_start_detached_window()` 另起一个 python 进程建窗 (为了躲开 `[python]` 块的 60 秒超时),
宿主既没有它的句柄也不知道它的 pid, 用户以前只能去任务管理器里找。插件管理器现在有「结束窗口」:
按 **标题匹配 + 只认 python 进程** 找出属于该插件的窗口, 先 `WM_CLOSE`(= 点 ✕), 不退再 `TerminateProcess`。

**判据**:
  S 纯函数 (不依赖桌面): `plugin_window_match` 的三条线索 (文件名主干 / NAME / CODE) 命中与误伤;
    **短 CODE 只认完全相等** (`fy` 不许匹配 "My fy tool"); 空标题不匹配; `win.terminate_process` 拒绝自杀;
  A 真窗口·优雅路径 (要桌面): 起一个标题 `wgtranslate` 的 Tk 子进程 -> `plugin_windows` 找得到 (pid 对得上)
    -> `end_plugin_windows` 关掉它: `closed>=1`、`killed==0` (走 WM_CLOSE)、子进程退出、不留窗口;
  B 安全阀 (要桌面): 标题不相关的 python 窗口**不许**被认领, `end_plugin_windows` 之后那个子进程**还活着**;
  C 强杀路径 (要桌面): 一个 `WM_DELETE_WINDOW` 被写成"什么都不做"的窗口(点 ✕ 关不掉 —— 就是用户遇到的形态)
    -> `end_plugin_windows` 必须 `killed==1` 把它结束掉。

**安全**: 只认**本测试自己起的** pid; 开跑前若检测到用户已经开着的同插件窗口, A/B/C 整体 SKIP, 绝不动用户的窗口。
没桌面 (Tk 起不来) 时 A/B/C SKIP, 只跑 S, 退出码 0。
跑法: python wgime-py-pure\tests\plugin-window-test.py
"""
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
sys.path.insert(0, PURE)

import tools          # noqa: E402
import win            # noqa: E402

PLUGIN = os.path.join(PURE, 'plugins', 'wgtranslate.py')
META = dict(name='剪贴板翻译', code='fy', filename=PLUGIN)
PY = sys.executable

fails, n = [], [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def has_desktop():
    try:
        import tkinter
        r = tkinter.Tk()
        r.withdraw()
        r.destroy()
        return True
    except Exception:
        return False


def spawn_window(title, ignore_close=False):
    """起一个真 Tk 窗口的子进程; ignore_close=True 时把 WM_DELETE_WINDOW 写成"什么都不做"。"""
    code = ("import tkinter as tk\n"
            "r = tk.Tk()\n"
            "r.title(%r)\n"
            "r.geometry('220x120')\n"
            "%s"
            "r.after(120000, r.destroy)\n"
            "r.mainloop()\n" % (title, "r.protocol('WM_DELETE_WINDOW', lambda: None)\n" if ignore_close else ""))
    return subprocess.Popen([PY, '-c', code], stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_window(pid, timeout=10.0):
    """等这个 pid 的窗口被 plugin_windows 认领 (找到就返回那条 hit, 超时返回 None)."""
    end = time.time() + timeout
    while time.time() < end:
        for hit in tools.plugin_windows(META['name'], META['code'], META['filename']):
            if hit[1] == pid:
                return hit
        time.sleep(0.2)
    return None


def cleanup(*procs):
    for p in procs:
        try:
            p.kill()
        except Exception:
            pass


# ---------------- S: 纯函数 ----------------
print('--- S. plugin_window_match (纯函数) ---')
M = tools.plugin_window_match
check('文件名主干命中 (wgtranslate)', M('wgtranslate', '剪贴板翻译', 'fy', PLUGIN) is True)
check('标题里带主干也命中', M('wgtranslate 翻译窗口', '剪贴板翻译', 'fy', PLUGIN) is True)
check('NAME 命中 (中文标题)', M('剪贴板翻译', '剪贴板翻译', 'fy', PLUGIN) is True)
check('长 CODE 子串命中 (pdf)', M('PDF 工具', 'PDF 工具', 'pdf', r'C:\x\pdf.py') is True)
check('短 CODE 完全相等才认 (fy)', M('fy', '', 'fy', PLUGIN) is True)
check('短 CODE 不许子串误伤 (My fy tool)', M('My fy tool', '', 'fy', PLUGIN) is False)
check('空标题不匹配', M('', '剪贴板翻译', 'fy', PLUGIN) is False)
check('无关窗口不匹配 (Firefox)', M('Firefox', '时钟', 'clock', r'C:\x\clock.py') is False)
check('terminate_process 拒绝自杀 (本进程)', win.terminate_process(os.getpid()) is False)
check('terminate_process 拒绝非法 pid', win.terminate_process(0) is False)

# 安全阀本身用**打桩**测 (不依赖桌面/不真起进程): 标题一样但进程不是 python -> 不许认领
_real_enum, _real_exe = win.enum_top_windows, win.process_exe_name
try:
    win.enum_top_windows = lambda: [(111111, 4242, 'wgtranslate')]
    win.process_exe_name = lambda pid: 'notepad.exe'
    check('非 python 进程的同名窗口不被认领 (安全阀)',
          tools.plugin_windows(META['name'], META['code'], META['filename']) == [])
    win.process_exe_name = lambda pid: 'pythonw.exe'
    check('python 进程的同名窗口会被认领 (上面的对照)',
          len(tools.plugin_windows(META['name'], META['code'], META['filename'])) == 1)
finally:
    win.enum_top_windows, win.process_exe_name = _real_enum, _real_exe

# ---------------- A/B/C: 真窗口 ----------------
if not has_desktop():
    print('--- A/B/C 跳过: 没有桌面 (Tk 起不来) ---')
else:
    pre = tools.plugin_windows(META['name'], META['code'], META['filename'])
    if pre:
        print('--- A/B/C 跳过: 检测到你已经开着的该插件窗口 %s, 本测试不动用户的窗口 ---'
              % [h[1] for h in pre])
    else:
        print('--- A. 优雅路径: WM_CLOSE 就能关掉 ---')
        a = spawn_window('wgtranslate')
        hit = wait_window(a.pid)
        check('找得到这个插件窗口 (pid 对得上)', hit is not None, 'pid=%s' % a.pid)
        if hit:
            res = tools.end_plugin_windows(META['name'], META['code'], META['filename'], wait=2.0)
            check('end: found>=1', res['found'] >= 1, repr(res))
            check('end: 走的是 WM_CLOSE (killed == 0)', res['killed'] == 0, repr(res))
            check('end: closed >= 1', res['closed'] >= 1, repr(res))
            gone = False
            for _ in range(30):
                if a.poll() is not None:
                    gone = True
                    break
                time.sleep(0.2)
            check('子进程真的退出了', gone, 'rc=%s' % a.poll())
            left = [h for h in tools.plugin_windows(META['name'], META['code'], META['filename'])
                    if h[1] == a.pid]
            check('不留残留窗口', not left, repr(left))
        cleanup(a)

        print('--- B. 安全阀: 不相关的窗口不许被认领/被杀 ---')
        b = spawn_window('WgIme 不相关测试窗')
        time.sleep(3)
        hits_b = [h for h in tools.plugin_windows(META['name'], META['code'], META['filename'])
                  if h[1] == b.pid]
        check('无关标题不被认领', not hits_b, repr(hits_b))
        tools.end_plugin_windows(META['name'], META['code'], META['filename'], wait=0.4)
        time.sleep(0.5)
        check('无关子进程还活着', b.poll() is None, 'rc=%s' % b.poll())
        cleanup(b)

        print('--- C. 强杀路径: 点 ✕ 关不掉的窗口必须被 TerminateProcess ---')
        c = spawn_window('wgtranslate', ignore_close=True)
        hit_c = wait_window(c.pid)
        check('找得到这个(关不掉的)窗口', hit_c is not None, 'pid=%s' % c.pid)
        if hit_c:
            res = tools.end_plugin_windows(META['name'], META['code'], META['filename'], wait=0.8)
            check('end: killed == 1 (WM_CLOSE 无效 -> 强杀)', res['killed'] == 1, repr(res))
            gone = False
            for _ in range(30):
                if c.poll() is not None:
                    gone = True
                    break
                time.sleep(0.2)
            check('子进程被结束', gone, 'rc=%s' % c.poll())
        cleanup(c)

print('')
if fails:
    print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
    sys.exit(1)
print('全部通过 (%d 项)' % n[0])
