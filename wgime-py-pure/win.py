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


# ---------- 启动早期用的 Win32 小工具 (不依赖 tkinter) ----------
def message_box(text, title='WgIme', flags=0x40):
    """Win32 消息框 (0x40=信息, 0x30=警告, 0x10=错误). 启动早期/单实例提示用, 不建 tk."""
    try:
        user32.MessageBoxW.restype = ctypes.c_int
        user32.MessageBoxW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p, w.UINT]
        return int(user32.MessageBoxW(None, str(text), str(title), int(flags)))
    except Exception:
        return 0


def single_instance(name):
    """命名互斥体单实例 (对齐 C# WgImeSingleInstance).
    返回句柄(需保持存活到进程结束); 已有实例在跑 -> None; 出错 -> 'error' (不拦启动)."""
    try:
        # 专用 use_last_error=True 的 kernel32: 才能可靠读取 ERROR_ALREADY_EXISTS
        k32 = ctypes.WinDLL('kernel32', use_last_error=True)
        k32.CreateMutexW.restype = ctypes.c_void_p
        k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        k32.CloseHandle.argtypes = [ctypes.c_void_p]
        h = k32.CreateMutexW(None, 1, str(name))
        err = ctypes.get_last_error()
        if not h:
            return 'error'
        if err == 183:                            # ERROR_ALREADY_EXISTS
            k32.CloseHandle(h)
            return None
        return h
    except Exception:
        return 'error'


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
    """全角标点后注入 X 吸收 + Back 擦除 (Qt 应用吞字规避). 按 UTF-16 码元注入, 标点判断仅对 BMP.
    代理对(emoji 等 astral 字符)按 C# UnicodeCommitQtFix **不算 trigger**: 否则每个代理半码都会
    插一对 X+Back, 上屏 emoji 时会带出多余的擦除动作."""
    items = []
    units = text.encode('utf-16-le', 'surrogatepass')
    for i in range(len(units) // 2):
        code = units[2 * i] | (units[2 * i + 1] << 8)
        items.append(('uk', code))
        items.append(('ku', code))
        if 0x3000 <= code <= 0xFFFF and not (0xD800 <= code <= 0xDFFF) \
                and not (0x4E00 <= code <= 0x9FFF) and not (0x3400 <= code <= 0x4DBF) \
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


# ---------- 托盘图标自检 (第四十一轮) ----------
# 起因: 个别机器"双击 .py 启动后哪里都看不到托盘图标"(控制台跑却正常). pystray 完全不检查
# Shell_NotifyIcon 的返回值, 它的错误只写 logging(→ sys.stderr, 而双击时 pythonw 的 stderr 是
# None, 于是**连报错都看不见**). 这里用 Shell_NotifyIconGetRect 反过来问 shell: 这个图标到底
# 登记上没有、是在可见区还是被收进了隐藏溢出区 —— 结果写 debug.log, 失败时直接弹框告诉用户。
class _NIDGUID(ctypes.Structure):
    _fields_ = [('Data1', w.DWORD), ('Data2', w.WORD), ('Data3', w.WORD), ('Data4', ctypes.c_byte * 8)]


class NOTIFYICONIDENTIFIER(ctypes.Structure):
    _fields_ = [('cbSize', w.DWORD), ('hWnd', ctypes.c_void_p), ('uID', w.UINT), ('guidItem', _NIDGUID)]


def tray_promoted(exe_path=None):
    """Windows 11/Server 2025 的"按 exe 记托盘图标显不显示"设置:
    HKCU\\Control Panel\\NotifyIconSettings\\<hash>\\{ExecutablePath, IsPromoted}.
    IsPromoted=1 -> 显示在托盘区; 缺省/0 -> 被收进 ^ 隐藏溢出区 (新机器/新 exe 的默认状态).
    返回 True(显示) / False(隐藏) / None(查不到, 例如 Win10 或还没有这个条目)。"""
    try:
        import winreg
        want = os.path.normcase(exe_path or _sys.executable or '')
        want_base = os.path.basename(want)
        want_stem = os.path.splitext(want_base)[0]
        key = winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Control Panel\NotifyIconSettings')
    except Exception:
        return None
    try:
        i = 0
        seen = None
        while True:
            try:
                sub = winreg.EnumKey(key, i)
            except OSError:
                break
            i += 1
            try:
                k = winreg.OpenKey(key, sub)
                p, _t = winreg.QueryValueEx(k, 'ExecutablePath')
                pb = os.path.normcase(os.path.basename(str(p)))
                ps = os.path.splitext(pb)[0]
                # 精确路径 > 同名 exe > 同"主干"(pythonw.exe vs pythonw3.12.exe —— 微软商店版就是后者)
                if not (os.path.normcase(str(p)) == want or pb == want_base
                        or (want_stem and (ps.startswith(want_stem) or want_stem.startswith(ps)))):
                    continue
                try:
                    v, _t = winreg.QueryValueEx(k, 'IsPromoted')
                except OSError:
                    v = 0
                seen = bool(v)
            except OSError:
                continue
        return seen
    except Exception:
        return None


def icon_from_ico_bytes(data, key):
    """把 ICO 字节落到 runtime 目录并 LoadImage 成 HICON —— **不依赖 Pillow**（第四十二轮）.

    起因: 用户机器（官方 Python 3.14, 没装 Pillow）双击运行时托盘图标完全没有, 因为 python 版的托盘
    以前要在运行时用 PIL 画图标（`from PIL import Image...`）。单文件版现在由构建脚本预渲染好 9 个
    图标（4 模式 × 开/关 + 工具模式）内嵌成 base64, 运行时只写文件 + LoadImage, 于是**不需要宿主装 Pillow**。
    """
    try:
        base = os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~')), 'wgime-py', 'runtime')
        root = os.path.join(base, 'icons')
        try:
            os.makedirs(root, exist_ok=True)
        except Exception:
            root = base
            os.makedirs(root, exist_ok=True)
        path = os.path.join(root, 'wgime-icon-%s.ico' % key)
        need = True
        try:
            if os.path.isfile(path) and os.path.getsize(path) == len(data):
                need = False
        except OSError:
            need = True
        if need:
            with open(path, 'wb') as f:
                f.write(data)
        IMAGE_ICON, LR_LOADFROMFILE = 1, 0x10
        user32.LoadImageW.restype = ctypes.c_void_p
        user32.LoadImageW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, w.UINT,
                                      ctypes.c_int, ctypes.c_int, w.UINT]
        h = user32.LoadImageW(None, path, IMAGE_ICON, 0, 0, LR_LOADFROMFILE)
        return int(h) if h else None
    except Exception as e:
        _dlog('icon_from_ico_bytes(%s) err %r' % (key, e))
        return None


