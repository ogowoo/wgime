# WgIme（纯 Python 版）→ TSF 输入法 技术评估

> 日期：2026-08-29　对象：`wgime-py-pure`（Python 3.13 + ctypes + tkinter，零 .NET）　结论：**可行但比 C# 版更重，建议独立子项目，先做 PoC spike**。原 bat/C# 版评估见本文件底部历史（被本版本取代，仅作对比）。

## 0. 结论先行

TSF（Text Services Framework）是 Windows 系统级输入法框架，TIP（Text Input Processor）是一个**进程内 COM 服务器 DLL**，被 ctfmon/系统加载进**每一个接受文本输入的应用进程**，直接参与 composition/commit。它能根治覆盖层架构的两个痛点：**UIPI 管理员窗口不可用**、**注入类兼容问题（微信 4.x 等）**。

但用**纯 Python** 做 TIP，比 C#（.NET CLR 驻留所有进程）**更重、更 tricky**——Python 解释器要被打进每个应用进程，且 TIP 按键回调发生在目标应用的主线程，**Python 的 GIL 与性能是硬挑战**。**强烈建议独立成 `wgime-tsf/` 子项目（PoC 先行）**，不要混进现有单文件覆盖层。

## 1. 现状：纯 Python 版覆盖层

`wgime-py-pure` 是**覆盖层输入法**：全局低级键盘钩子（`hook.py` 的 `SetWindowsHookExW(WH_KEYBOARD_LL)`）截获按键 → 维护编码缓冲/候选（`engine.py`）→ `win.py` 用 `SendInput`(KEYEVENTF_UNICODE) 把结果**模拟键盘注入**目标程序。候选窗是 `bar.py` 的无边框置顶 tkinter 窗。

- **UIPI 限制**（与 C# 版一致）：管理员（高完整性）窗口前台时，普通权限的 wgime 钩子收不到输入、注入被拒 → 连 Shift 切换都不行（本会话已加托盘提示：建议以管理员运行 wgime）。
- **注入兼容**：部分程序对注入敏感（已用 keyfix/剪贴板/clipboard 兜底）。
- **光标跟随**：已用 `GetGUIThreadInfo` + UI Automation TextPattern 三级回退，接近 TSF 的 caret tracking。

## 2. 为什么还要 TSF

1. **UIPI 根治**：TIP 已在目标进程内，天然不受 UIPI 限制，管理员窗口自然可用（无需"以管理员运行 IME"）。
2. **真实 composition/commit**：应用认为是正规输入法，注入类兼容 bug 从根上消失。
3. **系统集成**：系统语言栏/设置标准条目、caret tracking 原生、预编辑串（下划线）。

## 3. Python 实现 TSF TIP 的技术路径（核心）

TIP 必需是**进程内 COM 服务器（InprocServer32 指向一个 DLL）**。纯 Python 的三种走法：

### 路径 A：pywin32 COM 服务器（相对最可行）
- 用 `win32com.server`（pywin32 的 pythoncom）把 `ITfTextInputProcessor` 等接口注册为**进程内 COM 服务器**：`InprocServer32` 指向 `pythoncomXX.dll` + 已注册的 Python 类（`win32com.server.register`）。
- **后果**：每个文本应用进程会被加载 `pythoncomXX.dll` **和 Python 运行时（python313.dll）**——和 C# CLR 驻留所有进程同理，但 Python 解释器通常更重、更易和目标应用已有运行时冲突。
- **依赖**：pywin32（win32com/pythoncom）+ Python 3.13 运行时。分发要么"用户装 Python"，要么**内嵌（embeddable）Python** 一并部署。
- 性能/GIL：TSF 按键回调跑在目标应用主线程的 COM 消息泵里；Python 回调持 GIL，若处理慢会**卡住宿主应用**（更甚于现在自进程内）。热路径（按键→组合串）需极简回调 + 必要处 `ctypes` 释放 GIL。

### 路径 B：cffi 编译薄 TIP DLL + 内嵌 Python（可控性最好）
- 用 cffi 写一个**薄 C 层**（实现 TSF 的 vtable/COM 接口 + 类工厂），DLL 作 `InprocServer32`，内部把回调转发给**内嵌的 Python 解释器**（`Py_Initialize` + 加载 `wgime-tsf.py` 的 engine 逻辑）。
- **后果**：C 薄壳负责 COM/TSF 骨架与稳定（崩溃隔离、GIL 释放时机），Python 只做组合/候选/词频。这是"C 壳 + Python 核"的折中，开发和维护成本最高，但**性能与崩溃面最可控**。

### 路径 C：comtypes 手写 vtable（理论可行，工程最重）
- comtypes 是纯 Python COM（可定义/调用接口），但要作为**进程内服务器**被外界加载，仍需一个 DLL 宿主（comtypes 自身不是 InprocServer DLL）。基本上要回到"用 cffi/cython 造宿主 DLL"，可行性等于 B，且 vtable 全手写。

### 路径对比

| | A: pywin32 | B: cffi 薄壳+内嵌Python | C: comtypes vtable |
|---|---|---|---|
| 实现成本 | 中 | 高 | 高 |
| 每进程加载 | pythoncom + Python 运行时 | Python 运行时（C 壳很薄） | Python 运行时 |
| 性能/GIL | 回调持 GIL，风险大 | C 壳可控 GIL 释放 | 同 A |
| 崩溃隔离 | 差 | 较好 | 差 |
| 对目标应用侵入 | python 解释器驻留 | python 解释器驻留 | python 解释器驻留 |

