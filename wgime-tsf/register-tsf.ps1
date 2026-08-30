# register-tsf.ps1 - register/unregister wgime-tsf as a TSF keyboard input method (TIP)
#
# Reference: https://github.com/keymanapp/keyman/wiki/Making-sense-of-the-Windows-Layout-Registration
#            and the real disk layout written by ITfInputProcessorProfileMgr::RegisterProfile.
#
# A TSF keyboard IME needs THREE layers (missing any one -> "registered but never activates"):
#   A) COM registration (needs admin):      HKCR\CLSID\{CLSID}\InprocServer32 = DLL + ThreadingModel=Both
#                                           HKCR\CLSID\{CLSID}\Implemented Categories\{GUID_TFCAT_TIP_KEYBOARD}
#   B) Profile registration (needs admin):  HKLM\Software\Microsoft\CTF\TIP\{CLSID}\LanguageProfile\0x{langid}\{ProfileGUID}
#                                           with Description / Enable / HiddenInSettingUI
#   C) Per-user enable (no admin, HKCU):    put this profile into the current user's input method / language bar
#
# PATH NOTE: Windows PowerShell registry cmdlets (New-Item/Set-Item/Test-Path) want provider paths with a
#            colon (HKLM:\.., HKCU:\..), while reg.exe wants NO colon (HKLM\.., HKCU\..). This script keeps
#            separate variables for each and never mixes them.
#
# Usage:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File register-tsf.ps1          # full register (admin)
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File register-tsf.ps1 -UserOnly # per-user enable only (no admin)
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File register-tsf.ps1 -Unreg    # unregister
#
# NOTE: milestone 3 (typing in notepad) only fires in a real desktop session AFTER all three layers are
#       registered. Whether it shows in Settings -> Keyboard depends on layer C.

param(
    [switch]$Unreg,
    [switch]$UserOnly,
    [string]$DllPath = "",
    [int]$LangID = 0x0804,   # default Simplified Chinese (GB); English = 0x0409
    [switch]$SkipUserInstall
)

$ErrorActionPreference = "Continue"   # reg delete on a missing key writes stderr; must not abort install

$CLSID   = "{d2ffe102-f716-430f-aa8a-da54a54de90b}"
$Profile = "{a1e3d9c4-2f5b-7d4e-9c30-2a3b4c5d6e7f}"
$Name    = "wgime-tsf"
$CatKB   = "{34745c63-b2f0-4784-8b67-5e12c8701a31}"   # GUID_TFCAT_TIP_KEYBOARD

if (-not $DllPath) {
    $DllPath = Join-Path $PSScriptRoot "target\debug\wgime_tsf.dll"
    if (-not (Test-Path $DllPath)) {
        $DllPath = Join-Path $PSScriptRoot "target\release\wgime_tsf.dll"
    }
}
if (-not (Test-Path $DllPath)) { throw "DLL not found: $DllPath" }

$langHex = ("{0:X}" -f $LangID)

