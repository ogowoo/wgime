# -*- coding: utf-8 -*-
"""wgpet.dll 客观验收(探针, 不入库)。全靠像素/句柄, 不靠肉眼。

  1) 逐像素 alpha —— 精灵不同半径叠在纯品红背景上, 必须是真半透明过渡
  2) 抗锯齿      —— 本体边缘要有中间色, 不是硬跳变
  3) 鼠标穿透    —— 没画到的地方(alpha=0)WindowFromPoint 必须跳过本窗
  4) 不抢焦点    —— 起浮层前后 GetForegroundWindow 不变
  5) 真帧率 + 动画在动 + 能干净关闭
  6) 上下方向    —— 眼睛画在中心上方, 采到眼睛色即证明 DIB 没被翻转

用法: python wg-rustpet-verify.py <wgpet.dll>
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

u32 = ctypes.WinDLL('user32', use_last_error=True)
g32 = ctypes.WinDLL('gdi32', use_last_error=True)

MAGENTA = (255, 0, 255)
BODY = (250, 158, 51)
GLOW1 = (255, 199, 89)      # alpha 0.35
GLOW2 = (255, 230, 153)     # alpha 0.18
EYE = (26, 23, 31)

SEEN = []


def chk(name, ok, detail=''):
    SEEN.append((name, bool(ok), detail))
    print('%-4s %-40s %s' % ('ok' if ok else 'FAIL', name, detail), flush=True)
    return ok


def info(tag, detail):
    print('     %-40s %s' % (tag, detail), flush=True)


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
    buf = ctypes.string_at(bits, w * h * 4)
    out = {}
    for j in range(h):
        row = j * w * 4
        for i in range(w):
            o = row + i * 4
            out[(x + i, y + j)] = (buf[o + 2], buf[o + 1], buf[o])
    g32.SelectObject(mdc, old)
    g32.DeleteObject(hbmp)
    g32.DeleteDC(mdc)
    u32.ReleaseDC(None, sdc)
    return out


def main():
    dll = os.path.abspath(sys.argv[1])
    print('dll :', dll)
    u32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))

    lib = ctypes.WinDLL(dll)
    lib.wgime_pet_abi_version.restype = ctypes.c_uint32
    lib.wgime_pet_spike_start.restype = ctypes.c_int
    lib.wgime_pet_spike_stop.restype = ctypes.c_int
    lib.wgime_pet_spike_hwnd.restype = ctypes.c_ssize_t
    lib.wgime_pet_spike_frames.restype = ctypes.c_uint64
    lib.wgime_pet_spike_pause.argtypes = [ctypes.c_int]
    lib.wgime_pet_spike_sprite.argtypes = [ctypes.POINTER(ctypes.c_float)]
    lib.wgime_pet_debug.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    lib.wgime_pet_debug.restype = ctypes.c_size_t

    chk('ABI 版本可读', lib.wgime_pet_abi_version() == 1, 'abi=%d' % lib.wgime_pet_abi_version())

    hinst = ctypes.windll.kernel32.GetModuleHandleW(None)
    sw, sh = u32.GetSystemMetrics(0), u32.GetSystemMetrics(1)

    # 背景: 纯品红, 铺满浮层会经过的整条底部带(避免碰到任务栏)
    bx, by = 0, sh - 580
    bw, bh = sw, 520

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
    back = u32.CreateWindowExW(0, cls, cls, 0x80000000, bx, by, bw, bh, None, None, hinst, None)
    chk('背景窗建出来', bool(back), 'rect=%d,%d %dx%d' % (bx, by, bw, bh))
    u32.ShowWindow(back, 5)
    u32.UpdateWindow(back)
    pump(250)
    fg_before = u32.GetForegroundWindow()

    rc = lib.wgime_pet_spike_start()
    chk('浮层启动成功', rc == 0, 'rc=%d' % rc)
    if rc != 0:
        n = lib.wgime_pet_last_error(None, 0)
        b = ctypes.create_string_buffer(n + 1)
        lib.wgime_pet_last_error(b, n)
        print('   last_error:', b.value.decode('utf-8', 'replace'))
        return 2
    hwnd = lib.wgime_pet_spike_hwnd()
    chk('拿到窗口句柄', hwnd != 0, 'hwnd=0x%X' % hwnd)
    pump(150)

    ex = u32.GetWindowLongW(hwnd, GWL_EXSTYLE) & 0xFFFFFFFF
    want = {'LAYERED': WS_EX_LAYERED, 'NOACTIVATE': WS_EX_NOACTIVATE, 'TRANSPARENT': WS_EX_TRANSPARENT,
            'TOOLWINDOW': WS_EX_TOOLWINDOW, 'TOPMOST': WS_EX_TOPMOST}
    missing = [k for k, v in want.items() if not (ex & v)]
    chk('扩展样式五条齐', not missing, 'ex=0x%08X missing=%s' % (ex, missing or '-'))
    chk('没抢前台焦点', u32.GetForegroundWindow() == fg_before,
        'before=0x%X after=0x%X' % (fg_before, u32.GetForegroundWindow()))

    f0 = lib.wgime_pet_spike_frames()
    time.sleep(2.0)
    f1 = lib.wgime_pet_spike_frames()
    chk('真帧率 >= 50', (f1 - f0) / 2.0 >= 50, '%.1f fps' % ((f1 - f0) / 2.0))

    # 冻住动画 + 等几何连续三拍一致再采像素(AGENTS §5 规则 50)
    lib.wgime_pet_spike_pause(1)
    buf = (ctypes.c_float * 5)()
    prev, same = None, 0
    for _ in range(60):
        lib.wgime_pet_spike_sprite(buf)
        cur = tuple(round(v, 3) for v in buf)
        same = same + 1 if cur == prev else 0
        if same >= 3:
            break
        prev = cur
        time.sleep(0.05)
    chk('冻结后几何稳定', same >= 3, 'sprite=%s' % ([round(v, 1) for v in buf],))
    time.sleep(0.25)
    rcr = wt.RECT()
    u32.GetWindowRect(hwnd, ctypes.byref(rcr))
    cx, cy, rb, rg1, rg2 = list(buf)
    icx, icy = rcr.left + int(round(cx)), rcr.top + int(round(cy))
    w, h = rcr.right - rcr.left, rcr.bottom - rcr.top
    info('窗口', 'rect=%d,%d %dx%d 精灵中心=(%d,%d) r=%.1f/%.1f/%.1f'
         % (rcr.left, rcr.top, w, h, icx, icy, rb, rg1, rg2))

    # 环境闸门: 屏幕前的人一按截图/开个半透明窗, 整块读数就变成 40% 品红 (真踩过)。
    # 采像素前先确认背景色是干净的纯品红, 干净了才往下断言 —— 否则是假红不是真 bug。
    clean = False
    for attempt in range(30):
        p = grab(rcr.left + 1, rcr.top + 1, 3, 3)[(rcr.left + 2, rcr.top + 2)]
        if near(p, MAGENTA, 2):
            clean = True
            break
        if attempt == 0:
            info('环境闸门', '角点读数 %s != %s, 等待屏幕恢复(把截图遮罩/悬浮层关掉)' % (p, MAGENTA))
        time.sleep(1.0)
    chk('采样环境干净(没有遮罩层盖住屏幕)', clean,
        'attempts=%d corner=%s fg=0x%X' % (attempt + 1, p, u32.GetForegroundWindow()))

    shot = grab(rcr.left, rcr.top, w, h)

    def at(dx, dy):
        return shot[(icx + dx, icy + dy)]

    corner = shot[(rcr.left + 3, rcr.top + 3)]
    chk('窗内空白 = 纯背景色(真透明, 非不透明黑底)', near(corner, MAGENTA, 2),
        'corner=%s want=%s' % (corner, MAGENTA))
    core = at(0, 0)
    chk('本体核心 = 本体色', near(core, BODY, 10), 'core=%s want≈%s' % (core, BODY))
    g1 = at(0, -int(rg1 * 0.8))
    # 注意这里叠了**两层**: 内光晕压在(外光晕压过品红)之上
    a1 = blend(GLOW1, 0.35, blend(GLOW2, 0.18, MAGENTA))
    chk('内光晕 = 35%% 叠在(18%% 外光晕+品红)上(三层 alpha 逐通道吻合)', near(g1, a1, 8),
        'pix=%s want≈%s' % (g1, a1))
    g2 = at(0, -int((rg1 + rg2) / 2))
    a2 = blend(GLOW2, 0.18, MAGENTA)
    chk('外光晕 = 18%% 叠加', near(g2, a2, 16), 'pix=%s want≈%s' % (g2, a2))
    # 抗锯齿: 沿半径方向扫过"本体→内光晕→外光晕→背景"三层边界,
    # 硬边渲染只会有 4 种平坦色; 有中间色才说明真的抗锯齿
    flat = [BODY, a1, a2, MAGENTA]
    prof = [at(dx, 0) for dx in range(int(rb) - 6, int(rg2) + 8)]
    # 容差取 2: 期望值是自己按整数四舍五入算的, 与渲染差 ±1 属正常;
    # 取太大(=6)会把真正的边缘过渡像素也当成平坦色而漏掉。
    aa = [c for c in prof if not any(near(c, f, 2) for f in flat)]
    chk('三层边界都有中间色(真抗锯齿)', len(aa) >= 3,
        'aa=%s' % (aa,))
    eye = at(int(rb * 0.32), -5)
    chk('眼睛在上方(证明 DIB 没被上下翻转)', near(eye, EYE, 26), 'pix=%s want≈%s' % (eye, EYE))

    # 穿透: 没画到的地方必须放过鼠标; 实测 WS_EX_TRANSPARENT+分层窗连本体也放过(整窗穿透)
    for tag, pt in (('透明处', (rcr.left + 3, rcr.top + 3)), ('本体处', (icx, icy)),
                    ('光晕处', (icx, icy - int(rg1)))):
        wfp = u32.WindowFromPoint(wt.POINT(*pt))
        chk('%s鼠标穿透' % tag, wfp != hwnd, 'wfp=0x%X self=0x%X' % (wfp, hwnd))

    # 交互态: 摘掉 WS_EX_TRANSPARENT -> 只有画到的像素挡鼠标, 空白照旧穿透
    lib.wgime_pet_spike_interactive.argtypes = [ctypes.c_int]
    lib.wgime_pet_spike_interactive(1)
    pump(150)
    hit_body = u32.WindowFromPoint(wt.POINT(icx, icy))
    chk('交互态: 本体可点(命中本窗)', hit_body == hwnd, 'wfp=0x%X self=0x%X' % (hit_body, hwnd))
    hit_blank = u32.WindowFromPoint(wt.POINT(rcr.left + 3, rcr.top + 3))
    chk('交互态: 空白处仍穿透', hit_blank != hwnd, 'wfp=0x%X self=0x%X' % (hit_blank, hwnd))
    chk('交互态: 仍没抢焦点', u32.GetForegroundWindow() == fg_before,
        'fg=0x%X' % u32.GetForegroundWindow())
    lib.wgime_pet_spike_interactive(0)
    pump(150)
    chk('回到被动态: 整窗又穿透', u32.WindowFromPoint(wt.POINT(icx, icy)) != hwnd,
        'wfp=0x%X' % u32.WindowFromPoint(wt.POINT(icx, icy)))

    # 动画: 必须按**各自的窗口矩形**抓(窗口在横移, 拿旧矩形去抓只会抓到背景)
    def local_grab():
        r = wt.RECT()
        u32.GetWindowRect(hwnd, ctypes.byref(r))
        ww, hh = r.right - r.left, r.bottom - r.top
        raw = grab(r.left, r.top, ww, hh)
        return {(sx - r.left, sy - r.top): c for (sx, sy), c in raw.items()}, r

    lib.wgime_pet_spike_pause(0)
    time.sleep(0.35)
    a_img, a_rc = local_grab()
    a_sp = tuple(buf)
    time.sleep(0.4)
    b_img, b_rc = local_grab()
    lib.wgime_pet_spike_sprite(buf)
    b_sp = tuple(buf)
    diff = sum(1 for k in a_img if a_img[k] != b_img.get(k))
    chk('动画在动(精灵几何在变)', a_sp[:3] != b_sp[:3],
        'a=%s b=%s' % ([round(v, 1) for v in a_sp[:3]], [round(v, 1) for v in b_sp[:3]]))
    chk('动画在动(两拍像素有差异)', diff > 200,
        'diff_pixels=%d  a_rect=%d,%d b_rect=%d,%d' % (diff, a_rc.left, a_rc.top, b_rc.left, b_rc.top))

    rc2 = lib.wgime_pet_spike_stop()
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
