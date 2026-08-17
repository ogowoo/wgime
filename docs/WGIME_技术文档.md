# WgIme 技术文档

> 版本：2026-08-16（含"码表导入/固化/效率扩展/应用启动器/内嵌应用/插件系统/首次播种"）　适用文件：`wgime.bat`（单文件）

## 1. 概述

WgIme 是一个 **单文件悬浮输入法**（覆盖层 IME），支持拼音 / 五笔 / 混合 / 英汉词典四种模式。
核心设计目标：**免安装、免注册、不产生 exe** —— 用户双击一个 `.bat` 即可使用。

| 特性 | 说明 |
|---|---|
| 载体 | 单个 `wgime.bat`（cmd 引导 + PowerShell 引导 + 内嵌 C# + 内嵌预编译 DLL） |
| 输入原理 | 全局低级键盘钩子 `WH_KEYBOARD_LL` + `SendKeys` 回发文本 |
| 词典 | 内嵌表（**全单字**：拼音 26,719 字 / 五笔 17,366 字，BMP CJK + 〇 + 扩展A 区基本打尽，单文件即可打出所有有读音的汉字）+ 目录 txt 扩展（词语）+ 导入文件 + 用户词 + 词频记忆 |
| 缓存 | `%LOCALAPPDATA%\wgime\wgime.mb` 二进制词典缓存（MD5 失效校验） |
| 码表导入/固化 | 托盘导入常见码表（§5）；一键把合并词库烘焙进内置表（§6），之后可删除 txt 源文件 |
| 效率扩展 | 以词定字、rq/sj/xq 动态候选、自定义短语、五笔 z 通配符、反查编码、config.txt 配置、剪贴板粘贴上屏（§7）、光标跟随/空闲隐藏（§3.2）、Qt 注入修复 keyfix（§3.4） |
| 应用启动器 | 编码精确匹配 → `▶名称` 候选置顶 → 选中**启动而非上屏**；内置 计算器/工具箱/网络工具/剪贴板历史/便签/颜色拾取/插件管理（§7.3） |
| 插件系统 | `plugins\*.txt` 纯文本插件（步骤 DSL 或内嵌 C#/WinForms，CodeDom 内存编译），自动注册进启动器（§7.4，规范见 `docs/WGIME_插件规范.md`） |
| 首次播种 | 首次运行自动生成 tools.txt + plugins 示例与 README（`provisioned.done` 哨兵，§2） |
| 运行环境 | Windows PowerShell 5.1（.NET Framework 4.x），Win11 实测 |

## 2. 文件结构与启动链

```
wgime.bat
├─ [1-55]   cmd 引导（行号随编辑漂移，以 grep 实际为准）
│    ├─ 设置 WGIME_PATH / WGIME_DIR
│    ├─ 无 _h 参数：用 powershell.exe 重新拉起自身（加 _h 参数，隐藏窗口）
│    │        WGIME_DEBUG=1 时保持控制台可见，便于排错
│    └─ 有 _h 参数（:main）：powershell.exe -STA 读取自身全文，
│          定位 ###PWSH### 标记，取出其后全部文本 Invoke-Expression 执行；
│          异常写入 %TEMP%\WgIme_error.log（隐藏模式弹 MessageBox）
├─ [56]     ###PWSH### 标记
├─ [57-…]   PowerShell 引导
│    ├─ WgLog 日志函数（追加写 %TEMP%\WgIme_error.log）
│    ├─ 加载 System.Windows.Forms / System.Drawing
│    ├─ 三个内嵌 here-string 数据表：$pyData（拼音）、$wbData（五笔）、$ecData（英汉）
│    │    （**全单字内嵌**：拼音 26,719 字 / 五笔 17,366 字，由根目录 `build-full-singles.ps1`
│    │      从 py.txt/wb.txt 单字 + tests/pinyin-data.txt（mozillazg Unihan 派生表，声调符号
│    │      剥离、ü→v）合并生成；每次跑自带时间戳备份，字典缓存经 InputMd5 自动失效重建）
│    ├─ $cs = @'…'@ ：完整 C# 源码（命名空间外平铺类：KeyBordHook、WordBoard、MbData…）
│    ├─ DLL 加载器（见 2.1）：优先加载预编译 DLL，失败回退内存编译 $cs
│    └─ 首次播种（§7.5）：provisioned.done 哨兵 + 四段内嵌种子文本
├─ [末尾]  ###WGIME_DLL### 标记
└─ [末行]  base64 编码的预编译 DLL（单行，当前约 63 KB）
```

### 2.1 预编译 DLL 载荷机制

- bat 尾部 `###WGIME_DLL###` 之后是 **base64 编码的完整 .NET DLL**（由 `$cs` 编译而来）。
- 加载器逻辑：
  1. 取出 base64 串（`-replace '\s'` 去空白）；
  2. 计算 `MD5(base64串)` 前 8 位十六进制作为文件名 `%LOCALAPPDATA%\wgime\WgIme.<hash>.dll`；
  3. 文件不存在则解码写出，并 **删除同目录其他 `WgIme.*.dll`**（自动清理旧版本）；
  4. `Add-Type -Path` 加载；失败则回退 `Add-Type -TypeDefinition $cs` 内存编译。
- 意义：在 AppLocker/WDAC 等 **ConstrainedLanguage 策略**机器上，内存编译被禁，预编译 DLL 是唯一可运行路径；加载失败时日志会给出提示。
- **载荷行格式**：base64 串用**单引号包裹**（`'TVqQ…='`）——对 PowerShell 是无副作用的字符串表达式语句；若写成裸令牌，退出时会抛一次不可见的 CommandNotFoundException。加载器提取时用 `-replace "'"` 去掉引号（base64 字母表不含单引号，无损）。
- **约束：任何对 `$cs` 的修改都必须重新生成该载荷**，否则运行时仍运行旧代码。重建方法见 §11。

## 3. 架构组件

### 3.1 KeyBordHook —— 键盘钩子

- `SetWindowsHookEx(WH_KEYBOARD_LL)` 全局低级钩子，基于消息循环（-STA），事件驱动。
- 关键防护：
  - `LLKHF_INJECTED`（flags & 0x10）：**自己 `SendKeys` 发出的键直接放行**，避免回环；
  - `ModifierDown()`：Ctrl/Alt/Win 按下时全部放行，不干扰系统快捷键；
  - Shift 轻点状态机：Shift 按下置位 `shiftArm`，期间无其他键则释放时触发 `OnShiftTap`（开关输入法）。
