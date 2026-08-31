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


def _early_neutralize_uia():
    """在 win 模块加载时就彻底中和 comtypes 的 typelib 版本校验 + uiautomation 的黄字日志.
    不依赖任何时序(无需等 uiautomation import): 直接打补丁到 comtypes._tlib_version_checker
    及 uiautomation.Logger, 让 _check_version 恒通过, 并吞掉 'Can not load UIAutomationCore.dll'
    这类只吓人不致命的日志."""
    try:
        import comtypes._tlib_version_checker as _tvc
        _tvc._check_version = lambda *a, **kw: None
    except Exception:
        pass
    try:
        import comtypes.gen
        try:
            import sys as _s
            for _k in list(_s.modules):
                if _k.startswith('comtypes.gen.'):
                    try:
                        _s.modules[_k].__dict__['_check_version'] = lambda *a, **kw: None
                    except Exception:
                        pass
        except Exception:
            pass
    except Exception:
        pass
    try:
        import uiautomation.uiautomation as _uu
        if hasattr(_uu, 'Logger') and hasattr(_uu.Logger, 'WriteLine'):
            _real_wl = _uu.Logger.WriteLine
            def _quiet(*a, **kw):
                try:
                    if a and 'UIAutomationCore' in str(a[0]):
                        return                      # 吞掉 Can not load UIAutomationCore.dll 类提示
                except Exception:
                    pass
                return _real_wl(*a, **kw)
            _uu.Logger.WriteLine = _quiet
    except Exception:
        pass


# 顶层立即中和(单文件 via _load('win') 时即生效), 早于任何 uiautomation 使用.
_early_neutralize_uia()


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
_uia = [None]
# UIA 代价高(Teams 等 Electron 应用尤其慢): GetFocusedControl 一次可达几十~上百 ms.
# 加节流 + 复用元素, 避免每个 poll(15ms)都重做整套 UIA, 否则光标跟随会卡住 IME 主循环.
_uia_t = [0.0]        # 上次真正执行 UIA 检索的时间
_uia_el = [None]      # 缓存聚焦元素 + TextPattern(短 TTL 复用, GetSelection 每次仍重取当前选区)
_uia_fg = [0]         # 缓存时的前台 hwnd, 防止跨窗口复用过期元素
# 记录 UIA 库是否已确认加载失败, 避免每次调用都重复尝试 import (导入本身也慢)
_uia_import_broken = [False]


def _uia_retry_client(auto):
    """GetFocusedControl 首次失败(comtypes typelib 版本校验在 _AutomationClient 单例构造时抛,
    uiautomation 会在 stderr 打 'Can not load UIAutomationCore.dll' 黄字)时调用:
    重置单例(_instance=None), 触发重新构造——此时 _check_version 已被 _import_uia_robust 打成
    no-op, 重试即成功; 返回 el 或 None."""
    try:
        import uiautomation.uiautomation as _uu
        if hasattr(_uu, '_AutomationClient'):
            try:
                _uu._AutomationClient._instance = None
            except Exception:
                pass
        import time as _t
        _t.sleep(0.02)
        return auto.GetFocusedControl()
    except BaseException:
        return None


def _neutralize_uia_check_version():
    """把 comtypes.gen 里 UIAutomationClient/wrapper 模块的 _check_version 绑定名覆盖成 no-op.
    生成模块内部的 _check_version('1.4.16', <mtime>) 用 LOAD_GLOBAL 读模块 __dict__,
    **覆盖 __dict__['_check_version'] 即可直接让该调用不抛**(无论模块何时被 import),
    从而绕开 comtypes 的 "Typelib different than module" mtime 误判."""
    import sys
    for k in list(sys.modules):
        if not (k.startswith('comtypes.gen.') and ('UIAutomation' in k or '944DE083' in k)):
            continue
        try:
            sys.modules[k].__dict__['_check_version'] = lambda *a, **kw: None
        except Exception:
            pass
    # 也覆盖 comtypes._tlib_version_checker 模块属性(首层导入时用)
    try:
        from comtypes import _tlib_version_checker as _tvc
        _tvc._check_version = lambda *a, **kw: None
    except Exception:
        pass


