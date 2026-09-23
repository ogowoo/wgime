//! wgpet.dll — WgIme 桌面宠物浮层 (Rust)
//!
//! 渲染路径: **D2D 画到 32bpp 预乘 alpha 的 DIB, 再用 UpdateLayeredWindow 提交**。
//!
//! 为什么不是 DirectComposition(第八十六轮实测结论, 别走回头路):
//! DComp 的合成窗内容**不做按 alpha 的命中测试** —— `WindowFromPoint` 照样命中整块窗外框,
//! 鼠标点不穿; 唯一能强制穿透的 `SetWindowRgn` 又会把 DComp 内容一起裁掉
//! (实测: 装空区域后精灵像素变成背景色, 关掉立刻回来)。
//! `UpdateLayeredWindow` 的分层窗则是**逐像素按 alpha 做命中测试**: 没画到的像素
//! (alpha=0) 鼠标直接穿过去, 画到的像素才挡鼠标 —— 这正是桌面宠物要的语义,
//! 而且没有区域裁剪的副作用。抗锯齿/逐像素半透明由 D2D 负责, 与 DComp 路线完全同级。
//!
//! 窗口刻意做成**精灵大小**并跟着角色移动: 全屏窗 + 手算脏矩形那一整类残影 bug
//! 由此天然不存在(每帧整块重画, 无脏矩形可算错), 每帧要合成的像素也只有几百乘几百。

#![allow(non_snake_case)]

mod art;

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

// ---------------------------------------------------------------- 常量

/// 改动 ABI 就 +1; 宿主先问这个再决定要不要用本 DLL。
const ABI_VERSION: u32 = 1;

/// 窗口尺寸 = 角色外接框 + 余量(含抬脚/摆尾/软阴影)。窗越小每帧提交的像素越少。
const WIN_W: i32 = 300;
const WIN_H: i32 = 280;
/// 角色"脚底中心"在窗口里的位置
const ANCHOR_X: f32 = WIN_W as f32 * 0.52;
const ANCHOR_Y: f32 = WIN_H as f32 - 40.0;
/// 角色整体缩放
const DOG_SCALE: f32 = 1.15;
/// 一个完整步态周期对应的前进距离(像素) —— 步态相位按走过的距离推进, 脚不会打滑
const GAIT_CYCLE_PX: f32 = 74.0;
/// 走 / 跑 速度(像素/秒)
const WALK_SPEED: f32 = 96.0;
const RUN_SPEED: f32 = 340.0;
/// 见到鼠标就跑开的水平距离
const FLEE_DIST: f32 = 130.0;
/// 看鼠标的距离
const LOOK_DIST: f32 = 460.0;
/// 活动范围(屏幕宽度的比例)
const RANGE_LO: f32 = 0.06;
const RANGE_HI: f32 = 0.94;

/// 帧率上限。UpdateLayeredWindow **不做 vsync 节流**(实测不设上限能跑到 2085fps,
/// 纯烧 CPU), 所以必须自己限速。
const FPS_CAP: f32 = 120.0;

#[link(name = "winmm")]
unsafe extern "system" {
    fn timeBeginPeriod(uperiod: u32) -> u32;
    fn timeEndPeriod(uperiod: u32) -> u32;
}

static STOP: AtomicBool = AtomicBool::new(false);
static HWND_MAIN: AtomicIsize = AtomicIsize::new(0);
static READY: AtomicBool = AtomicBool::new(false);
static FRAMES: AtomicU64 = AtomicU64::new(0);
static PAUSED: AtomicBool = AtomicBool::new(false);
static LAST_ERR: Mutex<Option<String>> = Mutex::new(None);
static DBG: Mutex<String> = Mutex::new(String::new());
/// 探针标定点(窗口坐标 + 预期颜色/alpha), 由渲染帧写入
static PROBE: Mutex<[[f32; 6]; PROBE_N]> = Mutex::new([[0.0; 6]; PROBE_N]);

const PROBE_N: usize = 2;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

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

// ---------------------------------------------------------------- 导出

#[no_mangle]
pub extern "C" fn wgime_pet_abi_version() -> u32 {
    ABI_VERSION
}