# ---- reg.exe paths (NO colon) ----
$regClsid      = ("HKCR\CLSID\" + $CLSID)
$regInproc     = ($regClsid + "\InprocServer32")
$regCats       = ($regClsid + "\Implemented Categories\" + $CatKB)
$regTip        = ("HKLM\SOFTWARE\Microsoft\CTF\TIP\" + $CLSID)
$regProf       = ($regTip + "\LanguageProfile\0x" + $langHex + "\" + $Profile)
$regUserTip    = ("HKCU\Software\Microsoft\CTF\TIP\" + $CLSID + "\LanguageProfile\0x" + $langHex + "\" + $Profile)
$regUserSort   = ("HKCU\Software\Microsoft\CTF\SortOrder\AssemblyItem\" + $Profile)

# ---- provider paths (WITH colon, for New-Item/Set-Item/Test-Path) ----
$psTip       = ("HKLM:\SOFTWARE\Microsoft\CTF\TIP\" + $CLSID)
$psProf      = ($psTip + "\LanguageProfile\0x" + $langHex + "\" + $Profile)
$psUserTip   = ("HKCU:\Software\Microsoft\CTF\TIP\" + $CLSID + "\LanguageProfile\0x" + $langHex + "\" + $Profile)
$psUserSort  = ("HKCU:\Software\Microsoft\CTF\SortOrder\AssemblyItem\" + $Profile)

if ($Unreg) {
    reg delete $regClsid /f 2>$null | Out-Null
    reg delete $regTip /f 2>$null | Out-Null
    reg delete $regUserTip /f 2>$null | Out-Null
    Write-Host "Unregister done (best-effort, missing keys are OK)."
    return
}

# =====================================================================
# A) COM registration + Implemented Categories
# =====================================================================
if (-not $UserOnly) {
    Write-Host "[A] COM registration + Implemented Categories ..."
    reg delete $regClsid /f 2>$null | Out-Null
    reg add $regClsid              /d $Name     /f | Out-Null
    reg add $regInproc             /t REG_SZ /d $DllPath /f | Out-Null
    reg add $regInproc /v ThreadingModel /t REG_SZ /d Both /f | Out-Null
    reg add $regCats               /f | Out-Null
    Write-Host "  CLSID : $CLSID"
    Write-Host "  DLL   : $DllPath"
}

# =====================================================================
# B) Profile registration (HKLM, needs admin)
# =====================================================================
if (-not $UserOnly) {
    Write-Host "[B] Write TSF Profile ..."
    New-Item -Path $psTip  -Force | Out-Null
    Set-Item  -Path $psTip  -Value $Name
    New-Item -Path $psProf -Force | Out-Null
    Set-Item  -Path $psProf -Value $Name
    reg add $regProf /v Description /t REG_SZ /d $Name /f | Out-Null
    reg add $regProf /v Enable /t REG_DWORD /d 1 /f | Out-Null
    reg add $regProf /v HiddenInSettingUI /t REG_DWORD /d 0 /f | Out-Null
    Write-Host "  Profile: $regProf"
}

# =====================================================================
# C) Per-user enable (HKCU, no admin)
# =====================================================================
if (-not $SkipUserInstall) {
    Write-Host "[C] Per-user enable (HKCU) ..."

    # C1) per-user CTF TIP profile record
    New-Item -Path $psUserTip -Force | Out-Null
    Set-Item  -Path $psUserTip -Value $Name
    reg add $regUserTip /v Enable /t REG_DWORD /d 1 /f | Out-Null

    # C2) language-bar assembly order (legacy, still read by some versions).
    #     Try not to clobber the user's existing input methods.
    if (-not (Test-Path $psUserSort)) {
        New-Item -Path $psUserSort -Force | Out-Null
        Set-Item  -Path $psUserSort -Value $Name
        reg add $regUserSort /v Profile /t REG_SZ /d $Profile /f | Out-Null
        reg add $regUserSort /v KeyboardLayout /t REG_SZ /d "00000409" /f | Out-Null
    }

    # C3) recommended: let Windows add this TIP to the current user's language list.
    #     Only call when this TIP is absent, because Set-WinUserLanguageList rewrites the
    #     whole language+input list.
    $needsInstall = $false
    try {
        $L = Get-WinUserLanguageList -ErrorAction Stop
        $found = $false
        foreach ($entry in $L) {
            foreach ($im in $entry.InputMethodTips) {
                if ($im -match [regex]::Escape($Profile)) { $found = $true; break }
            }
        }
        $needsInstall = (-not $found)
    } catch {
        $needsInstall = $false
    }
    if ($needsInstall) {
        Write-Host "  -> calling Set-WinUserLanguageList to install to current user language list (may rewrite it)..."
        try {
            $L = Get-WinUserLanguageList
            if ($L.Count -eq 0) {
                $L = @()
                $L += New-WinUserLanguageList -Language "zh-CN"
            }
            foreach ($entry in $L) {
                $has = $false
                foreach ($im in $entry.InputMethodTips) {
                    if ($im -match [regex]::Escape($Profile)) { $has = $true; break }
                }
                if (-not $has) {
                    $entry.InputMethodTips = @($entry.InputMethodTips) + $Profile
                }
            }
            Set-WinUserLanguageList -LanguageList $L -Force
        } catch {
            Write-Host "  Set-WinUserLanguageList failed (no permission / empty language list). Add it manually in Settings -> Keyboard." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  (already in current user language list, skipping)"
    }
}

Write-Host ""
Write-Host "Register done. If 'Settings -> Time & Language -> Keyboard' shows wgime-tsf, select it and type in notepad to verify milestone 3."
Write-Host ("If not visible: log out/in (or reboot), and confirm (1) this script ran as admin (2) HKLM LanguageProfile key exists (3) language is 0x" + $langHex + ".")