# -*- coding: utf-8 -*-
"""win.py — 纯 ctypes Win32 层 (无 .NET): SendInput UNICODE 注入 / 光标跟随 / 剪贴板"""
import ctypes
import ctypes.wintypes as w
import os

# debug 日志(光标跟随耗时排查用): 设 WGIME_DEBUG=1 时才记录, 不拖慢正常输入.
# 写 %LOCALAPPDATA%\wgime-py\debug.log (与 main.py _dfn 同文件, 便于一起看).
_DEBUG_CARET = (os.environ.get('WGIME_DEBUG', '') == '1')


def _dlog(text):
    if not _DEBUG_CARET:
        return
    try:
        la = os.environ.get('LOCALAPPDATA', os.path.expanduser('~'))
        d = os.path.join(la, 'wgime-py')
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'debug.log'), 'a', encoding='utf-8') as f:
            f.write('%.3f [win] %s\n' % (__import__('time').time(), text))
    except Exception:
        pass

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32
gdi32 = ctypes.windll.gdi32

MAGIC = 0x5747494D      # 'WGIM': 自家注入事件的 dwExtraInfo 标记
user32.SendInput.restype = w.UINT
user32.SendInput.argtypes = [w.UINT, ctypes.c_void_p, ctypes.c_int]


# ---------- SendInput (UNICODE) ----------
class KEYBDINPUT(ctypes.Structure):
    _fields_ = [('wVk', w.WORD), ('wScan', w.WORD), ('dwFlags', w.DWORD),
                ('time', w.DWORD), ('dwExtraInfo', ctypes.c_ssize_t)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [('dx', ctypes.c_long), ('dy', ctypes.c_long), ('mouseData', w.DWORD),
                ('dwFlags', w.DWORD), ('time', w.DWORD), ('dwExtraInfo', ctypes.c_ssize_t)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [('uMsg', w.DWORD), ('wParamL', w.WORD), ('wParamH', w.WORD)]


class _U(ctypes.Union):
    _fields_ = [('mi', MOUSEINPUT), ('ki', KEYBDINPUT), ('hi', HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [('type', w.DWORD), ('u', _U)]


def send_unicode(text, magic=MAGIC):
    """per-char sendunicode; 按 UTF-16 码元注入(支持 astral/emoji 代理对, 不再截断); return count sent."""
    text = text or ''
    units = text.encode('utf-16-le', 'surrogatepass')   # 每 2 字节一个 UTF-16 码元
    nunits = len(units) // 2
    n = nunits * 2
    if n == 0:
        return 0
    arr = (INPUT * n)()
    for i in range(nunits):
        code = units[2 * i] | (units[2 * i + 1] << 8)
        lo = 2 * i
        arr[lo].type = 1
        arr[lo].u.ki.wScan = code
        arr[lo].u.ki.dwFlags = 0x4                                   # KEYEVENTF_UNICODE down
        arr[lo + 1].type = 1
        arr[lo + 1].u.ki.wScan = code
        arr[lo + 1].u.ki.dwFlags = 0x4 | 0x2                         # UNICODE + KEYUP
        arr[lo].u.ki.dwExtraInfo = magic
        arr[lo + 1].u.ki.dwExtraInfo = magic
    return user32.SendInput(n, arr, ctypes.sizeof(INPUT))


def send_unicode_qtfix(text, magic=MAGIC):
    """全角标点后注入 X 吸收 + Back 擦除 (Qt 应用吞字规避). 按 UTF-16 码元注入, 标点判断仅对 BMP."""
    items = []
    units = text.encode('utf-16-le', 'surrogatepass')
    for i in range(len(units) // 2):
        code = units[2 * i] | (units[2 * i + 1] << 8)
        items.append(('uk', code))
        items.append(('ku', code))
        if 0x3000 <= code <= 0xFFFF and not (0x4E00 <= code <= 0x9FFF) and not (0x3400 <= code <= 0x4DBF) \
                and not (0xF900 <= code <= 0xFAFF):
            items.append(('uk', ord('X')))
            items.append(('ku', ord('X')))
            items.append(('dn', 0x08))
            items.append(('up', 0x08))
    n = len(items)
    arr = (INPUT * n)()
    for i, (kind, val) in enumerate(items):
        arr[i].type = 1
        if kind == 'uk':
            arr[i].u.ki.wScan = val
            arr[i].u.ki.dwFlags = 0x4
            arr[i].u.ki.dwExtraInfo = magic
        elif kind == 'ku':
            arr[i].u.ki.wScan = val
            arr[i].u.ki.dwFlags = 0x4 | 0x2
            arr[i].u.ki.dwExtraInfo = magic
        elif kind == 'dn':
            arr[i].u.ki.wVk = val
            arr[i].u.ki.dwExtraInfo = magic
        else:
            arr[i].u.ki.wVk = val
            arr[i].u.ki.dwFlags = 0x2
            arr[i].u.ki.dwExtraInfo = magic
    return user32.SendInput(n, arr, ctypes.sizeof(INPUT))


def send_key_backspace(magic=MAGIC):
    """向应用注入一个退格键 (VK 0x08 down+up, MAGIC 标记自家注入)."""
    arr = (INPUT * 2)()
    arr[0].type = 1
    arr[0].u.ki.wVk = 0x08
    arr[0].u.ki.dwExtraInfo = magic
    arr[1].type = 1
    arr[1].u.ki.wVk = 0x08
    arr[1].u.ki.dwFlags = 0x2
    arr[1].u.ki.dwExtraInfo = magic
    return user32.SendInput(2, arr, ctypes.sizeof(INPUT))


_paste_gen = [0]   # 剪贴板粘贴代际: 连续粘贴时旧恢复线程不覆盖新内容


def paste_text(text, magic=MAGIC):
    """剪贴板粘贴 (提权窗口回退): 保存/恢复原剪贴板; 代际+读回校验防竞态覆盖."""
    prev = clipboard_text()
    if prev is not None and len(prev) == 0:
        prev = None                                            # 空原文不恢复
    _paste_gen[0] += 1
    gen = _paste_gen[0]
    clipboard_set(text)
    import time
    time.sleep(0.06)
    # 注入 Ctrl+V
    arr = (INPUT * 4)()
    for i in range(4):
        arr[i].type = 1
        arr[i].u.ki.dwExtraInfo = magic
    arr[0].u.ki.wVk = 0x11
    arr[1].u.ki.wVk = 0x56
    arr[2].u.ki.wVk = 0x56
    arr[2].u.ki.dwFlags = 0x2
    arr[3].u.ki.wVk = 0x11
    arr[3].u.ki.dwFlags = 0x2
    user32.SendInput(4, arr, ctypes.sizeof(INPUT))
    time.sleep(0.15)
    if prev:
        import threading
        def restore():
            time.sleep(0.3)
            if _paste_gen[0] == gen and clipboard_text() == text:   # 无新粘贴且剪贴板仍是我们设的值才恢复
                clipboard_set(prev)
        threading.Thread(target=restore, daemon=True).start()


# ---------- 剪贴板 (ctypes 原生, 零子进程/零编码问题) ----------
user32.OpenClipboard.restype = w.BOOL
user32.OpenClipboard.argtypes = [ctypes.c_void_p]
user32.GetClipboardData.restype = ctypes.c_void_p
user32.GetClipboardData.argtypes = [w.UINT]
user32.SetClipboardData.restype = ctypes.c_void_p
user32.SetClipboardData.argtypes = [w.UINT, ctypes.c_void_p]
user32.EmptyClipboard.restype = w.BOOL
kernel32.GlobalAlloc.restype = ctypes.c_void_p
kernel32.GlobalAlloc.argtypes = [w.UINT, ctypes.c_size_t]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]


def clipboard_text():
    """读剪贴板文本 (ctypes 原生, 零子进程/零编码问题); 非文本/失败返回 None."""
    if not user32.OpenClipboard(0):
        return None
    try:
        h = user32.GetClipboardData(13)            # CF_UNICODETEXT
        if not h:
            return None
        p = kernel32.GlobalLock(h)
        if not p:
            return None
        try:
            return ctypes.wstring_at(p)
        finally:
            kernel32.GlobalUnlock(h)
    finally:
        user32.CloseClipboard()


def clipboard_set(text):
    """写剪贴板文本 (ctypes 原生); 失败静默."""
    if text is None:
        text = ''
    try:
        user32.OpenClipboard(0)
    except Exception:
        return
    try:
        user32.EmptyClipboard()
        data = (str(text) + '\0').encode('utf-16-le')
        h = kernel32.GlobalAlloc(0x0002, len(data))   # GMEM_MOVEABLE
        if not h:
            return
        p = kernel32.GlobalLock(h)
        if p:
            ctypes.memmove(p, data, len(data))
            kernel32.GlobalUnlock(h)
            user32.SetClipboardData(13, h)            # CF_UNICODETEXT
    finally:
        user32.CloseClipboard()


# ---------- 光标跟随 ----------
class RECT(ctypes.Structure):
    _fields_ = [('left', ctypes.c_long), ('top', ctypes.c_long), ('right', ctypes.c_long), ('bottom', ctypes.c_long)]


class POINT(ctypes.Structure):
    _fields_ = [('x', ctypes.c_long), ('y', ctypes.c_long)]


class GUITHREADINFO(ctypes.Structure):
    _fields_ = [('cbSize', w.DWORD), ('flags', w.DWORD), ('hwndActive', w.HWND), ('hwndFocus', w.HWND),
                ('hwndCapture', w.HWND), ('hwndMenuOwner', w.HWND), ('hwndMoveSize', w.HWND),
                ('hwndCaret', w.HWND), ('rcCaret', RECT)]


_last_caret = [None]
_last_caret_source = ['none']   # 'caret' | 'mouse' | 'last' | 'fallback'


def get_caret_pos():
    """光标屏幕坐标(主线程, 绝不阻塞). 顺序: GetGUIThreadInfo -> 鼠标光标 ->
    上次有效位 -> 前台窗口底部居中. 纯 ctypes Win32, 不依赖 comtypes/uiautomation."""
    import time as _t
    _t0 = _t.time()
    try:
        fg = user32.GetForegroundWindow()
        tid = user32.GetWindowThreadProcessId(fg, None)
        g = GUITHREADINFO()
        g.cbSize = ctypes.sizeof(GUITHREADINFO)
        ok = bool(user32.GetGUIThreadInfo(tid, ctypes.byref(g)))
        if ok and g.hwndCaret:
            pt = POINT(g.rcCaret.left, g.rcCaret.bottom)
            user32.ClientToScreen(g.hwndCaret, ctypes.byref(pt))
            _last_caret[0] = (pt.x, pt.y)
            _last_caret_source[0] = 'caret'
            _dlog('get_caret_pos: GUITI ok(%.1fms) hwndCaret=%s -> %s' % (
                (_t.time()-_t0)*1000, bool(g.hwndCaret), _last_caret[0]))
            return _last_caret[0]
        _dlog('get_caret_pos: GUITI fail(%.1fms) ok=%s hwndCaret=%s rcCaret=(%d,%d,%d,%d) fg=%s' % (
            (_t.time()-_t0)*1000, ok, bool(g.hwndCaret),
            g.rcCaret.left, g.rcCaret.top, g.rcCaret.right, g.rcCaret.bottom, fg))
    except Exception as e:
        _dlog('get_caret_pos: GUITI exc(%.1fms) %s' % ((_t.time()-_t0)*1000, repr(e)))
    # 现代应用无 Win32 caret: 光标大概率在鼠标附近(用户边点边打字). 用"输入感知鼠标位"作兜底.
    mpos = _input_aware_mouse_pos()
    if mpos is not None:
        _last_caret_source[0] = 'mouse'
        _dlog('get_caret_pos: mouse-fallback(%.1fms) -> %s' % ((_t.time()-_t0)*1000, mpos))
        return mpos
    if _last_caret[0]:
        _last_caret_source[0] = 'last'
        _dlog('get_caret_pos: last-cache(%.1fms) -> %s' % ((_t.time()-_t0)*1000, _last_caret[0]))
        return _last_caret[0]
    _last_caret_source[0] = 'fallback'
    _dlog('get_caret_pos: fallback-origin(%.1fms)' % ((_t.time()-_t0)*1000))
    return _foreground_client_origin()


def _input_aware_mouse_pos():
    """输入感知鼠标兜底位. 垂直 y = 鼠标 y(输入行常在鼠标附近高度); 水平 x:
    若鼠标在前台窗口内 -> 用鼠标 x; 否则(鼠标停在工具栏/屏幕角落) -> 用前台窗口水平中央,
    避免候选窗跑到屏幕角落. 返回 (x, y) 或 None."""
    p = _mouse_pos()
    if p is None:
        return None
    mx, my = p
    fg = user32.GetForegroundWindow()
    if fg:
        r = RECT()
        if user32.GetClientRect(fg, ctypes.byref(r)):
            tl = POINT(0, 0)
            user32.ClientToScreen(fg, ctypes.byref(tl))
            # 前台窗口的屏幕矩形
            win_l, win_t = tl.x, tl.y
            win_r, win_b = tl.x + r.right, tl.y + r.bottom
            if win_l <= mx <= win_r and win_t <= my <= win_b:
                return mx, my           # 鼠标在窗口内, 直接用(光标列接近鼠标横向)
            # 鼠标在窗口外 -> 水平取窗口中央, 垂直仍用鼠标 y(避免贴到屏幕角落)
            return win_l + r.right // 2, my
        # 拿不到窗口矩形, 退回鼠标点
        return mx, my
    return mx, my

def _mouse_pos():
    """鼠标光标屏幕坐标(非 UIA 兜底, 快速)."""
    try:
        p = POINT()
        if user32.GetCursorPos(ctypes.byref(p)):
            return p.x, p.y
    except Exception:
        pass
    return None


def _foreground_client_origin():
    """前台窗口底部居中的屏幕坐标(光标探测失败的回退, 贴近输入区而非左上角)."""
    try:
        fg = user32.GetForegroundWindow()
        if not fg:
            return None
        r = RECT()
        if user32.GetClientRect(fg, ctypes.byref(r)):
            tl = POINT(0, 0)
            user32.ClientToScreen(fg, ctypes.byref(tl))
            # 底部居中附近(略靠左, 贴近常见输入区/任务栏上方), 宽高按 1/3 估算.
            x = tl.x + r.right // 3
            y = tl.y + max(r.bottom - 60, 0)
            return x, y
        pt = POINT(0, 0)
        user32.ClientToScreen(fg, ctypes.byref(pt))
        return pt.x + 120, pt.y + 200
    except Exception:
        return None


def screen_workarea():
    r = RECT()
    user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(r), 0)
    return r


def set_topmost(hwnd):
    """把窗口提到 topmost z-order 最顶(Win11 开始菜单等 Shell 层会比普通 topmost 更高, 用它压回)."""
    try:
        user32.SetWindowPos.restype = w.BOOL
        user32.SetWindowPos.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                                        ctypes.c_int, ctypes.c_int, w.UINT]
        flags = 0x0001 | 0x0002 | 0x0010                       # SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
        user32.SetWindowPos(ctypes.c_void_p(hwnd), ctypes.c_void_p(-1), 0, 0, 0, 0, flags)
    except Exception:
        pass


class MONITORINFO(ctypes.Structure):
    _fields_ = [('cbSize', w.DWORD), ('rcMonitor', RECT), ('rcWork', RECT), ('dwFlags', w.DWORD)]


def workarea_at(x, y):
    """返回 (x,y) 所在显示器的工作区 (多屏正确)."""
    try:
        pt = POINT(int(x), int(y))
        hmon = user32.MonitorFromPoint(pt, 2)                # MONITOR_DEFAULTTONEAREST
        mi = MONITORINFO()
        mi.cbSize = ctypes.sizeof(MONITORINFO)
        if user32.GetMonitorInfoW(hmon, ctypes.byref(mi)):
            return mi.rcWork
    except Exception:
        pass
    return screen_workarea()


class CURSORINFO(ctypes.Structure):
    _fields_ = [('cbSize', w.DWORD), ('flags', w.DWORD), ('hCursor', ctypes.c_void_p), ('ptScreenPos', POINT)]


def cursor_pos():
    p = POINT()
    user32.GetCursorPos(ctypes.byref(p))
    return p.x, p.y


def get_pixel(x, y):
    hdc = user32.GetDC(0)
    try:
        px = gdi32.GetPixel(hdc, x, y)
    finally:
        user32.ReleaseDC(0, hdc)
    if px == 0xFFFFFFFF:      # CLR_INVALID: 取色失败(越屏/无DC) -> None, 避免误判为白色
        return None
    return px & 0xFF, (px >> 8) & 0xFF, (px >> 16) & 0xFF


def foreground_process_name():
    try:
        fg = user32.GetForegroundWindow()
        pid = w.DWORD()
        user32.GetWindowThreadProcessId(fg, ctypes.byref(pid))
        h = kernel32.OpenProcess(0x1000, False, pid.value)
        if not h:
            return ''
        try:
            buf = ctypes.create_unicode_buffer(512)
            size = w.DWORD(512)
            if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size)):
                return os.path.splitext(os.path.basename(buf.value))[0].lower()
        finally:
            kernel32.CloseHandle(h)
    except Exception:
        pass
    return ''


def self_elevated():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def foreground_elevated():
    try:
        fg = user32.GetForegroundWindow()
        pid = w.DWORD()
        user32.GetWindowThreadProcessId(fg, ctypes.byref(pid))
        h = kernel32.OpenProcess(0x1000, False, pid.value)
        if not h:
            return False
        try:
            tok = w.HANDLE()
            if not ctypes.windll.advapi32.OpenProcessToken(h, 0x8, ctypes.byref(tok)):
                return False
            try:
                elev = w.DWORD()
                size = w.DWORD()
                ok = ctypes.windll.advapi32.GetTokenInformation(tok, 20, ctypes.byref(elev), 4, ctypes.byref(size))
                return bool(ok and elev.value != 0)
            finally:
                kernel32.CloseHandle(tok)
        finally:
            kernel32.CloseHandle(h)
    except Exception:
        return False
