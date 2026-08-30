//! wgime-tsf — WgIme TSF 输入法 spike (Rust + windows-rs 0.58)
//! 里程碑: 见 docs/WGIME_TSF_语言选型.md §5
//!   ① Windows 能 CoGetClassObject 加载本 DLL(第一步, 本文件)
//!   ② ITextInputProcessor(Ex)/ITfKeyEventSink 绑定 + TSF profile 注册
//!   ③ notepad 打字 -> 回调触发 -> 组合串 -> 上屏/候选
//!
//! 注意: 这是迭代式 PoC. 若某处 windows-rs API 与 0.58 有出入, 把编译报错贴回即可微调.

use std::ffi::c_void;
use windows::core::*;
use windows::Win32::Foundation::BOOL;
use windows::Win32::System::Com::{IClassFactory, IClassFactory_Impl};
use windows::Win32::System::LibraryLoader::GetModuleFileNameW;
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyW, RegDeleteTreeW, RegSetValueExW, HKEY, HKEY_CLASSES_ROOT, REG_SZ,
};

/// wgime-tsf 的 COM CLSID (本 PoC 用固定 GUID; TSF 里程碑② 注册到 HKCR\CLSID + 类别 + profile).
/// GUID: {d2ffe102-f716-430f-aa8a-da54a54de90b}
const WGIME_TSF_CLSID: GUID = GUID::from_u128(0xd2ffe102_f716_430f_aa8a_da54_a54d_e90b);
/// GUID 的带花括号字符串(注册表键路径用).
const WGIME_TSF_CLSID_STR: &str = "{d2ffe102-f716-430f-aa8a-da54a54de90b}";

/// 把字符串转成 UTF-16 向量, 避免临时指针悬挂.
fn to_w(s: &str) -> Vec<u16> {
    s.encode_utf16().collect()
}

/// 最简无状态 COM 对象(占位, 本步只为验证 DLL 能被加载 + 类工厂能创建一个 IUnknown).
#[implement(IClassFactory)]
struct TsfFactory;

impl IClassFactory_Impl for TsfFactory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Option<&IUnknown>,
        _riid: *const GUID,
        _ppv: *mut *mut c_void,
    ) -> Result<()> {
        if punkouter.is_some() {
            return Err(Error::from(HRESULT(0x8000_4005u32 as i32))); // CLASS_E_NOAGGREGATION
        }
        // TODO(里程碑②): 这里返回真正的文本服务对象(ITfTextInputProcessor 等).
        // 本步里程碑①只需 Windows 能 CoGetClassObject 加载本 DLL 并拿到 IClassFactory;
        // CreateInstance 先返回 E_NOTIMPL, 待 TSF 接口实现后再返回实际对象.
        Err(Error::from(HRESULT(0x8000_4001u32 as i32))) // E_NOTIMPL
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
    // SAFETY: buf 是合法可写缓冲区, hmodule=0 表示当前模块.
    let len = unsafe { GetModuleFileNameW(None, &mut buf) };
    String::from_utf16_lossy(&buf[..len as usize])
}

/// 注册类工厂: HKCR\CLSID\{CLSID} 下建 InprocServer32 = 本 DLL 路径, ThreadingModel=Both.
#[no_mangle]
pub unsafe extern "system" fn DllRegisterServer() -> HRESULT {
    const FAIL: HRESULT = HRESULT(0x8000_4005u32 as i32); // CLASS_E_CLASSNOTAVAILABLE 占位错误码

    let clsid_path = to_w(&format!("CLSID\\{}", WGIME_TSF_CLSID_STR));
    let inproc_path = to_w(&format!("CLSID\\{}\\InprocServer32", WGIME_TSF_CLSID_STR));

    // 父键 CLSID\{GUID}: RegCreateKeyW 会自动创建不存在的中间键.
    let mut hkey = HKEY(std::ptr::null_mut());
    let status = RegCreateKeyW(HKEY_CLASSES_ROOT, PCWSTR(clsid_path.as_ptr()), &mut hkey);
    if status.0 != 0 {
        return FAIL;
    }
    let _ = RegCloseKey(hkey);

    // InprocServer32 子键.
    let mut hkey2 = HKEY(std::ptr::null_mut());
    let status = RegCreateKeyW(HKEY_CLASSES_ROOT, PCWSTR(inproc_path.as_ptr()), &mut hkey2);
    if status.0 != 0 {
        return FAIL;
    }

    // 默认值 = DLL 完整路径.
    let path = to_w(&dll_path());
    let path_bytes: Vec<u8> = path.iter().flat_map(|u| u.to_le_bytes()).collect();
    let status = RegSetValueExW(hkey2, PCWSTR::null(), 0, REG_SZ, Some(&path_bytes));
    if status.0 != 0 {
        let _ = RegCloseKey(hkey2);
        return FAIL;
    }

    // ThreadingModel = Both.
    let tm = to_w("Both");
    let tm_bytes: Vec<u8> = tm.iter().flat_map(|u| u.to_le_bytes()).collect();
    let tm_name = to_w("ThreadingModel");
    let status = RegSetValueExW(
        hkey2,
        PCWSTR(tm_name.as_ptr()),
        0,
        REG_SZ,
        Some(&tm_bytes),
    );
    let _ = RegCloseKey(hkey2);

    if status.0 != 0 {
        FAIL
    } else {
        HRESULT(0) // S_OK
    }
}

/// 卸载注册: 删除 HKCR\CLSID\{CLSID}.
#[no_mangle]
pub unsafe extern "system" fn DllUnregisterServer() -> HRESULT {
    let clsid_path = to_w(&format!("CLSID\\{}", WGIME_TSF_CLSID_STR));
    let status = RegDeleteTreeW(HKEY_CLASSES_ROOT, PCWSTR(clsid_path.as_ptr()));
    // status 0 = ERROR_SUCCESS, 2 = ERROR_FILE_NOT_FOUND(未注册, 可接受).
    if status.0 == 0 || status.0 == 2 {
        HRESULT(0)
    } else {
        HRESULT(0x8000_4005u32 as i32)
    }
}
