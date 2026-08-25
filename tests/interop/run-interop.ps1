# Interop orchestrator: runs ref-client.js (Node) vs plugin-harness.ps1 (real plugin code)
# in both relay and MQTT modes, both directions. ASCII only. Requires: node, powershell 5.1, network.
param([string]$Mode = 'all')   # relay | mqtt | all
$ErrorActionPreference = 'Continue'
$room = 'wgtest' + (Get-Random -Minimum 10000 -Maximum 99999)
$stamp = Get-Date -Format 'HHmmss'
$results = [ordered]@{}

function Run-Case($mode, $url) {
    $tag = "$mode-$stamp"
    Write-Host "===== CASE $mode url=$url room=$room ====="
    $nodeOut = "$PSScriptRoot\node-$tag.log"
    $psOut = "$PSScriptRoot\ps-$tag.log"
    $node = Start-Process -FilePath 'node' -ArgumentList "$PSScriptRoot\ref-client.js $mode $url $room NodeRef nokey 32000 node2plugin-$mode" -RedirectStandardOutput $nodeOut -RedirectStandardError "$PSScriptRoot\node-err-$tag.log" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $ps = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $PSScriptRoot\plugin-harness.ps1 -BrokerUrl $url -Room $room -Nick WgPlugin -Key nokey -WaitMs 15000 -SendText plugin2node-$mode" -RedirectStandardOutput $psOut -RedirectStandardError "$PSScriptRoot\ps-err-$tag.log" -PassThru -WindowStyle Hidden
    $ps.WaitForExit(90000)
    if (-not $ps.HasExited) { $ps.Kill() }
    Start-Sleep -Seconds 8
    if (-not $node.HasExited) { $node.Kill() }
    $nodeLog = if (Test-Path $nodeOut) { Get-Content $nodeOut -Raw } else { '' }
    $psLog = if (Test-Path $psOut) { Get-Content $psOut -Raw } else { '' }
    Write-Host '----- NODE LOG -----'; Write-Host $nodeLog
    Write-Host '----- PLUGIN LOG -----'; Write-Host $psLog
    $nodeGotPlugin = $nodeLog -match [regex]::escape('"text":"plugin2node-' + $mode + '"')
    $pluginGotNode = ($psLog -match [regex]::escape('MSG|NodeRef|')) -and ($psLog -match [regex]::escape("node2plugin-$mode"))
    $ok = ($nodeGotPlugin -and $pluginGotNode)
    Write-Host ("CASE {0}: plugin->ref={1} ref->plugin={2} => {3}" -f $mode, $nodeGotPlugin, $pluginGotNode, $(if ($ok) { 'PASS' } else { 'FAIL' }))
    $script:results[$mode] = $ok
}

if ($Mode -eq 'relay' -or $Mode -eq 'all') { Run-Case 'relay' 'wss://chat.seee.uno' }
if ($Mode -eq 'mqtt' -or $Mode -eq 'all') { Run-Case 'mqtt' 'wss://broker.emqx.io:8084' }
Write-Host '===== SUMMARY ====='
$fail = 0
foreach ($k in $results.Keys) { Write-Host ("{0}: {1}" -f $k, $(if ($results[$k]) { 'PASS' } else { 'FAIL' })); if (-not $results[$k]) { $fail++ } }
exit $fail
