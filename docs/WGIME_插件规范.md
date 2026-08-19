# WgIme 插件规范

> 版本：2026-08　插件目录：`plugins\*.txt`（与 `wgime.bat` 同级）
> 管理界面：输入 `plugins`（或 `cjgl`）唤出——列表/重载/编辑/删除/新建模板/打开目录。**有意不进托盘菜单**，和工具箱一样只用编码唤出。

## 1. 插件是什么

插件是一个**纯文本文件**，把一个"启动编码"绑定到一组执行步骤。放入 `plugins\` 目录后无需重启——托盘"配置 → 重载配置"即生效：

```
输入 code  →  候选条出现 ▶<name>  →  空格/数字选中  →  后台依次执行步骤  →  气泡提示结果
```

插件复用工具箱（`tools.txt`）的**步骤 DSL**，外加三行头部元数据。

## 2. 文件格式

```ini
; 注释行（; 或 # 开头），空行忽略
code = qls              ; 启动编码，小写 a-z，必填，唯一（与内置/其他插件冲突时插件优先）
name = 清空回收站        ; 显示名，必填
desc = 一句话说明        ; 可选（目前仅作文档）

<步骤行>                ; 头部之后、直到文件末尾，全部为步骤，从上到下依次执行
```

- 头部只认 `code` / `name` / `desc` 三个键（`=` 或 `:` 分隔均可），**必须在步骤之前**。
- 第一个非"键=值"、非注释、非空的行开始即为步骤区。

## 3. 步骤 DSL（与 tools.txt 完全一致）

| 动词 | 说明 |
|---|---|
| `msg 文本` | 气泡提示 |
| `confirm 文本` | 确认框；选"否"**中止**该插件后续步骤 |
| `run <程序> [参数...]` | 静默运行并等待结束（输出/退出码入日志） |
| `shell <cmd 命令行>` | `cmd /c` 单行静默执行 |
| `shellx <cmd 命令行>` | 同 `shell` 但弹**可见控制台窗口**（交互式命令用），等窗口关闭 |
| `open <目标>` | 系统默认方式打开（程序/文件夹/网址），不等待 |
| `kill <进程名>` | 结束进程 |
| `wait <毫秒>` | 等待 |
| `reg-set <键> <值名> <类型> <数据>` | 写注册表（HKCU/HKLM/HKCR/HKU/HKCC；类型 string/expand/dword/qword/multi(`|`分隔)/binary(十六进制)；值名 `-` = 默认） |
| `reg-del <键> [值名]` | 删值或整键（含子键） |
| `file-del <路径>` | 删文件/目录（通配符、目录递归；占用/无权限的**自动跳过**并记日志，不中断；**拒绝盘符根目录**） |
| `mkdir <路径>` | 建目录 |

**多行脚本块**（块内每行不需要动词前缀）：

```
[shell] ... [/shell]              ; cmd 批处理（临时 .cmd，ANSI）
[powershell] ... [/powershell]    ; PowerShell（临时 .ps1，UTF-8 BOM + UTF-8 输出，中文安全）
; 简写: [cmd] / [ps]
[shellx] ... [/shellx]            ; 交互式版本：弹可见控制台窗口，可 read/choice/pause，
[psx] ... [/psx]                  ; 脚本结束后窗口停留，按键关闭（等窗口关闭后记退出码）
```

参数支持 `"引号"` 和 `%环境变量%`。

## 4. C# 代码插件（[csharp] 块）

插件不只限于步骤 DSL——`[csharp] ... [/csharp]` 块里可以直接写 **C# 源码**（含 WinForms 窗体），加载时 CodeDom 内存编译，选中即运行：

```ini
code = sz
name = 悬浮时钟

[csharp]
using System;
using System.Windows.Forms;

public class ClockPlugin
{
    public static void Run()
    {
        var f = new Form { Text = "clock", TopMost = true };
        f.Show();                       // 直接 Show 即可: 运行在 WgIme 的 UI 线程/消息循环上
    }
}
[/csharp]
```

**契约与规则**：

1. 源码里必须有一个类带 **`public static void Run()`** 入口（第一个匹配的类型生效）。
2. `Run()` 在**插件专用 STA 线程**（`WgImePlugins`，独立消息循环）上被调用：`new Form().Show()` 直接可用；**插件阻塞/死循环只会卡住它自己的窗体，不会影响输入法打字**——写长任务是安全的（但插件自己的窗体会失去响应）。
3. 编译引用：`System` / `System.Windows.Forms` / `System.Drawing` / `System.Core` / `System.Data`（mscorlib 默认）+ **WPF**（`WindowsBase` / `PresentationCore` / `PresentationFramework` / `System.Xaml`，GAC 全路径解析）。**C# 5 语法**（.NET 4.x 的 CodeDom：没有字符串插值、out var、?.）。
   - **WPF 窗体**：直接 `new System.Windows.Window { ... }.Show()` 即可（纯代码方式，无需 XAML；插件线程的 WinForms 消息泵同时服务 WPF Dispatcher）。
4. `[csharp]` 块与步骤 DSL **不混用**：有 csharp 块就是代码插件，步骤区忽略。
5. 编译错误不会炸宿主：插件照常出现在候选里，选中时气泡报编译错误（含行号）。
6. 示例：`plugins\clock.txt`（输入 `sz` 弹出置顶小时钟）。
7. 插件是**任意代码执行**——只放你自己写的/看得懂的插件文件。

## 5. 执行语义

- 步骤**后台线程**执行，不阻塞输入法；`confirm` 弹窗在 UI 线程。
- 单个步骤失败只记数不中断；`confirm` 选否才中断。
- 执行开始/完成/失败数通过托盘气泡反馈。
- 插件步骤的输出日志：需要详细日志的操作请改用工具箱（`itools`）里的按钮，或自己在脚本里 `Out-File` 落盘。

## 6. 编码冲突与优先级

启动编码注册顺序：内置（jsq/calc/itools/tools/net/wlgj/clip/jlb/bj/notes/ys/color）→ config.txt 的 `app =` 条目 → **插件**（最后注册，冲突时插件覆盖前者）。

## 7. 写插件的建议

1. **破坏性操作务必先 `confirm`**（file-del / reg-del / kill）。
2. 步骤尽量幂等；失败可重入。
3. 长任务用 `msg` 在开头结尾各报一次进度。
4. 需要交互输入的：用 `[csharp]` 块弹个窗体做交互（步骤 DSL 无输入动词，`Read-Host` 无控制台不可用）。
5. 调试：先把步骤贴进 `tools.txt` 的测试按钮里看日志，跑通后再落成插件文件；C# 插件可先用 LINQPad/本地 csc 验证语法。
