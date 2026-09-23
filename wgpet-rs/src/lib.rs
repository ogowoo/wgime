//! wgpet.dll — WgIme 桌面宠物浮层 (Rust)
//!
//! 渲染路径: **D2D 画到 32bpp 预乘 alpha 的 DIB, 再用 UpdateLayeredWindow 提交**。
//!
//! 为什么不是 DirectComposition(第八十六轮实测结论, 别走回头路):
//! DComp 的合成窗内容**不做按 alpha 的命中测试** —— WindowFromPoint 照样命中整块窗外框,
//! 鼠标点不穿; 唯一能强制穿透的 `SetWindowRgn` 又会把 DComp 内容一起裁掉
//! (实测: 装空区域后精灵像素变成背景色, 关掉区域立刻回来)。
//! `UpdateLayeredWindow` 的分层窗则是**逐像素按 alpha 做命中测试**: 没画到的像素
//! (alpha=0) 鼠标直接穿过去, 画到的像素才挡鼠标 —— 这正好是桌面宠物要的语义,
//! 而且没有区域裁剪的副作用。抗锯齿/逐像素半透明由 D2D 负责, 与 DComp 路线完全同级。
//!
//! 窗口刻意做成**精灵大小**并跟着角色移动: 全屏窗 + 手算脏矩形那一整类残影 bug
//! 由此天然不存在(每帧整块重画, 无脏矩形可算错), 每帧要合成的像素也只有几百乘几百。

#![allow(non_snake_case)]

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU64, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use windows::core::*;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;
use windows::Win32::Graphics::Dxgi::Common::DXGI_FORMAT_B8G8R8A8_UNORM;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::WindowsAndMessaging::*;

// ---------------------------------------------------------------- 导出契约

/// 改动 ABI 就 +1; 宿主先问这个再决定要不要用本 DLL。
const ABI_VERSION: u32 = 1;

/// 窗口尺寸 = 精灵外接框(含发光) + 余量。窗越小每帧要合成/提交的像素越少。
const WIN_W: i32 = 260;
const WIN_H: i32 = 260;
/// 精灵中心在窗口里的位置
const CX: f32 = WIN_W as f32 * 0.5;
const CY: f32 = WIN_H as f32 * 0.5;

static STOP: AtomicBool = AtomicBool::new(false);
static HWND_MAIN: AtomicIsize = AtomicIsize::new(0);
static READY: AtomicBool = AtomicBool::new(false);
static FRAMES: AtomicU64 = AtomicU64::new(0);
static PAUSED: AtomicBool = AtomicBool::new(false);

/// 帧率上限。UpdateLayeredWindow **不做 vsync 节流**(实测不设上限能跑到 2085fps,
/// 纯烧 CPU), 所以必须自己限速。
const FPS_CAP: f32 = 120.0;

#[link(name = "winmm")]
unsafe extern "system" {
    fn timeBeginPeriod(uperiod: u32) -> u32;
    fn timeEndPeriod(uperiod: u32) -> u32;
}

static LAST_ERR: Mutex<Option<String>> = Mutex::new(None);
/// 最近一帧的精灵几何 [cx, cy, r_body, r_glow1, r_glow2](窗口坐标), 给宿主验收探针用
static SPRITE: Mutex<[f32; 5]> = Mutex::new([0.0; 5]);
/// 初始化逐步日志 —— 出问题先看它, 别猜
static DBG: Mutex<String> = Mutex::new(String::new());

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 把 panic 挡在 FFI 边界内: 绝不让展开跨过 DLL 边界把宿主(输入法)带走。
fn guard<F: FnOnce() -> i32>(f: F) -> i32 {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(rc) => rc,
        Err(_) => -99,
    }
}

fn last_error(s: String) {
    if let Ok(mut g) = LAST_ERR.lock() {
        *g = Some(s);
    }
}

fn dbg(s: String) {
    if let Ok(mut g) = DBG.lock() {
        g.push_str(&s);
        g.push('\n');
    }
}

#[no_mangle]
pub extern "C" fn wgime_pet_abi_version() -> u32 {
    ABI_VERSION
}

/// 起浮层(尖刺版: 一个会呼吸/横移的发光团)。返回 0 成功。
/// -1 已在跑, -2 建窗超时, -3 起线程失败, -99 内部 panic
#[no_mangle]
pub extern "C" fn wgime_pet_spike_start() -> i32 {
    guard(|| {
        if READY.load(Ordering::SeqCst) {
            return -1;
        }
        STOP.store(false, Ordering::SeqCst);
        FRAMES.store(0, Ordering::SeqCst);
        let t = thread::Builder::new().name("wgpet-render".into()).spawn(|| {
            if let Err(e) = render_thread() {
                last_error(format!("render thread: {e}"));
            }
            READY.store(false, Ordering::SeqCst);
        });
        if t.is_err() {
            return -3;
        }
        let t0 = Instant::now();
        while !READY.load(Ordering::SeqCst) && t0.elapsed() < Duration::from_secs(5) {
            thread::sleep(Duration::from_millis(10));
        }
        if !READY.load(Ordering::SeqCst) {
            return -2;
        }
        0
    })
}

