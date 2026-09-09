# WgIme — 免安装的单文件输入法（含托盘工具箱运行模式）

**WgIme**：免安装的单文件悬浮输入法 —— 支持拼音 / 五笔 / 混合 / 英汉词典四种模式，带词频学习、简拼、模糊音、造词、码表导入与固化、整句连打、应用启动器、`tools.txt` 工具箱与 `plugins\*.txt` 插件。每个分发文件同时内置 **托盘工具箱运行模式**（`tray`，原独立 WgTray 已收敛为运行模式）。

运行模式由 `config.txt` 的 `mode` 键定义（`ime`=输入法，默认 / `tray`=纯托盘工具箱——无键盘钩子/候选窗/词典交互，只有托盘工具菜单），托盘菜单「运行模式」可随时切换（写 config + 自动重启）。三种分发形态功能一致，按环境取舍：

| 文件 | 形态 | 说明 | 体积 |
|---|---|---|---|
| `wgime.bat` | **bat 版（带载荷）** | cmd 引导 + 内嵌 C# 源码 + 内嵌基础码表，启动时内存编译 | ~3.3MB |
| `WgIme.ps1` | **ps1 版** | PS 引导 + 内嵌 base64 预编译 DLL（含全部词库/图标/emoji 资源），运行时解出加载 | ~39MB |
| `wgime-py-pure\dist\wgime-py.py` | **Python 纯版（单文件）** | 纯 Python 重实现，内嵌全部模块+插件+第三方库(zip)，零 .NET、免安装 | ~587KB |

> **bat 版 vs ps1 版**：bat 版靠 cmd 引导双击即用（`wgime.bat` 内嵌基础码表自包含）；ps1 版启动命令行只有 `powershell -File xxx.ps1`（无 `Add-Type`/`.dll`/`::Run` 明文），规避 EDR 对"隐藏 PowerShell 加载 DLL"行为模式的命令行告警。取含详见下文「bat 版 vs ps1 版」。

A single-file, install-free overlay IME (pinyin / wubi / mixed / EN-CN dictionary) for Windows — each distribution runs as **IME mode** or **tray-toolbox mode** (config `mode=ime|tray`, switchable from the tray menu).

## WgIme 输入法

- **全单字内嵌**：内置拼音 26,719 字 / 五笔 17,366 字（BMP CJK + 〇 + 扩展A区基本打尽）——删掉所有 txt 词库文件照样能打出几乎所有汉字；txt 提供词语与排序
- **四种模式**：混合（默认，五笔优先补拼音）/ 拼音 / 五笔 / 英汉词典
- **智能输入**：整句连打（`nihaoshijie` → 你好世界，6 万词表 + 词频最佳路径）、联想（学习个人习惯、可连续联想）、词频学习、简拼（`zg` → 中国）、模糊音（zh/z、ang/an、n/l…）、双拼（小鹤/自然码/微软）、以词定字
- **造词**：手动（Ctrl+Alt+C）/ 批量（文件导入）/ 自动（90 秒内连续选字自动组词）
- **码表导入**：Rime `*.dict.yaml`、编码在前/词在前 txt、英汉词表，自动识别 UTF-8/GB18030，热重载
- **固化码表**：一键把合并词库烘焙进 bat 内置表（滚动 7 份备份），之后可删除 txt 源文件
- **应用启动器**：编码唤出应用——内置 `jsq` 计算器 / `itools` 工具箱 / `net` 网络工具 / `clip` 剪贴板历史 / `bj` 便签 / `ys` 颜色拾取 / `plugins` 插件管理；config.txt 可挂任意程序/目录/网址
- **更多**：中文标点、vf 符号/emoji 面板（彩色 Fluent emoji）、v 模式（大写金额/千分位）、简繁切换、rq/sj/xq 动态候选、五笔 z 通配符、反查编码、自定义短语、快捷键全配置化、候选窗光标跟随（UIA 三级回退）、空闲自动隐藏、微信 4.x 等 Qt 应用标点吞字修复（keyfix）

## 运行模式（ime / tray）

一个分发文件两种运行形态，`config.txt` 的 `mode` 键决定启动方式（缺省 `ime`）：

- **ime（输入法）**：键盘钩子 + 候选窗 + 组字，托盘菜单含开关/模式/词库/选项/工具/运行模式
- **tray（托盘工具箱，原 WgTray）**：不装键盘钩子/候选窗，托盘出"工"字图标 + 工具菜单
  （工具箱 / 内置工具 / 插件管理 / config 应用 / 编辑配置），只做托盘工具

托盘菜单 **运行模式 ▸ 输入法 (IME) / 托盘工具箱 (Tray)** 可随时切换（写回 config 并自动重启）。

