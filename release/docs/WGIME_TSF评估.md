# WgIme → TSF 输入法 技术评估

> 日期：2026-08（基于当前 wgime.bat 架构评估）　结论：**可行但建议冻结为独立子项目**；现阶段用"注入架构 + keyfix + UIA 光标跟随"覆盖体验差距。

## 1. 背景

WgIme 当前是**覆盖层输入法**：全局低级键盘钩子（`WH_KEYBOARD_LL`）截获按键 → 维护内部编码缓冲与候选 → 用 `SendInput`（KEYEVENTF_UNICODE）把结果**模拟键盘注入**目标程序。全部逻辑在单个 `.bat`（内嵌 C# / 预编译 DLL）里，免安装、免注册、不产生 exe。

TSF（Text Services Framework）是 Windows 自 XP 起的官方输入法框架（Vista+ 成熟，Win8/10/11 的 modern 输入法均基于此）。TSF 输入法（TIP，Text Input Processor）是一个**进程内 COM 服务器 DLL**：被ctfmon/系统加载进**每一个接受文本输入的应用进程**，直接参与文本组合（composition）与编辑会话（edit session）。

## 2. 两条路的本质差异

| 维度 | 覆盖层（现状） | TSF |
|---|---|---|
| 代码位置 | 独立进程，外部观察键盘 | **DLL 驻留在每个应用进程内** |
| 文本上屏 | 模拟键盘事件（应用以为用户敲的） | 真实 composition → commit（应用认为是输入法） |
| 安装 | 双击即用 | 注册表注册（HKCR\CLSID + TIP profile），**需管理员** |
| 候选窗 | 自绘置顶窗，固定/拖动位置 | 可随光标（caret tracking 是 TSF 原生能力） |
| 失效场景 | UIPI（管理员窗口）、个别程序对注入敏感（微信4.x 已用 keyfix 修复） | UWP 进程拒绝加载托管 COM 对象（见 §4） |
| 故障面 | 只影响自己进程 | bug 出现在**别人的进程**里，可能拖垮目标应用 |

## 3. TSF TIP 的硬性要求清单

1. **COM 注册**：`HKCR\CLSID\{guid}\InprocServer32` 指向 DLL（32/64 位需分别提供对应架构的 DLL；ARM64 另算）。
2. **类别注册**：`ITfCategoryMgr::RegisterCategory` 挂 `GUID_TFCAT_TIP_KEYBOARD`。
3. **profile 注册**：`ITfInputProcessorProfiles::Register` + `AddLanguageProfile`（指定 LANGID、描述、图标），之后才会出现在系统设置的输入法列表里。
4. **接口实现**（最小集）：`ITfTextInputProcessor(Ex)`（Activate/Deactivate）、`ITfThreadMgrEventSink`（焦点跟踪）、`ITfKeyEventSink`（按键捕获/消费）、`ITfCompositionSink` + `ITfEditSession`（组合串显示与提交）、候选列表（自绘窗或 `ITfCandidateList`）、显示属性。
5. **权限**：注册写 HKCR/HKLM 需要管理员；卸载同理。

## 4. 托管（C#）实现可行性

- **有先例**：[TSF-TypeLib](https://github.com/nayaku/TSF-TypeLib)（C# 封装库，持续更新）；微软官方完整样例 [SampleIME](https://github.com/ChineseInputMethod/SampleIME) 是 C++。手写 COM interop 也可行，但几十个接口的 GUID/vtable 顺序必须逐一精确。
- **UWP 限制（硬伤）**：[CLR 不能在 UWP 进程里创建 .NET COM 对象](https://stackoverflow.com/questions/50660726)——托管 TIP 进不了 UWP 应用（设置、部分系统界面）。要全场景覆盖就得回到 C++ 原生。
- **CLR 驻留所有进程**：.NET Framework 4.x CLR 会被拉进每个文本输入进程——启动开销、内存、以及与目标应用加载的其他运行时（.NET 6+ 可并存，但仍有兼容面）。
- **调试**：Attach 到目标进程调别人的消息循环里的 COM 回调，体验远差于现在的单进程模型。

## 5. 能买到什么 / 付出什么

**买到**：组合输入原生体验（预编辑串、下划线）；注入类兼容问题（如微信 4.x 的 VK_PACKET 陈旧字符 bug）从根上消失；管理员窗口自然可用（TIP 已在目标进程内，不受 UIPI 限制）；系统语言栏/设置的标准集成。
**付出**：放弃"免安装免注册"这一核心卖点；新增常驻所有进程的代码面；开发与调试成本量级上升；UWP 盲区（除非转 C++）。

## 6. 若要做：分发与集成方案（设计草图）

复用 WgIme 现有机制，TSF 作为**可选安装组件**而非替代：

1. TSF TIP 独立编译为 `WgImeTsf.dll`（项目子目录，C# + TSF-TypeLib 或手写 interop）。
2. 以 base64 载荷形式内嵌进 `wgime.bat` 尾部（与现有 `###WGIME_DLL###` 机制相同，第二个标记位）。
3. 托盘新增"安装 TSF 模式（需管理员）"：解码写出 DLL 到 `%LOCALAPPDATA%\wgime\tsf\` → 提权注册（COM + category + profile）→ 引导用户在系统设置里启用；"卸载 TSF 模式"反向清理。
4. 词典复用 `%LOCALAPPDATA%\wgime\wgime.mb` 二进制缓存（TSF DLL 直接读，零重复构建）。
5. 覆盖层与 TSF 可共存：用户按语言栏切换，覆盖层检测到 TSF 激活时自动休眠（或反之）。

## 7. 工作量评估

| 阶段 | 内容 | 量级估计 |
|---|---|---|
| PoC | 注册→激活→捕获按键→组合串→上屏汉字→简单候选窗 | 数百行 interop + 数天跨进程调试 |
| 可用 | 词频/简拼/翻页/标点映射迁移，主流桌面应用实测 | 一至两周 |
| 生产级 | Chrome/Edge/旧 Win32/安全桌面/多 DPI/32 位，崩溃隔离 | 数周+ |

## 8. 风险清单

- 注册/卸载残留导致系统输入法列表脏条目；
- TIP 崩溃波及宿主应用（Explorer 也会加载）；
- 杀毒/EDR 对"注入所有进程的输入法 DLL"敏感（[TSF 已被红队用作持久化手段](https://www.praetorian.com/blog/leveraging-microsoft-text-services-framework-tsf-for-red-team-operations)，安全软件有理由盯）；
- Windows 大版本更新带来的 TSF 行为变化需要持续跟进。

## 9. 结论与替代路径

**建议冻结**：TSF 是"更正确但重得多"的路，与 WgIme 单文件免安装的定位相斥。当前架构下已落地/可落地的体验替代：

- **keyfix**（已落地）：微信 4.x 等 Qt 应用的注入吞字修复，全局默认开；
- **UIA 光标跟随**（已落地）：候选窗通过 `GetGUIThreadInfo` + UI Automation TextPattern 跟随光标（`followcaret = 1`），获得 TSF 最显眼的体验优势而不换架构；
- **按进程覆盖**（已有）：clipboard / keyfix / keyplain 逐项兜底个别顽固程序。

若未来真的启动 TSF 子项目，本文档 §6 的分发设计可直接复用，词典与候选管线（`ShowCharatar` 系列）也可平移。
