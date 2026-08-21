# ============================================================
#  build-wgtray.ps1 - generate the WgTray distribution file
#
#  Default output: WgTray.ps1 (single-file tray tool, payload edition)
#    * no IME (no keyboard hook / no candidate window / no dicts)
#    * taskbar tray menu only: toolbox (tools.txt) / plugins (plugins\*.txt)
#      / built-in applets / config.txt apps / config / exit
#    * ps1 bootstrap -> load the embedded base64 prebuilt DLL payload
#      (###WGTRAY_DLL### trailer), in-memory C# compile only as fallback
#    * UTF-8 BOM (seed texts contain Chinese; PS 5.1 needs the BOM)
#    * params: -Install registers a logon autostart scheduled task,
#      -RemoveTask deletes it
#
#  -Bat:        also/only write the legacy wgtray.bat (cmd bootstrap +
#               ###PWSHTRAY### self-read; CRLF no-BOM like the old build)
#  -NoPayload:  skip the base64 DLL trailer (in-memory compile only;
#               requires FullLanguage PowerShell at runtime)
#
#  Steps:
#    1. extract the embedded C# source ($cs) from wgime.bat
#    2. slice the reusable code (toolbox engine / ToolsForm / applets /
#       plugin system) by line ranges, prepend the new TrayApp shell
#       (wgtray_glue.cs.txt), produce tray_cs.cs
#    3. compile with Add-Type (Windows PowerShell 5.1 / .NET 4.x)
#    4. assemble WgTray.ps1 (PS head + embedded C# + base64 DLL payload);
#       seeds patched via wgtray_seed_patches.txt
#
#  After editing the C# embedded in the output, run rebuild-tray.ps1
#  (no re-slicing needed). Requires Windows PowerShell 5.1 (powershell.exe).
#
#  NOTE: this script is ASCII-only on purpose (Windows PS 5.1 reads .ps1
#  as ANSI). All non-ASCII content lives in UTF-8 template files that are
#  read explicitly: wgtray_glue.cs.txt, wgtray_ps_body.txt,
#  wgtray_seed_patches.txt.
# ============================================================
param([switch]$NoPayload, [switch]$Bat)
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'wgime.bat'
# default output: WgTray.ps1 (payload) / WgTray-nopayload.ps1 (-NoPayload)
# -Bat: legacy wgtray.bat / wgtray-nopayload.bat (cmd bootstrap, CRLF no-BOM)
if ($Bat) {
    $out = Join-Path $PSScriptRoot $(if ($NoPayload) { 'wgtray-nopayload.bat' } else { 'wgtray.bat' })
} else {
    $out = Join-Path $PSScriptRoot $(if ($NoPayload) { 'WgTray-nopayload.ps1' } else { 'WgTray.ps1' })
}
if (-not (Test-Path $src)) {
    throw "wgime.bat not found next to this script: $src`nThis is the wgtray distribution branch (no IME files). To rebuild wgtray.bat, run this script from a checkout of the master branch (or copy wgime.bat from master into this folder)."
}
$txt = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
$txt = $txt -replace "`r`n", "`n"          # normalize to LF internally

# ---- 1) extract the embedded C# from wgime.bat ----
$i     = $txt.IndexOf("cs = @'")
if ($i -lt 0) { throw "marker 'cs = @''' not found in wgime.bat" }
$start = $txt.IndexOf("`n", $i) + 1
$end   = $txt.IndexOf("`n'@", $start)
$cs    = $txt.Substring($start, $end - $start)
Write-Output ("wgime C# source: {0} chars" -f $cs.Length)
$lines = $cs -split "`n"

# ---- 2) reusable slices (1-based line numbers, anchor-line checked) ----
# NOTE: line numbers are relative to the C# here-string extracted from
# wgime.bat (see step 1). If wgime.bat's C# gains/loses lines, update the
# A/B numbers below (the Anchor check will fail loudly and name the slice).
function Slice([int]$a, [int]$b, [string]$anchor) {
    if ($a -lt 1 -or $b -gt $lines.Count) { throw "slice $a..$b out of range (max $($lines.Count))" }
    $first = $lines[$a - 1].TrimStart()
    if (-not $first.StartsWith($anchor)) { throw "slice $a..$b anchor mismatch: expected '$anchor', got '$first'" }
    $arr = $lines[($a - 1)..($b - 1)]
    return [string]::Join("`n", $arr)
}

$parts = [System.Collections.Generic.List[string]]::new()

# fixed usings (1..11)
$parts.Add((Slice 1 11 'using'))

