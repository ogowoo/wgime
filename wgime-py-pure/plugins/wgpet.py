# -*- coding: utf-8 -*-
"""wgpet.py — 桌面宠物 widget (全屏 / 鼠标穿透 / 不抢焦点), wgime-py 的双模式插件.

机制与实测见 AGENTS.md §5 规则 49 / AGENTS-DETAIL.md §D36。要点(别再退回 tkinter):
  * 自己 `CreateWindowExW` 且**创建时**就带 `WS_EX_NOACTIVATE` => 从第一帧起就不可能被激活。
    (Tk 的 Toplevel 建窗即 map, 激活已经发生; "先 withdraw 再 SW_SHOWNOACTIVATE"实测照样抢。)
  * `WS_EX_LAYERED` + `SetLayeredWindowAttributes(键色, LWA_COLORKEY)` = 键色真透明;
    `WS_EX_TRANSPARENT` = 整屏鼠标穿透; `WS_EX_TOOLWINDOW` = 不进任务栏/Alt-Tab。
  * 动画: 独立线程 + `timeBeginPeriod(1)` + `PostMessage(WM_APP_TICK)` + 主线程 `GetMessage`
    阻塞循环 => 实测 59.5fps(WM_TIMER+sleep 轮询只有 40fps, 是队列被饿住, 不是画不动)。
  * 只重画脏矩形; 每帧"铺键色 + 重画全部元素", 靠 BeginPaint 的裁剪区白拿裁剪。
  * 要你点工具时**只去掉 `WS_EX_TRANSPARENT`、保留 NOACTIVATE**: 画出来的地方点得到, 没画的地方
    (键色连命中测试也透明)仍穿透, 且**前台窗口全程不变** => 点工具不会丢输入框焦点。

挎包里的工具 = 你自己的 wgime 插件(`.py` 双模式 + `.txt` 步骤), **现读插件目录**(复用宿主
`plugins.py` 解析器), 点了就在**本进程后台线程**里跑 —— 不改宿主一行代码, 也不受 `[python]` 块
60s 超时管; 非 low 权限照 §16 先确认一次。

调起: 输入法打启动编码 `pet` + 空格; 或 `python wgpet.py` 独立运行。
呼出工具面板: 全局热键 **Ctrl+Alt+P**, 或直接点小狗。退出: 插件管理器「结束窗口」,
或再打一次 `pet`(第二个进程把开合消息转给已在跑的那个浮层)。
"""
import ctypes
import ctypes.wintypes as w
import json
import math
import os
import random
import sys
import threading
import time

# ---------------- manifest (§8.5 / §8.8) ----------------
CODE = 'pet'
NAME = '桌面宠物'
DESC = '全屏鼠标穿透挂件: 小狗驮着你的插件工具, 热键呼出工具面板, 点一下就叼出来用'
VERSION = '0.2.0'
AUTHOR = 'wgime'
PERM = 'low'                      # 只是画浮层 + 拉起你自己的工具; 工具自身的权限另算
STANDALONE = True                 # 双模式标记 (插件管理器显示"双模")

CHILD_ARG = '--wgime-pet-window'
WIN_TITLE = 'wgpet · 桌面宠物'     # 含文件名主干 wgpet => 插件管理器「结束窗口」认得出(§46)
DLL_NAME = 'wgpet.dll'            # Rust 浮层(第八十七轮)。有它就用它, 没有就退回下面这套 Python 实现
CLASS_NAME = 'WgImePetOverlayWnd'

# ---------------- Win32 常量 ----------------
GWL_EXSTYLE = -20
EX_LAYERED, EX_TRANSPARENT, EX_NOACTIVATE, EX_TOOLWINDOW, EX_TOPMOST = 0x80000, 0x20, 0x8000000, 0x80, 0x8
WS_POPUP = 0x80000000
SW_SHOWNOACTIVATE = 4
HWND_TOPMOST = -1
SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE, SWP_SHOWWINDOW = 0x1, 0x2, 0x10, 0x40
LWA_COLORKEY = 0x1
WM_PAINT, WM_DESTROY, WM_CLOSE, WM_ERASEBKGND, WM_QUIT = 0x000F, 0x0002, 0x0010, 0x0014, 0x0012
WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MOUSEMOVE = 0x0201, 0x0204, 0x0200
WM_HOTKEY = 0x0312
WM_APP_TICK, WM_APP_TOGGLE, WM_APP_ENTER, WM_APP_ACTIVITY, WM_APP_PAUSE = \
    0x8001, 0x8002, 0x8003, 0x8004, 0x8005
PM_REMOVE = 1
MOD_ALT, MOD_CONTROL, MOD_NOREPEAT = 0x1, 0x2, 0x4000
DT_CENTER, DT_VCENTER, DT_SINGLELINE = 0x1, 0x4, 0x20
TRANSPARENT_BK = 1
MB_OK, MB_OKCANCEL, MB_YESNO, MB_ICONWARNING, MB_TOPMOST, MB_SETFOREGROUND, MB_DEFBUTTON2 = \
    0x0, 0x1, 0x4, 0x30, 0x40000, 0x10000, 0x100
IDOK, IDYES = 1, 6
ERROR_ALREADY_EXISTS = 183

KEY_HEX = '#010203'                       # 键色: 精灵里绝不出现 (沿用 dot.py)
HOTKEY_ID, HOTKEY_VK = 0xB0B, 0x50        # Ctrl+Alt+P

user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
kernel32 = ctypes.windll.kernel32
winmm = ctypes.windll.winmm

# ---------------- Win32 声明 (必须逐个声明: 64 位下句柄按默认 c_int 传会被截断) ----------------
for _n, (_r, _a) in {
    'RegisterClassExW': (w.ATOM, [ctypes.c_void_p]),
    'UnregisterClassW': (ctypes.c_int, [w.LPCWSTR, ctypes.c_void_p]),
    'CreateWindowExW': (ctypes.c_void_p, [w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD, ctypes.c_int,
                                          ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p,
                                          ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]),
    'DefWindowProcW': (ctypes.c_ssize_t, [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]),
    'DestroyWindow': (ctypes.c_int, [ctypes.c_void_p]),
    'ShowWindow': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int]),
    'UpdateWindow': (ctypes.c_int, [ctypes.c_void_p]),
    'SetWindowPos': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_int, ctypes.c_uint]),
    'SetLayeredWindowAttributes': (ctypes.c_int, [ctypes.c_void_p, w.COLORREF, ctypes.c_ubyte, w.DWORD]),
    'GetWindowLongPtrW': (ctypes.c_ssize_t, [ctypes.c_void_p, ctypes.c_int]),
    'SetWindowLongPtrW': (ctypes.c_ssize_t, [ctypes.c_void_p, ctypes.c_int, ctypes.c_ssize_t]),
    'BeginPaint': (ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_void_p]),
    'EndPaint': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]),
    'InvalidateRect': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]),
    'FillRect': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]),
    'GetDC': (ctypes.c_void_p, [ctypes.c_void_p]),
    'ReleaseDC': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]),
    'GetSystemMetrics': (ctypes.c_int, [ctypes.c_int]),
    'GetForegroundWindow': (ctypes.c_void_p, []),
    'WindowFromPoint': (ctypes.c_void_p, [w.POINT]),
    'GetCursorPos': (ctypes.c_int, [ctypes.c_void_p]),
    'GetAsyncKeyState': (ctypes.c_short, [ctypes.c_int]),
    'RegisterHotKey': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]),
    'UnregisterHotKey': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int]),
    'GetMessageW': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]),
    'TranslateMessage': (ctypes.c_int, [ctypes.c_void_p]),
    'DispatchMessageW': (ctypes.c_ssize_t, [ctypes.c_void_p]),
    'PostMessageW': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]),
    'PostQuitMessage': (None, [ctypes.c_int]),
    'FindWindowW': (ctypes.c_void_p, [w.LPCWSTR, w.LPCWSTR]),
    'MessageBoxW': (ctypes.c_int, [ctypes.c_void_p, w.LPCWSTR, w.LPCWSTR, w.UINT]),
    'GetAncestor': (ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_uint]),
    'DrawTextW': (ctypes.c_int, [ctypes.c_void_p, w.LPCWSTR, ctypes.c_int, ctypes.c_void_p, w.UINT]),
}.items():
    _f = getattr(user32, _n)
    _f.restype, _f.argtypes = _r, _a

for _n, (_r, _a) in {
    'CreateSolidBrush': (ctypes.c_void_p, [w.COLORREF]),
    'CreatePen': (ctypes.c_void_p, [ctypes.c_int, ctypes.c_int, w.COLORREF]),
    'CreateFontW': (ctypes.c_void_p, [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                      ctypes.c_int, w.DWORD, w.DWORD, w.DWORD, w.DWORD, w.DWORD,
                                      w.DWORD, w.DWORD, w.DWORD, w.LPCWSTR]),
    'SelectObject': (ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_void_p]),
    'DeleteObject': (ctypes.c_int, [ctypes.c_void_p]),
    'Ellipse': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int]),
    'Rectangle': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int]),
    'RoundRect': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                 ctypes.c_int, ctypes.c_int, ctypes.c_int]),
    'Polygon': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]),
    'MoveToEx': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_void_p]),
    'LineTo': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]),
    'SetTextColor': (w.COLORREF, [ctypes.c_void_p, w.COLORREF]),
    'SetBkMode': (ctypes.c_int, [ctypes.c_void_p, ctypes.c_int]),
    'GetStockObject': (ctypes.c_void_p, [ctypes.c_int]),
}.items():
    _f = getattr(gdi32, _n)
    _f.restype, _f.argtypes = _r, _a

kernel32.GetModuleHandleW.restype, kernel32.GetModuleHandleW.argtypes = ctypes.c_void_p, [w.LPCWSTR]
kernel32.CreateMutexW.restype, kernel32.CreateMutexW.argtypes = ctypes.c_void_p, [ctypes.c_void_p,
                                                                                 ctypes.c_int, w.LPCWSTR]
kernel32.GetLastError.restype, kernel32.GetLastError.argtypes = ctypes.c_ulong, []
winmm.timeBeginPeriod.restype, winmm.timeBeginPeriod.argtypes = ctypes.c_uint, [ctypes.c_uint]
winmm.timeEndPeriod.restype, winmm.timeEndPeriod.argtypes = ctypes.c_uint, [ctypes.c_uint]

NULL_PEN = gdi32.GetStockObject(8)          # NULL_PEN
NULL_BRUSH = gdi32.GetStockObject(5)        # NULL_BRUSH
WHITE_BRUSH = gdi32.GetStockObject(0)
BLACK_PEN = gdi32.GetStockObject(7)
DEFAULT_GUI_FONT = gdi32.GetStockObject(17)


class RECT(ctypes.Structure):
    _fields_ = [('left', ctypes.c_long), ('top', ctypes.c_long),
                ('right', ctypes.c_long), ('bottom', ctypes.c_long)]


class PAINTSTRUCT(ctypes.Structure):
    _fields_ = [('hdc', ctypes.c_void_p), ('fErase', w.BOOL), ('rcPaint', RECT),
                ('fRestore', w.BOOL), ('fIncUpdate', w.BOOL), ('rgbReserved', ctypes.c_byte * 32)]


class MSG(ctypes.Structure):
    _fields_ = [('hwnd', ctypes.c_void_p), ('message', w.UINT), ('wParam', ctypes.c_size_t),
                ('lParam', ctypes.c_ssize_t), ('time', w.DWORD), ('pt', w.POINT)]


class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [('cbSize', w.UINT), ('style', w.UINT), ('lpfnWndProc', ctypes.c_void_p),
                ('cbClsExtra', ctypes.c_int), ('cbWndExtra', ctypes.c_int), ('hInstance', ctypes.c_void_p),
                ('hIcon', ctypes.c_void_p), ('hCursor', ctypes.c_void_p), ('hbrBackground', ctypes.c_void_p),
                ('lpszMenuName', w.LPCWSTR), ('lpszClassName', w.LPCWSTR), ('hIconSm', ctypes.c_void_p)]


def rgb(hexs):
    """'#rrggbb' -> COLORREF."""
    h = str(hexs).lstrip('#')
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return r | (g << 8) | (b << 16)


def vlog(text):
    """always-on 诊断: 写宿主同一个 debug.log(排障用)。"""
    try:
        la = os.environ.get('LOCALAPPDATA') or ''
        bases = ([os.path.join(la, 'wgime-py')] if la else []) + \
                [os.path.join(os.path.expanduser('~'), 'wgime-py')]
        for d in bases:
            os.makedirs(d, exist_ok=True)
            with open(os.path.join(d, 'debug.log'), 'a', encoding='utf-8') as f:
                f.write('%.3f [pet] %s\n' % (time.time(), text))
            return
    except Exception:
        pass