def notify_icon_rect(hwnd, uid=1):
    """问 shell 托盘图标状态. 返回 (state, rect):
    'visible'  已登记且在工作区可见 (S_OK, rect 有效)
    'overflow' 已登记但被收进隐藏溢出区 (S_FALSE) —— 用户得点 ^ 或去设置里打开
    'missing'  shell 里没有这个图标 (E_FAIL 等) —— 图标压根没加上去
    'unknown'  取不到状态 (老系统没有这个 API / 异常)
    """
    try:
        nid = NOTIFYICONIDENTIFIER(ctypes.sizeof(NOTIFYICONIDENTIFIER),
                                   ctypes.c_void_p(int(hwnd)), int(uid), _NIDGUID())
        rc = RECT()
        f = ctypes.windll.shell32.Shell_NotifyIconGetRect
        f.argtypes = [ctypes.POINTER(NOTIFYICONIDENTIFIER), ctypes.POINTER(RECT)]
        f.restype = ctypes.c_long
        hr = f(ctypes.byref(nid), ctypes.byref(rc))
        if hr == 0:
            return 'visible', (rc.left, rc.top, rc.right, rc.bottom)
        if hr == 1:                       # S_FALSE: 在隐藏溢出区
            return 'overflow', None
        return 'missing', None
    except Exception as e:
        _dlog('notify_icon_rect err %r' % (e,))
        return 'unknown', None


_last_caret = [None]
_last_caret_source = ['none']   # 'caret' | 'mouse' | 'last' | 'fallback' | 'focus' | 'uia'
# caret 抖动检测: 记录最近几次 GUITI caret, 若方向反复横跳/大幅摆动则判不可信(浏览器等自绘应用),
# 避免候选窗"跳舞". 用 deque 环形.
import collections as _col
_guiti_hist = _col.deque(maxlen=5)

