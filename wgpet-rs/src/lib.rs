//! wgpet.dll — WgIme 桌面宠物浮层 (Rust)
//!
//! 渲染路径: **D2D 画到 32bpp 预乘 alpha 的 DIB, 再用 UpdateLayeredWindow 提交**。
//!
//! 为什么不是 DirectComposition(第八十六轮实测结论, 别走回头路):
//! DComp 的合成窗内容**不做按 alpha 的命中测试** —— `WindowFromPoint` 照样命中整块窗外框,
//! 鼠标点不穿; 唯一能强制穿透的 `SetWindowRgn` 又会把 DComp 内容一起裁掉
//! (实测: 装空区域后精灵像素变成背景色, 关掉立刻回来)。
//! `UpdateLayeredWindow` 的分层窗则是**逐像素按 alpha 做命中测试**: 没画到的像素
//! (alpha=0) 鼠标直接穿过去, 画到的像素才挡鼠标 —— 这正是桌面宠物要的语义。
//!
//! 两个窗: `main` 装角色(开百宝袋时变大), `fx` 是飞行物/爆开效果的载体。
//! 为什么飞行物要单独一个窗: 它要飞到屏幕正中, 而角色窗只有几百像素宽 ——
//! 把角色窗撑到半个屏幕, 每帧要提交的像素会涨到几 MB(120fps 下就是几百 MB/s)。
//! 小窗跟着飞行物走, 每帧只需几十 KB。

#![allow(non_snake_case)]

mod art;
mod palette;

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

const ABI_VERSION: u32 = 2;

/// 关着百宝袋时的窗口(只装角色)
const SMALL: (i32, i32) = (300, 280);
/// 场景 1(投篮)的窗口: 要装得下左右两个球架 + 抛物线的最高点
const S1: (i32, i32) = (760, 360);
/// 场景 1 里角色的脚底中心(窗口坐标) 与 球架相对角色的水平距离 / 篮框高度
const S1_AX: f32 = 380.0;
const S1_HOOP_DX: f32 = 320.0;
const S1_RIM_Y: f32 = 96.0;
const S1_BALL_R: f32 = 15.0;
/// DIB 一律按**最大**尺寸分配, 提交时只交当前需要的那块(psize 允许是 DIB 的子矩形) ——
/// 于是开合面板、工具数变化时都不必重建 DIB 与 D2D 渲染目标。
/// **必须 >= 任何场景的窗口尺寸**: 场景 1 的场地窗是 760 宽, 一开始这里只有 620,
/// 于是"右边球架整块没画、画面还错位"(真踩过; 超出 DIB 的部分 ULW 取不到源)。
const MAX_W: i32 = 760;
const MAX_H: i32 = 440;
/// 飞行物窗口
const FX: i32 = 220;

const ANCHOR_X_SMALL: f32 = 156.0;
const ANCHOR_Y_SMALL: f32 = 240.0;
/// 脚底离窗口底边的距离(开面板时窗口变高, 用"离底边"算才能让角色原地不动)
const ANCHOR_BOTTOM: f32 = 34.0;
const DOG_SCALE: f32 = 1.15;

/// 一个完整步态周期对应的前进距离(像素) —— 步态相位按走过的距离推进, 脚不会打滑
const GAIT_CYCLE_PX: f32 = 74.0;
const WALK_SPEED: f32 = 96.0;
const RUN_SPEED: f32 = 340.0;
const FLEE_DIST: f32 = 130.0;
const LOOK_DIST: f32 = 460.0;
const RANGE_LO: f32 = 0.06;
const RANGE_HI: f32 = 0.94;

/// 与 python 版宠物同一套契约的消息(宿主/子进程之间转发用):
/// `WM_APP_TOGGLE` 再拉一次插件 = 开合百宝袋; `WM_APP_ENTER` = 让狗把工具甩出去;
/// `WM_APP_ACTIVITY` = 用户打字了, 让狗精神一下(摇尾/小跑一段)
const WM_APP_TOGGLE: u32 = 0x8002;
const WM_APP_ENTER: u32 = 0x8003;
const WM_APP_ACTIVITY: u32 = 0x8004;

/// 帧率上限。UpdateLayeredWindow **不做 vsync 节流**(实测不设上限能跑到 2085fps,
/// 纯烧 CPU), 所以必须自己限速。
const FPS_CAP: f32 = 120.0;

/// 掏工具的动作时间线(秒): [0,PULL) 从挎包里抽出来 → [PULL,FLY) 抛物线飞向屏幕正中
/// → 到达即回宿主启动工具, 并在落点炸一下
const T_PULL: f32 = 0.22;
const T_FLY: f32 = 0.62;
const T_BURST: f32 = 0.38;
/// 场景 1: 球从爪到篮框的飞行时间
const SHOT_T: f32 = 1.05;

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
static PROBE: Mutex<[[f32; 6]; PROBE_N]> = Mutex::new([[0.0; 6]; PROBE_N]);
static TOOLS: Mutex<Vec<palette::Item>> = Mutex::new(Vec::new());
static CLICK: Mutex<Option<(i32, i32)>> = Mutex::new(None);
/// 滚轮 delta(WM_MOUSEWHEEL)。注意: 鼠标滚轮默认发给**焦点窗**, 而本窗永不取焦点 ——
/// Win10+ 的「悬停时滚动非活动窗口」才会把它发过来, 所以翻页另有 ‹ › 按钮兜底。
static WHEEL: Mutex<Option<i32>> = Mutex::new(None);
/// 覆盖光标位置(测试钩子, x<0 = 用真实光标)
static FAKE_CURSOR: Mutex<Option<(f32, f32)>> = Mutex::new(None);
/// 吉祥物模式: 窗口自己填白底(导出插画用)。分层窗的 alpha 抓屏抓不到,
/// 所以"白底插画"不能靠事后合成, 得让窗口本身是不透明的白。
static MASCOT: AtomicBool = AtomicBool::new(false);
static LAST_LAUNCHED: Mutex<String> = Mutex::new(String::new());
/// 宿主给的回调: 点中工具时把 code 交回去, 由宿主启动(插件不许自己跑插件, 见 AGENTS §5 规则 51)
type ToolCb = unsafe extern "C" fn(*const u8, usize);
static LAUNCH_CB: AtomicIsize = AtomicIsize::new(0);
/// fx 窗的当前位置与可见性, 给探针用
static FX_STATE: Mutex<[f32; 3]> = Mutex::new([0.0, 0.0, 0.0]);

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

