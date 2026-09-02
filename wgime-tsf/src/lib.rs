//! wgime-tsf — WgIme TSF 输入法 spike (Rust + windows-rs 0.58)
//! 里程碑: 见 docs/WGIME_TSF_语言选型.md §5
//!   ① Windows 能 CoGetClassObject 加载本 DLL            (已通过)
//!   ② ITextInputProcessor(Ex)/ITfKeyEventSink 绑定 + TSF profile 注册  (本文件)
//!   ③ notepad 打字 -> 回调触发 -> 组合串 -> 上屏/候选
//!
//! 注意: 这是迭代式 PoC. 若某处 windows-rs API 与 0.58 有出入, 把编译报错贴回即可微调.
//!
//! TSF 键盘输入法 (TIP) 的激活流程(参考微软 SampleIME):
//!   - TSF 通过 InprocServer32 加载本 DLL, 调 DllGetClassObject 拿 IClassFactory;
//!   - CoCreateInstance(CLSID, IID_ITfTextInputProcessor) 创建我们的文本服务对象;
//!   - TSF 调 ITfTextInputProcessor::Activate(ptim, tid) 激活(每个应用进程一次);
//!   - Activate 里用 ITfThreadMgr QI 到 ITfKeystrokeMgr, AdviseKeyEventSink 注册按键回调;
//!   - 之后目标应用窗口的按键先经过 ITfKeyEventSink (OnTestKeyDown/OnKeyDown 等)。

use std::ffi::c_void;
use std::sync::Mutex;
use windows::core::*;
use windows::Win32::Foundation::{BOOL, LPARAM, WPARAM};
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyW, RegDeleteTreeW, RegSetValueExW, HKEY, HKEY_CLASSES_ROOT,
    HKEY_LOCAL_MACHINE, REG_SZ,
};
use windows::Win32::UI::TextServices::{
    ITfContext, ITfKeyEventSink, ITfKeyEventSink_Impl, ITfKeystrokeMgr, ITfTextInputProcessor,
    ITfTextInputProcessor_Impl, ITfTextInputProcessorEx, ITfTextInputProcessorEx_Impl, ITfThreadMgr,
};

/// wgime-tsf 的 COM CLSID (TSF 注册到 HKCR\CLSID + 类别 + profile).
/// GUID: {d2ffe102-f716-430f-aa8a-da54a54de90b}
const WGIME_TSF_CLSID: GUID = GUID::from_u128(0xd2ffe102_f716_430f_aa8a_da54_a54d_e90b);
const WGIME_TSF_CLSID_STR: &str = "{d2ffe102-f716-430f-aa8a-da54a54de90b}";

/// GUID_TFCAT_TIP_KEYBOARD 的字符串形式(Implemented Categories 子键用).
/// GUID: {34745c63-b2f0-4784-8b67-5e12c8701a31}
const GUID_TFCAT_TIP_KEYBOARD_STR: &str = "{34745c63-b2f0-4784-8b67-5e12c8701a31}";

/// 本 TSF 语言 profile 的 GUID (language profile 注册用, 里程碑②之后外部脚本使用).
/// GUID: {a1e3d9c4-2f5b-7d4e-9c30-2a3b4c5d6e7f}
#[allow(dead_code)]
const WGIME_TSF_PROFILE_GUID: GUID = GUID::from_u128(0xa1e3d9c4_2f5b_7d4e_9c30_2a3b4c5d6e7f);
#[allow(dead_code)]
const WGIME_TSF_PROFILE_STR: &str = "{a1e3d9c4-2f5b-7d4e-9c30-2a3b4c5d6e7f}";

fn to_w(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// 写一行调试日志到 %LOCALAPPDATA%\wgime-tsf-hook.log.
/// 里程碑③验证用: 看 Activate 是否被调、按键是否进入回调.
/// (DLL 在目标应用进程内运行, 用环境变量 + 一个简单文件即可观测, 不动注册表.)
fn log(msg: &str) {
    use std::io::Write;
    let path = std::env::var("LOCALAPPDATA")
        .map(|p| format!("{}\\wgime-tsf-hook.log", p))
        .unwrap_or_else(|_| "wgime-tsf-hook.log".to_string());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "[{}] {}: {}", std::process::id(), "wgime-tsf", msg);
    }
}

// ---------------------------------------------------------------------------
// 文本服务对象 (TsfTextService): 实现 ITfTextInputProcessor(Ex) + ITfKeyEventSink.
// ---------------------------------------------------------------------------

/// TSF 文本服务对象. 由 IClassFactory::CreateInstance 创建, 是实际接收按键的对象.
#[implement(ITfTextInputProcessor, ITfTextInputProcessorEx, ITfKeyEventSink)]
struct TsfTextService {
    /// 缓存的按键回调句柄(用于 Deactivate 时反注册).
    keystroke: Mutex<Option<ITfKeystrokeMgr>>,
    /// TSF 分配给我们这个客户端的 id.
    tid: Mutex<u32>,
}