# ======================================================================
# GDI: 一帧的笔刷/画笔/字体缓存 (用完把系统对象选回去再删, 否则 DeleteObject 失败=泄漏)
# ======================================================================
class Gfx(object):
    def __init__(self, hdc, oy=0):
        self.hdc = hdc
        self.oy = int(oy)          # 画布原点相对屏幕的 y 偏移(截图模式: 窗口只盖住底部一条)
        self.ext = None            # 本帧**实际画到**的范围(屏幕坐标) —— 脏矩形自愈用, 见 paint()
        self._objs = []

    def _hit(self, x0, y0, x1, y1):
        """记账: 本帧画到哪儿了(皮肤/球/面板/特效都算)。"""
        if x0 > x1:
            x0, x1 = x1, x0
        if y0 > y1:
            y0, y1 = y1, y0
        e = self.ext
        self.ext = ((x0, y0, x1, y1) if e is None else
                    (min(e[0], x0), min(e[1], y0), max(e[2], x1), max(e[3], y1)))

    def _brush(self, col):
        b = gdi32.CreateSolidBrush(rgb(col))
        self._objs.append(b)
        return b

    def _pen(self, col, width=1):
        p = gdi32.CreatePen(0, max(1, int(width)), rgb(col))
        self._objs.append(p)
        return p

    def _font(self, size, bold=False):
        f = gdi32.CreateFontW(-int(size), 0, 0, 0, 700 if bold else 400, 0, 0, 0, 1, 0, 0, 0, 0,
                              'Microsoft YaHei')
        self._objs.append(f)
        return f

    def _n(self, x0, y0, x1, y1):
        """坐标归一化(朝向翻转会让 x0>x1) + 平移到客户区。"""
        if x0 > x1:
            x0, x1 = x1, x0
        if y0 > y1:
            y0, y1 = y1, y0
        self._hit(x0, y0, x1, y1)          # 记的是屏幕坐标(不含 oy)
        return int(x0), int(y0) - self.oy, int(x1), int(y1) - self.oy

    def rect(self, x0, y0, x1, y1, fill=None, outline=None, width=1):
        x0, y0, x1, y1 = self._n(x0, y0, x1, y1)
        gdi32.SelectObject(self.hdc, self._brush(fill) if fill else NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(outline, width) if outline else NULL_PEN)
        gdi32.Rectangle(self.hdc, x0, y0, x1, y1)

    def rrect(self, x0, y0, x1, y1, r=8, fill=None, outline=None, width=1):
        x0, y0, x1, y1 = self._n(x0, y0, x1, y1)
        gdi32.SelectObject(self.hdc, self._brush(fill) if fill else NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(outline, width) if outline else NULL_PEN)
        gdi32.RoundRect(self.hdc, x0, y0, x1, y1, int(r) * 2, int(r) * 2)

    def ell(self, x0, y0, x1, y1, fill=None, outline=None, width=1):
        x0, y0, x1, y1 = self._n(x0, y0, x1, y1)
        gdi32.SelectObject(self.hdc, self._brush(fill) if fill else NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(outline, width) if outline else NULL_PEN)
        gdi32.Ellipse(self.hdc, x0, y0, x1, y1)

    def line(self, x0, y0, x1, y1, col, width=2):
        self._hit(min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
        gdi32.SelectObject(self.hdc, NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(col, width))
        gdi32.MoveToEx(self.hdc, int(x0), int(y0) - self.oy, None)
        gdi32.LineTo(self.hdc, int(x1), int(y1) - self.oy)

    def poly(self, pts, fill=None, outline=None, width=1):
        gdi32.SelectObject(self.hdc, self._brush(fill) if fill else NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(outline, width) if outline else NULL_PEN)
        if pts:
            self._hit(min(p[0] for p in pts), min(p[1] for p in pts),
                      max(p[0] for p in pts), max(p[1] for p in pts))
        arr = (w.POINT * len(pts))(*[w.POINT(int(x), int(y) - self.oy) for (x, y) in pts])
        gdi32.Polygon(self.hdc, arr, len(pts))

    def text(self, x0, y0, x1, y1, s, col, size=14, bold=False):
        if not s:
            return
        gdi32.SelectObject(self.hdc, self._font(size, bold))
        gdi32.SetTextColor(self.hdc, rgb(col))
        gdi32.SetBkMode(self.hdc, TRANSPARENT_BK)
        r = RECT(*self._n(x0, y0, x1, y1))
        user32.DrawTextW(self.hdc, str(s), -1, ctypes.byref(r),
                         DT_SINGLELINE | DT_VCENTER | DT_CENTER)

    def free(self):
        # 先把系统对象选回 DC, 不然我们自己的对象仍被选中 -> DeleteObject 失败 -> GDI 句柄泄漏
        try:
            gdi32.SelectObject(self.hdc, WHITE_BRUSH)
            gdi32.SelectObject(self.hdc, BLACK_PEN)
            gdi32.SelectObject(self.hdc, DEFAULT_GUI_FONT)
        except Exception:
            pass
        for o in self._objs:
            try:
                gdi32.DeleteObject(o)
            except Exception:
                pass
        self._objs = []


class ScaledGfx(object):
    """把画的东西整体放大/平移的适配器 —— 主角按屏幕尺寸放大, 但不用改 draw() 里那堆常数。

    缩放是**绕 (ox, oy) 这一点**做的(主角脚下), 所以它在原地长大, 不会跑偏。
    """

    def __init__(self, g, scale=1.0, ox=0.0, oy=0.0):
        self.g = g
        self.s = float(scale)
        self.ox, self.oy = float(ox), float(oy)

    def _x(self, v):
        return self.ox + (float(v) - self.ox) * self.s

    def _y(self, v):
        return self.oy + (float(v) - self.oy) * self.s

    def _w(self, v):
        return float(v) * self.s

    def rect(self, x0, y0, x1, y1, **kw):
        self.g.rect(self._x(x0), self._y(y0), self._x(x1), self._y(y1),
                    **self._kw(kw))

    def rrect(self, x0, y0, x1, y1, r=8, **kw):
        self.g.rrect(self._x(x0), self._y(y0), self._x(x1), self._y(y1),
                     r=max(1, int(self._w(r))), **self._kw(kw))

    def ell(self, x0, y0, x1, y1, **kw):
        self.g.ell(self._x(x0), self._y(y0), self._x(x1), self._y(y1), **self._kw(kw))

    def line(self, x0, y0, x1, y1, col, width=2):
        self.g.line(self._x(x0), self._y(y0), self._x(x1), self._y(y1), col,
                    max(1, int(self._w(width))))

    def poly(self, pts, **kw):
        self.g.poly([(self._x(x), self._y(y)) for (x, y) in pts], **self._kw(kw))

    def text(self, x0, y0, x1, y1, txt, col, size=14, bold=False):
        self.g.text(self._x(x0), self._y(y0), self._x(x1), self._y(y1), txt, col,
                    size=max(8, int(self._w(size))), bold=bold)

    def _kw(self, kw):
        if 'width' in kw:
            kw = dict(kw)
            kw['width'] = max(1, int(self._w(kw['width'])))
        return kw


# ======================================================================
# 路径 / 工具发现 / 执行 (复用宿主插件体系)
# ======================================================================
def _find_app_dir():
    """复刻 main._find_dict_dir()/APP_DIR 的判据: 找含 py.txt 的目录(dicts 或平级)。"""
    here = os.path.dirname(os.path.abspath(__file__))            # .../plugins
    base = os.path.dirname(here)
    for b in (base, os.path.dirname(base), os.path.join(os.path.dirname(base), 'package')):
        for d in (os.path.join(b, 'dicts'), b):
            if os.path.exists(os.path.join(d, 'py.txt')):
                return os.path.dirname(d) if os.path.basename(d).lower() == 'dicts' else d
    return base


def _ensure_paths():
    """把宿主目录 / 插件目录 / APP_DIR 挂上 sys.path (独立运行与子进程里都要)。"""
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.path.dirname(here), here, _find_app_dir()):
        if p and p not in sys.path:
            sys.path.insert(0, p)


def _read_text(path):
    """按宿主 §28 的规矩读用户可改文本(utf-8-sig -> gbk -> utf-8+replace)。"""
    try:
        with open(path, 'rb') as f:
            raw = f.read()
    except OSError:
        return ''
    for enc in ('utf-8-sig', 'gbk'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('utf-8', 'replace')


def _cfg_keys(*names):
    """从 config.txt 里抠几个 pet_* 键(值很小, 不引宿主 engine)。"""
    out = {}
    txt = _read_text(os.path.join(_find_app_dir(), 'config.txt'))
    for line in txt.split('\n'):
        s = line.rstrip('\r').strip()
        if not s or s[0] in ';#':
            continue
        for sep in ('=', ':'):
            if sep in s:
                k, v = s.split(sep, 1)
                if k.strip().lower() in names:
                    out[k.strip().lower()] = v.strip().strip('"').strip("'")
                break
    return out


def _py_meta(path):
    """静态读 .py 插件的 CODE/NAME/DESC/PERM (按 §8.8: 正则读, 不 import —— 免得跑副作用)。"""
    import re
    txt = _read_text(path)
    if not txt or not re.search(r'^def\s+run\s*\(', txt, re.M):
        return None

    def grab(key):
        m = re.search(r'^%s\s*=\s*[\'"]([^\'"]*)[\'"]' % key, txt, re.M)
        return m.group(1) if m else ''
    code = grab('CODE')
    if not code:
        return None
    return {'code': code, 'name': grab('NAME') or code, 'desc': grab('DESC'),
            'perm': grab('PERM') or 'low'}


def _save_scene(scene_no):
    """把 pet_scene 写回 config.txt: **只动这一行**, 保留原文件的行尾与其它内容; 失败只记日志。

    (用户改过的 config.txt 很娇气 —— 见 AGENTS.md §30/§28; 所以这里二进制读、按原来的行尾写。)
    """
    try:
        path = os.path.join(_find_app_dir(), 'config.txt')
        if not os.path.exists(path):
            return
        with open(path, 'rb') as f:
            raw = f.read()
        try:
            txt = raw.decode('utf-8-sig')
        except UnicodeDecodeError:
            txt = raw.decode('gbk', 'replace')
        eol = '\r\n' if '\r\n' in txt else '\n'
        lines = txt.split('\n')
        hit = False
        for k, ln in enumerate(lines):
            if ln.strip().lower().startswith('pet_scene'):
                lines[k] = 'pet_scene = %d' % scene_no
                hit = True
                break
        if not hit:
            lines.append('pet_scene = %d' % scene_no)
        out = eol.join(lines)
        with open(path, 'wb') as f:
            f.write(out.encode('utf-8'))
        vlog('pet: pet_scene=%d 已写进 %s' % (scene_no, path))
    except Exception as e:
        vlog('pet: 写 pet_scene 失败(不影响使用): %r' % (e,))


def _host_file():
    """宿主本体在哪 —— **跑插件必须由它来跑**(发行版是单文件, ui/win 只存在于它的 sys.modules 里)。

    发行版: `<package>\\wgime-py.py` (插件在 `<package>\\plugins`)
    源码版: `<wgime-py-pure>\\main.py` (插件在 `<wgime-py-pure>\\plugins`)
    """
    here = os.path.dirname(os.path.abspath(__file__))          # .../plugins
    up = os.path.dirname(here)
    for p in (os.path.join(up, 'wgime-py.py'), os.path.join(here, 'wgime-py.py'),
              os.path.join(up, 'main.py')):
        if os.path.exists(p):
            return p
    return ''


def _dll_path():
    """wgpet.dll 跟插件放一起(兼容几种布局)。"""
    here = os.path.dirname(os.path.abspath(__file__))
    up = os.path.dirname(here)
    cands = [os.path.join(here, DLL_NAME), os.path.join(up, DLL_NAME)]
    app = _find_app_dir()
    if app:
        cands.append(os.path.join(app, 'plugins', DLL_NAME))
    for p in cands:
        if os.path.exists(p):
            return p
    return ''


def _load_pet_dll():
    """载入 Rust 浮层 wgpet.dll。任何一步不对就返回 None —— 调用方退回 Python 实现。

    有 DLL 就用 DLL 是**刻意的**: 逐像素 alpha 分层窗 + D2D 抗锯齿 + 2 骨 IK 步态都在里面,
    Python 那套是 LWA_COLORKEY 的旧实现(边缘锯齿、没有半透明), 只在 DLL 缺失/ABI 不对时兜底。
    """
    if sys.platform != 'win32':
        return None
    # 测试钩子: `WGIME_PET_PY=1` 强制走 Python 实现。
    # 为什么必须有它: 有 wgpet.dll 躺在插件旁边时 `_window_main` 一律先走 DLL, 而 DLL 那套
    # **不写 live dump**(它只喂工具 + 看门), 于是 `tests\pet-overlay-test.py` 的 L/L2/L3/L4
    # 段(浮层真起窗/穿透/残影/三场景)全都读不到状态 —— 那是**假红**, 却也**测不到** Python 版。
    # Python 版不是死代码: DLL 缺失/ABI 不对时它就是兜底, 所以老浮层的回归必须留一条强制入口。
    if (os.environ.get('WGIME_PET_PY') or '') not in ('', '0'):
        vlog('pet: WGIME_PET_PY 置位, 强制用 Python 实现')
        return None
    p = _dll_path()
    if not p:
        vlog('pet: 没找到 %s, 用 Python 实现' % DLL_NAME)
        return None
    try:
        lib = ctypes.WinDLL(p)
        ver = int(lib.wgime_pet_abi_version())
        if ver < 1:
            vlog('pet: %s abi=%d 太旧, 用 Python 实现' % (DLL_NAME, ver))
            return None
        lib.wgime_pet_start.restype = ctypes.c_int
        lib.wgime_pet_stop.restype = ctypes.c_int
        lib.wgime_pet_hwnd.restype = ctypes.c_ssize_t
        lib.wgime_pet_palette.argtypes = [ctypes.c_int]
        lib.wgime_pet_set_tools.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        lib.wgime_pet_set_tools.restype = ctypes.c_ssize_t
        lib.wgime_pet_set_launcher.argtypes = [ctypes.c_void_p]
        lib.wgime_pet_debug.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
        lib.wgime_pet_debug.restype = ctypes.c_size_t
        vlog('pet: 用 Rust 浮层 %s (abi=%d)' % (os.path.basename(p), ver))
        return lib
    except Exception as e:
        vlog('pet: 载入 %s 失败 %r, 用 Python 实现' % (DLL_NAME, e))
        return None


def _find_overlay():
    """找已经开着的浮层窗口。DLL 版与 Python 版**标题相同**, 所以先按标题找, 再退回老的类名。"""
    for cls, title in ((None, WIN_TITLE), (CLASS_NAME, WIN_TITLE), (CLASS_NAME, None)):
        try:
            h = user32.FindWindowW(cls, title)
        except Exception:
            h = 0
        if h:
            return int(h)
    return 0


_TOOLCALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_char_p, ctypes.c_size_t)


def _api_call(args, timeout=30):
    """调宿主 API(一次性进程, 它把结果打出一行 JSON) -> dict | None。**显式按 UTF-8 解**。"""
    host = _host_file()
    if not host:
        vlog('pet: 找不到宿主本体, API 不可用')
        return None
    import subprocess
    try:
        r = subprocess.run([sys.executable or 'python', '-X', 'utf8', host, '--api'] + list(args),
                           capture_output=True, timeout=timeout,
                           creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000))
    except Exception as e:
        vlog('pet: api %r failed %r' % (list(args)[:1], e))
        return None
    txt = (r.stdout or b'').decode('utf-8', 'replace')
    for line in reversed(txt.strip().splitlines()):
        line = line.strip()
        if line.startswith('{'):
            try:
                return json.loads(line)
            except ValueError:
                continue
    vlog('pet: api %r bad output %r' % (list(args)[:1], txt[-200:]))
    return None


