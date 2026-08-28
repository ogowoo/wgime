# -*- coding: utf-8 -*-
"""bar.py — tkinter 无边框置顶候选条 (Canvas 自绘, 跟随光标, 分页指示)."""
import tkinter as tk
import tkinter.font as tkfont

import win

BG = '#FFFFFF'
BORDER = '#C3CCDD'
ACCENT = '#007AFF'
TEXT = '#1D1D1F'
SUB = '#6E7485'


class CandBar:
    def __init__(self, root):
        self.root = root
        self.top = tk.Toplevel(root)
        self.top.overrideredirect(True)
        self.top.attributes('-topmost', True)
        self.top.attributes('-toolwindow', True)
        self.canvas = tk.Canvas(self.top, bg=BG, highlightthickness=0, bd=0)
        self.canvas.pack(fill='both', expand=True)          # 铺满, 避免 Toplevel 灰底外露
        self.f_code = ('Microsoft YaHei UI', 9)
        self.f_cand = ('Microsoft YaHei UI', 11)
        self._pad = 10

    def _measure(self, text, font):
        return tkfont.Font(family=font[0], size=font[1]).measure(text)

    def show(self, header, code, cands, sel, page=0, total=1):
        c = self.canvas
        c.delete('all')
        line1 = self._pad + self._measure(header, self.f_code) + self._measure(code, self.f_code)
        page_ind = '◀ %d/%d ▶' % (page + 1, total) if total > 1 else ''
        ind_w = self._measure(page_ind, self.f_code) if page_ind else 0
        line2 = self._pad
        for i, cand in enumerate(cands):
            line2 += self._measure('%d.%s' % (i + 1, cand), self.f_cand) + 16
        w = max(line1 + ind_w + 18, line2, 120)
        h = 54
        # 圆角底
        self._round_rect(c, 0, 0, w - 1, h - 1, 10, fill=BG, outline=BORDER)
        # header + code (行1)
        y = 6
        x = self._pad
        c.create_text(x, y, anchor='nw', text=header, fill=ACCENT, font=self.f_code)
        x += self._measure(header, self.f_code)
        c.create_text(x, y, anchor='nw', text=code, fill=SUB, font=self.f_code)
        if page_ind:
            c.create_text(w - self._pad, y, anchor='ne', text=page_ind, fill=SUB, font=self.f_code)
        # candidates (行2)
        y = 26
        x = self._pad
        for i, cand in enumerate(cands):
            text = '%d.%s' % (i + 1, cand)
            tw = self._measure(text, self.f_cand)
            if i == sel:
                self._round_rect(c, x - 4, y, x + tw + 8, y + 26, 6, fill=ACCENT, outline=ACCENT)
                c.create_text(x + 2, y + 13, anchor='w', text=text, fill='#FFFFFF', font=self.f_cand)
            else:
                c.create_text(x + 2, y + 13, anchor='w', text=text, fill=TEXT, font=self.f_cand)
            x += tw + 16
        # 定位跟随光标 (钳制到屏幕内, 下方不够则翻到光标上方)
        ra = win.screen_workarea()
        pos = win.get_caret_pos()
        if pos:
            cx, cy = pos
            x = cx
            y = cy + 6
            if x + w > ra.right:
                x = ra.right - w
            if x < ra.left:
                x = ra.left
            if y + h > ra.bottom:
                y = cy - h - 6
            if y < ra.top:
                y = ra.top
            self.top.geometry('%dx%d+%d+%d' % (w, h, x, y))
        else:
            self.top.geometry('%dx%d+%d+%d' % (w, h, ra.left + (ra.right - ra.left - w) // 2, ra.bottom - h - 40))
        self.top.deiconify()

    def hide(self):
        self.top.withdraw()

    @staticmethod
    def _round_rect(c, x1, y1, x2, y2, r, **kw):
        r = min(r, (x2 - x1) // 2, (y2 - y1) // 2)
        c.create_polygon([(x1 + r, y1), (x2 - r, y1), (x2, y1), (x2, y1 + r), (x2, y2 - r), (x2, y2),
                          (x2 - r, y2), (x1 + r, y2), (x1, y2), (x1, y2 - r), (x1, y1 + r), (x1, y1)],
                         smooth=True, **kw)
