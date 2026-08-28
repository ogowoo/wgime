# -*- coding: utf-8 -*-
"""计算器插件: 安全表达式求值 (设计规范: 圆角 + 白卡显示区 + 磁贴网格)."""
import re
import tkinter as tk

import ui

CODE = 'js'
NAME = '计算器'
DESC = '安全表达式计算器'

SAFE = re.compile(r'^[\d+\-*/().% ]+$')


def _eval(expr):
    if not SAFE.match(expr):
        return '仅支持数字+(),%'
    try:
        return str(eval(expr.replace('%', '/100'), {'__builtins__': {}}, {}))
    except Exception:
        return '错误'


def run():
    win, content = ui.make_window('WgIme 计算器', 264, 356)
    disp = tk.Label(content, text='', anchor='e', bg=ui.CARD, fg=ui.TEXT, font=ui.font(18),
                    padx=10)
    disp.place(x=10, y=10, width=244, height=44)
    disp.configure(highlightthickness=1, highlightbackground=ui.BORDER)

    state = {'expr': ''}

    def press(t):
        state['expr'] += t
        disp.config(text=state['expr'])

    def clear():
        state['expr'] = ''
        disp.config(text='')

    def calc():
        r = _eval(state['expr'])
        disp.config(text=r)
        state['expr'] = '' if r in ('错误', '仅支持数字+(),%') else r

    keys = [('(', ')', '%', 'C'),
            ('7', '8', '9', '/'),
            ('4', '5', '6', '*'),
            ('1', '2', '3', '-'),
            ('0', '.', '=', '+')]
    bw = 56
    bh = 46
    x0, y0 = 10, 62
    for r, row in enumerate(keys):
        for c, k in enumerate(row):
            if k == 'C':
                cmd = clear
            elif k == '=':
                cmd = calc
            else:
                cmd = (lambda t=k: press(t))
            primary = (k == '=')
            ui.flat_button(content, k, cmd, primary=primary,
                           x=x0 + c * (bw + 6), y=y0 + r * (bh + 6), w=bw, h=bh)
    win.bind('<Return>', lambda e: calc())
    win.bind('<BackSpace>', lambda e: (state.__setitem__('expr', state['expr'][:-1]), disp.config(text=state['expr'])))
