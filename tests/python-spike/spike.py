# wgime-python spike: prove the riskiest assumptions with stdlib only.
# 1) WH_KEYBOARD_LL hook from Python via ctypes (toggle with F8)
# 2) letter keys swallowed while active, pinyin lookup from py.txt
# 3) borderless topmost tkinter candidate bar
# 4) commit candidate 1 via SendInput(UNICODE) on space
# Log: C:\Tools\wgime-py\spike.log
import ctypes, ctypes.wintypes as W, time, os, threading, queue
import tkinter as tk

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'spike.log')
def log(m):
    with open(LOG, 'a', encoding='utf-8') as f:
        f.write('%s %s\n' % (time.strftime('%H:%M:%S.') + '%03d' % (time.time() % 1 * 1000), m))

user32 = ctypes.WinDLL('user32', use_last_error=True)
kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)

WH_KEYBOARD_LL = 13
WM_KEYDOWN = 0x0100
WM_SYSKEYDOWN = 0x0104
HC_ACTION = 0
VK_F8 = 0x77
VK_SPACE = 0x20
VK_BACK = 0x08
VK_ESCAPE = 0x1B

class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [('vkCode', W.DWORD), ('scanCode', W.DWORD), ('flags', W.DWORD), ('time', W.DWORD), ('dwExtraInfo', ctypes.POINTER(ctypes.c_ulong))]

HOOKPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, ctypes.c_int, ctypes.c_size_t, ctypes.c_ssize_t)

# ---------- dict ----------
t0 = time.time()
PY = {}
with open(r'C:\Tools\wgime\py.txt', encoding='utf-8') as f:
    for line in f:
        line = line.strip()
        if not line or ' ' not in line:
            continue
        code, words = line.split(' ', 1)
        PY[code] = words  # first word only for spike
log('py.txt loaded: %d entries in %.0fms' % (len(PY), (time.time() - t0) * 1000))

# ---------- state ----------
active = False
buf = ''
ui_queue = queue.Queue()
root = None
label = None

def commit(text):
    # SendInput UNICODE events
    inp = (INPUT * (len(text) * 2))()
    for i, ch in enumerate(text):
        inp[2 * i].type = 1
        inp[2 * i].ki.wVk = 0
        inp[2 * i].ki.wScan = ord(ch)
        inp[2 * i].ki.dwFlags = 0x0004  # KEYEVENTF_UNICODE
        inp[2 * i + 1].type = 1
        inp[2 * i + 1].ki.wVk = 0
        inp[2 * i + 1].ki.wScan = ord(ch)
        inp[2 * i + 1].ki.dwFlags = 0x0004 | 0x0002  # UNICODE | KEYUP
    user32.SendInput(len(inp), inp, ctypes.sizeof(INPUT))

class KEYBDINPUT(ctypes.Structure):
    _fields_ = [('wVk', W.WORD), ('wScan', W.WORD), ('dwFlags', W.DWORD), ('time', W.DWORD), ('dwExtraInfo', ctypes.POINTER(ctypes.c_ulong))]
class INPUT(ctypes.Structure):
    _fields_ = [('type', W.DWORD), ('ki', KEYBDINPUT), ('pad', ctypes.c_long * 4)]  # pad covers MOUSEINPUT/HARDWAREINPUT union size

def hook_proc(nCode, wParam, lParam):
    global active, buf
    try:
        if nCode == HC_ACTION and wParam in (WM_KEYDOWN, WM_SYSKEYDOWN):
            vk = ctypes.cast(lParam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents.vkCode
            if vk == VK_F8:
                active = not active
                buf = ''
                log('active=%s' % active)
                ui_queue.put(('toggle', active))
                return 1
            if active:
                if 0x41 <= vk <= 0x5A:  # A-Z
                    buf += chr(vk + 32)
                    t = time.time()
                    cand = PY.get(buf, '')
                    dt = (time.time() - t) * 1000
                    log('key buf=%s cand=%s lookup=%.2fms' % (buf, cand[:20], dt))
                    ui_queue.put(('buf', buf, cand))
                    return 1  # swallow
                if vk == VK_BACK and buf:
                    buf = buf[:-1]
                    ui_queue.put(('buf', buf, PY.get(buf, '')))
                    return 1
                if vk == VK_SPACE and buf:
                    cand = PY.get(buf, '')
                    if cand:
                        commit(cand.split(',')[0].split(' ')[0])
                        log('commit %s' % cand[:20])
                    buf = ''
                    ui_queue.put(('buf', '', ''))
                    return 1
                if vk == VK_ESCAPE:
                    buf = ''
                    ui_queue.put(('buf', '', ''))
                    return 1
    except Exception as e:
        log('hook err %r' % e)
    return user32.CallNextHookEx(None, nCode, wParam, lParam)

hook_ref = HOOKPROC(hook_proc)  # keep alive

def hook_thread():
    h = user32.SetWindowsHookExW(WH_KEYBOARD_LL, hook_ref, None, 0)  # LL 钩子必须 hMod=NULL
    log('hook installed: %s' % bool(h))
    msg = W.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))

# ---------- UI (tkinter borderless topmost bar) ----------
def ui_thread():
    global root, label
    root = tk.Tk()
    root.overrideredirect(True)
    root.attributes('-topmost', True)
    root.configure(bg='#E8EDF5')
    label = tk.Label(root, text='spike: F8 开关', bg='white', fg='#1d1d1f', font=('Microsoft YaHei UI', 12), padx=12, pady=6)
    label.pack()
    root.geometry('+400+600')
    def poll():
        try:
            while True:
                item = ui_queue.get_nowait()
                if item[0] == 'toggle':
                    label.config(text='spike: %s' % ('ON' if item[1] else 'OFF'))
                elif item[0] == 'buf':
                    label.config(text=(item[1] + '  ' + item[2][:40]) if item[1] else 'spike: ON')
        except queue.Empty:
            pass
        root.after(30, poll)
    root.after(30, poll)
    root.mainloop()

threading.Thread(target=hook_thread, daemon=True).start()
log('spike started')
ui_thread()
