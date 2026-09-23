//! 工具面板(百宝袋) —— 点击工具后交给宿主启动。
//!
//! 布局全部在**窗口坐标**里算, 由 `layout()` 一处产出: 绘制、命中测试、给探针的矩形
//! 都用同一份结果 —— 三处各算一遍迟早会不一致(命中测试与画面错位是最难查的一类 bug)。

use crate::art::{Ctx, Text};
use windows::core::*;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;

#[derive(Clone, Default)]
pub struct Item {
    pub code: String,
    pub name: String,
    pub kind: String,
}

/// 面板打开时的窗口尺寸(左侧留出角色的位置)
pub const WIN_W: f32 = 620.0;
pub const WIN_H: f32 = 320.0;
pub const PANEL_W: f32 = 330.0;
pub const PANEL_Y: f32 = 38.0;
pub const PAD: f32 = 12.0;
pub const HEAD_H: f32 = 40.0;
pub const ITEM_H: f32 = 42.0;
pub const ITEM_GAP: f32 = 5.0;
pub const COLS: usize = 2;
/// 一屏最多显示几行(多了就报"还有 N 个")
pub const MAX_ROWS: usize = 4;
/// 角色脚底中心离窗口左/右边的距离
pub const DOG_INSET: f32 = 150.0;

pub struct Layout {
    /// (x, y, w, h)
    pub panel: (f32, f32, f32, f32),
    pub items: Vec<(f32, f32, f32, f32)>,
    /// 面板在角色右边? (角色靠屏幕右缘时翻到左边)
    pub flip: bool,
    pub hidden: usize,
}

/// 面板与每个格子的矩形。`flip` = 面板在角色左侧。
pub fn layout(n: usize, flip: bool) -> Layout {
    let shown = n.min(COLS * MAX_ROWS);
    let rows = shown.div_ceil(COLS).max(1);
    let ph = PAD + HEAD_H + rows as f32 * (ITEM_H + ITEM_GAP) - ITEM_GAP + PAD;
    let px = if flip { 22.0 } else { WIN_W - 22.0 - PANEL_W };
    let panel = (px, PANEL_Y, PANEL_W, ph);

    let inner_w = PANEL_W - 2.0 * PAD;
    let col_w = (inner_w - ITEM_GAP) / COLS as f32;
    let mut items = Vec::with_capacity(shown);
    for i in 0..shown {
        let r = i / COLS;
        let c = i % COLS;
        items.push((
            px + PAD + c as f32 * (col_w + ITEM_GAP),
            PANEL_Y + PAD + HEAD_H + r as f32 * (ITEM_H + ITEM_GAP),
            col_w,
            ITEM_H,
        ));
    }
    Layout {
        panel,
        items,
        flip,
        hidden: n.saturating_sub(shown),
    }
}

pub fn anchor_x(flip: bool, scale: f32) -> f32 {
    if flip {
        WIN_W - DOG_INSET * scale
    } else {
        DOG_INSET * scale
    }
}

pub struct Brushes {
    pub body: ID2D1SolidColorBrush,
    pub head: ID2D1SolidColorBrush,
    pub item: ID2D1SolidColorBrush,
    pub hover: ID2D1SolidColorBrush,
    pub outline: ID2D1SolidColorBrush,
    pub text: ID2D1SolidColorBrush,
    pub dim: ID2D1SolidColorBrush,
    pub white: ID2D1SolidColorBrush,
    pub shadow: ID2D1SolidColorBrush,
    pub icons: [ID2D1SolidColorBrush; 4],
}

impl Brushes {
    pub fn new(rt: &ID2D1RenderTarget) -> Result<Self> {
        let mk = |r: f32, g: f32, b: f32, a: f32| -> Result<ID2D1SolidColorBrush> {
            unsafe {
                rt.CreateSolidColorBrush(&D2D1_COLOR_F { r, g, b, a }, None)
            }
        };
        Ok(Self {
            body: mk(0.988, 0.976, 0.957, 0.985)?,
            head: mk(0.976, 0.878, 0.780, 1.0)?,
            item: mk(1.0, 1.0, 1.0, 1.0)?,
            hover: mk(0.996, 0.898, 0.741, 1.0)?,
            outline: mk(0.353, 0.216, 0.114, 1.0)?,
            text: mk(0.180, 0.137, 0.110, 1.0)?,
            dim: mk(0.451, 0.400, 0.361, 1.0)?,
            white: mk(1.0, 1.0, 1.0, 1.0)?,
            shadow: mk(0.09, 0.07, 0.10, 0.28)?,
            icons: [
                mk(0.361, 0.612, 0.812, 1.0)?,
                mk(0.945, 0.700, 0.259, 1.0)?,
                mk(0.541, 0.749, 0.478, 1.0)?,
                mk(0.741, 0.475, 0.573, 1.0)?,
            ],
        })
    }
}

fn rr(x: f32, y: f32, w: f32, h: f32, r: f32) -> D2D1_ROUNDED_RECT {
    D2D1_ROUNDED_RECT {
        rect: D2D_RECT_F {
            left: x,
            top: y,
            right: x + w,
            bottom: y + h,
        },
        radiusX: r,
        radiusY: r,
    }
}

