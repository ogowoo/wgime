# ============================================================
#  check-tray-payload-consistency.ps1 - wgtray.bat payload check
#  Compare method-body IL of the embedded payload DLL vs a fresh
#  compile of the embedded $cs (byte compare is invalid: MVID/GUID
#  metadata is random per compile, so we compare IL opcodes).
#
#  Run with Windows PowerShell 5.1:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\check-tray-payload-consistency.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\wgtray.bat'
if (-not (Test-Path $path)) { throw "wgtray.bat not found: $path" }
$txt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)

# --- compile $cs fresh ---
$i = $txt.IndexOf("cs = @'")
if ($i -lt 0) { throw "marker 'cs = @''' not found" }
$start = $txt.IndexOf("`n", $i) + 1
$end = $txt.IndexOf("`n'@", $start)
$cs = $txt.Substring($start, $end - $start)
$fresh = Join-Path $env:TEMP 'wgtray_fresh.dll'
if (Test-Path $fresh) { Remove-Item $fresh -Force }
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing `
         -OutputAssembly $fresh -OutputType Library -ErrorAction Stop

# --- extract payload from the bat ---
$tag = '###WGTRAY_DLL###'
$ts = $txt.LastIndexOf($tag)
if ($ts -lt 0) { throw "marker $tag not found" }
$payloadB64 = (($txt.Substring($ts + $tag.Length).Trim()) -replace '\s') -replace "'"
$payloadDll = Join-Path $env:TEMP 'wgtray_payload.dll'
[IO.File]::WriteAllBytes($payloadDll, [Convert]::FromBase64String($payloadB64))

# --- compare method IL on both assemblies ---
$asmFresh = [Reflection.Assembly]::LoadFile($fresh)
$asmPayload = [Reflection.Assembly]::LoadFile($payloadDll)

function Get-ILMap([Reflection.Assembly]$asm) {
    $map = @{}
    foreach ($t in $asm.GetTypes()) {
        foreach ($m in $t.GetMethods([Reflection.BindingFlags]'Public,NonPublic,Static,Instance,DeclaredOnly')) {
            try {
                $body = $m.GetMethodBody()
                if ($body) { $map[$t.FullName + '::' + $m.Name + '(' + $m.GetParameters().Length + ')'] = [Convert]::ToBase64String($body.GetILAsByteArray()) }
            } catch {}
        }
    }
    return $map
}

$ilFresh = Get-ILMap $asmFresh
$ilPayload = Get-ILMap $asmPayload
$keysF = $ilFresh.Keys | Sort-Object
$keysP = $ilPayload.Keys | Sort-Object

$diff = 0
foreach ($k in $keysF) {
    if (-not $ilPayload.ContainsKey($k)) { Write-Output "MISSING in payload: $k"; $diff++ }
    elseif ($ilFresh[$k] -ne $ilPayload[$k]) { Write-Output "IL DIFFERS: $k"; $diff++ }
}
foreach ($k in $keysP) { if (-not $ilFresh.ContainsKey($k)) { Write-Output "EXTRA in payload: $k"; $diff++ } }

Write-Output ("methods fresh: " + $keysF.Count + " / payload: " + $keysP.Count)
if ($diff -eq 0) {
    Write-Output "CONSISTENT: embedded payload IL matches freshly compiled C# source"
} else {
    Write-Output ("MISMATCH: " + $diff + " method(s) differ - run rebuild-tray.ps1 (powershell.exe 5.1)")
    exit 1
}
