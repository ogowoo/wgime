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

VK_TOGGLE = 0x77        # F8 (硬开关; python 额外, C# 只能靠 hotkey_toggle 配)
VK_TAP = 0xF8           # 合成: Shift 轻拍
VK_MODE = 0xF9          # 合成: Ctrl+` (可配 hotkey_mode)
VK_TRAD = 0xFA          # 合成: Ctrl+Shift+F (可配 hotkey_trad)
VK_MAKEWORD = 0xFB      # 合成: Ctrl+Alt+C (可配 hotkey_makeword)
VK_QUIT = 0xFC          # 合成: Ctrl+Alt+Q 退出 (python 额外)
VK_PUNCT = 0xFD         # 合成: Ctrl+. 全/半角标点切换 (python 额外)

# ---------- 可配置快捷键 / 候选操作键 (对齐 C# KeyBordHook: hotkey_* / key_* ) ----------
SHIFT_TAP = -1          # 哨兵: Shift 轻拍 (对齐 C# ModToggle = 0x80000000)
MOD_CTRL, MOD_ALT, MOD_SHIFT, MOD_WIN = 1, 2, 4, 8
# 缺省值 (与 C# 类字段一致); 每次 configure 都从缺省重建, 所以删掉 config 行即回缺省
DEFAULT_HOTKEYS = {'toggle': 'shift_tap', 'mode': 'ctrl+grave',
                   'makeword': 'ctrl+alt+c', 'trad': 'ctrl+shift+f'}
DEFAULT_KEYS = {'first': 'space', 'pageup': 'minus', 'pagedown': 'plus', 'back': 'backspace',
                'cancel': 'esc', 'raw': 'enter', 'pickfirst': 'lbracket', 'picklast': 'rbracket'}
# action -> (mods, vk); vk=0 = 禁用; mods=SHIFT_TAP = Shift 轻拍
HOTKEYS = {'toggle': (SHIFT_TAP, 0), 'mode': (MOD_CTRL, 0xC0),
           'makeword': (MOD_CTRL | MOD_ALT, 0x43), 'trad': (MOD_CTRL | MOD_SHIFT, 0x46)}
# name -> vk; 0 = 禁用
KEYS = {'first': 0x20, 'pageup': 0xBD, 'pagedown': 0xBB, 'back': 0x08,
        'cancel': 0x1B, 'raw': 0x0D, 'pickfirst': 0xDB, 'picklast': 0xDD}

_VK_NAMES = {
    'space': 0x20, 'enter': 0x0D, 'return': 0x0D, 'esc': 0x1B, 'escape': 0x1B,
    'backspace': 0x08, 'tab': 0x09, 'pgup': 0x21, 'pgdn': 0x22, 'home': 0x24, 'end': 0x23,
    'left': 0x25, 'right': 0x27, 'up': 0x26, 'down': 0x28,
    'grave': 0xC0, 'backquote': 0xC0, '`': 0xC0,
    'minus': 0xBD, '-': 0xBD, 'plus': 0xBB, 'equals': 0xBB, '=': 0xBB,
    'lbracket': 0xDB, '[': 0xDB, 'rbracket': 0xDD, ']': 0xDD,
    'semicolon': 0xBA, ';': 0xBA, 'quote': 0xDE, "'": 0xDE,
    'comma': 0xBC, ',': 0xBC, 'period': 0xBE, '.': 0xBE, 'slash': 0xBF, '/': 0xBF,
    'backslash': 0xDC, '\\': 0xDC,
}


def vk_from_name(n):
    """键名 -> 虚拟键码; 0 = 未知/'none' (对齐 C# VkFromName)."""
    if not n:
        return 0
    s = str(n).strip().lower()
    if len(s) == 1:
        c = s[0]
        if 'a' <= c <= 'z':
            return 0x41 + (ord(c) - ord('a'))
        if '0' <= c <= '9':
            return 0x30 + (ord(c) - ord('0'))
    if s in _VK_NAMES:
        return _VK_NAMES[s]
    if len(s) >= 2 and s[0] == 'f' and s[1:].isdigit():
        fn = int(s[1:])
        if 1 <= fn <= 12:
            return 0x6F + fn
    return 0


def parse_hotkey(v):
    """"ctrl+alt+c" -> (mods, vk); "none" -> (0, 0) 禁用; 无效 -> None (保持原值, 对齐 C# ParseHotkey)."""
    if v is None:
        return None
    t = str(v).strip().lower()
    if t == 'none':
        return (0, 0)
    mods = 0
    vk = 0
    for part in t.split('+'):
        q = part.strip()
        if q in ('ctrl', 'control'):
            mods |= MOD_CTRL
        elif q in ('alt', 'menu'):
            mods |= MOD_ALT
        elif q == 'shift':
            mods |= MOD_SHIFT
        elif q in ('win', 'windows'):
            mods |= MOD_WIN
        else:
            kv = vk_from_name(q)
            if kv == 0 or vk != 0:
                return None
            vk = kv
    if vk == 0:
        return None
    return (mods, vk)


