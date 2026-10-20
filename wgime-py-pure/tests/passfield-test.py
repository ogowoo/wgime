# -*- coding: utf-8 -*-
r"""密码框自动英文回归 (第九十二轮).

需求: 焦点在密码输入框时, 输入法**不组字**, 按键原样交给应用 (等于临时切成英文);
离开这个框自然恢复 —— 没改过模式, 所以不需要任何还原动作。

本测试分五段, 全部真跑(不是读源码猜):
  S 配置语义  —— engine.load_config 对 password_en / password_uia 的取值 (白名单: 非法值判关)
  W Win32 判定 —— **真建 Win32 控件**(Edit/Button), 验 ES_PASSWORD / EM_GETPASSWORDCHAR 两条线索,
                  以及"非原生文本框一律结论'看不出来'(None, 该问 UIA)"这条关键约定
  H 钩子矩阵  —— 伪造 lParam 直调 hook._proc: 密码框里字母/数字/标点/空格全透传、IME 级热键仍生效、
                  进框时要求 main 清掉残留拼音、探测函数抛异常不许连累打字、开关关掉时一次都不探测
  P 助手 IPC  —— 用**假助手源码**替换 PF_HELPER_SRC, 真起子进程走 JSONL, 验"结论按 hwnd 缓存 ->
                  password_context 认账", 以及前台窗口变了结论作废、关掉 password_uia 不发请求
  R 真助手    —— 内嵌 `_EMBEDDED_PF_HELPER` 真起子进程回 ready (证明 UIA vtable 那段可用);
                  UIA 不可用的环境记 SKIP 不算红 (本机实测可用)

跑法: python wgime-py-pure\tests\passfield-test.py
"""
import ctypes
import ctypes.wintypes as w
import json
import os
import shutil
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
sys.path.insert(0, PURE)

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-58s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def skip(name, why):
    n[0] += 1
    print('  %-58s SKIP %s' % (name, why))


def _write(path, text):
    with open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(text)


