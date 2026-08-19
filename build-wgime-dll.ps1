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
        EnsureShortcut(dir, batPath);            // first launch: create "<bat-name>.lnk" next to the bat
        WordBoard.RunApp(PyData, WbData, EcData, PyWords, PyWf, dir, batPath);
    }

    // First-launch convenience: a launcher shortcut next to the bat. The
    // shortcut targets powershell.exe DIRECTLY (no bat/cmd involved): it
    // loads WgIme.dll and runs - zero console flash, and -Command is not
    // ExecutionPolicy-gated, so it works under the default Restricted policy.
    // Generated per machine (absolute paths) - never committed. An existing
    // old-format shortcut (targeting the .bat) is upgraded in place.
    static void EnsureShortcut(string dir, string batPath)
    {
        try {
            string lnk = Path.Combine(dir, Path.GetFileNameWithoutExtension(batPath) + ".lnk");
            bool needCreate = !File.Exists(lnk);
            if (!needCreate) {
                try {
                    var ws0 = Type.GetTypeFromProgID("WScript.Shell");
                    var sh0 = Activator.CreateInstance(ws0);
                    var ex0 = ws0.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, sh0, new object[] { lnk });
                    string tgt = (string)ex0.GetType().InvokeMember("TargetPath", System.Reflection.BindingFlags.GetProperty, null, ex0, null);
                    needCreate = string.IsNullOrEmpty(tgt) || tgt.EndsWith(".bat", StringComparison.OrdinalIgnoreCase);   // old format -> upgrade
                } catch { needCreate = false; }
            }
            if (!needCreate) return;
            string dll = System.Reflection.Assembly.GetExecutingAssembly().Location;
            string args = "-NoProfile -NoLogo -STA -WindowStyle Hidden -Command \"try { Add-Type -AssemblyName System.Windows.Forms; Add-Type -Path '" + dll + "'; [WgImeLauncher]::Run('" + dir + "', '" + batPath + "') } catch { [IO.File]::WriteAllText((Join-Path `$env:TEMP 'WgIme_error.log'), (`$_ | Out-String)); [System.Windows.Forms.MessageBox]::Show((`$_ | Out-String),'WgIme Error') | Out-Null }\"";
            var type = Type.GetTypeFromProgID("WScript.Shell");
            var sh = Activator.CreateInstance(type);
            var s = type.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, sh, new object[] { lnk });
            var st = s.GetType();
            st.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, s, new object[] { "powershell.exe" });
            st.InvokeMember("Arguments", System.Reflection.BindingFlags.SetProperty, null, s, new object[] { args });
            st.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, s, new object[] { dir });
            st.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, s, new object[] { "WgIme (DLL edition)" });
            st.InvokeMember("IconLocation", System.Reflection.BindingFlags.SetProperty, null, s, new object[] { dll + ",0" });   // icon lives IN the assembly (build-time injected)
            st.InvokeMember("WindowStyle", System.Reflection.BindingFlags.SetProperty, null, s, new object[] { 7 });
            st.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, s, null);
        } catch {}
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

