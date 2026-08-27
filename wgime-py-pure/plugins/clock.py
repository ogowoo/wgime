# -*- coding: utf-8 -*-
"""时钟插件: 置顶时钟."""
import datetime
import tkinter as tk

CODE = 'sk'
NAME = '时钟'
DESC = '置顶时钟'


def run():
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('时钟')
    win.attributes('-topmost', True)
    win.geometry('220x120')
    lbl = tk.Label(win, font=('Consolas', 34, 'bold'), fg='#007AFF')
    lbl.pack(expand=True)
    date = tk.Label(win, font=('Microsoft YaHei UI', 9), fg='#666')
    date.pack(expand=True)

    def tick():
        now = datetime.datetime.now()
        lbl.config(text=now.strftime('%H:%M:%S'))
        date.config(text=now.strftime('%Y-%m-%d %A'))
        win.after(1000, tick)

    tick()
