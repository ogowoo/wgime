# -*- coding: utf-8 -*-
"""tools.py — 纯 tkinter 内置工具窗体, 遵循 docs/WGIME_窗体设计语言.md (浅蓝灰底+白卡片+深色控制台+圆角)."""
import os
import threading
import time
import tkinter as tk
from tkinter import messagebox

import plugins as plugmod
import win as w32
import ui


def _bg(fn):
    threading.Thread(target=fn, daemon=True).start()


def _msgbox(title, text):
    messagebox.showinfo(title, text)


def _confirm(text):
    return messagebox.askyesno('确认', text)


# ---------- 工具箱 (tools.txt tab/按钮 -> 步骤 DSL; 自绘标签页) ----------
def show_toolbox(tools, dict_dir):
    if not tools:
        _msgbox('工具箱', 'tools.txt 无内容')
        return
    win, content = ui.make_window('WgIme 工具箱', 520, 420)
    W, H = 520, 420
    tabbar = tk.Frame(content, bg=ui.BG)
    tabbar.place(x=10, y=8, width=W - 20, height=34)
    body = tk.Frame(content, bg=ui.BG)
    body.place(x=10, y=48, width=W - 20, height=H - 48 - 14)
    pages = []
    tabbtns = []

    def show_tab(i):
        for j, p in enumerate(pages):
            p.place_forget()
        pages[i].place(x=0, y=0, width=W - 20, height=H - 62)
        for j, b in enumerate(tabbtns):
            b.configure(fg=ui.ACCENT if j == i else ui.SUB)

    for i, tab in enumerate(tools):
        tb = ui.flat_button(tabbar, tab['name'], (lambda i=i: show_tab(i)), x=i * 92, y=0, w=84, h=28)
        tabbtns.append(tb)
        page = tk.Frame(body, bg=ui.BG)
        cols = max(1, min(6, tab.get('cols', 2)))
        btns = tab['buttons']
        for bi, b in enumerate(btns):
            bw = (W - 20 - (cols - 1) * 8) // cols
            btn = ui.flat_button(page, b['name'], (lambda s='\n'.join(b['steps']): _run_tool_steps(s)),
                                 x=(bi % cols) * (bw + 8), y=(bi // cols) * 46, w=bw, h=38)
        pages.append(page)
    show_tab(0)


def _run_tool_steps(steps):
    try:
        fails = plugmod.run_steps(steps, lambda m: print('[tool]', m), _msgbox, _confirm)
        if fails:
            _msgbox('工具箱', '部分步骤失败 (%d)' % fails)
    except Exception as ex:
        _msgbox('工具箱', '失败: %s' % ex)


# ---------- 剪贴板历史 ----------
_CLIPT = []


def _clip_poll():
    last = None
    while True:
        time.sleep(1.0)
        try:
            t = w32.clipboard_text()
            if t and t != last:
                last = t
                if not _CLIPT or _CLIPT[0] != t:
                    _CLIPT.insert(0, t)
                    del _CLIPT[30:]
        except Exception:
            pass


def show_clipboard():
    _bg(_clip_poll)
    win, content = ui.make_window('WgIme 剪贴板历史', 420, 400)
    lst = tk.Listbox(content, font=ui.font(9.5), bg=ui.CARD, fg=ui.TEXT, bd=0,
                     highlightthickness=1, highlightbackground=ui.BORDER, selectbackground=ui.ACCENT)
    lst.place(x=10, y=10, width=400, height=320)

    def refresh():
        lst.delete(0, 'end')
        for t in _CLIPT:
            lst.insert('end', t.replace('\r', ' ').replace('\n', ' ')[:60])

    def copy():
        i = lst.curselection()
        if i and 0 <= i[0] < len(_CLIPT):
            win.clipboard_clear()
            win.clipboard_append(_CLIPT[i[0]])

    def paste():
        i = lst.curselection()
        if i and 0 <= i[0] < len(_CLIPT):
            win.clipboard_clear()
            win.clipboard_append(_CLIPT[i[0]])
            _bg(lambda: (time.sleep(0.12), w32.paste_text(_CLIPT[i[0]])))
    ui.flat_button(content, '复制选中', copy, x=10, y=342, w=90, h=30)
    ui.flat_button(content, '粘贴上屏', paste, primary=True, x=110, y=342, w=90, h=30)
    ui.flat_button(content, '刷新', refresh, x=210, y=342, w=70, h=30)
    refresh()


# ---------- 便签 ----------
def show_notes(data_dir):
    win, content = ui.make_window('WgIme 便签', 420, 320)
    path = os.path.join(data_dir, 'notes.txt')
    frame = tk.Frame(content, bg=ui.CARD, highlightthickness=1, highlightbackground=ui.BORDER)
    frame.place(x=10, y=10, width=400, height=270)
    tb = tk.Text(frame, font=ui.font(11), bg=ui.CARD, fg=ui.TEXT, bd=0, highlightthickness=0,
                 padx=8, pady=8, wrap='word')
    tb.pack(fill='both', expand=True)
    try:
        tb.insert('1.0', open(path, encoding='utf-8').read())
    except OSError:
        pass
    win.protocol('WM_DELETE_WINDOW', lambda: (_save(tb, path), win.destroy()))


def _save(tb, path):
    try:
        open(path, 'w', encoding='utf-8').write(tb.get('1.0', 'end'))
    except OSError:
        pass


# ---------- 取色器 ----------
def show_color():
    win, content = ui.make_window('WgIme 取色器', 220, 200)
    prev = tk.Frame(content, bg='#000')
    prev.place(x=10, y=10, width=200, height=120)
    lbl = tk.Label(content, text='', bg=ui.BG, fg=ui.TEXT, font=ui.font(12, bold=True))
    lbl.place(x=10, y=138, width=200, height=24)
    state = {'hex': '#000000'}

    def tick():
        x, y = w32.cursor_pos()
        if win.winfo_x() <= x <= win.winfo_x() + win.winfo_width() and win.winfo_y() <= y <= win.winfo_y() + win.winfo_height():
            return
        r, g, b = w32.get_pixel(x, y)
        state['hex'] = '#%02X%02X%02X' % (r, g, b)
        prev.configure(bg=state['hex'])
        lbl.config(text='%s  (%d,%d)' % (state['hex'], x, y))
        win.after(60, tick)

    def copy(_):
        win.clipboard_clear()
        win.clipboard_append(state['hex'])
        lbl.config(text='已复制 ' + state['hex'])
    prev.bind('<Button-1>', copy)
    lbl.bind('<Button-1>', copy)
    tick()


# ---------- 网络工具 ----------
def show_nettools():
    win, content = ui.make_window('WgIme 网络工具', 480, 360)
    W = 480
    H_OUT = 360 - 50 - 14
    host = ui.rounded_entry(content, x=10, y=10, w=240, h=32, initial='www.baidu.com')
    out = ui.console_text(content, x=10, y=50, w=W - 20, h=H_OUT)

    def run(cmd):
        out.insert('end', '> ' + cmd + '\n')
        out.see('end')
        _bg(lambda: _stream(cmd))

    def _stream(cmd):
        try:
            p = __import__('subprocess').Popen(cmd, shell=True, stdout=-1, stderr=-1, universal_newlines=True)
            for line in p.stdout:
                win.after(0, lambda l=line: (out.insert('end', l), out.see('end')))
            p.stdout.close()
            p.wait()
            win.after(0, lambda: out.insert('end', '-- done --\n'))
        except Exception as ex:
            win.after(0, lambda: out.insert('end', 'ERR %s\n' % ex))

    ui.flat_button(content, 'Ping', lambda: run('ping -n 4 ' + host.get()), primary=True, x=258, y=10, w=64, h=32)
    ui.flat_button(content, 'Tracert', lambda: run('tracert -d ' + host.get()), x=330, y=10, w=70, h=32)
    ui.flat_button(content, 'NSLookup', lambda: run('nslookup ' + host.get()), x=408, y=10, w=64, h=32)


# ---------- 造词对话框 ----------
def show_makeword(data_dir, engine, prefill=''):
    win, content = ui.make_window('WgIme 造词', 380, 200)
    tk.Label(content, text='词语 (2-8 字)', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5)).place(x=14, y=10)
    wentry = ui.rounded_entry(content, x=14, y=30, w=352, h=32, initial=prefill)
    tk.Label(content, text='编码 (留空自动推导)', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5)).place(x=14, y=68)
    centry = ui.rounded_entry(content, x=14, y=88, w=352, h=32)
    status = tk.Label(content, text='', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5))
    status.place(x=14, y=126)

    def autofill(*_a):
        if not centry.get().strip():
            c = engine.code_for(wentry.get().strip())
            if c:
                centry.delete(0, 'end')
                centry.insert(0, c)
    wentry.bind('<KeyRelease>', autofill)
    autofill()

    def do_make():
        w = wentry.get().strip()
        c = centry.get().strip()
        if not (2 <= len(w) <= 8):
            status.config(text='词语需 2-8 字', fg=ui.RED)
            return
        if not c:
            c = engine.code_for(w)
        if not c:
            status.config(text='无法推导编码', fg=ui.RED)
            return
        if engine.add_user_word(w, c):
            status.config(text='已造词: %s (%s)' % (w, c), fg=ui.GREEN)
            win.after(900, win.destroy)
        else:
            status.config(text='已存在: %s' % w, fg=ui.RED)
    ui.flat_button(content, '造词', do_make, primary=True, x=14, y=152, w=100, h=32)
    ui.flat_button(content, '取消', win.destroy, x=120, y=152, w=90, h=32)
    wentry.focus_set()


