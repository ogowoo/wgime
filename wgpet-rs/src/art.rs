//! 角色绘制 —— 全部矢量零件, 由 D2D 抗锯齿渲染, 不用位图资源。
//!
//! 为什么不用精灵图集: ①矢量可以按参数连续形变(腿的 2 骨 IK、尾巴摆动、耳朵下垂),
//! 动作比抽帧图集顺; ②不必给 Rust 侧引入 PNG 解码依赖, 少一个能坏的地方;
//! ③任意缩放都不糊。若以后要换成美术画的图集, 只要替换本文件的 `draw_dog` 即可。
//!
//! 坐标系: **脚底中心为原点, y 向上为负**, 单位 ≈ 像素(scale=1 时)。
//! 朝向由 `face` 镜像; 所有部位先按"面向右"画, 需要时整体水平翻转。
//!
//! 两条踩过的坑(改这块务必注意):
//! ①`rot_at` 必须**与外层变换相乘**, 不能直接 `SetTransform(R)` —— 后者是绝对赋值,
//!   会把"镜像 + 平移"抹掉, 于是身体/头被画到窗口原点附近(窗口外), 屏幕上只剩腿和尾巴;
//! ②摆动相位一律用 `sin() `**有界**取角, 不能拿时间当角度累加(无界角度会把尾巴折进身体里)。

use windows::core::*;
use windows::Foundation::Numerics::Matrix3x2;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;

// ---------------------------------------------------------------- 配色

const fn rgb(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
}

/// 奶油色柯基风: 背毛暖棕、胸口/口鼻奶油白、四肢末端深棕、皮挎包。
pub const FUR: D2D1_COLOR_F = rgb(0.816, 0.545, 0.286, 1.0);
const FUR_LIGHT: D2D1_COLOR_F = rgb(0.976, 0.918, 0.831, 1.0);
const FUR_DARK: D2D1_COLOR_F = rgb(0.545, 0.318, 0.149, 1.0);
const FUR_SHADE: D2D1_COLOR_F = rgb(0.702, 0.435, 0.208, 1.0);
/// 描边: 卡通角色有没有这一圈差别很大(浅色/深色背景上都立得住)
const OUTLINE: D2D1_COLOR_F = rgb(0.353, 0.216, 0.114, 1.0);
const EAR_IN: D2D1_COLOR_F = rgb(0.804, 0.549, 0.451, 1.0);
const NOSE: D2D1_COLOR_F = rgb(0.196, 0.157, 0.176, 1.0);
const EYE: D2D1_COLOR_F = rgb(0.106, 0.090, 0.125, 1.0);
const EYE_HI: D2D1_COLOR_F = rgb(1.0, 1.0, 1.0, 0.95);
const STRAP: D2D1_COLOR_F = rgb(0.408, 0.259, 0.169, 1.0);
const BAG: D2D1_COLOR_F = rgb(0.769, 0.396, 0.231, 1.0);
const BAG_DARK: D2D1_COLOR_F = rgb(0.588, 0.275, 0.153, 1.0);
const METAL: D2D1_COLOR_F = rgb(0.925, 0.855, 0.612, 1.0);
const TOOL_A: D2D1_COLOR_F = rgb(0.361, 0.612, 0.812, 1.0);
const TOOL_B: D2D1_COLOR_F = rgb(0.945, 0.769, 0.259, 1.0);
const TOOL_C: D2D1_COLOR_F = rgb(0.541, 0.749, 0.478, 1.0);

