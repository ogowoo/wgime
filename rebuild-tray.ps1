# ============================================================
#  rebuild-tray.ps1  -  wgtray.bat C# payload rebuild tool
#
#  Purpose: after editing the C# source embedded in wgtray.bat
#  ($cs here-string), run this script to recompile and replace the
#  base64 prebuilt DLL payload; otherwise the runtime keeps the
#  old code.
#
#  Requirement: must run under Windows PowerShell 5.1
#  (powershell.exe). pwsh 7 (.NET Core) builds assemblies that
#  5.1 cannot load.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File rebuild-tray.ps1
#
#  Validation: on compile failure wgtray.bat is left untouched;
#  wrong payload line position aborts.
#
#  NOTE: ASCII-only on purpose (Windows PS 5.1 reads .ps1 as ANSI).
# ============================================================
$ErrorActionPreference = 'Stop'

$path = Join-Path $PSScriptRoot 'wgtray.bat'
if (-not (Test-Path $path)) { throw "wgtray.bat not found next to this script: $path" }
$txt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
# normalize to LF internally; write back as CRLF (mixed line endings possible after bake)
$txt = $txt -replace "`r`n", "`n"

# ---- 1) extract the $cs here-string source ("cs = @'" until the first line-start '@) ----
$i     = $txt.IndexOf("cs = @'")
if ($i -lt 0) { throw "marker 'cs = @''' not found" }
$start = $txt.IndexOf("`n", $i) + 1
$end   = $txt.IndexOf("`n'@", $start)
if ($end -lt 0) { throw "cs here-string terminator not found" }
$cs    = $txt.Substring($start, $end - $start)
Write-Output ("cs source: {0} chars" -f $cs.Length)

# ---- 2) compile (on failure wgtray.bat is untouched, safe) ----
$outDll = Join-Path $env:TEMP 'wgtray_new.dll'
if (Test-Path $outDll) { Remove-Item $outDll -Force }
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing `
         -OutputAssembly $outDll -OutputType Library -ErrorAction Stop
Write-Output "compiled OK -> $outDll"

# ---- 3) base64 replace of the payload line (file must stay CRLF / no BOM / UTF-8;
#         cmd.exe needs CRLF to parse the batch head) ----
$b64   = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outDll))
$lines = $txt -split "`n"
$mi    = [Array]::IndexOf($lines, '###WGTRAY_DLL###')
if ($mi -lt 0) {
    throw 'marker ###WGTRAY_DLL### not found - this wgtray.bat was built with -NoPayload (no prebuilt DLL). Run build-wgtray.ps1 instead to regenerate the whole file.'
}
if ($mi -ne ($lines.Count - 3)) {
    Write-Warning ("marker at index {0}, expected {1} - still replacing by marker position" -f $mi, ($lines.Count - 3))
}
# payload line is wrapped in single quotes (a no-op PS statement)
$lines[$mi + 1] = "'" + $b64 + "'"
$outText = [string]::Join("`r`n", $lines)
[IO.File]::WriteAllText($path, $outText, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("payload replaced: {0} chars base64 -> {1}" -f $b64.Length, $path)

# ---- 4) self-check: no BOM / pure CRLF (no bare LF, cmd cannot parse) ----
$bytes = [IO.File]::ReadAllBytes($path)
$bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if ($bom) { throw 'FAIL: file now has a BOM - encoding constraint violated' }
$loneLf = 0
for ($k = 0; $k -lt $bytes.Length; $k++) { if ($bytes[$k] -eq 0x0A -and ($k -eq 0 -or $bytes[$k-1] -ne 0x0D)) { $loneLf++ } }
if ($loneLf -gt 0) { throw ("FAIL: {0} lone LF line endings detected (must be pure CRLF, cmd.exe requires it)" -f $loneLf) }
Write-Output "file constraints OK (no BOM, pure CRLF)"
Write-Output "DONE - restart wgtray.bat to load the new code (new DLL hash name auto-created, old cleaned)"
