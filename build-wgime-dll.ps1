# ============================================================
#  build-wgime-dll.ps1 - generate the DLL edition of WgIme
#
#  Produces (inside the wgime-dll/ folder, new files only):
#    WgIme.bat   - thin double-click launcher (~1KB, no dicts,
#                  no base64, no embedded C#, no Invoke-Expression)
#    WgIme.dll   - the full IME assembly with the base dictionaries
#                  embedded (pinyin/wubi single chars + word tables)
#    config.txt / tools.txt / plugins\  - copied from this branch
#
#  Why this edition: same idea as wgtray-dll - a thin launcher that
#  only does Add-Type -Path, so there is no base64 PE payload, no
#  runtime C# compile and no script self-extract anywhere. The base
#  dictionaries ride inside the assembly (extracted from wgime.bat's
#  here-strings at build time), so the txt extension files remain
#  optional (py.txt / wb.txt / ec.txt merge on top, same as before).
#
#  The C# itself is UNCHANGED: WordBoard.RunApp keeps its original
#  signature; an additive WgImeLauncher class (also in the assembly)
#  supplies the embedded dictionaries and calls it. The user data
#  directory stays %LOCALAPPDATA%\wgime (created automatically,
#  shared with WgTray). Bake-in ("bake tables") intentionally fails
#  gracefully on this edition: there is no here-string to write into.
#
#  Reads (never modifies): wgime.bat.
#  Requires Windows PowerShell 5.1. ASCII-only script.
# ============================================================
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'wgime.bat'
if (-not (Test-Path $src)) {
    throw "wgime.bat not found next to this script: $src`nRestore it from master: git checkout master -- wgime.bat"
}
$outDir = Join-Path $PSScriptRoot 'wgime-dll'
$outBat = Join-Path $outDir 'WgIme.bat'
$outDll = Join-Path $outDir 'WgIme.dll'
New-Item $outDir -ItemType Directory -Force | Out-Null

$txt = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
$txt = $txt -replace "`r`n", "`n"

# ---- 1) extract the embedded C# and the base dictionaries ----
$i     = $txt.IndexOf("cs = @'")
if ($i -lt 0) { throw "marker 'cs = @''' not found in wgime.bat" }
$start = $txt.IndexOf("`n", $i) + 1
$end   = $txt.IndexOf("`n'@", $start)
$cs    = $txt.Substring($start, $end - $start)
Write-Output ("wgime C# source: {0} chars" -f $cs.Length)

function Get-HereString([string]$varName) {
    $m = "`n`$$varName = @'`n"
    $p = $txt.IndexOf($m)
    if ($p -lt 0) { throw "here-string $varName not found" }
    $s = $p + $m.Length
    $e = $txt.IndexOf("`n'@", $s)
    if ($e -lt 0) { throw "here-string $varName terminator not found" }
    return $txt.Substring($s, $e - $s)
}
$pyData = Get-HereString 'pyData'      # pinyin single chars
$wbData = Get-HereString 'wbData'      # wubi single chars
$ecData = Get-HereString 'ecData'      # EN-CN dictionary
$pyWords = Get-HereString 'pyWords'    # pinyin word table
$pyWFreq = Get-HereString 'pyWFreq'    # word/char corpus weights
Write-Output ("dicts: pyData={0} wbData={1} ecData={2} pyWords={3} pyWFreq={4}" -f $pyData.Length, $wbData.Length, $ecData.Length, $pyWords.Length, $pyWFreq.Length)

