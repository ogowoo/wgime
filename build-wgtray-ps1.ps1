# ============================================================
#  build-wgtray-ps1.ps1 - generate the PS1 edition of WgTray
#
#  Produces (new files only):
#    wgtray-ps1/WgTray.ps1 - single-file PowerShell: embedded C#
#    source, compiled in memory at startup
#
#  Why this edition: single-file like the bat editions but without
#  the bat self-extract chain (no Invoke-Expression, no
#  -ExecutionPolicy Bypass, no base64). Launch via right-click
#  "Run with PowerShell" (Process-scope bypass, works on stock
#  Windows), and it can be Authenticode-signed (sign-wgtray.ps1)
#  so it is trusted under AllSigned/RemoteSigned and by AV/SmartScreen.
#
#  Reads (never modifies): wgime.bat, wgtray_glue.cs.txt,
#  wgtray_seed_patches.txt, wgtray_ps1_shell.txt.
#  The only C# difference vs the bat editions: SetAutoStart creates
#  a powershell.exe shortcut when the host file is a .ps1.
#
#  Requires Windows PowerShell 5.1. ASCII-only script; non-ASCII
#  content comes from the UTF-8 templates. The output WgTray.ps1 is
#  written WITH a UTF-8 BOM (PS 5.1 reads BOM-less .ps1 as ANSI).
# ============================================================
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'wgime.bat'
if (-not (Test-Path $src)) {
    throw "wgime.bat not found next to this script: $src`nRestore it from master: git checkout master -- wgime.bat"
}
$outDir = Join-Path $PSScriptRoot 'wgtray-ps1'
$outPs1 = Join-Path $outDir 'WgTray.ps1'
New-Item $outDir -ItemType Directory -Force | Out-Null

$txt = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
$txt = $txt -replace "`r`n", "`n"

# ---- 1) extract the embedded C# from wgime.bat ----
$i     = $txt.IndexOf("cs = @'")
if ($i -lt 0) { throw "marker 'cs = @''' not found in wgime.bat" }
$start = $txt.IndexOf("`n", $i) + 1
$end   = $txt.IndexOf("`n'@", $start)
$cs    = $txt.Substring($start, $end - $start)
$lines = $cs -split "`n"

function Slice([int]$a, [int]$b, [string]$anchor) {
    if ($a -lt 1 -or $b -gt $lines.Count) { throw "slice $a..$b out of range (max $($lines.Count))" }
    $first = $lines[$a - 1].TrimStart()
    if (-not $first.StartsWith($anchor)) { throw "slice $a..$b anchor mismatch: expected '$anchor', got '$first'" }
    $arr = $lines[($a - 1)..($b - 1)]
    return [string]::Join("`n", $arr)
}

$parts = [System.Collections.Generic.List[string]]::new()
$parts.Add((Slice 1 11 'using'))

# ---- 2) TrayApp shell (same UTF-8 template the other editions use) ----
$glue = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'wgtray_glue.cs.txt'), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
if (-not $glue.Contains('public class TrayApp')) { throw "wgtray_glue.cs.txt does not contain the TrayApp class" }
$parts.Add($glue)

# ---- 3) verbatim reusable slices (same table as build-wgtray.ps1) ----
$sliceDefs = @(
    @{ A = 1487; B = 1495; Anchor = 'static void FixLegacyConfigIfBroken' },
    @{ A = 1847; B = 1869; Anchor = 'void LaunchApp(string code)' },
    @{ A = 1878; B = 1882; Anchor = 'class ToolAction' },
    @{ A = 1883; B = 2153; Anchor = 'static List<string> ToolToks(string line)' },
    @{ A = 2155; B = 2495; Anchor = 'class ToolsForm : Form' },
    @{ A = 2497; B = 2814; Anchor = '// ---------- embedded network tools' },
    @{ A = 2815; B = 3303; Anchor = 'class NetToolsForm : Form' },
    @{ A = 3305; B = 3324; Anchor = '// ---------- embedded clipboard history' },
    @{ A = 3325; B = 3386; Anchor = 'class ClipForm : Form' },
    @{ A = 3388; B = 3399; Anchor = '// ---------- embedded sticky note' },
    @{ A = 3400; B = 3744; Anchor = 'class NoteForm : Form' },
    @{ A = 3746; B = 3770; Anchor = '// ---------- embedded color picker' },
    @{ A = 3772; B = 3844; Anchor = 'class ColorForm : Form' },
    @{ A = 3846; B = 4060; Anchor = '// ---------- plugins: plugins' }
)
foreach ($d in $sliceDefs) {
    $s = Slice $d.A $d.B $d.Anchor
    $s = $s.Replace('"WgImePlugins"', '"WgTrayPlugins"')
    $s = $s.Replace('"WgIme"', '"WgTray"')
    $s = $s.Replace('(WgIme)', '(WgTray)')
    $s = $s.Replace('WordBoard', 'TrayApp')
    $s = $s.Replace('ExecToolStep(a.Steps[i], isBlock ? a.Raw[i] : ToolRest(a.Raw[i]), sb, this);',
                    'ExecToolStep(a.Steps[i], isBlock ? a.Raw[i] : ToolRest(a.Raw[i]), sb, Ui());')
    $s = $s.Replace('try { BeginInvoke((Action)delegate { TrayTip(a.Name, msg,',
                    'try { Ui().BeginInvoke((Action)delegate { TrayTip(a.Name, msg,')
    $parts.Add($s)
}
$parts.Add('}')