# ---------------------------------------------------------------- S 配置语义
def section_config():
    print('--- S 配置: password_en / password_uia 取值 (白名单, 非法判关) ---')
    import engine
    d = tempfile.mkdtemp(prefix='wgpf-')
    try:
        blank = engine.load_config(os.path.join(d, 'nope.txt'))     # 文件不存在 -> 全缺省
        check('S1 缺省 password_en=True (默认开启)', blank.get('password_en') is True,
              repr(blank.get('password_en')))
        check('S2 缺省 password_uia=True (默认问 UIA)', blank.get('password_uia') is True,
              repr(blank.get('password_uia')))

        def one(key, val):
            p = os.path.join(d, 'config.txt')
            _write(p, '%s = %s\n' % (key, val))
            return engine.load_config(p)

        def one2(text):
            p = os.path.join(d, 'both.txt')
            _write(p, text)
            return engine.load_config(p)

        check('S3 password_en = 0 -> False', one('password_en', '0').get('password_en') is False)
        check('S4 password_en = on -> True', one('password_en', 'on').get('password_en') is True)
        check('S5 password_en = true -> True', one('password_en', 'true').get('password_en') is True)
        check('S6 非法值 password_en = maybe -> False (保守: 判关)',
              one('password_en', 'maybe').get('password_en') is False)
        check('S7 password_uia = off -> False', one('password_uia', 'off').get('password_uia') is False)
        check('S8 键名大小写不敏感 (PASSWORD_EN = on -> True)',
              one('PASSWORD_EN', 'on').get('password_en') is True)
        # 值的大小写**敏感**是既有约定 (C# LoadConfig 只对 k 调 ToLower, v 原样比较;
        # keyfix/showcode/trad 等全都如此) —— 这里把它钉住, 免得以后"顺手"改出一个不一致。
        check('S8b 值大小写敏感 (PASSWORD_EN = ON -> False, 同 C# LoadConfig)',
              one('PASSWORD_EN', 'ON').get('password_en') is False)
        check('S9 两行都写: 各自生效', (lambda c: c['password_en'] is False and c['password_uia'] is False)(
            one2('password_en = 0\npassword_uia = 0\n')))
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ---------------------------------------------------------------- W Win32 判定
user32 = ctypes.windll.user32
user32.CreateWindowExW.restype = ctypes.c_void_p
user32.CreateWindowExW.argtypes = [w.DWORD, ctypes.c_wchar_p, ctypes.c_wchar_p, w.DWORD,
                                   ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                   ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
user32.DestroyWindow.argtypes = [ctypes.c_void_p]
user32.DestroyWindow.restype = w.BOOL
WS_POPUP = 0x80000000
ES_PASSWORD = 0x0020
ES_AUTOHSCROLL = 0x0080
EM_SETPASSWORDCHAR = 0x00CC


def make_win(cls, style=0):
    h = user32.CreateWindowExW(0, cls, '', WS_POPUP | style, 0, 0, 60, 20, None, None, None, None)
    return int(h or 0)


def section_win32():
    print('--- W Win32 判定: 真建控件 (Edit/Button) ---')
    import win
    ed_pw = make_win('Edit', ES_PASSWORD)
    ed_plain = make_win('Edit', ES_AUTOHSCROLL)
    btn = make_win('Button')
    try:
        check('W0 建窗口成功 (Edit+ES_PASSWORD / Edit / Button)',
              bool(ed_pw and ed_plain and btn), '%r %r %r' % (ed_pw, ed_plain, btn))
        if not (ed_pw and ed_plain and btn):
            return
        # 回归: 这段**只能建不可见窗口** —— 测试绝不许在用户屏幕上弹窗 (实测被用户当面抱怨过)
        check('W0b 测试窗口一律不可见 (屏幕上不弹窗)',
              not any(user32.IsWindowVisible(ctypes.c_void_p(h)) for h in (ed_pw, ed_plain, btn)))
        check('W1 类名读对了',
              win.win_class(ed_pw) == 'Edit' and win.win_class(btn) == 'Button',
              '%r / %r' % (win.win_class(ed_pw), win.win_class(btn)))
        check('W2 ES_PASSWORD 的 Edit -> 密码框',
              win.password_verdict(ed_pw) is True, repr(win.password_verdict(ed_pw)))
        check('W3 普通 Edit -> 确定不是密码框 (False, 不是"看不出来")',
              win.password_verdict(ed_plain) is False, repr(win.password_verdict(ed_plain)))
        # 只设密码字符、不置 ES_PASSWORD 的程序很多 (EM_SETPASSWORDCHAR 直接给控件)
        user32.SendMessageW(ctypes.c_void_p(ed_plain), EM_SETPASSWORDCHAR, ord('*'), 0)
        win._PF_CACHE.pop(ed_plain, None)                     # 清 2s 缓存, 强制重读
        check('W4 只 EM_SETPASSWORDCHAR(不置 ES_PASSWORD) -> 也算密码框',
              win.password_verdict(ed_plain) is True, repr(win.password_verdict(ed_plain)))
        check('W5 EM_GETPASSWORDCHAR 真读回来了', win._password_char(ed_plain) == ord('*'),
              repr(win._password_char(ed_plain)))
        user32.SendMessageW(ctypes.c_void_p(ed_plain), EM_SETPASSWORDCHAR, 0, 0)
        win._PF_CACHE.pop(ed_plain, None)
        check('W6 清掉密码字符 -> 又变回"不是"', win.password_verdict(ed_plain) is False)
        # **关键约定**: 非原生文本框必须返回 None(看不出来), 否则浏览器/Qt 永远没机会被认出来
        check('W7 Button -> None (看不出来, 该问 UIA) —— 这条是关键',
              win.password_verdict(btn) is None, repr(win.password_verdict(btn)))
        tl = {'edit': True, 'richedit20w': True, 'richedit50w': True, 'tedit': True,
              'windowsforms10.edit.app.0.2533c4_r7_ad1': True,
              'windowsforms10.richedit.app.0.x': True,
              'button': False, 'chrome_renderwidgethosthwnd': False, 'qt5152qwindowicon': False,
              'chrome_widgetwin_1': False, '': False}
        bad = {k: win.edit_like_class(k) for k, v in tl.items() if win.edit_like_class(k) != v}
        check('W8 类名分类表: 原生文本框 True / 浏览器-Qt-Button False', not bad, repr(bad))
        check('W9 2s 缓存生效 (缓存里留了该控件的类名)',
              any(e[0] == 'Edit' for e in win._PF_CACHE.values()), repr(win._PF_CACHE))

        # password_context: 只打桩"焦点在哪", 判定本身走真 Win32
        orig_focus = win.focus_hwnd
        try:
            win._PF_EN[0] = True
            win.focus_hwnd = lambda: (0x1111, ed_pw)
            check('W10 password_context: 焦点在密码框 -> True', win.password_context() is True)
            win.focus_hwnd = lambda: (0x1111, ed_plain)
            check('W11 password_context: 焦点在普通文本框 -> False', win.password_context() is False)
            win.focus_hwnd = lambda: (0x1111, btn)
            win._PF_UIA_CACHE.clear()
            check('W12 password_context: 看不出来的类且没结论 -> False (不阻塞, 当不是)',
                  win.password_context() is False)
            win._PF_UIA_CACHE[btn] = [0x1111, True, time.monotonic()]      # 假装 UIA 已答"是"
            check('W13 password_context: 看不出来的类 + UIA 结论 True -> True',
                  win.password_context() is True)
            win._PF_UIA_CACHE[btn] = [0x2222, True, time.monotonic()]      # 结论属于别的前台窗口
            check('W14 结论的前台窗口对不上 -> 不认', win.password_context() is False)
            win._PF_UIA_CACHE.clear()
            win._PF_EN[0] = False
            check('W15 总开关关掉 -> 一律 False (连判定都不做)', win.password_context() is False)
            win.focus_hwnd = lambda: (0x1111, ed_pw)
            check('W16 开关关掉时, 焦点在密码框也是 False', win.password_context() is False)
        finally:
            win.focus_hwnd = orig_focus
            win._PF_EN[0] = False
            win._PF_UIA_CACHE.clear()
    finally:
        for h in (ed_pw, ed_plain, btn):
            if h:
                user32.DestroyWindow(ctypes.c_void_p(h))


# ---------------------------------------------------------------- H 钩子矩阵
def section_hook():
    print('--- H 钩子矩阵: 伪造 lParam 直调 hook._proc ---')
    import hook

    orig_ks = hook._key_state
    modstate = {0x11: False, 0x12: False, 0x10: False, 0x5B: False, 0x5C: False}
    hook._key_state = lambda v: bool(modstate.get(v, False))
    saved = (hook.ACTIVE[0], hook.COMPOSING[0], hook.PUNCT[0], hook.PF_EN[0], hook.PF_PROBE[0])
    calls = [0]

    def probe_yes():
        calls[0] += 1
        return True

    def fire(vk, shift=False, composing=False, punct_on=True, active=True):
        modstate[0x10] = bool(shift)
        hook.ACTIVE[0] = active
        hook.COMPOSING[0] = composing
        hook.PUNCT[0] = punct_on
        while not hook.EVENTS.empty():
            hook.EVENTS.get()
        s = hook.KBDLLHOOKSTRUCT()
        s.vkCode = vk
        s.scanCode = 0
        s.flags = 0
        s.time = 0
        s.dwExtraInfo = 0
        rc = hook._proc(0, 0x0100, ctypes.addressof(s))
        got = []
        while not hook.EVENTS.empty():
            got.append(hook.EVENTS.get())
        return (rc == 1), (got[0] if got else None)

    try:
        hook.PF_EN[0] = True
        hook.PF_PROBE[0] = probe_yes
        sw, ev = fire(0x41)                                   # 密码框里的字母
        check('H1 密码框: 字母不吞 (原样给应用)', not sw and ev is None, 'swallow=%s ev=%r' % (sw, ev))
        sw, ev = fire(0x31, composing=True)                    # 组字中的数字(原本会选候选)
        check('H2 密码框: 数字不选候选, 透传', not sw and ev == hook.VK_PF, 'swallow=%s ev=%r' % (sw, ev))
        sw, ev = fire(0xBC)                                    # 逗号(原本变全角 ，)
        check('H3 密码框: 标点不吞 (不会变全角)', not sw and ev is None, 'swallow=%s ev=%r' % (sw, ev))
        sw, ev = fire(0x20, composing=True)                    # 组字中的空格(原本首候选上屏)
        check('H4 密码框: 空格透传 (不会上屏候选)', not sw and ev == hook.VK_PF, 'swallow=%s ev=%r' % (sw, ev))
        sw, ev = fire(0x08, composing=True)                    # 组字中的退格
        check('H5 密码框: 退格透传 (不吞进输入法)', not sw, 'swallow=%s ev=%r' % (sw, ev))
        sw, ev = fire(0x41, shift=True)                        # Shift+字母
        check('H6 密码框: Shift+字母照旧透传', not sw, 'swallow=%s' % (sw,))
        sw, ev = fire(0x77)                                    # F8 硬开关: IME 级热键不该被密码框挡住
        check('H7 密码框里 F8 仍能切开关 (IME 级热键不挡)',
              sw and ev == hook.VK_TOGGLE, 'swallow=%s ev=%r' % (sw, ev))
        hook.PF_PROBE[0] = lambda: (_ for _ in ()).throw(RuntimeError('boom'))
        sw, ev = fire(0x41)
        check('H8 探测函数抛异常 -> 当"不是", 照常组字 (绝不连累打字)',
              sw and ev == 0x41, 'swallow=%s ev=%r' % (sw, ev))
        hook.PF_PROBE[0] = probe_yes
        hook.PF_EN[0] = False
        calls[0] = 0
        sw, ev = fire(0x41)
        check('H9 开关关掉: 照常组字', sw and ev == 0x41, 'swallow=%s ev=%r' % (sw, ev))
        check('H10 开关关掉: 探测函数一次都不调 (零开销)', calls[0] == 0, 'calls=%d' % calls[0])
        hook.PF_PROBE[0] = None
        hook.PF_EN[0] = True
        sw, ev = fire(0x41)
        check('H11 没装探测函数: 照常组字 (不崩)', sw and ev == 0x41, 'swallow=%s ev=%r' % (sw, ev))
    finally:
        hook._key_state = orig_ks
        hook.ACTIVE[0], hook.COMPOSING[0], hook.PUNCT[0], hook.PF_EN[0], hook.PF_PROBE[0] = saved


# ---------------------------------------------------------------- P 助手 IPC
FAKE_HELPER_TMPL = r'''import json, sys
VAL = %s
print(json.dumps({"type": "ready", "pid": 1}), flush=True)
for line in sys.stdin:
    q = json.loads(line)
    print(json.dumps({"type": "result", "id": q.get("id"), "op": "password",
                      "hwnd": q.get("hwnd"), "fg": q.get("fg"),
                      "is_password": VAL, "ms": 0.1}), flush=True)
'''


class _FakeU32(object):
    """前台窗口钉死: 回包校验比的是 request.fg vs 回包时的 GetForegroundWindow, 不钉的话
    屏幕前的人切一下窗口这条就假红。"""

    def __init__(self, real):
        self._real = real

    def __getattr__(self, k):
        return getattr(self._real, k)

    def GetForegroundWindow(self):
        return 0xABCD


def run_fake_helper(val, hwnd, win, timeout=4.0):
    """假源码顶掉 _EMBEDDED_PF_HELPER, 真起一个子进程, 走真 _pf_reader 路由。"""
    if win._PF_PROC[0] is not None:                 # 上一段的助手还在: 杀掉(它还带着旧结论)
        try:
            win._PF_PROC[0].kill()
        except Exception:
            pass
        win._PF_PROC[0] = None
    win._PF_LAST_START[0] = 0.0                     # 清 1s 防风暴门
    win._PF_FAIL[0] = 0
    win._PF_REQ.clear()
    win._PF_REQ_FG.clear()
    win.PF_HELPER_SRC[0] = FAKE_HELPER_TMPL % ('True' if val else 'False')
    rid = win.request_password_probe(hwnd)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if hwnd in win._PF_UIA_CACHE:
            break
        if win._PF_PROC[0] is None:
            break
        time.sleep(0.02)
    return rid, win._PF_UIA_CACHE.get(hwnd)


def section_helper():
    print('--- P 助手 IPC: 假助手源码走真 JSONL 路由 ---')
    import win
    btn = make_win('Button')
    real_u32 = win.user32
    saved = (win.PF_HELPER_SRC[0], win._PF_EN[0], win._PF_UIA[0], win.focus_hwnd)
    try:
        check('P0 建测试窗口成功', bool(btn), repr(btn))
        if not btn:
            return
        win.user32 = _FakeU32(real_u32)
        win._PF_EN[0] = True
        win._PF_UIA[0] = True
        win._PF_UIA_CACHE.clear()

        rid, got = run_fake_helper(True, btn, win)
        check('P1 假助手起来并回了结论 (真起子进程/真 JSONL)',
              rid > 0 and got is not None, 'rid=%r got=%r' % (rid, got))
        check('P2 结论按 hwnd 缓存, 前台窗口也记对了',
              bool(got) and got[0] == 0xABCD and got[1] is True, repr(got))
        win.focus_hwnd = lambda: (0xABCD, btn)
        check('P3 password_context 认这条 UIA 结论 (看不出来的类 -> True)',
              win.password_context() is True, repr(win._PF_UIA_CACHE.get(btn)))
        win.focus_hwnd = lambda: (0x9999, btn)
        check('P4 换了个前台窗口 -> 旧结论不认', win.password_context() is False)

        win._PF_UIA_CACHE.clear()                   # 让假助手答"不是"
        rid, got = run_fake_helper(False, btn, win)
        win.focus_hwnd = lambda: (0xABCD, btn)
        check('P5 假助手答 False -> 缓存 False 且 password_context False',
              bool(got) and got[1] is False and win.password_context() is False, repr(got))

        if win._PF_PROC[0] is not None:             # 关掉 UIA 层: 一次都不许发请求
            try:
                win._PF_PROC[0].kill()
            except Exception:
                pass
            win._PF_PROC[0] = None
        win._PF_UIA_CACHE.clear()
        win._PF_REQ.clear()
        win._PF_UIA[0] = False
        win._PF_FAIL[0] = 0
        win._PF_LAST_START[0] = 0.0
        rid = win.request_password_probe(btn)
        check('P6 password_uia=0: 不发请求、不起进程',
              rid == 0 and win._PF_PROC[0] is None, 'rid=%r proc=%r' % (rid, win._PF_PROC[0]))
    finally:
        win.user32 = real_u32
        win.focus_hwnd = saved[3]
        win.PF_HELPER_SRC[0] = saved[0]
        win._PF_EN[0] = False
        win._PF_UIA[0] = saved[2]
        win._PF_UIA_CACHE.clear()
        win._PF_REQ.clear()
        win._PF_REQ_FG.clear()
        win.pf_configure(False, saved[2])           # 关掉 = 顺手杀助手, 不留孤儿
        if btn:
            user32.DestroyWindow(ctypes.c_void_p(btn))


# ---------------------------------------------------------------- V 助手判定规则
def section_verdict():
    print('--- V 助手判定规则: IsPassword 不支持时看 Chromium 的 ClassName ---')
    import win
    ns = {'__name__': 'pf_helper_under_test'}       # 助手源码末尾是 if __name__=='__main__' 守卫
    exec(compile(win._EMBEDDED_PF_HELPER, '<pf-helper>', 'exec'), ns)
    v = ns['verdict']
    check('V1 IsPassword 给了 True -> True', v(50004, 'password', True) is True)
    check('V2 IsPassword 给了 False -> False (即便 ClassName 像密码框)', v(50004, 'password', False) is False)
    # 本机实测(§D57): Chromium 的 password input -> ControlType 50004, ClassName 就是 input 的
    # type='password', 而 IsPassword(30050) 一律 VT_ERROR(没实现) -> 只剩 ClassName 这条线索
    check('V3 Chromium 密码框: ct=Edit + ClassName=password -> True', v(50004, 'password', None) is True)
    check('V4 Chromium 普通输入框: ct=Edit + ClassName=text -> False', v(50004, 'text', None) is False)
    check('V5 ClassName 大小写/空格容错', v(50004, ' Password ', None) is True)
    check('V6 焦点不是 Edit(文档/面板) -> None (看不出来, 上层当不是)', v(50030, 'RootWebArea', None) is None)
    check('V7 参数缺失也不崩', v(None, None, None) is None)


# ---------------------------------------------------------------- R 真助手
def _readline_timeout(p, secs):
    box = {}

    def rd():
        try:
            box['line'] = p.stdout.readline()
        except Exception as e:
            box['err'] = e

    t = threading.Thread(target=rd, daemon=True)
    t.start()
    t.join(secs)
    return box.get('line', '')


def section_real_helper():
    print('--- R 真助手: 内嵌源码能起来并回 ready (证明 UIA vtable 调用可用) ---')
    import win
    src = win._EMBEDDED_PF_HELPER
    try:
        compile(src, '<pf-helper>', 'exec')
        check('R1 内嵌助手源码语法正确', True)
    except SyntaxError as e:
        check('R1 内嵌助手源码语法正确', False, repr(e))
        return
    env = dict(os.environ)
    env[win._PF_SRC_ENV] = src
    p = None
    try:
        p = __import__('subprocess').Popen(
            [sys.executable, '-u', '-c', win._PF_BOOTSTRAP],
            stdin=__import__('subprocess').PIPE, stdout=__import__('subprocess').PIPE,
            stderr=__import__('subprocess').DEVNULL, text=True, encoding='utf-8', bufsize=1,
            env=env, creationflags=getattr(__import__('subprocess'), 'CREATE_NO_WINDOW', 0))
        line = (_readline_timeout(p, 8.0) or '').strip()
        try:
            o = json.loads(line) if line else {}
        except ValueError:
            o = {}
        if o.get('type') != 'ready':
            skip('R2 真助手 CoCreateInstance/UIA 可用', '(本环境 UIA 不可用: %r)' % (line[:100],))
            skip('R3 真助手对一次请求能回 result', '(同上)')
            return
        check('R2 真助手 CoCreateInstance/UIA 可用, 回 ready', True)
        p.stdin.write(json.dumps({'id': 7, 'op': 'password', 'hwnd': 0, 'fg': 0}) + '\n')
        p.stdin.flush()
        got = None
        t0 = time.time()
        while time.time() - t0 < 6.0:
            l2 = _readline_timeout(p, 6.0)
            if not l2:
                break
            try:
                o2 = json.loads(l2)
            except ValueError:
                continue
            if o2.get('type') == 'result':
                got = o2
                break
        check('R3 真助手对一次请求能回 result(op=password)',
              bool(got) and got.get('op') == 'password', repr(got))
    finally:
        if p is not None:
            try:
                p.kill()
            except Exception:
                pass
        win._PF_EN[0] = False


def main():
    section_config()
    section_win32()
    section_hook()
    section_helper()
    section_verdict()
    section_real_helper()
    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