# ---- 3) the new TrayApp shell (UTF-8 template, read explicitly) ----
$gluePath = Join-Path $PSScriptRoot 'wgtray_glue.cs.txt'
$glue = [IO.File]::ReadAllText($gluePath, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
if (-not $glue.Contains('public class TrayApp')) { throw "wgtray_glue.cs.txt does not contain the TrayApp class" }
$parts.Add($glue)

# ---- 4) verbatim reusable slices (only display-name renames) ----
$sliceDefs = @(
    @{ A = 1491; B = 1499; Anchor = 'static void FixLegacyConfigIfBroken' },
    @{ A = 1851; B = 1906; Anchor = 'void LaunchApp(string code)' },
    @{ A = 1915; B = 1920; Anchor = 'class ToolAction' },
    @{ A = 1921; B = 2206; Anchor = 'static List<string> ToolToks(string line)' },
    @{ A = 2208; B = 2548; Anchor = 'class ToolsForm : Form' },
    @{ A = 2550; B = 2867; Anchor = '// ---------- embedded network tools' },
    @{ A = 2868; B = 3356; Anchor = 'class NetToolsForm : Form' },
    @{ A = 3358; B = 3377; Anchor = '// ---------- embedded clipboard history' },
    @{ A = 3378; B = 3439; Anchor = 'class ClipForm : Form' },
    @{ A = 3441; B = 3452; Anchor = '// ---------- embedded sticky note' },
    @{ A = 3453; B = 3797; Anchor = 'class NoteForm : Form' },   # NoteForm nests NTChip + SBPanel; keep the whole block
    @{ A = 3799; B = 3823; Anchor = '// ---------- embedded color picker' },
    @{ A = 3825; B = 3897; Anchor = 'class ColorForm : Form' },
    @{ A = 3899; B = 4113; Anchor = '// ---------- plugins: plugins' }   # PluginMgrForm now lives in wgtray_glue.cs.txt (with the Run button)
)
foreach ($d in $sliceDefs) {
    $s = Slice $d.A $d.B $d.Anchor
    # display-name renames: "WgIme" -> "WgTray" in window titles / balloons / dialogs;
    # the data dir "wgime" and the "WgIme-NetTools" UserAgent stay untouched
    $s = $s.Replace('"WgImePlugins"', '"WgTrayPlugins"')
    $s = $s.Replace('"WgIme"', '"WgTray"')
    $s = $s.Replace('(WgIme)', '(WgTray)')
    # host class: every reference to WordBoard in the kept code points at TrayApp now
    $s = $s.Replace('WordBoard', 'TrayApp')
    # tool/plugin steps: ExecToolStep's Control param was 'this' (WordBoard was a Form) -> Ui()
    $s = $s.Replace('ExecToolStep(a.Steps[i], isBlock ? a.Raw[i] : ToolRest(a.Raw[i]), sb, this);',
                    'ExecToolStep(a.Steps[i], isBlock ? a.Raw[i] : ToolRest(a.Raw[i]), sb, Ui());')
    # RunToolCode (tools.txt button code runner): same 'this' -> Ui() swap
    $s = $s.Replace('ExecToolStep(a.Steps[k], isBlock ? a.Raw[k] : ToolRest(a.Raw[k]), sb, this);',
                    'ExecToolStep(a.Steps[k], isBlock ? a.Raw[k] : ToolRest(a.Raw[k]), sb, Ui());')
    # RunPlugin: BeginInvoke is a Form method -> marshal via the hidden Ui() control
    $s = $s.Replace('try { BeginInvoke((Action)delegate { TrayTip(a.Name, msg,',
                    'try { Ui().BeginInvoke((Action)delegate { TrayTip(a.Name, msg,')
    $parts.Add($s)
}

# close the TrayApp class (every slice is a WordBoard member, kept inside TrayApp)
$parts.Add('}')

# ---- 5) assemble tray_cs.cs (reference artifact) ----
$csTray = [string]::Join("`n", $parts)
$csTrayPath = Join-Path $PSScriptRoot 'tray_cs.cs'
[IO.File]::WriteAllText($csTrayPath, $csTray, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("tray_cs.cs written: {0} chars" -f $csTray.Length)

# ---- 6) compile (on failure the bat is left untouched) ----
$outDll = Join-Path $env:TEMP 'wgtray_new.dll'
if (Test-Path $outDll) { Remove-Item $outDll -Force }
Add-Type -TypeDefinition $csTray -ReferencedAssemblies System.Windows.Forms,System.Drawing `
         -OutputAssembly $outDll -OutputType Library -ErrorAction Stop
Write-Output ("compiled OK -> {0} ({1} bytes)" -f $outDll, (Get-Item $outDll).Length)

# ---- 7) seeds (extracted from wgime.bat, patched via UTF-8 data file) ----
function Get-Seed([string]$varName) {
    $m = "`n`$$varName = @'`n"
    $p = $txt.IndexOf($m)
    if ($p -lt 0) { throw "seed $varName not found" }
    $s = $p + $m.Length
    $e = $txt.IndexOf("`n'@", $s)
    if ($e -lt 0) { throw "seed $varName terminator not found" }
    return $txt.Substring($s, $e - $s)
}
$seedTools        = Get-Seed 'seedTools'
$seedPluginReadme = Get-Seed 'seedPluginReadme'
$seedCleanBin     = Get-Seed 'seedCleanBin'
$seedClock        = Get-Seed 'seedClock'
$seedCalc         = Get-Seed 'seedCalc'

$patchPath = Join-Path $PSScriptRoot 'wgtray_seed_patches.txt'
foreach ($pl in [IO.File]::ReadAllLines($patchPath, [Text.Encoding]::UTF8)) {
    if ($pl.Length -eq 0 -or $pl[0] -eq '#') { continue }
    $f1 = $pl.IndexOf("`t"); if ($f1 -lt 1) { continue }
    $f2 = $pl.IndexOf("`t", $f1 + 1); if ($f2 -lt 0) { continue }
    $target = $pl.Substring(0, $f1)
    $oldTxt = $pl.Substring($f1 + 1, $f2 - $f1 - 1)
    $newTxt = $pl.Substring($f2 + 1)
    if ($target -eq 'TOOLS') { $seedTools = $seedTools.Replace($oldTxt, $newTxt) }
    elseif ($target -eq 'README') { $seedPluginReadme = $seedPluginReadme.Replace($oldTxt, $newTxt) }
}

# ---- 8) head: cmd bootstrap (bat edition) or PS head (ps1 edition) ----
$batHead = @'
@echo off
rem ============================================================
rem  WgTray - tray-only toolbox (NO IME): taskbar tray menu +
rem  tools.txt toolbox + plugins\*.txt + config.txt apps
rem  bat bootstrap -> PowerShell -> in-memory C# (or prebuilt DLL)
rem  Errors are logged to %TEMP%\WgTray_error.log
rem ============================================================
set "WGTRAY_PATH=%~f0"
set "WGTRAY_DIR=%~dp0"
if /i "%~1"=="_h" goto :main
rem WGTRAY_DEBUG=1: keep console visible so startup errors can be seen on locked-down machines
if defined WGTRAY_DEBUG (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '_h'"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -ArgumentList '_h' -WindowStyle Hidden"
)
exit /b
:main
if defined WGTRAY_DEBUG (
  powershell.exe -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -Command "try { $s=[IO.File]::ReadAllText($env:WGTRAY_PATH,[Text.Encoding]::UTF8); $i=$s.LastIndexOf('###PWSHTRAY###'); $p=$s.Substring($i+14); Invoke-Expression $p } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)); Write-Host ($_ | Out-String) -ForegroundColor Red; Read-Host 'press ENTER to exit' }"
) else (
  powershell.exe -STA -NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { $s=[IO.File]::ReadAllText($env:WGTRAY_PATH,[Text.Encoding]::UTF8); $i=$s.LastIndexOf('###PWSHTRAY###'); $p=$s.Substring($i+14); Invoke-Expression $p } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)); Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(($_ | Out-String),'WgTray Error') | Out-Null }"
)
exit /b
###PWSHTRAY###
'@