# ---------------- 独立 Caret Helper IPC ----------------
# 主输入法绝不初始化 COM/UIA。所有 UIA 调用均在 wgime-caret-helper.py 子进程。
import subprocess as _sp, threading as _th, json as _json, time as _time, sys as _sys
_uia_el=[None]; _uia_fg=[0]; _uia_t=[0.0]; _uia_disabled=[False]
_ipc_proc=[None]; _ipc_started=[False]; _ipc_id=[0]; _ipc_done=[0]; _ipc_lock=_th.Lock(); _ipc_last_start=[0.0]
_helper_t0=[0.0]; _helper_fail=[0]         # helper 启动时刻 / 连续秒退计数 (见 _start_helper/_ipc_reader)
# 第四十轮修: 下面这两个全局量原来被写进了上一行的**行尾注释**里 (「...; _ipc_req_hwnd={}; _last_fg=[0]」),
# 于是从未真正执行 —— request_caret_refresh() 里 `_ipc_req_hwnd[rid]=hwnd` 抛 NameError, 被它自己的
# `except Exception` 吞掉后 **p.kill() 把 helper 杀掉** (表现为每打一个字就杀/重启一个 python 子进程,
# UIA 跟随完全失效, `_helper_fail` 三次后干脆不再起 helper); get_caret_pos() 第一行的 `_last_fg[0]`
# 同样 NameError 直接抛出去 -> 首次候选窗定位失败。两者都只在 debug.log 里留一行, 极易漏掉。
_ipc_req_hwnd={}                           # rid -> 请求时的前台 hwnd (回包校验用)
_last_fg=[0]                               # 上次的前台窗口 (变了就清 caret 缓存)
_EMBEDDED_CARET_HELPER = '# -*- coding: utf-8 -*-\n"""WgIme Caret Helper. UIA lives only in this process. JSONL stdin/stdout IPC."""\nimport ctypes, ctypes.wintypes as w, json, os, sys, time, traceback\nLOG=os.path.join(os.environ.get(\'LOCALAPPDATA\',os.path.expanduser(\'~\')),\'wgime-py\',\'caret-helper.log\')\ndef log(s):\n    if os.environ.get(\'WGIME_DEBUG\',\'\')!=\'1\':return\n    try:\n        os.makedirs(os.path.dirname(LOG),exist_ok=True)\n        with open(LOG,\'a\',encoding=\'utf-8\') as f:f.write(\'%.3f [helper:%d] %s\\n\'%(time.time(),os.getpid(),s))\n    except Exception: pass\ndef emit(o):\n    sys.stdout.write(json.dumps(o,ensure_ascii=False,separators=(\',\',\':\'))+\'\\n\');sys.stdout.flush()\nclass GUID(ctypes.Structure):\n    _fields_=[(\'Data1\',w.DWORD),(\'Data2\',w.WORD),(\'Data3\',w.WORD),(\'Data4\',ctypes.c_ubyte*8)]\ndef guid(s):\n    g=GUID();hr=ctypes.windll.ole32.CLSIDFromString(s,ctypes.byref(g))\n    if hr<0:raise OSError(\'CLSIDFromString 0x%08X\'%(hr&0xffffffff))\n    return g\nCLSID=guid(\'{FF48DBA4-60EF-4201-AA87-54103EEF594E}\')\nIID_AUTO=guid(\'{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}\')\nIID_TP2=guid(\'{506A921A-FCC9-409F-B23B-37EB74106872}\')\nIID_TP=guid(\'{32EBA289-3583-42C9-9C59-3B6D9A1E9B6A}\')\nole32=ctypes.OleDLL(\'ole32\');oa=ctypes.OleDLL(\'oleaut32\')\nole32.CoInitializeEx.argtypes=[ctypes.c_void_p,w.DWORD];ole32.CoInitializeEx.restype=ctypes.c_long\nole32.CoCreateInstance.argtypes=[ctypes.POINTER(GUID),ctypes.c_void_p,w.DWORD,ctypes.POINTER(GUID),ctypes.POINTER(ctypes.c_void_p)];ole32.CoCreateInstance.restype=ctypes.c_long\ndef pv(p):\n    try:return int(p.value or 0) if hasattr(p,\'value\') else int(p or 0)\n    except:return 0\ndef call(p,i,rt,args,*xs):\n    v=ctypes.cast(p,ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents\n    addr=pv(v[i]);log(\'call i=%d obj=0x%X method=0x%X\'%(i,pv(p),addr))\n    if addr<0x10000:raise OSError(\'bad method %d 0x%X\'%(i,addr))\n    return ctypes.WINFUNCTYPE(rt,ctypes.c_void_p,*args)(addr)(p,*xs)\ndef release(p):\n    if pv(p):\n        try:call(p,2,w.ULONG,[])\n        except:pass\ndef rect(rng,pattern):\n    psa=ctypes.c_void_p();hr=call(rng,10,ctypes.c_long,[ctypes.POINTER(ctypes.c_void_p)],ctypes.byref(psa))\n    log(\'%s GetBoundingRectangles hr=0x%08X psa=0x%X\'%(pattern,hr&0xffffffff,pv(psa)))\n    if hr<0 or not psa.value:return None\n    lo=ctypes.c_long();hi=ctypes.c_long();data=ctypes.c_void_p();access=False\n    try:\n        if oa.SafeArrayGetLBound(psa,1,ctypes.byref(lo))<0 or oa.SafeArrayGetUBound(psa,1,ctypes.byref(hi))<0:return None\n        n=hi.value-lo.value+1\n        if n<4 or n>4096 or oa.SafeArrayAccessData(psa,ctypes.byref(data))<0:return None\n        access=True;v=ctypes.cast(data,ctypes.POINTER(ctypes.c_double));raw=[float(v[i]) for i in range(n)]\n        x,y,cw,ch=raw[-4:];log(\'%s raw=%r\'%(pattern,raw[:24]))\n        if ch<1 or ch>240 or x<-10000 or y<-10000:return None\n        return {\'x\':round(x),\'y\':round(y+ch),\'rect\':[x,y,cw,ch],\'raw\':raw[:24],\'provider\':pattern}\n    finally:\n        if access:\n            try:oa.SafeArrayUnaccessData(psa)\n            except:pass\n        try:oa.SafeArrayDestroy(psa)\n        except:pass\ndef try_element(el,label):\n    pat=ctypes.c_void_p();rng=ctypes.c_void_p();arr=ctypes.c_void_p()\n    try:\n        log(\'PROBE %s el=0x%X\'%(label,pv(el)))\n        hr=call(el,14,ctypes.c_long,[ctypes.c_int,ctypes.POINTER(GUID),ctypes.POINTER(ctypes.c_void_p)],10024,ctypes.byref(IID_TP2),ctypes.byref(pat))\n        log(\'%s TP2 hr=0x%08X pat=0x%X\'%(label,hr&0xffffffff,pv(pat)))\n        if hr>=0 and pat.value:\n            active=w.BOOL();hr2=call(pat,10,ctypes.c_long,[ctypes.POINTER(w.BOOL),ctypes.POINTER(ctypes.c_void_p)],ctypes.byref(active),ctypes.byref(rng))\n            log(\'%s GetCaretRange hr=0x%08X active=%d rng=0x%X\'%(label,hr2&0xffffffff,active.value,pv(rng)))\n            if hr2>=0 and active.value and rng.value:\n                p=rect(rng,\'TextPattern2\')\n                if p:p[\'element_path\']=label;return p\n            release(rng);rng=ctypes.c_void_p();release(pat);pat=ctypes.c_void_p()\n        hr=call(el,14,ctypes.c_long,[ctypes.c_int,ctypes.POINTER(GUID),ctypes.POINTER(ctypes.c_void_p)],10014,ctypes.byref(IID_TP),ctypes.byref(pat))\n        log(\'%s TP hr=0x%08X pat=0x%X\'%(label,hr&0xffffffff,pv(pat)))\n        if hr<0 or not pat.value:return None\n        hr=call(pat,3,ctypes.c_long,[ctypes.POINTER(ctypes.c_void_p)],ctypes.byref(arr))\n        log(\'%s GetSelection hr=0x%08X arr=0x%X\'%(label,hr&0xffffffff,pv(arr)))\n        if hr<0 or not arr.value:return None\n        n=ctypes.c_int();hr=call(arr,3,ctypes.c_long,[ctypes.POINTER(ctypes.c_int)],ctypes.byref(n))\n        if hr<0 or n.value<1:return None\n        hr=call(arr,4,ctypes.c_long,[ctypes.c_int,ctypes.POINTER(ctypes.c_void_p)],0,ctypes.byref(rng))\n        if hr<0 or not rng.value:return None\n        p=rect(rng,\'TextPattern\')\n        if p:p[\'element_path\']=label\n        return p\n    finally:release(rng);release(arr);release(pat)\n_FAIL_UNTIL={}\nFAIL_COOLDOWN_S=8.0\n\ndef query(auto,hwnd):\n    now=time.monotonic()\n    until=_FAIL_UNTIL.get(hwnd,0.0)\n    if now<until:\n        return None,\'ProviderCooldown\',0\n    el=ctypes.c_void_p()\n    try:\n        hr=call(auto,8,ctypes.c_long,[ctypes.POINTER(ctypes.c_void_p)],ctypes.byref(el))\n        log(\'GetFocusedElement hwnd=%d hr=0x%08X el=0x%X\'%(hwnd,hr&0xffffffff,pv(el)))\n        if hr<0 or not el.value:\n            _FAIL_UNTIL[hwnd]=now+FAIL_COOLDOWN_S\n            return None,\'GetFocusedElement\',hr\n        p=try_element(el,\'focus\')\n        if p:\n            _FAIL_UNTIL.pop(hwnd,None)\n            return p,\'focus\',0\n        # The focused provider does not expose a usable caret. Do not scan the whole\n        # WebView tree on every keystroke. The main process keeps a per-window anchor.\n        _FAIL_UNTIL[hwnd]=time.monotonic()+FAIL_COOLDOWN_S\n        log(\'NO_CARET_PROVIDER hwnd=%d cooldown=%.1fs\'%(hwnd,FAIL_COOLDOWN_S))\n        return None,\'NoCaretProvider\',0\n    finally:\n        release(el)\ndef main():\n    hr=ole32.CoInitializeEx(None,0);log(\'START CoInitializeEx=0x%08X\'%(hr&0xffffffff));auto=ctypes.c_void_p()\n    try:\n        hr2=ole32.CoCreateInstance(ctypes.byref(CLSID),None,1,ctypes.byref(IID_AUTO),ctypes.byref(auto));log(\'CoCreateInstance=0x%08X auto=0x%X\'%(hr2&0xffffffff,pv(auto)))\n        if hr2<0 or not auto.value:return 2\n        emit({\'type\':\'ready\',\'pid\':os.getpid(),\'mode\':\'stable-focus-cooldown\',\'cooldown_s\':FAIL_COOLDOWN_S})\n        for line in sys.stdin:\n            try:\n                q=json.loads(line);rid=int(q.get(\'id\',0));t=time.perf_counter();p,stage,h=query(auto,int(q.get(\'hwnd\',0)));ms=(time.perf_counter()-t)*1000\n                o={\'type\':\'result\',\'id\':rid,\'ok\':bool(p),\'stage\':stage,\'hr\':\'0x%08X\'%(h&0xffffffff),\'elapsed_ms\':round(ms,2),\'pid\':os.getpid(),\'hwnd\':int(q.get(\'hwnd\',0))}\n                if p:o.update(p)\n                emit(o)\n            except BaseException as e:\n                log(\'QUERY EXC \'+repr(e)+\' \'+traceback.format_exc());emit({\'type\':\'result\',\'id\':q.get(\'id\',0) if \'q\' in locals() else 0,\'ok\':False,\'stage\':\'exception\',\'error\':repr(e),\'pid\':os.getpid(),\'hwnd\':int(q.get(\'hwnd\',0))})\n    finally:\n        release(auto)\n        try:ole32.CoUninitialize()\n        except:pass\nif __name__==\'__main__\':raise SystemExit(main())\n'
def _legacy_helper_path():
    """旧版(第四十二轮及以前)把 helper 源码落盘到这个 .py 文件. 现在改用 `python -c` 直接把源码
    喂给子进程, **磁盘上不再产生 caret-helper 文件**; 此路径只为清理历史遗留文件而保留."""
    base=os.path.join(os.environ.get('LOCALAPPDATA',os.path.expanduser('~')),'wgime-py','runtime')
    return os.path.join(base,'caret-helper','wgime-caret-helper-v3-stable-embedded.py')