/// 场景 1: 开始一次投篮(自己挑一侧: 交替, 保证两边都能看到)
fn shoot() {
    if let Ok(mut g) = PET.lock() {
        if g.scene == 1 && g.ball_mode == 0 {
            g.ball_side = -g.ball_side;
            g.ball_mode = 1;
            g.ball_t = 0.0;
            dbg(format!("court: 投篮 side={}", g.ball_side));
        }
    }
}

/// 场景 1 的球状态(窗口坐标): [x, y, mode, side] —— 给探针断言用
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_ball(out: *mut f32) -> i32 {
    if out.is_null() {
        return -1;
    }
    match PET.lock() {
        Ok(g) => {
            let v = [
                g.ball_x,
                g.ball_y,
                g.ball_mode as f32,
                g.ball_side as f32,
            ];
            std::ptr::copy_nonoverlapping(v.as_ptr(), out, 4);
            0
        }
        Err(_) => -1,
    }
}

/// 吉祥物模式(白底, 导出 IP 插画用): on=1 开。
#[no_mangle]
pub extern "C" fn wgime_pet_mascot(on: i32) -> i32 {
    MASCOT.store(on != 0, Ordering::SeqCst);
    0
}

/// 投篮一次(= 场景 1 里按回车)
#[no_mangle]
pub extern "C" fn wgime_pet_shoot() -> i32 {
    guard(|| {
        shoot();
        0
    })
}

/// 换场景(1=投篮 2=百宝袋狗 3=四边漫游)。返回换好之后的场景号。
#[no_mangle]
pub extern "C" fn wgime_pet_scene(no: i32) -> i32 {
    guard(|| {
        let mut v = 2;
        if let Ok(mut g) = PET.lock() {
            g.scene = no.clamp(1, 3);
            g.palette = false;
            g.throw_t = None;
            g.ball_mode = 0;
            g.ball_t = 0.0;
            v = g.scene;
        }
        v
    })
}

#[no_mangle]
pub extern "C" fn wgime_pet_scene_no() -> i32 {
    PET.lock().map(|g| g.scene).unwrap_or(2)
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

/// 被动(=1, 默认)整窗鼠标穿透; 交互(=0)只有画到的像素挡鼠标, 空白照旧穿透。
/// 开百宝袋时 DLL 会自己切到交互态, 不用宿主操心。
#[no_mangle]
pub extern "C" fn wgime_pet_set_passthrough(on: i32) -> i32 {
    guard(|| {
        let h = HWND_MAIN.load(Ordering::SeqCst);
        if h == 0 {
            return -1;
        }
        unsafe { set_passthrough(HWND(h as *mut c_void), on != 0) };
        0
    })
}

/// 把角色钉在屏幕某个 x(测试/演示用), face≠0 时同时钉朝向, 并停止自动漫游。
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

/// 钉住步态相位(0..1)并冻住动画(看画/测试用)
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

/// 看画用: 钉住眨眼(0=睁眼 1=闭眼)。会冻结动画, 免得截图正好抓到眨眼那一帧。
#[no_mangle]
pub extern "C" fn wgime_pet_set_blink(v: f32) -> i32 {
    guard(|| {
        if let Ok(mut g) = PET.lock() {
            g.blink = v.clamp(0.0, 1.0);
            g.blink_t = 0.5; // > 0.14 => 保持睁眼(别设 999: 见 step() 里的眨眼分段)
            g.hold = true;
        }
        PAUSED.store(true, Ordering::SeqCst);
        0
    })
}

/// 开/关百宝袋
#[no_mangle]
pub extern "C" fn wgime_pet_palette(on: i32) -> i32 {
    guard(|| {
        if let Ok(mut g) = PET.lock() {
            g.palette = on != 0;
            g.hover = -1;
        }
        0
    })
}

/// 灌工具清单: 每行 `code\tname\tkind`(UTF-8, 不要求结尾换行)。返回装入条数。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_set_tools(buf: *const u8, len: usize) -> i32 {
    guard(|| {
        if buf.is_null() {
            return -1;
        }
        let bytes = std::slice::from_raw_parts(buf, len);
        let text = match std::str::from_utf8(bytes) {
            Ok(t) => t,
            Err(_) => return -2,
        };
        let mut v = Vec::new();
        for line in text.split('\n') {
            let line = line.trim_end_matches('\r');
            if line.is_empty() {
                continue;
            }
            let mut f = line.split('\t');
            let code = f.next().unwrap_or("").trim().to_string();
            if code.is_empty() {
                continue;
            }
            v.push(palette::Item {
                code,
                name: f.next().unwrap_or("").trim().to_string(),
                kind: f.next().unwrap_or("").trim().to_string(),
            });
        }
        let n = v.len() as i32;
        if let Ok(mut g) = TOOLS.lock() {
            *g = v;
        }
        n
    })
}

/// 宿主登记"点中工具"的回调(把 code 交回宿主启动)
#[no_mangle]
pub extern "C" fn wgime_pet_set_launcher(cb: usize) -> i32 {
    LAUNCH_CB.store(cb as isize, Ordering::SeqCst);
    0
}

/// 模拟一次点击(屏幕坐标; 测试用)。返回点中的工具下标, -1 = 没点中。
#[no_mangle]
pub extern "C" fn wgime_pet_click(sx: i32, sy: i32) -> i32 {
    guard(|| {
        let h = HWND_MAIN.load(Ordering::SeqCst);
        if h == 0 {
            return -1;
        }
        if let Ok(mut c) = CLICK.lock() {
            *c = Some((sx, sy));
        }
        // 等渲染线程处理完(最多 500ms)
        let t0 = Instant::now();
        while t0.elapsed() < Duration::from_millis(500) {
            if CLICK.lock().map(|c| c.is_none()).unwrap_or(false) {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        LAST_IDX.load(Ordering::SeqCst) as i32
    })
}

static LAST_IDX: AtomicIsize = AtomicIsize::new(-1);

/// 上一次真的交给宿主启动的 code(UTF-8)。buf=NULL 返回长度。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_last_launched(buf: *mut u8, cap: usize) -> usize {
    let s = LAST_LAUNCHED.lock().map(|g| g.clone()).unwrap_or_default();
    copy_out(s.as_bytes(), buf, cap)
}

/// 面板矩形(屏幕坐标): [x, y, w, h]。没开面板时 w=0。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_panel_rect(out: *mut f32) -> i32 {
    if out.is_null() {
        return -1;
    }
    match layout_now() {
        None => {
            let z = [0.0f32; 4];
            std::ptr::copy_nonoverlapping(z.as_ptr(), out, 4);
        }
        Some((l, r)) => {
            let v = [
                r.0 as f32 + l.panel.0,
                r.1 as f32 + l.panel.1,
                l.panel.2,
                l.panel.3,
            ];
            std::ptr::copy_nonoverlapping(v.as_ptr(), out, 4);
        }
    }
    0
}

