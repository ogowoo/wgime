# WgIme 窗体设计语言（v1.1）

> 适用范围：`plugins\*.txt` 的 `[csharp]` 代码插件（WinForms 或 WPF），以及内置工具箱/便签/网络工具等 WgIme 家族窗体。本规范把 clock/calc 两个官方插件与内置工具箱/便签/网络工具共用的一套设计语言沉淀下来，新窗体照抄即可与整体风格一致。
> 相关：`docs/WGIME_插件规范.md`（插件格式与执行语义）。

---

## 1. 设计语言一句话

**浅蓝灰底 + 白色卡片 + 深色控制台 + 圆角 + 细滚动条**。窗口一律无边框圆角、显式坐标布局、自定义标题栏。

## 2. 色板（直接抄）

```csharp
static Color C_BG     = Color.FromArgb(255, 232, 237, 245);   // #E8EDF5 窗体底色（浅蓝灰）
static Color C_HEADER = Color.FromArgb(255, 220, 227, 239);   // 标题栏（深一档蓝灰）
static Color C_CARD   = Color.FromArgb(255, 255, 255, 255);   // 卡片/按钮/输入框
static Color C_SURF2  = Color.FromArgb(255, 217, 224, 236);   // 凹槽/轨道/次要按钮
static Color C_BORDER = Color.FromArgb(255, 195, 204, 221);   // 发丝描边
static Color C_TEXT   = Color.FromArgb(255, 29, 29, 31);      // 正文
static Color C_SUB    = Color.FromArgb(255, 110, 116, 133);   // 次要文字
static Color C_ACCENT = Color.FromArgb(255, 0, 122, 255);     // systemBlue 强调
static Color C_CONBG  = Color.FromArgb(255, 46, 48, 64);      // 深色控制台底
static Color C_CONFG  = Color.FromArgb(255, 214, 217, 226);   // 控制台文字

// 页面主题色（按需取用, Apple 系统色系）
static Color C_GREEN  = Color.FromArgb(255, 52, 199, 89);     // systemGreen
static Color C_ORANGE = Color.FromArgb(255, 255, 149, 0);     // systemOrange
static Color C_BLUE   = Color.FromArgb(255, 48, 176, 199);    // systemTeal
static Color C_RED    = Color.FromArgb(255, 255, 55, 95);     // systemPink
```

规则：底色必须有色调（纯白窗在桌面一堆白窗里认不出来）；按钮/输入框一律白色卡片浮在蓝灰底上；日志/输出区用深色控制台。

## 3. 字体

回退链，缺一自动降档：

```csharp
static Font F(float size, FontStyle st)
{
    string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
    foreach (string n in names) { try { return new Font(n, size, st, GraphicsUnit.Point); } catch {} }
    return new Font(FontFamily.GenericSansSerif, size, st, GraphicsUnit.Point);
}
```

字号约定：标题 10 Bold / 正文 9.5 / 次要 8.5 / 大数字 26-40 / 控制台 Consolas 9-9.5。

## 4. 标准窗体骨架

```csharp
var f = new Form();
f.Text = "WgIme XXX";                    // 窗口标识 (测试/alt-tab 用, 标题由自绘标题栏承担)
f.FormBorderStyle = FormBorderStyle.None;
f.AutoScaleMode = AutoScaleMode.None;    // 像素级布局, 禁止 DPI 自动缩放扭曲
f.ClientSize = new Size(400, 400);
f.BackColor = C_BG; f.TopMost = true; f.KeyPreview = true; f.ShowInTaskbar = false;
f.StartPosition = FormStartPosition.CenterScreen;

// 圆角: GDI 原生 Rgn (别用 GraphicsPath->Region, 角落有锯齿残点)
EventHandler rg = delegate { try { SetWindowRgn(f.Handle, CreateRoundRectRgn(0, 0, f.Width + 1, f.Height + 1, 20, 20), true); } catch {} };
f.HandleCreated += delegate { rg(f, EventArgs.Empty); };
f.Resize += delegate { rg(f, EventArgs.Empty); };

// 描边内缩 1px (抗锯齿不碰裁剪边界, 否则角落出深色杂点)
f.Paint += delegate(object s, PaintEventArgs e) {
    var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
    using (var path = RoundRect(new Rectangle(1, 1, f.Width - 3, f.Height - 3), 9))
    using (var pen = new Pen(C_BORDER, 1)) { g.DrawPath(pen, path); }
};
f.KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) f.Close(); };
```

**布局铁律：一律显式坐标，不用 Dock**。Dock 的停靠顺序由 z-order 决定，被 `BringToFront` 打乱后会静默错位（标题栏跑到标签栏下面的真实事故）。

## 5. 标准控件

### 5.1 标题栏（可拖动 + ✕）

