# -*- coding: utf-8 -*-
"""hook.py — WH_KEYBOARD_LL via ctypes. 钩子线程只做吞键判定 + 入队 (关键路径零 Python GIL 风险).
事件: Vk int (真实键) 或合成码 (0xF8 Shift轻拍切换 / 0xF9 Ctrl+`模式 / 0xFA Ctrl+Shift+F繁简 / 0xFB Ctrl+Alt+C造词).
"""
import ctypes
import ctypes.wintypes as w
import queue
import time
import threading

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32

WH_KEYBOARD_LL = 13
WM_KEYDOWN = 0x0100
WM_SYSKEYDOWN = 0x0104
WM_KEYUP = 0x0101
WM_SYSKEYUP = 0x0105
HC_ACTION = 0
LLKHF_INJECTED = 0x10

VK_TOGGLE = 0x77        # F8 (硬开关)
VK_TAP = 0xF8           # 合成: Shift 轻拍
VK_MODE = 0xF9          # 合成: Ctrl+`
VK_TRAD = 0xFA          # 合成: Ctrl+Shift+F
VK_MAKEWORD = 0xFB      # 合成: Ctrl+Alt+C

ACTIVE = [False]        # 输入法是否启用 (小写写入钩子线程判定)

EVENTS = queue.Queue()


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [('vkCode', w.DWORD), ('scanCode', w.DWORD), ('flags', w.DWORD),
                ('time', w.DWORD), ('dwExtraInfo', ctypes.c_ssize_t)]


HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, ctypes.c_size_t, ctypes.c_ssize_t)

# 正确原型 (64 位指针参数必须声明, 否则默认 32 位溢出)
user32.SetWindowsHookExW.restype = ctypes.c_void_p
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, HOOKPROC, ctypes.c_void_p, w.DWORD]
user32.CallNextHookEx.restype = ctypes.c_ssize_t
user32.CallNextHookEx.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_size_t, ctypes.c_ssize_t]
user32.GetMessageW.restype = ctypes.c_int
user32.GetMessageW.argtypes = [ctypes.POINTER(w.MSG), ctypes.c_void_p, w.UINT, w.UINT]
user32.GetKeyState.restype = ctypes.c_short
user32.GetKeyState.argtypes = [ctypes.c_int]


def _is_ime_key(vk):
    if 0x41 <= vk <= 0x5A:
        return True
    if 0x30 <= vk <= 0x39:
        return True
    return vk in (0x20, 0x08, 0x1B, 0x0D, 0xBD, 0xBB, 0xDB, 0xDD, 0xBA)   # space back esc enter - = [ ] ;


def _key_state(vk):
    return (user32.GetKeyState(vk) & 0x8000) != 0


_hook = [None]


def _proc(nCode, wParam, lParam):
    if nCode >= 0:
        kbd = ctypes.cast(lParam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
        # 自家注入 (MAGIC dwExtraInfo) → 直接放行
        if (kbd.flags & LLKHF_INJECTED) and kbd.dwExtraInfo == 0x5747494D:
            return user32.CallNextHookEx(None, nCode, wParam, lParam)
        m = int(wParam)
        vk = int(kbd.vkCode)
        if m == WM_KEYDOWN or m == WM_SYSKEYDOWN:
            if vk == VK_TOGGLE:                            # F8 硬开关: 未激活也可唤醒/关闭
                EVENTS.put(VK_TOGGLE)
                return 1
            if not ACTIVE[0]:                              # 未激活: 完全惰性, 全放行
                return user32.CallNextHookEx(None, nCode, wParam, lParam)
            ctrl = _key_state(0x11)
            shift = _key_state(0x10)
            alt = _key_state(0x12)
            if ctrl and vk == 0xC0:                        # Ctrl+` 模式
                EVENTS.put(VK_MODE)
                return 1
            if ctrl and shift and vk == 0x46:              # Ctrl+Shift+F 繁简
                EVENTS.put(VK_TRAD)
                return 1
            if ctrl and alt and vk == 0x43:                # Ctrl+Alt+C 造词
                EVENTS.put(VK_MAKEWORD)
                return 1
            if vk in (0xA0, 0xA1):                         # Shift down: 记录轻拍起点
                _tap_time[0] = time.time()
                _tap_dirty[0] = False
            else:
                if _tap_time[0] is not None:
                    _tap_dirty[0] = True                   # 有其它键介入, 不算轻拍
                if _is_ime_key(vk):                        # 激活态吞 IME 键
                    EVENTS.put(vk)
                    return 1
        elif m == WM_KEYUP or m == WM_SYSKEYUP:
            if vk in (0xA0, 0xA1):
                if ACTIVE[0] and _tap_time[0] is not None and not _tap_dirty[0] \
                        and time.time() - _tap_time[0] < 0.4:
                    EVENTS.put(VK_TAP)                     # 激活态: Shift 轻拍关闭
                _tap_time[0] = None
    return user32.CallNextHookEx(None, nCode, wParam, lParam)


_tap_time = [None]
_tap_dirty = [True]


def _pump():
    msg = w.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))


def start():
    _hook[0] = HOOKPROC(_proc)
    th = threading.Thread(target=lambda: (user32.SetWindowsHookExW(WH_KEYBOARD_LL, _hook[0], None, 0), _pump()), daemon=True)
    th.start()


def set_active(on):
    ACTIVE[0] = bool(on)


drain = EVENTS.get