/// 第 i 个工具格的矩形(屏幕坐标): [x, y, w, h]。不在当前页则返回 -1。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_item_rect(i: i32, out: *mut f32) -> i32 {
    if out.is_null() || i < 0 {
        return -1;
    }
    let Some((l, r)) = layout_now() else { return -1 };
    let Some(it) = l.items.iter().find(|it| it.0 == i as usize) else {
        return -1;
    };
    let v = [r.0 as f32 + it.1, r.1 as f32 + it.2, it.3, it.4];
    std::ptr::copy_nonoverlapping(v.as_ptr(), out, 4);
    0
}

/// 标题条控件的矩形: 0=关闭 1=上一页 2=下一页。给探针点击用。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_btn_rect(k: i32, out: *mut f32) -> i32 {
    if out.is_null() {
        return -1;
    }
    let Some((l, r)) = layout_now() else { return -1 };
    let b = match k {
        0 => l.close,
        1 => l.prev,
        2 => l.next,
        _ => return -1,
    };
    let v = [r.0 as f32 + b.0, r.1 as f32 + b.1, b.2, b.3];
    std::ptr::copy_nonoverlapping(v.as_ptr(), out, 4);
    0
}

/// 测试/演示用: 覆盖"光标位置"(x<0 恢复真实光标)。
/// 为什么必须有这个钩子: 悬停/看鼠标都读真实光标, 而**屏幕前的人一动鼠标**,
/// 断言就会假红(真踩过: 光标从 (1596,1830) 自己漂到 (1507,1868), 悬停断言白红一条)。
/// 与 python 版宠物的 `WGIME_PET_FAKE_MOUSE` 同一个用途。
#[no_mangle]
pub extern "C" fn wgime_pet_set_cursor(x: i32, y: i32) -> i32 {
    guard(|| {
        if let Ok(mut g) = FAKE_CURSOR.lock() {
            *g = if x < 0 {
                None
            } else {
                Some((x as f32, y as f32))
            };
        }
        0
    })
}

/// 角色的**屏幕**坐标: [脚底中心x, 脚底y, 窗口宽, 窗口高]。
/// 给探针用 —— 别让它自己拿窗口矩形去猜角色在哪(开合面板时锚点会变, 猜必错)。
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_dog_xy(out: *mut f32) -> i32 {
    if out.is_null() {
        return -1;
    }
    let (open, flip, scene) = PET
        .lock()
        .map(|g| (g.palette && g.anim > 0.02, g.flip, g.scene))
        .unwrap_or((false, false, 2));
    let n = TOOLS.lock().map(|t| t.len()).unwrap_or(0);
    let a = anchor(scene, open, flip, n);
    let h = HWND_MAIN.load(Ordering::SeqCst);
    let r = if h == 0 {
        (0, 0)
    } else {
        window_rect(HWND(h as *mut c_void))
    };
    let size = win_size(scene, open, n);
    let v = [
        r.0 as f32 + a.0,
        r.1 as f32 + a.1,
        size.0 as f32,
        size.1 as f32,
    ];
    std::ptr::copy_nonoverlapping(v.as_ptr(), out, 4);
    0
}

/// 当前页(0 基) / 总页数
#[no_mangle]
pub extern "C" fn wgime_pet_page() -> i32 {
    PET.lock().map(|g| g.page as i32).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn wgime_pet_pages() -> i32 {
    let n = TOOLS.lock().map(|t| t.len()).unwrap_or(0);
    n.div_ceil(palette::PER_PAGE).max(1) as i32
}

/// 当前高亮的工具下标(-1 = 没高亮)
#[no_mangle]
pub extern "C" fn wgime_pet_hover() -> i32 {
    PET.lock().map(|g| g.hover).unwrap_or(-1)
}

/// 飞行物状态: [屏幕x, 屏幕y, 可见(0/1)]
#[no_mangle]
pub unsafe extern "C" fn wgime_pet_fx(out: *mut f32) -> i32 {
    if out.is_null() {
        return -1;
    }
    match FX_STATE.lock() {
        Ok(g) => {
            std::ptr::copy_nonoverlapping(g.as_ptr(), out, 3);
            0
        }
        Err(_) => -1,
    }
}

#[no_mangle]
pub extern "C" fn wgime_pet_probe_count() -> i32 {
    PROBE_N as i32
}

/// 取第 i 个标定点: [窗口x, 窗口y, r, g, b, a]
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

struct Pet {
    x: f32,
    v: f32,
    face: f32,
    gait: f32,
    t: f32,
    hold_t: f32,
    blink_t: f32,
    blink: f32,
    look: f32,
    running: bool,
    hold: bool,
    /// 百宝袋开着
    palette: bool,
    /// 开场动画 0..1
    anim: f32,
    /// 高亮的工具**全局**下标(-1 = 无)
    hover: i32,
    /// 每个格子的悬停动效值 0..1(索引是格子序号, 不是工具下标)
    hover_anim: [f32; palette::PER_PAGE],
    /// 当前第几页
    page: usize,
    flip: bool,
    /// 掏工具动作进度: None = 没在掏
    throw_t: Option<f32>,
    throw_idx: i32,
    /// fx 落点爆开剩余时间
    burst: f32,
    /// 场景: 1=投篮 2=百宝袋狗 3=四边漫游(还没做)
    scene: i32,
    /// 抬前爪 0..1
    arm: f32,
    arm_want: f32,
    /// 球: mode 0=拍球 1=飞出 2=捡回来
    ball_mode: u8,
    ball_t: f32,
    ball_side: i32,
    ball_x: f32,
    ball_y: f32,
    ball_spin: f32,
    /// 进球后框口闪光剩余
    flash: f32,
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
    palette: false,
    anim: 0.0,
    hover: -1,
    hover_anim: [0.0; palette::PER_PAGE],
    page: 0,
    flip: false,
    throw_t: None,
    throw_idx: -1,
    burst: 0.0,
    scene: 2,
    arm: 0.0,
    arm_want: 0.0,
    ball_mode: 0,
    ball_t: 0.0,
    ball_side: 1,
    ball_x: 0.0,
    ball_y: 0.0,
    ball_spin: 0.0,
    flash: 0.0,
});