# ps1 head: direct PS bootstrap - the file IS the PowerShell script, so no
# cmd layer and no self-read/Invoke-Expression. Command line stays clean:
#   powershell -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File WgTray.ps1
# -Install registers a logon scheduled task (schtasks ONLOGON -> this ps1).
$ps1Head = @'
# ============================================================
#  WgTray - tray-only toolbox (NO IME): taskbar tray menu +
#  tools.txt toolbox + plugins\*.txt + config.txt apps
#  ps1 bootstrap -> load embedded prebuilt DLL payload
#  Errors are logged to %TEMP%\WgTray_error.log
#  Usage:
#    powershell -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File WgTray.ps1
#    powershell ... -File WgTray.ps1 -Install       # + register logon autostart task
#    powershell ... -File WgTray.ps1 -RemoveTask    # - delete the autostart task
# ============================================================
param([switch]$Install, [switch]$RemoveTask)
$env:WGTRAY_PATH = $PSCommandPath
$env:WGTRAY_DIR = $PSScriptRoot + '\'
$env:WGTRAY_AUTOSTART = ''
if ($Install) {
    $inner = 'powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $tr = '"' + $inner.Replace('"', '\"') + '"'
    & schtasks.exe /Create /F /TN WgTray /SC ONLOGON /TR $tr 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'WgTray autostart task registered (logon)' }
    else { Write-Host 'WgTray autostart task registration failed (try as admin)' }
    $env:WGTRAY_AUTOSTART = '1'
}
if ($RemoveTask) {
    & schtasks.exe /Delete /F /TN WgTray 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'WgTray autostart task removed' }
    else { Write-Host 'WgTray autostart task not found' }
    exit 0
}
# If this script's console is VISIBLE (right-click "Run with PowerShell",
# bare -File from a terminal), relaunch ourselves with a hidden console
# and exit - the visible window never stays around. When already started
# hidden (scheduled task / install.bat) IsWindowVisible is False and this
# whole block is skipped, so no extra process is spawned. The child is
# launched with -WindowStyle Hidden (its console is born hidden), and the
# WGHIDE env var guards against any recursion.
if ($env:WGHIDE -ne '1') {
    try {
        Add-Type -Name WgHide -Namespace Wg -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);' -ErrorAction Stop
        $hw = [Wg.WgHide]::GetConsoleWindow()
        if ($hw -ne [IntPtr]::Zero -and [Wg.WgHide]::IsWindowVisible($hw)) {
            $env:WGHIDE = '1'
            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-NoLogo','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"') -WindowStyle Hidden | Out-Null
            [Wg.WgHide]::ShowWindow($hw, 0) | Out-Null
            [Wg.WgHide]::ShowWindow($hw, 0) | Out-Null
            [Wg.WgHide]::SetWindowPos($hw, [IntPtr]::Zero, 0, 0, 0, 0, 0x0087) | Out-Null
            exit
        }
    } catch {}
}
'@

