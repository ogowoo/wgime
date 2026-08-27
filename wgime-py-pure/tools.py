# -*- coding: utf-8 -*-
"""tools.py — 纯 tkinter 内置工具窗体: 工具箱/剪贴板历史/便签/取色器/网络工具."""
import os
import threading
import time
import tkinter as tk
from tkinter import messagebox

import plugins as plugmod
import win as w32


def _bg(fn):
    threading.Thread(target=fn, daemon=True).start()


def _msgbox(title, text):
    messagebox.showinfo(title, text)


def _confirm(text):
    return messagebox.askyesno('确认', text)


# ---------- 工具箱 (tools.txt tab/按钮 -> 步骤 DSL) ----------
def show_toolbox(tools, dict_dir):
    if not tools:
        messagebox.showinfo('工具箱', 'tools.txt 无内容')
        return
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('工具箱')
    win.attributes('-topmost', True)
    win.geometry('520x420')
    nb = ttk_Notebook(win)
    nb.pack(fill='both', expand=True)
    for tab in tools:
        frame = tk.Frame(nb)
        nb.add(frame, text=tab['name'])
        cols = tab.get('cols', 2)
        for i, b in enumerate(tab['buttons']):
            btn = tk.Button(frame, text=b['name'], width=18 if cols <= 2 else 9, height=2,
                            command=lambda s=('\n'.join(b['steps'])): _run_tool_steps(s))
            btn.grid(row=i // cols, column=i % cols, padx=4, pady=4, sticky='nsew')
        for r in range((len(tab['buttons']) + cols - 1) // cols):
            frame.rowconfigure(r, weight=1)
        for c in range(cols):
            frame.columnconfigure(c, weight=1)


def _run_tool_steps(steps):
    try:
        fails = plugmod.run_steps(steps, lambda m: print('[tool]', m), _msgbox, _confirm)
        if fails:
            messagebox.showinfo('工具箱', '部分步骤失败 (%d)' % fails)
    except Exception as ex:
        messagebox.showinfo('工具箱', '失败: %s' % ex)


def ttk_Notebook(parent):
    try:
        from tkinter import ttk
        return ttk.Notebook(parent)
    except Exception:
        return _SimpleTabs(parent)


class _SimpleTabs(tk.Frame):
    """ttk 不可用时的兜底 (极少见)."""

    def __init__(self, parent):
        super().__init__(parent)
        self._pages = []
        self._header = tk.Frame(self)
        self._header.pack(fill='x')
        self._body = tk.Frame(self)
        self._body.pack(fill='both', expand=True)

    def add(self, frame, text):
        self._pages.append((frame, text))
        frame.pack_forget()

    def refresh(self):
        for w in self._header.winfo_children():
            w.destroy()
        for i, (frame, text) in enumerate(self._pages):
            tk.Button(self._header, text=text, command=lambda f=frame, p=self._pages: self._show(f, p)).pack(side='left')

    def _show(self, frame, pages):
        for f, _ in pages:
            f.pack_forget()
        frame.pack(fill='both', expand=True)

    def pack(self, *a, **k):
        super().pack(*a, **k)
        self.after(50, self.refresh)


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
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('剪贴板历史')
    win.attributes('-topmost', True)
    win.geometry('420x400')
    lst = tk.Listbox(win, font=('Microsoft YaHei UI', 10))
    lst.pack(fill='both', expand=True)
    btnrow = tk.Frame(win)
    btnrow.pack(fill='x')

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
    tk.Button(btnrow, text='复制选中', command=copy).pack(side='left', padx=4, pady=4)
    tk.Button(btnrow, text='粘贴上屏', command=paste).pack(side='left', padx=4)
    tk.Button(btnrow, text='刷新', command=refresh).pack(side='left', padx=4)
    refresh()


# ---------- 便签 ----------
def show_notes(data_dir):
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('便签')
    win.attributes('-topmost', True)
    win.geometry('420x300')
    path = os.path.join(data_dir, 'notes.txt')
    tb = tk.Text(win, font=('Microsoft YaHei UI', 11))
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
    root = tk._default_root
    win = tk.Toplevel(root)
    win.overrideredirect(True)
    win.attributes('-topmost', True)
    win.geometry('200x200')
    lbl = tk.Label(win, text='', font=('Consolas', 12, 'bold'), bg='#000', fg='#fff')
    lbl.pack(fill='both', expand=True)
    state = {'hex': '#000000'}

    def tick():
        x, y = w32.cursor_pos()
        if win.winfo_x() <= x <= win.winfo_x() + win.winfo_width() and win.winfo_y() <= y <= win.winfo_y() + win.winfo_height():
            return
        r, g, b = w32.get_pixel(x, y)
        state['hex'] = '#%02X%02X%02X' % (r, g, b)
        win.configure(bg=state['hex'])
        lbl.config(text='%s (%d,%d)' % (state['hex'], x, y))
        win.after(60, tick)

    def click(_):
        win.clipboard_clear()
        win.clipboard_append(state['hex'])
        win.destroy()
    win.bind('<Button-1>', click)
    tick()


# ---------- 网络工具 ----------
def show_nettools():
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('网络工具')
    win.attributes('-topmost', True)
    win.geometry('460x340')
    tb = tk.Text(win, font=('Consolas', 9), bg='#2E3040', fg='#D6D9E2')
    tb.pack(fill='both', expand=True)
    top = tk.Frame(win)
    top.pack(fill='x')
    host = tk.Entry(top)
    host.insert(0, 'www.baidu.com')
    host.pack(side='left', fill='x', expand=True, padx=4, pady=4)

    def run(cmd):
        tb.insert('end', '> ' + cmd + '\n')
        tb.see('end')
        _bg(lambda: _stream(cmd, tb))

    def _stream(cmd, tb):
        try:
            p = __import__('subprocess').Popen(cmd, shell=True, stdout=-1, stderr=-1, universal_newlines=True)
            for line in p.stdout:
                win.after(0, lambda l=line: (tb.insert('end', l), tb.see('end')))
            p.stdout.close()
            p.wait()
            win.after(0, lambda: tb.insert('end', '-- done --\n'))
        except Exception as ex:
            win.after(0, lambda: tb.insert('end', 'ERR %s\n' % ex))
    tk.Button(top, text='Ping', command=lambda: run('ping -n 4 ' + host.get())).pack(side='left', padx=4)
    tk.Button(top, text='Tracert', command=lambda: run('tracert -d ' + host.get())).pack(side='left', padx=4)
    tk.Button(top, text='NSLookup', command=lambda: run('nslookup ' + host.get())).pack(side='left', padx=4)