def _local_scan():
    """本地**静态**扫一遍(只读文件, 不起进程) —— 面板要立刻出得来, 不能等宿主进程启动。"""
    import re
    out, seen = [], set()
    here = os.path.dirname(os.path.abspath(__file__))
    app = _find_app_dir()
    me_name = os.path.basename(os.path.abspath(__file__)).lower()      # 自己别进自己的挎包
    for d in (here, os.path.join(app, 'plugins')):
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.startswith('_') or fn.lower() == me_name:
                continue
            low = fn.lower()
            if low.endswith('.py'):
                kind = 'py'
            elif low.endswith('.txt'):
                kind = 'txt'
            else:
                continue
            txt = _read_text(os.path.join(d, fn))
            if kind == 'py' and not re.search(r'^def\s+run\s*\(', txt, re.M):
                continue

            def g(key, _t=txt):
                m = re.search(r'^\s*%s\s*[:=]\s*[\'"]?([^\'"\r\n;]*)' % key, _t, re.M)
                return (m.group(1) if m else '').strip()
            code = g('code') or g('CODE')
            if not code or code.lower() in seen:
                continue
            seen.add(code.lower())
            out.append({'code': code, 'name': (g('name') or g('NAME') or code), 'kind': kind,
                        'perm': (g('perm') or g('PERM') or 'low'), 'path': os.path.join(d, fn)})
    return out


def discover_tools():
    """挎包里的工具 = 你自己的插件。先本地静态扫(立刻能显示), 随后**后台问宿主要权威清单**替换。

    为什么不能只自己扫: 发行版下 `import plugins` 会撞到**同名的目录**(命名空间包),
    于是 `.txt` 插件被静默丢掉 —— 实测面板里少了两个工具。
    """
    return sorted(_local_scan(), key=_tool_rank)


def refresh_tools_async(on_done):
    """后台问宿主 `--api list-plugins`, 拿到就回调(参数是 list)。"""
    def _bg():
        try:
            d = _api_call(['list-plugins'], timeout=40)
            items = (d or {}).get('plugins') if isinstance(d, dict) else None
            if items:
                on_done(items)
        except Exception as e:
            vlog('pet: refresh tools failed %r' % (e,))
    threading.Thread(target=_bg, name='wgpet-tools', daemon=True).start()


def _tool_rank(t):
    """面板排序: 风险低的在前, 同风险 .py 在前, 再按 code 名。"""
    perm = (t.get('perm') or 'low').lower()
    risk = 0
    for k, w in (('network', 1), ('run', 1), ('registry', 2), ('destructive', 3)):
        if k in perm:
            risk = max(risk, w)
    return (risk, 0 if t.get('kind') == 'py' else 1, (t.get('code') or '').lower())


_HIGH_PERM = (('network', '联网'), ('run', '执行命令'), ('registry', '修改注册表'),
              ('destructive', '删除文件/清理'))


def _mb(text, title, kind='ok', default_no=False):
    flags = MB_TOPMOST | MB_SETFOREGROUND
    if kind == 'okcancel':
        flags |= MB_OKCANCEL
    elif kind == 'yesno':
        flags |= MB_YESNO
    else:
        flags |= MB_OK
    if default_no:
        flags |= MB_DEFBUTTON2
    return user32.MessageBoxW(None, text, title or NAME, flags)


def _confirm_perm(tool):
    """非 low 权限先确认一次 (照 §16: 命中 network/run/registry/destructive 才弹)。"""
    perm = (tool.get('perm') or 'low').lower()
    high = [label for (k, label) in _HIGH_PERM if k in perm]
    if not high:
        return True
    msg = '插件「%s」声明了权限: %s\n\n确定要运行吗?' % (tool.get('name') or tool.get('code'),
                                                       '、'.join(high))
    return _mb(msg, '桌面宠物 · 工具权限确认', 'yesno', True) == IDYES


def run_tool(tool, on_log=None):
    """**交给宿主跑**这个工具 -> (ok, 说明)。

    为什么不在宠物进程里跑(真事故): 发行版是单文件, 插件的 `run()` 要 `import ui`/`win`/`wspy`,
    而它们**只存在于宿主进程的 sys.modules 里** —— 子进程 import 不到, 用户点工具的结果是
    `ModuleNotFoundError: No module named 'ui'`, 工具一个都起不来。
    现在走宿主 API `--api run-plugin <code>`: 宿主起一个进程、建 Tk root、跑 run(), 窗口自己活着。
    """
    code = tool.get('code') or ''
    if not _confirm_perm(tool):
        return False, '已取消(权限确认)'
    host = _host_file()
    if not host or not code:
        return False, '找不到宿主本体(没法运行插件)'
    import subprocess
    import tempfile
    flags = (getattr(subprocess, 'DETACHED_PROCESS', 0x00000008)
             | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x00000200)
             | getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000))
    out_f = tempfile.TemporaryFile()          # 用文件而不是管道: 工具活下来以后管道塞满会把工具卡死
    try:
        p = subprocess.Popen([sys.executable or 'python', '-X', 'utf8', host, '--api',
                              'run-plugin', code],
                             stdin=subprocess.DEVNULL, stdout=out_f, stderr=subprocess.STDOUT,
                             creationflags=flags, close_fds=True)
    except Exception as e:
        out_f.close()
        return False, '%s: %s' % (type(e).__name__, e)
    # 1.2s 内就退的 = 起不来; 把它的 JSON/错误尾巴捞出来给人看
    try:
        p.wait(timeout=1.2)
    except subprocess.TimeoutExpired:
        pass
    if p.poll() is not None:
        try:
            out_f.seek(0)
            txt = out_f.read().decode('utf-8', 'replace')
        except Exception:
            txt = ''
        out_f.close()
        for line in reversed(txt.strip().splitlines()):
            if line.strip().startswith('{'):
                try:
                    d = json.loads(line)
                    if d.get('ok'):
                        return True, '已启动 %s' % (tool.get('name') or code)
                    return False, '失败: %s' % (d.get('error') or '?')
                except ValueError:
                    pass
        tail = (txt.strip().splitlines() or ['起不来'])[-1][:90]
        vlog('pet: tool %s 起不来: %s' % (code, tail))
        return False, '失败: %s' % tail
    vlog('pet: tool %s -> 交给宿主 API (pid %s)' % (code, p.pid))
    if on_log:
        try:
            on_log('已交给输入法本体启动: %s' % code)
        except Exception:
            pass
    return True, '已启动 %s' % (tool.get('name') or code)


# ======================================================================
# 配色
# ======================================================================
PAL = {
    'fur': '#d98b3f', 'fur_d': '#a9631f', 'fur_l': '#f0c48a', 'dark': '#3a2716',
    'bag': '#8a4f1c', 'bag_d': '#5f3512', 'strap': '#4a2a10', 'eye': '#241a10',
    'panel': '#141c26', 'panel_e': '#3d5878', 'slot': '#243447', 'slot_h': '#39536f',
    'txt': '#eaf2ff', 'txt_d': '#9fb4cc', 'accent': '#ffcc4d', 'ball': '#e2701e',
    'shadow': '#0d1219', 'paw': '#f2e3c9', 'ear_in': '#df9d86', 'rope': '#6b5a3a', 'rope_d': '#8a7a52',
}
GROUND_PAD = 8


def _fake_mouse():
    """测试钩子: `WGIME_PET_FAKE_MOUSE="x,y"` —— 不真去动用户的鼠标也能测"躲猫猫"(§4 的规矩:
    被测代码读**真实输入**时必须能打桩, 否则屏幕前的人一动鼠标就假红)。"""
    v = os.environ.get('WGIME_PET_FAKE_MOUSE') or ''
    if ',' in v:
        try:
            a, b = v.split(',', 1)
            return (float(a), float(b))
        except ValueError:
            return None
    return None


def _mouse_pos():
    pt = w.POINT()
    if user32.GetCursorPos(ctypes.byref(pt)):
        return (float(pt.x), float(pt.y))
    return (0.0, 0.0)