def _force_zip_uia():
    """确保 comtypes/uiautomation 从我们内嵌的 thirdparty.zip 加载, 而不是用户 pip 装的
    site-packages 版(生产机若 pip 装了 uiautomation/comtypes, site-packages 可能抢在前面,
    那样我们的 _check_version 补丁(打在 zip comtypes 上)就完全无效——这正是生产机报
    'Typelib different than module' 的真正原因). 若 comtypes/uiautomation 已从别处加载,
    把它们从 sys.modules 清掉, 并让 zip 的路径排在 site-packages 前, 再重导."""
    import sys
    # 找我们内嵌的 thirdparty.zip 的路径(单文件 preamble 已 insert(0) 进 sys.path)
    zip_paths = [p for p in sys.path if p and p.lower().endswith('thirdparty.zip')]
    if not zip_paths:
        return
    zip_path = zip_paths[0]
    try:
        import comtypes
        cur = getattr(comtypes, '__file__', '') or ''
        if 'thirdparty.zip' not in cur:
            # 当前加载的不是我们的 zip 版 -> 清出 sys.modules 强制重导
            for k in list(sys.modules):
                if k == 'comtypes' or k.startswith('comtypes.') or k == 'uiautomation' or k.startswith('uiautomation.'):
                    del sys.modules[k]
            # 把 zip 顶到最前, 并剔除 comtypes/uiautomation 的 site-packages 目录影响
            if zip_path in sys.path:
                sys.path.remove(zip_path)
            sys.path.insert(0, zip_path)
    except Exception:
        pass


def _import_uia_robust():
    """稳健导入 uiautomation. comtypes 在 typelib 版本不匹配时会抛
    ImportError("Typelib different than module")——根因: 我们 zip 内嵌的
    comtypes.gen.UIAutomationClient 里烘焙了生成时的 UIAutomationCore.dll mtime
    (如 _check_version('1.4.16', <mtime>)), 用户机上该 DLL 的 mtime 与烘焙值相差>=1s
    就抛错. 这里在导入 uiautomation 前把 comtypes._tlib_version_checker._check_version
    打成 no-op, 并在导入后覆盖 comtypes.gen 各 UIAutomation 模块 __dict__ 的 _check_version
    绑定名——双保险, 顺序无关, 让跟随在这些机器上稳定工作."""
    if _uia_import_broken[0]:
        return None
    # 关键: 确保用的是我们内嵌 zip 的 comtypes/uiautomation, 而非用户 pip 装的 site-packages 版
    _force_zip_uia()
    # 首层打补丁: 让 _check_version 不再因 mtime 差异拒绝已生成的 typelib 模块
    try:
        from comtypes import _tlib_version_checker as _tvc
        _tvc._check_version = lambda *a, **k: None
    except Exception:
        pass
    try:
        import uiautomation as auto
        _neutralize_uia_check_version()
        return auto
    except KeyboardInterrupt:
        raise
    except BaseException:
        pass
    # 仍失败: 清 comtypes.gen 缓存模块, 强制内存里重新生成一次
    try:
        import sys
        for k in list(sys.modules):
            if k.startswith('comtypes.gen.') and ('UIAutomation' in k or '944DE083' in k):
                del sys.modules[k]
        import comtypes.gen
        for a in [a for a in dir(comtypes.gen) if 'UIAutomation' in a or '944DE083' in a]:
            try:
                delattr(comtypes.gen, a)
            except Exception:
                pass
        for _gp in getattr(comtypes.gen, '__path__', []):
            try:
                if os.path.isdir(_gp):
                    for _fn in os.listdir(_gp):
                        if 'UIAutomation' in _fn or '944DE083' in _fn:
                            try:
                                os.remove(os.path.join(_gp, _fn))
                            except OSError:
                                pass
            except Exception:
                pass
    except Exception:
        pass
    try:
        import uiautomation as auto
        _neutralize_uia_check_version()
        return auto
    except KeyboardInterrupt:
        raise
    except BaseException:
        _uia_import_broken[0] = True
        return None
    finally:
        pass


