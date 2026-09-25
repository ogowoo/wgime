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

/// 一个形状元素的输入
#[derive(Clone, Debug)]
pub struct Part {
    pub d: String,
    /// `fill="none"` / `<line>` / `<polyline>`: 只描边, 子路径按 HOLLOW + OPEN 建
    pub stroke_only: bool,
    pub even_odd: bool,
    /// 累计变换(`<g transform>` 嵌套 + 元素自己的 transform, 仿射矩阵 [a b c d e f])
    pub t: Option<[f32; 6]>,
}

/// 一份 SVG 里所有带 `id` 的 path
#[derive(Default)]
pub struct SvgPaths {
    parts: HashMap<String, Part>,
}

impl SvgPaths {
    /// 解析一份 SVG: 逐个认标签, `<g transform>` 进栈、`<defs>/<style>` 整段跳过,
    /// `<rect>/<circle>/<ellipse>/<line>/<polygon>/<polyline>` 先转成等价的 d 串。
    /// 这就是为什么 Inkscape/Figma/Illustrator 导出的"平铺版"可以直接用 —— 它们导出的就是这套。
    pub fn parse(svg: &str) -> Self {
        let clean = strip_comments(svg);
        let b = clean.as_bytes();
        let mut parts = HashMap::new();
        let mut gstack: Vec<[f32; 6]> = Vec::new();
        let mut skip = 0usize;
        let mut i = 0usize;
        while let Some(lt) = find(b, i, b"<") {
            if lt + 1 < b.len() && (b[lt + 1] == b'!' || b[lt + 1] == b'?') {
                let Some(end) = find(b, lt + 1, b">") else { break };
                i = end + 1;
                continue;
            }
            let Some(end) = tag_end(b, lt) else { break };
            let tag = &clean[lt + 1..end];
            i = end + 1;
            let closing = tag.trim_start().starts_with('/');
            let name = tag_name(tag);
            let selfclose = tag.trim_end().ends_with('/');
            if skip > 0 {
                if closing {
                    skip = skip.saturating_sub(1);
                }
                continue;
            }
            match name {
                "defs" | "style" | "metadata" | "title" | "desc" => {
                    if !closing && !selfclose {
                        skip += 1;
                    }
                }
                "g" | "svg" => {
                    if closing {
                        let _ = gstack.pop();
                    } else if !selfclose {
                        let t = attr(tag, "transform").as_deref().and_then(parse_transform);
                        gstack.push(t.unwrap_or(IDENTITY));
                    }
                }
                "path" | "rect" | "circle" | "ellipse" | "line" | "polygon" | "polyline" => {
                    let Some(id) = attr(tag, "id") else { continue };
                    let Some(d) = elem_to_d(name, tag) else { continue };
                    if d.trim().is_empty() {
                        continue;
                    }
                    let fill = attr(tag, "fill").unwrap_or_default();
                    let style = attr(tag, "style").unwrap_or_default().to_ascii_lowercase();
                    let mut stroke_only = fill.trim().eq_ignore_ascii_case("none")
                        || style.split(';').any(|kv| {
                            let mut it = kv.splitn(2, ':');
                            it.next().map(|k| k.trim() == "fill") == Some(true)
                                && it.next().map(|v| v.trim() == "none") == Some(true)
                        });
                    if name == "line" || name == "polyline" {
                        stroke_only = true;
                    }
                    let even_odd = attr(tag, "fill-rule")
                        .map(|v| v.trim().eq_ignore_ascii_case("evenodd"))
                        .unwrap_or(false);
                    // 有效变换 = 元素自己的 -> 最内层 <g> -> ... -> 最外层 <g>(每步都是"先左后右")
                    let mut t = attr(tag, "transform").as_deref().and_then(parse_transform);
                    for g in gstack.iter().rev() {
                        t = Some(match t {
                            Some(x) => mul(x, *g),
                            None => *g,
                        });
                    }
                    if t == Some(IDENTITY) {
                        t = None;
                    }
                    parts.insert(
                        id.trim().to_string(),
                        Part {
                            d,
                            stroke_only,
                            even_odd,
                            t,
                        },
                    );
                }
                _ => {}
            }
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
        build_path(f, &p.d, p.stroke_only, p.even_odd, p.t)
    }
}

// ---------------------------------------------------------------- 变换(仿射矩阵 [a b c d e f])

const IDENTITY: [f32; 6] = [1.0, 0.0, 0.0, 1.0, 0.0, 0.0];

/// 矩阵复合: `mul(a, b)` = 先做 a 再做 b(点 p 走 `b(a(p))`)。
/// SVG 属性 [a b c d e f] 的约定: x' = a·x + c·y + e, y' = b·x + d·y + f。
fn mul(a: [f32; 6], b: [f32; 6]) -> [f32; 6] {
    [
        b[0] * a[0] + b[2] * a[1],
        b[1] * a[0] + b[3] * a[1],
        b[0] * a[2] + b[2] * a[3],
        b[1] * a[2] + b[3] * a[3],
        b[0] * a[4] + b[2] * a[5] + b[4],
        b[1] * a[4] + b[3] * a[5] + b[5],
    ]
}

/// `transform="..."` 属性 → 矩阵。支持 translate / scale / rotate(含绕点) / matrix / skewX / skewY。
fn parse_transform(s: &str) -> Option<[f32; 6]> {
    let b = s.as_bytes();
    let mut acc = IDENTITY;
    let mut any = false;
    let mut i = 0usize;
    while i < b.len() {
        while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b',') {
            i += 1;
        }
        if i >= b.len() {
            break;
        }
        let start = i;
        while i < b.len() && b[i].is_ascii_alphabetic() {
            i += 1;
        }
        let name = &s[start..i];
        let Some(p) = find(b, i, b"(") else { break };
        let Some(q) = find(b, p, b")") else { break };
        let nums: Vec<f32> = s[p + 1..q]
            .split(|c: char| c.is_ascii_whitespace() || c == ',')
            .filter_map(|t| t.parse().ok())
            .collect();
        let n = |k: usize, d: f32| nums.get(k).copied().unwrap_or(d);
        let m = match name {
            "translate" => [1.0, 0.0, 0.0, 1.0, n(0, 0.0), n(1, 0.0)],
            "scale" => [n(0, 1.0), 0.0, 0.0, n(1, n(0, 1.0)), 0.0, 0.0],
            "matrix" if nums.len() == 6 => [nums[0], nums[1], nums[2], nums[3], nums[4], nums[5]],
            "rotate" => {
                let (si, co) = n(0, 0.0).to_radians().sin_cos();
                let r = [co, si, -si, co, 0.0, 0.0];
                if nums.len() >= 3 {
                    // rotate(a cx cy) = translate(cx,cy) · rotate(a) · translate(-cx,-cy)
                    mul(
                        mul([1.0, 0.0, 0.0, 1.0, nums[1], nums[2]], r),
                        [1.0, 0.0, 0.0, 1.0, -nums[1], -nums[2]],
                    )
                } else {
                    r
                }
            }
            "skewX" => [1.0, 0.0, n(0, 0.0).to_radians().tan(), 1.0, 0.0, 0.0],
            "skewY" => [1.0, n(0, 0.0).to_radians().tan(), 0.0, 1.0, 0.0, 0.0],
            _ => IDENTITY,
        };
        acc = mul(acc, m);
        any = true;
        i = q + 1;
    }
    if any {
        Some(acc)
    } else {
        None
    }
}