# ======================================================================
# 场景 2: 驮挎包的小狗 (活动范围 = 屏幕下方一条带)
# ======================================================================
class DogScene(object):
    """主角: 驮着挎包的小狗(活动范围 = 屏幕下缘, 但跑得快、会跳、会坐会睡会叫)。

    形象: 描边 + 双色明暗 + 像样的比例; 动作: 四拍走/跑/坐/睡/叫/跳, 尾巴一直在摇, 会眨眼。
    跟鼠标: 靠近 240px 就**看你**(头朝光标偏), 贴到 110px 以内就**躲开**(掉头小跑)。
    """

    RUN_SPEED = 360.0
    WALK_SPEED = 150.0

    def __init__(self, screen_w, screen_h):
        self.sw, self.sh = screen_w, screen_h
        self.ground = screen_h - GROUND_PAD
        self.x = screen_w * 0.5
        self.vx = -self.WALK_SPEED
        self.face = -1
        self.phase = 0.0
        self.state = 'walk'            # walk / run / alert / sit / sleep / flee
        self.state_t = 0.0
        self.idle_t = 0.0
        self.ear = 0.0                 # 耳朵竖起(受惊/打字)
        self.bark = 0.0
        self.blink = 0.0
        self.blink_t = self.rng_uniform(1.5, 4.0)
        self.tail = 0.0
        self.flap = 0.0                # 挎包盖 0..1
        self.palette_open = False
        self.hop = 0.0                 # 0..1 跳跃进度(0 = 落地)
        self.run_t = 0.0               # 这一趟快跑还剩多久
        self.look = 0.0                # 看向鼠标 -1..1
        self.mouse = (0.0, 0.0)
        self.rng = random.Random()

    def rng_uniform(self, a, b):
        return random.uniform(a, b)

    # ---- 状态机 ----
    def tick(self, dt, activity, hit_enter, mouse=None):
        self.state_t += dt
        if mouse:
            self.mouse = mouse
        if hit_enter:
            self.bark = 0.9
            self.ear = 1.0
            if self.hop <= 0.0 and self.state not in ('sleep',):
                self.hop = 1e-6
        self.ear = max(0.0, self.ear - dt * 0.8)
        self.bark = max(0.0, self.bark - dt * 1.5)
        self.flap += ((1.0 if self.palette_open else 0.0) - self.flap) * min(1.0, dt * 9.0)
        self.blink_t -= dt
        if self.blink_t <= 0:                      # 眨眼: 0.12s 闭眼, 然后 1.5~4.5s 后再眨
            self.blink = 0.12
            self.blink_t = self.rng_uniform(1.5, 4.5)
        self.blink = max(0.0, self.blink - dt)
        self.run_t = max(0.0, self.run_t - dt)
        if self.hop > 0.0:                          # 跳跃走一个 0.55s 的抛物线
            self.hop = min(1.0, self.hop + dt / 0.55)
            if self.hop >= 1.0:
                self.hop = 0.0

        # 鼠标: 先"看你", 太近就"躲"
        mx, my = self.mouse
        dx, dy = mx - self.x, my - (self.ground - 40)
        dist = (dx * dx + dy * dy) ** 0.5
        look_want = 0.0
        if dist < 420:
            look_want = 1.0 if dx > 0 else -1.0
        self.look += (look_want - self.look) * min(1.0, dt * 5.0)

        if self.palette_open:
            self.state, self.vx = 'sit', 0.0
            self.idle_t = 0.0
        elif dist < 110 and my > self.sh * 0.55:    # 贴脸了 -> 掉头小跑
            self.state = 'flee'
            self.state_t = 0.0
            self.face = -1 if dx > 0 else 1
            self.vx = self.face * self.RUN_SPEED * 1.05
            self.ear = 1.0
        elif activity > 0.15:                       # 你在打字: 站住抬头看你
            self.state, self.state_t = 'alert', 0.0
            self.idle_t = 0.0
            self.vx = 0.0
            self.ear = min(1.0, self.ear + dt * 4.0)
        elif self.state == 'flee':
            self.state = 'walk'
            self.vx = self.face * self.WALK_SPEED
        elif self.idle_t > 24.0 and self.state not in ('sleep',):
            self.state, self.state_t = 'sleep', 0.0
            self.vx = 0.0
        elif self.idle_t > 7.0 and self.state not in ('sit', 'sleep'):
            self.state, self.state_t = 'sit', 0.0
            self.vx = 0.0
        elif self.state in ('sit', 'sleep') and self.idle_t < 0.2:
            self.state = 'walk'
            self.vx = self.face * self.WALK_SPEED
        elif self.state == 'alert' and self.state_t > 0.6:
            self.state = 'walk'
            self.vx = self.face * self.WALK_SPEED

        if activity > 0.15 or self.palette_open or dist < 420:
            self.idle_t = 0.0
        else:
            self.idle_t += dt

        # 偶尔来一趟快跑(闲不住)
        if self.state == 'walk' and self.run_t <= 0 and self.rng.random() < dt * 0.25:
            self.run_t = self.rng.uniform(0.8, 2.2)
        speed = self.WALK_SPEED
        if self.run_t > 0 and self.state == 'walk':
            speed = self.RUN_SPEED

        if self.state in ('walk', 'flee'):
            self.vx = self.face * speed
            self.phase += dt * (speed / 26.0)
            self.x += self.vx * dt
            lo, hi = self.sw * 0.05, self.sw * 0.95
            if self.x < lo:
                self.x, self.face = lo, 1
            elif self.x > hi:
                self.x, self.face = hi, -1
        else:
            self.phase += dt * 1.6
        self.tail += dt * (7.5 if self.state in ('alert', 'sit', 'flee') else 3.2)

    # ---- 几何 ----
    def feet(self):
        return (self.x, self.ground)

    def mouth(self):
        """工具从嘴边抛出去(跟着精灵缩放)。"""
        s = self.SCALE
        return (self.x + self.face * 62 * s, self.ground - 66 * s)

    def origin(self):
        return self.mouth()

    def panel_anchor(self):
        return (self.x, self.ground)

    def bbox(self):
        # **要跟着 SCALE 放大**(踩过: 只放大精灵不改这里 -> 脏矩形盖不住 -> 走一路留一条拖尾)
        s = self.SCALE
        return (self.x - 100 * s, self.ground - 145 * s, self.x + 105 * s, self.ground + 18)

    # ---- 绘制: 描边 + 双色明暗 + 像样的比例 ----
    SCALE = 2.05                       # 4K 屏上不放大就是个小点

    def draw(self, g):
        import math
        g = ScaledGfx(g, self.SCALE * (self.sh / 2160.0 * 1.0 + 0.0) if False else self.SCALE,
                      self.x, self.ground)
        x, face = self.x, self.face
        hop_y = 62.0 * 4 * self.hop * (1 - self.hop) if self.hop else 0.0
        y = self.ground - hop_y
        walking = self.state in ('walk', 'flee')
        running = walking and self.run_t > 0
        swing = math.sin(self.phase) * (12.0 if running else 8.0) if walking else 0.0
        bob = (-abs(math.sin(self.phase)) * (3.0 if running else 2.0)) if walking else 0.0
        sit = self.state in ('sit', 'sleep')
        OL = PAL['dark']

        def P(dx, dy):
            return (x + face * dx, y + dy + bob)

        # 影子: 跳起来变小
        lift = min(1.0, hop_y / 60.0)
        sw_ = 48 - 16 * lift
        g.ell(x - sw_, self.ground - 9, x + sw_, self.ground + 9, fill=PAL['shadow'])
        g.ell(x - sw_ * 0.62, self.ground - 6, x + sw_ * 0.62, self.ground + 6, fill='#0a0e13')

        # 腿: 四拍(前近/前远/后近/后远), 坐着时收起来
        if sit:
            legs = [(-30, 0.0, 24), (28, 0.0, 26)]
        else:
            legs = [(-38, swing, 34), (-26, -swing, 34), (22, -swing, 34), (34, swing, 34)]
        for lx, sw, hgt in legs:
            px, py = P(lx + sw * 0.4, 0)
            g.rrect(px - 7, py - hgt, px + 7, py, r=5, fill=PAL['fur_d'], outline=OL, width=2)
            g.rrect(px - 8, py - 9, px + 10, py + 1, r=4, fill=PAL['paw'], outline=OL, width=2)

        # 尾巴: 三段 + 摇
        wag = math.sin(self.tail) * (0.6 if self.state in ('alert', 'sit', 'flee') else 0.34)
        b0 = P(-52, -72)
        b1 = (b0[0] - face * 22, b0[1] - 16 + wag * 10)
        b2 = (b1[0] - face * 15, b1[1] - 20 - wag * 18)
        g.line(b0[0], b0[1], b1[0], b1[1], OL, 11)
        g.line(b1[0], b1[1], b2[0], b2[1], OL, 9)
        g.line(b0[0], b0[1], b1[0], b1[1], PAL['fur'], 7)
        g.line(b1[0], b1[1], b2[0], b2[1], PAL['fur_l'], 5)

        # 身体: 描边 -> 主色 -> 肚皮亮面 -> 背脊高光
        b0, b1 = P(-52, -96), P(40, -34)
        g.ell(b0[0] - 3, b0[1] - 3, b1[0] + 3, b1[1] + 3, fill=OL)
        g.ell(b0[0], b0[1], b1[0], b1[1], fill=PAL['fur'])
        g.ell(b0[0] + 16, b0[1] + 22, b1[0] - 12, b1[1] - 4, fill=PAL['fur_l'])
        g.line(b0[0] + 14, b0[1] + 10, b1[0] - 18, b1[1] - 24, PAL['fur_l'], 4)

        # 挎包: 背带(斜跨胸口) + 深棕包体 + 盖 + 亮扣; 打开时露出工具
        s0, s1 = P(30, -92), P(-2, -60)
        g.line(s0[0], s0[1], s1[0], s1[1], OL, 9)
        g.line(s0[0], s0[1], s1[0], s1[1], PAL['strap'], 5)
        q0, q1 = P(-16, -74), P(22, -36)
        g.rrect(q0[0] - 3, q0[1] - 3, q1[0] + 3, q1[1] + 3, r=8, fill=OL)
        g.rrect(q0[0], q0[1], q1[0], q1[1], r=7, fill=PAL['bag'])
        qx0, qx1 = min(q0[0], q1[0]), max(q0[0], q1[0])
        if self.flap < 0.9:
            fh = (q1[1] - q0[1]) * 0.5 * (1.0 - self.flap)
            g.rrect(qx0 - 4, q0[1] - 5, qx1 + 4, q0[1] + fh, r=6, fill=PAL['bag_d'],
                    outline=OL, width=2)
        else:
            for k in range(3):
                ix = qx0 + 9 + k * 13
                g.rrect(ix, q0[1] + 7, ix + 10, q0[1] + 22, r=3, fill=PAL['accent'],
                        outline=OL, width=2)
        g.ell((qx0 + qx1) * 0.5 - 5, q0[1] + 16, (qx0 + qx1) * 0.5 + 5, q0[1] + 26,
              fill=PAL['accent'], outline=OL, width=2)

        # 头: 描边 -> 主色 -> 额头亮面
        drop = 18 if self.state == 'sleep' else 0
        hx = 44 + self.look * 5
        h0, h1 = P(hx - 29, -136 + drop), P(hx + 29, -78 + drop)
        g.ell(h0[0] - 3, h0[1] - 3, h1[0] + 3, h1[1] + 3, fill=OL)
        g.ell(h0[0], h0[1], h1[0], h1[1], fill=PAL['fur'])
        g.ell(h0[0] + 10, h0[1] + 8, h1[0] - 26, h1[1] - 26, fill=PAL['fur_l'])

        # 垂耳: 挂在头后上方, 受惊时竖起(ear -> 1)
        up = self.ear
        # 小三角垂耳: 底边贴头后上缘, 尖端斜下挂; 受惊时尖端抬起来
        e0 = P(hx - 4, -136 + drop)
        e1 = P(hx - 30, -128 + drop)
        e2 = P(hx - 34, -100 + drop - 30 * up)
        g.poly([e0, e1, e2], fill=OL)
        g.poly([(e0[0] + 2, e0[1] + 3), (e1[0] + 5, e1[1] + 4), (e2[0] + 4, e2[1] - 2)],
               fill=PAL['fur_d'])
        g.poly([(e0[0] + 4, e0[1] + 6), (e1[0] + 7, e1[1] + 6), (e2[0] + 6, e2[1] + 1)],
               fill=PAL['ear_in'])

        # 口鼻: 亮色吻部 + 黑鼻头 + 嘴(叫的时候张开)
        n0, n1 = P(hx + 16, -114 + drop), P(hx + 56, -88 + drop)
        g.ell(n0[0] - 2, n0[1] - 2, n1[0] + 2, n1[1] + 2, fill=OL)
        g.ell(n0[0], n0[1], n1[0], n1[1], fill=PAL['fur_l'])
        g.ell(n1[0] - 14, n1[1] - 14, n1[0] - 1, n1[1] - 3, fill=PAL['dark'])
        g.ell(n1[0] - 12, n1[1] - 12, n1[0] - 7, n1[1] - 8, fill='#ffffff')
        if self.bark > 0.1:
            m0, m1 = P(hx + 28, -102 + drop), P(hx + 58, -84 + drop)
            g.ell(m0[0], m0[1], m1[0], m1[1], fill='#8c2f2f', outline=OL, width=2)
            g.ell(m0[0] + 6, m1[1] - 8, m0[0] + 18, m1[1] + 2, fill='#e2726f')
        else:
            g.line(n1[0] - 16, n1[1] - 2, n1[0] - 4, n1[1] - 2, OL, 2)

        # 眼睛: 眼白 + 瞳孔 + 高光; 眨眼/睡觉是一条线
        er = 6.0 + 1.6 * self.ear
        ex, ey = P(hx + 8, -120 + drop)
        if self.blink > 0 or self.state == 'sleep':
            g.line(ex - er - 1, ey, ex + er + 1, ey, OL, 3)
        else:
            g.ell(ex - er - 1, ey - er - 1, ex + er + 1, ey + er + 1, fill=OL)
            g.ell(ex - er, ey - er, ex + er, ey + er, fill='#ffffff')
            px_ = ex + self.look * 2.0
            g.ell(px_ - er * 0.62, ey - er * 0.62, px_ + er * 0.62, ey + er * 0.62,
                  fill=PAL['eye'])
            g.ell(px_ - er * 0.5, ey - er * 0.6, px_ - er * 0.1, ey - er * 0.2, fill='#ffffff')

        # 叫: 三道声波
        if self.bark > 0.05:
            for k in range(3):
                rr = 16 + k * 12
                mx, my = P(hx + 60 + rr * 0.5, -110 + drop)
                g.line(mx, my - rr * 0.35, mx + 9, my - rr * 0.6 - 6, PAL['accent'], 3)
        # 睡觉: Zzz
        if self.state == 'sleep':
            for k, ch in enumerate('zzz'):
                zx, zy = P(hx + 34 + k * 15, -146 + drop - k * 17)
                g.text(zx - 11, zy - 11, zx + 11, zy + 11, ch, PAL['txt_d'], size=14 + k * 3,
                       bold=True)


# ======================================================================
# 场景 1: 篮球运动员 (屏幕下缘活动; 左右各一块篮板; 打字运球, 回车投篮)
# ======================================================================
HUMAN = {'skin': '#e8b48a', 'skin_d': '#c98f66', 'hair': '#2b2118', 'vest': '#2f6fd0',
         'vest_d': '#24559f', 'shorts': '#e8e8ef', 'shoe': '#e04b3a', 'ball': '#e2701e',
         'ball_d': '#8a3f10', 'hoop': '#e8e8ef', 'rim': '#e04b3a', 'net': '#cfd6e0'}
HOOP_Y_ABOVE = 430                 # 篮筐离地高度(px)