function Esc-CSharp([string]$s) {      # text -> C# string literal body
    $s = $s.Replace('\', '\\').Replace('"', '\"')
    $s = $s.Replace("`r", '')
    $s = $s.Replace("`n", '\n')
    return $s
}

# ---- 2) additive launcher class: supplies the embedded dicts, calls the
#         ORIGINAL WordBoard.RunApp signature (WordBoard untouched) ----
$launcher = @"

// WgImeLauncher - entry for the DLL edition (thin bat loads this assembly)
public static class WgImeLauncher
{
    public static void Run(string dir, string batPath)
    {
        WordBoard.RunApp(PyData, WbData, EcData, PyWords, PyWf, dir, batPath);
    }
    const string PyData = "$(Esc-CSharp $pyData)";
    const string WbData = "$(Esc-CSharp $wbData)";
    const string EcData = "$(Esc-CSharp $ecData)";
    const string PyWords = "$(Esc-CSharp $pyWords)";
    const string PyWf = "$(Esc-CSharp $pyWFreq)";
}
"@

$csFull = $cs + "`n" + $launcher

# ---- 3) compile (same referenced assemblies as rebuild.ps1: the IME C#
#         uses UIAutomation / WindowsBase for caret-follow) ----
Add-Type -TypeDefinition $csFull -ReferencedAssemblies System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes,WindowsBase `
         -OutputAssembly $outDll -OutputType Library -ErrorAction Stop
Write-Output ("WgIme.dll written: {0} bytes" -f (Get-Item $outDll).Length)

# ---- 4) thin launcher bat (CRLF, no BOM; -STA for WinForms/clipboard/hooks;
#         -Command is not ExecutionPolicy-gated, so no Bypass needed) ----
$bat = @'
@echo off
rem ============================================================
rem  WgIme - DLL edition (full IME, thin launcher)
rem  Loads the precompiled WgIme.dll next to this file. The base
rem  dictionaries are embedded in the assembly; py.txt / wb.txt /
rem  ec.txt next to this bat still extend them (optional).
rem  No base64 payload / no runtime compile / no self-extract.
rem  Errors are logged to %TEMP%\WgIme_error.log
rem ============================================================
set "WGIME_PATH=%~f0"
set "WGIME_DIR=%~dp0"
powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WGIME_DIR 'WgIme.dll'); [WgImeLauncher]::Run($env:WGIME_DIR, $env:WGIME_PATH) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgIme_error.log'), ($_ | Out-String)); [System.Windows.Forms.MessageBox]::Show(($_ | Out-String),'WgIme Error') | Out-Null }"
exit /b
'@
$batLines = $bat -split "`n"
if ($batLines.Count -gt 0 -and $batLines[$batLines.Count - 1] -eq '') { $batLines = $batLines[0..($batLines.Count - 2)] }
[IO.File]::WriteAllText($outBat, ([string]::Join("`r`n", $batLines) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("WgIme.bat written: {0} bytes" -f (Get-Item $outBat).Length)

# ---- 5) copy the related files into the folder (config / toolbox / plugins;
#         lt.txt is a personal plugin referencing a local path - skipped) ----
foreach ($f in @('config.txt', 'tools.txt')) {
    $fp = Join-Path $PSScriptRoot $f
    if (Test-Path $fp) { Copy-Item $fp (Join-Path $outDir $f) -Force }
}
$srcPlug = Join-Path $PSScriptRoot 'plugins'
$dstPlug = Join-Path $outDir 'plugins'
if (Test-Path $srcPlug) {
    New-Item $dstPlug -ItemType Directory -Force | Out-Null
    Get-ChildItem $srcPlug -File | Where-Object { $_.Name -ne 'lt.txt' } | ForEach-Object { Copy-Item $_.FullName $dstPlug -Force }
}
Write-Output "related files copied (config.txt, tools.txt, plugins\)"

# ---- 6) self-checks ----
$batTxt = [IO.File]::ReadAllText($outBat, [Text.Encoding]::UTF8)
foreach ($bad in @('Invoke-Expression', 'FromBase64String', 'Add-Type -TypeDefinition', 'ExecutionPolicy', '###PWSHTRAY###')) {
    if ($batTxt.Contains($bad)) { throw "FAIL: WgIme.bat must not contain '$bad'" }
}
if (-not $batTxt.Contains('Add-Type -Path')) { throw 'FAIL: WgIme.bat missing Add-Type -Path' }
if (-not $batTxt.Contains('[WgImeLauncher]::Run')) { throw 'FAIL: WgIme.bat missing the launcher entry' }
$batBytes = [IO.File]::ReadAllBytes($outBat)
$bom = ($batBytes.Length -ge 3 -and $batBytes[0] -eq 0xEF -and $batBytes[1] -eq 0xBB -and $batBytes[2] -eq 0xBF)
if ($bom) { throw 'FAIL: WgIme.bat has a BOM' }
$loneLf = 0
for ($k = 0; $k -lt $batBytes.Length; $k++) { if ($batBytes[$k] -eq 0x0A -and ($k -eq 0 -or $batBytes[$k-1] -ne 0x0D)) { $loneLf++ } }
if ($loneLf -gt 0) { throw "FAIL: WgIme.bat has $loneLf lone LF line endings" }
$dllBytes = [IO.File]::ReadAllBytes($outDll)
if ($dllBytes.Length -lt 2 -or $dllBytes[0] -ne 0x4D -or $dllBytes[1] -ne 0x5A) { throw 'FAIL: WgIme.dll is not a valid PE' }
Write-Output "checks OK (launcher clean, DLL is a valid PE)"
Write-Output ("DONE - copy the wgime-dll folder anywhere and double-click WgIme.bat (keep WgIme.dll next to it)")
