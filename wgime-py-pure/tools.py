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


# ---------- 插件管理 ----------
def show_makeword(data_dir, engine, prefill=''):
    """造词对话框: 词语 + 编码 (留空自动推导), 确认造词."""
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('造词')
    win.attributes('-topmost', True)
    win.geometry('360x190')
    win.configure(bg='#F4F7FB')
    tk.Label(win, text='词语 (2-8 字)', bg='#F4F7FB').pack(anchor='w', padx=10, pady=(10, 0))
    wentry = tk.Entry(win, font=('Microsoft YaHei UI', 12))
    wentry.pack(fill='x', padx=10, pady=4)
    wentry.insert(0, prefill)
    tk.Label(win, text='编码 (留空自动推导)', bg='#F4F7FB').pack(anchor='w', padx=10)
    centry = tk.Entry(win, font=('Consolas', 11))
    centry.pack(fill='x', padx=10, pady=4)
    status = tk.Label(win, text='', bg='#F4F7FB', fg='#666')
    status.pack(anchor='w', padx=10)

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
            status.config(text='词语需 2-8 字')
            return
        if not c:
            c = engine.code_for(w)
        if not c:
            status.config(text='无法推导编码')
            return
        if engine.add_user_word(w, c):
            status.config(text='已造词: %s (%s)' % (w, c), fg='#1a8f3c')
            win.after(900, win.destroy)
        else:
            status.config(text='已存在: %s' % w, fg='#c0392b')
    btnrow = tk.Frame(win, bg='#F4F7FB')
    btnrow.pack(pady=6)
    tk.Button(btnrow, text='造词', command=do_make, width=8).pack(side='left', padx=4)
    tk.Button(btnrow, text='取消', command=win.destroy, width=8).pack(side='left', padx=4)
    wentry.focus_set()


def show_plugin_mgr(plugins, data_dir, reload_fn):
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('插件管理')
    win.attributes('-topmost', True)
    win.geometry('400x320')
    frame = tk.Frame(win)
    frame.pack(fill='both', expand=True, padx=8, pady=8)
    vars_ = []
    try:
        disabled = set(l.strip() for l in open(os.path.join(data_dir, 'plugins-disabled.txt'), encoding='utf-8') if l.strip())
    except OSError:
        disabled = set()
    for m in plugins:
        code = getattr(m, 'CODE', '?')
        name = getattr(m, 'NAME', code)
        v = tk.BooleanVar(value=(code not in disabled))
        cb = tk.Checkbutton(frame, text='%s (%s)  %s' % (name, code, getattr(m, 'DESC', '')), variable=v, anchor='w')
        cb.pack(fill='x')
        vars_.append((code, v))
    btnrow = tk.Frame(win)
    btnrow.pack(fill='x', padx=8, pady=8)

    def apply():
        dis = set(code for code, v in vars_ if not v.get())
        try:
            open(os.path.join(data_dir, 'plugins-disabled.txt'), 'w', encoding='utf-8').write('\n'.join(sorted(dis)))
        except OSError:
            pass
        reload_fn()
        messagebox.showinfo('插件管理', '已应用并重载')
    tk.Button(btnrow, text='应用', command=apply).pack(side='left', padx=4)
