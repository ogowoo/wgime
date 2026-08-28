# -*- coding: utf-8 -*-
"""bar.py — tkinter 无边框置顶候选条 (真透明圆角 transparentcolor, 跟随光标, 分页指示, 双主题, 无边框)."""
import tkinter as tk
import tkinter.font as tkfont

import win

TRANSPARENT = '#010203'   # 透明关键色 (圆角四角透明)

# 双主题: dark = C# Morandi 深灰褐; light = 白底
THEMES = {
    'dark': dict(bg='#3B3836', text='#FFFFFF', sub='#B0ACA8', accent='#007AFF', alpha=0.88),
    'light': dict(bg='#FFFFFF', text='#1D1D1F', sub='#6E7485', accent='#007AFF', alpha=0.95),
}


class CandBar:
    def __init__(self, root):
        self.root = root
        self.theme = 'dark'
        self.top = tk.Toplevel(root)
        self.top.overrideredirect(True)
        self.top.attributes('-topmost', True)
        self.top.attributes('-toolwindow', True)
        self.top.configure(bg=TRANSPARENT)
        try:
            self.top.attributes('-transparentcolor', TRANSPARENT)   # 真透明圆角 (四角透明)
        except Exception:
            pass
        self.canvas = tk.Canvas(self.top, bg=TRANSPARENT, highlightthickness=0, bd=0)
        self.canvas.pack(fill='both', expand=True)
        self.canvas.bind('<ButtonPress-1>', self._drag_start)
        self.canvas.bind('<B1-Motion>', self._drag_move)
        self._drag = {'x': 0, 'y': 0}
        self._pad = 10
        self._fc = tkfont.Font(family='Microsoft YaHei UI', size=9)
        self._fd = tkfont.Font(family='Microsoft YaHei UI', size=11)

    def set_theme(self, name):
        if name in THEMES:
            self.theme = name
            self.top.attributes('-alpha', THEMES[name]['alpha'])

    def _round_rect(self, c, x1, y1, x2, y2, r, **kw):
        r = min(r, (x2 - x1) // 2, (y2 - y1) // 2)
        c.create_polygon([(x1 + r, y1), (x2 - r, y1), (x2, y1), (x2, y1 + r), (x2, y2 - r), (x2, y2),
                          (x2 - r, y2), (x1 + r, y2), (x1, y2), (x1, y2 - r), (x1, y1 + r), (x1, y1)],
                         smooth=True, **kw)

    def show(self, header, code, cands, sel, page=0, total=1, follow=True):
        t = THEMES[self.theme]
        c = self.canvas
        c.delete('all')
        # 候选显示截断: 超长词(整句/长词)截断 + 省略号, 避免候选条无限宽
        wa = win.screen_workarea()
        max_w = max(160, (wa.right - wa.left) - 24)   # 候选条最大宽度(留边距)
        def clip(s, n=24):
            return s if len(s) <= n else s[:n] + '…'
        cands = [clip(x) for x in cands]
        line1 = self._pad + self._fc.measure(header) + self._fc.measure(code)
        page_ind = '◀ %d/%d ▶' % (page + 1, total) if total > 1 else ''
        ind_w = self._fc.measure(page_ind) if page_ind else 0
        line2 = self._pad
        for i, cand in enumerate(cands):
            line2 += self._fd.measure('%d.%s' % (i + 1, cand)) + 16
        w = max(line1 + ind_w + 18, line2 + self._pad, 120)
        w = min(w, max_w)                              # 钳制到屏幕宽度, 不再无限长
        h = 54
        # 圆角底 (fill=主题底; 四角透明由 transparentcolor 提供)
        self._round_rect(c, 0, 0, w - 1, h - 1, 10, fill=t['bg'])
        # header + code (行1)
        y = 6
        x = self._pad
        c.create_text(x, y, anchor='nw', text=header, fill=t['accent'], font=self._fc)
        x += self._fc.measure(header)
        c.create_text(x, y, anchor='nw', text=code, fill=t['sub'], font=self._fc)
        if page_ind:
            c.create_text(w - self._pad, y, anchor='ne', text=page_ind, fill=t['sub'], font=self._fc)
        # candidates (行2)
        y = 26
        x = self._pad
        for i, cand in enumerate(cands):
            text = '%d.%s' % (i + 1, cand)
            tw = self._fd.measure(text)
            if i == sel:
                self._round_rect(c, x - 4, y, x + tw + 8, y + 26, 6, fill=t['accent'])
                c.create_text(x + 2, y + 13, anchor='w', text=text, fill='#FFFFFF', font=self._fd)
            else:
                c.create_text(x + 2, y + 13, anchor='w', text=text, fill=t['text'], font=self._fd)
            x += tw + 16
        # 定位: 跟随光标 (多屏: 按光标所在显示器钳制) 或 固定位置 (可拖动)
        if follow:
            pos = win.get_caret_pos()
            if pos:
                cx, cy = pos
                ra = win.workarea_at(cx, cy)
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
                ra = win.screen_workarea()
                self.top.geometry('%dx%d+%d+%d' % (w, h, ra.left + (ra.right - ra.left - w) // 2, ra.bottom - h - 40))
        else:
            self.top.geometry('%dx%d' % (w, h))
        self.top.deiconify()

    def _drag_start(self, e):
        self._drag['x'] = e.x_root - self.top.winfo_x()
        self._drag['y'] = e.y_root - self.top.winfo_y()

    def _drag_move(self, e):
        self.top.geometry('+%d+%d' % (e.x_root - self._drag['x'], e.y_root - self._drag['y']))

    def hide(self):
        self.top.withdraw()