/// 画面板。`hover` 是高亮格子的下标(-1 = 无), `anim` 0..1 是开场动画进度。
/// `pull` = (格子下标, 0..1 进度): 被点中的那格会朝角色那边滑出去并缩小, 读作"被掏出来"。
pub unsafe fn draw_panel(
    c: &Ctx,
    pb: &Brushes,
    text: &Text,
    items: &[Item],
    l: &Layout,
    hover: i32,
    anim: f32,
    pull: Option<(usize, f32)>,
) {
    let (px, py, pw, ph) = l.panel;
    // 开场: 从 0.94 缩到 1.0 并淡入(锚在面板靠角色那一侧的下角, 像是被狗"甩"出来的)
    let a = anim.clamp(0.0, 1.0);
    let sc = 0.94 + 0.06 * a;
    let ax = if l.flip { px + pw } else { px };
    let ay = py + ph;
    let _ = c.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2 {
        M11: sc,
        M12: 0.0,
        M21: 0.0,
        M22: sc,
        M31: ax * (1.0 - sc),
        M32: ay * (1.0 - sc),
    });

    // 投影
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(px + 4.0, py + 7.0, pw, ph, 16.0), &pb.shadow);
    // 指向角色的小尾巴: 一个 26x26 的圆角方块转 45° 当三角尖, 圆心**压进面板里** 9px
    // (转 45° 后外接半径是 0.707*26≈18.4, 所以要露多少就按这个反推圆心)
    let (tx, ty) = if l.flip {
        (px + pw - 9.0, py + ph - 52.0)
    } else {
        (px + 9.0, py + ph - 52.0)
    };
    c.rot_at(std::f32::consts::FRAC_PI_4, (tx, ty), |c| {
        let _ = c
            .rt
            .FillRoundedRectangle(&rr(tx - 13.0, ty - 13.0, 26.0, 26.0, 6.0), &pb.body);
    });
    // 面板本体
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(px, py, pw, ph, 16.0), &pb.body);
    // 标题条
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(px, py, pw, PAD + HEAD_H, 16.0), &pb.head);
    let _ = c
        .rt
        .FillRectangle(&D2D_RECT_F { left: px, top: py + HEAD_H - 4.0, right: px + pw, bottom: py + PAD + HEAD_H }, &pb.head);
    // 边框
    let _ = c
        .rt
        .DrawRoundedRectangle(&rr(px, py, pw, ph, 16.0), &pb.outline, 2.4, None);

    let _ = c.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2::identity());
    text.draw(
        c.rt,
        "百宝袋",
        px + PAD,
        py + 6.0,
        120.0,
        HEAD_H,
        &pb.text,
        &text.bold,
        0,
        1,
    );
    text.draw(
        c.rt,
        "点一个，小狗给你掏出来",
        px + 86.0,
        py + 6.0,
        pw - 98.0,
        HEAD_H,
        &pb.dim,
        &text.small,
        2,
        1,
    );

    for (i, (x, y, w, h)) in l.items.iter().enumerate() {
        let it = &items[i];
        let hot = i as i32 == hover;
        // 被掏出来的那格: 朝角色方向滑出 + 缩小
        let (mut x, mut y, w, h) = (*x, *y, *w, *h);
        if let Some((pi, k)) = pull {
            if pi == i {
                let dir = if l.flip { 1.0 } else { -1.0 };
                let k = k.clamp(0.0, 1.0);
                let sc = 1.0 - 0.4 * k;
                let (nw, nh) = (w * sc, h * sc);
                x += dir * k * 52.0 + (w - nw) / 2.0;
                y += k * 30.0 + (h - nh) / 2.0;
                let _ = c
                    .rt
                    .FillRoundedRectangle(&rr(x, y, nw, nh, 11.0), &pb.hover);
                let _ = c
                    .rt
                    .DrawRoundedRectangle(&rr(x, y, nw, nh, 11.0), &pb.outline, 2.2, None);
                let ic = match it.kind.as_str() {
                    "py" => 0,
                    "txt" => 1,
                    "tool" => 2,
                    _ => 3,
                };
                let r = 14.0 * sc;
                let _ = c.rt.FillRoundedRectangle(
                    &rr(x + nw / 2.0 - r, y + nh / 2.0 - r, r * 2.0, r * 2.0, 6.0),
                    &pb.icons[ic],
                );
                continue;
            }
        }
        let _ = c
            .rt
            .FillRoundedRectangle(&rr(x, y, w, h, 11.0), if hot { &pb.hover } else { &pb.item });
        let _ = c
            .rt
            .DrawRoundedRectangle(&rr(x, y, w, h, 11.0), &pb.outline, if hot { 2.2 } else { 1.4 }, None);
        // 图标: 按 kind 取色 + code 首字母
        let ic = match it.kind.as_str() {
            "py" => 0,
            "txt" => 1,
            "tool" => 2,
            _ => 3,
        };
        let ix = x + 8.0;
        let iy = y + (h - 28.0) / 2.0;
        let _ = c
            .rt
            .FillRoundedRectangle(&rr(ix, iy, 28.0, 28.0, 8.0), &pb.icons[ic]);
        let letter: String = it
            .code
            .chars()
            .next()
            .map(|ch| ch.to_uppercase().to_string())
            .unwrap_or_else(|| "?".into());
        text.draw(
            c.rt,
            &letter,
            ix,
            iy,
            28.0,
            28.0,
            &pb.white,
            &text.bold,
            1,
            1,
        );
        // 名字
        text.draw(
            c.rt,
            &it.name,
            ix + 34.0,
            y,
            w - 44.0,
            h,
            &pb.text,
            &text.normal,
            0,
            1,
        );
    }

    if l.hidden > 0 {
        text.draw(
            c.rt,
            &format!("还有 {} 个工具没摆下", l.hidden),
            px + PAD,
            py + ph - 18.0,
            pw - 2.0 * PAD,
            16.0,
            &pb.dim,
            &text.small,
            1,
            0,
        );
    }
}
