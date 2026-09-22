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
    def __init__(self, hdc):
        self.hdc = hdc
        self._objs = []

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

    @staticmethod
    def _n(x0, y0, x1, y1):
        """坐标归一化: 朝向翻转会让 x0>x1, 直接传给 GDI 画不出来。"""
        if x0 > x1:
            x0, x1 = x1, x0
        if y0 > y1:
            y0, y1 = y1, y0
        return int(x0), int(y0), int(x1), int(y1)

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
        gdi32.SelectObject(self.hdc, NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(col, width))
        gdi32.MoveToEx(self.hdc, int(x0), int(y0), None)
        gdi32.LineTo(self.hdc, int(x1), int(y1))

    def poly(self, pts, fill=None, outline=None, width=1):
        gdi32.SelectObject(self.hdc, self._brush(fill) if fill else NULL_BRUSH)
        gdi32.SelectObject(self.hdc, self._pen(outline, width) if outline else NULL_PEN)
        arr = (w.POINT * len(pts))(*[w.POINT(int(x), int(y)) for (x, y) in pts])
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


def discover_tools():
    """挎包里的工具 = 你自己的插件。

    `.py` 双模式插件扫两处(本插件所在 plugins / APP_DIR\\plugins), `.txt` 步骤插件只扫
    APP_DIR\\plugins —— 与宿主 `main.load_py_plugins()` / `plugins.load_plugins()` 一致
    (docs\\WGIME_插件规范.md §8.8 那个"两个目录不一样"的注)。
    """
    tools, seen = {}, set()
    here = os.path.dirname(os.path.abspath(__file__))
    app = _find_app_dir()
    me_path = os.path.abspath(__file__)
    me_name = os.path.basename(me_path).lower()          # 自己别出现在自己的挎包里
    for d in (here, os.path.join(app, 'plugins')):
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith('.py') or fn.startswith('_') or fn.lower() == me_name:
                continue
            path = os.path.join(d, fn)
            if os.path.abspath(path) == me_path or path.lower() in seen:
                continue
            meta = _py_meta(path)
            if not meta:
                continue
            seen.add(path.lower())
            meta.update({'kind': 'py', 'path': path})
            tools.setdefault(meta['code'].lower(), meta)      # 同一个 code 只留一份
    try:
        _ensure_paths()
        import plugins as host_plugins
        for d in (os.path.join(app, 'plugins'),):
            if not os.path.isdir(d):
                continue
            items, _disabled = host_plugins.load_plugins(d, app)
            for p in items:
                if p.path.lower() in seen:
                    continue
                seen.add(p.path.lower())
                m = host_plugins.plugin_meta(p)
                code = (m.get('code') or '').lower()
                if not code:
                    continue
                # 与 .py 同 code 的 .txt 不重复登记 —— 纯 Python 版的同功能插件以 .py 为准
                tools.setdefault(code, {'kind': 'txt', 'path': p.path, 'obj': p,
                                        'code': m.get('code') or '', 'name': m.get('name') or '',
                                        'desc': m.get('desc') or '', 'perm': m.get('perm') or 'low'})
    except Exception as e:
        vlog('discover .txt tools failed: %r' % (e,))
    return list(tools.values())


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
    """在本进程后台线程里执行一个工具 -> (ok, 说明)。"""
    def log(s):
        if on_log:
            try:
                on_log(str(s))
            except Exception:
                pass
        vlog('tool %s: %s' % (tool.get('code'), s))

    if not _confirm_perm(tool):
        return False, '已取消(权限确认)'
    try:
        _ensure_paths()
        if tool.get('kind') == 'py':
            import importlib.util
            name = 'wgpet_tool_%d' % (abs(hash(tool['path'])) & 0xFFFFFF)
            spec = importlib.util.spec_from_file_location(name, tool['path'])
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)          # 模块级副作用在这里发生(与宿主装载同规矩)
            fn = getattr(mod, 'run', None)
            if not callable(fn):
                return False, '没有可调用的 run()'
            fn()
            return True, '已启动 %s' % (tool.get('name') or tool.get('code'))
        if tool.get('kind') == 'txt':
            import plugins as host_plugins
            body = getattr(tool['obj'], 'body', None) or []
            host_plugins.run_steps(body, log,
                                   lambda title, text: _mb(text, title),
                                   lambda text, title='', buttons='ok', default_no=False:
                                   _mb(text, title, 'okcancel' if buttons == 'okcancel' else 'yesno',
                                       default_no) in (IDYES, IDOK))
            return True, '完成 %s' % (tool.get('name') or tool.get('code'))
    except Exception as e:
        return False, '%s: %s' % (type(e).__name__, e)
    return False, '不认识的工具类型'