#[no_mangle]
pub extern "C" fn wgime_pet_spike_stop() -> i32 {
    guard(|| {
        STOP.store(true, Ordering::SeqCst);
        let h = HWND_MAIN.load(Ordering::SeqCst);
        if h != 0 {
            unsafe {
                let _ = PostMessageW(HWND(h as *mut c_void), WM_CLOSE, WPARAM(0), LPARAM(0));
            }
        }
        0
    })
}

/// 被动/交互切换。被动(默认)=整窗穿透, 桌面上点什么都不会被宠物吃掉;
/// 交互=摘掉 `WS_EX_TRANSPARENT`, 于是**只有画到的像素**(alpha>0)才挡鼠标,
/// 面板外的空白照旧穿透 —— 点工具不会丢输入框焦点。
#[no_mangle]
pub extern "C" fn wgime_pet_spike_interactive(on: i32) -> i32 {
    guard(|| unsafe {
        let h = HWND(HWND_MAIN.load(Ordering::SeqCst) as *mut c_void);
        if h.0.is_null() {
            return -1;
        }
        let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
        let new = if on != 0 {
            ex & !(WS_EX_TRANSPARENT.0)
        } else {
            ex | WS_EX_TRANSPARENT.0
        };
        SetWindowLongW(h, GWL_EXSTYLE, new as i32);
        let _ = SetWindowPos(
            h,
            None,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
        0
    })
}

/// 浮层窗口句柄(0 = 还没建出来)
#[no_mangle]
pub extern "C" fn wgime_pet_spike_hwnd() -> isize {
    HWND_MAIN.load(Ordering::SeqCst)
}

/// 已提交的帧数。宿主隔一段时间取两次差就知道真帧率。
#[no_mangle]
pub extern "C" fn wgime_pet_spike_frames() -> u64 {
    FRAMES.load(Ordering::SeqCst)
}

/// 冻结/解冻动画(采像素前必须冻住, 否则拿到的是动着的坐标 —— AGENTS §5 规则 50)。
/// `on` 显式给 1/0, 不做 toggle。
#[no_mangle]
pub extern "C" fn wgime_pet_spike_pause(on: i32) -> i32 {
    PAUSED.store(on != 0, Ordering::SeqCst);
    0
}

/// 当前精灵几何(窗口坐标): [cx, cy, r_body, r_glow1, r_glow2]。宿主靠它知道该采哪几个像素。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_spike_sprite(out: *mut f32) -> i32 {
    if out.is_null() {
        return -1;
    }
    match SPRITE.lock() {
        Ok(g) => {
            std::ptr::copy_nonoverlapping(g.as_ptr(), out, 5);
            0
        }
        Err(_) => -1,
    }
}

/// 取最近一次错误(UTF-8)。buf=NULL 返回所需字节数。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_last_error(buf: *mut u8, cap: usize) -> usize {
    let s = LAST_ERR.lock().ok().and_then(|g| g.clone()).unwrap_or_default();
    copy_out(s.as_bytes(), buf, cap)
}

/// 取初始化日志(UTF-8)。buf=NULL 返回所需字节数。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_debug(buf: *mut u8, cap: usize) -> usize {
    let s = DBG.lock().map(|g| g.clone()).unwrap_or_default();
    copy_out(s.as_bytes(), buf, cap)
}

unsafe fn copy_out(bytes: &[u8], buf: *mut u8, cap: usize) -> usize {
    if buf.is_null() {
        return bytes.len();
    }
    let n = bytes.len().min(cap);
    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, n);
    n
}

// ---------------------------------------------------------------- 窗口

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        // 命中测试交给分层窗的逐像素 alpha 规则, 这里不画了但也不额外挡
        WM_NCHITTEST => DefWindowProcW(hwnd, msg, wp, lp),
        WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wp, lp),
    }
}

/// 一块 32bpp 预乘 alpha 的 DIB + 绑在它上面的 D2D 渲染目标。
/// 全部字段必须活到窗口销毁(COM 引用计数; 提前 drop 会把渲染目标拆掉)。
struct Surface {
    memdc: HDC,
    hbmp: HBITMAP,
    old: HGDIOBJ,
    bits: *mut c_void,
    d2d: ID2D1DCRenderTarget,
    rt: ID2D1RenderTarget,
    _factory: ID2D1Factory,
    body: ID2D1SolidColorBrush,
    glow1: ID2D1SolidColorBrush,
    glow2: ID2D1SolidColorBrush,
    eye: ID2D1SolidColorBrush,
}

