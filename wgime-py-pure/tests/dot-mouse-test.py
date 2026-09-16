# -*- coding: utf-8 -*-
r"""dot-mouse-test.py — 鼠标旁状态提示点 (`dot.py`) 的回归: 纯函数 + 真窗口的"别碍事"保证。

第六十九轮加了这个小圆点, 随后用户反馈"**好像影响到鼠标移动**"。实测查清了两件事, 本文件就钉它们:

  * **它不该抢事件**: 真窗口的 `WindowFromPoint(圆点中心)` 必须**返回底下的窗口**(= 鼠标事件穿透),
    而且圆点矩形**永远不能盖住光标本身**(否则点/拖都会磕到它);
  * **它不该是笔无谓的开销**: 外框样式一次写好、挪窗走 `win.move_topmost`(实测 0.68ms, 而
    `Tk.geometry()` 要 1.95ms), 光标没动就不碰窗口。

A 组是纯函数(不需要桌面); B 组要真建窗口 —— **拿不到 Tk/桌面就整组 SKIP**(退出码仍 0),
免得在没有交互会话的机器上误报红。

跑: python wgime-py-pure\tests\dot-mouse-test.py
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_MOD = os.path.dirname(_HERE)
if _MOD not in sys.path:
    sys.path.insert(0, _MOD)
import dot as dotmod                                # noqa: E402
import win                                          # noqa: E402

FAILS = []
N = [0]
SKIPPED = []


def ck(name, cond, extra=''):
    N[0] += 1
    if not cond:
        FAILS.append(name)
        print('  FAIL %s %s' % (name, extra))
    else:
        print('  ok   %s %s' % (name, extra))


print('A) 纯函数: 颜色 + 落点 (不需要桌面)')
ck('A1 未激活 = 灰', dotmod.dot_color(False, 0) == dotmod.C_OFF, dotmod.dot_color(False, 0))
ck('A2 录音中优先红', dotmod.dot_color(True, 2, recording=True) == dotmod.C_REC)
ck('A3 各模式颜色不同', len({dotmod.dot_color(True, m) for m in range(5)}) == 5)
ck('A4 模式取模不越界', dotmod.dot_color(True, 7) == dotmod.dot_color(True, 2))

WORK = (0, 0, 1920, 1080)
ck('A5 常规: 摆在鼠标右上方', dotmod.dot_pos(900, 500, WORK) == (912, 482),
   repr(dotmod.dot_pos(900, 500, WORK)))
x, y = dotmod.dot_pos(1915, 500, WORK)                    # 右边放不下 -> 翻到左侧
ck('A6 贴右边界 -> 翻到左侧', x + dotmod.DOT <= 1915, 'x=%d' % x)
x, y = dotmod.dot_pos(900, 2, WORK)                       # 上面放不下 -> 翻到下方
ck('A7 贴上边界 -> 翻到下方', y >= 2, 'y=%d' % y)
x, y = dotmod.dot_pos(-500, 500, (-1920, 0, 0, 1080))      # 左侧副屏
ck('A8 负坐标副屏也钳得进来', x >= -1920 and x + dotmod.DOT <= 0, 'x=%d' % x)
x, y = dotmod.dot_pos(100000, 100000, WORK)
ck('A9 离谱坐标被钳进工作区',
   WORK[0] <= x <= WORK[2] - dotmod.DOT and WORK[1] <= y <= WORK[3] - dotmod.DOT, '(%d,%d)' % (x, y))

worst = None
for wk in ((0, 0, 1920, 1080), (0, 0, 3840, 2160), (0, 0, 1366, 768), (0, 0, 800, 600),
           (-1920, -200, 0, 880)):
    for cx in range(wk[0], wk[2], 37):
        for cy in range(wk[1], wk[3], 41):
            px, py = dotmod.dot_pos(cx, cy, wk)
            if px <= cx < px + dotmod.DOT and py <= cy < py + dotmod.DOT:
                worst = (wk, cx, cy, px, py)
            if not (wk[0] <= px <= wk[2] - dotmod.DOT and wk[1] <= py <= wk[3] - dotmod.DOT):
                worst = ('超出工作区', wk, cx, cy, px, py)
ck('A10 遍历 5 种工作区 x 全部光标位置: 永远不盖住光标、也不越界', worst is None, repr(worst))

print('\nB) 真窗口: 样式 / 鼠标穿透 / 挪窗 (需要桌面, 拿不到就 SKIP)')
root = None
d = None
try:
    import tkinter as tk
    root = tk.Tk()
    root.withdraw()
    d = dotmod.Dot(root)
    p = win.cursor_pos()
    r = win.workarea_at(p[0], p[1])
    x, y = dotmod.dot_pos(p[0], p[1], (r.left, r.top, r.right, r.bottom))
    d.update(x, y, dotmod.dot_color(True, 0))
    root.update()
except Exception as ex:                                   # 没有交互桌面 / Tk 起不来
    SKIPPED.append('B 组(真窗口): %r' % (ex,))
    print('  SKIP 无法建窗口 (%r) —— 无桌面环境属正常' % (ex,))

if d is not None:
    u32 = ctypes.windll.user32
    u32.WindowFromPoint.restype = ctypes.c_void_p
    u32.WindowFromPoint.argtypes = [wt.POINT]
    u32.GetWindowRect.restype = wt.BOOL
    u32.GetWindowRect.argtypes = [ctypes.c_void_p, ctypes.POINTER(wt.RECT)]

    wid = d.top.winfo_id()
    hwnd = d.hwnd()
    ex = win.get_expanded_style(hwnd)
    ck('B1 样式写在**顶层外框**上 (TkChild 上等于没写, 见 §D11.1)',
       hwnd != wid and win.top_level_hwnd(wid) == hwnd)
    ck('B2 NOACTIVATE (不抢焦点)', bool(ex & 0x08000000), hex(ex))
    ck('B3 LAYERED|TRANSPARENT (鼠标穿透)', bool(ex & 0x00080000) and bool(ex & 0x00000020), hex(ex))
    ck('B4 TOOLWINDOW (不进任务栏/Alt-Tab)', bool(ex & 0x00000080), hex(ex))
    ck('B5 窗口已显示', d.is_shown() is True)

    rect = wt.RECT()
    u32.GetWindowRect(ctypes.c_void_p(hwnd), ctypes.byref(rect))
    ck('B6 落点与算出来的一致 (无 DPI 偏差)',
       (rect.left, rect.top) == (x, y), '实际(%d,%d) 期望(%d,%d)' % (rect.left, rect.top, x, y))
    ck('B7 圆点矩形不含光标',
       not (rect.left <= p[0] < rect.right and rect.top <= p[1] < rect.bottom),
       '圆点(%d,%d)-(%d,%d) 光标(%d,%d)' % (rect.left, rect.top, rect.right, rect.bottom, p[0], p[1]))

    cx, cy = (rect.left + rect.right) // 2, (rect.top + rect.bottom) // 2
    h = u32.WindowFromPoint(wt.POINT(cx, cy))
    h = int(h) if h else 0
    ck('B8 WindowFromPoint(圆点中心) **不是**圆点 -> 点击真的穿透',
       h != hwnd, 'hwnd=0x%08X 命中=0x%08X' % (hwnd, h))

    win.move_topmost(hwnd, 321, 234)
    root.update()
    rect2 = wt.RECT()
    u32.GetWindowRect(ctypes.c_void_p(hwnd), ctypes.byref(rect2))
    ck('B9 move_topmost 真的把窗口挪过去了',
       (rect2.left, rect2.top) == (321, 234), '(%d,%d)' % (rect2.left, rect2.top))
    ck('B10 挪窗后仍是穿透的 (样式没被重置)',
       int(u32.WindowFromPoint(wt.POINT(327, 240)) or 0) != hwnd)

    d.hide()
    ck('B11 hide() 之后不再显示', d.is_shown() is False)
    d.update(400, 300, dotmod.dot_color(False, 0))
    ck('B12 再 update 能显示回来', d.is_shown() is True)
    ck('B13 颜色跟着状态走', d.color() == dotmod.C_OFF, repr(d.color()))
    d.destroy()
    ck('B14 destroy 不抛', True)

if root is not None:
    try:
        root.destroy()
    except Exception:
        pass

print('\n%s' % ('ALL OK (%d 项)' % N[0] if not FAILS else 'FAILED %d/%d: %s' % (len(FAILS), N[0], FAILS)))
if SKIPPED:
    print('SKIP: %s' % '; '.join(SKIPPED))
sys.exit(1 if FAILS else 0)