/// 地面软阴影三层各自的 alpha(外→内)
const SH_OUT: f32 = 0.045;
const SH_MID: f32 = 0.11;
pub const SH_CORE: f32 = 0.22;
/// 三层叠起来在该点的**合成** alpha —— 宿主的验收探针按它做逐像素 alpha 的整数断言。
/// (曾经拿单层 0.22 去比, 差 9 个色阶, 白查了一轮: 那个点被三层同时盖住。)
pub const SHADOW_TOTAL_ALPHA: f32 = 1.0 - (1.0 - SH_OUT) * (1.0 - SH_MID) * (1.0 - SH_CORE);
/// 阴影标定点的颜色(不是纯黑, 是带一点冷调的深灰紫)
pub const SHADOW_TINT: (f32, f32, f32) = (0.09, 0.07, 0.10);
const SHADOW_OUT_C: D2D1_COLOR_F = rgb(SHADOW_TINT.0, SHADOW_TINT.1, SHADOW_TINT.2, SH_OUT);
const SHADOW_MID_C: D2D1_COLOR_F = rgb(SHADOW_TINT.0, SHADOW_TINT.1, SHADOW_TINT.2, SH_MID);
const SHADOW_CORE_C: D2D1_COLOR_F = rgb(SHADOW_TINT.0, SHADOW_TINT.1, SHADOW_TINT.2, SH_CORE);

pub struct Brushes {
    pub fur: ID2D1SolidColorBrush,
    pub fur_light: ID2D1SolidColorBrush,
    pub fur_dark: ID2D1SolidColorBrush,
    pub fur_shade: ID2D1SolidColorBrush,
    pub outline: ID2D1SolidColorBrush,
    pub ear_in: ID2D1SolidColorBrush,
    pub nose: ID2D1SolidColorBrush,
    pub eye: ID2D1SolidColorBrush,
    pub eye_hi: ID2D1SolidColorBrush,
    pub strap: ID2D1SolidColorBrush,
    pub bag: ID2D1SolidColorBrush,
    pub bag_dark: ID2D1SolidColorBrush,
    pub metal: ID2D1SolidColorBrush,
    pub tool_a: ID2D1SolidColorBrush,
    pub tool_b: ID2D1SolidColorBrush,
    pub tool_c: ID2D1SolidColorBrush,
    pub sh_core: ID2D1SolidColorBrush,
    pub sh_mid: ID2D1SolidColorBrush,
    pub sh_out: ID2D1SolidColorBrush,
}

impl Brushes {
    pub fn new(rt: &ID2D1RenderTarget) -> Result<Self> {
        let mk = |c: D2D1_COLOR_F| -> Result<ID2D1SolidColorBrush> {
            unsafe { rt.CreateSolidColorBrush(&c, None) }
        };
        Ok(Self {
            fur: mk(FUR)?,
            fur_light: mk(FUR_LIGHT)?,
            fur_dark: mk(FUR_DARK)?,
            fur_shade: mk(FUR_SHADE)?,
            outline: mk(OUTLINE)?,
            ear_in: mk(EAR_IN)?,
            nose: mk(NOSE)?,
            eye: mk(EYE)?,
            eye_hi: mk(EYE_HI)?,
            strap: mk(STRAP)?,
            bag: mk(BAG)?,
            bag_dark: mk(BAG_DARK)?,
            metal: mk(METAL)?,
            tool_a: mk(TOOL_A)?,
            tool_b: mk(TOOL_B)?,
            tool_c: mk(TOOL_C)?,
            sh_core: mk(SHADOW_CORE_C)?,
            sh_mid: mk(SHADOW_MID_C)?,
            sh_out: mk(SHADOW_OUT_C)?,
        })
    }
}

// ---------------------------------------------------------------- 姿势参数

/// 一帧的全部姿态输入。状态机只改这些数, 绘制完全由它们决定。
#[derive(Clone, Copy)]
pub struct Pose {
    /// 脚底中心(窗口坐标)
    pub x: f32,
    /// 地面 y(窗口坐标)
    pub ground: f32,
    /// +1 面向右 / -1 面向左
    pub face: f32,
    pub scale: f32,
    /// 步态相位 0..1, 每走一步 +1
    pub gait: f32,
    /// 步幅(0 = 站住不走)
    pub stride: f32,
    /// 抬脚高度
    pub lift: f32,
    /// 身体前后倾(弧度)
    pub lean: f32,
    /// 身体上下起伏(额外位移)
    pub bob: f32,
    /// 尾巴摆动相位(秒)
    pub tail: f32,
    /// 耳朵摆动相位(秒)
    pub ear: f32,
    /// 0=睁眼 1=闭眼
    pub blink: f32,
    /// 抬头看鼠标: -1..1(正=朝面朝方向看)
    pub look: f32,
    /// 0=趴着睡 1=正常站
    pub up: f32,
    /// 警觉(竖耳 + 抬尾)
    pub alert: f32,
}

