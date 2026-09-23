//! 工具面板(百宝袋) —— 点击工具后交给宿主启动。
//!
//! 布局全部在**窗口坐标**里算, 由 `layout()` 一处产出: 绘制、命中测试、分页按钮、给探针的矩形
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

/// 面板打开时的窗口宽度(左侧留出角色的位置); 高度按工具数算, 见 `win_size`
pub const WIN_W: f32 = 620.0;
pub const PANEL_W: f32 = 342.0;
pub const PANEL_Y: f32 = 38.0;
pub const PAD: f32 = 12.0;
pub const HEAD_H: f32 = 42.0;
pub const FOOT_H: f32 = 24.0;
pub const ITEM_H: f32 = 42.0;
pub const ITEM_GAP: f32 = 5.0;
pub const COLS: usize = 2;
/// 一页最多几行
pub const ROWS: usize = 6;
pub const PER_PAGE: usize = COLS * ROWS;
/// 角色脚底中心离窗口左/右边的距离
pub const DOG_INSET: f32 = 150.0;
/// 面板下方留白
pub const BOTTOM_PAD: f32 = 18.0;

/// 打开面板时窗口该多大: **高度跟着工具数走**(工具少时不留一片空白),
/// 但分页时不会跳(只看工具总数, 不看当前第几页)。
pub fn win_size(n: usize) -> (i32, i32) {
    let rows = rows_used(n);
    let ph = panel_h(rows);
    (WIN_W as i32, (PANEL_Y + ph + BOTTOM_PAD).ceil() as i32)
}

fn rows_used(n: usize) -> usize {
    n.div_ceil(COLS).clamp(1, ROWS)
}

fn panel_h(rows: usize) -> f32 {
    PAD + HEAD_H + rows as f32 * (ITEM_H + ITEM_GAP) - ITEM_GAP + FOOT_H + PAD
}

pub struct Layout {
    /// (x, y, w, h)
    pub panel: (f32, f32, f32, f32),
    /// 本页每个格子: (工具全局下标, x, y, w, h)
    pub items: Vec<(usize, f32, f32, f32, f32)>,
    pub page: usize,
    pub pages: usize,
    pub close: (f32, f32, f32, f32),
    pub prev: (f32, f32, f32, f32),
    pub next: (f32, f32, f32, f32),
    pub flip: bool,
}