def _cleanup_legacy_helper():
    """删掉旧版落盘的 helper 文件(不再需要). 只删这一个确切文件名, best-effort, 失败无妨."""
    try:
        p=_legacy_helper_path()
        if os.path.isfile(p):
            os.remove(p)
            _dlog('legacy on-disk helper removed '+p)
    except Exception as e:
        _dlog('legacy helper cleanup skipped '+repr(e))

# helper 源码直接经 `python -c` 传给子进程(不落盘): 7200 字符 << Windows 命令行上限 32767.
# 隔离: `-c` 下 sys.path[0] 是**当前工作目录**, 先剥掉 —— 保持第三十八轮那条"标准库不被抢占"的
# 隔离(历史 lib 目录里残留过 pythonnet 时代的 python38 整包, _ctypes.pyd/json.py 会顶掉标准库,
# 害得 helper 起来就秒退). helper 只用标准库, 剥掉 cwd 无副作用.
_HELPER_PATH_SANITIZE=("import sys as _wgs,os as _wgo\n"
                        "_wgs.path[:]=[p for p in _wgs.path if p not in ('','.',_wgo.getcwd())]\n")
def _ipc_reader(proc):
    try:
        for line in proc.stdout:
            try:
                o=_json.loads(line); _dlog('IPC recv '+repr(o))
                if o.get('type')!='result':continue
                rid=int(o.get('id',0));_ipc_done[0]=max(_ipc_done[0],rid)
                expected=_ipc_req_hwnd.pop(rid,None);current=int(user32.GetForegroundWindow())
                if o.get('ok') and expected is not None and int(o.get('hwnd',0))==expected and current==expected and rid>=_ipc_id[0]-1:
                    _uia_el[0]=(int(o['x']),int(o['y']));_uia_fg[0]=expected;_uia_t[0]=_time.monotonic()
                elif o.get('ok'):_dlog('IPC stale reject id=%d expected=%r current=%r result=%r'%(rid,expected,current,o.get('hwnd')))
            except Exception as e:_dlog('IPC parse error '+repr(e))
    finally:
        _dlog('IPC helper exited rc=%r'%(proc.poll(),));
        _alive=_time.monotonic()-_helper_t0[0]
        if _alive<3.0:                       # 秒退: 记一次失败, 连续 3 次后本进程不再重试 (回退 Win32 跟随)
            _helper_fail[0]+=1
            _dlog('IPC helper died after %.2fs (fail #%d/3)'%(_alive,_helper_fail[0]))
        else:
            _helper_fail[0]=0
        if _ipc_proc[0] is proc:_ipc_proc[0]=None
        _ipc_started[0]=False
        _uia_el[0]=None