$csTray = [string]::Join("`n", $parts)

# ---- 4) PS1-edition fix: the host file is a .ps1, so the autostart
#         shortcut must target powershell.exe -File instead of the file
#         itself (a .lnk to a .ps1 would open it in an editor). ----
$autoNeedle = 'lt.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { BatPath });'
if (-not $csTray.Contains($autoNeedle)) { throw 'SetAutoStart hook not found' }
$autoFix = @"
            if (BatPath.EndsWith(".ps1", StringComparison.OrdinalIgnoreCase)) {
                lt.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { "powershell.exe" });
                lt.InvokeMember("Arguments", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `" + BatPath + `"" });
            } else {
                $autoNeedle
            }
"@
$csTray = $csTray.Replace($autoNeedle, $autoFix)

# ---- 5) verify the C# compiles (same gate as the other editions) ----
$checkDll = Join-Path $env:TEMP 'wgtray_ps1_check.dll'
if (Test-Path $checkDll) { Remove-Item $checkDll -Force }
Add-Type -TypeDefinition $csTray -ReferencedAssemblies System.Windows.Forms,System.Drawing `
         -OutputAssembly $checkDll -OutputType Library -ErrorAction Stop
Write-Output ("C# compiled OK ({0} bytes)" -f (Get-Item $checkDll).Length)

# ---- 6) seeds (extracted from wgime.bat, patched via the shared data file) ----
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

# ---- 7) fill the shell template and write WgTray.ps1 (UTF-8 BOM + CRLF) ----
$shell = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'wgtray_ps1_shell.txt'), [Text.Encoding]::UTF8)
$shell = $shell.Replace("`r`n", "`n")
$shell = $shell.Replace('C#SOURCE', $csTray)
$shell = $shell.Replace('SEED_TOOLS', $seedTools)
$shell = $shell.Replace('SEED_README', $seedPluginReadme)
$shell = $shell.Replace('SEED_CLEANBIN', $seedCleanBin)
$shell = $shell.Replace('SEED_CLOCK', $seedClock)
$shell = $shell.Replace('SEED_CALC', $seedCalc)
$outText = $shell -replace "`n", "`r`n"
[IO.File]::WriteAllText($outPs1, $outText, (New-Object System.Text.UTF8Encoding($true)))
Write-Output ("WgTray.ps1 written: {0} bytes (UTF-8 BOM)" -f (Get-Item $outPs1).Length)

# ---- 8) self-checks ----
$ps1Bytes = [IO.File]::ReadAllBytes($outPs1)
$bom = ($ps1Bytes.Length -ge 3 -and $ps1Bytes[0] -eq 0xEF -and $ps1Bytes[1] -eq 0xBB -and $ps1Bytes[2] -eq 0xBF)
if (-not $bom) { throw 'FAIL: WgTray.ps1 must have a UTF-8 BOM (PS 5.1 reads BOM-less .ps1 as ANSI)' }
$ps1Txt = [IO.File]::ReadAllText($outPs1, [Text.Encoding]::UTF8)
foreach ($bad in @('Invoke-Expression', 'FromBase64String', '###PWSHTRAY###', 'wgtray.bat -ArgumentList')) {
    if ($ps1Txt.Contains($bad)) { throw "FAIL: WgTray.ps1 must not contain '$bad'" }
}
foreach ($need in @('Add-Type -TypeDefinition', '[TrayApp]::Run', '$cs = @''', 'EndsWith(".ps1"')) {
    if (-not $ps1Txt.Contains($need)) { throw "FAIL: WgTray.ps1 missing '$need'" }
}
Write-Output "checks OK (BOM present, no bat self-extract patterns, autostart fix in place)"
Write-Output "DONE - right-click wgtray-ps1\WgTray.ps1 -> Run with PowerShell (optionally sign with sign-wgtray.ps1)"
