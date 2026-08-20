# ============================================================
#  build-wgime-ps1.ps1 - generate WgIme.ps1 (single-file payload edition)
#
#  WgIme.ps1 = full IME as ONE file:
#    * PS head (no cmd layer, no self-extract) with -Install/-RemoveTask
#      scheduled-task autostart (same pattern as WgTray.ps1)
#    * embedded base64 WgIme.dll payload trailer (###WGIME_DLL###);
#      at runtime extracted to %LOCALAPPDATA%\wgime\WgIme.<md5>.dll
#      and Add-Type -Path'd, then [WgImeLauncher]::Run(dir, ps1)
#    * launch command line stays clean: ... -File WgIme.ps1
#      (no Add-Type/.dll/::Run plaintext -> EDR command-line rules
#      cannot match; no launcher shortcut is generated - autostart
#      and manual start both go through the ps1)
#    * UTF-8 BOM (PS 5.1 needs it)
#
#  This script first runs build-wgime-dll.ps1 to (re)compile the DLL
#  (embedded dicts + trailer + icon + emoji resources), then assembles
#  WgIme.ps1 from it. Requires Windows PowerShell 5.1 + wgime.bat.
#
#  NOTE: ASCII-only script (Windows PS 5.1 reads .ps1 as ANSI).
# ============================================================
param([switch]$NoPayload)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# ---- 1) build the DLL edition first (dicts/icon/emoji/trailer).
#         Build it into a temp dir so the wg-all distribution folder
#         keeps only the ps1 editions (no WgIme.bat / WgIme.dll). ----
$tmpOut = Join-Path $env:TEMP ("wgime-ps1-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $tmpOut -ItemType Directory -Force | Out-Null
& (Join-Path $root 'build-wgime-dll.ps1') -OutDir $tmpOut
$dllPath = Join-Path $tmpOut 'WgIme.dll'
if (-not (Test-Path $dllPath)) { throw "WgIme.dll not produced: $dllPath" }

# ---- 2) payload loader (runtime: read self -> extract DLL -> Add-Type) ----
$loader = @'
# ================= WgIme bootstrap: extract embedded prebuilt DLL =================
$wgLog = Join-Path $env:TEMP 'WgIme_error.log'
function WgLog([string]$m) { try {
    if (Test-Path $wgLog) { $len = (Get-Item $wgLog).Length; if ($len -gt 1MB) { Move-Item $wgLog ($wgLog + '.old') -Force -ErrorAction SilentlyContinue } }
    [IO.File]::AppendAllText($wgLog, ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m), [Text.Encoding]::UTF8)
} catch {} }
WgLog "---- WgIme starting ----"
try {
    $all = [IO.File]::ReadAllText($env:WGIME_PATH, [Text.Encoding]::UTF8)
    $tag = '###WGIME_DLL' + '###'
    $ts = $all.LastIndexOf($tag)
    if ($ts -lt 0) { throw 'payload trailer not found' }
    $b64 = (($all.Substring($ts + $tag.Length).Trim()) -replace '\s') -replace "'"
    $md5 = [Security.Cryptography.MD5]::Create()
    $h = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($b64)))).Replace('-','').Substring(0,8)
    $dllDir = Join-Path $env:LOCALAPPDATA 'wgime'
    New-Item $dllDir -ItemType Directory -Force | Out-Null
    $cand = Join-Path $dllDir ("WgIme." + $h + ".dll")
    if (-not (Test-Path $cand)) {
        [IO.File]::WriteAllBytes($cand, [Convert]::FromBase64String($b64))
        Get-ChildItem (Join-Path $dllDir 'WgIme.*.dll') -EA SilentlyContinue | Where-Object Name -ne (Split-Path $cand -Leaf) | Remove-Item -Force -Confirm:$false -EA SilentlyContinue
    }
    Add-Type -Path $cand -ErrorAction Stop
    WgLog ("prebuilt DLL loaded: " + $cand)
    [WgImeLauncher]::Run($env:WGIME_DIR, $env:WGIME_PATH)
    WgLog "WgIme exited"
} catch {
    WgLog ("FATAL: " + ($_ | Out-String))
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(($_ | Out-String), 'WgIme Error') | Out-Null
    throw
}
'@