def _start_helper():
    if _ipc_proc[0] is not None and _ipc_proc[0].poll() is None:return True
    if _helper_fail[0]>=3:                     # 连续秒退 3 次: 本进程不再 spawn (每次按键起一个 python 太浪费)
        return False
    now=_time.monotonic()
    if now-_ipc_last_start[0]<1.0:return False
    _ipc_last_start[0]=now
    try:
        flags=getattr(_sp,'CREATE_NO_WINDOW',0)
        # 源码内联: 不再把 helper 落盘成 .py, 子进程直接从命令行拿到源码(实测 spawn 137ms 出 ready).
        src=_HELPER_PATH_SANITIZE+_EMBEDDED_CARET_HELPER
        p=_sp.Popen([_sys.executable,'-u','-c',src],stdin=_sp.PIPE,stdout=_sp.PIPE,stderr=_sp.DEVNULL,text=True,encoding='utf-8',bufsize=1,creationflags=flags)
        _ipc_proc[0]=p;_ipc_started[0]=True;_helper_t0[0]=_time.monotonic()
        _th.Thread(target=_ipc_reader,args=(p,),name='WgImeCaretIPC',daemon=True).start()
        _dlog('IPC helper started pid=%d (inline -c, no file on disk)'%p.pid);return True
    except Exception as e:_dlog('IPC start failed '+repr(e));return False