tray 模式完整提供原 WgTray 能力：

- **工具箱…** —— `tools.txt` 驱动的多标签工具窗体（`[tab 标签页]` / `[cols 列数]` / `[按钮名]` / 步骤行；支持 `msg/confirm/run/shell/shellx/open/kill/wait/reg-set/reg-del/file-del/mkdir` 与 `[shell]`/`[powershell]`/`[shellx]`/`[psx]` 多行块，详见 tools.txt 文件头注释）
- **插件** —— `plugins\*.txt` 里启用的插件（步骤 DSL 与 `[python]` 块）+ **插件管理**（运行/列表/启用禁用/编辑/删除/新建模板/打开目录）
- **内置工具** —— 网络工具（ping/tracert/DNS/HTTP/端口/子网计算）/ 剪贴板历史 / 便签 / 颜色拾取
- **应用 (config.txt)** —— `app = 编码 名称 命令` 条目
- **配置** —— 编辑 config.txt / 重载配置 / 数据目录

> C# 版（bat/ps1）共用 WordBoard 代码：`TrayMode` 静态标志读自 config，tray 时跳过 `Hook.Start()`、
> 隐藏候选窗体、托盘菜单切换为工具风格；python 版由 `main.is_tray_mode()` 分支同样处理。

## 开机自启

程序**不自带**计划任务注册（无 `-Install` / `-RemoveTask`，托盘菜单也没有"开机自启"项）——自动启动由你自己的工具负责（如任务计划程序、启动文件夹、组策略），把启动命令加进去即可：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1      # 按 config mode 启动 (ime/tray)
```

> 这样做的原因：不写计划任务、不在程序里调用 schtasks，减少安全软件（EDR/杀软）对"隐藏 PowerShell 自启动"行为模式的告警面；需要自启的用户自己挂任务。

## 快速开始

1. 双击 `wgime.bat`（默认输入法，托盘"中"字图标）；要托盘工具箱模式，编辑 config.txt `mode = tray`（或托盘菜单「运行模式」切换）后启动；ps1 版用 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1`
2. 首次运行自动播种 `tools.txt` / `plugins\` / `config.txt` 示例（不覆盖已有文件）
3. 输入法：任意文本框输入拼音/五笔，候选条跟随光标出现（`Shift` 轻点开关，`` Ctrl+` `` 切换模式）
4. 改完 tools.txt / plugins / config.txt 后：托盘菜单 **配置 → 重载配置** 即时生效
5. 数据目录 `%LOCALAPPDATA%\wgime`（插件禁用记录、便签、颜色设置等；删除即恢复初始状态）

> 详细说明见 [docs/WGIME_使用说明.md](docs/WGIME_使用说明.md)（快捷键总表 / 四种模式 / 造词 / 码表导入 / 固化）、[docs/WGIME_技术文档.md](docs/WGIME_技术文档.md)（架构 / 启动链 / 载荷机制）。版本更新见 [CHANGELOG.md](CHANGELOG.md)。

## 构建与测试（Windows PowerShell 5.1）

```powershell
# WgIme ps1 版（从 wgime.bat 提取 C# 编译 DLL + 组包）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-ps1.ps1
# 测试
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1   # WgIme ps1 版回归
```

> `wgime.bat`（bat 版主源，含全部 C# 与基础码表）已入库；`build-wgime-ps1.ps1` 从它提取代码。
> 根目录 `py.txt`/`wb.txt`/`ec.txt`/`import_*.txt` 是本地构建用扩展码表（gitignored，全部词库已编入 `WgIme.ps1` 载荷与 wgime.bat 基础表）。原独立 WgTray 分发文件（wgtray.bat / WgTray.ps1 / wgtray-nopayload.bat）已退役并由 git 删除——`mode=tray` 完全替代（历史版本在早期 git 提交中）。

## bat 版 vs ps1 版（取舍分析）

两套形态功能完全一致（同一套代码、同一套测试），区别只在"程序集怎么来"与"启动命令行长什么样"：

**bat 版（带载荷）**
- 程序集 = bat 内嵌 C# 源码 + 基础码表，启动时内存编译
- 优点：双击直接跑（cmd 引导）、无 `-File` 命令行依赖
- 缺点：cmd 引导 + 内嵌源码是杀软经典扫描模式，误报面比 ps1 版大

**ps1 版**
- 程序集 = ps1 内嵌的 base64 预编译 DLL，运行时解出到 `%LOCALAPPDATA%\wgime\*.dll` 加载
- 优点：启动命令行只有 `powershell -File xxx.ps1`，没有 `Add-Type`/`.dll`/`::Run` 明文——规避 EDR 对"隐藏 PowerShell 加载 DLL"的命令行告警（Cisco 等安全软件环境下更安静）
- 缺点：需要 PowerShell 调用方式启动（双击默认用 notepad 打开，需右键"使用 PowerShell 运行"或由自己的启动工具拉起）

