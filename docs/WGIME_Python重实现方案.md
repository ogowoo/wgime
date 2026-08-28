# WgIme Python 重实现方案评估

> 版本：2026-08-25 ｜ 状态：评估文档（含已验证的可行性 spike）
> 目的：评估把 `wgime.bat`（bat+PowerShell+内存编译 C#）重实现为 Python 的可行性、选型与迁移路线。

---

## 1. 现状盘点（为什么要慎重）

`wgime.bat` 是一个 **3.4MB 单文件、免安装、零依赖** 的混合体：

| 层 | 内容 | 规模 |
|---|---|---|
| cmd 引导 | 读自身 → 提取 `###PWSH###`..`###WGIME_DATA###` 段 → powershell -STA Invoke-Expression | ~60 行 |
| PowerShell 引导 | 读码表数据块、编译/加载内嵌 DLL、种子播种 | ~500 行 |
| C#（`$cs` → 瘦 DLL 555KB） | **WordBoard 输入法核心**（~240KB 源，61+ 方法）+ 工具箱/网络工具/剪贴板/便签/取色器/插件系统（~250KB 源） | ~500KB C# 源 |
| `###WGIME_DATA###` | 内置码表 py/wb/ec/pywords/pywfreq | ~1.4MB 文本 |

WordBoard 的职责（都是硬需求）：

- `WH_KEYBOARD_LL` 全局低级键盘钩子 + 按模式吞键/转发 + `SendInput` UNICODE 上屏
- 候选条：无边框置顶自绘（emoji 图片候选）、跟随光标（`GUIThreadInfo`）
- 引擎：拼音/五笔/混合/英汉四模式、简拼、模糊音、双拼、繁简转换、造词确认、词频学习（后台落盘）、每应用独立模式（`AppModes`）
- 码表：py.txt(4.8MB)/wb.txt/ec.txt(23MB)/import_* 解析 + WGB4 缓存（命中 ~1.6s 启动）
- 外挂生态：`tools.txt` 步骤 DSL、`plugins\*.txt` 插件（含 `[csharp]` CodeDom 内存编译插件：calc/clock/chat/clean-bin/qping/wgtranslate）

**已做的性能优化**（重实现必须追平，否则是倒退）：启动缓存命中 ~1.6s、码表固化（BakeTables）、词频后台保存、启动计时日志。

---

## 2. 可行性 spike（已实机验证，代码在 `tests/python-spike/`）

用**纯标准库**（ctypes + tkinter，零第三方依赖）验证了最危险的四个假设：

| 假设 | 结果 |
|---|---|
| ctypes 装 `WH_KEYBOARD_LL` 全局钩子 | ✅（**坑：必须 `hMod=NULL`**，传 python.exe 模块句柄报 1428/126；回调签名要用指针宽度类型 `c_ssize_t/c_size_t`） |
| 钩子内吞键 + 缓冲拼码 | ✅ F8 开关、字母缓冲、Backspace/Esc 处理均正常 |
| 码表加载与查找性能 | ✅ py.txt 169130 条加载 **212ms**；单键查找 **<0.01ms** |
| `SendInput(KEYEVENTF_UNICODE)` 上屏中文 | ✅ 输入 `nihao` 空格上屏"你好" |

tkinter 无边框置顶候选条（`overrideredirect` + `-topmost`）可用。

**结论：技术上完全可行。** 钩子延迟对人类打字（<20 键/s）毫无压力；真正的工作量在功能对齐，不在可行性。

---

## 3. 技术选型对比

### 方案 A：纯标准库（ctypes 钩子 + tkinter UI）

- 依赖：零（Python 官方安装包即可）
- UI：tkinter Canvas 自绘候选条可行；圆角/悬停态能做但繁琐；托盘图标需 ctypes 调 `Shell_NotifyIcon`（能做）
- 插件生态：**C# 插件全部报废**，需改用 Python 插件 API 并重写 6 个现有插件
- 打包：PyInstaller onefile ≈ 12-18MB，或"embeddable zip 塞进 bat"延续现有单文件形态

### 方案 B：pythonnet + WinForms（推荐）

