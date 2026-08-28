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

    def show(self, header, code, cands, sel, page=0, total=1, follow=True, fixed=None):
        t = THEMES[self.theme]
        c = self.canvas
        c.delete('all')
        # 候选显示截断: 超长词(整句/长词)截断 + 省略号, 避免候选条无限宽
        wa = win.screen_workarea()
        # 候选条最大宽度: 不铺满屏, 封顶 min(屏幕宽-24, 880px); ≥240
        max_w = max(240, min((wa.right - wa.left) - 24, 880))
        def clip(s, n):
            return s if len(s) <= n else s[:n] + '…'
        line1 = self._pad + self._fc.measure(header) + self._fc.measure(code)
        page_ind = '◀ %d/%d ▶' % (page + 1, total) if total > 1 else ''
        ind_w = self._fc.measure(page_ind) if page_ind else 0
        # 动态收紧候选截断: 候选总宽超 max_w 时, 逐步缩短每个候选(24→8), 直到候选条不铺满屏,
        # 且每个候选仍可见(都剪短, 数字键/翻页可选); 到最小仍超则窗口封顶 max_w 自动裁
        cands = list(cands or [])
        clipped = cands
        line2 = self._pad
        for n in range(24, 7, -2):
            clipped = [clip(x, n) for x in cands]
            line2 = self._pad
            for i2, cnd in enumerate(clipped):
                line2 += self._fd.measure('%d.%s' % (i2 + 1, cnd)) + 16
            if line2 <= max_w or n <= 8:
                break
        cands = clipped
        w = max(line1 + ind_w + 18, line2 + self._pad, 120)
        w = min(w, max_w)                              # 钳制到候选条最大宽度, 不再无限长
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
        # 定位: 固定位置(fixed) > 跟随光标(多屏钳制) > 开始菜单/搜索 Shell 固定右下角 > 拖动保持
        _shell = win.foreground_process_name() in ('startmenuexperiencehost', 'searchhost', 'shellexperiencehost')
        if isinstance(fixed, (tuple, list)):
            self.top.geometry('%dx%d+%d+%d' % (w, h, fixed[0], fixed[1]))
        elif fixed == 'bottom-right':
            ra = win.screen_workarea()
            self.top.geometry('%dx%d+%d+%d' % (w, h, ra.right - w - 16, ra.bottom - h - 8))
        elif fixed == 'bottom-center':
            ra = win.screen_workarea()
            self.top.geometry('%dx%d+%d+%d' % (w, h, ra.left + (ra.right - ra.left - w) // 2, ra.bottom - h - 8))
        elif follow and not _shell:
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
        elif _shell:
            # 开始菜单/搜索类 UI: 固定屏幕右下角并贴着任务栏上方(避开浮窗, 不遮挡中央)
            ra = win.screen_workarea()
            self.top.geometry('%dx%d+%d+%d' % (w, h, ra.right - w - 16, ra.bottom - h - 8))
        else:
            # 固定模式(用户可拖动): 保持当前位置, 但候选变宽/高时 clamp 到工作区, 避免超屏看不到
            ra = win.screen_workarea()
            cx, cy = self.top.winfo_x(), self.top.winfo_y()
            if not cx and not cy:
                cx, cy = ra.left + (ra.right - ra.left - w) // 2, ra.bottom - h - 40
            if cx + w > ra.right:
                cx = ra.right - w
            if cx < ra.left:
                cx = ra.left
            if cy + h > ra.bottom:
                cy = ra.bottom - h
            if cy < ra.top:
                cy = ra.top
            self.top.geometry('%dx%d+%d+%d' % (w, h, cx, cy))
        self.top.deiconify()
        win.set_topmost(self.top.winfo_id())   # 强制提到 topmost z-order 最顶(Win11 开始菜单不压住候选框)

    def _drag_start(self, e):
        self._drag['x'] = e.x_root - self.top.winfo_x()
        self._drag['y'] = e.y_root - self.top.winfo_y()

    def _drag_move(self, e):
        self.top.geometry('+%d+%d' % (e.x_root - self._drag['x'], e.y_root - self._drag['y']))

    def hide(self):
        self.top.withdraw()