class BallScene(object):
    """场景 1: 篮球运动员。

    - 屏幕下缘自己溜达; **你打字他就原地运球**(随机换手 = 胯下运球那种感觉);
    - **回车 = 投篮**: 球划弧飞向最近那块篮板, 进筐时篮筐亮一下, 再把球捡回来;
    - 呼出工具时(见 PetWindow.request_palette)由 PetWindow 把**球**砸向屏幕中间炸开。
    """

    def __init__(self, sw, sh):
        self.sw, self.sh = sw, sh
        self.ground = sh - GROUND_PAD
        self.x = sw * 0.5
        self.vx = -1.2
        self.face = -1
        self.phase = 0.0
        self.state = 'walk'                     # walk / dribble / shoot / celebrate
        self.state_t = 0.0
        self.palette_open = False
        self.rng = random.Random()
        self.hand = 1                           # 球在身体哪一侧(+1 右 / -1 左)
        self.hand_t = 0.0
        self.hoop_flash = 0.0
        self.ball = {'x': self.x, 'y': self.ground - 30}
        self.mode = 'dribble'                   # dribble / shoot / back
        self.shot = None                        # {'from','to','t0','dur','hoop'}
        self.ba = 0.0                           # 球在手里的颠球相位

    # ---- 篮板/篮筐位置 ----
    def hoop_x(self, side):
        return 106 if side < 0 else self.sw - 106

    def hoop_y(self):
        return self.ground - HOOP_Y_ABOVE

    def nearest_side(self):
        return -1 if self.ball['x'] < self.sw / 2.0 else 1

    def mouth(self):
        """工具从哪儿抛出去(场景 1 用球的位置, 呼应"砸球呼出")。"""
        return (self.ball['x'], self.ball['y'])

    def origin(self):
        return self.mouth()

    def panel_anchor(self):
        return (self.x, self.ground)

    def bbox(self):
        s = self.SCALE
        bx, br = self.ball['x'], 60.0            # 球也放大了 1.5x
        x0 = min(self.x - 62 * s, bx - br)
        x1 = max(self.x + 62 * s, bx + br)
        y0 = min(self.ground - 195 * s, self.ball['y'] - br)
        y1 = self.ground + 10
        if self.mode == 'shoot' or self.hoop_flash > 0:
            for side in (-1, 1):                # 投篮/进球时把篮筐也算进脏区
                hx = self.hoop_x(side)
                x0, x1 = min(x0, hx - 70), max(x1, hx + 70)
                y0, y1 = min(y0, self.hoop_y() - 110), max(y1, self.hoop_y() + 90)
        return (x0, y0, x1, y1)

    # ---- 状态机 ----
    def tick(self, dt, activity, hit_enter, mouse=None):
        self.state_t += dt
        self.hoop_flash = max(0.0, self.hoop_flash - dt * 1.6)
        self.hand_t += dt

        if hit_enter and self.mode == 'dribble':            # 回车 = 投篮
            side = self.nearest_side()
            self.mode = 'shoot'
            self.state = 'shoot'
            self.state_t = 0.0
            self.shot = {'from': (self.ball['x'], self.ball['y']),
                         'to': (self.hoop_x(side), self.hoop_y()),
                         't0': time.perf_counter(), 'dur': 0.95, 'hoop': side}

        if self.palette_open:
            self.state, self.vx = 'dribble', 0.0
        elif self.mode == 'shoot':
            self.vx = 0.0
        elif activity > 0.15:                                # 打字: 原地运球
            self.state, self.state_t, self.vx = 'dribble', 0.0, 0.0
        elif self.state == 'shoot' and self.state_t > 1.5:
            self.state, self.vx = 'walk', (-1.2 if self.face < 0 else 1.2)
        elif self.state in ('dribble',) and activity <= 0.15 and self.mode == 'dribble':
            if self.state_t > 0.6:
                self.state = 'walk'
                self.vx = 1.2 if self.face > 0 else -1.2

        if self.state == 'walk':
            self.phase += dt * abs(self.vx) * 3.4
            self.x += self.vx * dt * 60.0
            lo, hi = self.sw * 0.10, self.sw * 0.90
            if self.x < lo:
                self.x, self.vx, self.face = lo, abs(self.vx), 1
            elif self.x > hi:
                self.x, self.vx, self.face = hi, -abs(self.vx), -1
        else:
            self.phase += dt * 2.2

        if self.mode == 'dribble':
            # 随机换手(胯下运球的感觉): 1~2 秒换一次
            if self.hand_t > self.rng.uniform(0.9, 2.0):
                self.hand_t = 0.0
                self.hand = -self.hand
            self.face = self.hand                       # 面向球那一侧
            self.ba += dt * (7.5 if activity > 0.15 else 4.2)
            hx = self.x + self.hand * 26
            by = self.ground - 22 - abs(math.sin(self.ba)) * 96
            self.ball['x'] += (hx - self.ball['x']) * min(1.0, dt * 9.0)
            self.ball['y'] = by
        elif self.mode == 'shoot':
            p = min(1.0, (time.perf_counter() - self.shot['t0']) / self.shot['dur'])
            (x0, y0), (x1, y1) = self.shot['from'], self.shot['to']
            self.ball['x'] = x0 + (x1 - x0) * p
            self.ball['y'] = y0 + (y1 - y0) * p - 300 * p * (1 - p)
            if p >= 1.0:
                self.hoop_flash = 1.0
                self.mode = 'back'
                self.shot = {'from': (x1, y1 + 30), 'to': (self.x + self.hand * 26, self.ground - 40),
                             't0': time.perf_counter(), 'dur': 0.55}
                self.state = 'celebrate'
        elif self.mode == 'back':
            p = min(1.0, (time.perf_counter() - self.shot['t0']) / self.shot['dur'])
            self.ball['x'] += (self.shot['to'][0] - self.ball['x']) * min(1.0, dt * 8.0)
            self.ball['y'] = self.shot['from'][1] + (self.shot['to'][1] - self.shot['from'][1]) * p
            if p >= 1.0:
                self.mode, self.state, self.ba = 'dribble', 'dribble', 0.0
        if self.state == 'celebrate' and self.state_t > 1.2:
            self.state = 'walk'

    # ---- 绘制 ----
    def draw(self, g):
        for side in (-1, 1):
            self._draw_hoop(g, side)
        self._draw_player(g)
        self._draw_ball(g)

    def _draw_hoop(self, g, side):
        hx, hy = self.hoop_x(side), self.hoop_y()
        board_x = 62 if side < 0 else self.sw - 62
        g.rect(board_x - 9, hy - 78, board_x + 9, hy + 44, fill=HUMAN['hoop'],
               outline='#9aa4b2', width=2)
        g.rect(board_x - 5, hy - 40, board_x + 5, hy + 8, fill=None, outline=HUMAN['rim'], width=2)
        g.line(board_x, hy + 44, board_x, hy + 150, '#8d97a5', 6)          # 立柱
        rim_r = 26 if side < 0 else 26
        rx = hx + (rim_r - 10 if side < 0 else 10 - rim_r)
        flash = self.hoop_flash
        g.ell(hx - rim_r, hy - 9, hx + rim_r, hy + 9, fill=None,
              outline=HUMAN['rim'], width=4 if flash > 0.1 else 3)
        for i in range(4):                                                  # 网
            nx = hx - rim_r + 8 + i * (rim_r * 2 - 16) / 3.0
            g.line(nx, hy + 7, hx + (nx - hx) * 0.45, hy + 40 + (10 if flash > 0.1 else 0),
                   HUMAN['net'], 1)
        if flash > 0.1:
            for i in range(3):
                rr = 34 + i * 12
                g.ell(hx - rr, hy - rr * 0.5, hx + rr, hy + rr * 0.5, fill=None,
                      outline=PAL['accent'], width=2)

    SCALE = 1.9

    def _draw_player(self, g):
        g = ScaledGfx(g, self.SCALE, self.x, self.ground)
        x, y, f = self.x, self.ground, self.face
        swing = math.sin(self.phase) * 7.0 if self.state == 'walk' else 0.0
        bob = -abs(math.sin(self.phase)) * 2.0 if self.state == 'walk' else 0.0
        hip = y - 52 + bob
        # 影子
        g.ell(x - 30, y - 7, x + 30, y + 7, fill=PAL['shadow'])
        # 腿 (+ 鞋)
        for lx, sw in ((-9, swing), (9, -swing)):
            g.rect(x + lx - 6, hip, x + lx + 6, y - 9, fill=HUMAN['skin_d'])
            g.rrect(x + lx - 9, y - 12, x + lx + 10, y - 3, r=3, fill=HUMAN['shoe'],
                    outline='#8f2f22', width=2)
            g.rect(x + lx - 9, y - 5, x + lx + 10, y - 3, fill='#f2f2f2')
        # 短裤
        g.rrect(x - 19, hip - 16, x + 19, hip + 8, r=5, fill=HUMAN['shorts'])
        # 躯干(球衣) + 号码
        g.rrect(x - 19, hip - 58, x + 19, hip - 12, r=7, fill=HUMAN['vest'],
                outline='#1d3f7a', width=2)
        g.rect(x - 3, hip - 58, x + 3, hip - 12, fill=HUMAN['vest_d'])
        g.text(x - 14, hip - 50, x + 14, hip - 30, '23', '#eaf2ff', size=11, bold=True)
        # 手臂: 运球时一只手跟着球, 投篮时双手举起
        if self.state == 'shoot' or self.state == 'celebrate':
            for s in (-1, 1):
                g.line(x + s * 12, hip - 52, x + s * 26, hip - 78, HUMAN['skin'], 6)
            g.ell(x + f * 22 - 7, hip - 92, x + f * 22 + 7, hip - 78, fill=HUMAN['ball'])
        else:
            g.line(x - 13, hip - 50, x - 20, hip - 18, HUMAN['skin'], 6)      # 左臂垂着
            hand_x = self.ball['x'] - f * 6
            hand_y = max(hip - 40, self.ball['y'] - 26)
            g.line(x + f * 13, hip - 50, hand_x, hand_y, HUMAN['skin'], 6)
            g.ell(hand_x - 6, hand_y - 6, hand_x + 6, hand_y + 6, fill=HUMAN['skin'])
        # 头 + 头发 + 眼睛
        hy = hip - 74
        g.ell(x - 14, hy - 14, x + 14, hy + 14, fill=HUMAN['skin'])
        g.ell(x - 15, hy - 17, x + 15, hy + 2, fill=HUMAN['hair'])
        for sgn in (-1, 1):                      # 两只眼 + 眉毛
            ex = x + sgn * 6
            g.ell(ex - 2, hy - 4, ex + 3, hy + 2, fill='#2b2118')
            g.line(ex - 3, hy - 8, ex + 3, hy - 9, HUMAN['hair'], 2)
        g.line(x - 3, hy + 7, x + 4, hy + 7, '#a4603f', 2)

    def _draw_ball(self, g):
        g = ScaledGfx(g, 1.5, self.ball['x'], self.ball['y'])
        bx, by = self.ball['x'], self.ball['y']
        r = 17
        # 轨迹残影(投篮/砸球时)
        if self.mode in ('shoot', 'back'):
            for k in (1, 2, 3):
                q = dict(self.shot)
                if q:
                    rx = bx - (bx - q['from'][0]) * 0.06 * k
                    g.ell(rx - 9, by - 9 + k * 5, rx + 9, by + 9 + k * 5, fill='#b06a2a')
        g.ell(bx - r, by - r, bx + r, by + r, fill=HUMAN['ball'], outline=HUMAN['ball_d'], width=2)
        g.line(bx - r, by, bx + r, by, HUMAN['ball_d'], 1)
        g.line(bx, by - r, bx, by + r, HUMAN['ball_d'], 1)


# ======================================================================
# 场景 3: 沿屏幕四边框活动 + 跟鼠标躲猫猫
# ======================================================================
def _critter(g, x, y, pose, phase, face=1, hide=0.0, look=0.0):
    """场景 3 的主角(和狗同一套形象)。**注意 (x, y) 是"与边框的接触点"**, 身体要朝屏幕里侧偏开
    —— 直接把身体画在接触点上, 半个身子就在屏幕外了(实测底边只露出一个头)。

    pose: stand(底边走) / climb(左右攀爬, 四肢抓墙) / hang(顶边倒挂, 四肢勾住上缘) / air(横跳)
    hide: 0..1 贴边缩起来(躲猫猫): 身体压扁、四肢收拢、眼睛眯起来
    """
    import math
    OL = PAL['dark']
    squash = 1.0 - 0.35 * hide
    swing = math.sin(phase * 2.2)
    wag = math.sin(phase * 1.7) * 6.0
    bw, bh = 26, 30 * squash
    GAP = 14                                   # 身体离边框留一点, 免得压线
    if pose == 'stand':
        bx, by = x, y - bh - GAP
    elif pose == 'climb':
        bx, by = x + face * (bw + GAP), y      # face 指向屏幕里侧 -> 身体往里挪, 四肢才够得着墙
    elif pose == 'hang':
        bx, by = x, y + bh + GAP
    else:
        bx, by = x, y

    # 尾巴(朝屏幕里侧甩)
    tx, ty = bx - face * (bw - 4) if pose == 'climb' else bx - face * (bw - 2), by + 4
    if pose == 'hang':
        ty = by + bh - 10
    g.line(tx, ty, tx - face * 18, ty + (14 + wag * 0.4), OL, 9)
    g.line(tx, ty, tx - face * 18, ty + (14 + wag * 0.4), PAL['fur_d'], 6)

    # 身体
    g.ell(bx - bw - 3, by - bh - 3, bx + bw + 3, by + bh + 3, fill=OL)
    g.ell(bx - bw, by - bh, bx + bw, by + bh, fill=PAL['fur'])
    g.ell(bx - bw + 9, by - bh + 9, bx + bw - 13, by + bh - 8, fill=PAL['fur_l'])

    # 头: 大多在身体"朝屏幕里侧"那一头; 倒挂时在下面
    if pose == 'hang':
        hcy = by + bh + 18
    else:
        hcy = by - bh - 18
    hx0, hy0, hx1, hy1 = bx - 22, hcy - 22, bx + 22, hcy + 22
    g.ell(hx0 - 3, hy0 - 3, hx1 + 3, hy1 + 3, fill=OL)
    g.ell(hx0, hy0, hx1, hy1, fill=PAL['fur'])
    g.ell(hx0 + 8, hy0 + 6, hx1 - 20, hy1 - 20, fill=PAL['fur_l'])
    ear_dn = 1 if pose in ('hang', 'stand') else 0
    for sgn in (-1, 1):
        e0 = (bx + sgn * 15, hcy - 18)
        e1 = (bx + sgn * 31, hcy - 10 + 22 * ear_dn)
        e2 = (bx + sgn * 27, hcy + 8 + 26 * ear_dn)
        g.poly([e0, e1, e2], fill=PAL['fur_d'], outline=OL)
    ex, ey = bx + face * 6, hcy + (-4 if pose != 'hang' else 4)
    if hide > 0.45:
        g.line(ex - 5, ey, ex + 5, ey, OL, 3)
    else:
        g.ell(ex - 6, ey - 6, ex + 6, ey + 6, fill=OL)
        g.ell(ex - 5, ey - 5, ex + 5, ey + 5, fill='#ffffff')
        g.ell(ex - 2 + look * 2, ey - 2, ex + 3 + look * 2, ey + 3, fill=PAL['eye'])
    nx, ny = bx + face * 11, hcy + (0 if pose != 'hang' else 6)
    g.ell(nx - 4, ny - 3, nx + 4, ny + 4, fill=PAL['dark'])

    # 四肢: 一律画在"接触点那一侧", 让脚掌/手爪真的贴上边框
    def limb(a0, a1):
        g.line(a0[0], a0[1], a1[0], a1[1], OL, 9)
        g.line(a0[0], a0[1], a1[0], a1[1], PAL['fur_d'], 6)
        g.ell(a1[0] - 6, a1[1] - 6, a1[0] + 6, a1[1] + 6, fill=PAL['paw'], outline=OL, width=2)

    if pose == 'climb':
        for k, dy in enumerate((-14, 14)):
            sw = swing * (9 if k == 0 else -9)
            limb((bx + face * (bw - 6), by + dy), (x, by + dy + sw))
    elif pose == 'hang':
        for k, dx in enumerate((-14, 14)):
            sw = swing * (9 if k == 0 else -9)
            limb((bx + dx, by - bh + 4), (bx + dx + sw, y))
    elif pose == 'air':
        for a in (-2.5, -1.4, -0.7, 0.4):
            limb((bx, by), (bx + math.cos(a) * 34, by + math.sin(a) * 34))
    else:                                       # stand: 四条腿踩地
        for k, (dx, sw) in enumerate(((-15, swing), (11, -swing))):
            lx = bx + dx
            g.rrect(lx - 6, by + bh - 14, lx + 6 + sw * 0.3, y - 2, r=4,
                    fill=PAL['fur_d'], outline=OL, width=2)
            g.rrect(lx - 7, y - 9, lx + 9, y + 1, r=3, fill=PAL['paw'], outline=OL, width=2)