- `pythonnet 2.5.2` 加载 .NET Framework 4.x CLR（Windows 自带，无需装运行时）
- UI **继续用 WinForms/GDI+**——窗体设计语言（圆角 Rgn、FlatBtn、RoundedEdit）逐行可搬，与 WgIme 家族窗体外观 1:1
- **`CSharpCodeProvider` 照样可用** → `[csharp]` 插件生态完整保留（chat/clock/calc 等零改动）
- 托盘 `NotifyIcon`、注册表、DPI 等与现在完全一致
- 风险：pythonnet 2.5.2 较老（仅支持 ≤Python 3.8 的轮子；3.12 需源码装或换 `pythonnet 3.x`+`.NET 6 Desktop Runtime`——那就要求用户装 .NET 6 桌面运行时，破坏零依赖）；GIL 与 WinForms 消息循环要按"主线程跑 Application.Run、Python 工作线程经 BeginInvoke 回 UI"的规矩来

### 方案 C：PySide6 / PyQt6

- UI 最现代、自绘最舒服；但 bundle 40MB+，且 C# 插件无法保留
- Qt 的全局钩子仍要 ctypes（Qt 不管系统钩子）
- 对"免安装单文件"伤害最大

### 方案 D：不换（维持 C#）

- 现有架构的痛点其实不在性能，而在**可维护性**：500KB C# 嵌在 PS here-string 里、无 IDE 支持、构建链脆弱（切片行号/瘦 DLL/三处同步）
- 如果痛点只是维护性，替代选项是**纯 C# 项目化**（.csproj + 编译期嵌资源 + 单文件 exe，.NET 4.x 仍免安装），比换语言代价小一个数量级

### 选型建议

- 目标是"**保留全部功能与插件生态、改善可维护性**" → **方案 B（pythonnet+WinForms）**，或先认真考虑方案 D 的"纯 C# 项目化"
- 目标是"**拥抱 Python 生态、可以接受插件重写**" → 方案 A（stdlib）最干净
- 不建议方案 C（bundle 大、插件生态损失无补偿）

---

## 4. 迁移路线（以方案 B 为例，A 同理砍插件兼容层）

**阶段 0 — 双轨骨架（1 个里程碑）**
- `wgime.py`：托盘 + 钩子 + 候选条 + py.txt 单模式打字（spike 已经证明可行性，扩成正式骨架）
- 与现有 bat 并存，不改现有发布物

**阶段 1 — IME 核心对齐**
- 四模式切换、简拼/模糊音/双拼/繁简、造词、词频学习与后台保存
- 码表缓存：Python 侧用 `marshal`/自定义二进制格式复刻 WGB4（或干脆共享读取 WGB4，缓存互通）
- 验收：同一 py.txt，候选顺序与 C# 版逐条一致（候选排序确定性是 §5.11 踩过的坑——遍历顺序要稳定排序）

**阶段 2 — 外壳与工具**
- 托盘菜单、配置窗、工具箱（tools.txt DSL 解释器用 Python 重写，DSL 本身不变）
- 便签/剪贴板/取色器/网络工具逐个搬（都是独立窗体，可分批）

**阶段 3 — 插件系统**
- 方案 B：CodeDom 直通（`[csharp]` 插件零改动）
- 方案 A：定义 Python 插件 API（`Run()` 入口 + 托盘/气泡/定时器原语），重写 6 个官方插件