// ---------------------------------------------------------------- 基本形 → d 串

fn tag_name(tag: &str) -> &str {
    let t = tag.trim_start_matches('/');
    let end = t
        .find(|c: char| c.is_ascii_whitespace() || c == '/' || c == '>')
        .unwrap_or(t.len());
    &t[..end]
}

fn elem_to_d(name: &str, tag: &str) -> Option<String> {
    if name == "path" {
        return attr(tag, "d");
    }
    let n = |k: &str| -> f32 {
        attr(tag, k)
            .and_then(|v| v.trim().parse().ok())
            .unwrap_or(0.0)
    };
    match name {
        "rect" => {
            let (x, y, w, h) = (n("x"), n("y"), n("width"), n("height"));
            if w <= 0.0 || h <= 0.0 {
                return None;
            }
            let mut rx = n("rx");
            let ry0 = n("ry");
            let ry = if ry0 > 0.0 { ry0 } else { rx };
            if ry0 > 0.0 {
                rx = ry0;
            }
            if rx <= 0.0 && ry <= 0.0 {
                Some(format!("M {x} {y} H {} V {} H {} Z", x + w, y + h, x))
            } else {
                let (rx, ry) = (rx.min(w / 2.0), ry.min(h / 2.0));
                Some(format!(
                    "M {} {} H {} A {} {} 0 0 1 {} {} V {} A {} {} 0 0 1 {} {} H {} A {} {} 0 0 1 {} {} V {} A {} {} 0 0 1 {} {} Z",
                    x + rx, y, x + w - rx, rx, ry, x + w, y + ry, y + h - ry, rx, ry,
                    x + w - rx, y + h, x + rx, rx, ry, x, y + h - ry, y + ry, rx, ry, x + rx, y
                ))
            }
        }
        "circle" => {
            let (cx, cy, r) = (n("cx"), n("cy"), n("r"));
            Some(format!(
                "M {} {} A {} {} 0 1 0 {} {} A {} {} 0 1 0 {} {} Z",
                cx - r, cy, r, r, cx + r, cy, r, r, cx - r, cy
            ))
        }
        "ellipse" => {
            let (cx, cy, rx, ry) = (n("cx"), n("cy"), n("rx"), n("ry"));
            Some(format!(
                "M {} {} A {} {} 0 1 0 {} {} A {} {} 0 1 0 {} {} Z",
                cx - rx, cy, rx, ry, cx + rx, cy, rx, ry, cx - rx, cy
            ))
        }
        "line" => Some(format!(
            "M {} {} L {} {}",
            n("x1"),
            n("y1"),
            n("x2"),
            n("y2")
        )),
        "polygon" | "polyline" => {
            let pts: Vec<f32> = attr(tag, "points")?
                .split(|c: char| c.is_ascii_whitespace() || c == ',')
                .filter_map(|t| t.parse().ok())
                .collect();
            if pts.len() < 4 {
                return None;
            }
            let mut d = format!("M {} {}", pts[0], pts[1]);
            for k in (2..pts.len()).step_by(2) {
                d.push_str(&format!(" L {} {}", pts[k], pts[k + 1]));
            }
            if name == "polygon" {
                d.push_str(" Z");
            }
            Some(d)
        }
        _ => None,
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
    t: Option<[f32; 6]>,
) -> std::result::Result<ID2D1PathGeometry, String> {
    unsafe {
        // 变换在**落点处**统一应用(仿射变换保中点/反射, 所以相对命令与 S/T 反射先在局部空间算好再映射,
        // 结果等价)。`A` 弧的 rx/ry/旋转不随变换(只映射终点) —— 我们的美术没有 A 弧做变换。
        let map = |p: P| -> P {
            match t {
                None => p,
                Some(m) => (m[0] * p.0 + m[2] * p.1 + m[4], m[1] * p.0 + m[3] * p.1 + m[5]),
            }
        };
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
                begin(&sink, map(cur), stroke_only);
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
                    begin(&sink, map((x, y)), stroke_only);
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
                    line(&sink, map((x, y)));
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
                    line(&sink, map((x, cur.1)));
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
                    line(&sink, map((cur.0, y)));
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
                    curve(&sink, map(a), map((b1x, b1y)), map((ex, ey)));
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
                    curve(&sink, map(c1), map(c2n), map((ex, ey)));
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
                        line(&sink, map((ex, ey)));
                    } else {
                        for (c1, c2n, p) in arcs {
                            curve(&sink, map(c1), map(c2n), map(p));
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