impl TsfTextService {
    fn new() -> Self {
        Self {
            keystroke: Mutex::new(None),
            tid: Mutex::new(0),
        }
    }
}

impl ITfTextInputProcessor_Impl for TsfTextService_Impl {
    fn Activate(&self, ptim: Option<&ITfThreadMgr>, tid: u32) -> Result<()> {
        log(&format!("Activate tid={:#x}", tid));
        *self.tid.lock().unwrap() = tid;
        if let Some(ptim) = ptim {
            // 从线程管理器拿到键盘管理器, 注册我们的按键回调(前台回调).
            let keystroke: ITfKeystrokeMgr = ptim.cast()?;
            let sink = self.to_interface::<ITfKeyEventSink>();
            unsafe { keystroke.AdviseKeyEventSink(tid, &sink, BOOL(1))? };
            *self.keystroke.lock().unwrap() = Some(keystroke);
            log("Activate: AdviseKeyEventSink OK");
        } else {
            log("Activate: ptim is None (no thread mgr)");
        }
        Ok(())
    }

    fn Deactivate(&self) -> Result<()> {
        log("Deactivate");
        let tid = *self.tid.lock().unwrap();
        if let Some(keystroke) = self.keystroke.lock().unwrap().take() {
            unsafe { keystroke.UnadviseKeyEventSink(tid) }?;
            log("Deactivate: UnadviseKeyEventSink OK");
        }
        Ok(())
    }
}

impl ITfTextInputProcessorEx_Impl for TsfTextService_Impl {
    // Ex 版激活: ActivateEx 与 Activate 逻辑一致(本 PoC 不做 UWP/immersive 特殊分支).
    fn ActivateEx(&self, ptim: Option<&ITfThreadMgr>, tid: u32, _dwflags: u32) -> Result<()> {
        ITfTextInputProcessor_Impl::Activate(self, ptim, tid)
    }
}

impl ITfKeyEventSink_Impl for TsfTextService_Impl {
    fn OnSetFocus(&self, fforeground: BOOL) -> Result<()> {
        log(&format!("OnSetFocus foreground={}", fforeground.0));
        Ok(())
    }

    fn OnTestKeyDown(
        &self,
        _pic: Option<&ITfContext>,
        wparam: WPARAM,
        _lparam: LPARAM,
    ) -> Result<BOOL> {
        // TODO(里程碑③): 这里真正处理拼音/五笔按键; 现暂不吞键(返回 FALSE 放行).
        log(&format!("OnTestKeyDown vk={:#x} wparam={:#x}", wparam.0 as u32, wparam.0));
        Ok(BOOL(0)) // S_FALSE: 不吞键, 交给下一个 sink / 应用
    }

    fn OnTestKeyUp(&self, _pic: Option<&ITfContext>, wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        log(&format!("OnTestKeyUp vk={:#x}", wparam.0 as u32));
        Ok(BOOL(0))
    }

    fn OnKeyDown(&self, _pic: Option<&ITfContext>, wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        log(&format!("OnKeyDown vk={:#x}", wparam.0 as u32));
        Ok(BOOL(0))
    }

    fn OnKeyUp(&self, _pic: Option<&ITfContext>, wparam: WPARAM, _lparam: LPARAM) -> Result<BOOL> {
        log(&format!("OnKeyUp vk={:#x}", wparam.0 as u32));
        Ok(BOOL(0))
    }

    fn OnPreservedKey(&self, _pic: Option<&ITfContext>, _rguid: *const GUID) -> Result<BOOL> {
        log("OnPreservedKey");
        Ok(BOOL(0))
    }
}

// ---------------------------------------------------------------------------
// 类工厂: 创建 TsfTextService.
// ---------------------------------------------------------------------------

#[implement(IClassFactory)]
struct TsfFactory;

impl IClassFactory_Impl for TsfFactory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Option<&IUnknown>,
        riid: *const GUID,
        ppv: *mut *mut c_void,
    ) -> Result<()> {
        if punkouter.is_some() {
            return Err(Error::from(HRESULT(0x8000_4005u32 as i32))); // CLASS_E_NOAGGREGATION
        }
        let service: IUnknown = TsfTextService::new().into();
        unsafe { service.query(riid, ppv) }.ok()?;
        Ok(())
    }

    fn LockServer(&self, _flock: BOOL) -> Result<()> {
        Ok(())
    }
}

#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    if rclsid.is_null() || *rclsid != WGIME_TSF_CLSID {
        return HRESULT(0x8004_0110u32 as i32); // CLASS_E_CLASSNOTAVAILABLE
    }
    let factory: IClassFactory = TsfFactory.into();
    factory.query(riid, ppv)
}

/// 返回本 DLL 的完整路径(用于写入 InprocServer32).
fn dll_path() -> String {
    let mut buf = [0u16; 1024];
    let len = unsafe { GetModuleFileNameW(None, &mut buf) };
    String::from_utf16_lossy(&buf[..len as usize])
}

