# -*- coding: utf-8 -*-
"""时钟插件: 置顶时钟 (设计规范: 圆角无边框 + 大数字)."""
import datetime
import tkinter as tk

import ui

CODE = 'sk'
NAME = '时钟'
DESC = '置顶时钟'


def run():
    win, content = ui.make_window('WgIme 时钟', 240, 130)
    lbl = tk.Label(content, font=ui.font(34, bold=True), fg=ui.ACCENT, bg=ui.BG, anchor='center')
    lbl.place(x=0, y=34, width=240, height=52)
    date = tk.Label(content, font=ui.font(9), fg=ui.SUB, bg=ui.BG, anchor='center')
    date.place(x=0, y=88, width=240, height=24)

    def tick():
        now = datetime.datetime.now()
        lbl.config(text=now.strftime('%H:%M:%S'))
        date.config(text=now.strftime('%Y-%m-%d  %A'))
        win.after(1000, tick)
    tick()
