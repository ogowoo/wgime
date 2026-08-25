# Interop orchestrator: runs ref-client.js (Node) vs plugin-harness.ps1 (real plugin code)
# in both relay and MQTT modes, both directions, incl. quote + file transfer. ASCII only.
# Requires: node, powershell 5.1, network.
param([string]$Mode = 'all')   # relay | mqtt | all
$ErrorActionPreference = 'Continue'
$room = 'wgtest' + (Get-Random -Minimum 10000 -Maximum 99999)
$stamp = Get-Date -Format 'HHmmss'
$results = [ordered]@{}

# shared test file (~30KB random)
$testFile = "$PSScriptRoot\testfile-$stamp.bin"
$bytes = New-Object byte[] 30000
(New-Object Random).NextBytes($bytes)
[IO.File]::WriteAllBytes($testFile, $bytes)
$testSha = (Get-FileHash $testFile -Algorithm SHA256).Hash.ToLower()

function Run-Case($mode, $url) {
    $tag = "$mode-$stamp"
    Write-Host "===== CASE $mode url=$url room=$room ====="
    $nodeOut = "$PSScriptRoot\node-$tag.log"
    $psOut = "$PSScriptRoot\ps-$tag.log"
    $node = Start-Process -FilePath 'node' -ArgumentList "$PSScriptRoot\ref-client.js $mode $url $room NodeRef nokey 40000 node2plugin-$mode $testFile" -RedirectStandardOutput $nodeOut -RedirectStandardError "$PSScriptRoot\node-err-$tag.log" -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    $ps = Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $PSScriptRoot\plugin-harness.ps1 -BrokerUrl $url -Room $room -Nick WgPlugin -Key nokey -WaitMs 22000 -SendText plugin2node-$mode -SendFile $testFile" -RedirectStandardOutput $psOut -RedirectStandardError "$PSScriptRoot\ps-err-$tag.log" -PassThru -WindowStyle Hidden
    $ps.WaitForExit(120000)
    if (-not $ps.HasExited) { $ps.Kill() }
    Start-Sleep -Seconds 8
    if (-not $node.HasExited) { $node.Kill() }
    $nodeLog = if (Test-Path $nodeOut) { Get-Content $nodeOut -Raw } else { '' }
    $psLog = if (Test-Path $psOut) { Get-Content $psOut -Raw } else { '' }
    Write-Host '----- NODE LOG -----'; Write-Host $nodeLog
    Write-Host '----- PLUGIN LOG -----'; Write-Host $psLog
    $checks = @(
        @{ N = 'chat plugin->ref'; Ok = ($nodeLog -match [regex]::escape('"text":"plugin2node-' + $mode + '"')) },
        @{ N = 'chat ref->plugin'; Ok = (($psLog -match [regex]::escape('MSG|NodeRef|')) -and ($psLog -match [regex]::escape("node2plugin-$mode"))) },
        @{ N = 'quote plugin->ref'; Ok = ($nodeLog -match '"quote":true') },
        @{ N = 'quote ref->plugin'; Ok = ($psLog -match [regex]::escape('|QUOTE')) },
        @{ N = 'file plugin->ref'; Ok = ($nodeLog -match [regex]::escape('"sha256":"' + $testSha + '"')) },
        @{ N = 'file ref->plugin'; Ok = (($psLog -match [regex]::escape('RECV-FILE|testfile-')) -and ($psLog -match $testSha)) }
    )
    $ok = $true
    foreach ($c in $checks) { Write-Host ("  {0}: {1}" -f $c.N, $(if ($c.Ok) { 'ok' } else { 'MISS' })); if (-not $c.Ok) { $ok = $false } }
    Write-Host ("CASE {0} => {1}" -f $mode, $(if ($ok) { 'PASS' } else { 'FAIL' }))
    $script:results[$mode] = $ok
}

if ($Mode -eq 'relay' -or $Mode -eq 'all') { Run-Case 'relay' 'wss://chat.seee.uno' }
if ($Mode -eq 'mqtt' -or $Mode -eq 'all') { Run-Case 'mqtt' 'wss://broker.emqx.io:8084' }
Write-Host '===== SUMMARY ====='
$fail = 0
foreach ($k in $results.Keys) { Write-Host ("{0}: {1}" -f $k, $(if ($results[$k]) { 'PASS' } else { 'FAIL' })); if (-not $results[$k]) { $fail++ } }
Remove-Item $testFile -Force -ErrorAction SilentlyContinue
exit $fail
