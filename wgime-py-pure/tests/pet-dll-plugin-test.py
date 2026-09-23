# -*- coding: utf-8 -*-
"""桌面宠物的 Rust 浮层(wgpet.dll)接入回归 —— S 段纯静态, L 段真机。

为什么单独一个文件: `pet-overlay-test.py` 测的是那套 Python 实现(LWA_COLORKEY 版);
这份测的是**第八十七轮起的 Rust 浮层**以及"插件优先用 DLL、DLL 不在才退回 Python"这条分派。

S(不需要桌面): 插件里的 DLL 接入点齐、DLL 文件就在插件旁边、DLL 能载入且 ABI/导出符号齐、
  插件自己的 `_load_pet_dll()` 真能拿到库、工具清单的排序与 `code\tname\tkind` 编码对。
L(要桌面): 宿主 API `--api run-plugin pet` 拉起的子进程里要起来浮层窗口; **再拉一次 = 开合百宝袋**
  (窗口从小变大再变小); 给窗口发 WM_CLOSE 后窗口消失**且子进程退出**(不留孤儿进程)。

用法: python pet-dll-plugin-test.py
"""
import ctypes
import importlib.util
import os
import subprocess
import sys
import time

PURE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUG = os.path.join(PURE, 'plugins', 'wgpet.py')
DLL = os.path.join(PURE, 'plugins', 'wgpet.dll')
HOST = os.path.join(PURE, 'main.py')
TITLE = 'wgpet · 桌面宠物'
WM_APP_TOGGLE = 0x8002
WM_CLOSE = 0x0010

SEEN = []


def chk(name, ok, detail=''):
    SEEN.append((name, bool(ok), detail))
    print('%-4s %-52s %s' % ('ok' if ok else 'FAIL', name, detail), flush=True)
    return bool(ok)


def skip(name, why):
    SEEN.append((name, True, 'SKIP: ' + why))
    print('SKIP %-52s %s' % (name, why), flush=True)


def load_plugin():
    spec = importlib.util.spec_from_file_location('wgpet_under_test', PLUG)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# ---------------------------------------------------------------- S 段

def sec_s():
    src = open(PLUG, encoding='utf-8').read()
    for token in ('DLL_NAME = ', 'def _dll_path(', 'def _load_pet_dll(',
                  'def _window_main_dll(', 'def _feed_tools(', 'def _find_overlay('):
        chk('插件里有 %s' % token.strip(), token in src)

    chk('wgpet.dll 就在插件旁边', os.path.exists(DLL),
        '%d 字节' % (os.path.getsize(DLL) if os.path.exists(DLL) else 0))

    lib = None
    try:
        lib = ctypes.WinDLL(DLL)
    except Exception as e:
        chk('wgpet.dll 能载入', False, repr(e))
    if lib is not None:
        chk('wgpet.dll 能载入', True)
        abi = int(lib.wgime_pet_abi_version())
        chk('ABI >= 1', abi >= 1, 'abi=%d' % abi)
        need = ('wgime_pet_start', 'wgime_pet_stop', 'wgime_pet_hwnd', 'wgime_pet_palette',
                'wgime_pet_set_tools', 'wgime_pet_set_launcher', 'wgime_pet_debug',
                'wgime_pet_item_rect', 'wgime_pet_btn_rect', 'wgime_pet_page', 'wgime_pet_pages')
        miss = []
        for n in need:
            try:
                getattr(lib, n)
            except AttributeError:
                miss.append(n)
        chk('DLL 导出宿主需要的全部符号', not miss, 'missing=%s' % (miss or '-'))

    mod = load_plugin()
    chk('插件清单没被改坏',
        mod.CODE == 'pet' and mod.STANDALONE is True and mod.PERM == 'low'
        and mod.DLL_NAME == 'wgpet.dll',
        'code=%s perm=%s standalone=%s' % (mod.CODE, mod.PERM, mod.STANDALONE))

    p = mod._dll_path()
    chk('插件的 _dll_path() 找得到 DLL', bool(p) and os.path.exists(p), p)
    pluglib = mod._load_pet_dll()
    chk('插件的 _load_pet_dll() 真能拿到库', pluglib is not None,
        'abi=%d' % (int(pluglib.wgime_pet_abi_version()) if pluglib else -1))

    class Fake:
        def __init__(self):
            self.text = None

        def wgime_pet_set_tools(self, buf, n):
            self.text = buf[:n].decode('utf-8')
            return len(self.text.splitlines())

    f = Fake()
    items = [{'code': 'zz', 'name': 'Z 工具', 'kind': 'py', 'perm': 'destructive'},
             {'code': 'aa', 'name': 'A 工具', 'kind': 'py', 'perm': 'low'},
             {'code': 'bb', 'name': 'B 工具', 'kind': 'txt', 'perm': 'low'}]
    n = mod._feed_tools(f, items)
    rows = f.text.splitlines()
    chk('工具编码 = code\\tname\\tkind', rows and all(len(r.split('\t')) == 3 for r in rows),
        repr(f.text))
    codes = [r.split('\t')[0] for r in rows]
    chk('低风险排在前面 + code 升序', codes == ['aa', 'bb', 'zz'], 'codes=%s n=%d' % (codes, n))


