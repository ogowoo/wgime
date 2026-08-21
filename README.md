# WgIme + WgTray — 免安装的单文件输入法与托盘工具箱

**WgIme**：免安装的单文件悬浮输入法 —— 支持拼音 / 五笔 / 混合 / 英汉词典四种模式，带词频学习、简拼、模糊音、造词、码表导入与固化、整句连打、应用启动器、`tools.txt` 工具箱与 `plugins\*.txt` 插件。

**WgTray**：无输入法的托盘工具箱 —— 只有任务栏托盘菜单，完全复用 WgIme 的 `tools.txt` 工具箱、`plugins\*.txt` 插件与 `config.txt` 应用配置（无键盘钩子 / 无候选窗 / 无词典数据）。

两个程序各自都有 **bat 版（带载荷）** 与 **ps1 版** 两种形态，功能完全一致，按环境取舍：

| 文件 | 程序 | 形态 | 说明 | 体积 |
|---|---|---|---|---|
| `wgime.bat` | WgIme | **bat 版（带载荷）** | cmd 引导 + 内嵌 C# 源码 + 内嵌基础码表，启动时内存编译 | ~3.3MB |
| `WgIme.ps1` | WgIme | **ps1 版** | PS 引导 + 内嵌 base64 预编译 DLL（含全部词库/图标/emoji 资源），运行时解出加载 | ~39MB |
| `wgtray.bat` | WgTray | **bat 版（带载荷）** | cmd 引导 + 内嵌 C# + 预编译 DLL 载荷，所有机器可跑（含受限语言模式机器） | ~380KB |
| `wgtray-nopayload.bat` | WgTray | bat 纯源码版 | 只有 C# 源码明文，启动时内存编译，杀软检测面更小 | ~227KB |
| `WgTray.ps1` | WgTray | **ps1 版** | PS 引导 + 内嵌 base64 预编译 DLL，运行时解出加载 | ~380KB |

> **bat 版 vs ps1 版**：bat 版靠 cmd 引导双击即用（`wgime.bat` 内嵌基础码表自包含）；ps1 版启动命令行只有 `powershell -File xxx.ps1`（无 `Add-Type`/`.dll`/`::Run` 明文），规避 EDR 对"隐藏 PowerShell 加载 DLL"行为模式的命令行告警。取含详见下文「bat 版 vs ps1 版」。

A single-file, install-free overlay IME (pinyin / wubi / mixed / EN-CN dictionary) plus a tray-only toolbox for Windows — each available as a bat edition (embedded payload) and a ps1 edition (embedded base64 prebuilt DLL).

## WgIme 输入法

- **全单字内嵌**：内置拼音 26,719 字 / 五笔 17,366 字（BMP CJK + 〇 + 扩展A区基本打尽）——删掉所有 txt 词库文件照样能打出几乎所有汉字；txt 提供词语与排序
- **四种模式**：混合（默认，五笔优先补拼音）/ 拼音 / 五笔 / 英汉词典
- **智能输入**：整句连打（`nihaoshijie` → 你好世界，6 万词表 + 词频最佳路径）、联想（学习个人习惯、可连续联想）、词频学习、简拼（`zg` → 中国）、模糊音（zh/z、ang/an、n/l…）、双拼（小鹤/自然码/微软）、以词定字
- **造词**：手动（Ctrl+Alt+C）/ 批量（文件导入）/ 自动（90 秒内连续选字自动组词）
- **码表导入**：Rime `*.dict.yaml`、编码在前/词在前 txt、英汉词表，自动识别 UTF-8/GB18030，热重载
- **固化码表**：一键把合并词库烘焙进 bat 内置表（滚动 7 份备份），之后可删除 txt 源文件
- **应用启动器**：编码唤出应用——内置 `jsq` 计算器 / `itools` 工具箱 / `net` 网络工具 / `clip` 剪贴板历史 / `bj` 便签 / `ys` 颜色拾取 / `plugins` 插件管理；config.txt 可挂任意程序/目录/网址
- **更多**：中文标点、vf 符号/emoji 面板（彩色 Fluent emoji）、v 模式（大写金额/千分位）、简繁切换、rq/sj/xq 动态候选、五笔 z 通配符、反查编码、自定义短语、快捷键全配置化、候选窗光标跟随（UIA 三级回退）、空闲自动隐藏、微信 4.x 等 Qt 应用标点吞字修复（keyfix）

## WgTray 托盘菜单

