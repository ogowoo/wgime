//! wgime-tsf — WgIme TSF 输入法最小 spike (Rust + windows-rs)
//!
//! 目标: 实现最简 `ITfTextInputProcessor` + `ITfKeyEventSink`, 注册为 TSF TIP,
//!      在 notepad 打字验证回调真的在目标应用进程内触发.
//!
//! 里程碑 (PoC, 见 docs/WGIME_TSF_语言选型.md §5):
//!   1. cargo build 出 InprocServer32 DLL(需 rustup + MSVC 或 MinGW-GNU 工具链)
//!   2. windows crate 的 ITfTextInputProcessor(Ex)/ITfKeyEventSink vtable 绑定
//!   3. 注册 HKCR\CLSID + GUID_TFCAT_TIP_KEYBOARD + 语言 profile
//!   4. notepad 打字 -> 回调触发 -> 组合串 -> 上屏汉字 -> 简单候选窗
//!
//! 说明: 本文件为骨架/占位; 完整实现需在具备 Rust + 链接器的机器上编译调试。
//!       (当前仓库仅提供项目骨架与依赖声明, 不在此处提交编译产物。)

fn main() {
    println!("wgime-tsf spike skeleton");
    println!("next: implement ITfTextInputProcessor + ITfKeyEventSink + COM registration");
}
