//! SVG `<path d="...">` → D2D 路径几何。**只当"绘制源", 不当渲染器**(§D55)。
//!
//! 为什么不直接引 `resvg`/`usvg`: 我们需要的只是"把 d 串变成 `ID2D1PathGeometry`"这一件事。
//! resvg 会把 CPU 光栅器 + 字体栈(fontdb/rustybuzz)整棵依赖树搬进 DLL(本机 crate 缓存里没有,
//! `cargo build --offline` 会直接失败), 而我们的动画是**参数化连续形变**(2 骨 IK / 尾巴 / 耳朵 /
//! 眨眼 / 张口), 光栅成位图就等于退回精灵图集 —— 那正是当初特意不要的做法。
//!
//! 支持的命令: `M m L l H h V v C c S s Q q T t A a Z z`(够 Inkscape 的"对象转路径"用: 矩形/椭圆
//! 出来的是 `A`, 铅笔/贝塞尔是 `C`, 相对命令也支持)。`Q/T` 自己转三次贝塞尔、`A` 走
//! 端点参数化转圆弧 —— **不碰 D2D 1.1 的 `AddQuadraticBezier`**(DC 渲染目标是 1.0 接口)。
//!
//! 只认两个属性: `id`(零件名)与 `fill="none"`/`style="fill:none"`(只描边的开放图形 → HOLLOW/OPEN)。
//! `fill-rule="evenodd"` 顺带认。颜色/描边宽度一律**忽略** —— 调色板与笔刷仍在 `art.rs` 里
//! (渐变笔刷是 Rust 侧按 pose 摆的, SVG 里那些颜色只是给你在 Inkscape 里看着顺眼)。

use std::collections::HashMap;
use windows::Win32::Graphics::Direct2D::Common::*;
use windows::Win32::Graphics::Direct2D::*;

type P = (f32, f32);

/// 一个 `<path>` 的输入
#[derive(Clone, Debug)]
pub struct Part {
    pub d: String,
    /// `fill="none"`: 只描边, 子路径按 HOLLOW + OPEN 建(否则 D2D 会把开口当闭合填充)
    pub stroke_only: bool,
    pub even_odd: bool,
}

/// 一份 SVG 里所有带 `id` 的 path
#[derive(Default)]
pub struct SvgPaths {
    parts: HashMap<String, Part>,
}

impl SvgPaths {
    pub fn parse(svg: &str) -> Self {
        let clean = strip_comments(svg);
        let b = clean.as_bytes();
        let mut parts = HashMap::new();
        let mut i = 0usize;
        while let Some(p) = find(b, i, b"<path") {
            let Some(end) = tag_end(b, p) else { break };
            let tag = &clean[p..end];
            i = end;
            let Some(id) = attr(tag, "id") else { continue };
            let d = attr(tag, "d").unwrap_or_default();
            if d.trim().is_empty() {
                continue;
            }
            let fill = attr(tag, "fill").unwrap_or_default();
            let style = attr(tag, "style").unwrap_or_default().to_ascii_lowercase();
            let stroke_only = fill.trim().eq_ignore_ascii_case("none")
                || style.split(';').any(|kv| {
                    let mut it = kv.splitn(2, ':');
                    it.next().map(|k| k.trim() == "fill") == Some(true)
                        && it.next().map(|v| v.trim() == "none") == Some(true)
                });
            let even_odd = attr(tag, "fill-rule")
                .map(|v| v.trim().eq_ignore_ascii_case("evenodd"))
                .unwrap_or(false);
            parts.insert(
                id.trim().to_string(),
                Part {
                    d,
                    stroke_only,
                    even_odd,
                },
            );
        }
        Self { parts }
    }

    pub fn len(&self) -> usize {
        self.parts.len()
    }

    pub fn ids(&self) -> Vec<&str> {
        let mut v: Vec<&str> = self.parts.keys().map(|s| s.as_str()).collect();
        v.sort_unstable();
        v
    }