def ensure_caret_bg():
    _cleanup_legacy_helper()                   # 清掉旧版落盘的 helper .py (已废弃)
    _start_helper()
def request_caret_refresh(reason='candidate'):
    if not _start_helper():return 0
    with _ipc_lock:
        _ipc_id[0]+=1;rid=_ipc_id[0];p=_ipc_proc[0]
        try:
            hwnd=int(user32.GetForegroundWindow());_ipc_req_hwnd[rid]=hwnd
            p.stdin.write(_json.dumps({'id':rid,'reason':reason,'hwnd':hwnd,'t':_time.time()},separators=(',',':'))+'\n');p.stdin.flush()
            _dlog('IPC send id=%d reason=%s'%(rid,reason));return rid
        except Exception as e:
            _dlog('IPC send failed '+repr(e));
            try:p.kill()
            except:pass
            return 0
def get_precise_caret_cache(max_age=0.8):
    if _uia_el[0] is not None and _uia_fg[0]==user32.GetForegroundWindow() and _time.monotonic()-_uia_t[0]<=max_age:return _uia_el[0]
    return None

def get_ipc_caret():
    """Return only the newest helper coordinate for the current foreground window."""
    fg=int(user32.GetForegroundWindow())
    if _uia_el[0] is not None and _uia_fg[0]==fg:
        return _uia_el[0]
    return None