# ---- 9) PowerShell bootstrap body (UTF-8 template with placeholders) ----
# A separate template file is required: the body itself contains multi-line
# here-strings ($cs = @' ... '@), which would terminate a nested here-string
# in this script prematurely.
$psTplPath = Join-Path $PSScriptRoot 'wgtray_ps_body.txt'
$psBody = [IO.File]::ReadAllText($psTplPath, [Text.Encoding]::UTF8)
$psBody = $psBody.Replace("`r`n", "`n")

# PAYLOAD_LOADER: default = full prebuilt-DLL loader; -NoPayload = skip straight to in-memory compile
$payloadLoader = @'
$wgDll = $null
try {
    $all = [IO.File]::ReadAllText($env:WGTRAY_PATH, [Text.Encoding]::UTF8)
    $tag = '###WGTRAY_DLL' + '###'
    $ts = $all.LastIndexOf($tag)
    if ($ts -ge 0) {
        $b64 = (($all.Substring($ts + $tag.Length).Trim()) -replace '\s') -replace "'"
        $md5 = [Security.Cryptography.MD5]::Create()
        $h = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($b64)))).Replace('-','').Substring(0,8)
        $wgDllDir = Join-Path $env:LOCALAPPDATA 'wgime'
        New-Item $wgDllDir -ItemType Directory -Force | Out-Null
        $cand = Join-Path $wgDllDir ("WgTray." + $h + ".dll")
        if (-not (Test-Path $cand)) {
            [IO.File]::WriteAllBytes($cand, [Convert]::FromBase64String($b64))
            Get-ChildItem (Join-Path $wgDllDir 'WgTray.*.dll') -EA SilentlyContinue | Where-Object Name -ne (Split-Path $cand -Leaf) | Remove-Item -Force -Confirm:$false -EA SilentlyContinue
        }
        $wgDll = $cand
    }
} catch { WgLog ("payload extract failed: " + $_.Exception.Message) }
$wgLoaded = $false
if ($wgDll) {
    try { Add-Type -Path $wgDll -ErrorAction Stop; $wgLoaded = $true; WgLog ("prebuilt DLL loaded: " + $wgDll) }
    catch { WgLog ("DLL load failed: " + ($_ | Out-String)) }
}
'@
if ($NoPayload) { $psBody = $psBody.Replace('PAYLOAD_LOADER', '$wgLoaded = $false') }
else            { $psBody = $psBody.Replace('PAYLOAD_LOADER', $payloadLoader) }

