# ============================================================
#  build-wgtray-dll.ps1 - generate the DLL edition of WgTray
#
#  Produces (inside the wgtray-dll/ folder, new files only):
#    WgTray.bat   - thin double-click launcher (no payload, no
#                   runtime compile, no self-extract, no Bypass)
#    WgTray.dll   - precompiled tray app assembly
#
#  Why this edition: the most AV-friendly non-exe form. At startup
#  the launcher only does Add-Type -Path (load an assembly); there is
#  no base64 PE blob, no FromBase64String, no Invoke-Expression and
#  no runtime C# compilation. Add-Type -Path is allowed even under
#  ConstrainedLanguage, so locked-down machines keep working. Works
#  under the default Restricted ExecutionPolicy (-Command is not gated).
#
#  Reads (never modifies): wgime.bat, wgtray_glue.cs.txt,
#  wgtray_seed_patches.txt. First-run seeding of tools.txt and the
#  plugin samples is done inside the C# (SeedSamples), so the DLL
#  edition is fully self-sufficient on a fresh machine.
#
#  Requires Windows PowerShell 5.1. ASCII-only script; non-ASCII
#  content comes from the UTF-8 templates.
# ============================================================
$ErrorActionPreference = 'Stop'

$src = Join-Path $PSScriptRoot 'wgime.bat'
if (-not (Test-Path $src)) {
    throw "wgime.bat not found next to this script: $src`nRestore it from master: git checkout master -- wgime.bat"
}
$outDir = Join-Path $PSScriptRoot 'wgtray-dll'
$outBat = Join-Path $outDir 'WgTray.bat'
$outDll = Join-Path $outDir 'WgTray.dll'
New-Item $outDir -ItemType Directory -Force | Out-Null

$txt = [IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)
$txt = $txt -replace "`r`n", "`n"          # normalize to LF internally

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

# ---- 2) TrayApp shell (same UTF-8 template the bat editions use) ----
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

# ---- 4) first-run seeding inside the C# (SeedSamples): the DLL edition
#         has no PowerShell bootstrap to seed from, so the samples are
#         embedded as escaped C# string literals and written on first run.
#         Seeds are extracted from wgime.bat and patched via the shared
#         wgtray_seed_patches.txt, exactly like the bat editions. ----
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