impl Default for Pose {
    fn default() -> Self {
        Self {
            x: 0.0,
            ground: 0.0,
            face: 1.0,
            scale: 1.0,
            gait: 0.0,
            stride: 0.0,
            lift: 0.0,
            lean: 0.0,
            bob: 0.0,
            tail: 0.0,
            ear: 0.0,
            blink: 0.0,
            look: 0.0,
            up: 1.0,
            alert: 0.0,
        }
    }
}

// ---------------------------------------------------------------- 绘制工具

type Pt = (f32, f32);

fn ell(x: f32, y: f32, rx: f32, ry: f32) -> D2D1_ELLIPSE {
    D2D1_ELLIPSE {
        point: D2D_POINT_2F { x, y },
        radiusX: rx,
        radiusY: ry,
    }
}

fn pt(p: Pt) -> D2D_POINT_2F {
    D2D_POINT_2F { x: p.0, y: p.1 }
}

fn rr(x: f32, y: f32, w: f32, h: f32, rx: f32, ry: f32) -> D2D1_ROUNDED_RECT {
    D2D1_ROUNDED_RECT {
        rect: D2D_RECT_F {
            left: x,
            top: y,
            right: x + w,
            bottom: y + h,
        },
        radiusX: rx,
        radiusY: ry,
    }
}

/// 2 骨 IK: 给定髋/肩 S 与脚 F, 求膝/肘。`bend` 正负决定往哪边弓。
/// 腿骨总长要**只比髋脚距离略长**, 否则膝盖会凸出一大截变成"Λ"形(真踩过)。
fn ik(s: Pt, f: Pt, l1: f32, l2: f32, bend: f32) -> Pt {
    let dx = f.0 - s.0;
    let dy = f.1 - s.1;
    let d = (dx * dx + dy * dy).sqrt().max(0.001);
    let d = d.min(l1 + l2 - 0.01).max((l1 - l2).abs() + 0.01);
    let a = (l1 * l1 - l2 * l2 + d * d) / (2.0 * d);
    let h = (l1 * l1 - a * a).max(0.0).sqrt();
    let ux = dx / d;
    let uy = dy / d;
    (s.0 + ux * a - uy * h * bend, s.1 + uy * a + ux * h * bend)
}

pub struct Ctx<'a> {
    pub rt: &'a ID2D1RenderTarget,
    pub b: &'a Brushes,
    pub stroke: &'a ID2D1StrokeStyle,
}

impl<'a> Ctx<'a> {
    unsafe fn limb(&self, a: Pt, c: Pt, w: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.DrawLine(pt(a), pt(c), brush, w, Some(self.stroke));
    }
    unsafe fn disc(&self, p: Pt, r: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.FillEllipse(&ell(p.0, p.1, r, r), brush);
    }
    unsafe fn oval(&self, p: Pt, rx: f32, ry: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.FillEllipse(&ell(p.0, p.1, rx, ry), brush);
    }
    /// 带描边的椭圆: 先画大一圈的深色, 再画本色
    unsafe fn oval_out(&self, p: Pt, rx: f32, ry: f32, brush: &ID2D1SolidColorBrush, w: f32) {
        self.oval(p, rx + w, ry + w, &self.b.outline);
        self.oval(p, rx, ry, brush);
    }
    /// 绕 (cx,cy) 旋转 angle 弧度后执行 f(与外层变换**相乘**, 不是替换)
    unsafe fn rot_at<F: FnOnce(&Self)>(&self, angle: f32, c: Pt, f: F) {
        let mut cur = Matrix3x2::default();
        self.rt.GetTransform(&mut cur);
        let _ = self
            .rt
            .SetTransform(&(Matrix3x2::rotation(angle, c.0, c.1) * cur));
        f(self);
        let _ = self.rt.SetTransform(&cur);
    }
    unsafe fn line_w(&self, a: Pt, c: Pt, w: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.DrawLine(pt(a), pt(c), brush, w, None);
    }
}

