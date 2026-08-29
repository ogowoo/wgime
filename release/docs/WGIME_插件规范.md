# WgIme 插件规范

> 版本：2026-08　插件目录：`plugins\*.txt`（与 `wgime.bat` 同级）
> 管理界面：输入 `plugins`（或 `cjgl`）唤出——列表/重载/**启用·禁用**/编辑/删除/新建模板/打开目录（禁用存数据目录 `plugins-disabled.txt`，禁用的插件仍参与解析与编译状态展示、只是不注册进启动器）。**有意不进托盘菜单**，和工具箱一样只用编码唤出。
> 相关：`docs/WGIME_窗体设计语言.md`（窗体设计语言：色板/标准控件/踩坑清单/骨架）。

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
6. 随附插件：`plugins\clock.txt`（输入 `sz` 弹出置顶时钟，支持全屏强制休息等提醒方式）、`plugins\chat.txt`（输入 `lt` 弹聊天窗，MQTT over WebSocket + AES 加密，与 itools-chat 互通）；种子示例见 `plugins\calc.txt`（计算器）。
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

## 8. 纯 Python 版插件（wgime-py-pure）

纯 Python 版（单文件成品 `wgime-py-pure\dist\wgime-py.py`，`package\` 为分发目录；数据目录 `%LOCALAPPDATA%\wgime-py`，Store 版 Python 自动切 `%USERPROFILE%\wgime-py`）实现了**双插件系统**，与 C# 版功能对齐。加载器：`wgime-py-pure\plugins.py`（`parse_plugin` / `load_plugins` / `run_steps` / `plugin_meta`）；`plugins\*.py` 由 `main.load_py_plugins` 加载。

### 8.1 两种插件形态

1. **`plugins\*.py`——纯 Python 模块**：模块级定义 `CODE` / `NAME` / `DESC`（可选）/ `VERSION` / `AUTHOR` / `PERM` + 一个 `run()` 入口，选中即调用。
2. **`plugins\*.txt`——与 C# 版兼容**：步骤 DSL 插件 / `[python]` 块插件 / `[csharp]` 块（经 sidecar 运行，见 §8.4）。文件格式、头部元数据、启动编码冲突规则与 C# 版一致（见 §2、§6）。

### 8.2 步骤 DSL 兼容

txt 插件复用与 C# 版同一套步骤 DSL：

- 动词：`msg` / `confirm` / `run` / `shell` / `open` / `kill` / `wait` / `file-del` / `reg-set` / `reg-del` / `mkdir`。
- 多行脚本块：`[shell]` / `[powershell]` / `[shellx]` / `[psx]`。
- **另有 `[python]` 块**：Python 代码在**子进程**中运行（超时 60s 熔断），不会拖垮宿主——不要指望它与输入法同进程共享状态。

### 8.3 [python] 块 JSON IPC 契约

`[python] ... [/python]` 块里若定义了 **`handle(ctx) -> actions`**，则走 JSON IPC：

- 入参 `ctx = {"code": ..., "name": ..., "buff": ..., "mode": ...}`（启动编码、插件名、当前编码缓冲、当前模式）。
- 返回 actions 列表，如 `[{"action": "msg", "text": "..."}, {"action": "log", "text": "..."}]`——宿主逐项执行（气泡提示 / 记日志）。
- 通信走 stdout 的 `@wgime <json>` 行协议。
- **没有 `handle` 则当作普通脚本**：整段在子进程里 `run()` 执行，无 IPC。

### 8.4 [csharp] 块：sidecar 兼容

txt 插件里的 `[csharp]` 块在纯 Python 版**仍然可用**：经 sidecar 脚本 `run-csharp-plugin.ps1` 用 PowerShell + CodeDom 编译为**独立进程**弹窗运行。因此 C# 代码插件（如 clock/chat）在 Python 版也能跑，只是从"宿主内线程"变为"独立进程"。

### 8.5 Manifest 与权限模型

- `plugins\*.txt` 头部支持 `code` / `name` / `desc` / `version` / `author` / `requires` / `perm`；`plugins\*.py` 用模块级 `CODE` / `NAME` / `VERSION` / `AUTHOR` / `PERM`。`plugins.py` 的 `plugin_meta()` 统一读取两类。
- `perm` 取值：`low` / `network` / `run` / `registry` / `destructive`。**声明非 `low` 的插件运行前弹权限确认**；旧插件无这些字段默认 `perm=low`，不弹确认。
- 步骤 DSL 的 **`file-del` / `reg-set` / `reg-del` / `kill`** 执行前**强制确认**（与 C# 版"破坏性操作建议先 confirm"的精神一致，这里是硬强制）。

### 8.6 插件管理

与 C# 版相同：输入 `plugins`（或 `cjgl`）唤出**插件管理窗体**——勾选启用/禁用（禁用名单存数据目录 `plugins-disabled.txt`）、重载。同样有意不进托盘菜单，只用编码唤出。
