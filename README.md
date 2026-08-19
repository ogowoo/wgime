# WgTray — 无输入法的托盘工具箱

**免安装的单文件托盘工具** —— 双击 `wgtray.bat` 即运行（任务栏托盘出现"工"字图标）。**没有输入法功能**（无键盘钩子 / 无候选窗 / 无词典数据，带载荷版约 380KB / 无载荷版约 227KB），**只有任务栏托盘菜单**，并完全兼容 WgIme 的 `tools.txt` 工具箱、`plugins\*.txt` 插件与 `config.txt` 应用配置。

A single-file, install-free tray-only toolbox for Windows: no IME — just a taskbar tray menu with a config-driven toolbox (tools.txt), a plugin system (plugins\*.txt, DSL or C#), built-in applets and global hotkeys.

## 托盘菜单

- **工具箱…** —— `tools.txt` 驱动的多标签工具窗体（`[tab 标签页]` / `[cols 列数]` / `[按钮名]` / 步骤行；支持 `msg/confirm/run/shell/shellx/open/kill/wait/reg-set/reg-del/file-del/mkdir` 与 `[shell]`/`[powershell]`/`[shellx]`/`[psx]` 多行块，详见 tools.txt 文件头注释）
- **插件** —— `plugins\*.txt` 里启用的插件（步骤 DSL 与 `[csharp]` 代码插件都支持，点插件名即执行）+ **插件管理**（**运行**按钮——管理器即插件的启动入口；另有列表/启用禁用/编辑/删除/新建模板/打开目录）
- **内置工具** —— 计算器（plugins\calc.txt）/ 网络工具（ping/tracert/DNS/HTTP/端口/子网计算）/ 剪贴板历史 / 便签 / 颜色拾取
- **应用 (config.txt)** —— config.txt 里 `app = 编码 名称 命令` 的条目
- **配置** —— 编辑 config.txt / 重载配置 / **开机自启**（勾选即创建/移除 `Startup\WgTray.lnk`）/ 数据目录
- **全局快捷键** —— 显示当前绑定，config.txt 的 `hotkey_*` 键可改（`none` 禁用）

## 全局快捷键

用 `RegisterHotKey`（系统级，非键盘钩子），默认：

| 快捷键 | 动作 |
|---|---|
| `Ctrl+Alt+T` | 打开工具箱 |
| `Ctrl+Alt+P` | 打开插件管理 |
| `Ctrl+Alt+W` | 在光标处显示托盘菜单 |

config.txt 可改：`hotkey_toolbox = ctrl+alt+t` / `hotkey_plugins = ...` / `hotkey_menu = ...`（格式 `ctrl/alt/shift/win + 键`，如 `ctrl+shift+m`；`none` 禁用）。

## 快速开始

1. 双击 `wgtray.bat`（托盘出现"工"字图标，首次运行自动播种 `tools.txt` 与 `plugins\` 示例，不覆盖已有文件）
2. 右键托盘图标打开菜单；改完 tools.txt / plugins / config.txt 后点 **配置 → 重载配置** 即时生效
3. 退出：菜单 → 退出；开机自启：配置 → 开机自启
4. 数据目录 `%LOCALAPPDATA%\wgime`（插件禁用记录、便签、颜色设置等；删除即恢复初始状态）

## 构建与测试（Windows PowerShell 5.1）

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1          # 重新生成 wgtray.bat（带预编译 DLL 载荷）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1 -NoPayload   # 无载荷版: 只有 C# 源码, 启动时内存编译
powershell.exe -NoProfile -ExecutionPolicy Bypass -File rebuild-tray.ps1          # 修改 wgtray.bat 内嵌 C# 后重建 DLL 载荷
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray.tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\check-tray-payload-consistency.ps1
```

> `wgtray.bat` 由 `build-wgtray.ps1` 从 WgIme 仓库（master 分支）的 `wgime.bat` 内嵌 C# 切分生成——本分支是 wgtray 的分发分支，不含输入法本体/词库/IME 文档。

### 关于预编译 DLL 载荷与杀软误报

`wgtray.bat` 默认内嵌一个 base64 预编译 DLL（用于受限语言模式机器——AppLocker/WDAC 策略禁止 PowerShell 内存编译时的兜底）。**这种"bat 内嵌 base64 PE + `FromBase64String` 落盘"模式正是恶意软件常用手法，部分启发式/EDR 杀软（如 Windows Defender 的 AMSI 扫描）可能误报**，尤其当脚本未签名、运行在用户可写目录时。

- **想要更低的检测面**：用 `-NoPayload` 构建（约 227KB）——不嵌 DLL、不含 `FromBase64String`，启动时直接内存编译 C# 源码（纯文本，可读）。代价：在受限语言模式机器上无法启动（`Add-Type` 被策略禁止）。
- 权衡：默认带载荷版保底所有机器（含学校/公司的锁定环境）；无载荷版更适合个人分发。两种版本功能完全一致。
- 附注：任何 bat+Powershell+内存编译的分发方式本身都会被部分杀软启发式关注，建议从可信位置运行、必要时对脚本做代码签名。

## 文件说明

| 文件 | 作用 |
|---|---|
| `wgtray.bat` | 程序本体（自包含；cmd 引导 + PowerShell + 内嵌 C# + 可选预编译 DLL 载荷） |
| `config.txt` | 用户配置（`app =` 应用条目 + `hotkey_*` 全局快捷键；首次运行自动播种模板） |
| `tools.txt` | 工具箱配置（`[tab 标签页]` / `[按钮名]` / 步骤行） |
| `plugins/` | 插件目录（步骤 DSL / C# 插件；规范见 [docs/WGIME_插件规范.md](docs/WGIME_插件规范.md)、UI 风格见 [docs/WGIME_插件UI规范.md](docs/WGIME_插件UI规范.md)） |
| `build-wgtray.ps1` | 生成 wgtray.bat（从 master 的 wgime.bat 切分复用代码 + 编译 + 组包；`-NoPayload` 出无载荷版） |
| `rebuild-tray.ps1` | 修改 wgtray.bat 内嵌 C# 后重建 DLL 载荷（Windows PowerShell 5.1） |
| `wgtray_glue.cs.txt` / `wgtray_ps_body.txt` / `wgtray_seed_patches.txt` | 构建模板（UTF-8；构建脚本本身保持 ASCII，兼容 PS 5.1 的 ANSI 解析） |
| `tests/wgtray.tests.ps1` | 回归测试（结构约束 / 无输入法代码保证 / tools 解析 / 插件与 config 加载 / 步骤引擎 / 网络工具 / CodeDom 编译 / 快捷键解析 / 真实启动冒烟） |
| `tests/check-tray-payload-consistency.ps1` | 内嵌 DLL 载荷与 C# 源码的 IL 一致性校验 |

## 开发

- 修改 wgtray.bat 内嵌 C# 后运行 `rebuild-tray.ps1`；改动托盘壳（wgtray_glue.cs.txt）/ 引导段（wgtray_ps_body.txt）后运行 `build-wgtray.ps1` 整体重建
- 运行测试：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray.tests.ps1` + `tests\check-tray-payload-consistency.ps1`
- 文件约束：wgtray.bat 纯 CRLF / 无 BOM（cmd.exe 依赖 CRLF 解析批处理头）；.ps1 脚本保持 ASCII（Windows PS 5.1 按 ANSI 读取），非 ASCII 内容一律放 UTF-8 模板

## 系统要求

Windows 10/11，Windows PowerShell 5.1（系统自带），无需安装。

## License

代码部分（`wgtray.bat`、构建脚本、`tests/`、`docs/`）遵循 MIT 协议，详情见各文件头注释。随附的插件示例（`plugins/`）仅限个人使用，分发前请确认各自许可。