- **工具箱…** —— `tools.txt` 驱动的多标签工具窗体（`[tab 标签页]` / `[cols 列数]` / `[按钮名]` / 步骤行；支持 `msg/confirm/run/shell/shellx/open/kill/wait/reg-set/reg-del/file-del/mkdir` 与 `[shell]`/`[powershell]`/`[shellx]`/`[psx]` 多行块，详见 tools.txt 文件头注释）
- **插件** —— `plugins\*.txt` 里启用的插件（步骤 DSL 与 `[csharp]` 代码插件都支持）+ **插件管理**（运行/列表/启用禁用/编辑/删除/新建模板/打开目录）
- **内置工具** —— 计算器（plugins\calc.txt）/ 网络工具（ping/tracert/DNS/HTTP/端口/子网计算）/ 剪贴板历史 / 便签 / 颜色拾取
- **应用 (config.txt)** —— `app = 编码 名称 命令` 条目
- **配置** —— 编辑 config.txt / 重载配置 / **开机自启**（计划任务 schtasks ONLOGON）/ 数据目录
- **全局快捷键** —— `Ctrl+Alt+T` 工具箱 / `Ctrl+Alt+P` 插件管理 / `Ctrl+Alt+W` 光标处菜单，config.txt 的 `hotkey_*` 键可改（`none` 禁用）

## 开机自启（计划任务，非 Startup 快捷方式）

各运行一次注册登录时启动的计划任务（schtasks ONLOGON）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1 -Install
powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgTray.ps1 -Install
```

取消自启：相应 ps1 加 `-RemoveTask`。托盘菜单「开机自启」开关也走同一计划任务（WgIme 菜单：顶部勾选项；WgTray 菜单：配置 → 开机自启）。

## 快速开始

1. 双击 `wgime.bat`（输入法，托盘出现"中"字图标）/ 双击 `wgtray.bat`（托盘工具箱，托盘出现"工"字图标）；ps1 版用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1`（或 `WgTray.ps1`）
2. 首次运行自动播种 `tools.txt` / `plugins\` / `config.txt` 示例（不覆盖已有文件）
3. 输入法：任意文本框输入拼音/五笔，候选条跟随光标出现（`Shift` 轻点开关，`` Ctrl+` `` 切换模式）
4. 改完 tools.txt / plugins / config.txt 后：托盘菜单 **配置 → 重载配置** 即时生效
5. 数据目录 `%LOCALAPPDATA%\wgime`（插件禁用记录、便签、颜色设置等；删除即恢复初始状态）

## 构建与测试（Windows PowerShell 5.1）

```powershell
# WgIme ps1 版（从 wgime.bat 提取 C# 编译 DLL + 组包）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-ps1.ps1
# WgTray 各版（从 wgime.bat 切分复用代码；默认输出 WgTray.ps1）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1            # WgTray.ps1（ps1 版，带载荷）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1 -Bat       # wgtray.bat（bat 版，带预编译 DLL 载荷）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1 -Bat -NoPayload   # wgtray-nopayload.bat（bat 纯源码版）
# 修改 wgtray.bat 内嵌 C# 后重建 DLL 载荷
powershell.exe -NoProfile -ExecutionPolicy Bypass -File rebuild-tray.ps1
# 测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1   # WgIme ps1 版回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1  # WgTray ps1 版回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray.tests.ps1      # WgTray 两版回归
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\check-tray-payload-consistency.ps1
```

> `wgime.bat`（bat 版主源，含全部 C# 与基础码表）已入库；`build-wgime-ps1.ps1` / `build-wgtray.ps1` 都从它提取/切分代码。根目录 `py.txt`/`wb.txt`/`ec.txt`/`import_*.txt` 是本地构建用扩展码表（gitignored，全部词库已编入 `WgIme.ps1` 载荷与 wgime.bat 基础表）。

## bat 版 vs ps1 版（取舍分析）

两套形态功能完全一致（同一套代码、同一套测试），区别只在"程序集怎么来"与"启动命令行长什么样"：

**bat 版（带载荷）**
- 程序集 = bat 内嵌的 base64 预编译 DLL（WgTray）/ 内嵌 C# 源码 + 基础码表（WgIme），双击即用
- 优点：双击直接跑（cmd 引导）、无 `-File` 命令行依赖；WgTray 带载荷版所有机器都能启动（受限语言模式机器）
- 缺点：cmd 引导 + 内嵌 blob 是杀软经典扫描模式，误报面比 ps1 版大