def get_caret_uia(max_age=0.15):
    """UI Automation 光标 (现代应用 Edge/Explorer/Office, GetGUIThreadInfo 探测不到时).
    带节流: 在 max_age 秒内复用上次聚焦控件/选区, 只返回缓存的屏幕位, 不重复 UIA COM 往返.
    若前台窗口变了则立即重新检索. 失败(返回 None)也记录尝试时间, 让"Teams UIA 拿不到光标"
    这种高频失败同样被节流, 不再每键都跑整套 UIA."""
    import time
    try:
        now = time.time()
        fg = user32.GetForegroundWindow()
        if fg == _uia_fg[0]:
            # 同一前台窗口(无论上次成功与否): 在 max_age 内都复用上次结果, 不重跑 UIA
            if _uia_el[0] is not None and (now - _uia_t[0]) < max_age:
                return _uia_el[0]
            if (now - _uia_t[0]) < max_age:
                return None          # 上次失败且仍在节流窗口内 -> 直接算失败, 不重跑 UIA
        # 到了节流窗口(或换了前台窗口): 重新做整套 UIA
        _t0 = time.time()
        if _uia[0] is None:
            auto = _import_uia_robust()
            if auto is None:
                # UIA 库加载失败(如 comtypes typelib 版本不匹配): 记录待节流, 不报错、本次算失败.
                _uia_t[0] = now
                _uia_fg[0] = fg
                _uia_el[0] = None
                return None
            _uia[0] = auto
        auto = _uia[0]
        try:
            el = auto.GetFocusedControl()
        except BaseException:
            # 首次 GetFocusedControl 若因 comtypes typelib 版本校验失败(_AutomationClient 单例
            # 构造失败), 重置该单例并重试一次——此时 _check_version 已被打成 no-op, 重新初始化即可.
            el = _uia_retry_client(auto)
        _dlog('get_caret_uia: GetFocusedControl=%.0fms el=%s' % ((time.time()-_t0)*1000, bool(el)))
        if not el:
            _uia_t[0] = now
            _uia_fg[0] = fg
            _uia_el[0] = None
            return None
        # 精确光标: ITextPattern.GetSelection(); caret 是细矩形(高 4~200, 宽<=200),
        # 太宽 = 整行/段落(某些 Chromium 字段) -> 不信任, 回退到控件边界
        try:
            tp = el.GetPattern(auto.PatternId.TextPattern)
            if tp:
                sel = tp.GetSelection()
                if sel and len(sel) > 0:
                    rects = sel[0].GetBoundingRectangles()
                    if rects:
                        r = rects[0]
                        cw = r.right - r.left
                        ch = r.bottom - r.top
                        if 0 < cw <= 200 and 4 <= ch <= 200:
                            pos = (int(r.left), int(r.bottom))
                            _uia_el[0] = pos
                            _uia_t[0] = now
                            _uia_fg[0] = fg
                            return pos
        except Exception:
            pass
        # 回退: 聚焦控件边界 (只算小控件, 避免全屏/整窗)
        r = el.BoundingRectangle
        cw = r.right - r.left
        ch = r.bottom - r.top
        if 0 < cw < 2000 and 0 < ch < 400:
            pos = (int(r.left), int(r.bottom))
            _uia_el[0] = pos
            _uia_t[0] = now
            _uia_fg[0] = fg
            return pos
        # 未取到: 记录此次尝试, 让后续调用被节流
        _uia_t[0] = now
        _uia_fg[0] = fg
        _uia_el[0] = None
    except Exception:
        pass
    return None


_uia_bg_started = [False]


def _caret_bg_loop():
    """后台线程: 周期性刷新 UIA 光标位置到 _uia_el[0], 供主线程 get_caret_pos 读缓存.
    关键: UIA GetFocusedControl/GetSelection 在 Teams 等 Electron 应用可耗时 1~几秒,
    若在主线程(bar.show 里)同步跑, 会阻塞按键处理/上屏. 这里挪到后台线程, 主线程只读缓存."""
    import time
    try:
        _force_zip_uia()
        _import_uia_robust()          # 先确保 uiautomation 可用 + _check_version 中和
        _dlog('caret_bg: started')
        while True:
            time.sleep(0.10)          # 后台: 每 100ms 试一次(内部 get_caret_uia 还有 150ms 节流)
            try:
                get_caret_uia()       # 更新 _uia_el[0]
            except Exception:
                pass
    except Exception:
        pass


def ensure_caret_bg():
    """启动后台光标刷新线程(仅一次). get_caret_pos 因此总能拿到缓存位, 主线程不阻塞."""
    import threading
    if _uia_bg_started[0]:
        return
    _uia_bg_started[0] = True
    try:
        threading.Thread(target=_caret_bg_loop, daemon=True).start()
    except Exception:
        pass


def get_caret_pos():
    """光标屏幕坐标(主线程, 绝不阻塞). GetGUIThreadInfo(廉价,同步) -> UIA 缓存(后台刷新) ->
    上次有效位 -> 前台窗口客户区."""
    import time as _t
    _t0 = _t.time()
    try:
        fg = user32.GetForegroundWindow()
        tid = user32.GetWindowThreadProcessId(fg, None)
        g = GUITHREADINFO()
        g.cbSize = ctypes.sizeof(GUITHREADINFO)
        if user32.GetGUIThreadInfo(tid, ctypes.byref(g)) and g.hwndCaret:
            pt = POINT(g.rcCaret.left, g.rcCaret.bottom)
            user32.ClientToScreen(g.hwndCaret, ctypes.byref(pt))
            _last_caret[0] = (pt.x, pt.y)
            _dlog('get_caret_pos: GUITI ok in %.1fms -> %s' % ((_t.time()-_t0)*1000, _last_caret[0]))
            return _last_caret[0]
    except Exception:
        pass
    # UIA 缓存(后台线程已刷新): 直接读, 不在此处同步跑 UIA(否则 Teams 会卡几秒).
    if _uia_el[0] is not None:
        _dlog('get_caret_pos: UIA-cache(%.1fms) -> %s' % ((_t.time()-_t0)*1000, _uia_el[0]))
        return _uia_el[0]
    if _last_caret[0]:
        _dlog('get_caret_pos: last-cache(%.1fms) -> %s' % ((_t.time()-_t0)*1000, _last_caret[0]))
        return _last_caret[0]
    _dlog('get_caret_pos: fallback-origin(%.1fms)' % ((_t.time()-_t0)*1000))
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
