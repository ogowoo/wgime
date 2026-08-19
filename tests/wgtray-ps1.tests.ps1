# ============================================================
#  wgtray-ps1.tests.ps1 - regression tests for the PS1 edition
#  (wgtray-ps1\WgTray.ps1: single-file, embedded C# source,
#   compiled in memory at startup; signable via sign-wgtray.ps1)
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1
#
#  NOTE: ASCII-only file - Windows PS 5.1 reads scripts as ANSI.
# ============================================================
$ErrorActionPreference = 'Stop'
$ps1Path = Join-Path $PSScriptRoot '..\wgtray-ps1\WgTray.ps1'
if (-not (Test-Path $ps1Path)) { throw "wgtray-ps1\WgTray.ps1 not found - run build-wgtray-ps1.ps1 first" }
$script:passed = 0; $script:failed = 0
function T($name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:passed++; Write-Host "PASS  $name" -ForegroundColor Green }
    else     { $script:failed++; Write-Host "FAIL  $name  $detail" -ForegroundColor Red }
}

# ================= 1. file structure / encoding =================
$bytes = [IO.File]::ReadAllBytes($ps1Path)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
T 'file has UTF-8 BOM (PS 5.1 needs it for the embedded CJK C#)' $bom
$txt = [IO.File]::ReadAllText($ps1Path, [Text.Encoding]::UTF8)
T 'is a single PowerShell file (no cmd bootstrap)' ($txt.TrimStart().StartsWith('#'))
T 'no bat self-extract marker' (-not $txt.Contains('###PWSHTRAY###'))
T 'no Invoke-Expression' (-not $txt.Contains('Invoke-Expression'))
T 'no FromBase64String' (-not $txt.Contains('FromBase64String'))
# the shell itself never self-launches with Bypass (right-click entry handles policy);
# the C# autostart fix legitimately embeds "-ExecutionPolicy Bypass" as .lnk target args
$shellPart = $txt.Substring(0, $txt.IndexOf("`$cs = @'"))
T 'shell does not self-launch with -ExecutionPolicy Bypass' (-not $shellPart.Contains('ExecutionPolicy'))
T 'compiles the embedded C# in memory' ($txt.Contains('Add-Type -TypeDefinition'))
T 'launches TrayApp with the script dir + path' ($txt.Contains('[TrayApp]::Run((Split-Path -Parent $PSCommandPath), $PSCommandPath)'))
T 'has console self-hide (tray UX)' ($txt.Contains('GetConsoleWindow'))

# ================= 2. embedded C# checks =================
$ci = $txt.IndexOf("`$cs = @'")
if ($ci -lt 0) { throw "embedded C# marker not found" }
$csStart = $txt.IndexOf("`n", $ci) + 1
$csEnd = $txt.IndexOf("`n'@", $csStart)
$cs = $txt.Substring($csStart, $csEnd - $csStart)
T 'no keyboard hook (no IME)' (-not $cs.Contains('class KeyBordHook'))
T 'no WH_KEYBOARD_LL hook' (-not $cs.Contains('WH_KEYBOARD_LL'))
T 'has TrayApp class' ($cs.Contains('public class TrayApp'))
T 'has plugin loader' ($cs.Contains('static void LoadPlugins'))
T 'has toolbox loader' ($cs.Contains('static void LoadTools'))
T 'has plugin manager Run button' ($cs.Contains('66, delegate { RunSel(); });'))
T 'has global hotkey host' ($cs.Contains('class HotKeyHost'))
T 'PS1-edition autostart fix: powershell.exe shortcut for .ps1 hosts' ($cs.Contains('EndsWith(".ps1"'))
# compile gate
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing -ErrorAction Stop
T 'embedded C# compiles (Add-Type)' $true

# ================= 3. runtime smoke: launch like right-click Run with PowerShell =================
$log = Join-Path $env:TEMP 'WgTray_error.log'
Remove-Item $log -Force -EA SilentlyContinue
try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$ps1Path | Out-Null
    Start-Sleep -Seconds 8
    $me = $PID
    $ps = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'"
    $worker = $ps | Where-Object { $_.ProcessId -ne $me -and $_.CommandLine -like '*WgTray.ps1*' }
    T 'runtime: worker is running' ($null -ne $worker)
    if (Test-Path $log) {
        $logTxt = Get-Content $log -Raw -Encoding UTF8
        T 'runtime: no FATAL error' (-not $logTxt.Contains('FATAL'))
    } else {
        T 'runtime: no FATAL error' $true
    }
    if ($worker) { $worker | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue } }
} catch {
    T 'runtime: worker is running' $false $_.Exception.Message
    T 'runtime: no FATAL error' $false $_.Exception.Message
}

# ================= summary =================
Write-Host ""
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
