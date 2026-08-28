# -*- coding: utf-8 -*-
"""ui.py — 纯 Python 版的设计系统 (对齐 docs/WGIME_窗体设计语言.md):
浅蓝灰底 #E8EDF5 + 白卡片 + 深色控制台 + 圆角 (SetWindowRgn) + 自绘标题栏 + 显式坐标.
"""
import ctypes
import tkinter as tk

# 色板 (直接抄规范)
BG = '#E8EDF5'
HEADER = '#DCE3EF'
CARD = '#FFFFFF'
SURF2 = '#D9E0EC'
BORDER = '#C3CCDD'
TEXT = '#1D1D1F'
SUB = '#6E7485'
ACCENT = '#007AFF'
CONBG = '#2E3040'
CONFG = '#D6D9E2'
GREEN = '#34C759'
ORANGE = '#FF9500'
BLUE = '#30B0C7'
RED = '#FF375F'

FONT_NAMES = ['Segoe UI Variable Display', 'Segoe UI', 'Microsoft YaHei UI']


def font(size, bold=False, mono=False):
    if mono:
        return ('Consolas', int(size))
    for n in FONT_NAMES:
        try:
            return (n, int(round(size)), 'bold' if bold else 'normal')
        except Exception:
            continue
    return ('Microsoft YaHei UI', int(round(size)), 'bold' if bold else 'normal')


def _round_region(win, w, h):
    """GDI 原生 Rgn 圆角 (C# 同款, 角落无锯齿)."""
    try:
        hwnd = win.winfo_id()
        rgn = ctypes.windll.gdi32.CreateRoundRectRgn(0, 0, w + 1, h + 1, 20, 20)
        ctypes.windll.user32.SetWindowRgn(hwnd, rgn, True)
    except Exception:
        pass


def center(win, w, h):
    sw = win.winfo_screenwidth()
    sh = win.winfo_screenheight()
    win.geometry('%dx%d+%d+%d' % (w, h, (sw - w) // 2, (sh - h) // 2))


def make_window(title, w, h, on_close=None):
    """无边框圆角 + 自绘标题栏 + 显式坐标. 返回 (win, content_frame)."""
    win = tk.Toplevel(tk._default_root)
    win.overrideredirect(True)
    win.attributes('-topmost', True)
    win.configure(bg=BG)
    center(win, w, h)

    # 标题栏
    bar = tk.Frame(win, bg=HEADER, height=38)
    bar.place(x=0, y=0, width=w, height=38)
    tk.Label(bar, text=title, bg=HEADER, fg=TEXT, font=font(10, bold=True)).place(x=12, y=9)
    tk.Frame(bar, bg=BORDER, height=1).place(x=0, y=37, width=w, height=1)

    def close(_=None):
        if on_close:
            on_close()
        win.destroy()

    xbtn = tk.Label(bar, text='✕', bg=HEADER, fg=TEXT, font=font(11), cursor='hand2')
    xbtn.place(x=w - 34, y=7, width=26, height=24)
    xbtn.bind('<Button-1>', close)
    xbtn.bind('<Enter>', lambda e: xbtn.configure(bg=RED, fg='white'))
    xbtn.bind('<Leave>', lambda e: xbtn.configure(bg=HEADER, fg=TEXT))

    # 拖动
    drag = {'x': 0, 'y': 0}

    def start(e):
        drag['x'], drag['y'] = e.x_root - win.winfo_x(), e.y_root - win.winfo_y()

    def move(e):
        win.geometry('+%d+%d' % (e.x_root - drag['x'], e.y_root - drag['y']))
    bar.bind('<ButtonPress-1>', start)
    bar.bind('<B1-Motion>', move)

    # 内容区
    content = tk.Frame(win, bg=BG)
    content.place(x=0, y=38, width=w, height=h - 38)

    # 圆角 (映射后)
    win.update_idletasks()
    _round_region(win, w, h)
    win.bind('<Escape>', lambda e: close())
    win.configure(width=w, height=h)
    return win, content


def flat_button(parent, text, command, primary=False, x=0, y=0, w=90, h=32):
    """扁平按钮: 白卡, primary=accent 实心白字. hover 提亮/按下压暗."""
    bg = ACCENT if primary else CARD
    fg = 'white' if primary else TEXT
    btn = tk.Label(parent, text=text, bg=bg, fg=fg, font=font(9.5), cursor='hand2')
    btn.place(x=x, y=y, width=w, height=h)

    def center_text():
        btn.configure(anchor='center')
    center_text()

    def enter(_):
        btn.configure(bg='#2C92FF' if primary else SURF2)

    def leave(_):
        btn.configure(bg=bg)

    def press(_):
        btn.configure(bg='#0A6CDC' if primary else SURF2)

    def release(_):
        btn.configure(bg=bg)
        command()
    btn.bind('<Enter>', enter)
    btn.bind('<Leave>', leave)
    btn.bind('<ButtonPress-1>', press)
    btn.bind('<ButtonRelease-1>', release)
    return btn


def console_text(parent, x=0, y=0, w=400, h=200):
    """深色控制台 Text (Consolas, 深色底)."""
    tb = tk.Text(parent, font=font(9.5, mono=True), bg=CONBG, fg=CONFG,
                 bd=0, highlightthickness=0, wrap='none')
    tb.place(x=x, y=y, width=w, height=h)
    return tb


def rounded_entry(parent, x=0, y=0, w=200, h=32, initial=''):
    """圆角白底输入框 (Frame 容器 + 内嵌无边框 Entry)."""
    frame = tk.Frame(parent, bg=CARD, highlightthickness=1, highlightbackground=BORDER)
    frame.place(x=x, y=y, width=w, height=h)
    e = tk.Entry(frame, font=font(9.5), bg=CARD, fg=TEXT, bd=0, highlightthickness=0)
    e.place(x=9, y=4, width=w - 18, height=h - 8)
    if initial:
        e.insert(0, initial)
    return e
