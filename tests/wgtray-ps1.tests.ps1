# ============================================================
#  wgtray-ps1.tests.ps1 - regression tests for the WgTray ps1
#  payload edition (single-file WgTray.ps1: PS bootstrap + embedded
#  base64 prebuilt DLL trailer; autostart via scheduled task)
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1
#
#  NOTE: ASCII-only file - Windows PS 5.1 reads scripts as ANSI.
# ============================================================
$ErrorActionPreference = 'Stop'
$rootDir = $PSScriptRoot | Split-Path -Parent
$ps1Path = Join-Path $rootDir 'WgTray.ps1'
$script:passed = 0; $script:failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# ================= 1. single-file payload structure =================
if (-not (Test-Path $ps1Path)) { throw "WgTray.ps1 not found - run build-wgtray.ps1 first" }
$bytes = [IO.File]::ReadAllBytes($ps1Path)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
T 'ps1 has UTF-8 BOM (Chinese seeds need it)' $bom
$txt = [IO.File]::ReadAllText($ps1Path, [Text.Encoding]::UTF8)
T 'ps1 is self-contained: payload trailer present' ($txt.Contains('###WGTRAY_DLL###'))
T 'ps1 embeds the C# fallback source' ($txt.Contains("cs = @'"))
T 'ps1 launches TrayApp' ($txt.Contains('[TrayApp]::Run'))
T 'ps1 no cmd self-extract marker (###PWSHTRAY###)' (-not $txt.Contains('###PWSHTRAY###'))
# launch command line stays clean: just -File WgTray.ps1, no Add-Type in it
T 'ps1 head registers the scheduled task via schtasks' ($txt.Contains('/TN WgTray /SC ONLOGON'))
T 'ps1 has -RemoveTask support' ($txt.Contains('-RemoveTask'))

# ================= 2. parse check =================
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errors) | Out-Null
T 'ps1 parses without syntax errors' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')

# ================= 3. scheduled-task autostart (-Install / -RemoveTask) =================
& cmd /c "schtasks.exe /Delete /F /TN WgTray 2>nul" | Out-Null
$ins = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ps1Path,'-Install' -PassThru
Start-Sleep -Seconds 10
$q = & schtasks.exe /Query /TN WgTray /FO LIST /V 2>&1 | Out-String
T 'install: task registered' ($q -match 'WgTray')
$tr = ($q -split "`r?`n") | Where-Object { $_ -match '^Task To Run' } | Select-Object -First 1
T 'install: task runs powershell -File ps1 (no Add-Type in cmd)' ($tr -match 'powershell\.exe.*-File.*WgTray\.ps1' -and $tr -notmatch 'Add-Type')
T 'install: task triggers at logon' ($q -match 'At logon time')
# -Install also launches the tray (install-and-run); stop the worker
$wIns = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like '*WgTray.ps1*' -and $_.CommandLine -like '*-Install*' }
if ($wIns) { $wIns | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }
$ps2 = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ps1Path,'-RemoveTask' -PassThru -Wait
T 'remove: -RemoveTask exits cleanly' ($ps2.ExitCode -eq 0)
$q2 = & cmd /c "schtasks.exe /Query /TN WgTray 2>nul" | Out-String
T 'remove: task removed' ($q2 -notmatch 'WgTray')

# ================= 4. runtime smoke: launch, payload DLL extracted, tray worker up =================
$errLog = Join-Path $env:TEMP 'WgTray_error.log'
Remove-Item $errLog -Force -EA SilentlyContinue
$dllDir = Join-Path $env:LOCALAPPDATA 'wgime'
Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-NoLogo','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ps1Path | Out-Null
Start-Sleep -Seconds 12
$me = $PID
$w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*WgTray.ps1*' }
T 'runtime: tray worker is running' ($null -ne $w)
# deterministic hash name: the payload DLL was extracted from the ps1 trailer
$extracted = Get-ChildItem (Join-Path $dllDir 'WgTray.*.dll') -EA SilentlyContinue | Select-Object -First 1
T 'runtime: payload DLL extracted from ps1 trailer' ($null -ne $extracted -and $extracted.Length -gt 50000) ("dll=$($extracted.Name) len=$($extracted.Length)")
$fatal = $null
if (Test-Path $errLog) { $fatal = Get-Content $errLog -Raw | Select-String -Pattern 'FATAL|throw' }
T 'runtime: no FATAL in error log' ($null -eq $fatal)
if ($w) { $w | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }

# ================= summary =================
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
