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

### 8.7 双模式插件（第七十九轮）：既是插件，也能独立运行

`plugins\*.py` 插件可以同时是**一个能 `python xxx.py` 直接跑起来的独立程序**。机制（三块都有才算数）：

1. **文件头**（必须在第一个宿主 import 之前——`import ui` 等在模块级，不先修 sys.path 独立跑直接 ImportError）：

   ```python
   if __name__ == '__main__':
       import os as _os, sys as _sys
       _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))
   ```

2. **清单识别标记**：模块级 `STANDALONE = True`（插件管理器据此显示 `py·双模`；`main._py_plugin_meta_static` 用正则读它，不 import）。

3. **文件尾**（共享引导层 `plugins\_standalone.py`；**名字以 `_` 开头是故意的**——装载器跳过它，不会当插件收）：

   ```python
   if __name__ == '__main__':
       import _standalone
       _standalone.standalone(run, NAME)
   ```

宿主装载时 `__name__` 是合成模块名（不是 `'__main__'`），三块都不执行，与装载行为零冲突。独立运行时引导层做：补 sys.path（宿主目录）→ 挂内嵌第三方 zip（`%LOCALAPPDATA%\wgime-py\site\thirdparty.zip`，pypdf 等）→ 建隐藏 Tk root → `run()` 建窗 → 窗口关即退出。回归：`python wgime-py-pure\tests\standalone-plugin-test.py`（真把每个插件当独立程序跑；`WGIME_STANDALONE_AUTOEXIT_MS` 是测试钩子，到点自动关窗）。


### 8.8 把普通单文件 Python 应用改造成插件（第八十一轮）

**可跑模板**：`wgime-py-pure\plugins\_example-plugin.py`。文件名以 `_` 开头 ⇒ **装载器不装载它**
（插件管理器里看不到、也不占启动编码）；当插件用就复制成 `插件目录\myplugin.py` 并改 `CODE`。
独立运行：`python wgime-py-pure\plugins\_example-plugin.py`。

#### 装载契约（`main.load_py_plugins()`）

| 项 | 要求 |
|---|---|
| 位置 | `plugins\*.py`，扫**两个目录**：脚本目录 `BASE\plugins` 与分发/配置目录 `APP_DIR\plugins` |
| 必需 | 模块级 `CODE`（非空）+ **可调用的 `run()`**；缺一即整份丢弃（日志 `plugin load err ...`） |
| 装载方式 | `importlib` 以合成名 `wgime_ext_<hash>_<文件名>` exec ⇒ **模块级代码在输入法启动时就执行** |
| 跳过 | `_` 开头的文件；`plugins-disabled.txt` 里的小写文件名（判断在 exec **之前**） |
| 触发 | 把 `CODE` 当启动编码打进去 → 候选条出启动器候选 → 上屏 → `run_launcher()` → 权限确认 → `run()` |
| 线程 | **`run()` 跑在 Tk 主线程且同步执行**：慢活儿自己开线程，否则打字停摆 |