**阶段 4 — 打包与发布**
- 单文件形态两条路：
  1. PyInstaller onefile exe（~20MB，首次解压到 %TEMP% 有 ~1s 开销）
  2. **延续现有 bat 形态**：bat 内嵌 python embeddable zip + 应用代码 + 码表数据块，首启解到 `%LOCALAPPDATA%\wgime\runtime\`（与现有 DLL 缓存同思路）——最贴近"免安装单文件"的现有体验
- 测试矩阵对齐现有 tests（启动/单实例/码表固化/插件编译/互通）

---

## 5. 风险清单

| 风险 | 程度 | 对策 |
|---|---|---|
| 钩子在 Python 里跑，GC/GIL 卡顿导致系统摘钩（LowLevelHooksTimeout） | 中 | 回调里只做入队，处理放工作线程；C# 版同样面临 GC 问题，实测可接受 |
| pythonnet 2.5.2 不支持新 Python / 3.x 要 .NET 6 运行时 | 中（方案 B） | 锁 Python 3.8 embeddable；或接受 .NET 6 依赖；或转方案 A |
| 码表解析冷启动（23MB ec.txt）Python 比 C# 慢 3-5 倍 | 低 | 缓存命中路径为主；冷解析用 `str.split` 批量化可到秒级（spike: 169k 条 212ms） |
| 内存占用高于 C#（大 dict 2-4 倍） | 低 | ec.txt 懒加载/转 SQLite |
| 候选排序与 C# 版不一致（dict 遍历顺序） | 中 | Python 3.7+ dict 保插入序，解析顺序固定即可；加候选一致性 diff 测试 |
| 插件生态断裂（方案 A/C） | 高 | 方案 B 规避；否则全部插件重写 |
| 双轨期用户困惑 | 低 | 独立发布通道，明确"实验版"标记 |

## 6. 结论

1. **可行**——最危险的钩子/性能/上屏三点已实机验证（`tests/python-spike/spike.py`）。
2. **值不值**取决于动机：若痛点是维护性，先做"纯 C# 项目化"（方案 D 变体）代价最小；若就是要 Python 生态，走方案 B 能保住插件与 UI 资产。
3. 建议第一步：阶段 0 双轨骨架（纯 ctypes+tkinter 或 pythonnet 均可），一周内能打出"能用的拼音输入法"，再决定是否全量迁移。

---

## 7. 阶段 0 已完成（2026-08-25，方案 B 骨架）

`wgime-py/`（仓库根目录）：`wgime.py`（主程序/状态机/托盘）+ `bridge.cs`（C# 实时层，运行时 CodeDom 编译、md5 缓存 DLL）+ `engine.py`（码表引擎）。

**运行环境**：Python 3.8 embeddable + pythonnet 2.5.2 + .NET Framework 4.x（Windows 自带，用户零依赖）。功能：F8 开关、托盘（启用/退出）、单实例、拼音整码输入（缓冲/选词/翻页/退格/Esc/回车上屏原文）、跟随光标的圆角候选条。字典加载 ~250ms。

**实机验证**：记事本内 `zhongguo` → 候选条 `1.中国 2.众过 3.忠果 4.重国` → 空格上屏"中国"；注入目标窗口确认为前台 Notepad。

**踩坑记录（后续阶段必读）**：

1. **钩子回调不能跨进 Python**：LL 钩子有 LowLevelHooksTimeout，Python 处理慢/抖动会被系统静默摘钩（实测出现"偶发不拦截"）。解法：C# 侧做吞键判定（激活态+键类白名单），事件入 `ConcurrentQueue`，Python 工作线程消费——关键路径零 GIL。
2. **SendInput 的 INPUT 结构必须恰好 40 字节（x64）**：多一个 long 垫片（48 字节）会导致 `SendInput` 返回 0 静默失败，或布局错位注入乱码。
3. **WinForms 控件句柄必须在泵线程创建**：候选条先在主线程取一次 `.Handle`，否则首次 `InvokeRequired` 判定为 false，在非泵线程建句柄后 BeginInvoke 全部卡住（实测队列延迟 ~15s）。
4. **pythonnet 命名空间**：运行时编译的程序集要放在命名空间里（如 `namespace WgBridge`）才能 `from WgBridge import ...`；全局命名空间的类型拿不到。
5. **out 参数**：Python 侧别用——C# 侧包一个 `Next()` 返回 null 的方法更省事。
6. pip 安装要绕本机系统代理：`NO_PROXY=*`；embeddable Python 装 pip 直接解压 wheel 到 `Lib\site-packages` 并在 `._pth` 里加该行。

---

## 8. 阶段 1 已完成（2026-08-25，IME 核心对齐）

逐行对照 C# WordBoard 移植（`wgime-py/engine.py` + `wgime.py` + `bridge.cs`）：

- **四模式**：0=混合(五笔先) 1=拼音 2=五笔 3=词典(英汉+汉反查)；`Ctrl+\`` 循环、Shift 轻拍开关、`Ctrl+Shift+F` 繁简（3602 对映射抽自 C# 内嵌表 → `trad.txt`）
- **候选组装**与 `ShowCharatar` 同序：精确匹配 → 前缀单字（bisect 走排序数组）→ 简拼 → 模糊音（7 对单替换，上限 16）→ 词频稳定排序（分模式桶）→ lastpick 置顶；`CandCap=60`/`PageSize=9` 一致
- **五笔四码唯一自动上屏**（仅纯五笔模式，与 C# 一致）；`[`/`]` 取首候选首/末字
- **词频学习**：分模式桶 + 合并视图，`userdict_{mix,py,wb}.txt`/`lastpick_*.txt` 与 C# 版**同格式可互换**，50 次或 5s 后台落盘、退出同步落盘
- **码表缓存**：pickle（含排序数组/简拼/反查索引，按输入文件 size+mtime 签名失效）——冷启动 7.3s → **热启动 1.35s**（含 ec.txt 65.8 万条 + 汉英反查 70.2 万条），已与 C# 版缓存命中同级
- **注入竞态修复**：注入前 30ms 沉降（被吞按键的 keyup 排空后再 SendInput）——此前快速连打 6 次只落 1 次，修后 6/6
- **验收**（`wgime-py/tests/accept-test.ps1` 实机驱动记事本）：混合 zhongguo→中国、拼音 nihao→你好、五笔 wqvb→自动上屏你好、词典 apple→苹果、繁简中國、Shift 轻拍中英切换，全部通过

