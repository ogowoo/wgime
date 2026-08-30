//! wgime-tsf — WgIme TSF 输入法 spike (Rust + windows-rs 0.58)
//! 里程碑: 见 docs/WGIME_TSF_语言选型.md §5
//!   ① Windows 能 CoGetClassObject 加载本 DLL(第一步, 本文件) 
//!   ② ITextInputProcessor(Ex)/ITfKeyEventSink 绑定 + TSF profile 注册
//!   ③ notepad 打字 -> 回调触发 -> 组合串 -> 上屏/候选
//!
//! 注意: 这是迭代式 PoC. 若某处 windows-rs API 与 0.58 有出入, 把编译报错贴回即可微调.

use windows::core::*;
use windows::Win32::System::Com::*;

/// 最简无状态 COM 对象(占位, 本步只为验证 DLL 能被加载 + 类工厂能创建一个 IUnknown).
#[implement(IClassFactory)]
struct TsfFactory;

impl IClassFactory_Impl for TsfFactory {
    fn CreateInstance(
        &self,
        punkouter: Option<&IUnknown>,
        riid: *const GUID,
        ppv: *mut *mut c_void,
    ) -> Result<()> {
        if punkouter.is_some() {
            return Err(Error::from(HRESULT(0x8000_4005))); // CLASS_E_NOAGGREGATION
        }
        // 这里最终要返回文本服务对象(ITfTextInputProcessor 等);
        // 本步先返回一个 #implement(IUnknown) 的占位对象验证加载链路.
        let obj: IUnknown = TsfSinkObject.into();
        obj.query_interface(riid, ppv)
    }

    fn LockServer(&self, _flock: BOOL) -> Result<()> {
        // TSF 服务器通常不 pin 模块; 可留空或返回 Ok.
        Ok(())
    }
}

/// 占位: 后续替换为真正的 text service (ITextInputProcessor 等).
#[implement(IUnknown)]
struct TsfSinkObject;

#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    _rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    let factory: IClassFactory = TsfFactory.into();
    factory.query_interface(riid, ppv).into()
}

/// 供脚本来注册/卸载 TSF 的 helper 导出 (本步占位; 后续写 HKCR\CLSID + 类别 + profile).
#[no_mangle]
pub unsafe extern "system" fn DllRegisterServer() -> HRESULT {
    HRESULT(0) // S_OK 占位; 后续写注册逻辑
}

#[no_mangle]
pub unsafe extern "system" fn DllUnregisterServer() -> HRESULT {
    HRESULT(0)
}
