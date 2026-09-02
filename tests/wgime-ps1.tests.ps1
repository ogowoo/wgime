# ============================================================
#  wgime-ps1.tests.ps1 - regression tests for the WgIme ps1
#  payload edition (single-file WgIme.ps1: PS head + embedded base64
#  prebuilt DLL trailer ###WGIME_DLL###; no scheduled-task autostart;
#  NO launcher shortcut - manual start via the ps1)
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1
#
#  NOTE: ASCII-only file - Windows PS 5.1 reads scripts as ANSI.
# ============================================================
$ErrorActionPreference = 'Stop'
$rootDir = $PSScriptRoot | Split-Path -Parent
$ps1Path = Join-Path $rootDir 'WgIme.ps1'
$script:passed = 0; $script:failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# ================= 1. single-file payload structure =================
if (-not (Test-Path $ps1Path)) { throw "WgIme.ps1 not found - run build-wgime-ps1.ps1 first" }
$bytes = [IO.File]::ReadAllBytes($ps1Path)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
T 'ps1 has UTF-8 BOM' $bom
$txt = [IO.File]::ReadAllText($ps1Path, [Text.Encoding]::UTF8)
T 'ps1 is self-contained: payload trailer present' ($txt.Contains('###WGIME_DLL###'))
T 'ps1 launches WgImeLauncher' ($txt.Contains('[WgImeLauncher]::Run'))
T 'ps1 no cmd self-extract marker (###PWSHTRAY###)' (-not $txt.Contains('###PWSHTRAY###'))
T 'ps1 has NO scheduled-task autostart (no -Install / no schtasks / no tray item)' ((-not $txt.Contains('/SC ONLOGON')) -and (-not $txt.Contains('-RemoveTask')) -and (-not $txt.Contains('SetAutoStartTask')))
T 'ps1 has NO shortcut code (no IShellLink / no CreateShortcut)' ((-not $txt.Contains('IShellLink')) -and (-not $txt.Contains('CreateShortcut')))

# ================= 2. parse check =================
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errors) | Out-Null
T 'ps1 parses without syntax errors' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')

# ================= 3. (removed) scheduled-task autostart - no longer shipped =================
# ps1 editions no longer register any scheduled task / autostart; the
# "no -Install / no schtasks" assertion above covers the head, and the
# "no tray autostart item" reflection checks below cover the C# payload.

# ================= 4. runtime smoke: launch, payload DLL extracted, IME worker up =================
$errLog = Join-Path $env:TEMP 'WgIme_error.log'
$mbCache = Join-Path $env:LOCALAPPDATA 'wgime\wgime.mb'
$dllDir = Join-Path $env:LOCALAPPDATA 'wgime'   # 先定义 dllDir 再使用(原脚本顺序 bug 导致 Join-Path null)
Remove-Item $errLog, $mbCache -Force -EA SilentlyContinue   # force a genuine dict rebuild from the trailer
Remove-Item (Join-Path $dllDir 'WgIme.*.dll') -Force -EA SilentlyContinue   # clear stale DLLs (bat thin DLL + ps1 full DLL share this dir; -First 1 would grab the wrong one)
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-NoLogo','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ps1Path | Out-Null
Start-Sleep -Seconds 40
$me = $PID
$w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*WgIme.ps1*' }
T 'runtime: IME worker is running' ($null -ne $w)
$extracted = Get-ChildItem (Join-Path $dllDir 'WgIme.*.dll') -EA SilentlyContinue | Select-Object -First 1
T 'runtime: payload DLL extracted from ps1 trailer' ($null -ne $extracted -and $extracted.Length -gt 1000000) ("dll=$($extracted.Name) len=$($extracted.Length)")
$fatal = $null
if (Test-Path $errLog) { $fatal = Get-Content $errLog -Raw | Select-String -Pattern 'FATAL' }
T 'runtime: no FATAL in error log' ($null -eq $fatal)
$mb = Get-Item $mbCache -EA SilentlyContinue
T 'runtime: dict cache present (trailer tables parsed)' ($null -ne $mb -and $mb.Length -gt 30000000) ("cache=$($mb.Length)")
if ($w) { $w | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }

# ================= 5. no launcher shortcut is created next to the ps1 =================
$lnkAny = Get-ChildItem $rootDir -Filter 'WgIme.lnk' -EA SilentlyContinue
T 'no launcher shortcut created (start via ps1 / scheduled task)' ($null -eq $lnkAny)

