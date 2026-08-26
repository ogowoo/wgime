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