    /// 建几何。没这个 `id` / d 解析不动 / D2D 报错 → `Err(原因)`, 调用方退回内置路径。
    pub fn build(&self, f: &ID2D1Factory, id: &str) -> std::result::Result<ID2D1PathGeometry, String> {
        let p = self
            .parts
            .get(id)
            .ok_or_else(|| "SVG 里没有这个 id".to_string())?;
        build_path(f, &p.d, p.stroke_only, p.even_odd)
    }
}

// ---------------------------------------------------------------- XML 小工具

fn strip_comments(svg: &str) -> String {
    let mut out = String::with_capacity(svg.len());
    let b = svg.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        if b[i..].starts_with(b"<!--") {
            match find(b, i + 4, b"-->") {
                Some(j) => i = j + 3,
                None => break,
            }
        } else {
            // 按字节推进会切坏 UTF-8; 只在 ASCII 位置切片才安全 —— 逐字符推
            let ch = svg[i..].chars().next().unwrap_or(' ');
            out.push(ch);
            i += ch.len_utf8();
        }
    }
    out
}

fn find(h: &[u8], from: usize, needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || h.len() < needle.len() || from > h.len() - needle.len() {
        return None;
    }
    (from..=h.len() - needle.len()).find(|&i| &h[i..i + needle.len()] == needle)
}

/// 标签属性区结束位置(引号里的 `>` 不算)
fn tag_end(h: &[u8], start: usize) -> Option<usize> {
    let mut q = 0u8;
    let mut i = start;
    while i < h.len() {
        let c = h[i];
        if q != 0 {
            if c == q {
                q = 0;
            }
        } else if c == b'"' || c == b'\'' {
            q = c;
        } else if c == b'>' {
            return Some(i);
        }
        i += 1;
    }
    None
}

/// 取属性值(双引号或单引号)
fn attr(tag: &str, name: &str) -> Option<String> {
    let b = tag.as_bytes();
    let mut from = 0usize;
    while let Some(p) = find(b, from, name.as_bytes()) {
        from = p + name.len();
        let prev_ok = p == 0 || !b[p - 1].is_ascii_alphanumeric() && b[p - 1] != b'-' && b[p - 1] != b'_';
        let mut j = from;
        while j < b.len() && b[j].is_ascii_whitespace() {
            j += 1;
        }
        if !prev_ok || j >= b.len() || b[j] != b'=' {
            continue;
        }
        j += 1;
        while j < b.len() && b[j].is_ascii_whitespace() {
            j += 1;
        }
        if j >= b.len() || (b[j] != b'"' && b[j] != b'\'') {
            continue;
        }
        let q = b[j];
        j += 1;
        let s = j;
        while j < b.len() && b[j] != q {
            j += 1;
        }
        return Some(tag[s..j].to_string());
    }
    None
}

// ---------------------------------------------------------------- d 串

struct Lex<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Lex<'a> {
    fn sep(&mut self) {
        while self.i < self.b.len()
            && (self.b[self.i].is_ascii_whitespace() || self.b[self.i] == b',')
        {
            self.i += 1;
        }
    }
    fn peek(&mut self) -> Option<u8> {
        self.sep();
        self.b.get(self.i).copied()
    }
    /// SVG 数字: 可选符号 + 整数/小数部分(允许 `.5` / `1.` / `1.5.5` 这种连写的第二个数) + 指数
    fn num(&mut self) -> Option<f32> {
        self.sep();
        let s = self.i;
        if self.i < self.b.len() && (self.b[self.i] == b'+' || self.b[self.i] == b'-') {
            self.i += 1;
        }
        let mut digits = false;
        while self.i < self.b.len() && self.b[self.i].is_ascii_digit() {
            self.i += 1;
            digits = true;
        }
        if self.i < self.b.len() && self.b[self.i] == b'.' {
            self.i += 1;
            while self.i < self.b.len() && self.b[self.i].is_ascii_digit() {
                self.i += 1;
                digits = true;
            }
        }
        if !digits {
            self.i = s;
            return None;
        }
        if self.i < self.b.len() && (self.b[self.i] == b'e' || self.b[self.i] == b'E') {
            let save = self.i;
            self.i += 1;
            if self.i < self.b.len() && (self.b[self.i] == b'+' || self.b[self.i] == b'-') {
                self.i += 1;
            }
            let mut ed = false;
            while self.i < self.b.len() && self.b[self.i].is_ascii_digit() {
                self.i += 1;
                ed = true;
            }
            if !ed {
                self.i = save;
            }
        }
        std::str::from_utf8(&self.b[s..self.i])
            .ok()?
            .parse::<f32>()
            .ok()
    }
}