/// 起浮层。返回 0 成功; -1 已在跑, -2 建窗超时, -3 起线程失败, -99 内部 panic
#[no_mangle]
pub extern "C" fn wgime_pet_start() -> i32 {
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
pub extern "C" fn wgime_pet_stop() -> i32 {
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

#[no_mangle]
pub extern "C" fn wgime_pet_hwnd() -> isize {
    HWND_MAIN.load(Ordering::SeqCst)
}

#[no_mangle]
pub extern "C" fn wgime_pet_frames() -> u64 {
    FRAMES.load(Ordering::SeqCst)
}

/// 冻结/解冻动画(采像素前必须冻住 —— AGENTS §5 规则 50)。`on` 显式给 1/0。
#[no_mangle]
pub extern "C" fn wgime_pet_pause(on: i32) -> i32 {
    PAUSED.store(on != 0, Ordering::SeqCst);
    0
}

/// 被动(=1, 默认)整窗鼠标穿透; 交互(=0)只摘 `WS_EX_TRANSPARENT`,
/// 于是只有画到的像素挡鼠标, 面板外空白照旧穿透, 前台全程不变。
#[no_mangle]
pub extern "C" fn wgime_pet_set_passthrough(on: i32) -> i32 {
    guard(|| unsafe {
        let h = HWND(HWND_MAIN.load(Ordering::SeqCst) as *mut c_void);
        if h.0.is_null() {
            return -1;
        }
        let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
        let new = if on != 0 {
            ex | WS_EX_TRANSPARENT.0
        } else {
            ex & !(WS_EX_TRANSPARENT.0)
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

/// 把角色直接放到屏幕上的某个 x(采像素/演示用), 并可选地钉住朝向。返回 0。
#[no_mangle]
pub extern "C" fn wgime_pet_set_x(x: i32, face: i32) -> i32 {
    guard(|| {
        let mut g = match PET.lock() {
            Ok(g) => g,
            Err(_) => return -1,
        };
        g.x = x as f32;
        g.v = 0.0;
        if face != 0 {
            g.face = if face > 0 { 1.0 } else { -1.0 };
        }
        g.hold = true;
        0
    })
}

#[no_mangle]
pub extern "C" fn wgime_pet_hold(off: i32) -> i32 {
    guard(|| {
        if let Ok(mut g) = PET.lock() {
            g.hold = off == 0;
        }
        0
    })
}

/// 测试/看画用: 钉住步态相位(0..1)并冻住动画。返回 0。
#[no_mangle]
pub extern "C" fn wgime_pet_set_gait(gait: f32) -> i32 {
    guard(|| {
        if let Ok(mut g) = PET.lock() {
            g.gait = gait.rem_euclid(1.0);
            g.v = 0.0;
            g.hold = true;
        }
        PAUSED.store(true, Ordering::SeqCst);
        0
    })
}

/// 标定点个数
#[no_mangle]
pub extern "C" fn wgime_pet_probe_count() -> i32 {
    PROBE_N as i32
}

/// 取第 i 个标定点: 写入 [窗口x, 窗口y, r, g, b, a]。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_probe(i: i32, out: *mut f32) -> i32 {
    if out.is_null() || i < 0 || i as usize >= PROBE_N {
        return -1;
    }
    match PROBE.lock() {
        Ok(g) => {
            std::ptr::copy_nonoverlapping(g[i as usize].as_ptr(), out, 6);
            0
        }
        Err(_) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn wgime_pet_last_error(buf: *mut u8, cap: usize) -> usize {
    let s = LAST_ERR.lock().ok().and_then(|g| g.clone()).unwrap_or_default();
    copy_out(s.as_bytes(), buf, cap)
}

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

// ---------------------------------------------------------------- 状态机

/// 宠物在屏幕坐标里的状态。绘制只读它, 交互只改它。
struct Pet {
    /// 屏幕坐标: 角色脚底中心的 x
    x: f32,
    /// 当前速度(带符号)
    v: f32,
    face: f32,
    /// 步态相位 0..1
    gait: f32,
    /// 尾巴 / 耳朵 的摆动时间
    t: f32,
    /// 本次"待机/走动"剩余时间
    hold_t: f32,
    /// 下一次眨眼剩余时间
    blink_t: f32,
    blink: f32,
    look: f32,
    /// 是不是"跑"
    running: bool,
    /// 测试用: 钉住不动
    hold: bool,
}

static PET: Mutex<Pet> = Mutex::new(Pet {
    x: 0.0,
    v: WALK_SPEED,
    face: 1.0,
    gait: 0.0,
    t: 0.0,
    hold_t: 0.0,
    blink_t: 2.0,
    blink: 0.0,
    look: 0.0,
    running: false,
    hold: false,
});

/// 便宜的随机数(xorshift), 免得引依赖
fn rnd(seed: &mut u32) -> f32 {
    let mut x = *seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *seed = x;
    (x >> 8) as f32 / 16777216.0
}

impl Pet {
    fn step(&mut self, dt: f32, sw: f32, mouse: (f32, f32), seed: &mut u32) {
        self.t += dt;
        let lo = sw * RANGE_LO;
        let hi = sw * RANGE_HI;
        if !self.hold {
            // 躲鼠标: 鼠标贴到身边就朝反方向跑
            let d = mouse.0 - self.x;
            if d.abs() < FLEE_DIST
                && (mouse.1 - ANCHOR_Y_SCREEN.load(Ordering::Relaxed) as f32).abs() < 260.0
            {
                self.face = if d > 0.0 { -1.0 } else { 1.0 };
                self.v = self.face * RUN_SPEED;
                self.running = true;
                self.hold_t = 1.2;
            } else if self.hold_t <= 0.0 {
                // 换一段行为: 走 或 站住歇一会儿
                if rnd(seed) < 0.72 {
                    self.running = rnd(seed) < 0.25;
                    self.v = self.face * if self.running { RUN_SPEED } else { WALK_SPEED };
                    self.hold_t = 1.2 + rnd(seed) * 2.6;
                } else {
                    self.v = 0.0;
                    self.running = false;
                    self.hold_t = 0.7 + rnd(seed) * 2.2;
                }
            } else {
                self.hold_t -= dt;
            }
            self.x += self.v * dt;
            if self.x < lo {
                self.x = lo;
                self.face = 1.0;
                self.v = self.v.abs();
                self.hold_t = 0.2;
            } else if self.x > hi {
                self.x = hi;
                self.face = -1.0;
                self.v = -self.v.abs();
                self.hold_t = 0.2;
            }
        } else {
            self.hold_t = 0.0;
        }
        // 步态按"走过的距离"推进: 快走快倒腿, 站住就不动, 脚不打滑
        self.gait = (self.gait + self.v.abs() * dt / GAIT_CYCLE_PX).fract();

        // 眨眼
        self.blink_t -= dt;
        if self.blink_t <= 0.0 {
            self.blink_t = 2.0 + rnd(seed) * 4.0;
        }
        let phase = self.blink_t;
        self.blink = if phase > 0.86 { ((phase - 0.86) / 0.14).min(1.0) } else { 0.0 };

        // 看鼠标
        let want = ((mouse.0 - self.x) / LOOK_DIST).clamp(-1.0, 1.0);
        self.look += (want - self.look) * (dt * 4.0).min(1.0);
    }

    fn pose(&self) -> art::Pose {
        let run = self.running as i32 as f32;
        let moving = self.v.abs() > 1.0;
        art::Pose {
            x: ANCHOR_X,
            ground: ANCHOR_Y,
            face: self.face,
            scale: DOG_SCALE,
            gait: self.gait,
            stride: if moving { 24.0 + run * 9.0 } else { 0.0 },
            lift: if moving { 8.5 + run * 4.0 } else { 0.0 },
            lean: self.v * 0.00035,
            bob: -((self.gait * std::f32::consts::TAU * 2.0).sin().abs()) * (2.4 + run * 1.6),
            tail: self.t * (3.4 + run * 3.0) + self.look * 0.5,
            ear: self.t * (2.2 + run * 2.0),
            blink: self.blink,
            look: self.look,
            up: 1.0,
            alert: if self.v.abs() > 200.0 { 0.35 } else { 0.0 },
        }
    }
}

/// 屏幕 y 的缓存(给"鼠标是否在宠物那一带"用)
static ANCHOR_Y_SCREEN: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

// ---------------------------------------------------------------- 窗口与渲染

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
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
    d2d: ID2D1DCRenderTarget,
    rt: ID2D1RenderTarget,
    _factory: ID2D1Factory,
    stroke: ID2D1StrokeStyle,
    b: art::Brushes,
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
        let y = sh - WIN_H - 20;
        ANCHOR_Y_SCREEN.store(y + ANCHOR_Y as i32, Ordering::SeqCst);
        {
            let mut g = PET.lock().map_err(|_| Error::from(E_FAIL))?;
            g.x = sw as f32 * 0.5;
            g.face = 1.0;
            g.v = WALK_SPEED;
        }
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
        timeBeginPeriod(1);
        READY.store(true, Ordering::SeqCst);
        last_error(String::new());

        let period = Duration::from_secs_f32(1.0 / FPS_CAP);
        let mut next = Instant::now();
        let mut prev = Instant::now();
        let mut msg = MSG::default();
        let mut seed: u32 = 0x1234_5678;
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
            let now = Instant::now();
            let dt = (now - prev).as_secs_f32().min(0.1);
            prev = now;
            let frozen = PAUSED.load(Ordering::SeqCst);

            let mut m = POINT { x: 0, y: 0 };
            let _ = GetCursorPos(&mut m);
            let (wx, pose) = {
                let mut g = match PET.lock() {
                    Ok(g) => g,
                    Err(_) => break,
                };
                if !frozen {
                    g.step(dt, sw as f32, (m.x as f32, m.y as f32), &mut seed);
                }
                ((g.x - ANCHOR_X).round() as i32, g.pose())
            };
            draw(&surf, &pose)?;
            present(hwnd, screen_dc, &surf, wx, y)?;
            FRAMES.fetch_add(1, Ordering::SeqCst);

            next += period;
            let now = Instant::now();
            if next > now {
                thread::sleep(next - now);
            } else {
                next = now;
            }
        }
        timeEndPeriod(1);

        let _ = ReleaseDC(None, screen_dc);
        let _ = DestroyWindow(hwnd);
        HWND_MAIN.store(0, Ordering::SeqCst);
        Ok(())
    }
}

unsafe fn create_surface() -> Result<Surface> {
    let screen_dc = GetDC(None);
    let memdc = CreateCompatibleDC(screen_dc);
    let bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: WIN_W,
            biHeight: -WIN_H,
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
    rt.SetAntialiasMode(D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
    let stroke = factory.CreateStrokeStyle(
        &D2D1_STROKE_STYLE_PROPERTIES {
            startCap: D2D1_CAP_STYLE_ROUND,
            endCap: D2D1_CAP_STYLE_ROUND,
            dashCap: D2D1_CAP_STYLE_ROUND,
            lineJoin: D2D1_LINE_JOIN_ROUND,
            miterLimit: 4.0,
            dashStyle: D2D1_DASH_STYLE_SOLID,
            dashOffset: 0.0,
        },
        None,
    )?;
    let b = art::Brushes::new(&rt)?;
    dbg("D2D DC render target ok".into());

    Ok(Surface {
        memdc,
        hbmp,
        old,
        d2d,
        rt,
        _factory: factory,
        stroke,
        b,
    })
}

unsafe fn draw(s: &Surface, pose: &art::Pose) -> Result<()> {
    let rc = RECT { left: 0, top: 0, right: WIN_W, bottom: WIN_H };
    s.d2d.BindDC(s.memdc, &rc)?;
    s.rt.BeginDraw();
    s.rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));

    let ctx = art::Ctx { rt: &s.rt, b: &s.b, stroke: &s.stroke };
    let probe = art::draw_dog(&ctx, pose);

    if let Ok(mut g) = PROBE.lock() {
        let (r, gg, b) = art::SHADOW_TINT;
        g[0] = [probe.shadow.0, probe.shadow.1, r, gg, b, art::SHADOW_TOTAL_ALPHA];
        let f = art::FUR;
        g[1] = [probe.body.0, probe.body.1, f.r, f.g, f.b, f.a];
    }

    s.rt.EndDraw(None, None)?;
    Ok(())
}

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