# ---------------------------------------------------------------- L 段

def desktop_ok():
    try:
        u = ctypes.WinDLL('user32')
        return int(u.GetSystemMetrics(0)) > 0
    except Exception:
        return False


def sec_l():
    u32 = ctypes.WinDLL('user32', use_last_error=True)
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    u32.EnumWindows.argtypes = [ctypes.c_void_p, ctypes.c_ssize_t]
    u32.GetWindowTextW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
    u32.IsWindowVisible.argtypes = [ctypes.c_void_p]

    def find():
        got = []

        def cb(hwnd, lp):
            if u32.IsWindowVisible(hwnd):
                buf = ctypes.create_unicode_buffer(200)
                u32.GetWindowTextW(hwnd, buf, 200)
                if buf.value == TITLE:
                    got.append(int(hwnd))
            return True

        u32.EnumWindows(ctypes.cast(ctypes.WINFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_ssize_t)(cb),
                                    ctypes.c_void_p), 0)
        return got[0] if got else 0

    def rect(h):
        r = ctypes.wintypes.RECT()
        u32.GetWindowRect(ctypes.c_void_p(h), ctypes.byref(r))
        return (r.right - r.left, r.bottom - r.top)

    def run_plugin():
        return subprocess.run([sys.executable, '-X', 'utf8', HOST, '--api', 'run-plugin', 'pet'],
                              capture_output=True, timeout=90,
                              creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0x08000000))

    if find():
        skip('L: 真机跑一遍插件路径', '你已经有宠物窗口在跑了, 不动它')
        return

    r = run_plugin()
    out = (r.stdout or b'').decode('utf-8', 'replace')
    chk('宿主 API 认得 pet 插件', '"ok": true' in out, out.strip()[:80])

    t0, hwnd = time.time(), 0
    while time.time() - t0 < 12 and not hwnd:
        hwnd = find()
        time.sleep(0.3)
    chk('子进程里起来了浮层窗口', bool(hwnd), 'hwnd=0x%X' % (hwnd or 0))
    if not hwnd:
        return
    w0, h0 = rect(hwnd)
    chk('初始是关着面板的尺寸', (w0, h0) == (300, 280), '%dx%d' % (w0, h0))
    pid = ctypes.wintypes.DWORD()
    u32.GetWindowThreadProcessId(ctypes.c_void_p(hwnd), ctypes.byref(pid))

    run_plugin()
    t0 = time.time()
    while time.time() - t0 < 8 and rect(hwnd)[1] <= h0 + 40:
        time.sleep(0.3)
    chk('再拉一次 = 百宝袋打开', rect(hwnd)[1] > h0 + 40, '%dx%d' % rect(hwnd))

    run_plugin()
    t0 = time.time()
    while time.time() - t0 < 8 and rect(hwnd)[1] > h0 + 2:
        time.sleep(0.3)
    chk('第三次 = 面板收起', rect(hwnd)[1] <= h0 + 2, '%dx%d' % rect(hwnd))

    u32.PostMessageW(ctypes.c_void_p(hwnd), WM_CLOSE, 0, 0)
    t0 = time.time()
    while time.time() - t0 < 6 and find():
        time.sleep(0.3)
    chk('WM_CLOSE 后窗口消失', not find())

    def gone():
        h = k32.OpenProcess(0x00100000, False, pid.value)   # 打不开 = 进程已不在
        if not h:
            return True
        k32.CloseHandle(h)
        return False

    t0 = time.time()
    while time.time() - t0 < 8 and not gone():
        time.sleep(0.3)
    chk('子进程跟着退出(不留孤儿)', gone(), 'pid=%d' % pid.value)


def main():
    print('S 段(静态)')
    sec_s()
    if not desktop_ok():
        skip('L: 真机跑一遍插件路径', '无桌面会话')
    else:
        print('L 段(真机)')
        sec_l()
    bad = [n for n, ok, _ in SEEN if not ok]
    print('%d/%d 项通过' % (len(SEEN) - len(bad), len(SEEN)))
    if bad:
        print('FAILED: ' + ', '.join(bad))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
