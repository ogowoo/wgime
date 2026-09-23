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
    pub factory: &'a ID2D1Factory,
    /// 缓存好的形状(每帧重建路径既慢又费内存)
    pub shapes: &'a Shapes,
}

/// 一次性建好、之后只靠变换摆放的路径。
/// 狗头/耳朵的形状是**固定**的, 变的是位置和角度 —— 所以只建一次。
pub struct Shapes {
    pub head: ID2D1PathGeometry,
    pub ear: ID2D1PathGeometry,
}

fn bez(p1: Pt, p2: Pt, p3: Pt) -> D2D1_BEZIER_SEGMENT {
    D2D1_BEZIER_SEGMENT {
        point1: pt(p1),
        point2: pt(p2),
        point3: pt(p3),
    }
}

/// 狗头侧面轮廓(朝右, 原点=头中心):
/// 颅顶圆 → 前额 → **前伸的吻部** → 上唇 → 下巴 → 后脑闭合。
/// 之前用两个椭圆拼(圆头 + 奶油色大椭圆), 读起来像海豹/水獭 —— 不像狗, 这才是真原因。
fn build_head(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((-15.0, -15.0)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((2.0, -31.0), (20.0, -22.0), (26.0, -8.0)));
        s.AddBezier(&bez((30.0, 0.0), (33.0, 5.0), (35.0, 7.5)));
        s.AddBezier(&bez((37.5, 10.5), (30.0, 14.5), (21.0, 14.0)));
        s.AddBezier(&bez((10.0, 13.5), (0.0, 12.0), (-6.0, 8.0)));
        s.AddBezier(&bez((-16.0, 2.0), (-22.0, -6.0), (-15.0, -15.0)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

/// 立耳: 底边在 y=0、尖端朝上的圆角三角(柯基那种)。垂耳/圆耳读起来像发髻。
fn build_ear(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((-9.0, 1.5)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((-8.0, -13.0), (-3.5, -23.0), (0.5, -26.0)));
        s.AddBezier(&bez((5.0, -23.0), (9.0, -13.0), (9.0, 1.5)));
        s.AddBezier(&bez((5.0, 4.0), (-5.0, 4.0), (-9.0, 1.5)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

impl Shapes {
    pub fn new(f: &ID2D1Factory) -> Result<Self> {
        Ok(Self {
            head: build_head(f)?,
            ear: build_ear(f)?,
        })
    }
}

impl<'a> Ctx<'a> {
    pub(crate) unsafe fn limb(&self, a: Pt, c: Pt, w: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.DrawLine(pt(a), pt(c), brush, w, Some(self.stroke));
    }
    pub(crate) unsafe fn disc(&self, p: Pt, r: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.FillEllipse(&ell(p.0, p.1, r, r), brush);
    }
    pub(crate) unsafe fn oval(&self, p: Pt, rx: f32, ry: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.FillEllipse(&ell(p.0, p.1, rx, ry), brush);
    }
    /// 绕 (cx,cy) 旋转 angle 弧度后执行 f(与外层变换**相乘**, 不是替换)
    pub(crate) unsafe fn rot_at<F: FnOnce(&Self)>(&self, angle: f32, c: Pt, f: F) {
        let mut cur = Matrix3x2::default();
        self.rt.GetTransform(&mut cur);
        let _ = self
            .rt
            .SetTransform(&(Matrix3x2::rotation(angle, c.0, c.1) * cur));
        f(self);
        let _ = self.rt.SetTransform(&cur);
    }
    /// 把局部坐标系的**原点**挪到 `at` 并旋转 angle(之后就能按"相对头中心"的点画东西)
    pub(crate) unsafe fn at<F: FnOnce(&Self)>(&self, at: Pt, angle: f32, f: F) {
        let mut cur = Matrix3x2::default();
        self.rt.GetTransform(&mut cur);
        let m = Matrix3x2::rotation(angle, at.0, at.1) * Matrix3x2::translation(at.0, at.1);
        let _ = self.rt.SetTransform(&(m * cur));
        f(self);
        let _ = self.rt.SetTransform(&cur);
    }
    /// 摆放一个缓存好的路径: 以它的局部原点为基准缩放/旋转, 填充 + 描边
    pub(crate) unsafe fn place(
        &self,
        geo: &ID2D1PathGeometry,
        at: Pt,
        angle: f32,
        sx: f32,
        sy: f32,
        fill: Option<&ID2D1SolidColorBrush>,
        outline: f32,
    ) {
        let mut cur = Matrix3x2::default();
        self.rt.GetTransform(&mut cur);
        let m = Matrix3x2::rotation(angle, at.0, at.1)
            * Matrix3x2 {
                M11: sx,
                M12: 0.0,
                M21: 0.0,
                M22: sy,
                M31: at.0,
                M32: at.1,
            };
        let _ = self.rt.SetTransform(&(m * cur));
        if let Some(br) = fill {
            let _ = self.rt.FillGeometry(geo, br, None);
        }
        if outline > 0.0 {
            let _ = self.rt.DrawGeometry(geo, &self.b.outline, outline, None);
        }
        let _ = self.rt.SetTransform(&cur);
    }
    pub(crate) unsafe fn line_w(&self, a: Pt, c: Pt, w: f32, brush: &ID2D1SolidColorBrush) {
        let _ = self.rt.DrawLine(pt(a), pt(c), brush, w, None);
    }
}

/// 给外面用的圆角矩形构造(面板模块用)
pub(crate) fn rounded(x: f32, y: f32, w: f32, h: f32, r: f32) -> D2D1_ROUNDED_RECT {
    rr(x, y, w, h, r, r)
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

/// 尾巴: **毛茸茸的羽状尾** —— 沿脊柱生成左右两侧轮廓再闭合填充。
/// 老写法是"一根渐细的线 + 末端一个球", 读起来像老鼠尾巴而不是狗的尾巴。
/// `phase` 是时间相位, 摆角由 sin 取(有界; 拿时间当角度累加会把尾巴折进身体里)。
unsafe fn tail(c: &Ctx, base: Pt, phase: f32, alert: f32, up: f32) {
    use std::f32::consts::{PI, TAU};
    const N: usize = 7;
    let mut spine = [(0.0f32, 0.0f32); N + 1];
    spine[0] = base;
    let mut ang = 0.30 + alert * 0.72 * up; // 0 → 正后方, π/2 → 正上方
    let mut cur = base;
    for i in 0..N {
        let t = i as f32 / N as f32;
        let wag = (phase * TAU + i as f32 * 0.5).sin() * 0.20;
        ang += wag * 0.32 - 0.02;
        let len = 4.8 + 2.8 * (t * PI).sin();
        cur = (cur.0 - ang.cos() * len, cur.1 - ang.sin() * len);
        spine[i + 1] = cur;
    }
    // 宽度剖面: 根部细 → 中后段最粗(蓬松) → 尖端收
    let mut left = [(0.0f32, 0.0f32); N + 1];
    let mut right = [(0.0f32, 0.0f32); N + 1];
    for i in 0..=N {
        let t = i as f32 / N as f32;
        let w = 3.2 + 7.6 * (t * PI * 0.9).sin();
        let (dx, dy) = if i == 0 {
            (spine[1].0 - spine[0].0, spine[1].1 - spine[0].1)
        } else {
            (spine[i].0 - spine[i - 1].0, spine[i].1 - spine[i - 1].1)
        };
        let l = (dx * dx + dy * dy).sqrt().max(0.001);
        let (nx, ny) = (-dy / l, dx / l);
        left[i] = (spine[i].0 + nx * w, spine[i].1 + ny * w);
        right[i] = (spine[i].0 - nx * w, spine[i].1 - ny * w);
    }
    let Ok(geo) = c.factory.CreatePathGeometry() else {
        return;
    };
    let Ok(sink) = geo.Open() else { return };
    sink.BeginFigure(pt(left[0]), D2D1_FIGURE_BEGIN_FILLED);
    for p in left.iter().take(N + 1).skip(1) {
        sink.AddLine(pt(*p));
    }
    let (ex, ey) = (spine[N].0 - spine[N - 1].0, spine[N].1 - spine[N - 1].1);
    let el = (ex * ex + ey * ey).sqrt().max(0.001);
    sink.AddLine(pt((spine[N].0 + ex / el * 5.5, spine[N].1 + ey / el * 5.5)));
    for p in right.iter().rev() {
        sink.AddLine(pt(*p));
    }
    sink.EndFigure(D2D1_FIGURE_END_CLOSED);
    if sink.Close().is_err() {
        return;
    }
    let _ = c.rt.FillGeometry(&geo, &c.b.fur, None);
    let _ = c.rt.DrawGeometry(&geo, &c.b.outline, 2.4, None);
    // 尾尖那撮白毛(柯基尾巴尖就是白的)
    c.disc(spine[N], 4.4, &c.b.fur_light);
}

/// 耳: 三角立耳。`tilt` 是相对头顶的外倾角, `alert` 时立得更直。
/// 老写法是两个圆椭圆耷在头顶, 读起来像发髻 —— 用户原话"耳朵位置有点诡异"。
unsafe fn ear(c: &Ctx, base: Pt, tilt: f32, swing: f32, alert: f32, far: bool) {
    let sy = (if far { 0.88 } else { 1.0 }) * (1.0 - alert * 0.16);
    let sx = if far { 0.9 } else { 1.0 };
    let ang = tilt + swing - alert * tilt * 0.45;
    let fill = if far { &c.b.fur_shade } else { &c.b.fur };
    c.place(&c.shapes.ear, base, ang, sx, sy, Some(fill), 2.4);
    if !far {
        // 内耳: 同一形状缩小, 只填色不描边
        c.place(
            &c.shapes.ear,
            (base.0 + 0.5, base.1 + 2.0),
            ang,
            0.52,
            sy * 0.60,
            Some(&c.b.ear_in),
            0.0,
        );
    }
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

    // ---- 头: 用**一条狗头侧面轮廓**(颅顶圆 → 前伸吻部 → 下巴)而不是两个椭圆拼。
    // 两个椭圆拼出来的是"圆头 + 奶油色大椭圆", 读起来像海豹/水獭 —— 这才是"狗头不像狗"的真原因。
    let hx = 44.0 + p.look * 5.0 + (1.0 - up) * -14.0;
    let hy = body_y - 36.0 - up * 3.0 + (1.0 - up) * 10.0;
    c.at((hx, hy), body_rot * 0.7 + p.look * 0.06, |c| {
        // 远侧耳(三角立耳, 画在头后面)
        ear(c, (-6.0, -16.0), -0.34, p.ear * 0.5, p.alert, true);
        // 头
        c.place(&c.shapes.head, (0.0, 0.0), 0.0, 1.0, 1.0, Some(&c.b.fur), 2.6);
        // 吻部浅色 + 额前白斑(柯基那副脸)
        c.oval((17.0, 5.0), 12.0, 7.0, &c.b.fur_light);
        c.oval((6.0, -9.0), 5.5, 12.0, &c.b.fur_light);
        // 鼻头(可以略微探出吻尖, 狗鼻子本来就鼓出来)
        c.oval((35.0, 6.5), 5.4, 4.2, &c.b.outline);
        c.oval((35.0, 6.5), 4.2, 3.1, &c.b.nose);
        // 嘴
        c.line_w((31.0, 11.0), (22.0, 13.0), 1.7, &c.b.outline);
        // 眼(略高、带高光)+ 眉
        let k = (1.0 - p.blink).max(0.07);
        let eh = 5.0 * k;
        let e1 = (1.0 + p.look * 1.5, -9.0);
        let e2 = (15.0 + p.look * 1.5, -11.0);
        for e in [e1, e2] {
            c.oval(e, 4.6, eh + 0.5, &c.b.outline);
            c.oval(e, 3.7, eh, &c.b.eye);
            // 高光必须**跟着眼皮一起缩**: 否则眨眼时那点白比眼睛还大, 看着像戴墨镜(真踩过)
            c.disc((e.0 + 1.2, e.1 - 1.5 * k), 1.5 * k, &c.b.eye_hi);
        }
        // 眉: 短、细、贴着眼的斜线
        c.line_w((0.0, -14.5), (6.5, -15.6), 1.5, &c.b.fur_shade);
        c.line_w((12.0, -16.2), (18.5, -16.6), 1.5, &c.b.fur_shade);
        // 近侧耳
        ear(c, (10.0, -17.0), 0.30, -p.ear * 0.5, p.alert, false);
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

// ---------------------------------------------------------------- 文字

use windows::Win32::Graphics::DirectWrite::*;

/// DirectWrite 文字: 面板上的工具名要显示中文, 所以走 DWrite 的文本布局。
pub struct Text {
    factory: IDWriteFactory,
    pub normal: IDWriteTextFormat,
    pub bold: IDWriteTextFormat,
    pub small: IDWriteTextFormat,
}

fn fmt(f: &IDWriteFactory, size: f32, weight: DWRITE_FONT_WEIGHT) -> Result<IDWriteTextFormat> {
    unsafe {
        f.CreateTextFormat(
            PCWSTR(wide("Microsoft YaHei UI").as_ptr()),
            None,
            weight,
            DWRITE_FONT_STYLE_NORMAL,
            DWRITE_FONT_STRETCH_NORMAL,
            size,
            PCWSTR(wide("zh-cn").as_ptr()),
        )
    }
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

impl Text {
    pub fn new() -> Result<Self> {
        let factory: IDWriteFactory = unsafe { DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)? };
        Ok(Self {
            normal: fmt(&factory, 14.5, DWRITE_FONT_WEIGHT_NORMAL)?,
            bold: fmt(&factory, 16.0, DWRITE_FONT_WEIGHT_SEMI_BOLD)?,
            small: fmt(&factory, 12.0, DWRITE_FONT_WEIGHT_NORMAL)?,
            factory,
        })
    }

    /// 在 (x,y) 处、给定宽高内画一段文字。`halign` 0=左 1=中 2=右, `valign` 0=上 1=中。
    #[allow(clippy::too_many_arguments)]
    pub unsafe fn draw(
        &self,
        rt: &ID2D1RenderTarget,
        s: &str,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        brush: &ID2D1SolidColorBrush,
        format: &IDWriteTextFormat,
        halign: i32,
        valign: i32,
    ) {
        let u: Vec<u16> = s.encode_utf16().collect();
        let Ok(lay) = self.factory.CreateTextLayout(&u, format, w, h) else {
            return;
        };
        let _ = lay.SetTextAlignment(match halign {
            1 => DWRITE_TEXT_ALIGNMENT_CENTER,
            2 => DWRITE_TEXT_ALIGNMENT_TRAILING,
            _ => DWRITE_TEXT_ALIGNMENT_LEADING,
        });
        let _ = lay.SetParagraphAlignment(if valign == 1 {
            DWRITE_PARAGRAPH_ALIGNMENT_CENTER
        } else {
            DWRITE_PARAGRAPH_ALIGNMENT_NEAR
        });
        rt.DrawTextLayout(D2D_POINT_2F { x, y }, &lay, brush, D2D1_DRAW_TEXT_OPTIONS_NONE);
    }
}
