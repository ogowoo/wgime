# -*- coding: utf-8 -*-
"""语音"点击落点"的真实鼠标钩子回归 (第七十四轮; 无桌面则 SKIP).

只验钩子本身 (状态机那半边在 tests\\pure-state-harness.py 里):
  A 装上后 click_watch_active() 为真; 重复 start 返回 False;
  B 真发一次鼠标左键 -> 回调被调、且**自动收钩**;
  C **不吞这次点击**: 那一下要真的落到被点的窗口上 (本测试建了个 scratch 窗口接 <Button-1>);
  D stop 幂等。
为什么要这条: 这里踩过两个**静默**的 Win32 坑 —— `GetModuleHandleW` 的 restype 没设(64 位 HMODULE 被
截断成负数 -> 钩子根本装不上), 以及 `CallNextHookEx` 没声明 argtypes(64 位 LPARAM 溢出 ->
回调抛异常 -> **用户那一下点击丢掉**)。两个都不会报错、只表现为"点了没反应"。
安全: 先把光标挪到本测试自己的窗口上再点, 结束还原光标 —— 不会点到用户的界面。
跑法: python wgime-py-pure\\tests\\voice-click-test.py
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time
import tkinter as tk

PURE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # 本测试在 <pure>\tests\ 下
sys.path.insert(0, PURE)
import win  # noqa: E402

u32 = ctypes.windll.user32
fails, n = [], [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-52s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [('dx', wt.LONG), ('dy', wt.LONG), ('mouseData', wt.DWORD),
                ('dwFlags', wt.DWORD), ('time', wt.DWORD), ('dwExtraInfo', ctypes.c_void_p)]


class INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        _fields_ = [('mi', MOUSEINPUT)]
    _anonymous_ = ('u',)
    _fields_ = [('type', wt.DWORD), ('u', _U)]


def click(x, y):
    old = wt.POINT()
    u32.GetCursorPos(ctypes.byref(old))
    u32.SetCursorPos(int(x), int(y))
    time.sleep(0.15)
    arr = (INPUT * 2)()
    for i, flag in enumerate((0x0002, 0x0004)):          # LEFTDOWN / LEFTUP
        arr[i].type = 0
        arr[i].mi = MOUSEINPUT(0, 0, 0, flag, 0, None)
    u32.SendInput(2, ctypes.byref(arr), ctypes.sizeof(INPUT))
    return old.x, old.y


root = tk.Tk()
root.title('wgime click-watch probe')
root.geometry('260x120+80+80')
root.attributes('-topmost', True)
got = []
lbl = tk.Label(root, text='点我 (探针窗口)')
lbl.pack(expand=True, fill='both')
root.bind('<Button-1>', lambda e: got.append(1))
root.update()
time.sleep(0.4)
root.update()

print('--- A. 装钩 ---')
hit = []
check('起始未装', win.click_watch_active() is False)
win.click_watch_start(lambda: hit.append(1))
time.sleep(0.5)
check('装上后 active=True', win.click_watch_active() is True)
check('重复 start 返回 False (不重复装)', win.click_watch_start(lambda: None) is False)

print('--- B/C. 真点一下 (点探针自己的窗口) ---')
cx = root.winfo_rootx() + root.winfo_width() // 2
cy = root.winfo_rooty() + root.winfo_height() // 2
ox, oy = click(cx, cy)
t0 = time.monotonic()
while time.monotonic() - t0 < 1.5 and (not hit or not got):
    root.update()
    time.sleep(0.02)
check('回调被调用', bool(hit), repr(hit))
check('命中后自动收钩', win.click_watch_active() is False)
check('这次点击**没被吞** (探针窗口收到了 <Button-1>)', bool(got), repr(got))

print('--- D. stop 幂等 ---')
err = ''
try:
    win.click_watch_stop()
    win.click_watch_stop()
except Exception as e:
    err = repr(e)
check('未装/重复 stop 不抛', err == '', err)

u32.SetCursorPos(ox, oy)                                  # 还原光标
root.destroy()
print('')
if fails:
    print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
    sys.exit(1)
print('全部通过 (%d 项)' % n[0])
