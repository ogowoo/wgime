# register-tsf.ps1 — 注册/卸载 wgime-tsf 为 TSF 键盘输入法 (TIP)
# 用法(需管理员, 因为 TSF profile 在 HKLM):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File register-tsf.ps1            # 注册
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File register-tsf.ps1 -Unreg    # 卸载
#
# 需要真实 TSF 键盘输入法, 要写三处:
#   1) HKCR\CLSID\{CLSID}\InprocServer32 = DLL 路径 + ThreadingModel=Both   (COM 注册)
#   2) HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID} 下记录类别 + profile
#   3) 语言 profile: 通常放在 HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}\{LANGID}
# 注: 不同 Windows 版本的表结构略有差异, 这里采用经典的 IME 注册方式; 若新版(10/11)
#     在"设置->键盘"切换输入法时看不到, 需再补 HKCU 的已启用 input method 项.

param(
    [switch]$Unreg,
    [string]$DllPath = "",
    [int]$LangID = 0x0804   # 默认简体中文(国标); 英文=0x0409
)

$ErrorActionPreference = "Stop"

$CLSID    = "{d2ffe102-f716-430f-aa8a-da54a54de90b}"
$Profile  = "{a1e3d9c4-2f5b-7d4e-9c30-2a3b4c5d6e7f}"
$Name     = "wgime-tsf"
$CategoryKey = "{34745c63-b2f0-4784-8b67-5e12c8701a31}"  # GUID_TFCAT_TIP_KEYBOARD

if (-not $DllPath) {
    # 默认用 debug 版
    $DllPath = Join-Path $PSScriptRoot "target\debug\wgime_tsf.dll"
}
if (-not (Test-Path $DllPath)) { throw "DLL 不存在: $DllPath" }

function Reg-SetDefault($Key, $Value) {
    New-Item -Path "Registry::$Key" -Force | Out-Null
    Set-Item -Path "Registry::$Key" -Value $Value
}

if ($Unreg) {
    reg delete "HKCR\CLSID\$CLSID" /f 2>$null | Out-Null
    reg delete "HKLM\SOFTWARE\Microsoft\CTF\TIP\$CLSID" /f 2>$null | Out-Null
    Write-Host "卸载完成(best-effort, 缺失键可忽略)"
    return
}

# --- 1. COM 注册 (HKCU 亦可; 这里写 HKCR 需管理员) ---
reg add "HKCR\CLSID\$CLSID" /f | Out-Null
reg add "HKCR\CLSID\$CLSID\InprocServer32" /t REG_SZ /d "$DllPath" /f | Out-Null
reg add "HKCR\CLSID\$CLSID\InprocServer32" /v ThreadingModel /t REG_SZ /d Both /f | Out-Null

# --- 2. TSF TIP 注册 ---
# HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}  (类别 + profile 描述)
$tipRoot = "HKLM:\SOFTWARE\Microsoft\CTF\TIP\$CLSID"
New-Item -Path $tipRoot -Force | Out-Null
Set-Item -Path $tipRoot -Value $Name

# 类别 GUID_TFCAT_TIP_KEYBOARD 的子键, 记录 profile 名
$catPath = Join-Path $tipRoot $CategoryKey
New-Item -Path $catPath -Force | Out-Null
Set-Item -Path $catPath -Value $Name

# --- 3. 语言 profile ---
# 经典 IME 注册: HKLM\SOFTWARE\Microsoft\CTF\TIP\{CLSID}\{LANGID}
$langHex = "{0:X}" -f $LangID
$langPath = Join-Path $tipRoot $langHex
New-Item -Path $langPath -Force | Out-Null
Set-Item -Path $langPath -Value $Name
# 子键 {LANGID}\{ProfileGUID}, 记录 profile 名
$profPath = Join-Path $langPath $Profile
New-Item -Path $profPath -Force | Out-Null
Set-Item -Path $profPath -Value $Name

Write-Host "注册完成:"
Write-Host "  CLSID  : $CLSID"
Write-Host "  DLL    : $DllPath"
Write-Host "  Profile: $Profile"
Write-Host "  LangID : 0x$langHex"
Write-Host ""
Write-Host "提示: 注册后需在'设置->时间和语言->语言/键盘'里把 wgime-tsf 添加为输入法;"
Write-Host "      新版 Windows 可能还需在 HKCU\Software\Microsoft\CTF\SortOrder 或"
Write-Host "      HKCU\Control Panel\International\User Profile 注册启用的 IME."