**阶段 1 未做（留给后续）**：造句（BestSentence）、联想行（assoc）、rq/sj/xq 动态候选、vf 符号面板、v 模式金额、应用启动码、短语、五笔 z 通配、造词/用户词、config.txt、PasteCommit/UIPI 提权窗口、Qt stale-char keyfix、每应用模式、emoji 候选。

---

## 9. 阶段 2 第一批已完成（2026-08-26）

- **造句**：一元格架（`pywfreq.txt` 71580 条词频抽自 `###PYWFREQ###` 数据段，`log(f+1) - edges*LogTotalW`），拼音模式/混合长码触发；实测 `zhonghuarenmingongheguo` → 首候选"中华人民共和国"
- **动态候选**：rq（日期三格式）/sj/xq 置顶不入学习；**v 模式金额**（千分位 + 大写金额，与 C# `UpperAmount`/`Thousands` 逐行一致，含零分组规则）
- **联想行**：连续上屏词对学二元组（RecordCommit 语义），上屏后出"↪联想"行，数字选、空格出真空格；`assoc.txt` 与 C# 同格式
- **简拼按词频重排**（ApplySwap 的稳定降序）
- **修坑**：① bridge `IsImeKey` 漏了数字 0（v 模式含 0 金额全乱）；② v 模式数字路由与 C# 完全一致——裸 'v' 有候选时数字选词、超出候选数才续码（wb.txt 里 'v 发' 有候选，所以 v2024 按 C# 语义就是选词——**这是 C# 现状的 quirk，不是移植 bug**）
- 验收：六场景（混合/拼音/五笔/词典/繁简/Shift）+ 造句 + rq + 联想链（中国→美国 学习并出联想行）全部实机通过

---

## 10. 阶段 2 第二批已完成（2026-08-26）

- **config.txt 加载**（与 C# `LoadConfig` 同格式）：fuzzy/showcode/hideidle/shuangpin/trad/sentence/assoc/starton/app 条目全支持；托盘"重载配置"即时生效
- **双拼三方案**（小鹤/自然码/微软，规则抽自 C# `SpRules` 的 rime preedit_format）：`SpSegment`/`ShuangpinExpand` 逐行移植，单测 nihc→nihao、ul→shuang、h;→hing 全对；微软方案 `;` 作 ing 码（bridge 按 `SemiAsCode` 门控吞键）
- **vf 符号面板**：vf 出五分类（单位/标点/图形/数学/emoji），数字进分类、数字/空格选符号、退格回根、`=`/`-` 翻页；emoji 用文本渲染（C# 版的 Fluent PNG 是另一条路线，文本先用系统 emoji 字体）
- **五笔 z 通配**：纯五笔模式下含 z 的码追加通配候选（不参与词频排序，与 C# 同序在最后）
- **造词**：连续单字上屏（90s 内、2-4 字、全拼码可验证）自动造词；`Ctrl+Alt+C` 剪贴板造词；用户词进拼音表+五笔表双注册（`WubiCodeFor` 86 构词规则），`userwords.txt` 与 C# 同格式
- **应用启动码**：config `app =` 条目中编码后出 ▶候选，选中即启动（URL/程序/带参命令）
- **托盘菜单**：开关/四模式直选/繁简/重载配置/打开数据目录/退出
- **验收**：vf 面板两级截图验证、Ctrl+Alt+C 造词落 userwords.txt、单字连打自动造词（什井→shenjing）、双拼单测全过

---

## 11. 阶段 2 第三批已完成（2026-08-26，上屏健壮性）