function Esc-CSharp([string]$s) {           # text -> C# string literal body (escapes \ " and newlines)
    $s = $s.Replace('\', '\\').Replace('"', '\"')
    $s = $s.Replace("`r", '')
    $s = $s.Replace("`n", '\n')
    return $s
}

$seedBlock = @"

        // ---------- first-run seeding (DLL edition, inside C#): tools.txt + plugins samples ----------
        // Guarded by %LOCALAPPDATA%\wgime\provisioned-tray-dll.done; never overwrites existing files
        static void SeedSamples()
        {
            try {
                string[] seedNames = { "tools.txt", "plugins\\README.txt", "plugins\\clean-bin.txt", "plugins\\clock.txt", "plugins\\calc.txt" };
                string[] seedTexts = {
                    "$(Esc-CSharp $seedTools)",
                    "$(Esc-CSharp $seedPluginReadme)",
                    "$(Esc-CSharp $seedCleanBin)",
                    "$(Esc-CSharp $seedClock)",
                    "$(Esc-CSharp $seedCalc)"
                };
                for (int si = 0; si < seedNames.Length; si++) {
                    string sfp = Path.Combine(BatDir, seedNames[si]);
                    try {
                        if (!File.Exists(sfp)) {
                            string sdir = Path.GetDirectoryName(sfp);
                            if (sdir != null && sdir.Length > 0 && !Directory.Exists(sdir)) Directory.CreateDirectory(sdir);
                            File.WriteAllText(sfp, seedTexts[si], new UTF8Encoding(false));
                        }
                    } catch {}
                }
                string smark = Path.Combine(DataDir, "provisioned-tray-dll.done");
                try { Directory.CreateDirectory(DataDir); File.WriteAllText(smark, DateTime.Now.ToString("s"), new UTF8Encoding(false)); } catch {}
            } catch {}
        }
"@
$parts.Add($seedBlock)
$parts.Add('}')

# ---- 5) assemble the tray C# and inject the SeedSamples call into Run ----
$csTray = [string]::Join("`n", $parts)
$needle = 'BatDir = dir; BatPath = batPath;'
if (-not $csTray.Contains($needle)) { throw 'Run() seed hook not found' }
$csTray = $csTray.Replace($needle, $needle + ' SeedSamples();')

# ---- 6) compile to wgtray-dll/WgTray.dll ----
Add-Type -TypeDefinition $csTray -ReferencedAssemblies System.Windows.Forms,System.Drawing `
         -OutputAssembly $outDll -OutputType Library -ErrorAction Stop
Write-Output ("WgTray.dll written: {0} bytes" -f (Get-Item $outDll).Length)

# ---- 7) thin launcher bat (CRLF, no BOM; no -ExecutionPolicy Bypass: -Command is not policy-gated) ----
$bat = @'
@echo off
rem ============================================================
rem  WgTray - DLL edition (tray-only toolbox, no IME)
rem  Loads the precompiled WgTray.dll next to this file and runs.
rem  No embedded payload / no runtime compile / no self-extract.
rem  Add-Type -Path works on ConstrainedLanguage machines too.
rem  Errors are logged to %TEMP%\WgTray_error.log
rem ============================================================
set "WGTRAY_PATH=%~f0"
set "WGTRAY_DIR=%~dp0"
powershell.exe -NoProfile -NoLogo -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path (Join-Path $env:WGTRAY_DIR 'WgTray.dll'); [TrayApp]::Run($env:WGTRAY_DIR, $env:WGTRAY_PATH) } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)); [System.Windows.Forms.MessageBox]::Show(($_ | Out-String),'WgTray Error') | Out-Null }"
exit /b
'@
$batLines = $bat -split "`n"
# remove the trailing empty element from the here-string, keep CRLF
if ($batLines.Count -gt 0 -and $batLines[$batLines.Count - 1] -eq '') { $batLines = $batLines[0..($batLines.Count - 2)] }
[IO.File]::WriteAllText($outBat, ([string]::Join("`r`n", $batLines) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("WgTray.bat written: {0} bytes" -f (Get-Item $outBat).Length)

# ---- 8) self-checks: no BOM / pure CRLF on the bat / DLL is a valid PE ----
$bytes = [IO.File]::ReadAllBytes($outBat)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if ($bom) { throw 'FAIL: WgTray.bat has a BOM' }
$loneLf = 0
for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
if ($loneLf -gt 0) { throw "FAIL: WgTray.bat has $loneLf lone LF line endings" }
$batTxt = [IO.File]::ReadAllText($outBat, [Text.Encoding]::UTF8)
foreach ($bad in @('Invoke-Expression', 'FromBase64String', 'Add-Type -TypeDefinition', 'ExecutionPolicy', '###PWSHTRAY###')) {
    if ($batTxt.Contains($bad)) { throw "FAIL: launcher must not contain '$bad'" }
}
if (-not $batTxt.Contains('Add-Type -Path')) { throw 'FAIL: launcher missing Add-Type -Path' }
$dllBytes = [IO.File]::ReadAllBytes($outDll)
if ($dllBytes.Length -lt 2 -or $dllBytes[0] -ne 0x4D -or $dllBytes[1] -ne 0x5A) { throw 'FAIL: WgTray.dll is not a valid PE' }
Write-Output "checks OK (launcher clean, DLL is a valid PE)"
Write-Output ("DONE - copy the wgtray-dll folder anywhere and double-click WgTray.bat (keep WgTray.dll next to it)")
