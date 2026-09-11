# -*- coding: utf-8 -*-
"""计算器插件 (1:1 对齐 C# 插件 plugins/calc.txt).

求值**不是** eval —— C# 用的是自己写的递归下降解析器 (`Calc`, calc.txt 79-106 行), 语义要点别改:
- `%` 是**整数取余**(与 * / 同级), **不是百分号**: `10%3`=1、`7%2`=1、`100%7`=2、
  `50%`=Err(缺右操作数)、`2%0`=Err(除零)、`0.5%0.3`=Err(两个操作数都截成 0); `-5%3`=-2(python 的 `%` 是 1!)
- 先**去掉全部空格**, 再把 `×÷（）` 映射成 `* / ( )`
- 出错/除零/NaN/Inf/没吃完整串 一律显示 `Err`
- 结果格式: 整数值且 |v|<1e15 显示整数(`4/2`→`2`), 否则 `G10` 十位有效数字
  (`1/3`→`0.3333333333`、`22/7`→`3.142857143`、`1e15`→`1E+15`); 所以 `0.1+0.2` 显示 `0.3`,
  而不是 python repr 的 `0.30000000000000004`。**别改回 str(eval(...))**
键位也对齐 C#: 4x5 = `C <- ( )` / `7 8 9 /` / `4 5 6 *` / `1 2 3 -` / `0 . = +`
(C# 键位里**没有** `%` 键, `%` 靠键盘直输; 所以 python 也要绑键盘直输, 否则取余根本用不上)。
显示是两行: 小字 `表达式 =` + 大字(当前输入/结果/`Err`), 空串显示 `0`。
"""
import math
import tkinter as tk

import ui

CODE = 'jsq'                       # 对齐 C# 插件头部 `code = jsq`; `calc` 是它的别名 (见 main.find_launcher)
NAME = '计算器'
DESC = '迷你计算器: 四则/括号/取余, 全角符号兼容, 键盘直输回车求值'
VERSION = '1.0'
AUTHOR = 'ogowoo'
PERM = 'low'

_INF = float('inf')
_KEYS = '0123456789.+-*/%()'       # C# KeyPress 允许直输的字符


class _P(object):
    """解析游标 (对齐 C# `class P { internal string s; internal int i; }`)."""
    __slots__ = ('s', 'i')

    def __init__(self, s):
        self.s = s
        self.i = 0


def _to_long(v):
    """C# `(long)double`: 向零截断; NaN/Inf/越界抛异常 (对齐 .NET OverflowException -> Err)."""
    if v != v or v == _INF or v == -_INF or abs(v) >= 2 ** 63:
        raise ValueError('cast')
    return int(v)


def _cs_mod(a, b):
    """C# `long % long`: 余数符号跟**被除数** —— python 的 `%` 跟除数, 不能直接用 `a % b`."""
    if b == 0:
        raise ZeroDivisionError('mod')
    q = abs(a) // abs(b)
    if (a < 0) != (b < 0):
        q = -q
    return a - q * b


def _fac(p):
    while p.i < len(p.s) and p.s[p.i] == ' ':
        p.i += 1
    if p.i >= len(p.s):
        raise ValueError('eof')
    c = p.s[p.i]
    if c == '(':
        p.i += 1
        v = _expr(p)
        if p.i >= len(p.s) or p.s[p.i] != ')':
            raise ValueError('paren')
        p.i += 1
        return v
    if c == '-':
        p.i += 1
        return -_fac(p)
    if c == '+':
        p.i += 1
        return _fac(p)
    st = p.i
    while p.i < len(p.s) and (p.s[p.i].isdigit() or p.s[p.i] == '.'):
        p.i += 1
    if st == p.i:
        raise ValueError('num')
    tok = p.s[st:p.i]
    for ch in tok:
        if ch not in '0123456789.':
            raise ValueError('num')     # double.Parse(InvariantCulture) 不认非 ASCII 数字
    return float(tok)


def _term(p):
    v = _fac(p)
    while p.i < len(p.s):
        c = p.s[p.i]
        if c == '*':
            p.i += 1
            v *= _fac(p)
        elif c == '/':
            p.i += 1
            v /= _fac(p)
        elif c == '%':
            p.i += 1
            v = float(_cs_mod(_to_long(v), _to_long(_fac(p))))
        else:
            break
    return v