# ================= 6. tools.txt button codes -> app launcher (WgIme only) =================
# A button whose line is followed by "code = xyz" must register Apps[xyz] =
# ["工具:name", "tool:xyz", ""] so typing xyz shows "▶工具:name" and picking
# it runs the action (RunToolCode).
$tcDir = Join-Path $env:TEMP 'wgime-toolcode-test'
New-Item $tcDir -ItemType Directory -Force | Out-Null
$tcTools = @'
[tab Test]
[Btn One]
code = btn1
msg Btn One ran
[Btn Two]
code = btn2
msg Btn Two ran
'@
[IO.File]::WriteAllText((Join-Path $tcDir 'tools.txt'), $tcTools, (New-Object System.Text.UTF8Encoding($false)))
# extract the shipped payload DLL from the ps1 trailer and load it
$wt = [IO.File]::ReadAllText($ps1Path, [Text.Encoding]::UTF8)
$tag = '###WGIME_DLL###'
$ts = $wt.LastIndexOf($tag)
$b64 = (($wt.Substring($ts + $tag.Length).Trim()) -replace '\s') -replace "'"
$bytes = [Convert]::FromBase64String($b64)
$tcDll = Join-Path $env:TEMP 'wgime_tc_test.dll'
[IO.File]::WriteAllBytes($tcDll, $bytes)
try {
    Add-Type -Path $tcDll -ErrorAction Stop
    $tcWb = [WordBoard]
    $tcAll = [Reflection.BindingFlags]'Static,NonPublic,Public,Instance,DeclaredOnly'
    $tcLt = $tcWb.GetMethod('LoadTools', $tcAll)
    if ($tcLt) {
        $tcLt.Invoke($null, [object[]]@([string]$tcDir)) | Out-Null
        $tcAf = $tcWb.GetField('Apps', $tcAll)
        $tcApps = $tcAf.GetValue($null)
        $tcGongju = [string][char]0x5DE5 + [string][char]0x5177 + ':'   # "工具:"
        $tc1 = $tcApps.ContainsKey('btn1') -and $tcApps['btn1'][1] -eq 'tool:btn1' -and $tcApps['btn1'][0].StartsWith($tcGongju)
        $tc2 = $tcApps.ContainsKey('btn2') -and $tcApps['btn2'][1] -eq 'tool:btn2'
        $tcRun = $null -ne $tcWb.GetMethod('RunToolCode', $tcAll)
        T 'tools-code: button code registers into app launcher' ($tc1 -and $tc2) ("btn1=$tc1 btn2=$tc2 apps=$($tcApps.Count)")
        T 'tools-code: RunToolCode runner exists' $tcRun
    } else {
        T 'tools-code: button code registers into app launcher' $false 'LoadTools missing'
        T 'tools-code: RunToolCode runner exists' $false
    }
} catch {
    T 'tools-code: button code registers into app launcher' $false $_.Exception.Message
    T 'tools-code: RunToolCode runner exists' $false $_.Exception.Message
}
Remove-Item $tcDll, $tcDir -Recurse -Force -EA SilentlyContinue

# ================= 7. no autostart in the tray menu / C# payload =================
# The autostart feature was removed: no miAuto field, no SetAutoStartTask /
# IsAutoStartTask methods, no schtasks references anywhere in the payload.
$auDll = Join-Path $env:TEMP 'wgime_autostart_test.dll'
[IO.File]::WriteAllBytes($auDll, $bytes)   # $bytes: payload DLL bytes from section 6
$auHasAuto = $false
try {
    Add-Type -Path $auDll -ErrorAction Stop
    $auWb = [WordBoard]
    $auFlags = [Reflection.BindingFlags]'Instance,Static,NonPublic,Public,DeclaredOnly'
    $auF = $auWb.GetField('miAuto', $auFlags)
    $auSet = $auWb.GetMethod('SetAutoStartTask', $auFlags)
    $auIs = $auWb.GetMethod('IsAutoStartTask', $auFlags)
    $auHasAuto = ($null -ne $auF) -or ($null -ne $auSet) -or ($null -ne $auIs)
    T 'tray: no autostart menu field / methods in payload' (-not $auHasAuto) ("miAuto=$($null -ne $auF) Set=$($null -ne $auSet) Is=$($null -ne $auIs)")
} catch {
    T 'tray: no autostart menu field / methods in payload' $false $_.Exception.Message
}
Remove-Item $auDll -Force -EA SilentlyContinue

# ================= summary =================
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
