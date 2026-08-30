# WgIme TSF 语言选型

> 日期：2026-08-29　主题：若做 **TSF 输入法（TSF TIP）**，用什么语言最合适。结论先行：**TSF 用 Rust（首选）或 C++（次选）原生编译；不要用 Python 硬凑（覆盖层保留 Python/C# 即可）。** 配套评估见 `docs/WGIME_TSF评估.md`（纯 Python 版）。

## 1. 关键：形态决定语言

选语言前先分清两种形态，它们对语言的要求完全不同：

| 形态 | 说明 | 语言取向 |
|---|---|---|
| **覆盖层 IME**（现状） | 独立进程 + 全局键盘钩子 + SendInput 注入 | Python（`wgime-py-pure`）/ C#（主版）够用，性能热路径无压力，**不必换** |
| **TSF 输入法**（要新做的） | 进程内 COM 服务器 DLL，被加载进每一个文本应用进程，直接参与 composition | **必须原生编译语言（C++ / Rust）**，不要 Python |

TSF TIP 的本质：**一个 DLL（`InprocServer32`）驻留在每个应用进程内**。这决定了：
- 必须是**原生/可嵌入**的运行时（C++/Rust 编译原生 DLL；C# 带 CLR；Python 带解释器）。
- 按键回调跑在**目标应用主线程**，性能/GIL 必须可控。

## 2. 语言对比（针对 IME + TSF + 免安装）

| 语言 | 性能 | 免安装单文件 | 内存安全 | TSF 生态 | 主要劣势 |
|---|---|---|---|---|---|
| **Rust** | C++ 级 | ✅ 单二进制（静态/动态） | ✅ 最强 | 少（`windows-rs` 有 Win32/COM/TSF 绑定） | TSF 示例少、学习曲线陡 |
| **C++** | 最强 | ✅ 单 exe/DLL | ⚠️ 手动管理 | **最成熟**（微软官方 `SampleIME` 即 C++） | 内存 bug 风险高（TSF 崩溃会拖垮宿主应用）、开发慢 |
| **C# (.NET)** | 好 | ⚠️ 自包含但体积大、启动慢 | ✅ | 有（`TSF-TypeLib`） | CLR 驻留所有进程、进不了 UWP、单文件体积大 |
| **Python** | 一般 | ✅ 单文件 | ✅ | ✗ 基本不适合 | 解释器驻留所有进程、GIL + 低层钩子超时、UWP 盲区 |

## 3. 结论与建议

- **覆盖层**：维持现状（Python / C#），不换语言。
- **TSF 子项目**：**Rust 首选、C++ 次选**。
  - **Rust** —— 现代 Windows 原生开发的"正确选择"：内存安全极大降低"TIP 崩溃拖垮 Explorer/其他应用"这类**致命事故**（TSF 最怕这个）；性能 C++ 级；`cargo build` 出一个独立 DLL/exe，贴合"免安装单文件"。代价：TSF 示例少、上手成本。
  - **C++** —— 微软官方同路、生态最全、能直接抄 `SampleIME`；代价：内存安全要自己扛、开发/维护慢。
- **我个人的排序**：TSF 用 **Rust 首选**（崩溃面大的场景 + 免安装单文件），**C++ 次选**（成熟但风险/成本高）。

## 4. 混合思路（如果舍不得 Python 快速迭代）

外壳用 Rust/C++ 编译成**很薄的 TSF TIP DLL**（COM 骨架 + 崩溃隔离 + 稳定性），内核（词频/候选/组合）用 Rust/C++ 重写原生 —— 不要用"原生壳 + 内嵌 Python"（那又把解释器拉进每个进程，前功尽弃）。

## 5. Rust 最小 spike（立项前验证）

目标：用 `windows-rs` 实现**最简 `ITfKeyEventSink`**，注册 COM + TSF profile，在 notepad 里打字确认**回调真的在目标应用进程内触发**。验证点：
1. Rust 工具链（rustup + MSVC 或 GNU 工具链）能编译出 `InprocServer32` DLL；
2. `windows` crate 的 COM/TSF 接口绑定可用（`ITfTextInputProcessor(Ex)` / `ITfKeyEventSink` / `ITfThreadMgrEventSink` 等）；
3. 回调延迟是否守住系统低层钩子超时；
4. UWP 应用是否加载（预期同样受限）。

> 若 spike 通过 → TSF 子项目可立项（Rust）；若 COM 注册/回调链路不通 → 明确"只能靠 keyfix/UIA 兜底"，不再投入。

### Spike 进度（`wgime-tsf/`，迭代式）

- **里程碑① ✅（2026-08-30）**：`wgime-tsf` 用 `windows-rs 0.58`（`#[implement(IClassFactory)]` + `IClassFactory_Impl for TsfFactory_Impl`）编译出 `wgime_tsf.dll`（`crate-type=["cdylib"]`），`DllGetClassObject`/`DllRegisterServer`/`DllUnregisterServer` 导出齐全。**实测**：`CoGetClassObject(CLSID, CLSCTX_INPROC_SERVER, IID_IClassFactory)` 返回 **S_OK**，Windows 成功加载 DLL 并创建类工厂实例。`CreateInstance` 目前返回 `E_NOTIMPL`（待里程碑② 返回真正的文本服务对象）。
  - 注册表键：`HKCR\CLSID\{d2ffe102-f716-430f-aa8a-da54a54de90b}\InprocServer32`（默认值=DLL 路径，`ThreadingModel=Both`）。写入 `HKCR\CLSID` 需 **管理员**（非提权进程 `RegCreateKeyW` 报 access denied）；PoC 验证可先写 `HKCU\Software\Classes\CLSID\...`（同样被 HKCR 合并）。
  - 待办：里程碑②（`ITfTextInputProcessor(Ex)`/`ITfKeyEventSink` 绑定 + TSF profile 注册）→ 里程碑③（notepad 打字回调触发）。