/// 面板与每个格子的矩形。`flip` = 面板在角色左侧。
pub fn layout(n: usize, flip: bool, page: usize) -> Layout {
    let rows = rows_used(n);
    let ph = panel_h(rows);
    let px = if flip { 22.0 } else { WIN_W - 22.0 - PANEL_W };
    let panel = (px, PANEL_Y, PANEL_W, ph);

    let pages = n.div_ceil(PER_PAGE).max(1);
    let page = page.min(pages - 1);
    let per = COLS * rows; // 本页能摆下的格子数(行数少时就更少)
    let start = page * per;
    let count = n.saturating_sub(start).min(per);

    let inner_w = PANEL_W - 2.0 * PAD;
    let col_w = (inner_w - ITEM_GAP) / COLS as f32;
    let mut items = Vec::with_capacity(count);
    for k in 0..count {
        let r = k / COLS;
        let c = k % COLS;
        items.push((
            start + k,
            px + PAD + c as f32 * (col_w + ITEM_GAP),
            PANEL_Y + PAD + HEAD_H + r as f32 * (ITEM_H + ITEM_GAP),
            col_w,
            ITEM_H,
        ));
    }

    // 标题条右侧: 关闭按钮贴最右, 翻页控件在它左边
    let by = PANEL_Y + (HEAD_H - 26.0) / 2.0;
    let close = (px + PANEL_W - PAD - 26.0, by, 26.0, 26.0);
    let next = (close.0 - 8.0 - 26.0, by, 26.0, 26.0);
    let prev = (next.0 - 4.0 - 26.0, by, 26.0, 26.0);

    Layout {
        panel,
        items,
        page,
        pages,
        close,
        prev,
        next,
        flip,
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
            unsafe { rt.CreateSolidColorBrush(&D2D1_COLOR_F { r, g, b, a }, None) }
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
            shadow: mk(0.09, 0.07, 0.10, 0.26)?,
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

fn icon_of(kind: &str) -> usize {
    match kind {
        "py" => 0,
        "txt" => 1,
        "tool" => 2,
        _ => 3,
    }
}

fn letter_of(code: &str) -> String {
    code.chars()
        .next()
        .map(|ch| ch.to_uppercase().to_string())
        .unwrap_or_else(|| "?".into())
}

/// 画面板。`hover` 是高亮的**全局**工具下标(-1 = 无), `hover_anim` 是每个格子的动效值 0..1,
/// `anim` 0..1 是开场动画进度, `pull` = (全局下标, 0..1) 表示正在被掏出来。
#[allow(clippy::too_many_arguments)]
pub unsafe fn draw_panel(
    c: &Ctx,
    pb: &Brushes,
    text: &Text,
    items: &[Item],
    l: &Layout,
    hover: i32,
    hover_anim: &[f32],
    anim: f32,
    pull: Option<(usize, f32)>,
) {
    let (px, py, pw, ph) = l.panel;
    // 开场: 从 0.94 缩到 1.0(锚在面板靠角色那一侧的下角, 像是被狗"甩"出来的)
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
    // 指向角色的小尾巴: 26x26 圆角方块转 45° 当三角尖, 圆心压进面板里 9px
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
    // 标题条(下缘留 4px 直线段, 免得圆角处出现月牙)
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(px, py, pw, PAD + HEAD_H, 16.0), &pb.head);
    let _ = c.rt.FillRectangle(
        &D2D_RECT_F {
            left: px,
            top: py + HEAD_H - 4.0,
            right: px + pw,
            bottom: py + PAD + HEAD_H,
        },
        &pb.head,
    );
    // 边框
    let _ = c
        .rt
        .DrawRoundedRectangle(&rr(px, py, pw, ph, 16.0), &pb.outline, 2.4, None);

    let _ = c.rt.SetTransform(&windows::Foundation::Numerics::Matrix3x2::identity());

    // 标题
    text.draw(
        c.rt, "百宝袋", px + PAD, py + 4.0, 110.0, HEAD_H - 4.0, &pb.text, &text.bold, 0, 1,
    );
    let cnt = format!("{} 个工具", items.len());
    text.draw(
        c.rt,
        &cnt,
        px + 84.0,
        py + 4.0,
        70.0,
        HEAD_H - 4.0,
        &pb.dim,
        &text.small,
        0,
        1,
    );

    // 翻页控件(只有一页就不画)
    if l.pages > 1 {
        for (r, label, hot) in [
            (l.prev, "‹".to_string(), l.page > 0),
            (l.next, "›".to_string(), l.page + 1 < l.pages),
        ] {
            if !hot {
                continue;
            }
            let _ = c.rt.FillRoundedRectangle(&rr(r.0, r.1, r.2, r.3, 7.0), &pb.item);
            let _ = c
                .rt
                .DrawRoundedRectangle(&rr(r.0, r.1, r.2, r.3, 7.0), &pb.outline, 1.4, None);
            text.draw(c.rt, &label, r.0, r.1, r.2, r.3, &pb.text, &text.bold, 1, 1);
        }
        let pg = format!("{}/{}", l.page + 1, l.pages);
        text.draw(
            c.rt,
            &pg,
            l.prev.0 + l.prev.2,
            l.prev.1,
            (l.next.0 - l.prev.0 - l.prev.2).max(24.0),
            26.0,
            &pb.dim,
            &text.small,
            1,
            1,
        );
    }
    // 关闭按钮
    let _ = c
        .rt
        .FillRoundedRectangle(&rr(l.close.0, l.close.1, l.close.2, l.close.3, 7.0), &pb.item);
    let _ = c
        .rt
        .DrawRoundedRectangle(&rr(l.close.0, l.close.1, l.close.2, l.close.3, 7.0), &pb.outline, 1.4, None);
    {
        let (x, y, s) = (l.close.0, l.close.1, l.close.2);
        let m = 8.0;
        c.line_w((x + m, y + m), (x + s - m, y + s - m), 2.2, &pb.text);
        c.line_w((x + s - m, y + m), (x + m, y + s - m), 2.2, &pb.text);
    }

    for (k, (gi, x, y, w, h)) in l.items.iter().enumerate() {
        let Some(it) = items.get(*gi) else { continue };
        let ha = hover_anim.get(k).copied().unwrap_or(0.0).clamp(0.0, 1.0);
        let hot = *gi as i32 == hover;
        // 悬停动效: 微微放大 + 投影 + 加粗描边
        let g = if hot { ha } else { 0.0 };
        let sc = 1.0 + 0.035 * g;
        let (nw, nh) = (w * sc, h * sc);
        let (mut x, mut y) = (x + (w - nw) / 2.0, y + (h - nh) / 2.0);
        let (w, h) = (nw, nh);

        // 被掏出来的那格: 朝角色方向滑出 + 缩小
        let mut w = w;
        let mut h = h;
        if let Some((pi, kk)) = pull {
            if pi == *gi {
                let dir = if l.flip { 1.0 } else { -1.0 };
                let kk = kk.clamp(0.0, 1.0);
                let s2 = 1.0 - 0.4 * kk;
                let (nw, nh) = (w * s2, h * s2);
                x += dir * kk * 52.0 + (w - nw) / 2.0;
                y += kk * 30.0 + (h - nh) / 2.0;
                w = nw;
                h = nh;
                let _ = c
                    .rt
                    .FillRoundedRectangle(&rr(x, y, w, h, 11.0), &pb.hover);
                let _ = c
                    .rt
                    .DrawRoundedRectangle(&rr(x, y, w, h, 11.0), &pb.outline, 2.2, None);
                let r = 14.0 * s2;
                let _ = c.rt.FillRoundedRectangle(
                    &rr(x + w / 2.0 - r, y + h / 2.0 - r, r * 2.0, r * 2.0, 6.0),
                    &pb.icons[icon_of(&it.kind)],
                );
                continue;
            }
        }

        if g > 0.02 {
            let _ = c.rt.FillRoundedRectangle(
                &rr(x + 1.0, y + 3.0 * g, w, h, 11.0),
                &pb.shadow,
            );
        }
        let fill = if g > 0.5 { &pb.hover } else { &pb.item };
        let _ = c.rt.FillRoundedRectangle(&rr(x, y, w, h, 11.0), fill);
        let _ = c.rt.DrawRoundedRectangle(
            &rr(x, y, w, h, 11.0),
            &pb.outline,
            1.4 + 0.9 * g,
            None,
        );
        // 图标: 按 kind 取色 + code 首字母
        let ix = x + 8.0;
        let iy = y + (h - 28.0) / 2.0;
        let _ = c
            .rt
            .FillRoundedRectangle(&rr(ix, iy, 28.0, 28.0, 8.0), &pb.icons[icon_of(&it.kind)]);
        text.draw(
            c.rt,
            &letter_of(&it.code),
            ix,
            iy,
            28.0,
            28.0,
            &pb.white,
            &text.bold,
            1,
            1,
        );
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

    // 页脚提示
    let hint = if l.pages > 1 {
        "滚轮或 ‹ › 翻页 · 点空白处关闭"
    } else {
        "点空白处关闭"
    };
    text.draw(
        c.rt,
        hint,
        px + PAD,
        py + ph - FOOT_H,
        pw - 2.0 * PAD,
        FOOT_H,
        &pb.dim,
        &text.small,
        1,
        1,
    );
}