class ClimbScene(object):
    """场景 3: 主角沿**屏幕四边框**活动, 左右边框是攀爬, 上方是倒挂/天空。

    实现取巧但很稳: 把整圈**周长参数化成一条一维路径** `s`(0=左下角向右), 于是"绕四边跑"就只是
    `s += v*dt`; `_place()` 把 s 映射回 (x, y, 边, 朝向)。躲猫猫只要在这条线上"往离鼠标远的那头跑",
    被逼到角落就**横跳(leap)**到屏幕另一边的边框 —— 顺带满足"扩展到全屏都能成为活动范围"。
    """

    def __init__(self, sw, sh):
        self.sw, self.sh = sw, sh
        self.per = 2.0 * (sw + sh)
        self.s = sw * 0.35
        _edge0 = (os.environ.get('WGIME_PET_EDGE') or '').lower()   # 测试钩子: 从哪条边开始
        if _edge0 == 'right':
            self.s = sw + sh * 0.5
        elif _edge0 == 'top':
            self.s = sw + sh + sw * 0.5
        elif _edge0 == 'left':
            self.s = sw + sh + sw + sh * 0.5
        elif _edge0 == 'bottom':
            self.s = sw * 0.35
        self.v = 120.0
        self.phase = 0.0
        self.palette_open = False
        self.rng = random.Random(3)
        self.mode = 'roam'                 # roam / flee / hide / leap
        self.mode_t = 0.0
        self.hide = 0.0                    # 0..1 贴边缩起来
        self.leap = None                   # {'from','to','t0','dur'}
        self.leap_cool = 0.0
        self.safe_t = 0.0
        # 测试钩子: 让"闲得慌就横跳"在固定时间后发生(否则要等 7~16 秒, 回归等不起)
        try:
            self.leap_after = float(os.environ.get('WGIME_PET_LEAP_MS') or 0) / 1000.0 or None
        except ValueError:
            self.leap_after = None
        self._last_mouse = (0, 0)

    # ---- s <-> 屏幕 ----
    def _place(self, s=None):
        s = (self.s if s is None else s) % self.per
        W, H = float(self.sw), float(self.sh)
        if s < W:
            return s, H - 6, 'bottom', 1
        s -= W
        if s < H:
            return W - 6, H - s, 'right', -1
        s -= H
        if s < W:
            return W - s, 6, 'top', -1
        s -= W
        return 6, s, 'left', 1

    def pos(self):
        if self.leap and self.mode == 'leap':
            p = min(1.0, (time.perf_counter() - self.leap['t0']) / self.leap['dur'])
            (x0, y0), (x1, y1) = self.leap['from'], self.leap['to']
            return (x0 + (x1 - x0) * p, y0 + (y1 - y0) * p - 220 * p * (1 - p), 'air', 1)
        return self._place()

    def mouth(self):
        x, y, _edge, _f = self.pos()
        return (x, y)

    origin = mouth

    def panel_anchor(self):
        x, y, _edge, _f = self.pos()
        return (x, max(y, self.sh * 0.35))      # 面板别贴到屏幕最上边(那儿挂不住)

    def bbox(self):
        x, y, edge, _f = self.pos()
        pad = 250          # _critter 1.85x 且身体离接触点有偏移 —— 留足, 免得留残影
        return (x - pad, y - pad, x + pad, y + pad)

    # ---- 状态机(躲猫猫) ----
    def tick(self, dt, activity, hit_enter, mouse=None):
        self.mode_t += dt
        self.phase += dt * (6.0 if self.mode in ('flee', 'leap') else 2.4)
        self.leap_cool = max(0.0, self.leap_cool - dt)
        if mouse:
            self._last_mouse = mouse
        mx, my = self._last_mouse

        if self.palette_open:
            self.mode, self.v = 'roam', 0.0
            self.hide += (0.0 - self.hide) * min(1.0, dt * 6.0)
            x, y, edge, _f = self.pos()
            return

        if self.mode == 'leap':
            p = (time.perf_counter() - self.leap['t0']) / self.leap['dur']
            if p >= 1.0:
                self.s = self.leap['to_s']
                self.mode, self.mode_t, self.leap = 'roam', 0.0, None
                x, y, edge, _f = self._place()
            else:
                self.hide += (0.0 - self.hide) * min(1.0, dt * 6.0)
                return
        else:
            x, y, edge, _f = self._place()

        d = math.hypot(mx - x, my - y)
        near = 300.0                                   # 靠近就躲
        touch = 105.0                                  # 快贴上了就缩起来
        if d < touch:
            self.mode = 'hide'
            self.mode_t = 0.0
        elif d < near:
            self.mode = 'flee'
            self.mode_t = 0.0

        if self.mode == 'hide':
            self.hide += (1.0 - self.hide) * min(1.0, dt * 8.0)
            self.v = 0.0
            if d > touch * 1.35:                       # 走了就接着跑
                self.mode, self.mode_t = 'flee', 0.0
        elif self.mode == 'flee':
            self.hide += (0.0 - self.hide) * min(1.0, dt * 8.0)
            self.v = 430.0
            ahead, behind = self._place(self.s + 90), self._place(self.s - 90)
            da = math.hypot(mx - ahead[0], my - ahead[1])
            db = math.hypot(mx - behind[0], my - behind[1])
            self.s += (90.0 if da >= db else -90.0) * dt * (self.v / 90.0)
            # 被逼住(前面也不比后面远) + 冷却到了 => 横跳走人
            if da < near * 0.8 and self.leap_cool <= 0:
                self._start_leap(mx, my)
            if d > near * 1.6:
                self.mode, self.mode_t = 'roam', 0.0
        else:                                          # roam
            self.hide += (0.0 - self.hide) * min(1.0, dt * 6.0)
            if activity > 0.15:
                self.v = 0.0                           # 你在打字: 它停下来看你
            else:
                self.v = 110.0
                self.s += self.v * dt
                if self.mode_t > (self.leap_after or self.rng.uniform(7.0, 16.0)) \
                        and self.leap_cool <= 0:
                    self._start_leap(mx, my)           # 闲得慌就横跳一下(全屏都是它的地盘)
        if self.safe_t >= 0:
            pass

    def _start_leap(self, mx, my):
        """跳到"离鼠标最远"的那段边框 —— 顺带把活动范围铺满整屏。"""
        cand = []
        for k in range(12):
            s = self.per * (k / 12.0)
            x, y, _e, _f = self._place(s)
            cand.append((math.hypot(mx - x, my - y), s))
        _d, best = max(cand)
        x, y, _e, _f = self._place()
        tx, ty, _e2, _f2 = self._place(best)
        self.leap = {'from': (x, y), 'to': (tx, ty), 'to_s': best,
                     't0': time.perf_counter(), 'dur': 0.75}
        self.mode, self.mode_t, self.leap_cool = 'leap', 0.0, 2.5

    # ---- 绘制 ----
    def draw(self, g):
        x, y, edge, face = self.pos()
        # 上边框先画"从天空垂下来的藤", 它不参与缩放
        if edge == 'top':
            g.line(x, 0, x, y - 30, PAL['rope'], 3)
            g.ell(x - 5, y - 36, x + 5, y - 26, fill=PAL['rope_d'])
        pose = {'bottom': 'stand', 'top': 'hang', 'left': 'climb', 'right': 'climb',
                'air': 'air'}.get(edge, 'stand')
        _critter(ScaledGfx(g, 1.85, x, y), x, y, pose, self.phase, face=face,
                 hide=self.hide, look=self._look())
        # 躲起来时头顶冒几根"紧张线"
        if self.hide > 0.5:
            for k in range(3):
                g.line(x - 12 + k * 12, y - 78, x - 16 + k * 12, y - 96, PAL['txt_d'], 2)

    def _look(self):
        """看向鼠标的方向(-1..1), 只用来偏移眼珠。"""
        mx, _my = self._last_mouse
        return 1.0 if mx > self.pos()[0] else -1.0



def _make_scene(scene_no, sw, sh):
    if scene_no == 1:
        return BallScene(sw, sh)
    if scene_no == 3:
        return ClimbScene(sw, sh)
    return DogScene(sw, sh)