def get_caret_pos():
    # Recovery v2 keeps keyboard/input path simple and deterministic.
    """光标屏幕坐标(主线程, 绝不阻塞). 顺序: UIA缓存(首选,后台刷新) -> GetGUIThreadInfo ->
    聚焦输入框矩形 -> 输入感知鼠标 -> 上次有效位 -> 前台窗口底部. UIA 不可用时自动回退纯 Win32."""
    import time as _t
    _t0 = _t.time()
    fg_now=int(user32.GetForegroundWindow())
    if _last_fg[0]!=fg_now:
        _last_fg[0]=fg_now;_last_caret[0]=None;_uia_el[0]=None;_guiti_hist.clear()
        _dlog('foreground changed: cleared caret caches hwnd=%s'%fg_now)
    # UIA 缓存(后台线程刷新的精确 caret)首选; 主线程只读缓存, 绝不在此跑 UIA.
    if not _uia_disabled[0] and _uia_el[0] is not None:
        # UIA 缓存只在"前台窗口未变"时可靠(后台线程按前台刷新). 前台已变(刚切换应用)时缓存是旧窗口的
        # 坐标, 用它会让候选窗先跳到旧位置再跳回来(表现为"刚输入就跳"). 故前台变时忽略缓存, 走下去用 GUITI.
        if _uia_fg[0] == user32.GetForegroundWindow():
            _last_caret_source[0] = 'uia'
            _dlog('get_caret_pos: UIA-cache(%.1fms) -> %s' % ((_t.time()-_t0)*1000, _uia_el[0]))
            return _uia_el[0]
    try:
        fg = user32.GetForegroundWindow()
        tid = user32.GetWindowThreadProcessId(fg, None)
        g = GUITHREADINFO()
        g.cbSize = ctypes.sizeof(GUITHREADINFO)
        ok = bool(user32.GetGUIThreadInfo(tid, ctypes.byref(g)))
        # 宽容判定(对齐 C# TryGetCaretScreenRect): 只要 hwndCaret 存在就采纳, 用 rcCaret.top 定位,
        # 容忍退化 caret(某些 Electron/Qt 给的是 2x2/零尺寸, 但 (x,y) 真实跟踪光标).
        if ok and g.hwndCaret:
            pt = POINT(g.rcCaret.left, g.rcCaret.top)
            user32.ClientToScreen(g.hwndCaret, ctypes.byref(pt))
            # 防最小化坐标(-32000)与越界.
            if pt.x > -10000 and pt.y > -10000:
                cand = (pt.x, pt.y)
                # 抖动检测: 若 caret 在历史里大幅往返/摆动(方向反复, 或单帧大幅跳), 判不可信,
                # 退回鼠标. 真光标通常原地或小幅单向移动, 不会剧烈横跳.
                if _caret_jittery(cand):
                    _dlog('get_caret_pos: GUITI jittery reject cand=%s' % (cand,))
                else:
                    _last_caret[0] = cand
                    _last_caret_source[0] = 'caret'
                    _dlog('get_caret_pos: GUITI ok(%.1fms) hwndCaret=%s rc=(%d,%d,%d,%d) -> %s' % (
                        (_t.time()-_t0)*1000, bool(g.hwndCaret),
                        g.rcCaret.left, g.rcCaret.top, g.rcCaret.right, g.rcCaret.bottom, cand))
                    return cand
            _dlog('get_caret_pos: GUITI degenerate(minimized?) hwndCaret=%s pt=(%d,%d)' % (
                bool(g.hwndCaret), pt.x, pt.y))
        else:
            _dlog('get_caret_pos: GUITI fail(%.1fms) ok=%s hwndCaret=%s rcCaret=(%d,%d,%d,%d) fg=%s' % (
                (_t.time()-_t0)*1000, ok, bool(g.hwndCaret),
                g.rcCaret.left, g.rcCaret.top, g.rcCaret.right, g.rcCaret.bottom, fg))
    except Exception as e:
        _dlog('get_caret_pos: GUITI exc(%.1fms) %s' % ((_t.time()-_t0)*1000, repr(e)))
    # GUITI 无 caret: 尝试聚焦输入框矩形(纯 Win32, 很多现代应用的文本控件是真 HWND).
    fr = _focus_edit_rect()
    if fr is not None:
        _last_caret_source[0] = 'focus'
        _dlog('get_caret_pos: focus-edit(%.1fms) -> %s' % ((_t.time()-_t0)*1000, fr))
        return fr
    # Recovery v2: mouse fallback is intentionally disabled.
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