fn dpt(p: P) -> D2D_POINT_2F {
    D2D_POINT_2F { x: p.0, y: p.1 }
}

unsafe fn begin(sink: &ID2D1GeometrySink, p: P, hollow: bool) {
    sink.BeginFigure(
        dpt(p),
        if hollow {
            D2D1_FIGURE_BEGIN_HOLLOW
        } else {
            D2D1_FIGURE_BEGIN_FILLED
        },
    );
}

unsafe fn line(sink: &ID2D1GeometrySink, p: P) {
    sink.AddLine(dpt(p));
}

unsafe fn curve(sink: &ID2D1GeometrySink, c1: P, c2: P, p: P) {
    sink.AddBezier(&D2D1_BEZIER_SEGMENT {
        point1: dpt(c1),
        point2: dpt(c2),
        point3: dpt(p),
    });
}

fn build_path(
    f: &ID2D1Factory,
    d: &str,
    stroke_only: bool,
    even_odd: bool,
) -> std::result::Result<ID2D1PathGeometry, String> {
    unsafe {
        let g = f.CreatePathGeometry().map_err(|e| format!("CreatePathGeometry: {e}"))?;
        let sink = g.Open().map_err(|e| format!("Open: {e}"))?;
        sink.SetFillMode(if even_odd {
            D2D1_FILL_MODE_ALTERNATE
        } else {
            D2D1_FILL_MODE_WINDING
        });

        let mut lex = Lex { b: d.as_bytes(), i: 0 };
        let mut cur: P = (0.0, 0.0);
        let mut sub: P = (0.0, 0.0);
        let mut c2: P = (0.0, 0.0); // 上一个三次的末控制点(S 反射用)
        let mut qc: P = (0.0, 0.0); // 上一个二次的控制点(T 反射用)
        let mut prev = 0u8;
        let mut cmd = 0u8;
        let mut open = false;
        let mut segs = 0usize;

        loop {
            let Some(c) = lex.peek() else { break };
            if c.is_ascii_alphabetic() {
                cmd = c;
                lex.i += 1;
            } else if cmd == 0 || cmd == b'Z' || cmd == b'z' {
                return Err(format!("第 {} 字节起: 命令缺失或 z 后跟数字", lex.i));
            }
            let up = cmd.to_ascii_uppercase();
            let rel = cmd.is_ascii_lowercase();
            if matches!(up, b'L' | b'H' | b'V' | b'C' | b'S' | b'Q' | b'T' | b'A') && !open {
                // `Z` 之后接着画: 新子路径从闭合点开始
                begin(&sink, cur, stroke_only);
                open = true;
            }
            match up {
                b'M' => {
                    let (Some(mut x), Some(mut y)) = (lex.num(), lex.num()) else {
                        return Err(format!("M 缺坐标(第 {} 字节)", lex.i));
                    };
                    if rel {
                        x += cur.0;
                        y += cur.1;
                    }
                    if open {
                        sink.EndFigure(D2D1_FIGURE_END_OPEN);
                    }
                    begin(&sink, (x, y), stroke_only);
                    open = true;
                    cur = (x, y);
                    sub = (x, y);
                    cmd = if rel { b'l' } else { b'L' }; // M 之后的隐式 lineto
                }
                b'L' => {
                    let (Some(mut x), Some(mut y)) = (lex.num(), lex.num()) else {
                        return Err(format!("L 缺坐标(第 {} 字节)", lex.i));
                    };
                    if rel {
                        x += cur.0;
                        y += cur.1;
                    }
                    line(&sink, (x, y));
                    cur = (x, y);
                    segs += 1;
                }
                b'H' => {
                    let Some(mut x) = lex.num() else {
                        return Err(format!("H 缺坐标(第 {} 字节)", lex.i));
                    };
                    if rel {
                        x += cur.0;
                    }
                    line(&sink, (x, cur.1));
                    cur.0 = x;
                    segs += 1;
                }
                b'V' => {
                    let Some(mut y) = lex.num() else {
                        return Err(format!("V 缺坐标(第 {} 字节)", lex.i));
                    };
                    if rel {
                        y += cur.1;
                    }
                    line(&sink, (cur.0, y));
                    cur.1 = y;
                    segs += 1;
                }
                b'C' | b'S' => {
                    let a = match (up, lex.num(), lex.num()) {
                        (b'C', Some(x), Some(y)) => (x, y),
                        (b'C', _, _) => return Err(format!("C 缺坐标(第 {} 字节)", lex.i)),
                        // S: 首控制点 = 上一条三次的末控制点关于当前点的反射
                        _ => {
                            if matches!(prev, b'C' | b'S') {
                                (2.0 * cur.0 - c2.0, 2.0 * cur.1 - c2.1)
                            } else {
                                cur
                            }
                        }
                    };
                    let (Some(mut b1x), Some(mut b1y), Some(mut ex), Some(mut ey)) =
                        (lex.num(), lex.num(), lex.num(), lex.num())
                    else {
                        return Err(format!("C/S 缺坐标(第 {} 字节)", lex.i));
                    };
                    if rel {
                        b1x += cur.0;
                        b1y += cur.1;
                        ex += cur.0;
                        ey += cur.1;
                    }
                    curve(&sink, a, (b1x, b1y), (ex, ey));
                    c2 = (b1x, b1y);
                    cur = (ex, ey);
                    segs += 1;
                }
                b'Q' | b'T' => {
                    let q = match (up, lex.num(), lex.num()) {
                        (b'Q', Some(x), Some(y)) => (x, y),
                        (b'Q', _, _) => return Err(format!("Q 缺坐标(第 {} 字节)", lex.i)),
                        _ => {
                            if matches!(prev, b'Q' | b'T') {
                                (2.0 * cur.0 - qc.0, 2.0 * cur.1 - qc.1)
                            } else {
                                cur
                            }
                        }
                    };
                    let (Some(mut ex), Some(mut ey)) = (lex.num(), lex.num()) else {
                        return Err(format!("Q/T 缺坐标(第 {} 字节)", lex.i));
                    };
                    if rel {
                        ex += cur.0;
                        ey += cur.1;
                    }
                    // 二次 → 三次: 控制点各取 2/3(D2D 1.0 没有 AddQuadraticBezier)
                    let q = (q.0, q.1);
                    let (c1, c2n) = (
                        (cur.0 + 2.0 / 3.0 * (q.0 - cur.0), cur.1 + 2.0 / 3.0 * (q.1 - cur.1)),
                        (ex + 2.0 / 3.0 * (q.0 - ex), ey + 2.0 / 3.0 * (q.1 - ey)),
                    );
                    curve(&sink, c1, c2n, (ex, ey));
                    qc = q;
                    cur = (ex, ey);
                    segs += 1;
                }
                b'A' => {
                    let n = (lex.num(), lex.num(), lex.num(), lex.num(), lex.num());
                    let (Some(rx), Some(ry), Some(rot), Some(laf), Some(sf)) = n else {
                        return Err(format!("A 缺参数(第 {} 字节)", lex.i));
                    };
                    let (Some(mut ex), Some(mut ey)) = (lex.num(), lex.num()) else {
                        return Err(format!("A 缺终点(第 {} 字节)", lex.i));
                    };
                    if rel {
                        ex += cur.0;
                        ey += cur.1;
                    }
                    let arcs = arc_to_cubics(cur, (rx, ry), rot, laf != 0.0, sf != 0.0, (ex, ey));
                    if arcs.is_empty() {
                        line(&sink, (ex, ey));
                    } else {
                        for (c1, c2n, p) in arcs {
                            curve(&sink, c1, c2n, p);
                        }
                    }
                    cur = (ex, ey);
                    segs += 1;
                }
                b'Z' => {
                    if open {
                        sink.EndFigure(D2D1_FIGURE_END_CLOSED);
                        open = false;
                    }
                    cur = sub;
                }
                _ => return Err(format!("不认识的命令 '{}'", cmd as char)),
            }
            prev = up;
        }
        if open {
            sink.EndFigure(D2D1_FIGURE_END_OPEN);
        }
        sink.Close().map_err(|e| format!("Close: {e}"))?;
        if segs == 0 {
            return Err("d 里没有任何线段".to_string());
        }
        Ok(g)
    }
}

