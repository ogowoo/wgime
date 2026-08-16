# True consistency check: compare method-body IL of the embedded payload DLL vs a fresh compile of $cs.
# Byte-level compare is invalid (MVID/GUID metadata is random per compile), so we compare IL opcodes.
# Run with Windows PowerShell 5.1:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\check-payload-consistency.ps1
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\wgime.bat'
if (-not (Test-Path $path)) { throw "wgime.bat not found: $path" }
$txt = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)

# --- compile $cs fresh ---
$i = $txt.IndexOf("cs = @'")
$start = $txt.IndexOf("`n", $i) + 1
$end = $txt.IndexOf("`n'@", $start)
$cs = $txt.Substring($start, $end - $start)
$fresh = Join-Path $env:TEMP 'wgime_fresh.dll'
if (Test-Path $fresh) { Remove-Item $fresh -Force }
Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms,System.Drawing,UIAutomationClient,UIAutomationTypes,WindowsBase `
         -OutputAssembly $fresh -OutputType Library -ErrorAction Stop

# --- extract payload from bat ---
$tag = '###WGIME_DLL###'
$ts = $txt.LastIndexOf($tag)
$payloadB64 = (($txt.Substring($ts + $tag.Length).Trim()) -replace '\s') -replace "'"
$payloadDll = Join-Path $env:TEMP 'wgime_payload.dll'
[IO.File]::WriteAllBytes($payloadDll, [Convert]::FromBase64String($payloadB64))

# --- load both in separate AppDomains is overkill; compare method IL via reflection on two assemblies ---
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
    Write-Output ("MISMATCH: " + $diff + " method(s) differ - run rebuild.ps1 (powershell.exe 5.1)")
    exit 1
}