fn rnd(seed: &mut u32) -> f32 {
    let mut x = *seed;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *seed = x;
    (x >> 8) as f32 / 16777216.0
}

impl Pet {
    /// 场景 1: 站在场地中间拍球; 按下"投篮"就把球抛向一侧的篮框, 进了闪一下再捡回来。
    /// 这一场**不漫游**(v=0) —— 场地是跟着它走的窗口, 走起来球架就跟着飘了。
    fn step_court(&mut self, dt: f32) {
        let ground = S1.1 as f32 - ANCHOR_BOTTOM;
        let paw = (S1_AX + 46.0, ground - 72.0);
        self.v = 0.0;
        self.running = false;
        self.look = 0.0;
        // 抬爪朝篮框那侧
        self.face = if self.ball_side >= 0 { 1.0 } else { -1.0 };
        self.arm += (self.arm_want - self.arm) * (dt * 9.0).min(1.0);
        self.ball_t += dt;
        let rim_x = S1_AX + self.ball_side as f32 * (S1_HOOP_DX - 33.0);
        match self.ball_mode {
            0 => {
                // 拍球: 在爪下弹
                let b = (self.ball_t * 4.6).sin().abs();
                self.ball_x = S1_AX + 46.0;
                self.ball_y = ground - 24.0 - b * 92.0;
                self.ball_spin += dt * 7.0;
                self.arm_want = 0.0;
            }
            1 => {
                // 飞出: 抛物线
                let k = (self.ball_t / SHOT_T).min(1.0);
                self.arm_want = if k < 0.3 { 1.0 } else { 0.0 };
                self.ball_x = paw.0 + (rim_x - paw.0) * k;
                self.ball_y = paw.1 + (S1_RIM_Y - paw.1) * k
                    - (k * std::f32::consts::PI).sin() * 118.0;
                self.ball_spin += dt * 9.0;
                if k >= 1.0 {
                    self.ball_mode = 2;
                    self.ball_t = 0.0;
                    self.flash = 1.0;
                    dbg("court: 进球".into());
                }
            }
            _ => {
                // 捡回来
                let k = (self.ball_t / 0.55).min(1.0);
                self.ball_x = rim_x + (paw.0 - rim_x) * k;
                self.ball_y = S1_RIM_Y + (paw.1 - S1_RIM_Y) * k
                    + (k * std::f32::consts::PI).sin() * 30.0;
                self.ball_spin += dt * 5.0;
                if k >= 1.0 {
                    self.ball_mode = 0;
                    self.ball_t = 0.0;
                }
            }
        }
        self.flash = (self.flash - dt * 1.6).max(0.0);
    }