# ---------- 插件管理 ----------
def show_plugin_mgr(plugins, data_dir, reload_fn):
    win, content = ui.make_window('WgIme 插件管理', 400, 320)
    frame = tk.Frame(content, bg=ui.BG)
    frame.place(x=12, y=10, width=376, height=270)
    vars_ = []
    try:
        disabled = set(l.strip() for l in open(os.path.join(data_dir, 'plugins-disabled.txt'), encoding='utf-8') if l.strip())
    except OSError:
        disabled = set()
    for m in plugins:
        code = getattr(m, 'CODE', '?')
        name = getattr(m, 'NAME', code)
        v = tk.BooleanVar(value=(code not in disabled))
        cb = tk.Checkbutton(frame, text='%s (%s)  %s' % (name, code, getattr(m, 'DESC', '')), variable=v,
                            anchor='w', bg=ui.BG, fg=ui.TEXT, font=ui.font(9.5), activebackground=ui.BG)
        cb.pack(fill='x')
        vars_.append((code, v))

    def apply():
        dis = set(code for code, v in vars_ if not v.get())
        try:
            open(os.path.join(data_dir, 'plugins-disabled.txt'), 'w', encoding='utf-8').write('\n'.join(sorted(dis)))
        except OSError:
            pass
        reload_fn()
        _msgbox('插件管理', '已应用并重载')
    ui.flat_button(content, '应用', apply, primary=True, x=12, y=282, w=90, h=30)
