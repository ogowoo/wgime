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

/// 赤柴: 赤色背毛 + **里白**(吻部/脸颊/胸腹/四肢下段/尾尖), 鼻头与眼圈深色
pub const FUR: D2D1_COLOR_F = rgb(0.878, 0.478, 0.212, 1.0);
/// 里白(urajiro): 柴犬那张"白脸白胸白袜子"就靠它
const URAJIRO: D2D1_COLOR_F = rgb(0.996, 0.980, 0.957, 1.0);
/// 远侧肢体用的里白(略压暗, 制造前后层次)
const URAJIRO_DIM: D2D1_COLOR_F = rgb(0.878, 0.851, 0.827, 1.0);
const FUR_SHADE: D2D1_COLOR_F = rgb(0.702, 0.435, 0.208, 1.0);
/// 描边: 卡通角色有没有这一圈差别很大(浅色/深色背景上都立得住)
const OUTLINE: D2D1_COLOR_F = rgb(0.353, 0.216, 0.114, 1.0);
const EAR_IN: D2D1_COLOR_F = rgb(0.878, 0.639, 0.612, 1.0);
const NOSE: D2D1_COLOR_F = rgb(0.196, 0.157, 0.176, 1.0);
const EYE: D2D1_COLOR_F = rgb(0.106, 0.090, 0.125, 1.0);
/// 张嘴的暗部与舌头: 参考图里"张着嘴笑"是萌点的主力, 只画一条嘴线是不够的
const MOUTH: D2D1_COLOR_F = rgb(0.451, 0.176, 0.196, 1.0);
const TONGUE: D2D1_COLOR_F = rgb(0.933, 0.502, 0.545, 1.0);
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
    pub urajiro: ID2D1SolidColorBrush,
    pub urajiro_dim: ID2D1SolidColorBrush,
    pub fur_shade: ID2D1SolidColorBrush,
    pub outline: ID2D1SolidColorBrush,
    pub ear_in: ID2D1SolidColorBrush,
    pub nose: ID2D1SolidColorBrush,
    pub eye: ID2D1SolidColorBrush,
    pub eye_hi: ID2D1SolidColorBrush,
    pub mouth: ID2D1SolidColorBrush,
    pub tongue: ID2D1SolidColorBrush,
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
            urajiro: mk(URAJIRO)?,
            urajiro_dim: mk(URAJIRO_DIM)?,
            fur_shade: mk(FUR_SHADE)?,
            outline: mk(OUTLINE)?,
            ear_in: mk(EAR_IN)?,
            nose: mk(NOSE)?,
            eye: mk(EYE)?,
            eye_hi: mk(EYE_HI)?,
            mouth: mk(MOUTH)?,
            tongue: mk(TONGUE)?,
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
/// 狗头/耳/身体的形状是**固定**的, 变的是位置和角度 —— 所以只建一次。
pub struct Shapes {
    pub head: ID2D1PathGeometry,
    pub ear: ID2D1PathGeometry,
    pub body: ID2D1PathGeometry,
}

fn bez(p1: Pt, p2: Pt, p3: Pt) -> D2D1_BEZIER_SEGMENT {
    D2D1_BEZIER_SEGMENT {
        point1: pt(p1),
        point2: pt(p2),
        point3: pt(p3),
    }
}

/// 柴犬头侧面轮廓(朝右, 原点=头中心): **圆颅骨 + 明显额段(停) + 短而钝的楔形吻**。
/// 之前那版吻部又长又尖(吻尖到 27.5 而颅骨又小), 读起来像狐狸/食蚁兽 —— 用户原话"头很诡异"。
fn build_head(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((-16.0, -16.0)), D2D1_FIGURE_BEGIN_FILLED);
        // 颅顶(高而圆)
        s.AddBezier(&bez((1.0, -34.0), (11.0, -35.0), (16.0, -23.0)));
        // 额段(停) + 吻上缘: 吻部占头长三分之一强 ——
        // 太短像小熊/猫, 太长像狐狸(两个方向都试过), 这一段是"像狗"的甜点区
        s.AddBezier(&bez((21.0, -16.0), (27.0, -8.0), (32.0, -2.0)));
        // 吻尖
        s.AddBezier(&bez((34.0, 0.0), (34.0, 2.0), (32.5, 4.5)));
        // 上唇 -> 下颚
        s.AddBezier(&bez((30.0, 8.0), (24.0, 10.5), (16.0, 10.5)));
        s.AddBezier(&bez((6.0, 10.5), (0.0, 9.0), (-6.0, 6.0)));
        // 喉/颈回到起点
        s.AddBezier(&bez((-11.0, 1.0), (-17.0, -7.0), (-16.0, -16.0)));
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