/// 一条腿: 髋/肩 → 膝/肘 → 爪, 带描边
unsafe fn leg(c: &Ctx, s: Pt, f: Pt, bend: f32, w: f32, far: bool) {
    // 骨长只比髋脚距离略长 => 膝盖只轻微外凸; 太长会变成"Λ"形
    let k = ik(s, f, 21.5, 21.5, bend);
    let fur = if far { &c.b.fur_shade } else { &c.b.fur };
    c.limb(s, k, w + 3.0, &c.b.outline);
    c.limb(k, f, w * 0.86 + 2.8, &c.b.outline);
    c.limb(s, k, w, fur);
    c.limb(k, f, w * 0.86, fur);
    // 爪
    c.oval((f.0 + 1.5, f.1), w * 0.86, w * 0.6, &c.b.outline);
    c.oval((f.0 + 1.5, f.1), w * 0.7, w * 0.47, &c.b.fur_dark);
}

/// 尾巴: 4 段递减粗细 + 一撮毛。`phase` 是**时间相位**, 摆角由 sin 取(有界)。
unsafe fn tail(c: &Ctx, base: Pt, phase: f32, alert: f32, up: f32) {
    let lift = 0.34 + alert * 0.75 * up; // 0 → 正后方, π/2 → 正上方
    let mut cur = base;
    let mut w = 10.4;
    for i in 0..4 {
        let wag = (phase * std::f32::consts::TAU + i as f32 * 0.55).sin() * 0.26;
        let ang = lift + wag + i as f32 * 0.05;
        let len = 12.5 - i as f32 * 1.2;
        let nx = cur.0 - ang.cos() * len;
        let ny = cur.1 - ang.sin() * len;
        c.limb(cur, (nx, ny), w + 2.6, &c.b.outline);
        c.limb(cur, (nx, ny), w, &c.b.fur);
        cur = (nx, ny);
        w *= 0.88;
    }
    c.oval((cur.0 + 1.5, cur.1 - 1.0), 8.0, 7.4, &c.b.outline);
    c.oval((cur.0 + 1.5, cur.1 - 1.0), 6.4, 5.8, &c.b.fur_light);
}

/// 垂耳: 从头顶往侧下方耷拉。`alert` 时抬起。
unsafe fn ear(c: &Ctx, root: Pt, side: f32, swing: f32, alert: f32, far: bool) {
    let h = 17.0 - alert * 8.0;
    let ang = side * 0.55 + swing + alert * side * 0.55;
    let brush = if far { &c.b.fur_shade } else { &c.b.fur };
    c.rot_at(ang, root, |c| {
        c.oval((root.0 + side * 1.5, root.1 + h * 0.45), 7.8, h * 0.62, &c.b.outline);
        c.oval((root.0 + side * 1.5, root.1 + h * 0.45), 6.6, h * 0.52, brush);
        if !far {
            c.oval((root.0 + side * 1.8, root.1 + h * 0.5), 3.6, h * 0.3, &c.b.ear_in);
        }
    });
}

