# -*- coding: utf-8 -*-
"""wgpet.dll 客观验收(随 crate 一起入库; 不靠肉眼)。

靠的是"渲染器自己报标定点 + 抓屏读像素":
  1) 逐像素 alpha —— 渲染器报出阴影核心点(合成 alpha 0.337)与本体点(alpha 1),
     探针把它们与**纯色背景**做叠加算术, 要求**逐通道整数吻合**;
  2) 抗锯齿 —— 窗内不同颜色数必须够多(硬边渲染只会有那十几个平坦色);
  3) 透明 —— 窗内没画到的地方必须还是纯背景色;
  4) 穿透 —— 被动态整窗穿透; 交互态只有画到的像素挡鼠标;
  5) 不抢焦点 / 真帧率 / 能干净关闭。
  另有一道**环境闸门**: 屏幕前的人一按截图, 遮罩层会把整块读数压暗 -> 先确认背景干净再断言,
  否则报"环境不干净"而不是假装是代码 bug(真踩过, 8 条断言集体假红)。

用法: python verify-overlay.py [wgpet.dll]
默认 dll 路径: <本文件目录>/target/release/wgpet.dll
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

u32 = ctypes.WinDLL('user32', use_last_error=True)
g32 = ctypes.WinDLL('gdi32', use_last_error=True)

MAGENTA = (255, 0, 255)
# 硬边渲染: 一堆平坦色 + 边框, 窗内不同颜色数会明显偏少。实测带抗锯齿时远高于此。
MIN_DISTINCT = 60

SEEN = []


def chk(name, ok, detail=''):
    SEEN.append((name, bool(ok), detail))
    print('%-4s %-42s %s' % ('ok' if ok else 'FAIL', name, detail), flush=True)
    return ok


def info(tag, detail):
    print('     %-42s %s' % (tag, detail), flush=True)


def blend(src, alpha, dst):
    return tuple(int(round(alpha * s + (1 - alpha) * d)) for s, d in zip(src, dst))


def near(c, want, tol):
    return all(abs(a - b) <= tol for a, b in zip(c, want))


class WNDCLASSEXW(ctypes.Structure):
    _fields_ = [('cbSize', wt.UINT), ('style', wt.UINT), ('lpfnWndProc', ctypes.c_void_p),
                ('cbClsExtra', ctypes.c_int), ('cbWndExtra', ctypes.c_int),
                ('hInstance', wt.HINSTANCE), ('hIcon', wt.HICON), ('hCursor', wt.HANDLE),
                ('hbrBackground', wt.HBRUSH), ('lpszMenuName', wt.LPCWSTR),
                ('lpszClassName', wt.LPCWSTR), ('hIconSm', wt.HICON)]


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [('biSize', wt.DWORD), ('biWidth', ctypes.c_long), ('biHeight', ctypes.c_long),
                ('biPlanes', wt.WORD), ('biBitCount', wt.WORD), ('biCompression', wt.DWORD),
                ('biSizeImage', wt.DWORD), ('biXPelsPerMeter', ctypes.c_long),
                ('biYPelsPerMeter', ctypes.c_long), ('biClrUsed', wt.DWORD), ('biClrImportant', wt.DWORD)]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [('bmiHeader', BITMAPINFOHEADER), ('bmiColors', wt.DWORD * 3)]


u32.RegisterClassExW.argtypes = [ctypes.POINTER(WNDCLASSEXW)]
u32.CreateWindowExW.argtypes = [wt.DWORD, wt.LPCWSTR, wt.LPCWSTR, wt.DWORD, ctypes.c_int, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, wt.HWND, wt.HMENU, wt.HINSTANCE, ctypes.c_void_p]
u32.CreateWindowExW.restype = wt.HWND
u32.GetWindowRect.argtypes = [wt.HWND, ctypes.POINTER(wt.RECT)]
u32.GetWindowLongW.argtypes = [wt.HWND, ctypes.c_int]
u32.WindowFromPoint.argtypes = [wt.POINT]
u32.WindowFromPoint.restype = wt.HWND
u32.GetForegroundWindow.restype = wt.HWND
u32.GetDC.argtypes = [wt.HWND]
u32.GetDC.restype = wt.HDC
u32.ReleaseDC.argtypes = [wt.HWND, wt.HDC]
u32.GetSystemMetrics.argtypes = [ctypes.c_int]
u32.SetProcessDpiAwarenessContext.argtypes = [ctypes.c_void_p]
u32.DefWindowProcW.argtypes = [wt.HWND, wt.UINT, ctypes.c_size_t, ctypes.c_ssize_t]
u32.DefWindowProcW.restype = ctypes.c_ssize_t
u32.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
u32.UpdateWindow.argtypes = [wt.HWND]
u32.PeekMessageW.argtypes = [ctypes.POINTER(wt.MSG), wt.HWND, wt.UINT, wt.UINT, wt.UINT]
u32.IsWindow.argtypes = [wt.HWND]
u32.DestroyWindow.argtypes = [wt.HWND]
g32.CreateSolidBrush.argtypes = [wt.DWORD]
g32.CreateSolidBrush.restype = wt.HBRUSH
g32.BitBlt.argtypes = [wt.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                       wt.HDC, ctypes.c_int, ctypes.c_int, wt.DWORD]
g32.CreateCompatibleDC.argtypes = [wt.HDC]
g32.CreateCompatibleDC.restype = wt.HDC
g32.CreateDIBSection.argtypes = [wt.HDC, ctypes.POINTER(BITMAPINFO), wt.UINT,
                                 ctypes.POINTER(ctypes.c_void_p), wt.HANDLE, wt.DWORD]
g32.CreateDIBSection.restype = wt.HBITMAP
g32.SelectObject.argtypes = [wt.HDC, wt.HGDIOBJ]
g32.SelectObject.restype = wt.HGDIOBJ
g32.DeleteObject.argtypes = [wt.HGDIOBJ]
g32.DeleteDC.argtypes = [wt.HDC]

SRCCOPY = 0x00CC0020
WS_EX_LAYERED = 0x00080000
WS_EX_NOACTIVATE = 0x08000000
WS_EX_TRANSPARENT = 0x00000020
WS_EX_TOOLWINDOW = 0x00000080
WS_EX_TOPMOST = 0x00000008
GWL_EXSTYLE = -20


def colorref(rgb):
    r, g, b = rgb
    return (b << 16) | (g << 8) | r


def pump(ms):
    msg = wt.MSG()
    t0 = time.time()
    while (time.time() - t0) * 1000 < ms:
        while u32.PeekMessageW(ctypes.byref(msg), None, 0, 0, 1):
            u32.TranslateMessage(ctypes.byref(msg))
            u32.DispatchMessageW(ctypes.byref(msg))
        time.sleep(0.01)


def grab(x, y, w, h):
    sdc = u32.GetDC(None)
    mdc = g32.CreateCompatibleDC(sdc)
    bmi = BITMAPINFO()
    bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    bmi.bmiHeader.biWidth = w
    bmi.bmiHeader.biHeight = -h
    bmi.bmiHeader.biPlanes = 1
    bmi.bmiHeader.biBitCount = 32
    bmi.bmiHeader.biCompression = 0
    bits = ctypes.c_void_p()
    hbmp = g32.CreateDIBSection(sdc, ctypes.byref(bmi), 0, ctypes.byref(bits), None, 0)
    old = g32.SelectObject(mdc, hbmp)
    g32.BitBlt(mdc, 0, 0, w, h, sdc, x, y, SRCCOPY)
    raw = ctypes.string_at(bits, w * h * 4)
    g32.SelectObject(mdc, old)
    g32.DeleteObject(hbmp)
    g32.DeleteDC(mdc)
    u32.ReleaseDC(None, sdc)
    out = {}
    for j in range(h):
        row = j * w * 4
        for i in range(w):
            o = row + i * 4
            out[(x + i, y + j)] = (raw[o + 2], raw[o + 1], raw[o])
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    dll = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(
        here, 'target', 'release', 'wgpet.dll')
    if not os.path.exists(dll):
        print('SKIP: 找不到 %s (先 cargo build --release)' % dll)
        return 0
    print('dll :', dll)
    u32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))

    lib = ctypes.WinDLL(dll)
    lib.wgime_pet_abi_version.restype = ctypes.c_uint32
    for f in ('wgime_pet_start', 'wgime_pet_stop', 'wgime_pet_hwnd', 'wgime_pet_frames',
              'wgime_pet_pause', 'wgime_pet_set_passthrough', 'wgime_pet_set_x',
              'wgime_pet_hold', 'wgime_pet_probe_count'):
        getattr(lib, f).restype = ctypes.c_ssize_t
    lib.wgime_pet_set_gait.argtypes = [ctypes.c_float]
    lib.wgime_pet_probe.argtypes = [ctypes.c_int, ctypes.POINTER(ctypes.c_float)]
    lib.wgime_pet_debug.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    lib.wgime_pet_debug.restype = ctypes.c_size_t

    chk('ABI 版本可读', lib.wgime_pet_abi_version() >= 1, 'abi=%d' % lib.wgime_pet_abi_version())

    hinst = ctypes.windll.kernel32.GetModuleHandleW(None)
    sw, sh = u32.GetSystemMetrics(0), u32.GetSystemMetrics(1)

    def wndproc(h, m, wp, lp):
        return u32.DefWindowProcW(h, m, wp, lp)

    WNDPROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wt.HWND, wt.UINT, ctypes.c_size_t, ctypes.c_ssize_t)
    proc = WNDPROC(wndproc)
    cls = 'WgPetVerifyBackdrop'
    wc = WNDCLASSEXW()
    wc.cbSize = ctypes.sizeof(WNDCLASSEXW)
    wc.lpfnWndProc = ctypes.cast(proc, ctypes.c_void_p)
    wc.hInstance = hinst
    wc.hbrBackground = g32.CreateSolidBrush(colorref(MAGENTA))
    wc.lpszClassName = cls
    if not u32.RegisterClassExW(ctypes.byref(wc)):
        print('backdrop register failed', ctypes.get_last_error())
        return 2
    back = u32.CreateWindowExW(0, cls, cls, 0x80000000, 0, sh - 460, sw, 480, None, None, hinst, None)
    chk('背景窗建出来', bool(back), 'rect=0,%d %s' % (sh - 460, '%dx480' % sw))
    u32.ShowWindow(back, 5)
    u32.UpdateWindow(back)
    pump(250)
    fg_before = u32.GetForegroundWindow()

    rc = lib.wgime_pet_start()
    chk('浮层启动成功', rc == 0, 'rc=%d' % rc)
    if rc != 0:
        n = lib.wgime_pet_last_error(None, 0)
        b = ctypes.create_string_buffer(n + 1)
        lib.wgime_pet_last_error(b, n)
        print('   last_error:', b.value.decode('utf-8', 'replace'))
        return 2
    hwnd = lib.wgime_pet_hwnd()
    chk('拿到窗口句柄', hwnd != 0, 'hwnd=0x%X' % hwnd)
    pump(200)

    ex = u32.GetWindowLongW(hwnd, GWL_EXSTYLE) & 0xFFFFFFFF
    want = {'LAYERED': WS_EX_LAYERED, 'NOACTIVATE': WS_EX_NOACTIVATE, 'TRANSPARENT': WS_EX_TRANSPARENT,
            'TOOLWINDOW': WS_EX_TOOLWINDOW, 'TOPMOST': WS_EX_TOPMOST}
    missing = [k for k, v in want.items() if not (ex & v)]
    chk('扩展样式五条齐', not missing, 'ex=0x%08X missing=%s' % (ex, missing or '-'))
    chk('没抢前台焦点', u32.GetForegroundWindow() == fg_before,
        'before=0x%X after=0x%X' % (fg_before, u32.GetForegroundWindow()))

    f0 = lib.wgime_pet_frames()
    time.sleep(2.0)
    f1 = lib.wgime_pet_frames()
    chk('真帧率 >= 50', (f1 - f0) / 2.0 >= 50, '%.1f fps' % ((f1 - f0) / 2.0))

    # 钉住位置/步态再采像素(AGENTS §5 规则 50: 必须冻住动画)
    lib.wgime_pet_set_x(int(sw * 0.4), 1)
    lib.wgime_pet_set_gait(0.25)
    pump(300)
    rcr = wt.RECT()
    u32.GetWindowRect(hwnd, ctypes.byref(rcr))
    W, H = rcr.right - rcr.left, rcr.bottom - rcr.top
    info('窗口', 'rect=%d,%d %dx%d' % (rcr.left, rcr.top, W, H))

    # 环境闸门: 背景必须是干净的纯品红(否则是屏幕上有遮罩层在压暗, 属于假红)
    clean, corner = False, None
    for attempt in range(30):
        corner = grab(rcr.left + 1, rcr.top + 1, 3, 3)[(rcr.left + 2, rcr.top + 2)]
        if near(corner, MAGENTA, 2):
            clean = True
            break
        if attempt == 0:
            info('环境闸门', '角点 %s != %s, 等屏幕恢复(关掉截图遮罩)' % (corner, MAGENTA))
        time.sleep(1.0)
    chk('采样环境干净(无遮罩层盖住屏幕)', clean,
        'attempts=%d corner=%s fg=0x%X' % (attempt + 1, corner, u32.GetForegroundWindow()))

    shot = grab(rcr.left, rcr.top, W, H)

    def px(x, y):
        return shot[(rcr.left + int(round(x)), rcr.top + int(round(y)))]

    corner = shot[(rcr.left + 3, rcr.top + 3)]
    chk('窗内空白 = 纯背景色(真透明, 非不透明黑底)', near(corner, MAGENTA, 2),
        'corner=%s want=%s' % (corner, MAGENTA))

    n_probe = lib.wgime_pet_probe_count()
    chk('渲染器报了标定点', n_probe >= 2, 'probe_count=%d' % n_probe)
    buf = (ctypes.c_float * 6)()
    body_pt = (W // 2, H // 2)
    for i in range(min(n_probe, 2)):
        lib.wgime_pet_probe(i, buf)
        x, y, cr, cg, cb, ca = list(buf)
        if i == 1:
            body_pt = (int(round(x)), int(round(y)))
        want_c = blend((cr * 255, cg * 255, cb * 255), ca, MAGENTA)
        got = px(x, y)
        chk('标定点%d 逐通道吻合 alpha=%.3f' % (i, ca), near(got, want_c, 1),
            'at(%.0f,%.0f) 实测=%s 期望=%s' % (x, y, got, want_c))

    distinct = len({c for c in shot.values()})
    chk('窗内颜色数够多(带抗锯齿; 硬边会明显偏少)', distinct >= MIN_DISTINCT,
        'distinct=%d (阈值 %d)' % (distinct, MIN_DISTINCT))

    # 穿透: 被动态整窗穿透(含本体)。本体位置用渲染器报的标定点, 别拿窗口正中 —— 那里是空的
    body_scr = (rcr.left + body_pt[0], rcr.top + body_pt[1])
    for tag, pt in (('透明处', (rcr.left + 3, rcr.top + 3)), ('本体处', body_scr)):
        wfp = u32.WindowFromPoint(wt.POINT(*pt))
        chk('被动态%s鼠标穿透' % tag, wfp != hwnd, 'wfp=0x%X self=0x%X' % (wfp, hwnd))

    # 交互态: 只摘 WS_EX_TRANSPARENT -> 只有画到的像素挡鼠标, 空白仍穿透, 前台不变
    lib.wgime_pet_set_passthrough(0)
    pump(200)
    hit_body = u32.WindowFromPoint(wt.POINT(*body_scr))
    chk('交互态: 本体可点(命中本窗)', hit_body == hwnd, 'wfp=0x%X self=0x%X' % (hit_body, hwnd))
    hit_blank = u32.WindowFromPoint(wt.POINT(rcr.left + 3, rcr.top + 3))
    chk('交互态: 空白处仍穿透', hit_blank != hwnd, 'wfp=0x%X self=0x%X' % (hit_blank, hwnd))
    chk('交互态: 仍没抢焦点', u32.GetForegroundWindow() == fg_before,
        'fg=0x%X' % u32.GetForegroundWindow())
    lib.wgime_pet_set_passthrough(1)
    pump(200)
    chk('回到被动态: 整窗又穿透', u32.WindowFromPoint(wt.POINT(*body_scr)) != hwnd)

    # 动画: 解冻后两拍像素必须有差异(窗口在移动, 所以按各自窗口矩形比)
    lib.wgime_pet_hold(0)
    lib.wgime_pet_pause(0)

    def local_grab():
        r = wt.RECT()
        u32.GetWindowRect(hwnd, ctypes.byref(r))
        raw = grab(r.left, r.top, r.right - r.left, r.bottom - r.top)
        return {(sx - r.left, sy - r.top): c for (sx, sy), c in raw.items()}, r

    time.sleep(0.45)
    a_img, a_rc = local_grab()
    time.sleep(0.45)
    b_img, b_rc = local_grab()
    diff = sum(1 for k in a_img if a_img[k] != b_img.get(k))
    chk('动画在动(两拍像素有差异)', diff > 200,
        'diff_pixels=%d  a_rect=%d b_rect=%d' % (diff, a_rc.left, b_rc.left))

    rc2 = lib.wgime_pet_stop()
    pump(400)
    chk('能正常关闭', rc2 == 0 and u32.IsWindow(hwnd) == 0,
        'rc=%d IsWindow=%d' % (rc2, u32.IsWindow(hwnd)))

    n = lib.wgime_pet_debug(None, 0)
    b = ctypes.create_string_buffer(n + 1)
    lib.wgime_pet_debug(b, n)
    print('--- init log ---')
    print(b.value.decode('utf-8', 'replace').strip())

    g32.DeleteObject(wc.hbrBackground)
    u32.DestroyWindow(back)

    bad = [n for n, ok, _ in SEEN if not ok]
    print('%d/%d 项通过' % (len(SEEN) - len(bad), len(SEEN)))
    if bad:
        print('FAILED: ' + ', '.join(bad))
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
