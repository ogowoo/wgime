import ctypes, ctypes.wintypes as W
user32 = ctypes.WinDLL('user32', use_last_error=True)
kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_long, ctypes.c_int, W.WPARAM, W.LPARAM)
def proc(n, w, l):
    return user32.CallNextHookEx(None, n, w, l)
cb = HOOKPROC(proc)
h = user32.SetWindowsHookExW(13, cb, kernel32.GetModuleHandleW(None), 0)
print('hmod=%s hook=%s err=%s' % (kernel32.GetModuleHandleW(None), h, ctypes.get_last_error()))
# retry with NULL hmod
h2 = user32.SetWindowsHookExW(13, cb, None, 0)
print('null-hmod hook=%s err=%s' % (h2, ctypes.get_last_error()))
