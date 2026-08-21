# ============================================================
#  wgtray-ps1.tests.ps1 - regression tests for the WgTray ps1
#  payload edition (single-file WgTray.ps1: PS bootstrap + embedded
#  base64 prebuilt DLL trailer; no scheduled-task autostart)
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
T 'ps1 has NO scheduled-task autostart (no -Install / no schtasks / no tray item)' ((-not $txt.Contains('/SC ONLOGON')) -and (-not $txt.Contains('-RemoveTask')) -and (-not $txt.Contains('SetAutoStart')) -and (-not $txt.Contains('IsAutoStart')))

# ================= 2. parse check =================
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($ps1Path, [ref]$tokens, [ref]$errors) | Out-Null
T 'ps1 parses without syntax errors' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')

# ================= 3. (removed) scheduled-task autostart - no longer shipped =================
# ps1 editions no longer register any scheduled task / autostart; the
# "no -Install / no schtasks / no SetAutoStart" assertion above covers it.

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