# ======================================================================
# 浮层窗口
# ======================================================================
class PetWindow(object):
    def __init__(self, scene=None, open_palette=False):
        self.sw = user32.GetSystemMetrics(0)
        self.sh = user32.GetSystemMetrics(1)
        cfg = _cfg_keys('pet_scene')
        try:
            self.scene_no = int(scene or cfg.get('pet_scene') or 2)
        except ValueError:
            self.scene_no = 2
        self.palette_open = False
        self.force_open = bool(open_palette)
        self.tools = []
        self.hover = -1
        self.throw = None
        self.burst = None
        self.threw = []                    # 叼出去过的工具 code (测试看它)
        self.launched = []                 # 真正执行过的工具 code
        self._live_dump = os.environ.get('WGIME_PET_DUMP_LIVE') or ''
        self._live_last = 0.0
        self._live_err = 0
        self.dog = _make_scene(self.scene_no, self.sw, self.sh)   # 主角(按 pet_scene 选场景)
        self.slam = None                  # 场景 1: 呼出时"把球砸向屏幕中间"
        self.pending_palette = False
        self.mouse = (0.0, 0.0)
        self.fake_mouse = _fake_mouse()   # 测试钩子: 不真动用户鼠标也能测躲猫猫
        self.force_enter = False
        self.force_activity = 0.0
        self.paused = False                # 测试钩子(WM_APP_PAUSE) 用
        # 测试钩子: 截图模式 —— 普通不透明窗 + 浅灰底, 让 BitBlt/CopyFromScreen 抓得到
        _shot = (os.environ.get('WGIME_PET_SHOT') or '')
        self.shot = bool(_shot)
        self.shot_full = (_shot.lower() == 'full')
        self.shot_y = 0
        self.prev_rect = None
        self.keys_down = set()
        self.activity = 0.0
        self.frames = 0
        self.t0 = time.perf_counter()
        self._last = self.t0
        self.running = True
        self.hwnd = None
        self._panel = None
        self._cls = None
        self._build()

    # ---------- 建窗(创建时就带 NOACTIVATE -> 永不抢焦点) ----------
    def _build(self):
        hinst = kernel32.GetModuleHandleW(None)
        self._hinst = hinst
        c = WNDCLASSEXW()
        c.cbSize = ctypes.sizeof(WNDCLASSEXW)
        WPPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_void_p, ctypes.c_uint,
                                    ctypes.c_size_t, ctypes.c_ssize_t)
        self._proc = WPPROC(self._wndproc)          # 必须保引用, 否则 GC 后回调炸
        c.lpfnWndProc = ctypes.cast(self._proc, ctypes.c_void_p)
        c.hInstance = hinst
        c.lpszClassName = CLASS_NAME
        self._cls = c
        if not user32.RegisterClassExW(ctypes.byref(c)) and kernel32.GetLastError() != 1410:
            vlog('pet: RegisterClassExW failed err=%s' % kernel32.GetLastError())
        if self.shot:
            self.shot_y = 0 if self.shot_full else max(0, self.sh - 470)
            ex = int(EX_NOACTIVATE | EX_TOOLWINDOW | EX_TOPMOST)
            _h = self.sh if self.shot_full else self.sh - self.shot_y
            self.hwnd = user32.CreateWindowExW(ex, CLASS_NAME, WIN_TITLE, WS_POPUP, 0, self.shot_y,
                                               self.sw, _h, None, None, hinst, None)
        else:
            ex = int(EX_LAYERED | EX_TRANSPARENT | EX_NOACTIVATE | EX_TOOLWINDOW | EX_TOPMOST)
            self.hwnd = user32.CreateWindowExW(ex, CLASS_NAME, WIN_TITLE, WS_POPUP, 0, 0,
                                               self.sw, self.sh, None, None, hinst, None)
            if not self.hwnd:
                raise RuntimeError('CreateWindowExW failed err=%s' % kernel32.GetLastError())
            if not user32.SetLayeredWindowAttributes(ctypes.c_void_p(int(self.hwnd)), rgb(KEY_HEX), 0,
                                                     LWA_COLORKEY):
                user32.DestroyWindow(ctypes.c_void_p(int(self.hwnd)))
                raise RuntimeError('SetLayeredWindowAttributes 失败(键色透明不可用)')
        if not self.hwnd:
            raise RuntimeError('CreateWindowExW failed err=%s' % kernel32.GetLastError())
        self._style()
        user32.ShowWindow(ctypes.c_void_p(int(self.hwnd)), SW_SHOWNOACTIVATE)
        user32.UpdateWindow(ctypes.c_void_p(int(self.hwnd)))
        if not user32.RegisterHotKey(ctypes.c_void_p(int(self.hwnd)), HOTKEY_ID,
                                     MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, HOTKEY_VK):
            vlog('pet: RegisterHotKey Ctrl+Alt+P 失败(可能被别的程序占了)')

    def _style(self):
        """把扩展样式写成"当前该有的样子": 平时穿透, 面板开着时交互(但永不 NOACTIVATE)。"""
        if self.shot:
            return                      # 截图模式是普通窗, 别再加 LAYERED(加了没设属性 = 隐形)
        h = ctypes.c_void_p(int(self.hwnd))
        cur = int(user32.GetWindowLongPtrW(h, GWL_EXSTYLE))
        want = cur | EX_LAYERED | EX_NOACTIVATE | EX_TOOLWINDOW
        want = (want & ~EX_TRANSPARENT) if self.palette_open else (want | EX_TRANSPARENT)
        if want != cur:
            user32.SetWindowLongPtrW(h, GWL_EXSTYLE, want)
        user32.SetWindowPos(h, ctypes.c_void_p(HWND_TOPMOST), 0, 0, 0, 0,
                            SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE)

    # ---------- 工具面板 ----------
    def load_tools(self):
        if not self.tools:
            self.tools = discover_tools()                    # 本地静态扫: 面板立刻出得来
            vlog('pet: %d tools (local scan)' % len(self.tools))
            refresh_tools_async(self._on_tools_refreshed)     # 后台问宿主要权威清单
        return self.tools

    def _on_tools_refreshed(self, items):
        """宿主 API 给的权威清单(后台线程回调): 换掉本地扫的结果。"""
        try:
            seen, out = set(), []
            for t in items:
                c = (t.get('code') or '')
                if not c or c.lower() in seen or c.lower() == CODE.lower():
                    continue                                          # 去重 + 不列自己
                seen.add(c.lower())
                out.append(t)
            if not out:
                return
            self.tools = sorted(out, key=_tool_rank)
            self._panel = None                                    # 面板按新格子数重算
            if self.palette_open:
                self.slots()
            vlog('pet: tools from host API: %d' % len(out))
        except Exception as e:
            vlog('pet: tools refresh cb err %r' % (e,))

    def slots(self):
        """工具面板格子矩形(屏幕坐标); 顺手把整块面板矩形记到 self._panel。"""
        n = max(1, len(self.tools))
        size, gap, cols_max = 60, 12, 6
        cols = min(n, cols_max)
        rows = (n + cols - 1) // cols
        w = cols * size + (cols - 1) * gap
        h = rows * size + (rows - 1) * gap
        ax, ay = self.dog.panel_anchor() if hasattr(self.dog, 'panel_anchor') else (self.sw / 2.0,
                                                                                    self.sh - 8)
        cx = min(max(ax, w / 2.0 + 24), self.sw - w / 2.0 - 24)
        top = max(24, min(ay - 210 - h, self.sh - h - 60))
        left = cx - w / 2.0
        out = []
        for i in range(n):
            r, c = divmod(i, cols)
            x0 = left + c * (size + gap)
            y0 = top + r * (size + gap)
            out.append((x0, y0, x0 + size, y0 + size))
        self._panel = (left - 18, top - 46, left + w + 18, top + h + 18)
        return out

    def open_palette(self):
        self.load_tools()
        self.slots()
        if not self.tools:
            self.burst = {'t0': time.perf_counter(), 'at': (self.sw / 2, self.sh / 2),
                          'text': '没找到工具(插件目录里没有 .py/.txt 插件)'}
            return
        self.palette_open = True
        self.dog.palette_open = True
        self.hover = -1
        self._style()
        vlog('pet: palette open (%d tools)' % len(self.tools))

    def close_palette(self):
        self.palette_open = False
        self.dog.palette_open = False
        self.hover = -1
        self._style()

    def request_palette(self):
        """呼出工具面板。场景 1 是"先把球砸向屏幕中间、炸开、再弹面板"(用户要的那个手感)。"""
        if self.palette_open:
            self.close_palette()
            return
        if self.scene_no == 1:
            self.slam = {'t0': time.perf_counter(), 'dur': 0.55,
                         'from': self.dog.mouth(), 'to': (self.sw / 2.0, self.sh / 2.0)}
            self.pending_palette = True
        else:
            self.open_palette()

    def toggle_palette(self):
        self.close_palette() if self.palette_open else self.request_palette()

    def cycle_scene(self):
        """右键点主角: 换下一个场景(1->2->3->1), 换完记进 config.txt 的 pet_scene。"""
        self.scene_no = 1 if self.scene_no >= 3 else self.scene_no + 1
        self.dog = _make_scene(self.scene_no, self.sw, self.sh)
        self.dog.palette_open = self.palette_open
        self._panel = None
        self.prev_rect = None
        self.invalidate()
        _save_scene(self.scene_no)
        vlog('pet: scene -> %d (右键切换)' % self.scene_no)

    def on_click(self, sx, sy):
        if self.palette_open:
            for i, r in enumerate(self.slots()):
                if r[0] <= sx <= r[2] and r[1] <= sy <= r[3]:
                    self.start_throw(i)
                    return
            self.close_palette()                  # 点空白 = 收起
            return
        bx0, by0, bx1, by1 = self.dog.bbox()
        if bx0 <= sx <= bx1 and by0 <= sy <= by1:
            self.request_palette()                # 点主角 = 开面板

    def start_throw(self, i):
        tool = self.tools[i]
        self.threw.append(tool.get('code'))
        self.throw = {'tool': tool, 't0': time.perf_counter(), 'dur': 0.7,
                      'from': self.dog.mouth(), 'to': (self.sw / 2.0, self.sh / 2.0)}
        self.close_palette()
        vlog('pet: 叼出工具 %s' % (tool.get('name') or tool.get('code')))

    # ---------- 帧 ----------
    def scene_rect(self):
        parts = [self.dog.bbox()]
        if self.palette_open and self._panel:
            parts.append(self._panel)
        if self.throw:
            tx, ty = self._throw_pos(self.throw)
            parts.append((tx - 40, ty - 40, tx + 40, ty + 40))
        if self.slam:
            sx, sy = self._slam_pos(self.slam)
            parts.append((sx - 46, sy - 46, sx + 46, sy + 46))
        if self.burst:
            ax, ay = self.burst['at']
            parts.append((ax - 280, ay - 170, ax + 280, ay + 170))
        x0 = max(0, int(min(p[0] for p in parts)) - 6)
        y0 = max(0, int(min(p[1] for p in parts)) - 6)
        x1 = min(self.sw, int(max(p[2] for p in parts)) + 6)
        y1 = min(self.sh, int(max(p[3] for p in parts)) + 6)
        return (x0, y0, x1, y1)

    @staticmethod
    def _throw_pos(th):
        p = min(1.0, max(0.0, (time.perf_counter() - th['t0']) / th['dur']))
        (x0, y0), (x1, y1) = th['from'], th['to']
        return (x0 + (x1 - x0) * p, y0 + (y1 - y0) * p - 260 * p * (1 - p))

    @staticmethod
    def _slam_pos(th):
        """场景 1 呼出: 球从手里砸向屏幕中间(弧比工具抛得低一点, 像"砸"过去)。"""
        p = min(1.0, max(0.0, (time.perf_counter() - th['t0']) / th['dur']))
        (x0, y0), (x1, y1) = th['from'], th['to']
        return (x0 + (x1 - x0) * p, y0 + (y1 - y0) * p - 150 * p * (1 - p))

    def tick(self):
        now = time.perf_counter()
        dt = min(0.1, now - self._last)
        self._last = now
        if self.paused:
            # 测试钩子(WM_APP_PAUSE): 冻住动画但仍出帧/仍写 dump —— 这样"状态里的坐标"和
            # "屏幕上的像素"严格一致, 回归就能只扫几十个像素(本机 GetPixel 要 8.5ms/次)。
            dt = 0.0
        act, enter = self._sample_keys()
        if self.force_activity > 0:            # 测试钩子(WM_APP_ACTIVITY): 假装在打字
            act = max(act, self.force_activity)
        if self.force_enter:                   # 测试钩子(WM_APP_ENTER): 假装按了回车
            enter = True
            self.force_enter = False
        self.activity = max(act, self.activity - dt * 2.2)
        self.mouse = self.fake_mouse or _mouse_pos()
        self.dog.tick(dt, self.activity, enter, mouse=self.mouse)
        self.frames += 1
        if self.slam and now - self.slam['t0'] >= self.slam['dur']:
            self.burst = {'t0': now, 'at': self.slam['to'], 'text': ''}
            self.slam = None
            if self.pending_palette:
                self.pending_palette = False
                self.open_palette()
                if self.burst:
                    self.burst['text'] = '%d 个工具' % len(self.tools)
        if self.force_open and not self.palette_open:
            self.force_open = False
            self.open_palette()
        if self.throw and now - self.throw['t0'] >= self.throw['dur']:
            tool = self.throw['tool']
            self.burst = {'t0': now, 'at': self.throw['to'],
                          'text': tool.get('name') or tool.get('code')}
            self.throw = None
            threading.Thread(target=self._run_tool_bg, args=(tool,), daemon=True).start()
        if self.burst and now - self.burst['t0'] > 1.1:
            self.burst = None
        self._maybe_live_dump(now)

    def _maybe_live_dump(self, now):
        """测试钩子: 每 ~0.4s 把状态写到 WGIME_PET_DUMP_LIVE, 让回归能在它运行时断言。"""
        if not self._live_dump or now - self._live_last < 0.4:
            return
        self._live_last = now
        try:
            with open(self._live_dump, 'w', encoding='utf-8') as f:
                json.dump(self.dump(), f, ensure_ascii=False)
        except Exception as e:
            # **别静默吞**: 这里吞掉过一个真 bug —— dump() 引用了只有某个场景才有的字段,
            # 结果 live dump 一直是 0 字节, 回归只报"起不来", 查了半天。第一次失败一定写日志。
            self._live_err += 1
            if self._live_err in (1, 20, 100):
                vlog('pet: live dump failed (#%d) %r' % (self._live_err, e))

    def _sample_keys(self):
        """轮询按键(不装钩子 => 绝不干扰输入法)。回车单独算, 其余字母/空格算"打字"。"""
        now, enter = set(), False
        for vk in range(0x41, 0x5B):
            if user32.GetAsyncKeyState(vk) & 0x8000:
                now.add(vk)
        for vk in (0x20, 0x0D):
            if user32.GetAsyncKeyState(vk) & 0x8000:
                now.add(vk)
        new = now - self.keys_down
        if 0x0D in new:
            enter = True
        act = 1.0 if (new - {0x0D}) else 0.0
        self.keys_down = now
        return act, enter

    def _run_tool_bg(self, tool):
        code = tool.get('code')
        self.launched.append(code)
        if os.environ.get('WGIME_PET_NO_LAUNCH'):        # 测试钩子: 只记不跑(别在测试里真开窗)
            self.burst = {'t0': time.perf_counter(), 'at': (self.sw / 2.0, self.sh / 2.0),
                          'text': '%s (测试: 未真执行)' % code}
            return
        ok, msg = run_tool(tool, on_log=lambda s: vlog('pet tool log: %s' % s))
        self.burst = {'t0': time.perf_counter(), 'at': (self.sw / 2.0, self.sh / 2.0),
                      'text': (tool.get('name') or tool.get('code')) if ok
                              else ('失败: %s' % msg)[:60]}
        vlog('pet: tool %s -> ok=%s %s' % (code, ok, msg))

    # ---------- 绘制 ----------
    def paint(self, hdc, rc):
        g = Gfx(hdc, oy=(self.shot_y if self.shot else 0))
        try:
            br = gdi32.CreateSolidBrush(rgb('#e9edf2' if self.shot else KEY_HEX))
            try:
                rr = RECT(rc.left, rc.top, rc.right, rc.bottom)
                user32.FillRect(hdc, ctypes.byref(rr), br)     # 铺键色 = 透明
            finally:
                gdi32.DeleteObject(br)
            self._draw_scene(g)
        finally:
            g.free()
        self._heal_dirty(rc, g.ext)

    def _heal_dirty(self, rc, ext):
        """脏矩形**自愈**: 这一帧实际画到的地方若超出了刚才给我们的绘制区(美术放大了/面板挪了),
        立刻把多出来那块也标脏 —— 否则精灵边缘会**留下残影**(实测: 狗走过一路都是身子的拖尾)。"""
        if not ext:
            return
        x0, y0, x1, y1 = ext
        pad = 8
        if x0 < rc.left - pad or y0 < rc.top - pad or x1 > rc.right + pad or y1 > rc.bottom + pad:
            r = RECT(int(x0) - pad, int(y0) - pad, int(x1) + pad, int(y1) + pad)
            user32.InvalidateRect(ctypes.c_void_p(int(self.hwnd)), ctypes.byref(r), 0)

    def _draw_scene(self, g):
        self.dog.draw(g)
        if self.palette_open and self.tools:
            self._draw_palette(g)
        if self.slam:
            self._draw_slam(g)
        if self.throw:
            self._draw_throw(g)
        if self.burst:
            self._draw_burst(g)

    def _draw_slam(self, g):
        x, y = self._slam_pos(self.slam)
        for k in (2, 1):
            ghost = dict(self.slam, t0=self.slam['t0'] - k * 0.06)
            qx, qy = self._slam_pos(ghost)
            g.ell(qx - 10, qy - 10, qx + 10, qy + 10, fill='#b06a2a')
        g.ell(x - 20, y - 20, x + 20, y + 20, fill=HUMAN['ball'], outline=HUMAN['ball_d'], width=2)
        g.line(x - 20, y, x + 20, y, HUMAN['ball_d'], 2)
        g.line(x, y - 20, x, y + 20, HUMAN['ball_d'], 2)

    def _draw_palette(self, g):
        px0, py0, px1, py1 = self._panel or (0, 0, 0, 0)
        g.rrect(px0, py0, px1, py1, r=14, fill=PAL['panel'], outline=PAL['panel_e'], width=2)
        if 0 <= self.hover < len(self.tools):
            t = self.tools[self.hover]
            title = '%s  ·  %s' % (t.get('name') or t.get('code'), (t.get('desc') or '')[:44])
        else:
            title = '挎包里的工具 %d 个 —— 点一个, 小狗给你叼出来' % len(self.tools)
        g.text(px0 + 12, py0 + 6, px1 - 12, py0 + 36, title, PAL['txt'], size=15, bold=True)
        for i, r in enumerate(self.slots()):
            hot = (i == self.hover)
            g.rrect(r[0], r[1], r[2], r[3], r=10, fill=PAL['slot_h'] if hot else PAL['slot'],
                    outline=PAL['accent'] if hot else PAL['panel_e'], width=2)
            nm = (self.tools[i].get('name') or self.tools[i].get('code') or '?')
            g.text(r[0], r[1] + 6, r[2], r[1] + 36, nm[:2],
                   PAL['accent'] if hot else PAL['txt'], size=20, bold=True)
            g.text(r[0] + 2, r[1] + 34, r[2] - 2, r[3] - 2, nm[:4], PAL['txt_d'], size=11)
        g.text(px0 + 12, py1 - 24, px1 - 12, py1 - 6,
               'Ctrl+Alt+P 开合 · 点空白处收起', PAL['txt_d'], size=11)

    def _draw_throw(self, g):
        th = self.throw
        x, y = self._throw_pos(th)
        for k in (2, 1):                       # 运动残影
            ghost = dict(th, t0=th['t0'] - k * 0.07 * th['dur'])
            qx, qy = self._throw_pos(ghost)
            g.ell(qx - 11, qy - 11, qx + 11, qy + 11, fill=PAL['slot_h'])
        t = th['tool']
        g.rrect(x - 17, y - 17, x + 17, y + 17, r=8, fill=PAL['accent'],
                outline=PAL['dark'], width=2)
        g.text(x - 17, y - 15, x + 17, y + 15, (t.get('name') or t.get('code') or '?')[:2],
               PAL['dark'], size=16, bold=True)

    def _draw_burst(self, g):
        age = time.perf_counter() - self.burst['t0']
        ax, ay = self.burst['at']
        k = min(1.0, age / 0.45)
        for i in range(12):
            a = i * math.pi / 6.0
            r0 = 30 + 110 * k
            g.line(ax + math.cos(a) * r0 * 0.32, ay + math.sin(a) * r0 * 0.32,
                   ax + math.cos(a) * r0, ay + math.sin(a) * r0, PAL['accent'], 3)
        rr = 34 * (1 - k)
        if rr > 2:
            g.ell(ax - rr, ay - rr, ax + rr, ay + rr, fill=PAL['ball'])
        if age > 0.45:
            g.text(ax - 280, ay + 62, ax + 280, ay + 100, self.burst.get('text') or '',
                   PAL['txt'], size=18, bold=True)

    # ---------- 消息处理 ----------
    def _wndproc(self, hwnd, msg, wp, lp):
        try:
            if msg == WM_ERASEBKGND:
                return 1
            if msg == WM_PAINT:
                ps = PAINTSTRUCT()
                hdc = user32.BeginPaint(ctypes.c_void_p(int(hwnd)), ctypes.byref(ps))
                try:
                    self.paint(hdc, ps.rcPaint)
                finally:
                    user32.EndPaint(ctypes.c_void_p(int(hwnd)), ctypes.byref(ps))
                return 0
            if msg == WM_APP_TICK:
                self.tick()
                self.invalidate(hwnd)
                return 0
            if msg == WM_HOTKEY:
                if int(wp) == HOTKEY_ID:
                    self.toggle_palette()
                return 0
            if msg == WM_MOUSEMOVE:
                x, y = self._xy(lp)
                self._on_move(x, y)
                return 0
            if msg == WM_LBUTTONDOWN:
                x, y = self._xy(lp)
                self.on_click(x, y)
                return 0
            if msg == WM_RBUTTONDOWN:
                self.cycle_scene()          # 右键 = 换下一个场景(1->2->3->1)
                return 0
            if msg == WM_APP_TOGGLE:
                self.toggle_palette()
                return 0
            if msg == WM_APP_ENTER:            # 测试钩子: 等价于"按了回车"(投篮/叫)
                self.force_enter = True
                return 0
            if msg == WM_APP_ACTIVITY:         # 测试钩子: 等价于"正在打字"
                self.force_activity = 1.0
                return 0
            if msg == WM_APP_PAUSE:            # 测试钩子: 冻住动画(wp=1)/解冻(wp=0)
                self.paused = bool(wp)         # **显式指定, 不用 toggle** —— 多处调用时 toggle 会错位
                return 0
            if msg == WM_CLOSE:
                user32.DestroyWindow(ctypes.c_void_p(int(hwnd)))
                return 0
            if msg == WM_DESTROY:
                self.running = False
                user32.PostQuitMessage(0)
                return 0
        except Exception as e:
            vlog('pet wndproc msg=%s err=%r' % (msg, e))
        return user32.DefWindowProcW(ctypes.c_void_p(int(hwnd)), msg, wp, lp)

    @staticmethod
    def _xy(lp):
        v = int(lp) & 0xFFFFFFFF
        return ctypes.c_short(v & 0xFFFF).value, ctypes.c_short((v >> 16) & 0xFFFF).value

    def _on_move(self, x, y):
        if not self.palette_open:
            return
        old = self.hover
        self.hover = -1
        for i, r in enumerate(self.slots()):
            if r[0] <= x <= r[2] and r[1] <= y <= r[3]:
                self.hover = i
                break
        if old != self.hover:
            self.invalidate()

    def invalidate(self, hwnd=None):
        hwnd = hwnd or self.hwnd
        r = self.scene_rect()
        if self.prev_rect:                     # 旧位+新位一起脏(不然会留残影)
            r = (min(r[0], self.prev_rect[0]), min(r[1], self.prev_rect[1]),
                 max(r[2], self.prev_rect[2]), max(r[3], self.prev_rect[3]))
        self.prev_rect = self.scene_rect()
        rr = RECT(*r)
        user32.InvalidateRect(ctypes.c_void_p(int(hwnd)), ctypes.byref(rr), 0)

    def pump(self, until=None):
        """消息循环(阻塞式 GetMessage: 实测 59.5fps; 轮询 sleep 会饿住队列只有 40fps)。"""
        msg = MSG()
        while self.running:
            if until and until():
                break
            got = user32.GetMessageW(ctypes.byref(msg), None, 0, 0)
            if got in (0, -1):
                break
            user32.TranslateMessage(ctypes.byref(msg))
            user32.DispatchMessageW(ctypes.byref(msg))

    def destroy(self):
        try:
            user32.UnregisterHotKey(ctypes.c_void_p(int(self.hwnd)), HOTKEY_ID)
        except Exception:
            pass
        try:
            user32.DestroyWindow(ctypes.c_void_p(int(self.hwnd)))
        except Exception:
            pass
        try:
            user32.UnregisterClassW(CLASS_NAME, self._hinst)
        except Exception:
            pass

    def dump(self):
        ex = int(user32.GetWindowLongPtrW(ctypes.c_void_p(int(self.hwnd)), GWL_EXSTYLE))
        anchor = self.dog.panel_anchor() if hasattr(self.dog, 'panel_anchor') else (0.0, 0.0)
        return {'hwnd': int(self.hwnd), 'frames': self.frames,
                'elapsed': round(time.perf_counter() - self.t0, 3),
                'scene': self.scene_no, 'tools': [t.get('code') for t in self.tools],
                'tools_n': len(self.tools), 'palette_open': self.palette_open,
                'hover': self.hover, 'exstyle': ex,
                'transparent': bool(ex & EX_TRANSPARENT),
                'noactivate': bool(ex & EX_NOACTIVATE),
                'layered': bool(ex & EX_LAYERED), 'toolwindow': bool(ex & EX_TOOLWINDOW),
                'topmost': bool(ex & EX_TOPMOST),
                'dog_x': round(anchor[0], 2), 'dog_y': round(anchor[1], 2),
                'dog_state': getattr(self.dog, 'state', None),
                'dog_bbox': [round(v, 1) for v in self.dog.bbox()],
                'activity': round(self.activity, 3),
                'threw': list(self.threw), 'launched': list(self.launched),
                'slots': [[round(v) for v in r] for r in (self.slots() if self.tools else [])],
                'panel': [round(v) for v in self._panel] if self._panel else None,
                'screen': [self.sw, self.sh], 'key': KEY_HEX,
                # 场景相关(测试要看):
                'mouse': [round(self.mouse[0]), round(self.mouse[1])],
                'slam': bool(self.slam), 'pending_palette': self.pending_palette,
                'dog_pos': [round(v, 1) for v in self.dog.mouth()],
                'ball': ([round(self.dog.ball['x']), round(self.dog.ball['y'])]
                         if hasattr(self.dog, 'ball') else None),
                'ball_mode': getattr(self.dog, 'mode', None),
                'hoop_flash': round(getattr(self.dog, 'hoop_flash', 0.0), 3),
                'hoop_y': (round(self.dog.hoop_y()) if self.scene_no == 1 else None),
                'hoop_x': ([round(self.dog.hoop_x(-1)), round(self.dog.hoop_x(1))]
                           if self.scene_no == 1 else None),
                'edge': getattr(self.dog, 'mode', None) if self.scene_no == 3 else None,
                'climb_mode': getattr(self.dog, 'mode', None) if self.scene_no == 3 else None,
                'hide': round(getattr(self.dog, 'hide', 0.0), 3),
                'leaped': round(getattr(self.dog, 's', 0.0), 1) if self.scene_no == 3 else None}