# ---- 3) ps1 head (autostart task, same pattern as WgTray.ps1) ----
$head = @'
# ============================================================
#  WgIme - full IME (pinyin/wubi/mixed/EN-CN dicts), single-file
#  ps1 payload edition: PS head -> embedded base64 prebuilt DLL
#  (###WGIME_DLL### trailer), extracted at runtime and loaded.
#  Errors are logged to %TEMP%\WgIme_error.log
#  Usage:
#    powershell -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File WgIme.ps1
#    powershell ... -File WgIme.ps1 -Install       # + register logon autostart task
#    powershell ... -File WgIme.ps1 -RemoveTask    # - delete the autostart task
# ============================================================
param([switch]$Install, [switch]$RemoveTask)
$env:WGIME_PATH = $PSCommandPath
$env:WGIME_DIR = $PSScriptRoot + '\'
if ($Install) {
    $inner = 'powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $tr = '"' + $inner.Replace('"', '\"') + '"'
    & schtasks.exe /Create /F /TN WgIme /SC ONLOGON /TR $tr 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'WgIme autostart task registered (logon)' }
    else { Write-Host 'WgIme autostart task registration failed (try as admin)' }
}
if ($RemoveTask) {
    & schtasks.exe /Delete /F /TN WgIme 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'WgIme autostart task removed' }
    else { Write-Host 'WgIme autostart task not found' }
    exit 0
}
# Hide this script's console window if one is visible (e.g. right-click
# "Run with PowerShell" / bare -File launch). GetConsoleWindow() returns
# the console attached to THIS process (MainWindowHandle is useless here:
# on Win10+ the console belongs to conhost, so it is always 0). When the
# console is already hidden (scheduled task / install.bat) ShowWindow
# returns False and nothing changes.
try {
    Add-Type -Name WgHide -Namespace Wg -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' -ErrorAction Stop
    $hw = [Wg.WgHide]::GetConsoleWindow()
    if ($hw -ne [IntPtr]::Zero) { [Wg.WgHide]::ShowWindow($hw, 0) | Out-Null }
} catch {}
'@

# ---- 4) assemble WgIme.ps1 (UTF-8 BOM) ----
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dllPath))
$lines = @()
$lines += ($head -split "`n")
$lines += ($loader -split "`n")
if (-not $NoPayload) {
    $lines += '###WGIME_DLL###'
    $lines += "'" + $b64 + "'"
}
$lines += ''
$outText = [string]::Join("`n", $lines)
$out = Join-Path $root 'WgIme.ps1'
[IO.File]::WriteAllText($out, $outText, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("WgIme.ps1 written: {0} bytes" -f (Get-Item $out).Length)
# also refresh the wg-all copy (distribution folder)
$wgAllOut = Join-Path $root 'wg-all\WgIme.ps1'
[IO.File]::WriteAllText($wgAllOut, $outText, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("wg-all\WgIme.ps1 written: {0} bytes" -f (Get-Item $wgAllOut).Length)

# ---- 5) self-check ----
$bytes = [IO.File]::ReadAllBytes($out)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if (-not $bom) { throw 'FAIL: WgIme.ps1 has no UTF-8 BOM' }
$txtOut = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
if ($NoPayload) {
    if ($txtOut.Contains('###WGIME_DLL###')) { throw 'FAIL: -NoPayload build still contains the payload marker' }
} else {
    if (-not $txtOut.Contains('###WGIME_DLL###')) { throw 'FAIL: payload build missing the payload marker' }
}
if (-not $txtOut.Contains('[WgImeLauncher]::Run')) { throw 'FAIL: missing launcher entry' }
Write-Output "checks OK (UTF-8 BOM, markers present)"
# the wg-all distribution folder ships only the ps1 editions - the
# DLL/bat intermediates live in the temp build dir, now removed
Remove-Item $tmpOut -Recurse -Force -EA SilentlyContinue
Write-Output "DONE - WgIme.ps1 ready (run with -Install for logon autostart)"