def _caret_jittery(cand):
    """判断 GUITI caret 候选是否"抖动/漂移"不可信. 若候选相对历史位置大幅往返(单帧跳变大且方向
    反复), 视为自绘应用的噪声(浏览器 etc), 返回 True -> 调用方退回鼠标. 真光标移动幅度小且方向一致."""
    _guiti_hist.append(cand)
    if len(_guiti_hist) < 2:
        return False
    # 连续两帧的位移
    prev = _guiti_hist[-2]
    dx = cand[0] - prev[0]
    dy = cand[1] - prev[1]
    import math as _m
    dist = _m.hypot(dx, dy)
    if dist > 120:      # 单帧跳超 120px(跨越整屏跳动), 很像噪声
        return True
    # 看最近 3 帧是否方向反复(先右后左 / 先上后下 来回横跳)
    if len(_guiti_hist) >= 3:
        p0 = _guiti_hist[-3]
        d1 = (cand[0] - prev[0], cand[1] - prev[1])
        d2 = (prev[0] - p0[0], prev[1] - p0[1])
        # x 方向或 y 方向出现明显反向(>40px) => 横跳
        if (d1[0] > 40 and d2[0] < -40) or (d1[0] < -40 and d2[0] > 40):
            return True
        if (d1[1] > 30 and d2[1] < -30) or (d1[1] < -30 and d2[1] > 30):
            return True
    return False


def _focus_edit_rect():
    """取当前聚焦窗口(GetFocus)的屏幕矩形, 作为"输入框"位置的近似. 纯 Win32(不依赖 UIA):
    很多现代应用(Chrome/部分 Electron 对话框)的文本控件是真实 HWND, GetWindowRect 能拿到其
    位置, 比鼠标更贴近输入框. 若能拿到且矩形合理(非全屏/非空), 返回 (x, y) 光标近似点."""
    try:
        hwnd = user32.GetFocus()
        if not hwnd:
            return None
        r = RECT()
        if not user32.GetWindowRect(hwnd, ctypes.byref(r)):
            return None
        w = r.right - r.left
        h = r.bottom - r.top
        # 合理输入框: 宽 > 40, 高 8~90, 且不是全屏.
        if w > 40 and 8 <= h <= 90 and w < 4000:
            # 用输入框左边缘下方作为候选窗锚点(贴近光标列/行).
            return r.left + 12, r.top + h // 2
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


def shell_execute(path, args='', cwd=None):
    """ShellExecuteW 'open' (对齐 C# `ProcessStartInfo { UseShellExecute = true }` + `Arguments`):
    exe / 相对或绝对路径 / 文件夹 / URL 都能启动, 且参数**不经过 cmd.exe**(避免 & ^ % 被 shell 解释)。
    返回是否成功 (ShellExecuteW > 32 视为成功)。"""
    try:
        shell32 = ctypes.windll.shell32
        shell32.ShellExecuteW.restype = ctypes.c_ssize_t
        shell32.ShellExecuteW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p,
                                          ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_int]
        r = shell32.ShellExecuteW(None, 'open', str(path), (str(args) or None),
                                  (str(cwd) if cwd else None), 1)      # SW_SHOWNORMAL
        return int(r) > 32
    except Exception:
        return False


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