def configure(hotkeys=None, ckeys=None):
    """从 config.txt 的 hotkey_* / key_* 安装快捷键与候选操作键 (缺省重建, 无效值忽略)."""
    for act, raw in DEFAULT_HOTKEYS.items():
        r = raw
        if hotkeys and act in hotkeys:
            r = hotkeys[act]
        if act == 'toggle' and str(r).strip().lower() == 'shift_tap':
            HOTKEYS['toggle'] = (SHIFT_TAP, 0)
            continue
        p = parse_hotkey(r)
        if p is not None:
            HOTKEYS[act] = p
    for name, raw in DEFAULT_KEYS.items():
        r = raw
        if ckeys and name in ckeys:
            r = ckeys[name]
        if str(r).strip().lower() == 'none':
            KEYS[name] = 0
            continue
        kv = vk_from_name(r)
        if kv:
            KEYS[name] = kv
    _rebuild_swallow()


def _rebuild_swallow():
    """组字中要吞掉的候选操作键 (对齐 C#: 配置键 + PgUp/PgDn 常驻)."""
    s = set(v for v in KEYS.values() if v)
    s.add(0x21)                                   # PgUp: 组字中恒翻页
    s.add(0x22)                                   # PgDn
    _swallow[0] = s


_swallow = [set()]

ACTIVE = [False]        # 输入法是否启用 (主线程写入, 钩子线程判定)
COMPOSING = [False]     # 是否有拼音缓冲/联想 (主线程写入; 空缓冲时空格/退格/回车透传)
PUNCT = [True]          # 全角标点开关 (主线程写入; 关闭时标点键透传半角)

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


def _key_state(vk):
    return (user32.GetKeyState(vk) & 0x8000) != 0


def _mods_down():
    return (_key_state(0x11) or _key_state(0x12) or _key_state(0x10)
            or _key_state(0x5B) or _key_state(0x5C))


def _match_mods(mods):
    """严格匹配: 有标志的修饰键必须按下, 其余必须抬起 (对齐 C# MatchMods)."""
    c = _key_state(0x11)
    a = _key_state(0x12)
    s = _key_state(0x10)
    w = _key_state(0x5B) or _key_state(0x5C)
    return (((mods & MOD_CTRL) != 0) == c and ((mods & MOD_ALT) != 0) == a
            and ((mods & MOD_SHIFT) != 0) == s and ((mods & MOD_WIN) != 0) == w)


_hook = [None]


