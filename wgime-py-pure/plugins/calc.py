# -*- coding: utf-8 -*-
"""计算器插件: 安全表达式求值 (仅数字/四则/括号/百分号)."""
import re
import tkinter as tk

CODE = 'js'
NAME = '计算器'
DESC = '安全表达式计算器'

SAFE = re.compile(r'^[\d+\-*/().% ]+$')


def _eval(expr):
    if not SAFE.match(expr):
        return '仅支持数字+(),%'
    try:
        # 百分号: a%b -> a/100*b ; 仅处理末尾简单情形
        e = expr.replace('%', '/100')
        return str(eval(e, {'__builtins__': {}}, {}))
    except Exception as ex:
        return '错误'


def run():
    root = tk._default_root
    win = tk.Toplevel(root)
    win.title('计算器')
    win.attributes('-topmost', True)
    win.geometry('260x300')
    disp = tk.Entry(win, font=('Consolas', 16), justify='right')
    disp.pack(fill='x', padx=8, pady=6)

    def press(t):
        disp.insert('end', t)

    def calc():
        try:
            disp.delete(0, 'end')
            disp.insert(0, _eval(disp.get()))
        except Exception:
            pass

    def clear():
        disp.delete(0, 'end')

    keys = [('(', ')', '%', 'C'),
            ('7', '8', '9', '/'),
            ('4', '5', '6', '*'),
            ('1', '2', '3', '-'),
            ('0', '.', '=', '+')]
    grid = tk.Frame(win)
    grid.pack(fill='both', expand=True, padx=8, pady=4)
    for r, row in enumerate(keys):
        for c, k in enumerate(row):
            cmd = clear if k == 'C' else (calc if k == '=' else (lambda t=k: press(t)))
            b = tk.Button(grid, text=k, command=cmd, height=2)
            b.grid(row=r, column=c, sticky='nsew', padx=2, pady=2)
            grid.rowconfigure(r, weight=1)
            grid.columnconfigure(c, weight=1)
    win.bind('<Return>', lambda e: calc())
