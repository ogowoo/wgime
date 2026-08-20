# ============================================================
#  wgime-ps1.tests.ps1 - regression tests for the WgIme ps1
#  payload edition (single-file WgIme.ps1: PS head + embedded base64
#  prebuilt DLL trailer ###WGIME_DLL###; autostart via scheduled task;
#  NO launcher shortcut - start via the ps1 or the scheduled task)
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
T 'ps1 head registers the scheduled task via schtasks' ($txt.Contains('/TN WgIme /SC ONLOGON'))
T 'ps1 has -RemoveTask support' ($txt.Contains('-RemoveTask'))
T 'ps1 has NO shortcut code (no IShellLink / no CreateShortcut)' ((-not $txt.Contains('IShellLink')) -and (-not $txt.Contains('CreateShortcut')))

# ================= 2. parse check =================
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errors) | Out-Null
T 'ps1 parses without syntax errors' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')

# ================= 3. scheduled-task autostart (-Install / -RemoveTask) =================
& cmd /c "schtasks.exe /Delete /F /TN WgIme 2>nul" | Out-Null
$ins = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ps1Path,'-Install' -PassThru
Start-Sleep -Seconds 10
$q = & schtasks.exe /Query /TN WgIme /FO LIST /V 2>&1 | Out-String
T 'install: task registered' ($q -match 'WgIme')
$tr = ($q -split "`r?`n") | Where-Object { $_ -match '^Task To Run' } | Select-Object -First 1
T 'install: task runs powershell -File ps1 (no Add-Type in cmd)' ($tr -match 'powershell\.exe.*-File.*WgIme\.ps1' -and $tr -notmatch 'Add-Type')
T 'install: task triggers at logon' ($q -match 'At logon time')
# -Install also launches the IME (install-and-run); stop the worker
$wIns = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*WgIme.ps1*' -and $_.CommandLine -like '*-Install*' }
if ($wIns) { $wIns | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }
$ps2 = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ps1Path,'-RemoveTask' -PassThru -Wait
T 'remove: -RemoveTask exits cleanly' ($ps2.ExitCode -eq 0)
$q2 = & cmd /c "schtasks.exe /Query /TN WgIme 2>nul" | Out-String
T 'remove: task removed' ($q2 -notmatch 'WgIme')

# ================= 4. runtime smoke: launch, payload DLL extracted, IME worker up =================
$errLog = Join-Path $env:TEMP 'WgIme_error.log'
$mbCache = Join-Path $env:LOCALAPPDATA 'wgime\wgime.mb'
Remove-Item $errLog, $mbCache -Force -EA SilentlyContinue   # force a genuine dict rebuild from the trailer
$dllDir = Join-Path $env:LOCALAPPDATA 'wgime'
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

# ================= summary =================
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