def _proc(nCode, wParam, lParam):
    try:
        if nCode >= 0:
            kbd = ctypes.cast(lParam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
            # 所有注入键(第三方宏/AHK/远程桌面)一律放行不吞, 与 C# 版对齐
            if (kbd.flags & LLKHF_INJECTED):
                return user32.CallNextHookEx(None, nCode, wParam, lParam)
            m = int(wParam)
            vk = int(kbd.vkCode)
            if m == WM_KEYDOWN or m == WM_SYSKEYDOWN:
                if vk == VK_TOGGLE:                            # F8 硬开关: 带修饰键则透传(不劫持 Ctrl+F8/Shift+F8 等)
                    if (_key_state(0x11) or _key_state(0x12) or _key_state(0x10)
                            or _key_state(0x5B) or _key_state(0x5C)):
                        return user32.CallNextHookEx(None, nCode, wParam, lParam)
                    EVENTS.put(VK_TOGGLE)
                    return 1
                if _key_state(0x11) and _key_state(0x12) and vk == 0x51:   # Ctrl+Alt+Q 退出
                    EVENTS.put(VK_QUIT)
                    return 1
                ctrl = _key_state(0x11)
                shift = _key_state(0x10)
                alt = _key_state(0x12)
                if vk in (0xA0, 0xA1):                         # Shift down
                    # 带 Ctrl/Alt/Win 时不武装轻拍(避免 Ctrl+Shift/Alt+Shift 误触发开关);
                    # hotkey_toggle 配成别的键时 Shift 轻拍随之停用 (对齐 C# shiftTap 只在 ModToggle 为轻拍时成立)
                    if (HOTKEYS.get('toggle', (0, 0))[0] != SHIFT_TAP
                            or ctrl or alt or _key_state(0x5B) or _key_state(0x5C)):
                        _tap_time[0] = None
                        _tap_dirty[0] = True
                    else:
                        _tap_time[0] = time.time()
                        _tap_dirty[0] = False
                else:
                    if _tap_time[0] is not None:
                        _tap_dirty[0] = True                   # 有其它键介入, 不算轻拍
                    # 可配置热键 (对齐 C#: 在 IsLocked 之前判定, 故输入法关闭/无缓冲时同样生效并按严格修饰键匹配)
                    for _act, _code in (('toggle', VK_TAP), ('mode', VK_MODE),
                                        ('makeword', VK_MAKEWORD), ('trad', VK_TRAD)):
                        _mods, _hk = HOTKEYS.get(_act, (0, 0))
                        if _hk and _hk == vk and _mods != SHIFT_TAP and _match_mods(_mods):
                            EVENTS.put(_code)
                            return 1
                    if ACTIVE[0]:
                        if ctrl and not shift and not alt and vk == 0xBE:   # Ctrl+. 全/半角标点 (python 额外)
                            EVENTS.put(VK_PUNCT)
                            return 1
                        winkey = _key_state(0x5B) or _key_state(0x5C)
                        if ctrl or alt or winkey:              # 带 Ctrl/Alt/Win 的快捷键: 透传
                            return user32.CallNextHookEx(None, nCode, wParam, lParam)
                        # 中文标点 (cnpunct 开时): 吞 , . ; / \ [ ] ' 及 Shift 变体 (《》？：等), Shift 状态随事件编码
                        if PUNCT[0] and (
                                vk in (0xBC, 0xBE, 0xBA, 0xDE)          # , . ; ' -> 任意 shift 都吞
                                or (shift and vk == 0xBF)               # Shift+/ -> ？ (裸 / 透传)
                                or (not shift and vk in (0xDC, 0xDB, 0xDD))   # \ [ ] -> 、 【 】 (Shift 变体透传 | { })
                                or (shift and vk == 0x34 and not COMPOSING[0])):   # Shift+4 -> ¥ (组字中让位候选选择)
                            EVENTS.put(vk | (0x200 if shift else 0))
                            return 1
                        if shift:                              # Shift 修正键: 透传
                            return user32.CallNextHookEx(None, nCode, wParam, lParam)
                        if 0x41 <= vk <= 0x5A:                 # 裸字母: 吞 (开始拼音)
                            EVENTS.put(vk)
                            return 1
                        if 0x30 <= vk <= 0x39 and COMPOSING[0]:   # 数字: 仅组字/联想时吞(候选选择/v模式), 裸数字透传(C# 对齐)
                            EVENTS.put(vk)
                            return 1
                        # 候选操作键 (config key_*; 含 PgUp/PgDn 常驻): 仅缓冲有效时吞 (对齐 C# HasCode 条件)
                        if vk in _swallow[0] and COMPOSING[0]:
                            EVENTS.put(vk)
                            return 1
                        # 其余键透传 (无缓冲时空格/退格/回车交给应用)
            elif m == WM_KEYUP or m == WM_SYSKEYUP:
                if vk in (0xA0, 0xA1):
                    if _tap_time[0] is not None and not _tap_dirty[0] \
                            and time.time() - _tap_time[0] < 0.4:
                        EVENTS.put(VK_TAP)                     # 孤立快速 Shift 轻拍: 切换 (激活/关闭)
                    _tap_time[0] = None
    except Exception:
        return user32.CallNextHookEx(None, nCode, wParam, lParam)
    return user32.CallNextHookEx(None, nCode, wParam, lParam)


_tap_time = [None]
_tap_dirty = [True]

_rebuild_swallow()          # 模块导入即装缺省快捷键/候选键, main.apply_config 会再 configure 一次


def _pump():
    msg = w.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))


_started = [False]
_installed = [False]      # 钩子是否装上 (对齐 C# Hook.Installed)
_last_err = [0]           # 安装失败时的 Win32 错误码
_install_done = threading.Event()


def start():
    """装全局键盘钩子并在该线程跑消息泵; 返回钩子是否安装成功 (等安装完成再返回, 上限 2s).
    对齐 C# Hook.Start() 的同步安装 —— main 据此给"钩子失败"提示."""
    if _started[0]:
        return _installed[0]
    _started[0] = True
    _hook[0] = HOOKPROC(_proc)

    def work():
        try:
            h = user32.SetWindowsHookExW(WH_KEYBOARD_LL, _hook[0], None, 0)
            _installed[0] = bool(h)
            if not h:
                _last_err[0] = ctypes.get_last_error()
        except Exception:
            try:
                _last_err[0] = ctypes.get_last_error()
            except Exception:
                pass
        finally:
            _install_done.set()
        _pump()

    threading.Thread(target=work, daemon=True).start()
    _install_done.wait(2.0)
    return _installed[0]


def last_error():
    return _last_err[0]


def set_active(on):
    ACTIVE[0] = bool(on)


def set_punct(on):
    """全角标点开关 (主线程在配置加载/切换时同步进来)."""
    PUNCT[0] = bool(on)


drain = EVENTS.get