/// 挎包: 斜挎带 + 包体 + 翻盖 + 扣子 + 露出的小工具
unsafe fn satchel(c: &Ctx, bx: f32, by: f32, flap: f32, tools: usize) {
    // 露出的工具(在带子后面)
    let colors = [&c.b.tool_a, &c.b.tool_b, &c.b.tool_c];
    for i in 0..tools.min(3) {
        let x = bx - 19.0 + i as f32 * 9.5;
        c.rot_at(-0.32 + i as f32 * 0.28, (x, by - 2.0), |c| {
            let _ = c.rt.FillRoundedRectangle(
                &rr(x - 3.4, by - 22.0, 6.8, 21.0, 3.0, 3.0),
                &c.b.outline,
            );
            let _ = c.rt.FillRoundedRectangle(
                &rr(x - 2.4, by - 20.5, 4.8, 18.5, 2.2, 2.2),
                colors[i],
            );
        });
    }
    // 斜挎带
    c.limb((bx + 26.0, by - 20.0), (bx - 12.0, by + 14.0), 6.2, &c.b.outline);
    c.limb((bx + 26.0, by - 20.0), (bx - 12.0, by + 14.0), 4.2, &c.b.strap);
    // 包体(带描边)
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(bx - 22.5, by - 5.5, 41.0, 33.0, 7.0, 7.0), &c.b.outline);
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(bx - 20.5, by - 3.5, 37.0, 29.0, 6.0, 6.0), &c.b.bag);
    // 翻盖(走路时轻微起伏)
    let _ = c.rt.FillRoundedRectangle(
        &rr(bx - 20.5, by - 5.0 + flap * 1.2, 37.0, 16.0, 6.0, 5.0),
        &c.b.bag_dark,
    );
    // 扣子
    let _ = c.rt.FillRoundedRectangle(
        &rr(bx - 5.0, by + 6.0, 10.0, 7.0, 2.0, 2.0),
        &c.b.outline,
    );
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(bx - 3.6, by + 7.2, 7.2, 4.6, 1.4, 1.4), &c.b.metal);
}

/// 给宿主探针的两个标定点(窗口坐标): 阴影核心(恒定合成 alpha)与本体(不透明)。
/// 有了它们, 验收就能做**逐通道整数**的 alpha 断言, 而不是"看着差不多"。
pub struct Probe {
    pub shadow: Pt,
    pub body: Pt,
}

