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

/// 零件形状的**真身**(编译期嵌进 DLL, 单文件交付不变)。见 `art/dog.svg` 头部注释与 §D55。
const ART_SVG: &str = include_str!("../art/dog.svg");

// ---------------------------------------------------------------- 配色

const fn rgb(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F {
    D2D1_COLOR_F { r, g, b, a }
}

/// 赤柴: 赤色背毛 + **里白**(吻部/脸颊/胸腹/四肢下段/尾尖), 鼻头与眼圈深色
/// 调色板按用户给的**姿态图**取样定色(第九十轮补五): 背毛 `#eb953c` / 里白 `#fdf2e0` /
/// 描边 `#6b3d1a`(暖棕, **不是**近黑 —— 参考图的线是细暖棕) / 鼻眼 `#0f1111` / 舌 `#f1836c`
pub const FUR: D2D1_COLOR_F = rgb(0.922, 0.584, 0.235, 1.0);
/// 里白(urajiro): 柴犬那张"白脸白胸白袜子"就靠它
const URAJIRO: D2D1_COLOR_F = rgb(0.992, 0.949, 0.878, 1.0);
/// 远侧肢体用的里白(略压暗, 制造前后层次)
const URAJIRO_DIM: D2D1_COLOR_F = rgb(0.937, 0.878, 0.784, 1.0);
const FUR_SHADE: D2D1_COLOR_F = rgb(0.851, 0.502, 0.227, 1.0);
/// 赛璐璐光影: 一块平涂的暗面(不渐变), 压在下半身/内侧 —— 动漫插画那味儿
const CEL: D2D1_COLOR_F = rgb(0.878, 0.533, 0.204, 1.0);
/// 受光面(比背毛更亮更黄)。径向"体积球"的球心色 —— 用户要的"立体一点"全靠它。
const FUR_LIGHT: D2D1_COLOR_F = rgb(0.973, 0.725, 0.420, 1.0);
/// 体积球最外圈的反光暗面(比 CEL 更深, 否则球没有"转过去"的感觉)
const FUR_DEEP: D2D1_COLOR_F = rgb(0.761, 0.416, 0.157, 1.0);
/// 里白的球心(近纯白)
const URAJIRO_LIGHT: D2D1_COLOR_F = rgb(1.000, 0.984, 0.945, 1.0);
/// 描边: 参考图是**暖棕细线**(原来是近黑粗边, 太"记号笔")
const OUTLINE: D2D1_COLOR_F = rgb(0.420, 0.239, 0.102, 1.0);
const EAR_IN: D2D1_COLOR_F = rgb(0.984, 0.820, 0.667, 1.0);
const NOSE: D2D1_COLOR_F = rgb(0.059, 0.067, 0.067, 1.0);
const EYE: D2D1_COLOR_F = rgb(0.059, 0.067, 0.067, 1.0);
/// 张嘴的暗部与舌头: 参考图里"张着嘴笑"是萌点的主力, 只画一条嘴线是不够的
const MOUTH: D2D1_COLOR_F = rgb(0.478, 0.165, 0.125, 1.0);
const TONGUE: D2D1_COLOR_F = rgb(0.945, 0.514, 0.424, 1.0);
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
    /// 背毛受光面(背脊高光/边缘光用)
    pub fur_light: ID2D1SolidColorBrush,
    /// 立体感的主力: 一条**全局光向**的线性渐变(左上受光 → 本体 → 右下暗面)。
    /// 渐变坐标在狗的局部空间里, 所以身体/头/腿/耳共用它就有统一的光向。
    pub fur_grad: ID2D1LinearGradientBrush,
    /// 里白也带一点体积(上白下灰)
    pub urajiro_grad: ID2D1LinearGradientBrush,
    /// **体积球**: 径向渐变(球心偏左上受光 → 边缘压暗)。
    /// 为什么线性渐变不够: 在"圆球"形状上它只拉出一条斜的色带, 读起来还是平的;
    /// 而径向渐变的等值线是圆的, 才有"球面转过去"的效果 —— 用户原话"能做立体一点的吗"。
    /// 单位半径(1.0), 用的时候靠 `Ctx::ball_at` 摆到目标位置并按 rx/ry 缩放。
    pub ball: ID2D1RadialGradientBrush,
    /// 里白的体积球(吻部/胸腹/脸)
    pub ball_white: ID2D1RadialGradientBrush,
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
        // 全局光向: 从左上(-90,-180)打到右下(110,60)。三段: 亮边 → 本体 → 暗面
        let grad = |a: D2D1_COLOR_F, b: D2D1_COLOR_F, c: D2D1_COLOR_F, p0: Pt, p1: Pt| {
            unsafe {
                let stops = [
                    D2D1_GRADIENT_STOP {
                        position: 0.0,
                        color: a,
                    },
                    D2D1_GRADIENT_STOP {
                        position: 0.52,
                        color: b,
                    },
                    D2D1_GRADIENT_STOP {
                        position: 1.0,
                        color: c,
                    },
                ];
                let coll = rt.CreateGradientStopCollection(
                    &stops,
                    D2D1_GAMMA_2_2,
                    D2D1_EXTEND_MODE_CLAMP,
                )?;
                rt.CreateLinearGradientBrush(
                    &D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES {
                        startPoint: D2D_POINT_2F { x: p0.0, y: p0.1 },
                        endPoint: D2D_POINT_2F { x: p1.0, y: p1.1 },
                    },
                    None,
                    &coll,
                )
            }
        };
        // 单位"体积球": 半径 1, 球心在原点; 受光点由 gradientOriginOffset 往左上偏。
        // 四段停靠点让亮面→本体→暗面→反光的过渡更像球形, 而不是两色对半开。
        let ball = |hi: D2D1_COLOR_F, mid: D2D1_COLOR_F, dark: D2D1_COLOR_F, off: Pt| {
            unsafe {
                let stops = [
                    D2D1_GRADIENT_STOP {
                        position: 0.0,
                        color: hi,
                    },
                    D2D1_GRADIENT_STOP {
                        position: 0.42,
                        color: mid,
                    },
                    D2D1_GRADIENT_STOP {
                        position: 0.72,
                        color: mid,
                    },
                    D2D1_GRADIENT_STOP {
                        position: 1.0,
                        color: dark,
                    },
                ];
                let coll = rt.CreateGradientStopCollection(
                    &stops,
                    D2D1_GAMMA_2_2,
                    D2D1_EXTEND_MODE_CLAMP,
                )?;
                rt.CreateRadialGradientBrush(
                    &D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES {
                        center: D2D_POINT_2F { x: 0.0, y: 0.0 },
                        gradientOriginOffset: D2D_POINT_2F { x: off.0, y: off.1 },
                        radiusX: 1.0,
                        radiusY: 1.0,
                    },
                    None,
                    &coll,
                )
            }
        };
        Ok(Self {
            fur: mk(FUR)?,
            fur_light: mk(FUR_LIGHT)?,
            fur_grad: grad(
                FUR_SHADE,
                FUR,
                CEL,
                (-90.0, -180.0),
                (110.0, 60.0),
            )?,
            ball: ball(FUR_LIGHT, FUR, FUR_DEEP, (-0.26, -0.30))?,
            ball_white: ball(URAJIRO_LIGHT, URAJIRO, URAJIRO_DIM, (-0.22, -0.28))?,
            urajiro_grad: grad(
                URAJIRO,
                URAJIRO,
                URAJIRO_DIM,
                (-70.0, -170.0),
                (80.0, 30.0),
            )?,
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
    /// 挎包 0..1: 只有场景 2(百宝袋)需要它。参考图里的柴犬**不背包** ——
    /// 背包会把整个身体挡住, 读起来就是"一个头 + 一个包"(用户原话"什么都不像")
    pub bag: f32,
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
            bag: 0.0,
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
    /// **白脸罩**(里白): 颊 + 眼周, 顶上留一道橙 V —— 柴犬的脸就靠它
    pub mask: ID2D1PathGeometry,
    /// 嘴线(只描边, 不填充)
    pub mouth: ID2D1PathGeometry,
    /// 吻部的鼻梁线(只描边)
    pub bridge: ID2D1PathGeometry,
}

fn bez(p1: Pt, p2: Pt, p3: Pt) -> D2D1_BEZIER_SEGMENT {
    D2D1_BEZIER_SEGMENT {
        point1: pt(p1),
        point2: pt(p2),
        point3: pt(p3),
    }
}

/// 柴犬头(朝右, 原点=头中心): **圆颅骨 + 前下方伸出一小段短吻**, 一个闭合轮廓。
/// 姿态图里的头是"大而圆 + 吻很短", 五官都摆在这个轮廓的中前部。
fn build_head(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((-15.0, -12.0)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((-14.0, -24.5), (-4.0, -29.5), (7.0, -27.0)));
        s.AddBezier(&bez((16.5, -24.5), (21.5, -18.0), (23.0, -9.5)));
        s.AddBezier(&bez((24.5, -3.0), (27.5, 0.0), (31.0, 1.5)));
        s.AddBezier(&bez((34.5, 3.2), (34.0, 7.5), (30.0, 9.0)));
        s.AddBezier(&bez((25.5, 10.6), (20.0, 10.4), (15.5, 9.2)));
        s.AddBezier(&bez((9.5, 12.0), (1.0, 13.4), (-5.5, 12.2)));
        s.AddBezier(&bez((-11.5, 11.0), (-15.0, 6.0), (-15.2, 0.0)));
        s.AddBezier(&bez((-15.4, -4.5), (-15.2, -8.5), (-15.0, -12.0)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

/// **白脸罩**(里白): 颊 + 眼周 + 吻, 顶上是一道"人字"橙 V(额头那道橙毛).
/// 姿态图的脸就是这个结构: 橙色的额 V 从两眼之间下来, 其余下半张脸都是里白。
fn build_mask(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((-13.0, 8.5)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((-6.0, 12.0), (3.0, 12.5), (9.5, 10.5)));
        s.AddBezier(&bez((15.0, 8.6), (21.0, 6.0), (24.5, 2.5)));
        s.AddBezier(&bez((26.0, 0.5), (25.5, -3.0), (23.5, -6.5)));
        s.AddBezier(&bez((21.5, -11.0), (19.0, -16.0), (14.0, -18.0)));
        s.AddBezier(&bez((10.0, -19.5), (6.0, -19.5), (3.5, -17.5)));
        // V 字凹口: 额头那道橙毛从这儿下来(窄而浅 —— 太深会把白脸劈成两半)
        s.AddBezier(&bez((2.5, -16.0), (1.5, -16.0), (0.0, -17.5)));
        s.AddBezier(&bez((-2.0, -19.5), (-6.0, -19.5), (-9.5, -18.0)));
        s.AddBezier(&bez((-13.0, -16.5), (-15.5, -11.0), (-15.5, -5.0)));
        s.AddBezier(&bez((-15.5, 1.0), (-14.5, 5.5), (-13.0, 8.5)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

fn build_ear(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;

        // 姿态图里的厚三角立耳(底宽 ≈ 高度的 0.8, 尖端略圆)。
        s.BeginFigure(pt((-9.5, 2.5)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((-10.0, -7.5), (-6.5, -15.5), (0.0, -19.5)));
        s.AddBezier(&bez((6.5, -15.5), (10.0, -7.5), (9.5, 2.5)));
        s.AddBezier(&bez((5.0, 5.2), (-5.0, 5.2), (-9.5, 2.5)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

/// 吻部的**鼻梁线**(只描边): 从鼻根往后上方回到眼睛下方。
/// 为什么不描吻部整条轮廓: 闭合的圆角矩形轮廓 = 脸上糊了一张"白方框"(用户看到的"不像"之一),
/// 卡通狗只画这条鼻梁线 + 嘴, 吻部其余边缘靠里白色自己交代。
fn build_bridge(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((27.0, -0.4)), D2D1_FIGURE_BEGIN_HOLLOW);
        s.AddBezier(&bez((23.0, -3.4), (17.0, -5.0), (11.0, -4.6)));
        s.EndFigure(D2D1_FIGURE_END_OPEN);
        s.Close()?;
        Ok(g)
    }
}

/// 嘴: **张开的笑口**(填充的月牙 + 里面的舌头)。
/// 一条细嘴线读不出"笑" —— 参考图里那个萌点就是张着嘴。单独一条路径才能填充+描边。
fn build_mouth(f: &ID2D1Factory) -> Result<ID2D1PathGeometry> {
    unsafe {
        let g = f.CreatePathGeometry()?;
        let s = g.Open()?;
        s.BeginFigure(pt((26.0, 3.6)), D2D1_FIGURE_BEGIN_FILLED);
        // 下缘(从鼻根往后下方兜出去)
        s.AddBezier(&bez((25.5, 6.6), (23.0, 8.8), (20.0, 8.6)));
        s.AddBezier(&bez((18.0, 8.4), (16.5, 7.2), (16.1, 5.4)));
        // 上缘(贴着吻部回去)
        s.AddBezier(&bez((19.1, 5.6), (23.0, 4.9), (26.0, 3.6)));
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
        // **长度是 Q 版的关键**: 原来 -46..36 (82 单位) 是"腊肠犬", 大头必须配短身子。
        // 这里 x 全体按 0.88 向中心压缩(以 -5 为轴), y 不变 —— 长度降到 72, 头身比才立得住。
        s.BeginFigure(pt((26.7, -77.0)), D2D1_FIGURE_BEGIN_FILLED);
        s.AddBezier(&bez((12.6, -82.0), (-9.4, -82.0), (-24.4, -76.0)));
        s.AddBezier(&bez((-37.6, -71.0), (-41.1, -58.0), (-40.2, -45.0)));
        s.AddBezier(&bez((-39.3, -33.0), (-32.3, -27.0), (-21.7, -27.0)));
        s.AddBezier(&bez((-10.3, -31.0), (0.3, -32.0), (10.0, -29.0)));
        s.AddBezier(&bez((19.6, -26.0), (25.8, -28.0), (27.6, -37.0)));
        s.AddBezier(&bez((30.2, -49.0), (31.1, -66.0), (26.7, -77.0)));
        s.EndFigure(D2D1_FIGURE_END_CLOSED);
        s.Close()?;
        Ok(g)
    }
}

impl Shapes {
    pub fn new(f: &ID2D1Factory) -> Result<Self> {
        // 零件形状的**真身**在 `art/dog.svg`(编译期嵌进 DLL); 下面这些 `build_*` 是**兜底**:
        // SVG 缺 id / d 解析不动 / D2D 报错时才用它们 —— 所以它们不能删(改了 SVG 也别删)。
        // 每次启动都比一次两边的包围盒, 把差值写进初始化日志: 它抓不出"改丑了"(那是你的自由),
        // 但能立刻抓出"解析失败、悄悄退回内置路径、看着像没生效"。
        let svg = crate::svgpath::SvgPaths::parse(ART_SVG);
        let mut used = 0usize;
        let mut notes: Vec<String> = Vec::new();
        let mut pick =
            |id: &str, fb: fn(&ID2D1Factory) -> Result<ID2D1PathGeometry>| -> Result<ID2D1PathGeometry> {
                let builtin = fb(f)?;
                match svg.build(f, id) {
                    Ok(g) => {
                        used += 1;
                        if let (Ok(a), Ok(b)) = (bounds(&g), bounds(&builtin)) {
                            let d = (a.0 - b.0)
                                .abs()
                                .max((a.1 - b.1).abs())
                                .max((a.2 - b.2).abs())
                                .max((a.3 - b.3).abs());
                            if d > 0.01 {
                                notes.push(format!("{id} 差{d:.2}"));
                            }
                        }
                        Ok(g)
                    }
                    Err(e) => {
                        notes.push(format!("{id} 退回内置({e})"));
                        Ok(builtin)
                    }
                }
            };
        let s = Self {
            head: pick("head", build_head)?,
            ear: pick("ear", build_ear)?,
            body: pick("body", build_body)?,
            mask: pick("mask", build_mask)?,
            mouth: pick("mouth", build_mouth)?,
            bridge: pick("bridge", build_bridge)?,
        };
        crate::dbg(format!(
            "art: svg 用了 {}/{} 个零件 [{}]{}, 与内置路径的包围盒差: {}",
            used,
            svg.len(),
            svg.ids().join(" "),
            if notes.is_empty() { "" } else { " (有偏差)" },
            if notes.is_empty() {
                "0(逐件一致)".to_string()
            } else {
                notes.join(", ")
            }
        ));
        Ok(s)
    }
}

/// 路径包围盒 (left, top, right, bottom) —— 只给上面那行自检日志用
fn bounds(g: &ID2D1PathGeometry) -> Result<(f32, f32, f32, f32)> {
    unsafe {
        let r = g.GetBounds(None)?;
        Ok((r.left, r.top, r.right, r.bottom))
    }
}

impl<'a> Ctx<'a> {
    pub(crate) unsafe fn limb(&self, a: Pt, c: Pt, w: f32, brush: &ID2D1Brush) {
        let _ = self.rt.DrawLine(pt(a), pt(c), brush, w, Some(self.stroke));
    }
    pub(crate) unsafe fn disc(&self, p: Pt, r: f32, brush: &ID2D1Brush) {
        let _ = self.rt.FillEllipse(&ell(p.0, p.1, r, r), brush);
    }
    pub(crate) unsafe fn oval(&self, p: Pt, rx: f32, ry: f32, brush: &ID2D1Brush) {
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
        fill: Option<&ID2D1Brush>,
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
    /// 把"单位体积球"刷摆到局部坐标 `center` 并按 `rx/ry` 缩放, 在 `f` 里用它填形状。
    /// 刷的变换与渲染目标变换**各自独立**(刷的坐标空间就是画几何时用的那个空间),
    /// 所以 `ball_at` 的 center/rx/ry 一律用**画该形状时的局部坐标**, 不用管外层怎么平移。
    /// 画完还原刷的变换 —— 否则下一次用同一个球刷会继承上次的位置。
    pub(crate) unsafe fn ball_at<F: FnOnce(&Self)>(
        &self,
        b: &ID2D1RadialGradientBrush,
        center: Pt,
        rx: f32,
        ry: f32,
        f: F,
    ) {
        let mut prev = Matrix3x2::default();
        b.GetTransform(&mut prev);
        // 单位球 → 目标: 先按 (rx,ry) 缩放, 再平移到 center(M31/M32 就是平移项)
        let _ = b.SetTransform(&Matrix3x2 {
            M11: rx,
            M12: 0.0,
            M21: 0.0,
            M22: ry,
            M31: center.0,
            M32: center.1,
        });
        f(self);
        let _ = b.SetTransform(&prev);
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
    let upper: &ID2D1Brush = if far { &c.b.fur_shade } else { &c.b.fur_grad };
    let lower = if far { &c.b.urajiro_dim } else { &c.b.urajiro };

    // 大腿根一坨: 腿是**从身体里长出来**的, 不是接在身上的一根管子
    c.oval((s.0, s.1 + 1.5), w * 0.88, w * 1.10, upper);

    // 参考图的腿更短、更粗，避免线条腿；脚掌做成圆润的小白爪。
    // 描边收细(参考图是细而均匀的线): 原来 +4.0/+3.2 像记号笔
    c.limb(s, k, w + 2.4, &c.b.outline);
    c.limb(k, f, w * 0.90 + 1.9, &c.b.outline);
    c.limb(s, k, w, upper);
    c.limb(k, f, w * 0.90, lower);

    c.oval((f.0 + 1.0, f.1), w * 0.80, w * 0.56, &c.b.outline);
    c.oval((f.0 + 1.0, f.1), w * 0.64, w * 0.43, lower);
}

/// 尾巴: **柴犬的卷尾**(背在背上那一卷) —— 沿一圈螺旋生成脊柱, 再算左右轮廓闭合填充。
/// 柴犬的尾巴是最好认的特征: 粗、卷、尾尖白。之前那版是"沿背斜着翘起来的羽状尾", 读起来不像柴。
unsafe fn tail(c: &Ctx, base_y: f32, wag: f32, alert: f32, up: f32) {
    use std::f32::consts::PI;
    const N: usize = 10;
    // 卷心抬到背上方; **圈半径必须明显大于尾巴的粗细**, 否则圈被填死、看起来只是"背上一坨"
    // (真踩过: r=15.5 配半宽 11.4 => 内孔半径只剩 4, 整条尾巴糊成一个横香肠)
    let cx = -21.0 + wag * 1.1;
    let cy = base_y - 29.0 - alert * 2.5 * up + wag * 1.0;
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
        // 中段最蓬松(参考图里那条尾巴又粗又蓬, 快赶上身子了)
        let w = 10.8 + 4.0 * (t * PI * 0.95).sin();
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
    let _ = c.rt.DrawGeometry(&geo, &c.b.outline, 1.7, None);
    // 参考图不是纯白尾尖，而是卷尾内侧的一小块奶油色里白。
    let ti = N.saturating_sub(1);
    let tx = spine[ti].0 * 0.82 + spine[N].0 * 0.18;
    let ty = spine[ti].1 * 0.82 + spine[N].1 * 0.18;
    c.disc((tx, ty), 3.8, &c.b.urajiro);
}

/// 耳: 三角立耳。`tilt` 是相对头顶的外倾角, `alert` 时立得更直。
/// 老写法是两个圆椭圆耷在头顶, 读起来像发髻 —— 用户原话"耳朵位置有点诡异"。
unsafe fn ear(c: &Ctx, base: Pt, tilt: f32, swing: f32, alert: f32, far: bool) {
    // **耳朵的总高度必须是头的 1/3 上下**: 这里的几何高 21.5, 配 0.95 缩放 ≈ 20; 耳根坐在颅顶
    // (头轮廓的顶在 -26 左右, 所以耳根给 -20 上下, 下半截埋在头里 —— 真踩过: 耳根给太低
    // 整只耳朵被头盖住, 画面上只剩一个尖)。
    let sy = (if far { 0.92 } else { 1.0 }) * (1.0 - alert * 0.12) * 1.12;
    let sx = (if far { 0.95 } else { 1.0 }) * 1.02;
    let ang = tilt + swing - alert * tilt * 0.45;
    // 耳的填充**不用体积球**: 球刷的坐标在"画几何的那个空间"里, 而耳是在头的 `at_scaled`
    // 里画的(还乘了头的缩放), 会算错位置 —— 小零件上不值当, 线性渐变够了。
    let fill: &ID2D1Brush = if far { &c.b.fur_shade } else { &c.b.fur_grad };
    c.place(&c.shapes.ear, base, ang, sx, sy, Some(fill), 1.7);
    if !far {
        // 内耳: 同一形状缩小(只填色不描边)。**别做得太满** —— 顶到耳廓边缘就成了"粉三角"。
        c.place(
            &c.shapes.ear,
            (base.0 + 0.3, base.1 + 3.0),
            ang,
            0.44,
            sy * 0.52,
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
    let body_y = -50.0 * up - 13.0 * (1.0 - up) + p.bob + sit * 3.0 - bow * 6.0;
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
    let (ff, fr) = feet(p, 0.5, 25.0, -30.5, 0.0);
    leg(c, (21.5, body_y + 16.0), (ff.0, ff.1), -1.0, 8.0, true);
    leg(c, (-28.5, body_y + 18.0), (fr.0, fr.1), 1.0, 8.8, true);

    // ---- 尾巴: 卷在背上
    tail(c, body_y, (p.tail * std::f32::consts::TAU).sin(), p.alert, up);

    // ---- 身体: 用**轮廓路径**(背线平直 + 深胸 + 收腰), 不是一个大椭圆。
    // 比例对齐参考图那张表: 身体放大到 1.06(之前 0.90 配上 1.58 的大头 = "大头娃娃")
    c.rot_at(body_rot, (0.0, body_y), |c| {
        let dy = body_y + 58.0;
        // 身体: 轮廓路径 + **体积球**填充(球心在胸腹之间偏左上) —— 桶形身材的立体感
        c.ball_at(
            &c.b.ball,
            (-3.5, body_y + 3.0),
            44.0,
            29.0 * (0.85 + 0.15 * up),
            |c| {
                c.place(
                    &c.shapes.body,
                    (0.0, dy),
                    0.0,
                    1.00,
                    0.82 + 0.18 * up,
                    Some(&c.b.ball),
                    2.3,
                );
            },
        );
        // 暗面: 参考图是**水彩柔过渡**而不是硬平涂 —— 用两层半透明叠出柔和的边
        if let Ok(soft) = c.rt.CreateSolidColorBrush(
            &D2D1_COLOR_F {
                r: FUR_DEEP.r,
                g: FUR_DEEP.g,
                b: FUR_DEEP.b,
                a: 0.30,
            },
            None,
        ) {
            c.oval((-3.5, body_y + 14.0), 30.0, 11.0, &soft);
        }
        c.oval((-4.5, body_y + 15.0), 24.0, 5.6, &c.b.cel);
        // 背脊高光(一圈亮的边缘光, 让背线"鼓"起来)
        c.oval((-8.0, body_y - 21.0), 20.0, 3.2, &c.b.fur_light);
        // 里白: 胸口一坨 + 腹线一条
        c.ball_at(&c.b.ball_white, (21.0, body_y + 20.0), 15.0, 16.0, |c| {
            c.oval((19.0, body_y + 18.0), 12.0, 14.0, &c.b.ball_white);
        });
        c.oval((1.0, body_y + 23.0), 18.0, 5.5, &c.b.urajiro_grad);
    });

    // ---- 挎包(骑在身体上)。**只有场景 2 背**: 它会把身体整个盖住(见 Pose.bag 的注释)
    if p.bag > 0.01 {
        c.rot_at(body_rot, (0.0, body_y), |c| {
            satchel(c, -6.0, body_y + 6.0, p.bob, 3);
        });
    }

    // ---- 近侧两条腿: 柴犬是壮实的小型犬, 腿要**短而粗**(细杆腿是"不像"的主因之一)
    let (nf, nr) = feet(p, 0.0, 32.5, -23.0 + sit * 16.0, p.arm);
    leg(c, (28.0, body_y + 18.0), (nf.0, nf.1), -1.0, 12.6, false);
    leg(
        c,
        (-19.5, body_y + 20.0),
        (nr.0, nr.1),
        if sit > 0.4 { -0.5 } else { 1.0 },
        13.4,
        false,
    );

    // ---- 脖子: 粗(柴犬有厚颈毛), 把身体和头连起来(不描边, 否则肩上会多一道深色圆弧)
    // **别再往这里挂项圈**: 侧视里一条横杠无论怎么摆都读成"肩上贴了块皮子"(用户看到的就是这个),
    // 而参考图的柴犬本来就不戴项圈 —— 只有场景 2 的挎包。
    let neck = (27.0, body_y - 15.0);
    c.rot_at(0.42, neck, |c| {
        c.oval(neck, 15.5, 14.5, &c.b.fur);
    });

    // ---- 头: 姿态图那张脸(圆颅骨 + 短吻 + 白脸罩 + 额前橙 V + 眉上两点 + 小圆黑眼)
    let look = p.look.clamp(-1.0, 1.0);
    let yaw = look * 0.10;
    let hx = 36.0 + look * 3.8 + (1.0 - up) * -11.0;
    let hy = body_y - 29.0 - up * 3.0 + (1.0 - up) * 9.0 + p.head_drop * 26.0;
    // **头整体缩放**: 五官/耳朵一律画在"艺术坐标"里, 由 `at_scaled` 统一缩放 ——
    // 只把颅骨 `place(..., head_sx, ...)` 放大是错的: 头涨大而五官不动, 出来是个"大空脑袋"
    // (真踩过)。凡是这一层里 `ball_at` 的坐标/半径都是**画几何用的那个空间**, 要乘 hs。
    let hs = 1.34 * (1.0 - look.abs() * 0.035);
    c.at_scaled((hx, hy), body_rot * 0.65 + yaw + p.head_tilt, hs, |c| {
        // 远耳(立在颅顶后侧)
        ear(
            c,
            (-9.0 + look * 1.2, -20.0),
            -0.30 - look * 0.04,
            p.ear * 0.30,
            p.alert,
            true,
        );

        // 颅骨 + 吻(一整条轮廓): **体积球**填 —— 球心在头中偏左上(受光), 右下自然压暗
        c.ball_at(&c.b.ball, (4.0 * hs, -7.0 * hs), 30.0 * hs, 27.0 * hs, |c| {
            c.place(
                &c.shapes.head,
                (0.0, 0.0),
                0.0,
                1.0,
                1.0,
                Some(&c.b.ball),
                2.0,
            );
        });
        // **白脸罩**(里白): 颊 + 眼周, 顶上是那道橙 V。与吻部共用同一条里白渐变 ⇒ 无缝
        // (用体积球会在白底上留一道弧形的暗边, 看着像脸上贴了块白方子 —— 真踩过)。
        c.place(
            &c.shapes.mask,
            (0.0, 0.0),
            0.0,
            1.0,
            1.0,
            Some(&c.b.urajiro_grad),
            0.0,
        );
        // 眉上两点(柴犬的"四眼"): 奶油小圆点, 压在额头那道橙 V 上面
        c.oval((-6.5, -23.0), 2.7, 2.1, &c.b.urajiro);
        c.oval((4.5, -22.0), 2.5, 2.0, &c.b.urajiro);

        // 鼻梁线(眼下方 → 鼻根)
        let _ = c
            .rt
            .DrawGeometry(&c.shapes.bridge, &c.b.outline, 1.7, None);
        // 嘴: 张开的笑口(月牙) + 舌头。**先嘴后鼻** —— 鼻子压在嘴上沿, 嘴才不会盖住鼻头。
        let yz = p.yawn.clamp(0.0, 1.0);
        c.place(
            &c.shapes.mouth,
            (0.0, 0.0),
            0.0,
            1.0 + yz * 0.08,
            1.0 + yz * 0.55,
            Some(&c.b.mouth),
            1.5,
        );
        c.oval(
            (21.0, 6.8 + yz * 2.0),
            2.6 + yz * 1.5,
            1.3 + yz * 2.1,
            &c.b.tongue,
        );
        // 鼻: 姿态图里是**小的圆角三角黑鼻**(不是大圆鼻头), 压在吻的前上方
        c.oval((28.0, 1.0), 3.8, 3.0, &c.b.nose);
        c.disc((26.8, 0.0), 0.8, &c.b.eye_hi);

        // 眼: **小黑豆 + 单点高光**(姿态图的眼睛比原来那对大圆眼小一圈, 位置更低更分开),
        // 两只都落在白脸罩里。近大远小(三分之四视角)。
        let k = (1.0 - p.blink).max(0.08);
        for (e, r, tilt) in [
            ((-5.0 + look * 2.0, -10.5), 4.0f32, -0.10f32),
            ((6.5 + look * 2.0, -10.0), 4.3f32, -0.13f32),
        ] {
            let eh = r * 1.18 * k;
            c.rot_at(tilt, e, |c| {
                c.oval(e, r, eh, &c.b.eye);
            });
            c.disc(
                (e.0 - r * 0.28, e.1 - r * 0.36 * k),
                r * 0.34 * k,
                &c.b.eye_hi,
            );
        }

        // 近耳(立在颅顶前侧)
        ear(
            c,
            (6.0 + look * 0.9, -21.0),
            0.26 + look * 0.05,
            -p.ear * 0.34,
            p.alert,
            false,
        );
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