- **上屏方式路由**（`EffectiveMode` 语义）：paste=auto/on/off/key + 每程序 pin（`pastemode.txt` 同格式）；auto 模式下检测前台提权窗口（UIPI）自动改剪贴板粘贴
- **PasteCommit**：保存原剪贴板 → SetText → 60ms 沉降 → 注入 Ctrl+V → 150ms → 300ms 后恢复原剪贴板（未被改动才恢复）；实测 notepad pin 到 clipboard 后"你好"正确上屏且剪贴板原样恢复
- **Qt stale-char keyfix**：全角标点后注入 X+Back 吸收擦除（微信 4.x 等 Qt 应用的吞字规避），per-app pin 可关
- **钩子注入过滤**：自家 SendInput 事件带 `dwExtraInfo=0x5747494D('WGIM')` 标记，钩子见 `LLKHF_INJECTED+MAGIC` 直接放行——修掉"粘贴的 Ctrl+V 被自家钩子当字母 v 吞掉"的互踩；外部测试工具（SendKeys，无标记）仍可驱动
- 托盘新增"当前程序：剪贴板上屏切换 / 标点吞字修复切换"

---

## 12. 阶段 3 第一批已完成（2026-08-26，外挂生态）

- **插件系统**：`plugins\*.txt` 解析（code/name/desc 头 + 步骤 DSL 或 `[csharp]`）；`[csharp]` 走运行时 CodeDom 编译 + 专用 STA 线程（`PluginHost`：`Application.Run` + 定时器泵队列），错误落盘 + 弹窗；与 WgIme 宿主同契约——`lt` 选中 ▶聊天 即弹出真正的聊天窗（验证通过）
- **步骤 DSL 执行器**（`plugins.py`）：msg/confirm/run/shell/shellx/open/kill/wait/reg-set/reg-del/file-del/mkdir + `[shell]/[powershell]/[shellx]/[psx]` 块（ANSI .cmd / UTF-8 BOM .ps1，临时文件）；失败记日志不中断、confirm 选否中止
- **工具箱窗体**：`tools.txt` tab/cols/按钮解析 → TabControl + 按钮网格，点击后台执行对应步骤
- **插件管理窗体**：列表 + 启用/禁用（`plugins-disabled.txt`）+ 重载
- **剪贴板历史**：轮询剪贴板序列号，30 条历史，复制选中/粘贴上屏
- **便签**：多行文本自动保存 `notes.txt`
- **启动器整合**：候选条 ▶ 前缀合一（config app= / 插件 / 工具 code / 内置 itools·plugins·jlb·bj）
- 关键修坑：pythonnet 内置窗体不能在工作线程建（无消息泵）——统一 `PluginHost.Post(System.Action(...))` 调度到 STA 线程；pythonnet 的 lambda 不能直接传 `Post(Action)`，需 `System.Action(...)` 显式包装
- **遗留**：取色器、网络工具、emoji 图片版候选、打包发布（embeddable zip 内嵌 bat 或 PyInstaller）

---

## 13. 阶段 3 第二/三批已完成（2026-08-26，窗体套件 + 免安装单文件打包）

- **取色器**：跟随光标无边框放大镜，实时显示颜色值，点击复制 hex + 气泡
- **网络工具**：ping/tracert/nslookup 深色控制台窗体（后台 Popen 流式输出）
- **免安装单文件打包**（`build-wgime-py.ps1` → `dist\wgime.py.bat`，42.5MB）：
  - 结构仿 wgime.bat：cmd 引导 → 按 `###PYZIP###/###APP###/###DICTS###` 标记（**base64**）→ PowerShell 解压到 `%LOCALAPPDATA%\wgime-py\runtime`（版本标记 `.ok` 缓存）→ `python.exe wgime.py`
  - 内嵌：Python 3.8 embeddable + pythonnet 2.5.2（扁平 clr.pyd/Python.Runtime.dll）+ 应用脚本 + 小数据（trad/pywfreq/config/tools/plugins）+ 全部码表（py/wb/ec/import）
  - 实测端到端：双击 bat → 首次解压 → IME 托盘启动（`started, dict 9s` 冷解析，后续走 pickle 缓存）
- **打包踩坑（记录）**：① PowerShell 函数调用 `f('a','b','c')` 是**单个数组参数**——必须 `f 'a' 'b' 'c'` 空格分隔；② 标记在解压脚本里也出现——提取用 `LastIndexOf`；③ `.NET Framework` 的 `ZipFile.ExtractToDirectory` 无 bool 重载；④ `$env:TEMP` 是 8.3 短路径而 `FileInfo.FullName` 是长路径——相对路径子串要用 `[IO.Path]::GetFullPath` 归一化；⑤ cmd 不解析 `$`，powerShell 块要压成单行 + 单引号保持字面量
- **打包遗留**：emoji 图片版候选（当前文本渲染）、码表选配（可去掉 23MB ec.txt 减包）