$psBody = $psBody.Replace('CS_SOURCE', $csTray)
$psBody = $psBody.Replace('SEED_TOOLS', $seedTools)
$psBody = $psBody.Replace('SEED_README', $seedPluginReadme)
$psBody = $psBody.Replace('SEED_CLEANBIN', $seedCleanBin)
$psBody = $psBody.Replace('SEED_CLOCK', $seedClock)
$psBody = $psBody.Replace('SEED_CALC', $seedCalc)

# ---- 10) assemble the output file ----
$allLines = @()
if ($Bat) {
    $allLines += ($batHead -split "`n")
} else {
    $allLines += ($ps1Head -split "`n")
}
$allLines += ($psBody -split "`n")
if (-not $NoPayload) {
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outDll))
    $allLines += '###WGTRAY_DLL###'
    $allLines += "'" + $b64 + "'"
}
$allLines += ''
$outText = [string]::Join("`n", $allLines)
if ($Bat) {
    # bat: pure CRLF, no BOM (cmd.exe requirement)
    $outText = $outText -replace "`n", "`r`n"
    [IO.File]::WriteAllText($out, $outText, (New-Object System.Text.UTF8Encoding($false)))
} else {
    # ps1: UTF-8 BOM (seed texts contain Chinese; PS 5.1 needs the BOM to read UTF-8)
    [IO.File]::WriteAllText($out, $outText, (New-Object System.Text.UTF8Encoding($true)))
}
Write-Output ("{0} written: {1} bytes{2}" -f (Split-Path $out -Leaf), (Get-Item $out).Length, $(if ($NoPayload) { ' (no payload - in-memory compile only)' } else { '' }))

# ---- 11) self-check ----
$bytes = [IO.File]::ReadAllBytes($out)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if ($Bat) {
    if ($bom) { throw 'FAIL: bat output has a BOM - encoding constraint violated' }
    $loneLf = 0
    for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
    if ($loneLf -gt 0) { throw ("FAIL: {0} lone LF line endings detected (must be pure CRLF, cmd.exe requires it)" -f $loneLf) }
} else {
    if (-not $bom) { throw 'FAIL: ps1 output has no UTF-8 BOM (PS 5.1 would read Chinese seeds as ANSI)' }
}
$txtOut = [IO.File]::ReadAllText($out, [Text.Encoding]::UTF8)
foreach ($m in @('$env:WGTRAY_PATH', '[TrayApp]::Run')) {
    if ($txtOut.IndexOf($m) -lt 0) { throw "marker not found in output: $m" }
}
if ($Bat) {
    if ($txtOut.IndexOf('###PWSHTRAY###') -lt 0) { throw 'FAIL: bat output missing ###PWSHTRAY###' }
}
if ($NoPayload) {
    if ($txtOut.IndexOf('###WGTRAY_DLL###') -ge 0) { throw 'FAIL: -NoPayload build still contains the payload marker' }
    if ($txtOut.IndexOf('FromBase64String') -ge 0) { throw 'FAIL: -NoPayload build still contains FromBase64String' }
} else {
    if ($txtOut.IndexOf('###WGTRAY_DLL###') -lt 0) { throw 'FAIL: payload build missing the payload marker' }
}
Write-Output "file constraints OK"
# ps1 editions also refresh the wg-all distribution folder (keeps it in sync)
if (-not $Bat) {
    $wgAllOut = Join-Path $PSScriptRoot 'wg-all\WgTray.ps1'
    [IO.File]::WriteAllText($wgAllOut, $outText, (New-Object System.Text.UTF8Encoding($true)))
    Write-Output ("wg-all\WgTray.ps1 refreshed: {0} bytes" -f (Get-Item $wgAllOut).Length)
    $relOut = Join-Path $PSScriptRoot 'release\WgTray.ps1'
    [IO.File]::WriteAllText($relOut, $outText, (New-Object System.Text.UTF8Encoding($true)))
    Write-Output ("release\WgTray.ps1 refreshed: {0} bytes" -f (Get-Item $relOut).Length)
}
# -Bat editions also refresh the release folder (pure deliverables)
if ($Bat) {
    $relBat = Join-Path $PSScriptRoot ('release\' + (Split-Path $out -Leaf))
    [IO.File]::WriteAllText($relBat, $outText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ("release\{0} refreshed: {1} bytes" -f (Split-Path $out -Leaf), (Get-Item $relBat).Length)
}
Write-Output ("DONE - {0} is ready (double-click the shortcut / run with -Install for autostart)" -f (Split-Path $out -Leaf))