def _expr(p):
    v = _term(p)
    while p.i < len(p.s):
        c = p.s[p.i]
        if c == '+':
            p.i += 1
            v += _term(p)
        elif c == '-':
            p.i += 1
            v -= _term(p)
        else:
            break
    return v


def calc_value(s):
    """C# `Calc(string)`: 求值 -> 显示串 (失败一律 'Err'; 空串返回 '')."""
    s = (s or '').replace(' ', '').replace('×', '*').replace('÷', '/') \
                 .replace('（', '(').replace('）', ')')
    if len(s) == 0:
        return ''
    try:
        p = _P(s)
        v = _expr(p)
        if p.i != len(s) or v != v or v == _INF or v == -_INF:
            return 'Err'
        if v == math.floor(v) and abs(v) < 1e15:
            return str(_to_long(v))
        return '%.10G' % v
    except Exception:
        return 'Err'


def run():
    win, content = ui.make_window('WgIme 计算器', 264, 356)
    # 内容区坐标 = C# 客户区坐标 - 38 (ui.make_window 的标题栏固定 38 高, C# 那个自绘标题栏是 32):
    # 这样卡片/键位与 C# **绝对位置**一致 (卡片 C# 客户区 y=42, 键位 y=110..332)
    card = tk.Frame(content, bg=ui.CARD, highlightthickness=1, highlightbackground=ui.BORDER)
    card.place(x=12, y=4, width=240, height=58)
    lbl_expr = tk.Label(card, text='', anchor='e', bg=ui.CARD, fg=ui.SUB, font=ui.font(8))
    lbl_expr.place(x=10, y=5, width=220, height=16)
    lbl_main = tk.Label(card, text='0', anchor='e', bg=ui.CARD, fg=ui.TEXT, font=ui.font(17))
    lbl_main.place(x=10, y=20, width=220, height=34)

    state = {'expr': ''}

    def refresh():
        lbl_main.configure(text=state['expr'] if state['expr'] else '0')

    def evaluate():
        if not state['expr']:
            return
        r = calc_value(state['expr'])
        lbl_expr.configure(text=state['expr'] + ' =')
        if r == 'Err':
            state['expr'] = ''
            lbl_main.configure(text='Err')
        else:
            state['expr'] = r
            refresh()

    def press(cap):
        if cap == 'C':
            state['expr'] = ''
            lbl_expr.configure(text='')
        elif cap == '<-':
            state['expr'] = state['expr'][:-1]
        elif cap == '=':
            evaluate()
            return
        else:
            state['expr'] += cap
        refresh()
        try:
            win.focus_force()                  # 对齐 C# `b.Click += ... f.Focus();` (点完还能键盘直输)
        except Exception:
            pass

    caps = (('C', '<-', '(', ')'),
            ('7', '8', '9', '/'),
            ('4', '5', '6', '*'),
            ('1', '2', '3', '-'),
            ('0', '.', '=', '+'))
    ops = ('(', ')', '/', '*', '-', '+')
    for r, row in enumerate(caps):
        for c, cap in enumerate(row):
            b = ui.flat_button(content, cap, (lambda t=cap: press(t)), primary=(cap == '='),
                               x=12 + c * 62, y=72 + r * 46, w=54, h=38)
            if cap == 'C':
                b.configure(fg=ui.RED)         # C# `b.Fg = C_RED`
            elif cap in ops:
                b.configure(fg=ui.ACCENT)      # C# 给运算符磁贴换底色, python 设计系统用前景色表达

    def on_key(e):
        if e.char and e.char in _KEYS:          # 对齐 C# KeyPress: 只收这些字符
            state['expr'] += e.char
            refresh()

    win.bind('<Key>', on_key)
    win.bind('<Return>', lambda e: evaluate())
    win.bind('<BackSpace>', lambda e: press('<-'))

    def focus():
        try:
            win.focus_force()                   # C# 窗体会变 Active, 键盘直输立即可用
        except Exception:
            pass
    try:
        win.after(0, focus)
    except Exception:
        pass