**建议**：要双击即用 → bat 版；在意安全软件命令行告警（如公司机）→ ps1 版（程序不自带自启注册，自启用你自己的任务计划/启动文件夹）。

## 分发（wg-all/）

`wg-all\` 是合并分发目录：`install.bat`（ime/tray 入口）+ `WgIme.ps1`（单文件双模式）+ `config.txt` + `tools.txt` + `plugins\` + `README.txt`。只发行 ps1 版，不产生任何 .dll/.bat 启动器/快捷方式。

## 文件说明

| 文件 | 作用 |
|---|---|
| `wgime.bat` | 程序本体 + 构建主源（bat 版带载荷，内嵌 C# + 基础码表；纯 CRLF 无 BOM） |
| `WgIme.ps1` | ps1 版（PS 引导 + 内嵌 base64 预编译 DLL） |
| `config.txt` | 共用配置（`mode = ime|tray` 运行模式 / 输入法键 / `app=` 应用 / `hotkey_*`） |
| `tools.txt` | 工具箱配置（`[tab 标签页]` / `[按钮名]` / `code = xxx` 启动编码 / 步骤行） |
| `plugins/` | 插件目录（步骤 DSL / 插件；规范见 [docs/WGIME_插件规范.md](docs/WGIME_插件规范.md)、窗体风格见 [docs/WGIME_窗体设计语言.md](docs/WGIME_窗体设计语言.md)） |
| `build-wgime-ps1.ps1` | 从 wgime.bat 构建 WgIme.ps1（编译 DLL + base64 嵌入 + wg-all 同步） |
| `vt-scan.ps1` | VirusTotal 一键扫描脚本（wg-all 分发文件） |
| `tests/` | 回归测试（wgime-ps1 等） |
| `wgime-py-pure/` | **纯 Python 版**：`main.py`(状态机/注入/tray api) / `hook.py`(ctypes 键盘钩子) / `win.py`(ctypes Win32 注入+原生剪贴板+UIA 光标) / `bar.py`(无边框圆角候选条) / `engine.py`(码表/候选/词频/造句) / `plugins.py`(插件+步骤DSL) / `tools.py`(工具箱等) / `tray.py`(pystray 双语托盘) / `ui.py`(窗体设计语言实现) / `wspy.py`(WS 客户端) / `plugins\*.py`(Python 插件) |
| `wgime-py-pure\build-wgime-pure.py` | 生成纯 Python 单文件 `dist\wgime-py.py`（内嵌全部模块+插件+第三方库） |
| `wgime-py-pure\build-package.ps1` | 刷新纯 Python 版 `package\` 分发目录（单文件 + sidecar + dicts + 配置/插件） |
| `wg-all/` | 合并分发目录（install.bat + WgIme.ps1 双模式 + 配置/插件/README） |
| `docs/` | 文档目录：使用说明 / 技术文档 / 插件规范 / 窗体设计语言 / TSF 评估 |

## 开发

- 修改 C# 一律改 `wgime.bat`（唯一源码真身）；`build-wgime-ps1.ps1` 重新出 ps1 版
- 运行模式改动点：`TrayMode` 字段(读 config mode) / 构造中托盘菜单分支与候选隐藏 / `OnLoad` 跳过 `Hook.Start` / `RestartInMode`(写 config+重启) / `RefreshLabel` tray 图标
- 运行测试：`tests\wgime-ps1.tests.ps1`
- 文件约束：wgime.bat 纯 CRLF / 无 BOM（cmd.exe 依赖 CRLF 解析批处理头，见 .gitattributes）；.ps1 构建脚本保持 ASCII（Windows PS 5.1 按 ANSI 读取），非 ASCII 内容一律放 UTF-8 模板

## 项目演进

> 完整逐版本记录见 [CHANGELOG.md](CHANGELOG.md)。这里是从最初到现在的概览。

- **2026-08-13 最初形态**：单一 `wgime.bat`（~930KB），纯 C# 内存编译（每次启动 `Add-Type`），无 ps1 版、无托盘工具箱、无插件系统。词库是散落的 `py.txt`/`wb.txt`/`ec.txt`。
- **分发形态演进**：
  1. 纯内存编译 bat（受限语言模式机器跑不了）→ **预编译 DLL 载荷**（AppLocker/WDAC 锁定机也能跑）
  2. 单一程序 → **双程序**：WgIme（输入法）+ WgTray（无输入法的托盘工具箱）
  3. 每种程序 → **bat / ps1 双形态**（bat 双击即用，ps1 命令行干净规避 EDR 告警）
  4. 词库散落 → **全部内嵌**（压缩 trailer，文件夹不再需要 txt）
  5. **双程序 → 单程序双模式**（2026-09）：WgTray 退役，`config.txt mode = ime|tray` 定义运行模式，
     托盘菜单「运行模式」切换 + 自动重启；bat/ps/py 三版一致支持
- **新增子系统**：托盘菜单、插件系统（DSL + C# 代码插件 + 管理器）、应用启动器、网络工具、时钟插件（多提醒方式）、聊天插件（MQTT+加密，与 itools-chat 互通）、tools.txt 按钮启动编码。
- **性能与稳定性**：词库加载优化（批量缓存读 + 并行建表 + 缓存命中跳过解压）、修复长时间运行上屏卡顿（词频保存后台化 + 内存上限）。
- **安全与合规**：去 base64 降 ML 误报面、移除快捷方式/计划任务自启、控制台自隐藏、词库原始二进制。
- **工程化**：完整测试套件（86 项）、docs 文档、CHANGELOG、Git 分支合并回 master、码表 txt 入库、行尾规范化。
- **2026-08-26 起 纯 Python 版**：追加 `wgime-py-pure/`（纯 Python 重实现，零 .NET）——`python wgime-py-pure\dist\wgime-py.py` 单文件运行；功能与 C# 版对齐（四模式/词频/简拼/双拼/造词/码表导入固化/启动器/工具箱/插件/候选窗/托盘），词频机制升级（语料+学习+近期热度），候选条宽度限制，UI 用 `ui.py` 设计系统；插件支持 `plugins/*.py` + `[python]` 块 + `[csharp]` sidecar。

## 纯 Python 版（wgime-py-pure）

除 C# 版（bat/ps1）外，项目还有一个**纯 Python 重实现**（`wgime-py-pure/`），零 .NET、免安装、单文件：

- **运行**：Python 3.13+（3.12+ 即可），`python wgime-py-pure\dist\wgime-py.py`（单文件，内嵌全部模块与 pystray/uiautomation/comtypes）或 `python wgime-py-pure\package\wgime-py.py`（分发目录）。**无黑窗口**：被 `python.exe` 启动会自动用 `pythonw.exe` 无控制台重启自身（设 `WGIME_DEBUG=1` 可保留控制台看错误）。**重载**：改 `config.txt`/`tools.txt`/插件后，用托盘菜单「这个程序 → 重载配置」即可生效，无需重启程序（同 C# 版）；也可「这个程序 → 编辑配置」直接打开 config.txt
- **零第三方必需**：pystray（托盘）/uiautomation+comtypes（现代应用光标跟随）已 zip 内嵌进单文件；`cryptography`（聊天加密）可选
- **数据目录** `%LOCALAPPDATA%\wgime-py`（词频/联想/词库缓存）；若用 **Microsoft Store 版 Python**（AppContainer 沙箱虚拟化 `%LOCALAPPDATA%`），程序自动切到 `C:\Users\<user>\wgime-py`
- **功能**：与 C# 版基本对齐——四种模式 / 词频学习 / 简拼 / 模糊音 / 双拼 / 造词 / 码表导入与固化 / 启动器 / 工具箱 / 插件 / 候选窗 / 托盘菜单 / 反查编码 / 简繁 / 整句 / 联想 / 空闲隐藏
- **差异**：
  - 拼音候选排序结合**语料先验 + 学习词频 + 近期热度**（比 C# 版只按学习词频更优）；词频机制已升级（默认/主动区分、近期滑动窗口、误学回滚、`learnk`/`recentk` 可配）
  - 候选条宽度有限制（不铺满屏，超宽时动态截断候选）
  - UI 用 `wgime-py-pure\ui.py` 设计系统实现 C# 版窗体设计语言（浅蓝灰底/白卡/深色控制台/圆角/flat 按钮），chat/calc/clock 插件同风格
- **插件**：`plugins/*.py`（纯 Python 模块：`CODE`/`NAME`/`PERM` + `run()`）+ `plugins/*.txt`（步骤 DSL / `[python]` 块 / `[csharp]` sidecar），支持 manifest（version/author/requires/perm）与权限确认

## 系统要求

Windows 10/11，Windows PowerShell 5.1（系统自带），无需安装。

## License

代码部分（`wgime.bat`、构建脚本、`tests/`、`docs/`）遵循 MIT 协议，详情见各文件头注释。随附的插件示例（`plugins/`）仅限个人使用，分发前请确认各自许可。