/// 画一只狗。返回两个标定点。
pub unsafe fn draw_dog(c: &Ctx, p: &Pose) -> Probe {
    let s = p.scale;
    let _ = c.rt.SetTransform(&Matrix3x2 {
        M11: p.face * s,
        M12: 0.0,
        M21: 0.0,
        M22: s,
        M31: p.x,
        M32: p.ground,
    });

    let up = p.up;
    let body_y = -58.0 * up - 16.0 * (1.0 - up) + p.bob;
    let body_rot = p.lean * 0.6 + (1.0 - up) * 0.18;

    // ---- 地面软阴影: 三层递减 alpha + 半径, 核心层是恒定 alpha(探针按合成值断言)
    let sy = 2.0;
    c.oval((-2.0, sy), 50.0, 10.5, &c.b.sh_out);
    c.oval((-2.0, sy), 38.0, 8.0, &c.b.sh_mid);
    let shadow_core_local = (-2.0, sy);
    c.oval(shadow_core_local, 25.0, 5.4, &c.b.sh_core);

    // ---- 远侧两条腿(先画, 显深, 制造前后层次)
    let (ff, fr) = feet(p, 0.5, 28.0, -34.0);
    leg(c, (24.0, body_y + 16.0), (ff.0, ff.1), -1.0, 8.0, true);
    leg(c, (-32.0, body_y + 18.0), (fr.0, fr.1), 1.0, 8.8, true);

    // ---- 尾巴(在身体之后)
    tail(c, (-40.0, body_y - 14.0), p.tail, p.alert, up);

    // ---- 身体
    c.rot_at(body_rot, (0.0, body_y), |c| {
        c.oval((0.0, body_y), 49.0, 28.0 * (0.84 + 0.16 * up), &c.b.outline);
        c.oval((0.0, body_y), 47.0, 26.0 * (0.84 + 0.16 * up), &c.b.fur);
        // 肚子/胸口奶油色
        c.oval((11.0, body_y + 11.0), 27.0, 14.0, &c.b.fur_light);
        // 背脊高光
        c.oval((-6.0, body_y - 17.0), 27.0, 5.2, &c.b.fur_shade);
    });

    // ---- 挎包(骑在身体上)
    c.rot_at(body_rot, (0.0, body_y), |c| {
        satchel(c, -7.0, body_y + 6.0, p.bob, 3);
    });

    // ---- 近侧两条腿
    let (nf, nr) = feet(p, 0.0, 36.0, -26.0);
    leg(c, (32.0, body_y + 16.0), (nf.0, nf.1), -1.0, 8.6, false);
    leg(c, (-22.0, body_y + 18.0), (nr.0, nr.1), 1.0, 9.2, false);

    // ---- 脖子: 把身体和头连起来(不描边, 否则肩上会多出一道深色圆弧)
    let neck = (28.0, body_y - 22.0);
    c.rot_at(0.42, neck, |c| {
        c.oval(neck, 17.0, 15.0, &c.b.fur);
    });

    // ---- 头
    let hx = 42.0 + p.look * 5.0 + (1.0 - up) * -14.0;
    let hy = body_y - 35.0 - up * 3.0 + (1.0 - up) * 10.0;
    c.rot_at(body_rot * 0.7 + p.look * 0.06, (hx, hy), |c| {
        // 远侧耳(在头后面)
        ear(c, (hx + 3.0, hy - 14.0), -1.0, p.ear * 0.8, p.alert, true);
        // 头
        c.oval((hx, hy), 26.0, 24.5, &c.b.outline);
        c.oval((hx, hy), 24.3, 22.8, &c.b.fur);
        // 近侧耳: **必须在口鼻/眼睛之前画**, 而且要往外推 ——
        // 否则它会盖住眼睛(真事故: 屏幕上只看得见一只眼)
        ear(c, (hx + 18.0, hy - 12.0), 1.0, -p.ear * 0.8, p.alert, false);
        // 额前浅色
        c.oval((hx + 8.0, hy + 8.0), 14.0, 10.0, &c.b.fur_light);
        // 口鼻(压低、收小, 免得把眼睛挤掉)
        let mz = (hx + 21.0, hy + 11.0);
        c.oval(mz, 13.0, 10.5, &c.b.outline);
        c.oval(mz, 11.6, 9.2, &c.b.fur_light);
        // 鼻头
        let ns = (hx + 30.0, hy + 7.0);
        c.oval(ns, 5.6, 4.4, &c.b.outline);
        c.oval(ns, 4.4, 3.3, &c.b.nose);
        // 嘴
        c.line_w((hx + 27.0, hy + 13.5), (hx + 19.0, hy + 15.5), 1.7, &c.b.outline);
        // 眼: 两只间距要够(小于 8 单位就会糊成一个黑点), blink 压扁
        let eh = 4.6 * (1.0 - p.blink).max(0.07);
        let e1 = (hx - 1.0 + p.look * 2.0, hy - 7.0);
        let e2 = (hx + 13.0 + p.look * 2.0, hy - 9.0);
        for e in [e1, e2] {
            c.oval(e, 4.2, eh + 0.6, &c.b.outline);
            c.oval(e, 3.4, eh, &c.b.eye);
            c.disc((e.0 + 1.1, e.1 - 1.4), 1.5, &c.b.eye_hi);
        }
    });

    let _ = c.rt.SetTransform(&Matrix3x2::identity());
    // 本体标定点: 必须挑一块**确定的纯背毛**——不能压在奶油色肚皮/挎包/工具/描边上。
    // 曾经取 (-30, body_y-8), 那一带正好被挎包里竖出来的工具描边盖住, 读数变成描边色
    // (逐通道断言因此假红)。改到后腰下方, 距最近的工具描边还有 6 个单位。
    let body_local = (-36.0, body_y + 4.0);
    let w = |l: Pt| (p.x + p.face * s * l.0, p.ground + s * l.1);
    Probe {
        shadow: w(shadow_core_local),
        body: w(body_local),
    }
}

/// 四只脚的落点。`phase` 决定这一对腿的相位(近侧 0 / 远侧 0.5 = 对角步态)。
fn feet(p: &Pose, phase: f32, front_x: f32, rear_x: f32) -> (Pt, Pt) {
    let foot = |base_x: f32, ph: f32| -> Pt {
        let th = (p.gait + ph) * std::f32::consts::TAU;
        let swing = th.sin();
        let x = base_x + swing * p.stride * 0.5;
        // 只有向后摆(支撑相)时贴地, 其余抬起
        let lift = if swing < 0.0 { 0.0 } else { p.lift * swing };
        (x, -lift)
    };
    (foot(front_x, phase), foot(rear_x, phase + 0.5))
}