/// 柴犬躯干侧面轮廓(朝右, 原点=脚底中心, y 向上为负):
/// **背线平直 + 胸深 + 腰收紧(tuck-up) + 后躯圆**。
/// 之前是一个大椭圆("面包"), 侧面看既没背线也没腰, 读不出品种 —— 用户原话"身体不像"。
fn build_body(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        // 肩隆(背线前端)
        s.BeginFigure(pt((33.0, -84.0)), D2D1_FIGURE_BEGIN_FILLED);
        // 背线: 几乎水平(柴犬的背线是平的)
        s.AddBezier(&bez((-8.0, -87.0), (-24.0, -86.0), (-34.0, -80.0)));
        // 臀 -> 后躯
        s.AddBezier(&bez((-46.0, -74.0), (-50.0, -63.0), (-50.0, -50.0)));
        // 后躯 -> 后腿根
        s.AddBezier(&bez((-50.0, -38.0), (-44.0, -30.0), (-34.0, -30.0)));
        // 腹线: 向后**收紧**(tuck-up)
        s.AddBezier(&bez((-18.0, -34.0), (-4.0, -35.0), (8.0, -32.0)));
        // 深胸(最低点在前胸)
        s.AddBezier(&bez((20.0, -29.0), (28.0, -25.0), (30.0, -23.0)));
        // 前胸上缘
        s.AddBezier(&bez((36.0, -28.0), (38.0, -46.0), (37.0, -60.0)));
        // 回到肩隆
        s.AddBezier(&bez((37.0, -72.0), (35.0, -80.0), (33.0, -84.0)));
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
            body: build_body(f)?,
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

/// 一条腿: 髋/肩 → 膝/肘 → 爪, 带描边。
/// **大腿赤色、小腿以下里白** —— 柴犬的"白袜子"就是这么来的。
unsafe fn leg(c: &Ctx, s: Pt, f: Pt, bend: f32, w: f32, far: bool) {
    // 骨长只比髋脚距离略长 => 膝盖只轻微外凸; 太长会变成"Λ"形
    let k = ik(s, f, 21.5, 21.5, bend);
    let upper = if far { &c.b.fur_shade } else { &c.b.fur };
    let lower = if far { &c.b.urajiro_dim } else { &c.b.urajiro };
    c.limb(s, k, w + 3.0, &c.b.outline);
    c.limb(k, f, w * 0.86 + 2.8, &c.b.outline);
    c.limb(s, k, w, upper);
    c.limb(k, f, w * 0.86, lower);
    // 爪
    c.oval((f.0 + 1.5, f.1), w * 0.86, w * 0.6, &c.b.outline);
    c.oval((f.0 + 1.5, f.1), w * 0.7, w * 0.47, lower);
}

/// 尾巴: **柴犬的卷尾**(背在背上那一卷) —— 沿一圈螺旋生成脊柱, 再算左右轮廓闭合填充。
/// 柴犬的尾巴是最好认的特征: 粗、卷、尾尖白。之前那版是"沿背斜着翘起来的羽状尾", 读起来不像柴。
unsafe fn tail(c: &Ctx, base_y: f32, wag: f32, alert: f32, up: f32) {
    use std::f32::consts::PI;
    const N: usize = 10;
    // 卷心抬到背上方; **圈半径必须明显大于尾巴的粗细**, 否则圈被填死、看起来只是"背上一坨"
    // (真踩过: r=15.5 配半宽 11.4 => 内孔半径只剩 4, 整条尾巴糊成一个横香肠)
    let cx = -26.0 + wag * 1.5;
    let cy = base_y - 30.0 - alert * 3.0 * up + wag * 1.2;
    let mut spine = [(0.0f32, 0.0f32); N + 1];
    for (i, p) in spine.iter_mut().enumerate() {
        let t = i as f32 / N as f32;
        let a = 3.50 - t * 4.6 + wag * 0.16;
        let r = 17.0 - t * 2.0;
        *p = (cx + r * a.cos(), cy - r * a.sin());
    }
    let mut left = [(0.0f32, 0.0f32); N + 1];
    let mut right = [(0.0f32, 0.0f32); N + 1];
    for i in 0..=N {
        let t = i as f32 / N as f32;
        // 中段最蓬松(柴犬尾很厚), 尖端收
        let w = 5.0 + 3.6 * (t * PI * 0.95).sin();
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
    sink.AddLine(pt((spine[N].0 + ex / el * 6.0, spine[N].1 + ey / el * 6.0)));
    for p in right.iter().rev() {
        sink.AddLine(pt(*p));
    }
    sink.EndFigure(D2D1_FIGURE_END_CLOSED);
    if sink.Close().is_err() {
        return;
    }
    let _ = c.rt.FillGeometry(&geo, &c.b.fur, None);
    let _ = c.rt.DrawGeometry(&geo, &c.b.outline, 2.4, None);
    // 尾尖那撮白毛(柴犬的里白一直白到尾巴尖)
    c.disc(spine[N], 5.0, &c.b.urajiro);
}

/// 耳: 三角立耳。`tilt` 是相对头顶的外倾角, `alert` 时立得更直。
/// 老写法是两个圆椭圆耷在头顶, 读起来像发髻 —— 用户原话"耳朵位置有点诡异"。
unsafe fn ear(c: &Ctx, base: Pt, tilt: f32, swing: f32, alert: f32, far: bool) {
    // 整体缩小到 0.82: 柴犬的耳朵相对头是小的; 原来的三角比半个头还高, 看着像纸片贴上去
    let sy = (if far { 0.88 } else { 1.0 }) * (1.0 - alert * 0.16) * 0.82;
    let sx = (if far { 0.9 } else { 1.0 }) * 0.86;
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

    // ---- 尾巴: 卷在背上
    tail(c, body_y, (p.tail * std::f32::consts::TAU).sin(), p.alert, up);

    // ---- 身体: 用**轮廓路径**(背线平直 + 深胸 + 收腰), 不是一个大椭圆
    c.rot_at(body_rot, (0.0, body_y), |c| {
        // 路径是按"身体中心在 y=-58"画的, 所以这里整体抬到 body_y
        let dy = body_y + 58.0;
        c.place(
            &c.shapes.body,
            (0.0, dy),
            0.0,
            1.0,
            0.84 + 0.16 * up,
            Some(&c.b.fur),
            2.6,
        );
        // 背脊高光: 贴着背线的一道浅色
        c.oval((-6.0, body_y - 26.0), 28.0, 3.6, &c.b.fur_shade);
        // 里白: 胸口一坨 + 腹线一条 —— 侧面看赤色要占主体, 别铺满下半身
        c.oval((26.0, body_y + 22.0), 12.0, 13.0, &c.b.urajiro);
        c.oval((2.0, body_y + 26.0), 22.0, 5.5, &c.b.urajiro);
    });

    // ---- 挎包(骑在身体上)
    c.rot_at(body_rot, (0.0, body_y), |c| {
        satchel(c, -7.0, body_y + 6.0, p.bob, 3);
    });

    // ---- 近侧两条腿(比之前粗一点: 柴犬是壮实的小型犬, 不是细腿)
    let (nf, nr) = feet(p, 0.0, 36.0, -26.0);
    leg(c, (32.0, body_y + 18.0), (nf.0, nf.1), -1.0, 9.6, false);
    leg(c, (-22.0, body_y + 20.0), (nr.0, nr.1), 1.0, 10.4, false);

    // ---- 脖子: 粗(柴犬有厚颈毛), 把身体和头连起来(不描边, 否则肩上会多一道深色圆弧)
    // 但**别太粗太高**: 一大坨会把头托成"长在粗柄上"
    let neck = (36.0, body_y - 24.0);
    c.rot_at(0.42, neck, |c| {
        c.oval(neck, 13.0, 12.0, &c.b.fur);
        // 项圈(参考图里那条深色皮带): 做得**细一点** —— 6.8 单位宽时在屏幕上就是一条黑围巾,
        // 和头的轮廓糊在一起(按真实大小看才发现的)
        let _ = c
            .rt
            .FillRoundedRectangle(&rr(neck.0 - 13.0, neck.1 + 1.0, 26.0, 4.4, 2.2, 2.2), &c.b.bag_dark);
        c.disc((neck.0 - 3.0, neck.1 + 9.0), 3.0, &c.b.outline);
        c.disc((neck.0 - 3.0, neck.1 + 9.0), 2.2, &c.b.metal);
    });

    // ---- 头: 用**一条狗头侧面轮廓**(颅顶圆 → 前伸吻部 → 下巴)而不是两个椭圆拼。
    // 两个椭圆拼出来的是"圆头 + 奶油色大椭圆", 读起来像海豹/水獭 —— 这才是"狗头不像狗"的真原因。
    // 头中心比背线只高一点点(约 10 单位): 抬太高就成了"脖子很长的怪东西"
    let hx = 45.0 + p.look * 5.0 + (1.0 - up) * -14.0;
    let hy = body_y - 36.0 - up * 3.0 + (1.0 - up) * 10.0;
    c.at((hx, hy), body_rot * 0.7 + p.look * 0.06, |c| {
        // 远侧耳(长在**颅顶**上、靠近彼此; 之前两耳拉得太开, 像贴在头两侧的纸片)
        ear(c, (-9.0, -17.0), -0.18, p.ear * 0.5, p.alert, true);
        // 头
        c.place(&c.shapes.head, (0.0, 0.0), 0.0, 1.0, 1.0, Some(&c.b.fur), 2.6);
        // 里白: **大面罩**(参考图的萌点之一) —— 吻+下颊+鼻梁一直连到两眼之间,
        // 赤色只剩头顶/眼周那一圈"帽子"。铺太大成白狗, 铺太小成狐狸, 参考图给的就是这个比例
        c.oval((18.0, 6.0), 15.5, 9.5, &c.b.urajiro);
        c.oval((5.0, -6.0), 5.5, 9.0, &c.b.urajiro);
        // 眉上两个白点(眉斑) —— 位置: ①落在赤毛上 ②比耳根低
        c.oval((-5.0, -13.0), 3.7, 2.9, &c.b.urajiro);
        c.oval((7.0, -16.0), 3.5, 2.7, &c.b.urajiro);
        // 张嘴 + 吐舌(参考图里最抓眼的那个表情): 位置在鼻子下方偏后, 舌头略探出下颚
        c.oval((21.5, 6.0), 5.4, 4.2, &c.b.outline);
        c.oval((21.5, 6.0), 4.2, 3.2, &c.b.mouth);
        c.oval((20.5, 9.0), 3.3, 2.5, &c.b.tongue);
        // 鼻头(黑鼻)
        c.oval((31.5, 1.5), 5.0, 4.2, &c.b.outline);
        c.oval((31.5, 1.5), 3.9, 3.1, &c.b.nose);
        // 眼: 大一点、双高光(一大一小) —— 参考图的眼神全靠这个
        let k = (1.0 - p.blink).max(0.07);
        let eh = 5.2 * k;
        for (e, tilt) in [
            ((-2.0 + p.look * 1.5, -9.5), -0.16f32),
            ((11.0 + p.look * 1.5, -11.5), -0.20f32),
        ] {
            c.rot_at(tilt, e, |c| {
                c.oval(e, 4.6, eh + 0.5, &c.b.outline);
                c.oval(e, 3.8, eh * 0.9, &c.b.eye);
            });
            c.disc((e.0 - 0.9, e.1 - 1.6 * k), 1.9 * k, &c.b.eye_hi);
            c.disc((e.0 + 1.3, e.1 + 1.2 * k), 1.0 * k, &c.b.eye_hi);
        }
        // 近侧耳(小三角, 前倾; 两耳靠近)
        ear(c, (2.0, -22.0), 0.26, -p.ear * 0.5, p.alert, false);
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