# ======================================================================
# 配色
# ======================================================================
PAL = {
    'fur': '#c07a33', 'fur_d': '#8f5520', 'fur_l': '#dda05a', 'dark': '#3a2716',
    'bag': '#a8703c', 'bag_d': '#7d5027', 'strap': '#5d3a1c', 'eye': '#241a10',
    'panel': '#141c26', 'panel_e': '#3d5878', 'slot': '#243447', 'slot_h': '#39536f',
    'txt': '#eaf2ff', 'txt_d': '#9fb4cc', 'accent': '#ffcc4d', 'ball': '#e2701e',
    'shadow': '#0d1219',
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
    def __init__(self, screen_w, screen_h):
        self.sw, self.sh = screen_w, screen_h
        self.x = screen_w * 0.28
        self.y = screen_h - GROUND_PAD
        self.vx = -0.9
        self.face = -1                    # -1 朝左, +1 朝右
        self.phase = 0.0
        self.state = 'walk'
        self.state_t = 0.0
        self.ear = 0.0
        self.bark = 0.0
        self.flap = 0.0
        self.palette_open = False

    def tick(self, dt, activity, hit_enter, mouse=None):
        self.state_t += dt
        if hit_enter:
            self.bark = 0.8
            self.ear = 1.0
        self.ear = max(0.0, self.ear - dt * 0.9)
        self.bark = max(0.0, self.bark - dt * 1.5)
        self.flap += ((1.0 if self.palette_open else 0.0) - self.flap) * min(1.0, dt * 9.0)

        if self.palette_open:
            self.state, self.vx = 'sit', 0.0
        elif activity > 0.15:                      # 在打字: 站住抬头, 耳朵竖起
            self.state, self.state_t = 'alert', 0.0
            self.ear = min(1.0, self.ear + dt * 5.0)
            self.vx = 0.0
        elif self.state == 'alert' and self.state_t > 0.5:
            self.state = 'walk'
            self.vx = 0.9 if self.face > 0 else -0.9

        if self.state == 'walk':
            self.phase += dt * abs(self.vx) * 3.6
            self.x += self.vx * dt * 60.0
            lo, hi = self.sw * 0.06, self.sw * 0.94
            if self.x < lo:
                self.x, self.vx, self.face = lo, abs(self.vx), 1
            elif self.x > hi:
                self.x, self.vx, self.face = hi, -abs(self.vx), -1
        else:
            self.phase += dt * 1.1

    def mouth(self):
        return (self.x + self.face * 58, self.y - 62)

    def panel_anchor(self):
        """面板挂在主角上方: 用脚下的位置算。"""
        return (self.x, self.y)

    def bbox(self):
        return (self.x - 74, self.y - 100, self.x + 80, self.y + 6)

    # ---- 绘制 ----
    def draw(self, g):
        x, y, f = self.x, self.y, self.face
        bob = -abs(math.sin(self.phase)) * 2.0 if self.state == 'walk' else 0.0
        swing = math.sin(self.phase) * 5.0 if self.state == 'walk' else 0.0

        def P(dx, dy):
            return (x + f * dx, y + dy + bob)

        g.ell(x - 46, y - 7, x + 46, y + 7, fill=PAL['shadow'])          # 影子
        for lx, sw in ((-26, swing), (20, -swing)):                      # 四条腿
            px, py = P(lx, 0)
            g.rrect(px - 5, py - 26, px + 5, py, r=4, fill=PAL['fur_d'])
        tx0, ty0 = P(-40, -46)                                           # 尾巴
        tx1, ty1 = P(-58 - (4 if self.bark > 0 else 0), -58 - (12 if self.bark > 0 else 0))
        g.line(tx0, ty0, tx1, ty1, PAL['fur_d'], 5)
        b0, b1 = P(-44, -60), P(32, -18)                                 # 身体
        g.ell(b0[0], b0[1], b1[0], b1[1], fill=PAL['fur'])
        g.ell(b0[0] + (10 if f > 0 else -10), b0[1] + 9, b1[0] - (16 if f > 0 else -16), b1[1] - 5,
              fill=PAL['fur_l'])
        s0, s1 = P(-6, -58), P(8, -24)                                   # 挎包背带
        g.line(s0[0], s0[1], s1[0], s1[1], PAL['strap'], 4)
        q0, q1 = P(-14, -46), P(18, -12)                                 # 挎包
        g.rrect(q0[0], q0[1], q1[0], q1[1], r=6, fill=PAL['bag'],
                outline=PAL['bag_d'], width=2)
        gx0, gx1 = min(q0[0], q1[0]), max(q0[0], q1[0])
        if self.flap < 0.95:
            fh = (q1[1] - q0[1]) * 0.34 * (1.0 - self.flap)
            g.rrect(gx0 - 2, q0[1] - 5, gx1 + 2, q0[1] + fh, r=5,
                    fill=PAL['bag_d'], outline=PAL['strap'])
        else:
            for i in range(3):                                           # 全开: 露出工具
                ix = gx0 + 6 + i * 9
                g.rect(ix, q0[1] + 5, ix + 6, q0[1] + 14, fill=PAL['accent'])
        h0, h1 = P(16, -78), P(60, -38)                                  # 头
        g.ell(h0[0], h0[1], h1[0], h1[1], fill=PAL['fur'])
        e0, e1, e2 = P(26, -72), P(38 - 7 * self.ear, -94 - 7 * self.ear), P(52, -68)
        g.poly([e0, e1, e2], fill=PAL['fur_d'], outline=PAL['dark'])     # 耳朵
        n0, n1 = P(44, -62), P(72, -46)                                  # 口鼻
        g.ell(n0[0], n0[1], n1[0], n1[1], fill=PAL['fur_l'])
        nose = 3.0
        g.ell(n1[0] - 9 - nose, n1[1] - 10 - nose, n1[0] - 9 + nose, n1[1] - 10 + nose,
              fill=PAL['dark'])
        er = 3.2 + 1.6 * self.ear                                        # 眼睛(受惊睁大)
        ex, ey = P(42, -66)
        g.ell(ex - er, ey - er, ex + er, ey + er, fill=PAL['eye'])
        if self.bark > 0.05:                                             # 叫: 三道声波
            for i in range(3):
                rr = 12 + i * 10
                mx, my = P(78 + rr * 0.5, -66)
                g.line(mx, my - rr * 0.35, mx + 7, my - rr * 0.55 - 5, PAL['accent'], 2)


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
        x0 = min(self.x - 60, self.ball['x'] - 40)
        x1 = max(self.x + 60, self.ball['x'] + 40)
        y0 = min(self.ground - 190, self.ball['y'] - 40)
        y1 = self.ground + 6
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

    def _draw_player(self, g):
        x, y, f = self.x, self.ground, self.face
        swing = math.sin(self.phase) * 7.0 if self.state == 'walk' else 0.0
        bob = -abs(math.sin(self.phase)) * 2.0 if self.state == 'walk' else 0.0
        hip = y - 52 + bob
        # 影子
        g.ell(x - 30, y - 7, x + 30, y + 7, fill=PAL['shadow'])
        # 腿 (+ 鞋)
        for lx, sw in ((-9, swing), (9, -swing)):
            g.rect(x + lx - 6, hip, x + lx + 6, y - 8, fill=HUMAN['skin_d'])
            g.rect(x + lx - 8, y - 10, x + lx + 9, y - 2, fill=HUMAN['shoe'])
        # 短裤
        g.rrect(x - 19, hip - 16, x + 19, hip + 8, r=5, fill=HUMAN['shorts'])
        # 躯干(球衣)
        g.rrect(x - 17, hip - 56, x + 17, hip - 12, r=7, fill=HUMAN['vest'])
        g.rect(x - 3, hip - 56, x + 3, hip - 12, fill=HUMAN['vest_d'])
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
        g.ell(x + f * 5 - 2, hy - 3, x + f * 5 + 3, hy + 3, fill='#2b2118')

    def _draw_ball(self, g):
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
        pad = 86
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
        x, y, edge, f = self.pos()
        h = self.hide * 0.55                            # 贴边缩起来的程度
        # 影/挂点
        if edge == 'bottom':
            g.ell(x - 26, y - 6, x + 26, y + 6, fill=PAL['shadow'])
        elif edge == 'top':
            g.line(x, 0, x, y - 34, '#6b5a3a', 3)       # 从"天空"垂下来的藤/绳
        # 身体(按所在边框摆姿势): 朝屏幕里面的方向伸手脚
        bw, bh = 26, 30
        if edge == 'air':
            g.ell(x - 24, y - 24, x + 24, y + 24, fill=PAL['fur'])
            for a in (-0.9, -0.3, 0.3, 0.9):            # 四肢张开
                g.line(x, y, x + math.cos(a) * 40, y + math.sin(a) * 40, PAL['fur_d'], 5)
            g.ell(x - 15, y - 34, x + 15, y - 8, fill=PAL['fur'])
            g.ell(x - 3, y - 24, x + 3, y - 18, fill=PAL['dark'])
            return
        if edge == 'top':
            cy = y + 30 + h * 14
        else:
            cy = y - 34 - h * 10
        g.ell(x - bw, cy - bh, x + bw, cy + bh, fill=PAL['fur'])
        g.ell(x - bw + 8, cy - bh + 8, x + bw - 12, cy + bh - 8, fill=PAL['fur_l'])
        # 尾巴(在屏幕内侧那一边甩)
        tx, ty = (x + f * 26, cy) if edge in ('bottom', 'top') else (x, cy + f * 26)
        g.line(tx, ty, tx + f * 20, ty - 16, PAL['fur_d'], 5)
        # 头(朝边框外/内都看得清)
        hx = x + (f * 8 if edge in ('bottom', 'top') else 0)
        hy = cy - bh - 12 if edge != 'top' else cy + bh + 12
        g.ell(hx - 19, hy - 17, hx + 19, hy + 17, fill=PAL['fur'])
        g.poly([(hx - 12, hy - 14), (hx - 22, hy - 30), (hx - 2, hy - 20)],
               fill=PAL['fur_d'], outline=PAL['dark'])
        g.ell(hx + f * 6 - 3, hy - 4, hx + f * 6 + 4, hy + 4, fill=PAL['dark'])
        g.ell(hx + f * 12 - 4, hy + 6, hx + f * 12 + 4, hy + 12, fill=PAL['fur_l'])
        # 四肢: 攀爬时一上一下交替(这就是"爬树"的观感)
        sw = math.sin(self.phase * 2.2) * (18 if edge in ('left', 'right') else 12)
        if edge == 'bottom':
            for lx in (-14, 14):
                g.line(x + lx, cy + bh - 6, x + lx + sw * (1 if lx > 0 else -1), y - 2,
                       PAL['fur_d'], 5)
        elif edge in ('left', 'right'):
            toward = -1 if edge == 'right' else 1
            for k, ly in enumerate((-16, 16)):          # 两只手交替抓墙
                g.line(x + toward * 12, cy + ly, x + toward * (34 + (sw if k == 0 else -sw)),
                       cy + ly - (10 if k == 0 else -10), PAL['fur_d'], 5)
        else:                                            # top: 倒挂着伸手
            for lx in (-14, 14):
                g.line(x + lx, cy - bh + 6, x + lx + sw * 0.4, 4, PAL['fur_d'], 5)


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
        ex = int(EX_LAYERED | EX_TRANSPARENT | EX_NOACTIVATE | EX_TOOLWINDOW | EX_TOPMOST)
        self.hwnd = user32.CreateWindowExW(ex, CLASS_NAME, WIN_TITLE, WS_POPUP, 0, 0, self.sw, self.sh,
                                           None, None, hinst, None)
        if not self.hwnd:
            raise RuntimeError('CreateWindowExW failed err=%s' % kernel32.GetLastError())
        if not user32.SetLayeredWindowAttributes(ctypes.c_void_p(int(self.hwnd)), rgb(KEY_HEX), 0,
                                                 LWA_COLORKEY):
            user32.DestroyWindow(ctypes.c_void_p(int(self.hwnd)))
            raise RuntimeError('SetLayeredWindowAttributes 失败(键色透明不可用)')
        self._style()
        user32.ShowWindow(ctypes.c_void_p(int(self.hwnd)), SW_SHOWNOACTIVATE)
        user32.UpdateWindow(ctypes.c_void_p(int(self.hwnd)))
        if not user32.RegisterHotKey(ctypes.c_void_p(int(self.hwnd)), HOTKEY_ID,
                                     MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, HOTKEY_VK):
            vlog('pet: RegisterHotKey Ctrl+Alt+P 失败(可能被别的程序占了)')

    def _style(self):
        """把扩展样式写成"当前该有的样子": 平时穿透, 面板开着时交互(但永不 NOACTIVATE)。"""
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
            self.tools = discover_tools()
            vlog('pet: %d tools' % len(self.tools))
        return self.tools

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
        g = Gfx(hdc)
        try:
            br = gdi32.CreateSolidBrush(rgb(KEY_HEX))
            try:
                rr = RECT(rc.left, rc.top, rc.right, rc.bottom)
                user32.FillRect(hdc, ctypes.byref(rr), br)     # 铺键色 = 透明
            finally:
                gdi32.DeleteObject(br)
            self._draw_scene(g)
        finally:
            g.free()

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
            if msg in (WM_LBUTTONDOWN, WM_RBUTTONDOWN):
                x, y = self._xy(lp)
                self.on_click(x, y)
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


def _window_main(standalone=False):
    """浮层进程真正干活的地方(被插件 detached 拉起, 或独立运行)。"""
    if sys.platform != 'win32':
        raise SystemExit('Windows only')
    _ensure_paths()
    inst = kernel32.CreateMutexW(None, 0, 'WgImePetOverlayMutex')
    if inst and kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
        h = user32.FindWindowW(CLASS_NAME, WIN_TITLE)      # 已在跑: 把"开合"转给它, 自己退出
        if h:
            try:
                user32.PostMessageW(ctypes.c_void_p(int(h)), WM_APP_TOGGLE, 0, 0)
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
