//! 角色绘制 V4 —— Q版柴犬正脸/三分之四/侧脸增强版 —— 全部矢量零件, 由 D2D 抗锯齿渲染, 不用位图资源。
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
pub const FUR: D2D1_COLOR_F = rgb(0.957, 0.604, 0.205, 1.0);
/// 里白(urajiro): 柴犬那张"白脸白胸白袜子"就靠它
const URAJIRO: D2D1_COLOR_F = rgb(1.000, 0.957, 0.855, 1.0);
/// 远侧肢体用的里白(略压暗, 制造前后层次)
const URAJIRO_DIM: D2D1_COLOR_F = rgb(0.900, 0.840, 0.750, 1.0);
const FUR_SHADE: D2D1_COLOR_F = rgb(0.900, 0.500, 0.145, 1.0);
/// 赛璐璐光影: 一块平涂的暗面(不渐变), 压在下半身/内侧 —— 动漫插画那味儿
const CEL: D2D1_COLOR_F = rgb(0.890, 0.505, 0.135, 1.0);
/// 描边: 动漫插画那种**粗黑边**(原来是棕色细边, 换近黑后立刻"立"起来)
const OUTLINE: D2D1_COLOR_F = rgb(0.180, 0.105, 0.075, 1.0);
const EAR_IN: D2D1_COLOR_F = rgb(0.925, 0.525, 0.455, 1.0);
const NOSE: D2D1_COLOR_F = rgb(0.105, 0.070, 0.055, 1.0);
const EYE: D2D1_COLOR_F = rgb(0.075, 0.050, 0.040, 1.0);
/// 张嘴的暗部与舌头: 参考图里"张着嘴笑"是萌点的主力, 只画一条嘴线是不够的
const MOUTH: D2D1_COLOR_F = rgb(0.400, 0.105, 0.100, 1.0);
const TONGUE: D2D1_COLOR_F = rgb(0.960, 0.430, 0.470, 1.0);
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
    pub cel: ID2D1SolidColorBrush,
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
            cel: mk(CEL)?,
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
    /// 抬前爪 0..1(投篮/挥手用): 近侧前腿抬起来
    pub arm: f32,
    /// 坐姿 0..1: 屁股着地、后腿折在身子底下、身体略微后仰
    pub sit: f32,
    /// 前趴(玩耍/伸懒腰)0..1: 前身压低、屁股翘起
    pub bow: f32,
    /// 低头 0..1(闻地面/鞠躬): 头往地面压
    pub head_drop: f32,
    /// 歪头(弧度, 正负=左右)
    pub head_tilt: f32,
    /// 打哈欠 0..1: 嘴张到最大、舌头伸出来
    pub yawn: f32,
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
            arm: 0.0,
            sit: 0.0,
            bow: 0.0,
            head_drop: 0.0,
            head_tilt: 0.0,
            yawn: 0.0,
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

        // V4：不再追求“长吻侧脸”，而是把柴犬脸做成圆润的包子脸。
        // 鼻口区域短、宽、钝，这样 face 镜像后仍然能读成正脸/三分之四脸。
        s.BeginFigure(pt((-20.5, -12.0)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((-21.0, -25.0), (-11.0, -36.5), (1.0, -38.0)));
        s.AddBezier(&bez((14.0, -38.5), (23.5, -31.0), (26.5, -20.5)));
        s.AddBezier(&bez((28.5, -14.0), (28.5, -8.0), (29.5, -3.0)));
        // 短圆吻：比 V3 再收 2~3px，避免狐狸感。
        s.AddBezier(&bez((30.5, -0.5), (30.0, 3.5), (26.5, 5.5)));
        s.AddBezier(&bez((23.0, 9.5), (16.0, 12.5), (8.0, 12.5)));
        s.AddBezier(&bez((-1.5, 12.5), (-10.5, 9.5), (-16.5, 4.0)));
        s.AddBezier(&bez((-21.0, -0.5), (-22.0, -6.5), (-20.5, -12.0)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

fn build_ear(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;

        // 参考图中的小而厚的圆角三角立耳。
        s.BeginFigure(pt((-8.0, 1.5)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((-8.0, -10.0), (-5.0, -21.0), (0.0, -25.0)));
        s.AddBezier(&bez((5.0, -21.0), (8.0, -10.0), (8.0, 1.5)));
        s.AddBezier(&bez((4.5, 4.0), (-4.5, 4.0), (-8.0, 1.5)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

fn build_body(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;

        // Q版重点：身体比原版更短、更圆、更敦实，胸腹呈软乎乎的桶形。
        s.BeginFigure(pt((31.0, -77.0)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((15.0, -82.0), (-10.0, -82.0), (-27.0, -76.0)));
        s.AddBezier(&bez((-42.0, -71.0), (-46.0, -58.0), (-45.0, -45.0)));
        s.AddBezier(&bez((-44.0, -33.0), (-36.0, -27.0), (-24.0, -27.0)));
        s.AddBezier(&bez((-11.0, -31.0), (1.0, -32.0), (12.0, -29.0)));
        s.AddBezier(&bez((23.0, -26.0), (30.0, -28.0), (32.0, -37.0)));
        s.AddBezier(&bez((35.0, -49.0), (36.0, -66.0), (31.0, -77.0)));
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
    /// 同 `at`, 但额外绕 `at` 缩放 `sc` 倍(Q版的大头就是靠它)
    pub(crate) unsafe fn at_scaled<F: FnOnce(&Self)>(&self, at: Pt, angle: f32, sc: f32, f: F) {
        let mut cur = Matrix3x2::default();
        self.rt.GetTransform(&mut cur);
        let m = Matrix3x2::rotation(angle, at.0, at.1)
            * Matrix3x2 {
                M11: sc,
                M12: 0.0,
                M21: 0.0,
                M22: sc,
                M31: at.0 * (1.0 - sc),
                M32: at.1 * (1.0 - sc),
            }
            * Matrix3x2::translation(at.0, at.1);
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
    let k = ik(s, f, 18.5, 17.5, bend);
    let upper = if far { &c.b.fur_shade } else { &c.b.fur };
    let lower = if far { &c.b.urajiro_dim } else { &c.b.urajiro };

    // 参考图的腿更短、更粗，避免线条腿；脚掌做成圆润的小白爪。
    c.limb(s, k, w + 4.0, &c.b.outline);
    c.limb(k, f, w * 0.90 + 3.2, &c.b.outline);
    c.limb(s, k, w, upper);
    c.limb(k, f, w * 0.90, lower);

    c.oval((f.0 + 1.0, f.1), w * 0.95, w * 0.66, &c.b.outline);
    c.oval((f.0 + 1.0, f.1), w * 0.78, w * 0.52, lower);
}

/// 尾巴: **柴犬的卷尾**(背在背上那一卷) —— 沿一圈螺旋生成脊柱, 再算左右轮廓闭合填充。
/// 柴犬的尾巴是最好认的特征: 粗、卷、尾尖白。之前那版是"沿背斜着翘起来的羽状尾", 读起来不像柴。
unsafe fn tail(c: &Ctx, base_y: f32, wag: f32, alert: f32, up: f32) {
    use std::f32::consts::PI;
    const N: usize = 10;
    // 卷心抬到背上方; **圈半径必须明显大于尾巴的粗细**, 否则圈被填死、看起来只是"背上一坨"
    // (真踩过: r=15.5 配半宽 11.4 => 内孔半径只剩 4, 整条尾巴糊成一个横香肠)
    let cx = -24.0 + wag * 1.1;
    let cy = base_y - 31.0 - alert * 2.5 * up + wag * 1.0;
    let mut spine = [(0.0f32, 0.0f32); N + 1];
    for (i, p) in spine.iter_mut().enumerate() {
        let t = i as f32 / N as f32;
        let a = 3.50 - t * 4.6 + wag * 0.16;
        let r = 16.0 - t * 1.7;
        *p = (cx + r * a.cos(), cy - r * a.sin());
    }
    let mut left = [(0.0f32, 0.0f32); N + 1];
    let mut right = [(0.0f32, 0.0f32); N + 1];
    for i in 0..=N {
        let t = i as f32 / N as f32;
        // 中段最蓬松(柴犬尾很厚), 尖端收
        let w = 5.0 + 3.7 * (t * PI * 0.95).sin();
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
    // 参考图不是纯白尾尖，而是卷尾内侧的一小块奶油色里白。
    let ti = N.saturating_sub(1);
    let tx = spine[ti].0 * 0.82 + spine[N].0 * 0.18;
    let ty = spine[ti].1 * 0.82 + spine[N].1 * 0.18;
    c.disc((tx, ty), 3.8, &c.b.urajiro);
}

/// 耳: 三角立耳。`tilt` 是相对头顶的外倾角, `alert` 时立得更直。
/// 老写法是两个圆椭圆耷在头顶, 读起来像发髻 —— 用户原话"耳朵位置有点诡异"。
unsafe fn ear(c: &Ctx, base: Pt, tilt: f32, swing: f32, alert: f32, far: bool) {
    // 整体缩小到 0.82: 柴犬的耳朵相对头是小的; 原来的三角比半个头还高, 看着像纸片贴上去
    let sy = (if far { 0.88 } else { 1.0 }) * (1.0 - alert * 0.12) * 0.72;
    let sx = (if far { 0.92 } else { 1.0 }) * 0.94;
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
    // V4：仅通过现有 Pose 的 look/face 做轻微转头，不修改宿主 API。
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
    let sit = p.sit.clamp(0.0, 1.0);
    let bow = p.bow.clamp(0.0, 1.0);
    let body_y = -56.0 * up - 15.0 * (1.0 - up) + p.bob + sit * 3.0 - bow * 6.0;
    // 坐姿: 后躯往下坐、前身抬起(负角 = 逆时针 = 前侧抬高) —— 柴犬坐着就是这个斜度
    // 前趴(bow): 正相反, 前身压低、屁股翘起
    let body_rot = p.lean * 0.55 + (1.0 - up) * 0.16 - sit * 0.34 + bow * 0.38;

    // ---- 地面软阴影: 三层递减 alpha + 半径, 核心层是恒定 alpha(探针按合成值断言)
    let sy = 2.0;
    c.oval((-2.0, sy), 50.0, 10.5, &c.b.sh_out);
    c.oval((-2.0, sy), 38.0, 8.0, &c.b.sh_mid);
    let shadow_core_local = (-2.0, sy);
    c.oval(shadow_core_local, 25.0, 5.4, &c.b.sh_core);
    // 采样点挪到 x=+14: 坐姿时后爪正好落在 (-2,2) 那一带, 会把阴影盖成爪子的描边色
    let shadow_sample = (14.0, sy);

    // ---- 远侧两条腿(先画, 显深, 制造前后层次)
    let (ff, fr) = feet(p, 0.5, 28.0, -34.0, 0.0);
    leg(c, (24.0, body_y + 16.0), (ff.0, ff.1), -1.0, 8.0, true);
    leg(c, (-32.0, body_y + 18.0), (fr.0, fr.1), 1.0, 8.8, true);

    // ---- 尾巴: 卷在背上
    tail(c, body_y, (p.tail * std::f32::consts::TAU).sin(), p.alert, up);

    // ---- 身体: 用**轮廓路径**(背线平直 + 深胸 + 收腰), 不是一个大椭圆。
    // V3：身体更短更圆，头脸保持参考图的大头团子比例。
    c.rot_at(body_rot, (0.0, body_y), |c| {
        let dy = body_y + 58.0;
        c.place(
            &c.shapes.body,
            (0.0, dy),
            0.0,
            0.90,
            0.90 * (0.82 + 0.18 * up),
            Some(&c.b.fur),
            3.4,
        );
        // 赛璐璐暗面: 一块平涂压在下半身(动漫插画那味儿, 不渐变)
        c.oval((-5.0, body_y + 13.0), 29.0, 7.0, &c.b.cel);
        // 背脊高光
        c.oval((-7.0, body_y - 20.0), 22.0, 3.0, &c.b.fur_shade);
        // 里白: 胸口一坨 + 腹线一条
        c.oval((22.0, body_y + 18.0), 12.5, 14.0, &c.b.urajiro);
        c.oval((2.0, body_y + 23.0), 20.0, 5.5, &c.b.urajiro);
    });

    // ---- 挎包(骑在身体上)
    c.rot_at(body_rot, (0.0, body_y), |c| {
        satchel(c, -7.0, body_y + 6.0, p.bob, 3);
    });

    // ---- 近侧两条腿(比之前粗一点: 柴犬是壮实的小型犬, 不是细腿)。
    // 坐姿时后腿折到身子底下(脚往前收 + 微微离地)
    let (nf, nr) = feet(p, 0.0, 36.0, -26.0 + sit * 16.0, p.arm);
    leg(c, (32.0, body_y + 18.0), (nf.0, nf.1), -1.0, 9.6, false);
    leg(
        c,
        (-22.0, body_y + 20.0),
        (nr.0, nr.1),
        if sit > 0.4 { -0.5 } else { 1.0 },
        10.4,
        false,
    );

    // ---- 脖子: 粗(柴犬有厚颈毛), 把身体和头连起来(不描边, 否则肩上会多一道深色圆弧)
    let neck = (30.0, body_y - 15.0);
    c.rot_at(0.42, neck, |c| {
        c.oval(neck, 17.0, 16.0, &c.b.fur);
        // 项圈(深棕) + **银色圆环吊坠**(用户要的那个环)
        let _ = c.rt.FillRoundedRectangle(
            &rr(neck.0 - 14.0, neck.1 + 1.0, 28.0, 5.2, 2.6, 2.6),
            &c.b.outline,
        );
        let _ = c.rt.FillRoundedRectangle(
            &rr(neck.0 - 13.0, neck.1 + 2.0, 26.0, 3.2, 1.6, 1.6),
            &c.b.bag_dark,
        );
        c.oval((neck.0 - 3.0, neck.1 + 10.0), 3.6, 3.6, &c.b.outline);
        c.oval((neck.0 - 3.0, neck.1 + 10.0), 2.6, 2.6, &c.b.metal);
        c.oval((neck.0 - 3.0, neck.1 + 10.0), 1.3, 1.3, &c.b.outline);
    });

    // ---- 头：V4 Q版“包子脸”
    // p.look 不再只是让眼睛平移，而是模拟轻微转头：
    //   look≈0  -> 三分之四/正面感最强
    //   |look|大 -> 更明显的侧向关注
    // 这样不需要改 Pose/状态机，现有动画全部兼容。
    let look = p.look.clamp(-1.0, 1.0);
    let yaw = look * 0.10;
    let hx = 38.5 + look * 3.8 + (1.0 - up) * -11.0;
    let hy = body_y - 31.5 - up * 3.0 + (1.0 - up) * 9.0 + p.head_drop * 26.0;
    let head_sx = 1.58 * (1.0 - look.abs() * 0.035);
    let head_sy = 1.58;

    c.at_scaled((hx, hy), body_rot * 0.65 + yaw + p.head_tilt, 1.0, |c| {
        // 远耳：向头顶中心收，避免“耳朵长在脸两边”。
        ear(c, (-9.0 + look * 1.2, -18.5), -0.10 - look * 0.04, p.ear * 0.30, p.alert, true);

        // 头本体。x/y 分开缩放，保持大头但不把脸拉成长椭圆。
        c.place(&c.shapes.head, (0.0, 0.0), 0.0, head_sx, head_sy, Some(&c.b.fur), 2.7);

        // V4：里白改成更“蝴蝶结/心形”的包子脸结构。
        // 中央白面负责正脸识别，两侧脸颊负责 Q 版圆润感。
        c.oval((13.0 + look * 1.5, 5.0), 15.0, 10.5, &c.b.urajiro);
        c.oval((3.0 + look * 0.5, -4.0), 8.0, 11.5, &c.b.urajiro);
        c.oval((-7.5, 1.0), 7.8, 7.2, &c.b.urajiro);
        c.oval((8.5, 1.0), 8.3, 7.5, &c.b.urajiro);

        // 柴犬眉斑：稍微靠内，正面看更对称。
        c.oval((-6.0 + look * 0.4, -13.0), 3.7, 2.8, &c.b.urajiro);
        c.oval((6.5 + look * 0.6, -13.2), 3.7, 2.8, &c.b.urajiro);

        // 眼睛：V4 采用“近眼略大、远眼略小”的三分之四错觉。
        let k = (1.0 - p.blink).max(0.07);
        let eh = 5.9 * k;
        let near_scale = 1.0 + look.abs() * 0.08;
        let far_scale = 1.0 - look.abs() * 0.10;
        let eyes = [
            ((-4.8 + look * 1.15, -9.0), -0.08f32, far_scale),
            ((8.4 + look * 1.25, -10.0), -0.08f32, near_scale),
        ];
        for (e, tilt, es) in eyes {
            c.rot_at(tilt, e, |c| {
                c.oval(e, 4.7 * es, eh + 0.55, &c.b.outline);
                c.oval(e, 3.85 * es, eh * 0.9, &c.b.eye);
            });
            c.disc((e.0 - 0.9, e.1 - 1.6 * k), 1.9 * k * es, &c.b.eye_hi);
            c.disc((e.0 + 1.25, e.1 + 1.15 * k), 0.95 * k * es, &c.b.eye_hi);
        }

        // 鼻子往脸中心收，形成“柴犬正脸”的圆鼻，而不是狐狸尖鼻。
        let nose_x = 24.0 + look * 3.2;
        let nose_y = 1.0 + look.abs() * 0.5;
        c.oval((nose_x, nose_y), 4.5, 3.7, &c.b.outline);
        c.oval((nose_x, nose_y), 3.45, 2.75, &c.b.nose);
        c.disc((nose_x - 1.0, nose_y - 0.9), 0.72, &c.b.eye_hi);

        // 嘴：短短的倒Y型，配一点小舌头，避免 V3 的“长嘴线”。
        // 打哈欠(yawn)时把嘴和舌头摊大、舌头伸下来
        let yz = p.yawn.clamp(0.0, 1.0);
        c.line_w((nose_x, nose_y + 2.4), (nose_x - 1.5, nose_y + 5.8), 1.8, &c.b.mouth);
        c.line_w((nose_x - 1.5, nose_y + 5.8), (nose_x - 5.0, nose_y + 5.2), 1.7, &c.b.mouth);
        c.line_w((nose_x - 1.5, nose_y + 5.8), (nose_x + 2.0, nose_y + 5.1), 1.7, &c.b.mouth);
        c.oval(
            (nose_x - 0.5, nose_y + 7.2 + yz * 1.4),
            2.6 + yz * 2.4,
            2.0 + yz * 2.6,
            &c.b.outline,
        );
        c.oval(
            (nose_x - 0.5, nose_y + 7.8 + yz * 2.6),
            2.0 + yz * 1.8,
            1.5 + yz * 3.0,
            &c.b.tongue,
        );

        // 近侧耳：更靠中、更短、更厚，贴着圆头生长。
        ear(c, (0.5 + look * 0.9, -22.0), 0.19 + look * 0.05, -p.ear * 0.34, p.alert, false);
    });

    let _ = c.rt.SetTransform(&Matrix3x2::identity());
    // 本体标定点: 必须挑一块**确定的纯背毛**——不能压在奶油色肚皮/挎包/工具/描边上。
    // 而且**要按身体自己的旋转算**(坐姿时身体是斜的): 直接拿没旋过的局部点会落到别处,
    // 实测就落到了黑描边上(读数 (33,25,28) 正是 OUTLINE 色)。
    let body_local = (-40.0, body_y - 8.0);
    let (cs, sn) = (body_rot.cos(), body_rot.sin());
    let (ox, oy) = (body_local.0, body_local.1 - body_y);
    let body_world = (
        ox * cs - oy * sn,
        ox * sn + oy * cs + body_y,
    );
    let w = |l: Pt| (p.x + p.face * s * l.0, p.ground + s * l.1);
    Probe {
        shadow: w(shadow_sample),
        body: w(body_world),
    }
}

// ---------------------------------------------------------------- 场景 1: 投篮

/// 球架: 立柱 + 篮板 + 篮框 + 网; 进球时 `flash`>0 会在框口炸一圈。
/// `x` 是立柱所在竖线, `side` = +1 表示篮板往里侧(左)伸。
pub unsafe fn draw_hoop(c: &Ctx, x: f32, ground: f32, rim_y: f32, side: f32, flash: f32) {
    c.line_w((x, ground), (x, rim_y - 30.0), 8.0, &c.b.outline);
    c.line_w((x, ground), (x, rim_y - 30.0), 5.0, &c.b.metal);
    let bx = x - side * 26.0;                       // 篮板中心
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(bx - 14.0, rim_y - 58.0, 28.0, 58.0, 4.0, 4.0), &c.b.outline);
    let _ = c.rt.FillRoundedRectangle(
        &rr(bx - 12.0, rim_y - 56.0, 24.0, 54.0, 3.0, 3.0),
        &c.b.urajiro,
    );
    // 篮板上的方框
    let _ = c.rt.DrawRectangle(
        &D2D_RECT_F {
            left: bx - 8.0,
            top: rim_y - 32.0,
            right: bx + 8.0,
            bottom: rim_y - 12.0,
        },
        &c.b.bag,
        2.4,
        None,
    );
    // 篮框(往里侧伸的横杆)
    let rx = bx - side * 13.0;
    let w = if flash > 0.0 { 5.4 } else { 4.2 };
    c.line_w((bx, rim_y), (rx, rim_y), w, &c.b.outline);
    c.line_w((bx, rim_y), (rx, rim_y), w - 1.8, &c.b.bag);
    // 网
    for i in 0..4 {
        let k = i as f32 / 3.0;
        let nx = bx + (rx - bx) * k;
        c.line_w(
            (nx, rim_y + 2.0),
            (rx + (bx - rx) * 0.4 + (k - 0.5) * 9.0, rim_y + 24.0),
            1.5,
            &c.b.urajiro,
        );
    }
    if flash > 0.0 {
        for i in 0..2 {
            let r = 12.0 + (1.0 - flash) * 30.0 + i as f32 * 9.0;
            if let Ok(ring) = c.rt.CreateSolidColorBrush(
                &D2D1_COLOR_F {
                    r: 1.0,
                    g: 0.85,
                    b: 0.35,
                    a: flash * 0.65,
                },
                None,
            ) {
                let _ = c.rt.DrawEllipse(&ell(rx, rim_y, r, r * 0.62), &ring, 3.0, None);
            }
        }
    }
}

/// 篮球: 橙色球 + 深色接缝线
pub unsafe fn draw_ball(c: &Ctx, x: f32, y: f32, r: f32, spin: f32) {
    c.oval((x, y), r, r, &c.b.outline);
    c.oval((x, y), r - 1.6, r - 1.6, &c.b.bag);
    c.rot_at(spin, (x, y), |c| {
        c.line_w((x - r, y), (x + r, y), 1.5, &c.b.outline);
        c.line_w((x, y - r), (x, y + r), 1.5, &c.b.outline);
    });
    c.rot_at(spin + 0.9, (x, y), |c| {
        c.line_w(
            (x - r * 0.75, y - r * 0.75),
            (x + r * 0.75, y + r * 0.75),
            1.2,
            &c.b.outline,
        );
    });
}

/// 四只脚的落点。`phase` 决定这一对腿的相位(近侧 0 / 远侧 0.5 = 对角步态)。
/// `arm` > 0 时把近侧**前**脚抬起来(投篮/挥手), 于是 IK 会把腿折起来 —— 不用另画抬腿姿势。
fn feet(p: &Pose, phase: f32, front_x: f32, rear_x: f32, arm: f32) -> (Pt, Pt) {
    let foot = |base_x: f32, ph: f32, lift_extra: f32| -> Pt {
        let th = (p.gait + ph) * std::f32::consts::TAU;
        let swing = th.sin();
        let x = base_x + swing * p.stride * 0.5 + lift_extra * 0.25;
        // 只有向后摆(支撑相)时贴地, 其余抬起
        let lift = if swing < 0.0 { 0.0 } else { p.lift * swing };
        (x, -lift - lift_extra)
    };
    (
        foot(front_x, phase, arm * 58.0),
        foot(rear_x, phase + 0.5, 0.0),
    )
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