```csharp
var title = new Panel { Location = new Point(0, 0), Size = new Size(400, 38), BackColor = C_HEADER };
// ✕: Label, 悬停 BackColor = Color.FromArgb(255,232,17,35) + 白字, 离开还原
// 拖动: title.MouseDown -> ReleaseCapture(); SendMessage(f.Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero);
// 底边发丝线: title.Paint 里 DrawLine(C_BORDER, 0, h-1, w, h-1)
```

### 5.2 扁平按钮（**必须 Panel 基类**）

```csharp
class FlatBtn : Panel    // 禁用 Button 基类: 原生主题镶边会在运行一段时间后渗出黑角
{
    public Color Bg = C_CARD...;  // 普通按钮白卡, 次要按钮 C_SURF2
    public bool Primary;          // 主操作: systemBlue 实心填充白字 (悬停提亮/按下压暗)
    public bool AccentLine, Selected;   // 标签页模式: 选中时 3px accent 下划线
    // DoubleBuffered = true; Cursor = Hand;
    // OnPaint: 先 Parent.BackColor 填满整个矩形(否则圆角外四角露出下层内容),
    //          再 RoundRect(rect, 7) 填充, 最后居中 DrawString
    // 状态: hover / down / !Enabled(置灰)
}
```

### 5.3 圆角输入框（RoundedEdit）

原生 TextBox 永远是直角。做法：Panel 容器（圆角白底 + 描边）内嵌无边框 TextBox，**聚焦时描边变 accent 2px**。Padding(9,4,9,3)。

### 5.4 深色控制台 + 细滚动条

- TextBox：`ScrollBars = None`、无边框、C_CONBG/C_CONFG、Consolas 9.5
- 滚动条：右侧 10px 自绘条（6px 圆角滑块），`EM_GETLINECOUNT(0xBA)` / `EM_GETFIRSTVISIBLELINE(0xCE)` / `EM_LINESCROLL(0xB6)` 同步；支持拖拽滑块、点轨道翻页
- **同步定时器只在首尾行号变化时才 Invalidate**（每 tick 无条件重绘会抖动）；面板开 DoubleBuffered
- 内容一屏放得下时不画滑块

### 5.5 标签页

自定义标签条（不用系统 TabControl）：一排 FlatBtn（AccentLine 模式）+ 每页一个 Panel，点击切换 `Selected`/`Visible`。

## 6. 踩坑清单（都是真实修过的）

| 坑 | 现象 | 对策 |
|---|---|---|
| Dock + BringToFront | 标题栏跑到标签栏下面 | 一律显式坐标 |
| Button 基类自绘按钮 | 运行一段时间后角上渗黑块 | **Panel 基类**（NCPAINT 抑制不彻底） |
| 透明面板叠文字标签 | 真实屏幕上文字消失（DrawToBitmap 里却正常） | 文字画进面板自己的 Paint |
| 圆角按钮只画圆角路径 | 四角露出下层内容 | 先用父背景色填满整个矩形 |
| GraphicsPath→Region | 角落锯齿残点 | `CreateRoundRectRgn` + `SetWindowRgn` |
| 描边贴裁剪边 | 角落深色杂点 | 描边内缩 1px |
| DrawToBitmap 验证 | 与真实合成路径不同，问题测不出 | **用 `CopyFromScreen` 真实截屏验证**（绿底反衬 + 像素分析） |
| 颜色通道加减 | `Lighten(c, -12)` 出 -2 崩溃 | 双向钳 0~255 |
| `DrawString` 点坐标重载 | 忽略 `StringFormat.Alignment`，文字右偏 | 用矩形区域重载居中 |
| AutoScaleMode=Font | 高 DPI 下像素布局错位 | `AutoScaleMode.None` |

## 7. WPF 插件

`[csharp]` 引用含 WPF 全套，可直接 `new System.Windows.Window().Show()`（纯代码，无需 XAML；插件线程的消息泵同时服务 Dispatcher）。WPF 插件同样建议沿用本规范的色板（`Color.FromRgb(232,237,245)` 底 / 白卡片 / `#007AFF` 强调）。

## 8. 最小骨架（复制即用）

见 `plugins\calc.txt`——它就是按本规范写的最小完整插件（264x356，标题栏/卡片显示区/4x5 磁贴/键盘处理），结构：

```
plugins\xxx.txt
  code = xx
  name = 名称
  desc = 一句话
  [csharp]
    色板 → F() → RoundRect → DllImport(Rgn/拖动) → FlatBtn(Panel) → (RoundedEdit) → Run(): 骨架窗体 + 内容
  [/csharp]
```

## 9. 验证要求

1. 插件能通过 CodeDom 编译（C# 5 语法）；
2. `CopyFromScreen` 真实截屏核验每个页面（不是 DrawToBitmap）；
3. 涉及圆角时做一次绿底反衬像素检查；
4. 长时间运行/反复悬停后再看一次（原生镶边渗出类问题只在运行后暴露）。