/// SVG 端点参数化圆弧 → 一串三次贝塞尔(每段 ≤90°)。返回 (c1, c2, end) 三元组。
fn arc_to_cubics(
    from: P,
    r: P,
    rot_deg: f32,
    large: bool,
    sweep: bool,
    to: P,
) -> Vec<(P, P, P)> {
    use std::f32::consts::{FRAC_PI_2, PI, TAU};
    let (mut rx, mut ry) = (r.0.abs(), r.1.abs());
    if rx < 1e-6 || ry < 1e-6 || (from.0 - to.0).abs() < 1e-9 && (from.1 - to.1).abs() < 1e-9 {
        return Vec::new();
    }
    let phi = rot_deg * PI / 180.0;
    let (sp, cp) = (phi.sin(), phi.cos());
    let (dx, dy) = ((from.0 - to.0) / 2.0, (from.1 - to.1) / 2.0);
    let x1p = cp * dx + sp * dy;
    let y1p = -sp * dx + cp * dy;
    // 半径太小就按规范放大
    let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lam > 1.0 {
        let s = lam.sqrt();
        rx *= s;
        ry *= s;
    }
    let num = (rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p).max(0.0);
    let den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
    let co = if den <= 0.0 {
        0.0
    } else {
        (num / den).sqrt() * if large != sweep { 1.0 } else { -1.0 }
    };
    let cxp = co * rx * y1p / ry;
    let cyp = -co * ry * x1p / rx;
    let cx = cp * cxp - sp * cyp + (from.0 + to.0) / 2.0;
    let cy = sp * cxp + cp * cyp + (from.1 + to.1) / 2.0;

    let ang = |ux: f32, uy: f32, vx: f32, vy: f32| -> f32 {
        let d = ux * vx + uy * vy;
        let l = ((ux * ux + uy * uy) * (vx * vx + vy * vy)).sqrt().max(1e-9);
        let a = (d / l).clamp(-1.0, 1.0).acos();
        if ux * vy - uy * vx < 0.0 {
            -a
        } else {
            a
        }
    };
    let u = ((x1p - cxp) / rx, (y1p - cyp) / ry);
    let v = ((-x1p - cxp) / rx, (-y1p - cyp) / ry);
    let t1 = ang(1.0, 0.0, u.0, u.1);
    let mut dt = ang(u.0, u.1, v.0, v.1);
    if !sweep && dt > 0.0 {
        dt -= TAU;
    } else if sweep && dt < 0.0 {
        dt += TAU;
    }
    let n = ((dt.abs() / FRAC_PI_2).ceil() as usize).max(1);
    let step = dt / n as f32;
    let k = 4.0 / 3.0 * (step / 4.0).tan();
    let pt_at = |t: f32| -> P {
        (
            cx + rx * t.cos() * cp - ry * t.sin() * sp,
            cy + rx * t.cos() * sp + ry * t.sin() * cp,
        )
    };
    let d_at = |t: f32| -> P {
        (
            -rx * t.sin() * cp - ry * t.cos() * sp,
            -rx * t.sin() * sp + ry * t.cos() * cp,
        )
    };
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let (ta, tb) = (t1 + step * i as f32, t1 + step * (i + 1) as f32);
        let (pa, pb) = (pt_at(ta), pt_at(tb));
        let (da, db) = (d_at(ta), d_at(tb));
        out.push((
            (pa.0 + k * da.0, pa.1 + k * da.1),
            (pb.0 - k * db.0, pb.1 - k * db.1),
            pb,
        ));
    }
    out
}