unsafe impl Send for Surface {}

impl Drop for Surface {
    fn drop(&mut self) {
        unsafe {
            let _ = SelectObject(self.memdc, self.old);
            let _ = DeleteObject(self.hbmp);
            let _ = DeleteDC(self.memdc);
        }
    }
}

fn render_thread() -> Result<()> {
    unsafe {
        let hinst = GetModuleHandleW(None)?;
        let cls_name = wide("WgpetOverlay");
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst.into(),
            lpszClassName: PCWSTR(cls_name.as_ptr()),
            ..Default::default()
        };
        if RegisterClassExW(&wc) == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS {
            return Err(Error::from_win32());
        }

        // 分层窗 + 鼠标穿透 + 不激活 + 不进任务栏 + 置顶。
        // 注意**不设** WS_EX_NOREDIRECTIONBITMAP: 那是 DComp 路线的东西。
        let ex = WS_EX_LAYERED
            | WS_EX_TRANSPARENT
            | WS_EX_NOACTIVATE
            | WS_EX_TOOLWINDOW
            | WS_EX_TOPMOST;
        let sw = GetSystemMetrics(SM_CXSCREEN);
        let sh = GetSystemMetrics(SM_CYSCREEN);
        let y = sh - WIN_H - 160;
        let hwnd = CreateWindowExW(
            ex,
            PCWSTR(cls_name.as_ptr()),
            PCWSTR(wide("wgpet · 桌面宠物").as_ptr()),
            WS_POPUP,
            (sw - WIN_W) / 2,
            y,
            WIN_W,
            WIN_H,
            None,
            None,
            hinst,
            None,
        )?;
        HWND_MAIN.store(hwnd.0 as isize, Ordering::SeqCst);
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        dbg(format!("window ok hwnd=0x{:X} {}x{}", hwnd.0 as isize, WIN_W, WIN_H));

        let surf = create_surface()?;
        let screen_dc = GetDC(None);
        let mut anim = Anim { t0: Instant::now(), frozen: None };
        timeBeginPeriod(1);
        READY.store(true, Ordering::SeqCst);
        last_error(String::new());

        let period = Duration::from_secs_f32(1.0 / FPS_CAP);
        let mut next = Instant::now();
        let mut msg = MSG::default();
        'outer: loop {
            if STOP.load(Ordering::SeqCst) {
                break;
            }
            while PeekMessageW(&mut msg, None, 0, 0, PM_REMOVE).as_bool() {
                if msg.message == WM_QUIT {
                    break 'outer;
                }
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            let t = anim.time(PAUSED.load(Ordering::SeqCst));
            // 角色横移 = 移动窗口(而不是画在固定大窗里): 窗口只跟着角色走
            let wx = (sw - WIN_W) / 2 + ((t * 1.1).sin() * (sw as f32 * 0.28)) as i32;
            draw(&surf, t)?;
            present(hwnd, screen_dc, &surf, wx, y)?;
            FRAMES.fetch_add(1, Ordering::SeqCst);

            next += period;
            let now = Instant::now();
            if next > now {
                thread::sleep(next - now);
            } else {
                next = now; // 落后了就丢时间, 不追帧
            }
        }
        timeEndPeriod(1);

        let _ = ReleaseDC(None, screen_dc);
        let _ = DestroyWindow(hwnd);
        HWND_MAIN.store(0, Ordering::SeqCst);
        Ok(())
    }
}

struct Anim {
    t0: Instant,
    frozen: Option<f32>,
}

impl Anim {
    fn time(&mut self, paused: bool) -> f32 {
        let el = self.t0.elapsed().as_secs_f32();
        if paused {
            *self.frozen.get_or_insert(el)
        } else {
            self.frozen = None;
            el
        }
    }
}