**ps1 版**
- 程序集 = ps1 内嵌的 base64 预编译 DLL，运行时解出到 `%LOCALAPPDATA%\wgime\*.dll` 加载
- 优点：启动命令行只有 `powershell -File xxx.ps1`，没有 `Add-Type`/`.dll`/`::Run` 明文——规避 EDR 对"隐藏 PowerShell 加载 DLL"的命令行告警（Cisco 等安全软件环境下更安静）
- 缺点：需要 PowerShell 调用方式启动（双击默认用 notepad 打开，需右键"使用 PowerShell 运行"或走计划任务/install.bat）

**建议**：要双击即用 → bat 版；在意安全软件命令行告警（如公司机）→ ps1 版 + 计划任务自启。

## 分发（wg-all/）

`wg-all\` 是合并分发目录：`install.bat`（all/ime/tray 三种模式）+ `WgIme.ps1` + `WgTray.ps1` + `config.txt` + `tools.txt` + `plugins\` + `README.txt`。只发行 ps1 版，不产生任何 .dll/.bat 启动器/快捷方式。

## 文件说明

| 文件 | 作用 |
|---|---|
| `wgime.bat` | WgIme 程序本体 + 构建主源（bat 版带载荷，内嵌 C# + 基础码表；纯 CRLF 无 BOM） |
| `WgIme.ps1` | WgIme ps1 版（PS 引导 + 内嵌 base64 预编译 DLL） |
| `wgtray.bat` | WgTray 程序本体（带预编译 DLL 载荷版，保底所有机器） |
| `wgtray-nopayload.bat` | WgTray 纯源码版（启动内存编译，杀软检测面小） |
| `WgTray.ps1` | WgTray ps1 版（PS 引导 + 内嵌 base64 预编译 DLL） |
| `config.txt` | 共用配置（WgIme 输入法键 + WgTray 的 app=/hotkey_*；互相兼容） |
| `tools.txt` | 工具箱配置（`[tab 标签页]` / `[按钮名]` / `code = xxx` 启动编码 / 步骤行） |
| `plugins/` | 插件目录（步骤 DSL / C# 插件；规范见 [docs/WGIME_插件规范.md](docs/WGIME_插件规范.md)、UI 风格见 [docs/WGIME_插件UI规范.md](docs/WGIME_插件UI规范.md)） |
| `build-wgime-ps1.ps1` | 从 wgime.bat 构建 WgIme.ps1（编译 DLL + base64 嵌入 + wg-all 同步） |
| `build-wgtray.ps1` | 生成 wgtray.bat / wgtray-nopayload.bat / WgTray.ps1（从 wgime.bat 切分复用代码） |
| `rebuild-tray.ps1` | 修改 wgtray.bat 内嵌 C# 后重建 DLL 载荷（Windows PowerShell 5.1） |
| `wgtray_glue.cs.txt` / `wgtray_ps_body.txt` / `wgtray_seed_patches.txt` | WgTray 构建模板（UTF-8；构建脚本本身保持 ASCII，兼容 PS 5.1 的 ANSI 解析） |
| `vt-scan.ps1` | VirusTotal 一键扫描脚本（wg-all 分发文件） |
| `tests/` | 回归测试（wgime-ps1 / wgtray-ps1 / wgtray 两版 / 载荷一致性） |
| `wg-all/` | 合并分发目录（install.bat + 双 ps1 版 + 配置/插件/README） |
| `docs/` | 插件规范与 UI 规范 |

## 开发

- 修改输入法/工具箱 C# 一律改 `wgime.bat`（唯一源码真身）；`build-wgime-ps1.ps1` 重新出 ps1 版
- 修改 wgtray.bat 内嵌 C# 后运行 `rebuild-tray.ps1`；改动托盘壳（wgtray_glue.cs.txt）/ 引导段（wgtray_ps_body.txt）后运行 `build-wgtray.ps1` 整体重建
- 运行测试：`tests\wgime-ps1.tests.ps1` + `tests\wgtray-ps1.tests.ps1` + `tests\wgtray.tests.ps1`
- 文件约束：wgime.bat / wgtray.bat 纯 CRLF / 无 BOM（cmd.exe 依赖 CRLF 解析批处理头，见 .gitattributes）；.ps1 构建脚本保持 ASCII（Windows PS 5.1 按 ANSI 读取），非 ASCII 内容一律放 UTF-8 模板

## 系统要求

Windows 10/11，Windows PowerShell 5.1（系统自带），无需安装。

## License

代码部分（`wgime.bat`、`wgtray.bat`、构建脚本、`tests/`、`docs/`）遵循 MIT 协议，详情见各文件头注释。随附的插件示例（`plugins/`）仅限个人使用，分发前请确认各自许可。