    fn step(&mut self, dt: f32, sw: f32, ground: f32, mouse: (f32, f32), seed: &mut u32) {
        self.t += dt;
        // 眨眼(所有场景共用)
        self.blink_t -= dt;
        if self.blink_t <= 0.0 {
            self.blink_t = 2.0 + rnd(seed) * 4.0;
        }
        // 只在 blink_t 掉到最后 0.14s 才闭眼。
        // **别写成 `if blink_t > 0.86`** —— 那样 blink_t 一大就等于 1(闭着),
        // 也就是眼睛几乎永远闭着(真 bug: 表现是"像戴墨镜/一直眯着眼", 只修高光缩放是治标)
        self.blink = if self.blink_t < 0.14 {
            ((0.14 - self.blink_t) / 0.14).min(1.0)
        } else {
            0.0
        };
        if self.scene == 1 {
            self.step_court(dt);
            return;
        }
        let _ = ground;
        // 面板开着的时候站住不动(不然面板跟着角色满屏跑, 鼠标追不上)
        let want_hold = self.hold || self.palette || self.throw_t.is_some();
        if !want_hold {
            let d = mouse.0 - self.x;
            if d.abs() < FLEE_DIST && (mouse.1 - ground).abs() < 260.0 {
                self.face = if d > 0.0 { -1.0 } else { 1.0 };
                self.v = self.face * RUN_SPEED;
                self.running = true;
                self.hold_t = 1.2;
            } else if self.hold_t <= 0.0 {
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
            let (lo, hi) = (sw * RANGE_LO, sw * RANGE_HI);
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
            self.v = 0.0;
        }
        self.gait = (self.gait + self.v.abs() * dt / GAIT_CYCLE_PX).fract();

        let want = ((mouse.0 - self.x) / LOOK_DIST).clamp(-1.0, 1.0);
        self.look += (want - self.look) * (dt * 4.0).min(1.0);

        // 面板开场动画
        let target = if self.palette { 1.0 } else { 0.0 };
        let sp = (dt / 0.16).min(1.0);
        self.anim += (target - self.anim) * sp;

        // 面板在角色左边还是右边: 角色靠屏幕右缘就翻到左边
        self.flip = self.x > sw * 0.6;

        // 掏工具: 抽 → 抛 → 爆
        if let Some(t) = self.throw_t {
            let nt = t + dt;
            if t < T_PULL && nt >= T_PULL {
                dbg(format!("throw: pull done -> fly (tool {})", self.throw_idx));
            }
            if nt >= T_PULL + T_FLY && t < T_PULL + T_FLY {
                // 到落点: 交给宿主启动(插件不许自己跑插件)
                let code = TOOLS
                    .lock()
                    .ok()
                    .and_then(|g| g.get(self.throw_idx.max(0) as usize).map(|i| i.code.clone()))
                    .unwrap_or_default();
                if !code.is_empty() {
                    if let Ok(mut g) = LAST_LAUNCHED.lock() {
                        *g = code.clone();
                    }
                    let cb = LAUNCH_CB.load(Ordering::SeqCst);
                    if cb != 0 {
                        let f: ToolCb = unsafe { std::mem::transmute(cb) };
                        unsafe { f(code.as_ptr(), code.len()) };
                    }
                }
                self.burst = T_BURST;
            }
            if nt >= T_PULL + T_FLY + T_BURST {
                self.throw_t = None;
            } else {
                self.throw_t = Some(nt);
            }
        }
        if self.burst > 0.0 {
            self.burst = (self.burst - dt).max(0.0);
        }
    }

    fn pose(&self, anchor_x: f32, anchor_y: f32) -> art::Pose {
        let run = self.running as i32 as f32;
        let moving = self.v.abs() > 1.0;
        art::Pose {
            x: anchor_x,
            ground: anchor_y,
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
            alert: if self.throw_t.is_some() {
                0.9
            } else if self.v.abs() > 200.0 {
                0.35
            } else {
                0.0
            },
            arm: self.arm,
            // 站住不动(且不是投篮场)时坐着: Q版柴犬的常态姿势就是坐姿
            sit: if self.scene != 1 && self.v.abs() < 1.0 && self.throw_t.is_none() {
                1.0
            } else {
                0.0
            },
        }
    }
}

// ---------------------------------------------------------------- 几何

fn win_size(scene: i32, open: bool, n: usize) -> (i32, i32) {
    if scene == 1 {
        S1
    } else if open {
        palette::win_size(n)
    } else {
        SMALL
    }
}

fn anchor(scene: i32, open: bool, flip: bool, n: usize) -> (f32, f32) {
    if scene == 1 {
        (S1_AX, S1.1 as f32 - ANCHOR_BOTTOM)
    } else if open {
        (
            palette::anchor_x(flip, 1.0),
            palette::win_size(n).1 as f32 - ANCHOR_BOTTOM,
        )
    } else {
        (ANCHOR_X_SMALL, ANCHOR_Y_SMALL)
    }
}

/// 当前布局(仅面板开着时), 以及窗口左上角屏幕坐标 —— 给导出用
fn layout_now() -> Option<(palette::Layout, (i32, i32))> {
    let (open, flip, page) = PET
        .lock()
        .map(|g| (g.palette && g.anim > 0.02, g.flip, g.page))
        .unwrap_or((false, false, 0));
    if !open {
        return None;
    }
    let n = TOOLS.lock().map(|t| t.len()).unwrap_or(0);
    let h = HWND_MAIN.load(Ordering::SeqCst);
    let r = if h == 0 {
        (0, 0)
    } else {
        window_rect(HWND(h as *mut c_void))
    };
    Some((palette::layout(n, flip, page), r))
}

fn window_rect(h: HWND) -> (i32, i32) {
    let mut r = RECT::default();
    unsafe {
        let _ = GetWindowRect(h, &mut r);
    }
    (r.left, r.top)
}

/// 给导出用的快照: (窗口宽, 是否翻到左边, 面板是否开着, 窗口左上角)
#[allow(dead_code)]
fn geom_snapshot() -> (i32, bool, bool, (i32, i32)) {
    let v = PET.lock().map(|g| g.v).unwrap_or(0.0);
    let _ = v;
    let (open, flip, scene) = PET
        .lock()
        .map(|g| (g.palette && g.anim > 0.02, g.flip, g.scene))
        .unwrap_or((false, false, 2));
    let h = HWND_MAIN.load(Ordering::SeqCst);
    let r = if h == 0 {
        (0, 0)
    } else {
        window_rect(HWND(h as *mut c_void))
    };
    let n = TOOLS.lock().map(|t| t.len()).unwrap_or(0);
    (win_size(scene, open, n).0, flip, open, r)
}

// ---------------------------------------------------------------- 窗口与渲染

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        // 宿主/子进程转发过来的动作(契约见 WM_APP_* 常量)
        WM_APP_TOGGLE => {
            if let Ok(mut g) = PET.lock() {
                g.palette = !g.palette;
                g.hover = -1;
            }
            LRESULT(0)
        }
        WM_APP_ACTIVITY => {
            // 打字了: 精神一下(小跑一段 + 竖耳)
            if let Ok(mut g) = PET.lock() {
                g.hold_t = 0.0;
                g.running = true;
                g.v = g.face * RUN_SPEED;
            }
            LRESULT(0)
        }
        WM_APP_ENTER => {
            // 场景 1 = 投篮; 场景 2 = 把第一格(或高亮那格)工具甩出去
            let (scene, idx) = {
                let g = PET.lock().ok();
                match g {
                    Some(g) if g.scene == 1 => (1, -1),
                    Some(g) if g.palette && g.throw_t.is_none() => {
                        (2, if g.hover >= 0 { g.hover } else { 0 })
                    }
                    _ => (0, -1),
                }
            };
            if scene == 1 {
                shoot();
            } else if idx >= 0 {
                if let Ok(mut g) = PET.lock() {
                    g.throw_idx = idx;
                    g.throw_t = Some(0.0);
                }
            }
            LRESULT(0)
        }
        WM_RBUTTONDOWN => {
            // 右键 = 换场景 1→2→3→1(python 版宠物也是这个规矩)
            if let Ok(mut g) = PET.lock() {
                g.scene = if g.scene >= 3 { 1 } else { g.scene + 1 };
                g.palette = false;
                dbg(format!("scene -> {}", g.scene));
            }
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            // 统一成**屏幕坐标**: 命中测试与 wgime_pet_click 注入都按屏幕坐标算,
            // 免得两条路各用一套坐标系(客户端 vs 屏幕)而错位
            let mut p = POINT {
                x: (lp.0 & 0xFFFF) as i16 as i32,
                y: ((lp.0 >> 16) & 0xFFFF) as i16 as i32,
            };
            let _ = ClientToScreen(hwnd, &mut p);
            if let Ok(mut c) = CLICK.lock() {
                *c = Some((p.x, p.y));
            }
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let d = ((wp.0 >> 16) & 0xFFFF) as i16 as i32;
            if let Ok(mut w) = WHEEL.lock() {
                *w = Some(d);
            }
            LRESULT(0)
        }
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
    /// DIB 的像素首地址 —— 验收标定点要**回读自己刚画的画**(见 `refine_probe`)
    bits: *mut c_void,
    w: i32,
    h: i32,
    d2d: ID2D1DCRenderTarget,
    rt: ID2D1RenderTarget,
    factory: ID2D1Factory,
    stroke: ID2D1StrokeStyle,
    shapes: art::Shapes,
    b: art::Brushes,
    text: art::Text,
    pb: palette::Brushes,
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
        // 站在**工作区**底边上(不是屏幕底边): 否则角色会陷进任务栏里 ——
        // 半透明任务栏会透出底下的东西, 看起来像"脚被切了", 标定点读数也会偏(真踩过)。
        // 再往上留 16px: 软阴影要落在桌面上, 不能压到任务栏那条边界
        let mut work = RECT::default();
        let _ = SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some(&mut work as *mut _ as *mut c_void),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        );
        let work_bottom = if work.bottom > 0 { work.bottom } else { sh };
        let ground = work_bottom - 16;
        {
            let mut g = PET.lock().map_err(|_| Error::from(E_FAIL))?;
            g.x = sw as f32 * 0.5;
            g.face = 1.0;
            g.v = WALK_SPEED;
        }
        let (a0x, a0y) = anchor(2, false, false, 0);
        let hwnd = CreateWindowExW(
            ex,
            PCWSTR(cls_name.as_ptr()),
            PCWSTR(wide("wgpet · 桌面宠物").as_ptr()),
            WS_POPUP,
            (g0x(sw, a0x)) as i32,
            ground - a0y as i32,
            SMALL.0,
            SMALL.1,
            None,
            None,
            hinst,
            None,
        )?;
        HWND_MAIN.store(hwnd.0 as isize, Ordering::SeqCst);
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);

        // 飞行物窗: 常驻但平时藏着(创建/销毁每次都动窗口管理器, 没必要)
        let fx = CreateWindowExW(
            ex,
            PCWSTR(cls_name.as_ptr()),
            PCWSTR(wide("wgpet · 投掷物").as_ptr()),
            WS_POPUP,
            0,
            0,
            FX,
            FX,
            None,
            None,
            hinst,
            None,
        )?;
        dbg(format!(
            "windows ok main=0x{:X} fx=0x{:X} {}x{}",
            hwnd.0 as isize,
            fx.0 as isize,
            SMALL.0,
            SMALL.1
        ));

        let surf = create_surface(MAX_W, MAX_H)?;
        let fxs = create_surface(FX, FX)?;
        let screen_dc = GetDC(None);
        timeBeginPeriod(1);
        READY.store(true, Ordering::SeqCst);
        last_error(String::new());

        let period = Duration::from_secs_f32(1.0 / FPS_CAP);
        let mut next = Instant::now();
        let mut prev = Instant::now();
        let mut msg = MSG::default();
        let mut seed: u32 = 0x1234_5678;
        let mut interactive = false;
        let mut fx_shown = false;
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
            let (mx, my) = match FAKE_CURSOR.lock().ok().and_then(|g| *g) {
                Some((x, y)) => (x, y),
                None => (m.x as f32, m.y as f32),
            };
            let click = CLICK.lock().ok().and_then(|mut c| c.take());

            let (open, flip, ax, ay, pose, thrown, fx_pos, fx_vis, burst, fx_letter, n, page, scene) = {
                let mut g = match PET.lock() {
                    Ok(g) => g,
                    Err(_) => break,
                };
                if !frozen {
                    g.step(dt, sw as f32, ground as f32, (mx, my), &mut seed);
                }
                let open = g.palette && g.anim > 0.02;
                let n = TOOLS.lock().map(|t| t.len()).unwrap_or(0);
                let scene = g.scene; let (ax, ay) = anchor(scene, open, g.flip, n);
                let l = palette::layout(n, g.flip, g.page);
                // 命中测试: 光标 → 窗口坐标 → 面板格子
                let wr = window_rect(hwnd);
                let (lx, ly) = (mx - wr.0 as f32, my - wr.1 as f32);
                let mut hover = -1;
                if open && g.throw_t.is_none() {
                    for (gi, x, y, w, h) in l.items.iter() {
                        if lx >= *x && lx <= x + w && ly >= *y && ly <= y + h {
                            hover = *gi as i32;
                            break;
                        }
                    }
                }
                if g.hover != hover {
                    dbg(format!(
                        "hover {} -> {} cursor=({},{}) local=({:.0},{:.0}) win=({},{}) page={}",
                        g.hover, hover, m.x, m.y, lx, ly, wr.0, wr.1, g.page
                    ));
                }
                g.hover = hover;
                // 悬停动效: 每个格子朝目标值靠(亮起来/暗下去都平滑)
                let sp = (dt * 14.0).min(1.0);
                for k in 0..palette::PER_PAGE {
                    let target = if l.items.get(k).map(|it| it.0 as i32) == Some(hover) {
                        1.0
                    } else {
                        0.0
                    };
                    g.hover_anim[k] += (target - g.hover_anim[k]) * sp;
                }
                // 滚轮翻页
                if let Some(d) = WHEEL.lock().ok().and_then(|mut w| w.take()) {
                    if open {
                        if d > 0 && g.page > 0 {
                            g.page -= 1;
                        } else if d < 0 && g.page + 1 < l.pages {
                            g.page += 1;
                        }
                    }
                }
                // 点击(真实 WM_LBUTTONDOWN 或 wgime_pet_click 注入, 都是屏幕坐标)
                if let Some((cx, cy)) = click {
                    let (rx, ry) = (wr.0 as f32, wr.1 as f32);
                    let inside = |r: (f32, f32, f32, f32)| {
                        cx as f32 >= rx + r.0
                            && (cx as f32) <= rx + r.0 + r.2
                            && cy as f32 >= ry + r.1
                            && (cy as f32) <= ry + r.1 + r.3
                    };
                    let mut idx = -1;
                    if open && g.throw_t.is_none() {
                        if inside(l.close) {
                            g.palette = false;
                            dbg("palette: 关闭按钮收起".into());
                        } else if l.pages > 1 && inside(l.prev) && g.page > 0 {
                            g.page -= 1;
                        } else if l.pages > 1 && inside(l.next) && g.page + 1 < l.pages {
                            g.page += 1;
                        } else if inside(l.panel) {
                            for (gi, x, y, w, h) in l.items.iter() {
                                if inside((*x, *y, *w, *h)) {
                                    idx = *gi as i32;
                                    break;
                                }
                            }
                        } else {
                            g.palette = false;
                            dbg("palette: 点空白处收起".into());
                        }
                    }
                    LAST_IDX.store(idx as isize, Ordering::SeqCst);
                    if idx >= 0 {
                        g.throw_idx = idx;
                        g.throw_t = Some(0.0);
                    }
                }
                let letter: String = TOOLS
                    .lock()
                    .ok()
                    .and_then(|t| {
                        t.get(g.throw_idx.max(0) as usize).map(|i| {
                            i.code
                                .chars()
                                .next()
                                .map(|ch| ch.to_uppercase().to_string())
                                .unwrap_or_default()
                        })
                    })
                    .unwrap_or_default();
                let thrown = g.throw_t;
                let (mut fx_x, mut fx_y, mut fx_vis) = (0.0f32, 0.0f32, false);
                if let Some(t) = thrown {
                    // 从挎包飞到屏幕正中; 抛物线 + 自转
                    let (bx, by) = (g.x - 8.0 * DOG_SCALE, ground as f32 - 62.0 * DOG_SCALE);
                    let (ex_, ey_) = (sw as f32 * 0.5, sh as f32 * 0.5);
                    let k = ((t - T_PULL) / T_FLY).clamp(0.0, 1.0);
                    let arc = (k * std::f32::consts::PI).sin() * 150.0;
                    fx_x = bx + (ex_ - bx) * k;
                    fx_y = by + (ey_ - by) * k - arc;
                    fx_vis = t >= 0.0;
                }
                (open, g.flip, ax, ay, g.pose(ax, ay), thrown, (fx_x, fx_y), fx_vis, g.burst, letter, n, g.page, scene)
            };

            // 窗口尺寸/位置随面板开合与工具数变化(锚点按离底边的距离算 => 脚底原地不动);
            // 场景 1 的场地窗固定在屏幕中间(球架跟着窗口走, 走起来球架就飘了)
            let want = win_size(scene, open, n);
            let wx = if scene == 1 {
                (sw - S1.0) / 2
            } else {
                (state_x() - ax).round() as i32
            };
            let wy = ground - ay.round() as i32;
            if want.0 > MAX_W || want.1 > MAX_H {
                static WARNED: AtomicBool = AtomicBool::new(false);
                if !WARNED.swap(true, Ordering::SeqCst) {
                    dbg(format!("!! 窗口 {}x{} 超出 DIB {}x{}", want.0, want.1, MAX_W, MAX_H));
                }
            }
            draw(&surf, &pose, open, flip, page, want, &thrown, scene)?;
            present(hwnd, screen_dc, &surf, wx, wy, want.0, want.1)?;

            // 交互态切换: 面板开着才需要点得到
            if interactive != open {
                set_passthrough(hwnd, !open);
                interactive = open;
            }

            // 飞行物
            if fx_vis && thrown.is_some() {
                if !fx_shown {
                    let _ = ShowWindow(fx, SW_SHOWNOACTIVATE);
                    fx_shown = true;
                }
                draw_fx(&fxs, &thrown, burst, &fx_letter)?;
                present(
                    fx,
                    screen_dc,
                    &fxs,
                    fx_pos.0.round() as i32 - FX / 2,
                    fx_pos.1.round() as i32 - FX / 2,
                    FX,
                    FX,
                )?;
                if let Ok(mut s) = FX_STATE.lock() {
                    *s = [fx_pos.0, fx_pos.1, 1.0];
                }
            } else if fx_shown && burst <= 0.0 {
                let _ = ShowWindow(fx, SW_HIDE);
                fx_shown = false;
                if let Ok(mut s) = FX_STATE.lock() {
                    *s = [0.0, 0.0, 0.0];
                }
            }

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
        let _ = DestroyWindow(fx);
        let _ = DestroyWindow(hwnd);
        HWND_MAIN.store(0, Ordering::SeqCst);
        Ok(())
    }
}