- 键分发表（Ctrl+`、Ctrl+Alt+C、Shift 轻点不受 `IsLocked` 限制，其余需 `IsLocked` 为开且无修饰键）：

| 键 | 条件 | 事件 |
|---|---|---|
| 1-9 | 有编码 | `OnSpaced(1..9)` 选第 N 候选（0 键同样被拦截但无动作） |
| Space | 有编码 | `OnSpaced(0)` 选首候选 |
| Backspace | 有编码 | `OnBacked` 删一个码 |
| Esc | 有编码 | `OnEscaped` 清空 |
| Enter | 有编码 | `OnEntered` 原码上屏 |
| a-z | 无 Shift | `KeyUpEvent` 追加编码 |
| = / PgDn、- / PgUp | 有编码 | `OnPage(+1/-1)` 翻页 |
| ` | Ctrl 按下 | `OnCtrlBackquote` 切换模式（裸 ` 正常打出） |
| C | Ctrl+Alt 同时按下 | `OnMakeWord` 剪贴板造词 |
| [ / ] | 有编码且无 Shift | `OnPickChar(0/1)` 以词定字（取候选 1 首字/尾字）；无编码时仍走标点映射 【 】 |
| 标点键 | — | `OnPunct` 中文标点映射 |

- 中文标点映射（`MapPunct`，`"`/`'` 自动交替配对）：

| 物理键 | 裸键 | Shift |
|---|---|---|
| `,` | ， | 《 |
| `.` | 。 | 》 |
| `;` | ； | ： |
| `/` | 放行 | ？ |
| `\` | 、 | 放行 |
| `[` | 【 | 放行 |
| `]` | 】 | 放行 |
| `$` | 放行 | ¥ |
| `'` | ‘ / ’（交替） | “ / ”（交替） |

### 3.2 WordBoard —— 候选条 + 托盘