---

## 14. 纯 Python 版已启动（2026-08-26，`wgime-py-pure/`，方案 A）

**动机**：3.8 版本锁来自 pythonnet（.NET 桥）轮子上限，而需 .NET 的唯一强需求是 CodeDom 编译 `[csharp]` 插件 + .NET Framework 免安装。放弃这两者后，任意新版 Python 都能用。

**架构**（Python 3.12 + ctypes + tkinter，零 .NET）：
- `hook.py` — ctypes `WH_KEYBOARD_LL`，回调只做吞键判定+入队（关键路径快）；自家注入按 `dwExtraInfo=0x5747494D` 放行；Shift 轻拍/Ctrl+`/Ctrl+Shift+F/Ctrl+Alt+C 合成事件
- `win.py` — ctypes `SendInput(UNICODE)` / `GUIThreadInfo` 光标跟随 / 剪贴板（powershell 兜底）
- `bar.py` — tkinter 无边框置顶候选条（Canvas 自绘圆角，跟随光标）
- `main.py` — 状态机复用 `wgime.py`（pythonnet 版）逻辑，UI/注入换纯 Python；engine/plugins 纯标准库直接复用
- 复用：`engine.py`、`plugins.py`（本就是纯标准库）

**实机验证**：notepad 中 `zhongguo` → 候选条 `1.中国 2.众过 3.忠果 4.重国 5.宗国`（tkinter 自绘，跟随光标）→ 空格上屏"中国"，并自动出联想行（↪联想 你好）。

**踩坑**：① ctypes 回调返回 `CallNextHookEx` 必须声明 argtypes（64 位指针参数默认 32 位会 OverflowError）；② ctypes `SendInput` 的 INPUT 需 pointer-sized `dwExtraInfo`；③ `import tkinter.font as tkfont`（`tk.font` 不自动加载）。

**待迁移**：插件系统改 Python 插件 API（chat/clock/calc 重写，协议层 Python 更顺）；工具箱/剪贴板/便签/取色器/网络工具改 tkinter；托盘（pystray）；粘贴/提权关键路径（纯 ctypes 已备）。

---

## 15. 纯 Python chat 插件已迁移并互通（2026-08-26）

- **插件 API**：`plugins\*.py` 定义 `CODE/NAME/DESC + run()`（无 .NET）；主程序 `load_py_plugins()` 扫描加载，启动器 code 命中即 `run()`
- **最小同步 WebSocket 客户端**（`wspy.py`，标准库 socket+ssl，RFC 6455）：HTTP 升级 / 掩码帧 / 分片聚合 / ping-pong 应答，文本帧（relay）与二进制帧（MQTT-over-WS）通用
- **chat.py**：`[csharp]` 版完整重写为纯 Python——AES-256-CBC + HMAC-SHA256(`cryptography`)，relay 文本帧 / MQTT-over-WS 二选一，join/online/leave/chat，auto-reconnect；tkinter 聊天窗，网络后台线程 + 队列回主线程
- **互操作验证**（与 Node 参考端同一 relay 房间）：Node 发 `hello-from-python-pure` → 插件**正确解密并显示**（`NodeRef  hello-from-python-pure`）；Node 端看到 PyChat 的 join/online。**INTEROP PASS**
- **踩坑**：tkinter 变量（Entry/StringVar）不能跨线程读——join() 在主线程固化配置，网络线程只用快照
- **依赖**：`cryptography`（AES，pypi），`websockets`（可选，纯版未用——自写 ws）；其余纯标准库

---

## 16. 纯 Python 版全部迁移 + 单文件化（2026-08-26）

- **其余插件**：`clock`（置顶时钟）、`calc`（安全表达式计算器）、`chat` 均为纯 Python + tkinter
- **内置工具**（`tools.py`，tkinter）：工具箱（`tools.txt` tab/按钮 → 步骤 DSL）、剪贴板历史、便签（自动保存）、取色器（跟随光标采样+复制 hex）、网络工具（ping/tracert/nslookup）
- **单文件化**（`build-wgime-pure.py` → `dist\wgime-py.py`，105KB）：所有模块+插件源 __repr__ 内嵌，按依赖序 exec 进 `sys.modules`（真实 `import win/hook/...` 仍可用），插件注册为 `plug_*`，最后把 main.py 源 exec 进 `__main__`。就一个文件，仿 wgime.bat 载荷形态
- **启动器码**：`lt`→聊天、`sk`→时钟、`js`→计算器、`itools`→工具箱、`jlb`→剪贴板、`bj`→便签、`ys`→取色器、`net`→网络工具
- **单文件验证**：notepad `nihao`→`你好` 上屏；`sk`→▶时钟→空格弹出时钟窗，均通过
- **关键坑**：① `pprint.pformat` 按字母序排 dict 键导致依赖序错——必须用 `repr` 保持插入序；② engine 读 trad/pywfreq 原用 `__file__`，单文件下模块目录无此文件——改为从 `dict_dir` 读（`self.dict_dir`）；③ 单文件模块要设 `__file__/__name__`
- **运行**：`python wgime-py-pure\dist\wgime-py.py`（单文件、免安装、零 .NET，需 Python 3.12 + tkinter + cryptography；码表/配置从 `C:\Tools\wgime` 读）
- **未激活即惰性**（用户反馈"启动即拦截"）：启动读 `config.txt` 的 `starton`（默认 0 = 关）；**未激活时钩子完全惰性**——Shift 轻拍/Ctrl+`/Ctrl+Shift+F/Ctrl+Alt+C 全部透传，仅 F8（硬开关）和托盘能唤醒；激活态才吞 IME 键 + 组合键。实测日志：启动 `active=False` 无拦截，F8 到 `kb 77` 才切换
- **Shift 轻拍唤醒（最终版）**：Shift 轻拍（<400ms 的**孤立**单次 Shift，中间没夹其它键——正常打大写"Shift+字母"不算轻拍）**激活与关闭都生效**，未激活时也能用它轻松唤起；但**组合键仅激活态生效**（未激活时 Ctrl+` 等透传，不干扰日常快捷键）。实测：`abc你好xyz`——notepad 未激活打 `abc` 透传 → Shift 轻拍唤醒 → `nihao` 上屏 `你好` → Shift 轻拍关闭 → `xyz` 透传，全部正确（`shift-test.ps1`）
- **激活态日常键透传（用户反馈）**：① **Shift+Enter/空格/退格等修正键透传**（Shift 按住时这些控制键交给应用，不再当 IME 提交/删除）；② **空拼音缓冲时空格/退格/回车透传**（`COMPOSING` 标志随 `reset/refresh` 立即同步，无 15ms 竞态）——否则激活时打不了空格/删不了字；③ **托盘图标随状态刷新**（`set_active` 时刷新，蓝=激活/灰=未激活）。实测：`你好` 上屏、Shift+Enter 不再产生 `kb 0d`、空缓冲空格/退格透传（`runtime-test.ps1`）
- **修饰键组合透传 + 候选框修正（用户反馈）**：① **带 Ctrl/Alt/Win 的快捷键透传**（`Win+Shift+S`、`Ctrl+S`、`Alt+Tab` 等不再被吞）；② 候选框 `canvas.pack(fill/expand)` 修复两侧灰底；③ 宽度按两行最大值正确计算；④ **分页指示** `◀1/7▶`，`=`/`-` 翻页。实测：`z` 出 7 页候选，`Ctrl+S` 不产生 `kb 53`（`modifier-test.ps1`）
- **英汉候选补进混合/拼音模式 + 联想退格（用户反馈）**：① 混合/拼音模式之前不查英汉字典（只词典模式查），`vest` 候选为空、候选框消失——补上 `add_from_dict(ec)`，`vest → 1.背心 2.汗背心 3.使穿衣服 4.授予`；② **联想态退格**：退出联想并把退格交给应用（删刚上屏的字）+ `clear_assoc` 隐藏候选条（之前只改状态不隐藏）。实测：`你好`→联想态→退格→`你` 且联想条消失（`vest-assoc-test.ps1`）
- **收尾补齐（对照 pythonnet 版）**：① 注入恢复完整路由（paste 粘贴/提权 UIPI 回退 + Qt 吞字 qtfix + per-app `pastemode.txt` 模式）；② 托盘加"当前程序: 剪贴板上屏切换 / 标点吞字修复切换"；③ **插件管理窗体**（`plugins`/`cjgl` 启动器，勾选启停 + `plugins-disabled.txt` + 重载）。托盘块移到主循环前（函数定义后），回调用 lambda 延迟求值。实测：`plugins` → ▶插件管理 弹窗列出 3 插件

> 剩余非阻塞项：emoji 候选目前文本渲染（C# 版用 Fluent PNG）；造词对话框（C# 有，可用 Ctrl+Alt+C 剪贴板造词替代）

---

## 17. 造词对话框 + 光标跟随修复 + 托盘崩溃修复（2026-08-27）

- **造词对话框**（`tools.show_makeword`，Ctrl+Alt+C 弹出）：剪贴板预填词语，编码留空自动推导（`engine.code_for`），可改码后确认造词；与自动造词/剪贴板造词并存
- **光标跟随修复**：`get_caret_pos` 探测本身准确，但**探测不到时**旧代码落到"屏幕底部居中"→ 很错位。改为：① 缓存上次有效光标位，探测失败时复用（不跳走）；② 否则用前台窗口客户区左上（贴近输入区）；③ 候选框钳制到屏幕内 + 下方不够时翻到光标上方；④ 加 DPI 感知（高分屏 tkinter/Win32 坐标一致）
- **托盘崩溃修复（关键）**：pystray 回调在其**自己的线程**跑，原来调 `root.after` 触发 `RuntimeError: main thread is not in main loop` 直接崩掉整个 app——改为 `TRAY_Q` 队列 + 主线程 `poll` 里执行 + 刷新图标；`poll` 的 `winfo_exists` 加防护（关闭阶段不报错）
- 实测：造词对话框弹出（词语/编码/造词/取消）；托盘不再崩溃；`get_caret_pos` 探测 `(301,126)` 即实际光标处
- **托盘退出修复（用户反馈"退出用不了"）**：pystray 的 `_run_detached` 线程**非 daemon**，`root.destroy()` 后进程挂住（窗口没了图标还在）——`quit_app` 先 `icon.stop()` 再 `root.destroy()` 最后 `os._exit(0)` 强制结束；补 `Ctrl+Alt+Q` 键盘退出（钩子加 `VK_QUIT`，注意 **VK_QUIT 必须在 hook.py 里定义**，否则 NameError）。实测 Ctrl+Alt+Q → 进程干净退出 (exit 0)
- **UIA 光标跟随（用户反馈"窗口最左方"）**：Edge/Explorer 这类 Chromium/多线程 UI `GetGUIThreadInfo` 探测不到光标，旧回退落到窗口左上/屏幕底部。改为：GetGUIThreadInfo → **UI Automation**（`uiautomation` 包，ITextPattern.GetSelection 精确光标，聚焦控件边界做小控件回退）→ 上次有效位缓存 → 前台窗口客户区。需 `pip install uiautomation`
- Alt+D 等组合键实测透传正常（日志无 `kb 44`）；之前是托盘崩溃+光标错位造成的误解
- **UIA Rect 索引坑**：`uiautomation` 的 `BoundingRectangle`/`GetBoundingRectangles` 返回 `Rect` 对象，**不能下标索引**（`r[0]` 报错），要用 `.left/.top/.right/.bottom` 属性。修后 UIA 能拿到聚焦控件位置（探针：Tk 文本框 UIA=(308,431)），GUIThreadInfo 优先精确值，UIA 回退，现代应用（Edge/Explorer）候选框跟随到地址栏/输入框
- **托盘图标与 C# 版一致**：圆角方形(squircle)+模式汉字镂空(中/拼/五/译)+Win11 强调色(蓝#0078D4/青#00B7C3/橙#CA5010/紫#881798)，未激活灰色#BEB9B3——Pillow 复刻，模式+激活态联动刷新

---

## 18. 补全 + C#/C++ 插件支持（2026-08-28）

- **小补全**：showcode 反查编码渲染（候选上显示编码）、hideidle=0 常驻候选、phrase= 自定义短语置顶、网络工具补齐 7 页签（Ping/Tracert/DNS/HTTP/端口/子网/本机）
- **插件方案对齐 C#**（`plugins\*.txt` + `tools.txt` + `config.txt`）：步骤 DSL 插件（clean-bin/qping 等）直接跑；`[python]` 块（替代 `[csharp]`）exec 运行；`[csharp]` 块经 **sidecar**（`run-csharp-plugin.ps1` PowerShell+CodeDom 编译运行，独立进程弹窗）——C# 插件也能跑
- **候选框圆角真透明**（transparentcolor，替代 SetWindowRgn 裁边残影）+ 修宽度溢出
- **C++/DLL**：纯版可用 ctypes `LoadLibrary`+导出函数调用 C++ DLL 插件（可行，未做插件实例）
- **遗留大补**：WgTray（托盘工具箱独立程序）、hotkey_* 全局热键、emoji PNG 图片版