**说明**：无论哪条路，Python TIP 都会让 **Python 运行时驻留每一个文本应用进程**——这是和 C# 版 TSF 相同的方向，但 Python 解释器通常比 .NET CLR 更挑剔（运行时兼容、启动开销、GIL）。这是本版评估比 C# 版**更保守**的根本原因。

## 4. TSF TIP 硬性要求（与 C# 版相同）

1. **COM 注册**：`HKCR\CLSID\{guid}\InprocServer32` 指向 TIP DLL（pythoncom/comtypes 宿主 DLL 或 cffi 编译 DLL）；32/64 位需对应架构 DLL。
2. **类别注册**：`ITfCategoryMgr::RegisterCategory` 挂 `GUID_TFCAT_TIP_KEYBOARD`。
3. **profile 注册**：`ITfInputProcessorProfiles::Register` + `AddLanguageProfile`（LANGID、描述、图标），之后才进系统输入法列表。
4. **接口最小集**：`ITfTextInputProcessor(Ex)`（Activate/Deactivate）、`ITfThreadMgrEventSink`（焦点）、`ITfKeyEventSink`（按键）、`ITfCompositionSink`+`ITfEditSession`（组合/提交）、候选列表（自绘窗或 `ITfCandidateList`）、显示属性。
5. **权限**：注册写 HKCR/HKLM 需**管理员**；卸载同理。

## 5. 可行性 spike（必须先验证，Py 特有）

在动手前，先写一个最小 spike（复用 `tests/python-spike/` 思路）验证：
1. **Python 能否被作为进程内 COM 服务器加载进别的应用**：pywin32 `win32com.server.register` 一个最简接口（如 `ITfKeyEventSink` 占位），注册后用一个普通 Win32 应用（notepad/写字板）接受输入，确认**回调真的在该应用进程内触发**。这是最大不确定性——若 Python COM 服务器的 InprocServer 加载/注册链路不通，后续全部作废。
2. **Python 3.13 作为内嵌运行时打进应用进程**：确认 `python313.dll` 在任意文本应用里能被 `Py_Initialize`（或 pywin32 自动加载），无路径/依赖问题。
3. **按键回调延迟**：在目标应用主线程里跑 Python 回调，测 `SetWindowsHookEx`/TSF 回调到组合串的延迟；确认 GIL 释放/低延迟是否守住系统低层钩子超时（LowLevelHooksTimeout，系统会对耗时钩子摘除）。
4. 确认**UWP 应用**：托管/解释型 COM 对象在 UWP 进程（Win10/11 设置、部分系统界面）**是否加载**。C# 侧已知 CLR 进不去 UWP（`CLR cannot be used in UWP`），Python 大概率同样进不去——**这是全场景覆盖的明显盲区**，除非转纯 C++。

> spike 通过与否，直接决定 TSF 子项目是"可以立项"还是"仅能覆盖非 UWP 的桌面应用"。

## 6. 独立子项目方案（若立项）

- **目录**：`wgime-tsf/`（与 wgime-py-pure 平级），Python 为主 —— `tsf.py`(COM/TSF 接口)、`engine.py`/`cands.py`(复用/移植 wgime-py-pure 的 engine 候选/词频逻辑)、`build_tsf.py`(打包嵌入 Python 或 pywin32 server)。
- **复用**：词频（`freq_m`/`lastpick_m`/`freq_recent`）与候选管线（`ShowCharatar` 逻辑）可直接从 `wgime-py-pure/engine.py` 平移；词库缓存 `dict-cache.pkl` 可共用。
- **与覆盖层共存**：用户按语言栏切换；覆盖层检测 TSF 激活时自动休眠（或反之），避免双输入。
- **分发**：可选安装——托盘「**安装 TSF 模式（需管理员）**／**卸载 TSF 模式**」；把 pywin32/嵌入式 Python 打成目录 + 注册脚本，而不是塞进单文件。

## 7. 风险清单

- Python 运行时驻留所有进程（比 CLR 更重、兼容面更大）；
- GIL/低层钩子超时：回调慢被系统摘钩，或卡宿主应用；
- **UWP 盲区**：解释型 COM 大概率进不去 UWP（与 C# 版同病，除非转 C++）；
- 注册/卸载残留、杀软/EDR 对"输入法 DLL 注入所有进程"敏感（TSF 被红队用做持久化）；
- Win 大版本更新带来的 TSF 行为变化需持续跟进。

## 8. 替代路径（不改架构，现在可做）

- **keyfix / 剪贴板 / per-app 兜底**（已落地）：逐项覆盖注入兼容问题；
- **UIA 光标跟随**（已落地）：有 TSF care tracking 的体验而不换架构；
- **UIPI**：目前只能"以管理员运行 wgime"（本会话加了托盘提示）。

---

## 附：原 bat/C# 版评估要点（2026-08，已被本版本取代，仅对比）

原评估（wgime.bat 时期）结论：可行但建议冻结为独立子项目；用 C# + TSF-TypeLib 或手写 interop；CLR 进不了 UWP；放弃"免安装免注册"。本版评估差异：**改用 Python 技术栈（pywin32/comtypes/cffi），难点从"CLR 驻留所有进程"升级为"Python 解释器驻留所有进程 + GIL/低层钩子超时"**，整体更保守，PoC 验证（§5 的前 3 点）是立项前必做。