# ---- 3b) embed a launcher icon INTO the DLL (no .ico file at runtime) ----
# Draw a 256px rounded blue tile with a knocked-out U+4E2D, wrap it as a
# PNG-in-ICO, then inject RT_ICON + RT_GROUP_ICON resources with
# UpdateResource. The shortcut points at "WgIme.dll,0" and Explorer shows
# the icon on the DLL itself.
Add-Type -AssemblyName System.Drawing
$S = 256
$bmp = New-Object System.Drawing.Bitmap($S, $S)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::Transparent)
$rad = [float]($S * 14 / 64); $d = $rad * 2
$tile = New-Object System.Drawing.Drawing2D.GraphicsPath
$tile.AddArc(0, 0, $d, $d, 180, 90)
$tile.AddArc($S - $d, 0, $d, $d, 270, 90)
$tile.AddArc($S - $d, $S - $d, $d, $d, 0, 90)
$tile.AddArc(0, $S - $d, $d, $d, 90, 90)
$tile.CloseFigure()
$br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(0, 120, 212))
$g.FillPath($br, $tile)
$gp = New-Object System.Drawing.Drawing2D.GraphicsPath
$f = New-Object System.Drawing.Font('Microsoft YaHei UI', [single]($S * 52 / 64), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
$sf = New-Object System.Drawing.StringFormat
$sf.Alignment = [System.Drawing.StringAlignment]::Center
$sf.LineAlignment = [System.Drawing.StringAlignment]::Center
$gp.AddString([string][char]0x4E2D, $f.FontFamily, [int][System.Drawing.FontStyle]::Regular, [single]($S * 52 / 64), (New-Object System.Drawing.RectangleF(0, 0, $S, $S)), $sf)
$g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
$tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Transparent)
$g.FillPath($tb, $gp)
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
$png = $ms.ToArray()
$g.Dispose(); $bmp.Dispose(); $tile.Dispose(); $gp.Dispose(); $br.Dispose(); $tb.Dispose(); $f.Dispose(); $sf.Dispose(); $ms.Dispose()

# PNG-in-ICO container (256px, 32bpp)
$icoMs = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter($icoMs)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]1)
$w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0); $w.Write([byte]0)
$w.Write([int16]1); $w.Write([int16]32)
$w.Write([int32]$png.Length)
$w.Write([int32]22)
$w.Write($png)
$icoBytes = $icoMs.ToArray()
$w.Dispose(); $icoMs.Dispose()

# GRPICONDIR + one GRPICONDIRENTRY (resource id 1)
$gms = New-Object System.IO.MemoryStream
$gw = New-Object System.IO.BinaryWriter($gms)
$gw.Write([int16]0); $gw.Write([int16]1); $gw.Write([int16]1)
$gw.Write([byte]0); $gw.Write([byte]0); $gw.Write([byte]0); $gw.Write([byte]0)
$gw.Write([int16]1); $gw.Write([int16]32)
$gw.Write([int32]$png.Length)
$gw.Write([int16]1)
$groupBytes = $gms.ToArray()
$gw.Dispose(); $gms.Dispose()

# inject RT_ICON (3) + RT_GROUP_ICON (14) via UpdateResource
Add-Type -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);' -Name W -Namespace Wg
$hRes = [Wg.W]::BeginUpdateResource($outDll, $false)
if ($hRes -eq [IntPtr]::Zero) { throw 'BeginUpdateResource failed - icon not embedded' }
$ok1 = [Wg.W]::UpdateResource($hRes, [IntPtr]3, [IntPtr]1, 0, $png, [uint32]$png.Length)        # RT_ICON
$ok2 = [Wg.W]::UpdateResource($hRes, [IntPtr]14, [IntPtr]1, 0, $groupBytes, [uint32]$groupBytes.Length)  # RT_GROUP_ICON
$ok3 = [Wg.W]::EndUpdateResource($hRes, $false)
if (-not ($ok1 -and $ok2 -and $ok3)) { throw 'icon resource injection failed' }
Write-Output ("icon embedded into WgIme.dll (256px PNG-in-ICO, {0} bytes)" -f $png.Length)
# verify: the DLL now exposes an icon with a blue tile
$chkIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($outDll)
if ($null -eq $chkIcon) { throw 'icon verification failed: ExtractAssociatedIcon returned null' }
$chkBmp = $chkIcon.ToBitmap()
$c1 = $chkBmp.GetPixel([int]($chkBmp.Width * 0.12), [int]($chkBmp.Height * 0.5))   # left of the glyph, inside the tile: blue
$c2 = $chkBmp.GetPixel([int]($chkBmp.Width * 0.5), [int]($chkBmp.Height * 0.5))    # center of the glyph: transparent
$chkBmp.Dispose(); $chkIcon.Dispose()
if (-not ($c1.B -gt 100 -and $c2.A -lt 128)) { throw ('icon verification failed: unexpected pixels R{0},{1},{2} / A{3}' -f $c1.R, $c1.G, $c1.B, $c2.A) }
Write-Output "icon verified (blue tile + knocked-out glyph)"

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