unsafe fn create_surface() -> Result<Surface> {
    let screen_dc = GetDC(None);
    let memdc = CreateCompatibleDC(screen_dc);
    let bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: WIN_W,
            biHeight: -WIN_H, // 负 = 自上而下
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut bits: *mut c_void = std::ptr::null_mut();
    let hbmp = CreateDIBSection(memdc, &bmi, DIB_RGB_COLORS, &mut bits, None, 0)?;
    let old = SelectObject(memdc, HGDIOBJ(hbmp.0));
    ReleaseDC(None, screen_dc);
    dbg("DIB section ok (32bpp, premultiplied)".into());

    // D2D 直接画到这块 DIB 上(DC 渲染目标 = 软件光栅, 与分层窗天然配对)
    let factory: ID2D1Factory = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, None)?;
    let props = D2D1_RENDER_TARGET_PROPERTIES {
        r#type: D2D1_RENDER_TARGET_TYPE_SOFTWARE,
        pixelFormat: D2D1_PIXEL_FORMAT {
            format: DXGI_FORMAT_B8G8R8A8_UNORM,
            alphaMode: D2D1_ALPHA_MODE_PREMULTIPLIED,
        },
        dpiX: 96.0,
        dpiY: 96.0,
        usage: D2D1_RENDER_TARGET_USAGE_NONE,
        minLevel: D2D1_FEATURE_LEVEL_DEFAULT,
    };
    let d2d = factory.CreateDCRenderTarget(&props)?;
    let rt: ID2D1RenderTarget = d2d.cast()?;
    // 渲染目标 dpi=96 + DIB 是 96dpi, 于是 1 DIP = 1 像素, 坐标即像素
    debug_assert_eq!(props.dpiX, 96.0);
    dbg("D2D DC render target ok".into());

    let mk = |c: D2D1_COLOR_F| -> Result<ID2D1SolidColorBrush> { rt.CreateSolidColorBrush(&c, None) };
    let body = mk(D2D1_COLOR_F { r: 0.98, g: 0.62, b: 0.20, a: 1.0 })?;
    let glow1 = mk(D2D1_COLOR_F { r: 1.0, g: 0.78, b: 0.35, a: 0.35 })?;
    let glow2 = mk(D2D1_COLOR_F { r: 1.0, g: 0.90, b: 0.60, a: 0.18 })?;
    let eye = mk(D2D1_COLOR_F { r: 0.10, g: 0.09, b: 0.12, a: 1.0 })?;

    Ok(Surface {
        memdc,
        hbmp,
        old,
        bits,
        d2d,
        rt,
        _factory: factory,
        body,
        glow1,
        glow2,
        eye,
    })
}

unsafe fn draw(s: &Surface, t: f32) -> Result<()> {
    let rc = RECT { left: 0, top: 0, right: WIN_W, bottom: WIN_H };
    s.d2d.BindDC(s.memdc, &rc)?;
    s.rt.BeginDraw();
    s.rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));

    let breath = 1.0 + (t * 2.2).sin() * 0.05;
    let cy = CY + (t * 1.7).sin() * 8.0;
    let rb = 34.0 * breath;
    let rg1 = 46.0 * breath;
    let rg2 = 62.0 * breath;
    if let Ok(mut g) = SPRITE.lock() {
        *g = [CX, cy, rb, rg1, rg2];
    }

    let ell = |x: f32, y: f32, rx: f32, ry: f32| D2D1_ELLIPSE {
        point: D2D_POINT_2F { x, y },
        radiusX: rx,
        radiusY: ry,
    };
    // 分层发光: 叠在桌面上会真的半透明过渡(逐像素 alpha 的可视证据), 边缘圆滑靠 D2D 抗锯齿
    s.rt.FillEllipse(&ell(CX, cy, rg2, rg2), &s.glow2);
    s.rt.FillEllipse(&ell(CX, cy, rg1, rg1), &s.glow1);
    s.rt.FillEllipse(&ell(CX, cy, rb, rb * 0.92), &s.body);
    let ex = 11.0 * breath;
    s.rt.FillEllipse(&ell(CX - ex, cy - 5.0, 4.2, 4.8), &s.eye);
    s.rt.FillEllipse(&ell(CX + ex, cy - 5.0, 4.2, 4.8), &s.eye);

    s.rt.EndDraw(None, None)?;
    Ok(())
}

/// 提交这一帧: UpdateLayeredWindow 同时负责"移到哪"和"长什么样"。
unsafe fn present(hwnd: HWND, screen_dc: HDC, s: &Surface, x: i32, y: i32) -> Result<()> {
    let dst = POINT { x, y };
    let size = SIZE { cx: WIN_W, cy: WIN_H };
    let src = POINT { x: 0, y: 0 };
    let blend = BLENDFUNCTION {
        BlendOp: AC_SRC_OVER as u8,
        BlendFlags: 0,
        SourceConstantAlpha: 255,
        AlphaFormat: AC_SRC_ALPHA as u8,
    };
    let _ = s.bits; // bits 只是给 D2D 写的那块内存, 这里用不到
    UpdateLayeredWindow(
        hwnd,
        screen_dc,
        Some(&dst),
        Some(&size),
        s.memdc,
        Some(&src),
        COLORREF(0),
        Some(&blend),
        ULW_ALPHA,
    )
}