// ---------------------------------------------------------------------------
// 注册 / 卸载. TSF 键盘输入法要同时写:
//   HKCR\CLSID\{GUID}\InprocServer32 = DLL 路径 + ThreadingModel=Both      (COM)
//   HKLM\Software\Microsoft\CTF\TIP\{GUID}                                   (类别 + profile)
//   并在 Keyboard 类别下注册 profile.
// ---------------------------------------------------------------------------

#[no_mangle]
pub unsafe extern "system" fn DllRegisterServer() -> HRESULT {
    const FAIL: HRESULT = HRESULT(0x8000_4005u32 as i32); // CLASS_E_CLASSNOTAVAILABLE 占位错误码

    let clsid_path = to_w(&format!("CLSID\\{}", WGIME_TSF_CLSID_STR));
    let inproc_path = to_w(&format!("CLSID\\{}\\InprocServer32", WGIME_TSF_CLSID_STR));

    // --- COM 注册: CLSID\{GUID} ---
    let mut hkey = HKEY(std::ptr::null_mut());
    if RegCreateKeyW(HKEY_CLASSES_ROOT, PCWSTR(clsid_path.as_ptr()), &mut hkey).0 != 0 {
        return FAIL;
    }
    let _ = RegCloseKey(hkey);

    // --- InprocServer32 = DLL 路径 + ThreadingModel=Both ---
    let mut hkey2 = HKEY(std::ptr::null_mut());
    if RegCreateKeyW(HKEY_CLASSES_ROOT, PCWSTR(inproc_path.as_ptr()), &mut hkey2).0 != 0 {
        return FAIL;
    }
    let path = to_w(&dll_path());
    let path_bytes: Vec<u8> = path.iter().flat_map(|u| u.to_le_bytes()).collect();
    if RegSetValueExW(hkey2, PCWSTR::null(), 0, REG_SZ, Some(&path_bytes)).0 != 0 {
        let _ = RegCloseKey(hkey2);
        return FAIL;
    }
    let tm = to_w("Both");
    let tm_bytes: Vec<u8> = tm.iter().flat_map(|u| u.to_le_bytes()).collect();
    let tm_name = to_w("ThreadingModel");
    let status = RegSetValueExW(hkey2, PCWSTR(tm_name.as_ptr()), 0, REG_SZ, Some(&tm_bytes));
    let _ = RegCloseKey(hkey2);
    if status.0 != 0 {
        return FAIL;
    }

    // --- Implemented Categories: TSF 线程管理器靠这个发现"键盘输入法"类别 ---
    // HKCR\CLSID\{GUID}\Implemented Categories\{34745c63-b2f0-4784-8b67-5e12c8701a31}
    //    (GUID_TFCAT_TIP_KEYBOARD)
    let cat_path = to_w(&format!(
        "CLSID\\{}\\Implemented Categories\\{GUID_TFCAT_TIP_KEYBOARD_STR}",
        WGIME_TSF_CLSID_STR
    ));
    let mut hkey_cat = HKEY(std::ptr::null_mut());
    let cat_status = RegCreateKeyW(HKEY_CLASSES_ROOT, PCWSTR(cat_path.as_ptr()), &mut hkey_cat);
    if cat_status.0 != 0 {
        return FAIL;
    }
    let _ = RegCloseKey(hkey_cat);

    // --- TSF TIP 注册 (需管理员写 HKLM). ---
    let tip_path = to_w(&format!("Software\\Microsoft\\CTF\\TIP\\{}", WGIME_TSF_CLSID_STR));
    let mut hkey3 = HKEY(std::ptr::null_mut());
    let tip_status = RegCreateKeyW(HKEY_LOCAL_MACHINE, PCWSTR(tip_path.as_ptr()), &mut hkey3);
    if tip_status.0 == 0 {
        let _ = RegCloseKey(hkey3);
    }

    HRESULT(0) // S_OK
}

/// 卸载注册: 删除 COM CLSID 键 + TSF TIP 键(best-effort, 需管理员).
#[no_mangle]
pub unsafe extern "system" fn DllUnregisterServer() -> HRESULT {
    let clsid_path = to_w(&format!("CLSID\\{}", WGIME_TSF_CLSID_STR));
    let s1 = RegDeleteTreeW(HKEY_CLASSES_ROOT, PCWSTR(clsid_path.as_ptr()));
    let tip_path = to_w(&format!("Software\\Microsoft\\CTF\\TIP\\{}", WGIME_TSF_CLSID_STR));
    let s2 = RegDeleteTreeW(HKEY_LOCAL_MACHINE, PCWSTR(tip_path.as_ptr()));
    // 0 = SUCCESS, 2 = NOT_FOUND(可接受).
    if (s1.0 == 0 || s1.0 == 2) && (s2.0 == 0 || s2.0 == 2) {
        HRESULT(0)
    } else {
        HRESULT(0x8000_4005u32 as i32)
    }
}