- 无边框半透明置顶窗体（`Opacity=0.88`，`WS_EX_NOACTIVATE|WS_EX_TOOLWINDOW|WS_EX_TOPMOST`，不抢焦点），可拖动，位置存 `pos.txt`，宽度随内容自适应。**光标跟随**（`followcaret = 1` 默认开，托盘"选项"可切）：每次开始组字（`keys.Length == 1`）时把候选条定位到文本光标处——三级回退取锚点矩形：① UIA `TextPattern` 选区矩形（只接受**细**矩形：宽 >200px 的整行/整段矩形不可信，降级——某些 Chromium 输入框会给宽矩形）；② 原生 caret（`GetGUIThreadInfo` + `ClientToScreen`）——**包括退化 caret**：Qt 的 2×2 caret（微信 `mmui::ChatInputField`）尺寸是假的但**坐标逐像素跟踪真实光标**（实测 +7px/ASCII 字符），只把高度替换成估算行高（22px）；③ UIA 焦点元素矩形 + **文本估算**（真拿不到 caret 时）：用 `TextPattern` 算出光标前字符、按行号×行高 + 行内逐字宽（CJK≈1em、ASCII≈0.56em）估算光标像素位置。超屏自动翻转到光标上方或收边（多显示器按光标所在屏的 WorkingArea）。取不到光标（全屏游戏等）保持原位。**空闲隐藏**（`hideidle = 1` 默认开，托盘"选项"可切）：无编码无候选时 `Visible=false`，候选窗只在组字期间出现。
- 托盘菜单（分组子菜单，打开时同步勾选状态）：开关 / 模式（混合/拼音/五笔/词典直达）/ 词库（造词 / 批量造词 / 用户词表 / 导入码表 / 固化码表）/ 选项（反查编码 / 简繁输出 / 候选窗跟随光标）/ 这个程序（剪贴板上屏 / 标点吞字修复）/ 工具箱… / 配置（编辑配置 / 重载配置 / 数据目录）/ 退出。
- 托盘图标：程序内用 GDI+ 绘制的**Win11 超椭圆圆角（半径 14/64px ≈22%）+镂空字**图标（色块铺满画布；`GraphicsPath.AddString` + `CompositingMode.SourceCopy` 把 52px 模式字从色块中抠成透明洞，字与边框留约 2px 间距，透出任务栏背景）；模式字 中/拼/五/译，**开=Win11 强调色块（蓝 #0078D4 / 青 #00B7C3 / 橙 #CA5010 / 紫 #881798），关=浅暖灰色块**。
- 模式机：`mode ∈ {0 混合, 1 拼音, 2 五笔, 3 词典}`，`Ctrl+\`` 循环切换，模式不同时托盘图标与候选条前缀同步变化。
- `inDialog` 实例标志：模态对话框打开期间，钩子的三个旁路事件（Shift 轻点 / Ctrl+` / Ctrl+Alt+C）被忽略，且 `IsLocked` 被临时关闭，防止选文件时按键污染编码缓冲。

### 3.3 候选计算管线（`ShowCharatar`）

1. 按模式查询词典：
   - `AddFromDict`：先精确命中（五笔命中置 `exactWubi`），再对**有序键数组二分**定位前缀区间，前缀匹配只取单字（`extendable` 置位）；
   - 混合模式顺序：五笔 → 拼音；词典模式走 `AddTranslate`。
2. `AddAcro` 简拼（如 `zg → 中国`）；候选不足 9 个时 `AddFuzzy` 模糊音补全（zh/z、ch/c、sh/s、ang/an、eng/en、ing/in、n/l 单次替换，最多 16 个变体）。
3. 排序：词频（`Freq`）降序；若本码在 `LastPick` 中有上次选择，直接置顶。
4. 上限：`CandCap=60`，`PageSize=9`（一页 9 个，1-9 选，Space 选第 1 个）。
5. 扩展候选（模式 0-2，词频排序之后插入，恒在首位区）：`AddDynamic`（rq/sj/xq → 日期/时间/星期）→ `AddAppCand`（应用启动器：编码精确命中 `Apps` 注册表时插入 `▶名称` 候选，`appSet` 标记——选中时 `LaunchApp` 启动而非上屏、不学习；五笔四码自动上屏有守卫）→ `AddPhrase`（config.txt 短语，含空格文本，最顶）→ 五笔模式含 `z` 时 `AddWubiWildcard`（对 wb 表线性扫描通配匹配）。
6. 五笔惯例：**纯五笔模式下**，4 码精确命中且无可扩展前缀时自动上屏**首个候选**（无需空格，候选列表不显示；同码多词时可用 Backspace 退回三码查看全部候选）。
7. 反查编码（`ShowCode`）：候选后附 `(码)` —— 拼音/混合模式取 `RevWb`（词→五笔码反向表，`ApplySwap` 时从 wb 表构建），五笔模式取 `CodeFor`（CharPy 拼接全拼）。

### 3.4 上屏机制

`Send(msg)`：**发送队列**（`sendQueue` + `sending` 标志）——提交事件先入队，UI 线程 `DrainSendQueue` 逐个发送；**发送期间按键不再被丢弃**（字母/退格/清空照常处理，提交事件排队按序发送）。按 `EffectiveMode()`（全局 `PasteMode` 叠加按进程覆盖）选择通道：
- **逐字符 Unicode 注入（默认 `paste=key`）**：`FillUnicodeEvents` 把整串文本转成 N×2 个 `SendInput` 事件（每字符一对 `KEYEVENTF_UNICODE` down/up，字符放在 `wScan`），一次批量注入输入队列——**输入队列天然串行有序，无剪贴板共享状态，无竞态、无空读、无恢复**；长文本压力测试 45/45 逐字精确、耗时约为剪贴板方案的一半。**代理对**（增补平面字符）：按 hi-down、lo-down、lo-up、hi-up 顺序发 4 个事件，孤立代理项跳过。
- **剪贴板粘贴（`paste=on`，回退通道）**：`PasteCommit` 链式捕获一次原始剪贴板（300ms 窗口内连续上屏只读一次，且原始内容为空/非文本时**永不恢复**）→ `Clipboard.SetText` → `SendInput` 注入 Ctrl+V（`INPUT` 结构体 x64 布局 40 字节）→ **事件同步**（钩子在注入放行分支检测自己注入的 V 键抬起 → `pasteSeen` 事件，泵消息等待 ≤1.5s，加 80ms 余量）→ 代际守卫的单链定时器（过期回调作废）恢复剪贴板。
- `paste=auto`：仅当前台进程提权且自身未提权时走粘贴（提权检测：`OpenProcess`→`OpenProcessToken`→`GetTokenInformation(TokenElevation)`），否则按 key。
- `paste=off`：纯 `SendKeys.Send(Sanitize(msg))`（`Sanitize` 转义 `+^%~(){}[]`；钩子忽略 LLKHF_INJECTED 注入键，自注入不回环）。已知局限：目标窗口内有系统输入法时注入 CJK 可能乱码。
- **按进程覆盖**（`%LOCALAPPDATA%\wgime\pastemode.txt`，`程序名.exe=clipboard|sendkeys|key|keyfix|keyplain`，`#` 注释）：`EffectiveMode()` 先查 `AppModes[前台进程名]`（`GetForegroundWindow`→`GetWindowThreadProcessId`→进程名小写），命中则覆盖全局 `PasteMode`。托盘菜单"这个程序改用剪贴板上屏"为**当前前台程序**切换/清除覆盖并即时保存——个别程序不兼容 key 模式时无需动全局配置。
- **Qt 陈旧字符修复（`keyfix`，全局默认开）**：Qt 应用（微信 4.x `Weixin.exe`、Telegram 等）的键盘映射用 `PeekMessage(WM_CHAR, PM_REMOVE)` 认领按键对应的字符消息，而 `VK_PACKET` 注入的字符**只随 WM_CHAR 携带**（WM_KEYDOWN 的 lParam 里没有）；注入全角标点（，。、；：？！《》【】… 实测 U+FF0C/U+3001/U+3002 触发，汉字/ASCII/引号 U+201C/¥/emoji 不触发）后认领关系错位，**下一个注入字符被替换成该标点**（与注入间隔、分批方式无关，恰好消耗一个字符，参见 [tdesktop#26643](https://github.com/telegramdesktop/tdesktop/issues/26643)）。修复：`UnicodeCommitQtFix` 在每个触发字符（`StaleTrigger`：≥U+3000 且非汉字区段）后追加一个 ASCII `X`（吸收陈旧命中，被显示成重复标点）+ `VK_BACK`（删掉它），同一 SendInput 批次、零延时。**免白名单全局启用**（`EffectiveKeyfix`）：X+退格在符合规范的应用里自我中和（已对 Win32 EDIT 控件做字节级断言验证，无残留无丢字），正常程序无感知。逃生通道：全局 `config.txt keyfix=0`；按进程 `pastemode.txt` 里 `程序名.exe=keyplain`（强制关）/`keyfix`（强制开，覆盖全局关）；托盘菜单"这个程序切换标点吞字修复"为当前前台程序钉住与全局默认相反的值。keyfix 路径下目标提权时回退剪贴板（同 auto）。

### 3.5 学习与造词

| 文件 | 内容 | 保存时机 |
|---|---|---|
| `userdict.txt` | `词 频次` | 每累计 10 次学习或退出时 |
| `lastpick.txt` | `码 上次选的词` | 同上 |
| `userwords.txt` | `码 词1 词2…`（按码聚合） | 每次造词 |
| `pos.txt` | 候选条位置 `x,y` | 拖动结束 |

- 自动造词：90 秒内连续选择 2–4 个单字且其编码可验证 → 自动组合成词（`RecordCommit` 链）。
- 手动造词：`Ctrl+Alt+C` 读取剪贴板 2–8 个汉字，用 `CharPy`（字→拼音码映射）反推编码入库。
- `AddUserWord` 同时热注入 `PyDict`/排序数组/简拼索引，无需重启生效。

## 4. 词典数据管线

### 4.1 数据源分层（叠加优先级从低到高）

```
内嵌 $pyData/$wbData/$ecData（bat 内 here-string，打包单字自动拆空格式）
  → 目录文件 py.txt / wb.txt / ec.txt（UTF-8，覆盖或扩展同码候选）
  → 导入文件 import_py.txt / import_wb.txt / import_ec.txt（码表导入功能生成，叠加）
  → userwords.txt（仅并入拼音表，MergeUserWords）
  → 运行时：Freq / LastPick 仅影响排序，不改词典
```

### 4.2 解析规则

`ParseDict` / `AddDictLine`：
- 每行 `code cand1 cand2 ...`，空格分隔，码小写化；
- 内嵌表允许"打包单字"（如 `a 啊阿呵`）——无空格时按字拆开（`packChars`）；
- 外部 txt 不打包。所有 txt 均为 UTF-8。

### 4.3 wgime.mb 二进制缓存格式

| 偏移 | 内容 |
|---|---|
| 0 | Magic `WGMB2`（5 字节） |
| 5 | 输入 MD5（16 字节）——见 4.4 |
| 21 | Deflate 压缩流：按序写 拼音表 → 五笔表 → 英汉表 → 英汉反向表（各为 `count + [len+utf8 键][len+utf8 值]×N`）→ 简拼表（`count + [key][空格join的词表]×N`） |

### 4.4 失效机制（InputMd5）

对以下 **10 项字节流**（每项后补一个 0x00 分隔）计算 MD5：内嵌三表、目录三 txt、导入三 txt、userwords.txt。
任何一项变化（包括**删除导入文件**）都会使缓存 MD5 不匹配 → 丢弃缓存、全量重建并写回新缓存。

### 4.5 共享管线与热重载（本版本重构）

```
BuildDicts(dir)          # lock(DictLock) 串行化
  ├─ LoadUserWords（UserWords 为空则初始化）
  ├─ SafeRead 各源文件 → InputMd5
  ├─ TryLoadMb 命中 → BuildCharPy（造词需要）→ 返回
  └─ 未命中 → ParseDict×3 → OverlayImport×3 → MergeUserWords(py)
       → BuildReverse(ec) → BuildAcro(py)（内含 BuildCharPy）
       → BuildSorted×3 → SaveMb(path, md5, mb) → 返回 MbData

ApplySwap(mb)            # 一次性原子替换全部静态引用，DictsReady=true
```

- 启动：`Task.Run { BuildDicts → LoadFreq → ApplySwap → 刷新 }`；
- 导入后热重载：复用同一管线，Freq/LastPick 不重载（词频记忆跨导入保留）；
- 异常兜底：启动构建异常写 `%LOCALAPPDATA%\wgime\mb_error.log`；导入重载失败则旧词典继续可用，导入文件已落盘、下次启动生效。

## 5. 码表导入功能（新增）

### 5.1 交互流程

托盘菜单"导入码表…" → `OpenFileDialog`（*.txt;*.dict;*.yaml;*.yml）→ 读取（>64MB 拒绝）→ 格式自动检测 + 按文件名猜目标词库 → 确认对话框（目标：五笔/拼音/英汉；格式：自动/词在前/编码在前）→ 后台线程转换合并 → 写 bat 目录下 `import_*.txt` → `BuildDicts` 热重载 → 气泡提示统计。

### 5.2 格式检测（DetectFormat，前 200 行采样多数决）

| 特征 | 判定 |
|---|---|
| 行内含 `\t` | 词在前（Rime dict.yaml：`词<TAB>码[<TAB>权重]`） |
| 首列纯 ASCII | 编码在前（`码 词 词…`，wgime 原生格式/小小输入法等） |
| 首列含 CJK | 词在前（`词 码`，如 QQ/极点词库导出） |

### 5.3 转换规则（ConvertFile）

- 跳过：空行、`#`/`;`/`//` 开头、`---`、`...`、YAML `key: value` 头行（不计数）；格式非法行计数为"跳过"。
- 尾部全数字字段视为权重丢弃（如 Rime 的 `100`）。
- 码：小写化，必须匹配 `^[a-z][a-z0-9']{0,31}$`（最长 32 字符，与候选条编码缓冲上限一致）。
- 词在前且第二列不是合法码时自动翻转：若首列是 ASCII 合法码（如英汉文件 `apple<TAB>苹果`），按编码在前处理。
- **含内嵌空格的词条跳过并计数**——空格是 wgime 码表的分隔符，此类词条与格式不兼容（如 `AirPods Pro`）。
- 上限：每码 300 词、全表 500000 码，超出截断并计数。
- 编码：严格 UTF-8 → 失败回退 GB18030（54936）→ GBK（936）。

### 5.4 合并与幂等

- 目标文件 = bat 目录下 `import_wb.txt` / `import_py.txt` / `import_ec.txt`（按所选目标词库）。
- 先读入已有 import 文件作为基底，再叠加新词条：**已有候选保持优先位置，新候选去重追加，新码新建行**；按码排序写出，UTF-8 无 BOM。
- 重复导入同一文件字节级幂等（已验证：两次写出 MD5 一致）。

### 5.5 测试记录（2026-08-13）

- C# 测试夹具（反射调用私有静态方法）24 项全过：格式检测、yaml 转换（`yvqk→朗逸`、权重丢弃）、编码在前/词在前/英汉 TAB、GBK 回退、跳过/校验规则、合并幂等。
- 端到端管线 4 项全过：全量重建（75705 五笔码 ≈2.8s）→ 导入叠加（+1028 码）→ 缓存命中（≈0.8s）且叠加保持。
- 固化回环 11 项全过：合并词典序列化 → 三次 ReplaceHereString 链式替换 → 再提取解析，条目数逐一保持（py 169130 / wb 76733 / ec 323393）、标记完好、重复烘焙幂等、带引号载荷可解码。
- 效率扩展 22 项全过：config 解析（模糊音覆盖/短语/开关/默认值/none 关闭/未知键忽略）、动态候选 rq/sj/xq、z 通配符匹配、BuildRevWb+CodeHint（含真实词库 `朗逸→yvqk`、`中国→zhongguo`）、默认模板、提权检测助手可调用。
- 配置修复 9 项全过：多行模板、旧一行模板自动修复、paste 默认 on、follow 键完全移除（字段/解析/模板/文档全部清除）。
- 英汉词典扩充（2026-08-13）：编码缓冲上限 12→32 码（拼音/五笔不受影响，长英文单词可完整输入）；用 ECDICT（skywind3000，340 万词条）按 `^[a-z]{1,32}$` 过滤出纯单词 33.4 万条并入 ec.txt（现共 65.8 万码，21.9MB；词组/带空格条目天然不可作编码故被过滤）。全量重建+写缓存实测 5.8s，缓存命中启动秒开。
- 上屏性能重构（2026-08-13）：发送队列化（发送期间不丢按键）+ 同步 WM_PASTE 上屏（消除输入队列竞态）+ 剪贴板链式单定时器恢复 + SendInput 批量注入（仅提权回退）。压力测试 6 项全过：三次无间隔连发按序落盘（你好啊）、两轮连发后剪贴板均恢复原始内容、INPUT 结构体 x64 布局 40 字节校验。
- 上屏小项（2026-08-13）：按进程上屏方式覆盖（pastemode.txt 解析/保存往返、默认回退）+ Unicode 代理对发送（BMP 2 事件、增补平面 8 事件 hi-lo 序、孤立代理跳过）10 项全过；全量回归（全部夹具 104 项 + 长文本 45/45 逐字精确）无回归。
- vf 符号/emoji 面板（2026-08-13）：静态数据 8 项 + 实窗交互 18 项全过（根目录/分类/翻页/退格/Esc/Enter/空格忽略/标点与以词定字守卫/emoji 代理对端到端上屏/不学习）；全量回归 104 项 + 长文本 45/45 无回归。候选条 emoji 显示修复：先试 BarLabel 分 run 字体（GDI+ 基础 run + GDI Segoe UI Emoji），逐路径探针证明全部传统渲染路径只能输出单色后，改为内嵌彩色 PNG 图片渲染（33/33 覆盖 + 黄色像素验证）；按用户要求图集换成微软 Fluent Emoji 3D（MIT，Windows 11 同款风格），harness12 34 项全过。
- 用户词管理（2026-08-13）：UserWordsDialog 填充/勾选提取/全选按钮/保存-重载往返 9 项全过；全量回归 147 项 + 长文本 45/45 无回归。
- 双拼支持（2026-08-13）：三套方案（小鹤/自然码/微软）音节还原 71 项 + 管线集成 3 项（vsgo→中国、双拼下 vf 面板关闭、ms y;→应）全过；全量回归 147 项 + 长文本 45/45 无回归。
- 简繁转换 + v 模式（2026-08-13）：ToTrad 单字/整句/开关 9 项、金额大写 11 项（零规则/万亿兆/16 位/超限）、千分位 3 项、AddVMode 4 项、实窗集成 8 项（数字进缓冲、DigitAsCode 三态门控）全过；全量回归 256 项 + 长文本 45/45 无回归。
- 启动默认关闭选项（2026-08-14）：config `starton = 1/0`，模板/默认值/解析 3 项新增，全量回归 259 项 + 长文本 45/45 无回归。
- 批量造词（2026-08-14）：CollectWordLines 行过滤/去重、BatchAddWords 批量注入（新增/跳过计数、词典/用户词/排序数组/简拼索引/落盘一次到位）、确认对话框 11 项全过；全量回归 270 项 + 长文本 45/45 无回归。
- 快捷键全配置化（2026-08-14）：VkFromName 键名表 12 项、ParseHotkey 组合键解析 6 项、LoadConfig 应用到钩子静态字段 9 项、模板 1 项全过；顺带修正以词定字 `[` 的 vk 常量 bug（原 0x5B 永远取尾字）；全量回归 298 项 + 长文本 45/45 无回归。

## 6. 固化码表（烘焙进内置）

把**当前合并后的词库**（内嵌表 + 目录 txt + 导入文件 + 用户词）写回 bat 的内嵌 here-string，使 bat 成为自包含单文件——之后目录下的 txt 码表文件可以放心删除。

### 6.1 机制

- `SerializeDict(d)`：把词典按码排序序列化为 `码 词1 词2…` 行（与 wgime txt 格式一致，空格分隔——单字不打包，与运行时词典值直接对应）。
- `ReplaceHereString(bat, varName, newBody, out result)`：定位 `$pyData = @'` 等开标记，取其后**首个行首 `'@`** 为结束，整段替换正文。三个 here-string 依次链式替换后整体写回（UTF-8 无 BOM；替换区外字节不变——批处理头保持 CRLF，被替换的表体为 LF，混合换行对 cmd/PowerShell 均安全）。
- **here-string 安全性**：生成内容每行都以编码开头（`[a-z][a-z0-9']*`），不可能出现行首 `'@` 提前终止；单引号 here-string 不做插值、不处理转义，词条中的 `$`、反引号、行中 `@'` 均安全。
- **与缓存的关系**：烘焙不改内存词典（已经是最新合并结果）；下次启动时内嵌表字节变化 → `InputMd5` 失效 → 自动重建 `wgime.mb`（一次性，约 3 秒），之后仍秒开。重复烘焙幂等（已验证字节级一致）。

### 6.2 交互流程（BakeTables）

托盘"固化码表…" → `BakeDialog`（勾选 五笔/拼音/英汉 并显示各自序列化体积；可选"完成后删除目录中对应的 txt / import 文件"）→ 后台线程：

1. 读入 `BatPath`（由 `$env:WGIME_PATH` 传入，改名不影响）全部文本；
2. 先写滚动备份 `wgime.bat.bak-yyyyMMdd-HHmmss`（UTF-8 无 BOM；**备份写失败则整体中止**，bat 不被改动），随后 `PruneBaks` 裁剪：文件名严格匹配 15 位时间戳，按字典序（=时间序）只保留**最新 7 份**，其余删除——无关文件（如 `wgime.bat.bak-notes.txt`、旧版 `wgime.bat.bak`）不参与匹配也不受影响；
3. 按勾选依次替换 here-string 并写回 bat（**写回成功之后**才执行第 4 步）；
4. 可选删除 `py/wb/ec.txt` 与 `import_py/wb/ec.txt` 中对应词库的文件；
5. 气泡提示统计与备份位置。任一步失败：气泡报错，源文件不动。

- 词频（`userdict.txt`）、上次选择（`lastpick.txt`）、用户词（`userwords.txt`）、候选条位置（`pos.txt`）**不参与固化**，仍为独立学习数据。
- 已删除的 txt 若日后想恢复：从任一份 `wgime.bat.bak-*` 备份还原，或重新放置同名 txt 文件（内容会再叠加，重复条目自动去重）。
- 注意：bat 体积会增长到十几 MB，每次启动 PowerShell 需解析更大的脚本文本（略慢数秒，词典本身仍走缓存秒开）。固化写入的是"当时"的合并快照，之后新导入的码表仍通过 import 文件叠加。

## 7. 配置与扩展功能（config.txt）

### 7.1 配置加载（LoadConfig）

bat 目录 `config.txt`（UTF-8），键 = 值，`;`/`#` 注释。启动时加载；托盘"重载配置"再次加载（文件不存在则写出 `DefaultConfigText` 模板）。键：

| 键 | 值 | 作用 |
|---|---|---|
| `fuzzy` | `a-b,c-d` 逗号分隔 / `none` | 覆盖 `DefaultFuzzyPairs`（内置 7 组）；`FuzzyPairs` 由 readonly 改为可变静态 |
| `showcode` | 1/0 | `ShowCode`：候选附反查编码 |
| `paste` | key/on/auto/off | `PasteMode` 3/1/0/2：默认 3（key，逐字符 Unicode 注入）；`on`=剪贴板粘贴（恢复时仅当剪贴板未被用户改动才写回）；`auto`=仅提权窗口走粘贴；`off`=纯 SendKeys。另有按进程覆盖文件 `pastemode.txt`（§3.4） |
| `shuangpin` | xiaohe/ziranma/ms/none | `Shuangpin` 1/2/3/0：双拼方案，默认 0（关闭） |
| `starton` | 1/0 | `StartOn`：启动时 `Hook.IsLocked` 初始值（RunApp 中 LoadConfig 之后、窗体创建之前应用），默认 1 |
| `hotkey_*` / `key_*` | 见使用说明 §9 | 全部快捷键可配置：`KeyBordHook` 静态字段（Mod/Vk 对 + `MatchMods` 严格匹配修饰键），`VkFromName` 键名表、`ParseHotkey` 解析 `ctrl+alt+c` 格式（`none`=禁用，`shift_tap` 哨兵值 0x80000000 表示轻点 Shift）；候选操作键经 `SetKeyConfig`（ref 静态字段）；`LoadConfig` 解析后直接写钩子静态字段，重载配置即时生效 |
| `phrase` | `码<TAB>文本` | 自定义短语（文本可含空格，与码表空格分隔格式独立存储于 `Phrases` 字典） |

（历史：曾实现候选条跟随光标 `GetGUIThreadInfo`，因在部分环境下异常已按用户要求移除。）

### 7.2 以词定字 / 动态候选 / 通配符 / 反查

- 用户词管理：托盘"用户词表…" → `ManageUserWords`（inDialog 守卫 + IsLocked 临时关闭，同导入流程）→ `UserWordsDialog`（ListView 复选，词/编码两列 + 全选/全不选/删除选中/关闭）；`UserWords` 按词排序后填充。删除：移除选中词 → `SaveUserWords` 重写 userwords.txt → 后台 `BuildDicts`+`ApplySwap` 热重载（`BuildDicts` 内部重新 `LoadUserWords`，字典管线自洽）→ 气泡反馈。
- 批量造词：托盘"批量造词…" → `BatchMakeWords`：选文件 → `ReadImportText`（UTF-8/GB18030 自动识别）→ `CollectWordLines`（每行 2-8 汉字、去重、计跳过行）→ `ConfirmWordsDialog` 确认 → `BatchAddWords`（**批量优化**：逐词 `CodeFor` 取拼音码注入 `UserWords`/`PyDict`，最后只做一次 `BuildSorted` + 一次 Acro 注入 + 一次 `SaveUserWords`，避免了 AddUserWord 逐词全量排序/落盘的开销）→ 气泡统计。**造词双注册（2026-08-16）**：用户词同时进五笔表——`CharWb`（字→全码，最长码优先，一二级简码不参与）惰性构建、词库交换（`ApplySwap`）时失效重建；`WubiCodeFor` 按 86 组词规则推导（两字各取前两码 / 三字前两字首码+末字前两码 / 四字以上一二三末各取首码）；`userwords.txt` 仍只存拼音码，五笔侧在 `BuildDicts` 的 `MergeUserWordsWb` 里启动时推导（旧文件完全兼容），运行时 `AddUserWord`/`BatchAddWords` 即时双注入并各自一次重排序；缺五笔码的字只进拼音。测试 `tests/wubi-userwords.tests.ps1` 18 项全过。
- 以词定字：钩子拦截有编码时的裸 `[` `]` → `OnPickChar` → 取候选 1 首/尾字上屏并 `Learn` 记功整词；候选为空时退回中文标点 【 】。
- 动态候选：`AddDynamic` 精确匹配 `rq`（yyyy-MM-dd / yyyy年M月d日 / yyyy/MM/dd）、`sj`（HH:mm / HH:mm:ss / yyyy-MM-dd HH:mm）、`xq`（星期X / 周X），词频排序后插到最前，不参与学习。
- 五笔 z 通配符：`AddWubiWildcard` 对 wb 表线性扫描（≈7.5 万码，微秒级），`z` 位匹配任意字母；不设置 `exactWubi`，不会触发四码自动上屏。
- 反查：`RevWb`（词→五笔码）在 `ApplySwap` 中由 `BuildRevWb` 构建（含导入词条，已在测试中验证 `朗逸→yvqk`）；显示格式 `词(码)`。
- 双拼：`ShuangpinExpand` 把按键按 2 键音节切分，每段依次套用 rime preedit 规则链（`SpRules` 正则替换表，取自 rime-double-pinyin 的 preedit_format，保证键位与官方方案一致）；零声母 aa/oo/ee 折叠、自然码/微软单 `r`→er、ü→v（内置词典约定 lv/lue）；仅 mode<2 的拼音侧使用还原码（`AddFromDict`/`AddAcro`/`AddFuzzy` 参数化 code；五笔与词典模式不受影响）；双拼下 vf 面板与 rq/sj/xq 停用（`vf`/`xq`/`sj` 在双拼里是真实音节）；微软的 ing（`;` 键）经 `KeyBordHook.SemiAsCode` + `OnSemi` 事件进入编码缓冲。
- 简繁转换：OpenCC TSCharacters 单字映射（3602 对，`SimpSeq`/`TradSeq` 双串对齐嵌入，`ToTrad` 惰性建 `Dictionary<char,char>`，多繁体映射**先到先得**=最常用形）；`Send` 提交点与 `RefreshLabel` 显示统一转换，内部词库始终简体；`Ctrl+Shift+F`（钩子 VK_F+Ctrl+Shift 分支）与托盘"简繁输出"翻转 `Trad`；config `trad=1/0`。字符级局限：发/干/后等上下文相关字不做词组消歧。
- v 模式：`AddVMode` 对 `^v\d{1,16}$` 生成 大写金额（`UpperAmount`：4 位分组 万/亿/兆/京 + 跨组/组内零规则 + 恒输出"元整"）与千分位（`Thousands`）候选，dynSet 标记不学习；数字键在 `keys=="v"`（双拼/五笔/词典模式外）经 `KeyBordHook.DigitAsCode` + `OnDigit` 追加进编码缓冲。
- vf 符号面板：`ShowCharatar` 在 `keys=="vf"` 时短路词典管线（与模式、词库无关）；`symCat`（0=根目录，1..5=分类）驱动两级候选。根目录数字选分类、空格忽略；分类内数字/空格选符号上屏（跳过 `Learn`/`RecordCommit`，不污染词频），`=`/`-` 复用现有翻页；退格回根目录、Esc/Enter 关闭、字母键退出面板（`keys` 变长即 `symCat` 复位）；面板内标点/以词定字被守卫，不自动提交"分类名"。符号数据为 `SymCatNames`/`SymCats` 静态数组（5 类 141 符号，含代理对 emoji，经 `FillUnicodeEvents` 上屏）。
- 候选条 emoji 渲染：GDI+ Label 无字体回退，emoji 最初画成方块。自定义 `BarLabel` 把文本按 run 拆分（`Runs`）：基础 run（微软雅黑）走 GDI+ `DrawString`；emoji/符号 run（U+2190–U+2BFF、代理对、VS16，`EmojiAt` 判定）**优先绘制内嵌彩色 PNG**。背景：逐路径探针实测，GDI（不支持 COLRv1）、GDI+（无彩色字体支持）、RichEdit 2.0/5.0、WPF 软件光栅器在这台 Win11 上全部只画单色轮廓，硬件 D2D 又无法用于 Opacity 分层窗口——**图片是唯一可靠彩色路径**。33 个 emoji 分类符号内嵌 Microsoft Fluent Emoji 3D 图（48px PNG，MIT 协议，微软官方开源、Windows 11 同款风格；base64 存 `EmojiPngs`，`EmojiImage` 惰性解码缓存），按 `Font.GetHeight()+2` 等比缩放绘制；无图片的符号回退 GDI 单色字形。宽度由 `BarWidth` 按 run/字符（图片宽）测量。

### 7.3 应用启动器与内嵌应用

- **注册表**：`Apps: code -> [名称, 命令, 参数]`。内置编码：`jsq`/`calc`（计算器）、`itools`/`tools`（工具箱）、`net`/`wlgj`（网络工具）、`clip`/`jlb`（剪贴板历史）、`bj`/`notes`（便签）、`ys`/`color`（颜色拾取）、`plugins`/`cjgl`（插件管理）。config.txt 可挂外部程序/目录/网址：`app = 码<TAB>名称<TAB>命令[<TAB>参数]`（`UseShellExecute` 打开）。
- **候选注入**：`AddAppCand` 在编码精确命中时把 `▶名称` 插到候选最顶（双拼下停用，与 rq/sj/xq 同理）；`Hook_OnSpaced` 命中 `appSet` 时走 `LaunchApp` 而非 `Send`，跳过 `Learn`/`RecordCommit`。
- **命令类型**：`builtin:xxx` → 内嵌窗体；`plugin:<file>` → 步骤 DSL 插件；`codeplugin:<file>` → C# 插件；其余 → `Process.Start`。
- **内嵌窗体**（全部 TopMost、Esc 关闭、后台线程干活不卡 UI）：
  - `CalcForm`：递归下降表达式解析（+ - * / % 括号，全角 ×÷（）自适应，整数/双精度格式化）；
  - `ToolsForm`：tools.txt 驱动的多标签按钮面板 + 日志窗（步骤后台线程逐条执行，confirm 可中止）；
  - `NetToolsForm`：Ping/Tracert（`System.Net.NetworkInformation.Ping`）/子网计算（`SubnetCalc`：/31、/32、非连续掩码等边界全处理）/端口检测（BeginConnect+超时）/本机信息；日志带时间戳、只增不减、可保存；
  - `ClipForm`：`AddClipboardFormatListener` + `WM_CLIPBOARDUPDATE` 监听（窗体开着才监听），`ClipPush` 去重置顶、上限 200，点选复制回剪贴板（`selfSet` 防自环）；
  - `NoteForm`：800ms 防抖自动保存 `%LOCALAPPDATA%\wgime\notes.txt`；
  - `ColorForm`：取色期间挂临时 `WH_MOUSE_LL` 钩子（左键取色并吞掉这次点击、右键取消），`CopyFromScreen` 取像素，显示 HEX/RGB/HSV 并可复制；
  - `PluginMgrForm`：插件列表（名称/编码/类型/编译状态/文件）+ 重载/打开目录/编辑/删除（带确认）/新建模板。**有意不进托盘菜单**（工具箱同为启动器唤出）。

### 7.4 工具箱与插件系统（tools.txt / plugins\）

- **tools.txt**：bat 同目录，UTF-8。`[tab 名]` 开标签页、`[按钮名]` 加按钮、其余行为步骤。步骤动词：`msg`/`confirm`/`run`/`shell`/`open`/`kill`/`wait`/`reg-set`/`reg-del`/`file-del`（通配+递归+根目录保护）/`mkdir`；`[shell]...[/shell]`（临时 .cmd，ANSI）与 `[powershell]...[/powershell]`（临时 .ps1，**UTF-8 BOM + 强制 UTF-8 输出**——PS 5.1 无 BOM 按 ANSI 读、重定向时默认 ASCII 会把中文变 `??`，两个坑都已在 `RunScriptBlock` 处理）多行块。解析：`ToolToks`（引号分词）+ `ToolPath`（引号剥离+环境变量展开）+ `ToolRegSplit`（HKCU 等 hive 映射）；执行 `ExecToolStep`（null=成功，`"abort"`=用户取消，其余=错误文本）。
- **plugins\\*.txt**：头部 `code`/`name`/`desc`（`=`/`:` 均可），之后为步骤区；**`[csharp]` 块则整件变代码插件**：CodeDom 内存编译（引用 System/Forms/Drawing/Core/Data，**C# 5 语法**），契约 = 一个 `public static void Run()`；编译错误缓存，运行时气泡报行号。`Run()` 在**插件专用 STA 线程**（`WgImePlugins`，隐藏 Control 做 BeginInvoke 封送，`Application.Run()` 自持消息循环）执行——插件可直接 `Show()` 窗体，阻塞只波及插件自己的窗口，不影响输入法。插件最后注册，编码冲突时覆盖内置与 config。
- 结构要点：`ParseToolSteps` 为步骤/脚本块共用解析器；`PluginActions`（步骤插件）与 `PluginCodeCache`（代码插件）分存；`LoadPlugins` 由 `LoadConfig` 末尾调用（重载配置即时生效）。

### 7.5 首次运行播种

PS 引导层在 `RunApp` 之前内嵌四段 here-string 种子（`$seedTools`/`$seedPluginReadme`/`$seedCleanBin`/`$seedClock`）。哨兵 `%LOCALAPPDATA%\wgime\provisioned.done` 存在则跳过；否则写出缺失的 `tools.txt`、`plugins\README.txt`（精简规范）、`clean-bin.txt`、`clock.txt` 并落哨兵。**绝不覆盖已有文件**；用户删除示例不复活，删哨兵可重播。种子与仓库文件的逐字节一致性由 `tests/seed-sync.tests.ps1`（14 项）守住。

## 8. 线程模型与并发

| 线程 | 职责 |
|---|---|
| STA 主线程（PowerShell -STA） | 消息循环：钩子回调、窗体、托盘、SendKeys |
| 后台 Task（线程池） | 词典全量构建/热重载、码表转换写文件 |
| `DictLock` | 串行化 BuildDicts（启动与热重载并发时排队） |
| `DictsReady` | 词典就绪标志（volatile），就绪前候选条显示"词库加载中" |
| 交换原子性 | ApplySwap 一次替换全部静态引用；Freq/LastPick 不参与交换 |

## 9. 数据文件清单

**bat 目录（C:\Tools\WgIme\）**

| 文件 | 说明 |
|---|---|
| `wgime.bat` | 程序本体 |
| `config.txt` | 配置（模糊音/短语/showcode/paste），托盘"重载配置"可生成模板 |
| `wgime.bat.bak-yyyyMMdd-HHmmss` | 固化码表前的滚动备份，自动保留最新 7 份 |
| `py.txt` / `wb.txt` / `ec.txt` | 扩展词典（`码 词 词…`，UTF-8），可选 |
| `import_py.txt` / `import_wb.txt` / `import_ec.txt` | 码表导入产物，启动自动叠加，删除即撤销导入 |
| `tools.txt` | 工具箱配置（§7.4），首次运行自动播种 |
| `plugins\` | 插件目录（§7.4）：`README.txt` + `clean-bin.txt` + `clock.txt` 为播种示例 |
| `build-full-singles.ps1` | 全单字内嵌表构建脚本（§4.1 注） |

**%LOCALAPPDATA%\wgime\**

| 文件 | 说明 |
|---|---|
| `wgime.mb` | 词典二进制缓存（可随时删除，下次启动重建） |
| `WgIme.<hash>.dll` | 预编译载荷（自动维护，旧版自动清理） |
| `userdict.txt` / `lastpick.txt` | 词频与每码上次选择 |
| `userwords.txt` | 用户造词 |
| `pos.txt` | 候选条位置（followcaret=1 时仅作兜底） |
| `pastemode.txt` | 按进程上屏方式覆盖（`程序名.exe=clipboard/sendkeys/key/keyfix/keyplain`），托盘切换自动维护 |
| `notes.txt` | 便签内容（bj/notes 自动保存） |
| `provisioned.done` | 首次播种哨兵（存在则跳过播种；删除可重播） |
| `mb_error.log` | 词典构建异常日志 |

## 10. 日志与排错

- `%TEMP%\WgIme_error.log`：启动全过程（OS/PS 版本、LanguageMode、DLL 加载/编译、FATAL）。
- `set WGIME_DEBUG=1` 后运行 wgime.bat：保留控制台，错误红字显示并暂停。
- 典型问题：
  - `ConstrainedLanguage`：内存编译被策略禁用且无可用 DLL → 日志有 HINT，需管理员放行 `%LOCALAPPDATA%\wgime` 或签名脚本；
  - 钩子失败：托盘弹气泡"钩子失败, 见 %TEMP%\WgIme_error.log"（候选条不显示任何指示）；
  - 词典构建异常：`mb_error.log`。

## 11. 开发与维护

### 11.1 修改 C# 源码后重建预编译载荷（必须）

用 **Windows PowerShell 5.1**（勿用 pwsh 7，.NET Core 编出的程序集无法被 5.1 加载）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File rebuild.ps1
```

脚本解剖（rebuild.ps1）：读取后先归一化为 LF 处理 → 提取 `$cs` here-string → 编译到 `%TEMP%\wgime_new.dll`（引用 System.Windows.Forms / System.Drawing / UIAutomationClient / UIAutomationTypes / WindowsBase；失败则 bat 不被改动）→ base64 替换 `###WGIME_DLL###` 载荷行（单引号包裹）→ 以 CRLF 写回并硬断言无 BOM、无裸 LF（纯 CRLF）。运行时首次启动会按 `MD5(base64)前8位` 生成新 DLL 名并自动清理旧版本。

**只改数据/引导层不用重建**：内嵌码表用 `build-full-singles.ps1`（全单字合并：内嵌 + py.txt/wb.txt 单字 + Unihan 派生表 tests/pinyin-data.txt 补齐，自带时间戳备份与 BOM/批处理头 CRLF 校验）；PS 引导层（含播种种子）改动直接生效。

### 11.2 测试套件清单

全部用 PowerShell 5.1 跑（`powershell.exe -File tests\xxx.ps1`）：

| 文件 | 覆盖 |
|---|---|
| `wgime.tests.ps1` | 词典管线/缓存/造词/配置写回等核心夹具（22 项） |
| `e2e-real-dict.ps1` | 真实码表端到端构建与缓存命中 |
| `check-payload-consistency.ps1` | 内嵌 DLL 载荷 IL 与 $cs 新编译逐方法一致（防忘重建） |
| `keyfix-mode-check.ps1` | 标点吞字修复路由（StaleTrigger 表 / EffectiveKeyfix 优先级） |
| `keyfix-neutral-check.ps1` / `keyfix-neutral-dump.ps1` | X+退格在普通控件自我中和（字节级断言 / 消息流取证） |
| `wechat-*.ps1` | 真实微信注入复现/方案验证/出厂代码端到端（需要微信开着） |
| `caret-follow.tests.ps1` / `caret-probe*.ps1` / `caret-wechat-verify.ps1` | 光标跟随三级回退（真实 caret / 微信实测锚点） |
| `app-launcher.tests.ps1` | 计算器解析器 / Apps 注册表 / 窗体渲染 |
| `tools.tests.ps1` | tools.txt DSL 解析与执行（含脚本块、注册表回环、根目录守卫） |
| `plugins-applets.tests.ps1` | 插件系统（DSL + C# 编译 + 覆盖优先级）/ 剪贴板/便签/取色 / 插件管理窗体 |
| `nettools.tests.ps1` | 子网计算边界 / ping / tracert / 端口检测 / 本机信息 |
| `dict-coverage.ps1` | 内嵌表单字覆盖率分析（配合 build-full-singles.ps1 验收） |
| `seed-sync.tests.ps1` | 首次播种种子与仓库文件逐字节一致 + 播种逻辑结构断言 |

### 11.3 编码与格式约束（踩坑清单）

1. **C# 5.0**（CodeDom/csc）：禁 `$"…"` 插值、`?.`、表达式体成员、`nameof`、`using static`。
2. **批处理头（`###PWSH###` 之前）必须为 CRLF 换行、无 BOM、UTF-8**——cmd.exe 依赖 CRLF 解析标签/括号块/`exit /b`；纯 LF 会让 cmd 把行切碎并跌进 PowerShell 段（报 `'xxx' is not recognized`）。here-string 数据体可以是 LF（烘焙/播种替换产生混合换行也安全），PowerShell 与 C# 对两种换行都能解析。仓库用 `.gitattributes` 的 `eol=crlf` 强制保证克隆产物可直接运行；rebuild.ps1 写回纯 CRLF 并硬断言。
3. 新增 C# 代码**不得以行首 `'@` 开头**（会提前终止 here-string）；`'@` 行首仅允许出现在三个数据表与 $cs 的结束行。
4. `###WGIME_DLL###` 全文件只出现一次（加载器代码里拆成两段字符串拼接），勿在别处复制该字样。
5. SendKeys 输出需经 `Sanitize` 转义；钩子依赖 `LLKHF_INJECTED` 防回环。
6. 候选词不得含空格（分隔符冲突），导入转换器已自动跳过此类词条。
7. **PS 5.1 读无 BOM 的 .ps1 按 ANSI 解码**——所有测试/工具脚本必须纯 ASCII，中文一律用码点构造；多行 PS 块的临时 .ps1 由 `RunScriptBlock` 带 BOM 写出。
8. **PowerShell 反射三坑**：函数返回的集合会被管道拆包（单元素 List 被拆成本体，`.Count` 量出的是元素数——用 `(, $v)` 或强类型变量阻止）；`@()` 里内联 `New-Object` 会包 PSObject 导致反射绑定失败（先赋给强类型变量）；私有嵌套类字段只能走 `GetField(..., NonPublic)` 读，ETS 不暴露。

## 12. 已知局限

- **注入上屏**：管理员权限窗口/部分 UWP 应用可能拒绝注入；游戏全屏输入不支持。Qt 应用（微信 4.x）的 VK_PACKET 陈旧字符问题已由 keyfix 全局修复（§3.4）；顽固程序可按进程覆盖（pastemode.txt）。
- 单实例（Mutex `WgImeSingleInstance`）。
- 码表词条不支持内嵌空格；每码候选上限 60（显示）、每码存储上限 300（导入）。
- 钩子放行一切含 Ctrl/Alt/Win 的组合键，无法自定义组合快捷键。
- 不支持 .scel（搜狗二进制词库）等二进制格式导入。
- 固化码表后 bat 体积增大到约十几 MB，启动时 PowerShell 解析脚本文本略慢（词典加载本身仍走 `wgime.mb` 缓存秒开）。