> **`.py` 与 `.txt` 的插件目录不一样（有意为之，别踩）**：`.py` 插件 `BASE\plugins` 与 `APP_DIR\plugins`
> **两个都扫**；`.txt` 插件**只**从 `APP_DIR\plugins` 读（`main.reload_plugins()` 调
> `plugins.py load_plugins(APP_DIR\plugins)`）。开发版 `BASE = wgime-py-pure\`、`APP_DIR =` 仓库根
> （码表所在目录）；分发版两者都是成品目录。所以「与 C# 版兼容的 txt 插件」放仓库根 `plugins\`，
> 「纯 Python 插件」放 `wgime-py-pure\plugins\` 最自然。

#### 五步改造

1. 补清单：`CODE` / `NAME` / `DESC` / `VERSION` / `AUTHOR` / `PERM`。
2. 入口改名：`if __name__ == '__main__': main()` → `def run():`（无参）。
3. **删掉自己的 `tk.Tk()` 和 `mainloop()`** —— 宿主已有 Tk root；窗口改用
   `ui.make_window(title, w, h, on_close=None)`，返回 `(win, content)`，`content` 的坐标原点在标题栏下方
   （标题栏固定 38px；所以窗口高度 = 内容真正需要的高度 + 38）。
4. 不要 `sys.exit()`；关窗只 `win.destroy()`。
5. 慢活儿开 `threading.Thread(..., daemon=True)`，**后台异常自己兜住**（pythonw 下 `sys.stdout/stderr` 都是
   `None`，裸线程抛异常完全无声）。

`ui` 可用 API：`make_window` / `flat_button(parent, text, command, primary=False, x, y, w, h)` /
`console_text(..., scrollbar=True)` / `rounded_entry(..., initial='')` / `font(size, bold=False, mono=False)` /
配色 `BG CARD TEXT SUB BORDER HEADER RED`。示例见模板文件。

#### 不想改原程序的两条替代路线

- **txt 插件拉起外部程序**：`plugins\xxx.txt` 写头部 `code`/`name` + 步骤 DSL，如
  `run python "C:\Tools\myapp\app.py"`（静默运行并等结束，输出/退出码入日志）或 `open "...\app.py"`（不等待）。
  零改造，但它是**独立进程**、没有 WgIme 外观，也不能与输入法共享状态。
- **`[python]` 块**：整段在**子进程**里跑（超时 60s 熔断）；定义了 `handle(ctx) -> actions` 就走 JSON IPC（§8.3）。
- **插件壳**：`.py` 插件的 `run()` 里只 `subprocess.Popen([sys.executable, ...], creationflags=0x08000000)`
  把原程序拉起来 —— 原程序一行不改，同时又是个正规插件（`0x08000000` = `CREATE_NO_WINDOW`，免黑框）。

#### 陷阱

1. **模块级代码在输入法启动时就执行**（用户可能永不点它）—— 别在模块级建窗口/连网/读大文件；重初始化搬进 `run()`。
2. `PERM` 非 `low` 会在运行前弹权限确认：`network` / `run` / `registry` / `destructive`（支持 `network,run` 多值）。
3. 文件 **UTF-8 无 BOM + LF**；脚本改 `.py` 要用二进制写（AGENTS.md §30），否则整文件变 diff。
4. 读用户可改的文本用 `engine.read_text()`（GBK 容错，见 AGENTS.md §28）。
5. 第三方库：内嵌的是**纯 Python**（如 `pypdf`）；**C 扩展内嵌不了**（`numpy`/`PIL`…），只能"装了就用、没装报人话"。
6. 改了宿主模块（`main`/`ui`/`engine`…）要重建 dist；**只改插件不用** —— 插件不内嵌进单文件。

回归：`python wgime-py-pure\tests\example-plugin-test.py`（模板契约 + `_` 前缀不被装载 + `run()` 真建窗 +
独立运行 + 文档一致性；无桌面时后两项 SKIP）。

### 8.9 重依赖 GUI 程序怎么接（薄包装 + 下划线载荷）

不是所有程序都能按 §8.8 那样直接写成 `plugins\*.py`。典型反例是 **Qt（PySide6/PyQt）** 程序：

- PySide6 是**巨型 C 扩展**，内嵌不进单文件发行版（§12 的 C 扩展边界）；
- 它的 `import PySide6` 常在**模块级**，而且往往还带一句模块级的依赖自举（缺包就自己 pip 装、装不上直接退出）；
- Qt 与宿主的 Tk **不能共用主线程事件循环**。

这类程序一律用「**薄包装 + 下划线载荷**」：

1. **载荷**（原程序，**一个字节都不用改**）放 `plugins\_xxx_app.py` —— 名字以 `_` 开头，
   `load_py_plugins()` 会跳过它（§8.1/§8.8），于是它**不会被输入法启动时 exec**：
   既不拖慢启动，也不会因为缺依赖而让插件静默消失。它同时**不进** `tests\undefined-globals.py`
   的扫描（第三方生成物的嵌套作用域会被 symtable 误判），需要在该文件的 `SKIP_FILES` 里登记一行。
2. **薄插件** `plugins\xxx.py` 只做三件事：声明清单（`CODE/NAME/DESC/...`）、检查重依赖、
   用**独立进程**把载荷拉起来（`subprocess.Popen` + `CREATE_NO_WINDOW`，`pythonw.exe` 优先）。
   宿主入口 `run()` 必须**立刻返回**（它在 Tk 主线程里同步调）。
3. 依赖检查要给**人话出口**：缺依赖时发气泡说明装法（走 wgime 的依赖自检 `deps`，或 `pip install`），
   **不要**在插件里悄悄装几百 MB。
4. 把私有依赖目录（`%LOCALAPPDATA%\wgime-py\site\pip`）塞进子进程的 `PYTHONPATH` ——
   否则用 wgime 依赖自检装出来的包，子进程看不见。
5. 独立运行（`python xxx.py`）也走载荷；回归里给一条 `--check-deps` 之类的**不出界面**的自检路径，
   免得测试真的弹全屏窗口。

参考实现：`plugins\pyshot.py` + `plugins\_pyshot_app.py`（PyShot 截图工具），
回归 `wgime-py-pure\tests\pyshot-plugin-test.py`。