def _ticker(win, stop, fps=60):
    winmm.timeBeginPeriod(1)
    period = 1.0 / float(fps)
    nxt = time.perf_counter()
    try:
        while not stop.is_set() and win.running:
            nxt += period
            d = nxt - time.perf_counter()
            if d > 0:
                time.sleep(d)
            else:
                nxt = time.perf_counter()
            if not user32.PostMessageW(ctypes.c_void_p(int(win.hwnd)), WM_APP_TICK, 0, 0):
                break
    finally:
        winmm.timeEndPeriod(1)


def _selftest_ms():
    for key in ('WGIME_PET_SELFTEST_MS', 'WGIME_STANDALONE_AUTOEXIT_MS'):
        try:
            v = int(os.environ.get(key) or 0)
        except ValueError:
            v = 0
        if v > 0:
            return v
    return 0


def _window_main_dll(lib, standalone=False):
    """DLL 模式: 渲染/动画/命中测试/面板全在 DLL 里(它自带窗口与渲染线程),
    这里只负责: 喂工具清单、把点中的工具交回宿主启动、看门(窗口关了本进程就退)。

    看门这一条不能省: 插件管理器「结束窗口」是给窗口发 WM_CLOSE, 窗口没了但本进程还活着
    就是一个永远睡着的孤儿进程(§46 的收尾逻辑只杀"还有窗口"的进程)。
    """
    h = _find_overlay()
    if h:
        # 已经有一只了 => 这次的"再拉一次插件"读作"开合百宝袋"(与 Python 版同一套游戏式热键)
        user32.PostMessageW(ctypes.c_void_p(h), WM_APP_TOGGLE, 0, 0)
        vlog('pet(dll): 已有浮层 hwnd=%s, 转发开合消息后退出' % h)
        return 0

    tools = discover_tools()
    _feed_tools(lib, tools)
    refresh_tools_async(lambda items: _feed_tools(lib, items))

    def _on_tool(p, n):
        code = ctypes.string_at(p, n).decode('utf-8', 'replace')
        vlog('pet(dll): tool %s -> 交给宿主 API 启动' % code)
        _api_call(['run-plugin', code], timeout=15)

    cb = _TOOLCALLBACK(_on_tool)          # 必须保引用, 否则被 GC 掉就是野指针
    lib.wgime_pet_set_launcher(ctypes.cast(cb, ctypes.c_void_p))

    rc = int(lib.wgime_pet_start())
    if rc != 0:
        vlog('pet(dll): start rc=%d, 退回 Python 实现' % rc)
        return rc
    if standalone:
        print('STANDALONE-OK', flush=True)
    if os.environ.get('WGIME_PET_OPEN_PALETTE'):
        time.sleep(0.3)
        lib.wgime_pet_palette(1)
    vlog('pet(dll): started tools=%d hwnd=%s' % (len(tools), lib.wgime_pet_hwnd()))

    ms = _selftest_ms()
    t0 = time.perf_counter()
    while True:
        time.sleep(0.35)
        if int(lib.wgime_pet_hwnd()) == 0:
            vlog('pet(dll): 窗口已关, 退出')
            break
        if ms and (time.perf_counter() - t0) * 1000.0 >= ms:
            vlog('pet(dll): 自检到点, 关闭')
            lib.wgime_pet_stop()
            break
    return 0


def _feed_tools(lib, items):
    """把工具清单灌进 DLL(格式: 每行 `code\\tname\\tkind`, UTF-8)。"""
    try:
        rows = [(t.get('code') or '', t.get('name') or '', t.get('kind') or '')
                for t in sorted(items, key=_tool_rank)]
        rows = [r for r in rows if r[0]]
        text = '\n'.join('%s\t%s\t%s' % r for r in rows)
        n = int(lib.wgime_pet_set_tools(text.encode('utf-8'), len(text.encode('utf-8'))))
        vlog('pet(dll): 装入 %d 个工具' % n)
        return n
    except Exception as e:
        vlog('pet(dll): 灌工具失败 %r' % (e,))
        return 0


def _window_main(standalone=False):
    """浮层进程真正干活的地方(被插件 detached 拉起, 或独立运行)。"""
    if sys.platform != 'win32':
        raise SystemExit('Windows only')
    _ensure_paths()
    # 首选 Rust 浮层(wgpet.dll); 起不来才用下面这套 Python 实现
    lib = _load_pet_dll()
    if lib is not None:
        rc = _window_main_dll(lib, standalone=standalone)
        if rc == 0 or standalone:
            return rc
        vlog('pet: DLL 模式失败(rc=%d), 改用 Python 实现' % rc)
    inst = None if os.environ.get('WGIME_PET_SHOT') else \
        kernel32.CreateMutexW(None, 0, 'WgImePetOverlayMutex')
    if inst and kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
        h = _find_overlay()                                # 已在跑: 把"开合"转给它, 自己退出
        if h:
            try:
                user32.PostMessageW(ctypes.c_void_p(h), WM_APP_TOGGLE, 0, 0)
                return 0
            except Exception:
                pass
    win = PetWindow(scene=os.environ.get('WGIME_PET_SCENE') or None,
                    open_palette=bool(os.environ.get('WGIME_PET_OPEN_PALETTE')))
    win.load_tools()
    vlog('pet: started scene=%s tools=%d hwnd=%s screen=%dx%d'
         % (win.scene_no, len(win.tools), win.hwnd, win.sw, win.sh))
    if standalone:
        print('STANDALONE-OK', flush=True)
    stop = threading.Event()
    threading.Thread(target=_ticker, args=(win, stop), daemon=True).start()
    ms = _selftest_ms()
    deadline = (time.perf_counter() + ms / 1000.0) if ms else None
    dump_to = os.environ.get('WGIME_PET_DUMP')
    try:
        win.pump(until=(lambda: deadline is not None and time.perf_counter() >= deadline))
    finally:
        stop.set()
        if dump_to:
            try:
                with open(dump_to, 'w', encoding='utf-8') as f:
                    json.dump(win.dump(), f, ensure_ascii=False)
            except Exception as e:
                vlog('pet: dump failed %r' % (e,))
        win.destroy()
    vlog('pet: exit (frames=%d)' % win.frames)
    return 0


def _start_detached_window():
    """宿主入口必须**尽快返回**: 浮层在 detached 子进程里跑(同 wgtranslate 的规矩)。"""
    import subprocess
    script = os.path.abspath(__file__)
    flags = (getattr(subprocess, 'DETACHED_PROCESS', 0x00000008)
             | getattr(subprocess, 'CREATE_NEW_PROCESS_GROUP', 0x00000200)
             | getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000))
    try:
        subprocess.Popen([sys.executable, script, CHILD_ARG], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True, creationflags=flags)
        return True
    except Exception as e:
        vlog('pet: spawn failed %r' % (e,))
        return False


def run():
    """宿主入口(Tk 主线程里同步跑, 必须立刻返回)。"""
    if sys.platform != 'win32':
        return
    _start_detached_window()


if __name__ == '__main__':
    # 入口**只有一个**(§45): 带 CHILD_ARG = 被插件拉起的浮层进程; 不带 = 独立运行。
    # 独立运行**不**复用 run()(那会再起一个 detached 子进程, 父进程立刻退出、留下没主的窗口),
    # 而是就在本进程建浮层 —— 它自带 Win32 消息循环, 用不上 `_standalone.py` 那套 Tk 看守
    # (本插件不是 Tk 程序; 用 _standalone 会白建一个隐藏 Tk root, 且它监视不到这个窗口)。
    _window_main(standalone=(CHILD_ARG not in sys.argv))
