# -*- coding: utf-8 -*-
"""win.py — 纯 ctypes Win32 层 (无 .NET): SendInput UNICODE 注入 / 光标跟随 / 剪贴板"""
import ctypes
import ctypes.wintypes as w
import os
import subprocess

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
    """per-char sendunicode; return count sent."""
    text = text or ''
    n = len(text) * 2
    if n == 0:
        return 0
    arr = (INPUT * n)()
    for i, ch in enumerate(text):
        lo = 2 * i
        arr[lo].type = 1
        arr[lo].u.ki.wScan = ord(ch)
        arr[lo].u.ki.dwFlags = 0x4                                   # KEYEVENTF_UNICODE down
        arr[lo + 1].type = 1
        arr[lo + 1].u.ki.wScan = ord(ch)
        arr[lo + 1].u.ki.dwFlags = 0x4 | 0x2                         # UNICODE + KEYUP
        arr[lo].u.ki.dwExtraInfo = magic
        arr[lo + 1].u.ki.dwExtraInfo = magic
    return user32.SendInput(n, arr, ctypes.sizeof(INPUT))


def send_unicode_qtfix(text, magic=MAGIC):
    """全角标点后注入 X 吸收 + Back 擦除 (Qt 应用吞字规避)."""
    items = []
    for ch in text:
        items.append(('uk', ord(ch)))
        items.append(('ku', ord(ch)))
        if ch >= '\u3000' and not (0x4E00 <= ord(ch) <= 0x9FFF) and not (0x3400 <= ord(ch) <= 0x4DBF) \
                and not (0xF900 <= ord(ch) <= 0xFAFF):
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


def paste_text(text, magic=MAGIC):
    """剪贴板粘贴 (提权窗口回退): 保存/恢复原剪贴板."""
    prev = clipboard_text()
    if prev is not None and len(prev) == 0:
        prev = None                                            # 空原文不恢复
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
        threading.Thread(target=lambda: (time.sleep(0.3), clipboard_set(prev)), daemon=True).start()


def clipboard_text():
    try:
        return subprocess.run(['powershell.exe', '-NoProfile', '-Command', 'Get-Clipboard'],
                              capture_output=True, encoding='utf-8', creationflags=0x08000000).stdout.rstrip('\r\n')
    except Exception:
        return None


def clipboard_set(text):
    try:
        subprocess.run(['powershell.exe', '-NoProfile', '-Command', 'Set-Clipboard -Value %s' % _ps_quote(text)],
                       capture_output=True, encoding='utf-8', creationflags=0x08000000)
    except Exception:
        pass


def _ps_quote(s):
    return "'" + s.replace("'", "''") + "'"


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


def get_caret_pos():
    """光标屏幕坐标. 失败时复用上次有效位, 再失败用前台窗口客户区左上 (贴近输入区)."""
    try:
        fg = user32.GetForegroundWindow()
        tid = user32.GetWindowThreadProcessId(fg, None)
        g = GUITHREADINFO()
        g.cbSize = ctypes.sizeof(GUITHREADINFO)
        if user32.GetGUIThreadInfo(tid, ctypes.byref(g)) and g.hwndCaret:
            pt = POINT(g.rcCaret.left, g.rcCaret.bottom)
            user32.ClientToScreen(g.hwndCaret, ctypes.byref(pt))
            _last_caret[0] = (pt.x, pt.y)
            return _last_caret[0]
    except Exception:
        pass
    if _last_caret[0]:
        return _last_caret[0]
    return _foreground_client_origin()


def _foreground_client_origin():
    """前台窗口客户区左上角的屏幕坐标 (光标探测失败的回退)."""
    try:
        fg = user32.GetForegroundWindow()
        if not fg:
            return None
        pt = POINT(0, 0)
        user32.ClientToScreen(fg, ctypes.byref(pt))
        return pt.x + 12, pt.y + 40
    except Exception:
        return None


def screen_workarea():
    sm = ctypes.windll.user32
    r = RECT()
    sm.SystemParametersInfoW(0x0030, 0, ctypes.byref(r), 0)
    return r


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
        from ctypes import wintypes
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
