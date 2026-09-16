# -*- coding: utf-8 -*-
"""dot.py — 鼠标旁的「输入法状态提示点」(第六十九轮, python 独有).

**为什么需要**: `hideidle = 1`(默认) 时空闲不显示候选条, 用户**看不出输入法是开还是关** ——
第五十七轮的真实抱怨("托盘图标都不会变了 / 混合的模式切换不过去")就是这么来的: 空闲隐藏下,
候选条不显示、托盘图标还可能被 Windows 收进 `^`, 于是"切模式"没有任何可见反馈。
这里在鼠标旁画一个 12px 的小圆点, 颜色 = 当前状态, 一眼可辨。

**实现要点**(与 `bar.py` 同一套 tk 浮层做法 + 三条 Win32 样式, 见 `win.set_overlay_styles`):
  - `overrideredirect` + `-topmost` + `-transparentcolor`: 无边框 / 置顶 / 四角真透明;
  - `WS_EX_NOACTIVATE`   —— **永不抢焦点**(否则会从输入框里把焦点夺走);
  - `WS_EX_TOOLWINDOW`   —— 不进任务栏 / 不进 Alt-Tab;
  - `WS_EX_LAYERED|WS_EX_TRANSPARENT` —— **鼠标穿透**(否则 12px 也会挡住光标附近的点击);
  - 位置**跟鼠标**(`win.cursor_pos`), 由 `main._dot_tick()` 每 ~32ms 摆一次。

参考实现: `harold-lu-bit/IMEDot`(Ubuntu + PyQt6 的"置顶小圆点" —— 形态借它的)。**但要注意它跟的
也是鼠标**: Linux 上没有统一可查的文本 caret API(要 AT-SPI, 多数应用不实现), 所以"轮询 + 置顶小窗"
那条免注册路线在桌面上真正能落地的形态就是"跟鼠标"。我们候选条的"跟随光标"已按用户决定冻结
(AGENTS §17 / §D10), **状态点跟鼠标不受那条约束**: 它不承载内容, 只是状态灯, 没有"离正文太远"的问题。
"""

import tkinter as tk

import win

DOT = 12                   # 圆点直径 (px)
GAP_X, GAP_Y = 12, -18     # 相对鼠标的偏移 (右上方, 避开点击位置)
KEY = '#010203'            # -transparentcolor 的键色 (任何状态色都不用它)

# 状态色 (深色背景下都够亮, 且互相好区分)
C_OFF = '#6B6B6B'          # 输入法未激活 = 灰
C_REC = '#FF3B30'          # 录音中 = 红
MODES = {0: '#FF9F0A',     # 混合 = 橙
         1: '#0A84FF',     # 拼音 = 蓝
         2: '#BF5AF2',     # 五笔 = 紫
         3: '#40C8E0',     # 词典 = 青
         4: '#30D158'}     # 语音 = 绿


def dot_color(active, mode, recording=False):
    """圆点颜色 (传 None 给 `Dot.update` 即隐藏 → 这里永不返回 None).

    **未激活时仍然显示灰点**(而不是隐藏): 用户要的就是"看得出开没开" —— 有灰点才能区分
    "关着" vs "程序没跑/提示点被关了"。录音中优先显示红色 (那时模式色不重要)。
    """
    if recording:
        return C_REC
    if not active:
        return C_OFF
    return MODES.get(int(mode) % 5, C_OFF)


def dot_pos(cx, cy, work, size=DOT, gap=(GAP_X, GAP_Y)):
    """把圆点摆在鼠标右上方; 贴边就翻到另一侧, 最后整体钳进工作区.

    work = (left, top, right, bottom) —— 传 `win.workarea_at(cx, cy)` 的四条边(多屏正确)。
    纯函数(不碰 Tk/Win32), 便于 headless 断言四边/多屏/DPI 缩放下的钳制。
    """
    x = cx + gap[0]
    y = cy + gap[1]
    if x + size > work[2]:                 # 右边放不下 -> 翻到鼠标左侧
        x = cx - gap[0] - size
    if y < work[1]:                        # 上面放不下 -> 翻到鼠标下方
        y = cy + 8
    x = max(work[0], min(x, work[2] - size))
    y = max(work[1], min(y, work[3] - size))
    return x, y


class Dot:
    """一个 12px 的置顶圆点 (不抢焦点 / 鼠标穿透 / 不进任务栏). 由 poll tick 驱动 `update()`.

    懒创建(见 `main._dot`): 配置关掉时**一个窗口都不建**。颜色/位置都没变时不做任何
    Win32 调用 —— 每 32ms 一次 tick 的开销就是一次 `GetCursorPos`。
    """

    def __init__(self, root):
        self.top = tk.Toplevel(root)
        self.top.overrideredirect(True)
        self.top.attributes('-topmost', True)
        self.top.attributes('-transparentcolor', KEY)
        self.top.configure(bg=KEY)
        self.cv = tk.Canvas(self.top, width=DOT, height=DOT, bg=KEY,
                            highlightthickness=0, bd=0)
        self.cv.pack()
        self._oval = self.cv.create_oval(0, 0, DOT - 1, DOT - 1, fill=MODES[0], outline='')
        self.top.withdraw()
        self._shown = False
        self._styles_done = False
        self._color = None
        self._xy = None

    # ------------------------------------------------------------------
    def hwnd(self):
        return self.top.winfo_id()

    def _apply_styles(self):
        """改 Win32 扩展样式 (noactivate/toolwindow/穿透) + 置顶. 失败只记日志, 不影响输入法."""
        if self._styles_done:
            return
        try:
            self.top.update_idletasks()          # 先让 Tk 真把窗口建出来, 再拿 hwnd 改样式
            if win.set_overlay_styles(self.hwnd()):
                self._styles_done = True
            # 置顶必须用 SetWindowPos —— WS_EX_TOPMOST 是只读位, SetWindowLong 设不上(探针实测)。
            # 同一招 bar.py 用来压 Win11 开始菜单那类 Shell 层。
            win.set_topmost(self.hwnd())
        except Exception:
            pass

    def update(self, x, y, color):
        """摆到 (x, y) 并按 color 上色 (颜色变了才重画, 位置变了才 move)."""
        if not self._styles_done:
            self._apply_styles()
        if color != self._color:
            self.cv.itemconfigure(self._oval, fill=color)
            self._color = color
        if (x, y) != self._xy:
            self.top.geometry('+%d+%d' % (int(x), int(y)))
            self._xy = (x, y)
        if not self._shown:
            self.top.deiconify()
            self._shown = True
            self._apply_styles()                 # deiconify 后再保险一次 (见 §17 托盘句柄时序那类坑)

    def hide(self):
        if self._shown:
            self.top.withdraw()
            self._shown = False

    def is_shown(self):
        return self._shown

    def destroy(self):
        try:
            self.top.destroy()
        except Exception:
            pass
        self._shown = False