fn g0x(sw: i32, ax: f32) -> f32 {
    sw as f32 * 0.5 - ax
}

fn state_x() -> f32 {
    PET.lock().map(|g| g.x).unwrap_or(0.0)
}

unsafe fn set_passthrough(h: HWND, on: bool) {
    let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
    let new = if on {
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
}

unsafe fn create_surface(w: i32, h: i32) -> Result<Surface> {
    let screen_dc = GetDC(None);
    let memdc = CreateCompatibleDC(screen_dc);
    let bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h,
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
    let shapes = art::Shapes::new(&factory)?;
    let text = art::Text::new()?;
    let pb = palette::Brushes::new(&rt)?;

    Ok(Surface {
        memdc,
        hbmp,
        old,
        bits,
        w,
        h,
        d2d,
        rt,
        factory,
        stroke,
        shapes,
        b,
        text,
        pb,
    })
}

unsafe fn begin(s: &Surface, w: i32, h: i32) -> Result<()> {
    let rc = RECT {
        left: 0,
        top: 0,
        right: w,
        bottom: h,
    };
    s.d2d.BindDC(s.memdc, &rc)?;
    s.rt.BeginDraw();
    if MASCOT.load(Ordering::SeqCst) {
        // 不透明白: 导出"吉祥物插画"用
        s.rt.Clear(Some(&D2D1_COLOR_F {
            r: 1.0,
            g: 1.0,
            b: 1.0,
            a: 1.0,
        }));
    } else {
        s.rt.Clear(Some(&D2D1_COLOR_F {
            r: 0.0,
            g: 0.0,
            b: 0.0,
            a: 0.0,
        }));
    }
    Ok(())
}

/// 标定点**自愈**: 回读自己刚画的那一帧, 在标定点附近找一块确定的纯背毛。
/// 为什么要这样: 形象一改(身体变小/坐姿旋转/加赛璐璐暗面), 手挑的点就可能落到
/// 描边、暗面或挎包上, 逐通道断言就变成**假红** —— 这个坑已经踩过三次
/// (挎包工具的描边、身体旋转、以及 V4 瘦身), 与其每次改画都手调坐标, 不如让它自己找。
unsafe fn refine_probe(s: &Surface, p: (f32, f32)) -> (f32, f32) {
    let px = |x: i32, y: i32| -> (u8, u8, u8, u8) {
        if x < 1 || y < 1 || x >= s.w - 1 || y >= s.h - 1 || s.bits.is_null() {
            return (0, 0, 0, 0);
        }
        let o = ((y as isize) * (s.w as isize) + x as isize) * 4;
        let q = s.bits as *const u8;
        unsafe {
            (
                *q.offset(o + 2),
                *q.offset(o + 1),
                *q.offset(o),
                *q.offset(o + 3),
            )
        }
    };
    let want = (
        (art::FUR.r * 255.0) as i32,
        (art::FUR.g * 255.0) as i32,
        (art::FUR.b * 255.0) as i32,
    );
    let plain = |c: (u8, u8, u8, u8)| {
        c.3 == 255
            && (c.0 as i32 - want.0).abs() <= 2
            && (c.1 as i32 - want.1).abs() <= 2
            && (c.2 as i32 - want.2).abs() <= 2
    };
    let (x0, y0) = (p.0.round() as i32, p.1.round() as i32);
    if plain(px(x0, y0)) {
        return p;
    }
    for r in 1..=30i32 {
        for (dx, dy) in [
            (r, 0),
            (-r, 0),
            (0, r),
            (0, -r),
            (r, r),
            (-r, -r),
            (r, -r),
            (-r, r),
        ] {
            let (x, y) = (x0 + dx, y0 + dy);
            if plain(px(x, y)) && plain(px(x + 1, y)) && plain(px(x, y + 1)) && plain(px(x - 1, y)) {
                return (x as f32, y as f32);
            }
        }
    }
    p
}

unsafe fn draw(
    s: &Surface,
    pose: &art::Pose,
    open: bool,
    flip: bool,
    page: usize,
    size: (i32, i32),
    thrown: &Option<f32>,
    scene: i32,
) -> Result<()> {
    begin(s, size.0, size.1)?;
    let ctx = art::Ctx {
        rt: &s.rt,
        b: &s.b,
        stroke: &s.stroke,
        factory: &s.factory,
        shapes: &s.shapes,
    };
    // 场景 1: 先把场地画了(球架在角色后面)
    if scene == 1 {
        let ground = S1.1 as f32 - ANCHOR_BOTTOM;
        let (flash, side, bx, by, spin) = PET
            .lock()
            .map(|g| (g.flash, g.ball_side, g.ball_x, g.ball_y, g.ball_spin))
            .unwrap_or((0.0, 1, 0.0, 0.0, 0.0));
        art::draw_hoop(&ctx, S1_AX + S1_HOOP_DX, ground, S1_RIM_Y, 1.0, flash);
        art::draw_hoop(&ctx, S1_AX - S1_HOOP_DX, ground, S1_RIM_Y, -1.0, flash);
        let _ = side;
        let _ = (bx, by, spin);
    }
    let probe = art::draw_dog(&ctx, pose);
    // 球在角色之前(拍球时球在爪下、投篮时球在手前)
    if scene == 1 {
        if let Ok(g) = PET.lock() {
            art::draw_ball(&ctx, g.ball_x, g.ball_y, S1_BALL_R, g.ball_spin);
        }
    }

    if open {
        let items = TOOLS.lock().map(|g| g.clone()).unwrap_or_default();
        let (anim, hover, hover_anim) = PET
            .lock()
            .map(|g| (g.anim, g.hover, g.hover_anim))
            .unwrap_or((1.0, -1, [0.0; palette::PER_PAGE]));
        let thrown_idx = PET.lock().map(|g| g.throw_idx).unwrap_or(-1);
        let l = palette::layout(items.len(), flip, page);
        let hover = if thrown.is_some() { thrown_idx } else { hover };
        let pull = thrown.map(|t| (thrown_idx.max(0) as usize, (t / T_PULL).clamp(0.0, 1.0)));
        palette::draw_panel(
            &ctx,
            &s.pb,
            &s.text,
            &items,
            &l,
            hover,
            &hover_anim,
            anim,
            pull,
        );
    }

    if let Ok(mut g) = PROBE.lock() {
        let (r, gg, b) = art::SHADOW_TINT;
        g[0] = [
            probe.shadow.0,
            probe.shadow.1,
            r,
            gg,
            b,
            art::SHADOW_TOTAL_ALPHA,
        ];
        let body = refine_probe(s, probe.body);
        let f = art::FUR;
        g[1] = [body.0, body.1, f.r, f.g, f.b, f.a];
    }
    s.rt.EndDraw(None, None)?;
    Ok(())
}

/// 飞行物: 旋转的圆角方块(取工具 code 的首字) + 落点爆开的圈
unsafe fn draw_fx(s: &Surface, thrown: &Option<f32>, burst: f32, letter: &str) -> Result<()> {
    begin(s, FX, FX)?;
    let ctx = art::Ctx {
        rt: &s.rt,
        b: &s.b,
        stroke: &s.stroke,
        factory: &s.factory,
        shapes: &s.shapes,
    };
    let c = FX as f32 * 0.5;
    if let Some(&t) = thrown.as_ref() {
        if t < T_PULL + T_FLY {
            let k = ((t - T_PULL) / T_FLY).clamp(0.0, 1.0);
            // 拖影: 往回画三个越来越淡的影子
            for i in (1..=3).rev() {
                let kk = (k - i as f32 * 0.035).max(0.0);
                let wob = (kk * 6.0) * 0.9;
                let r = 17.0 - i as f32 * 1.5;
                ctx.rot_at(wob, (c, c), |ctx| {
                    let _ = ctx.rt.FillRoundedRectangle(
                        &art::rounded(c - r, c - r, r * 2.0, r * 2.0, 6.0),
                        &s.pb.icons[1],
                    );
                });
            }
            let _ = s.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2::identity());
            ctx.rot_at(k * 9.0, (c, c), |ctx| {
                let _ = ctx.rt.FillRoundedRectangle(
                    &art::rounded(c - 19.0, c - 19.0, 38.0, 38.0, 8.0),
                    &s.b.outline,
                );
                let _ = ctx.rt.FillRoundedRectangle(
                    &art::rounded(c - 16.0, c - 16.0, 32.0, 32.0, 6.0),
                    &s.pb.icons[0],
                );
            });
            let _ = s.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2::identity());
            s.text.draw(
                &s.rt,
                &letter,
                c - 19.0,
                c - 19.0,
                38.0,
                38.0,
                &s.pb.white,
                &s.text.bold,
                1,
                1,
            );
        }
    }
    if burst > 0.0 {
        let k = 1.0 - (burst / T_BURST);
        for i in 0..3 {
            let r = 26.0 + k * 70.0 + i as f32 * 16.0;
            let a = (1.0 - k) * (0.55 - i as f32 * 0.15);
            if a <= 0.0 {
                continue;
            }
            // 用现成的暖黄笔刷, 不再每帧新建(爆开只有 0.38 秒, 但 120fps 下也是每帧 3 个 COM 对象)
            let ring = s.rt.CreateSolidColorBrush(
                &D2D1_COLOR_F {
                    r: 1.0,
                    g: 0.85,
                    b: 0.45,
                    a,
                },
                None,
            )?;
            let _ = s.rt.DrawEllipse(
                &D2D1_ELLIPSE {
                    point: D2D_POINT_2F { x: c, y: c },
                    radiusX: r,
                    radiusY: r,
                },
                &ring,
                4.0,
                None,
            );
        }
    }
    s.rt.EndDraw(None, None)?;
    Ok(())
}

unsafe fn present(
    hwnd: HWND,
    screen_dc: HDC,
    s: &Surface,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
) -> Result<()> {
    let dst = POINT { x, y };
    let size = SIZE { cx: w, cy: h };
    let src = POINT { x: 0, y: 0 };
    let blend = BLENDFUNCTION {
        BlendOp: AC_SRC_OVER as u8,
        BlendFlags: 0,
        SourceConstantAlpha: 255,
        AlphaFormat: AC_SRC_ALPHA as u8,
    };
    let _ = (s.w, s.h);
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
