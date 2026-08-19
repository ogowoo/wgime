# ============================================================
#  vt-scan.ps1 - scan the wg-all distribution on VirusTotal
#
#  Free API key: register at virustotal.com (free tier:
#  4 requests/min, ~500/day). Run:
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File vt-scan.ps1 -ApiKey <key>
#    powershell.exe -NoProfile -ExecutionPolicy Bypass -File vt-scan.ps1 -ApiKey <key> -Path wg-all\WgIme.dll
#
#  For each file: if the SHA256 was already scanned, print the
#  report; otherwise upload it and poll until the analysis
#  completes, then print the detection stats + flagged engines.
#  Throttled to 1 request / 15s (free tier is 4/min).
#
#  NOTE: ASCII-only (Windows PS 5.1 reads .ps1 as ANSI).
# ============================================================
param(
    [string]$ApiKey = '',
    [string[]]$Path = @()
)
$ErrorActionPreference = 'Stop'

if (-not $ApiKey) { throw 'provide -ApiKey (free key from virustotal.com)' }

if ($Path.Count -eq 0) {
    $base = Join-Path $PSScriptRoot 'wg-all'
    $Path = @(
        (Join-Path $base 'WgIme.dll'),
        (Join-Path $base 'WgTray.dll'),
        (Join-Path $base 'install.bat'),
        (Join-Path $base 'WgIme.bat'),
        (Join-Path $base 'WgTray.bat')
    )
}
foreach ($p in $Path) { if (-not (Test-Path $p)) { throw "not found: $p" } }

$client = New-Object System.Net.Http.HttpClient
$client.Timeout = [TimeSpan]::FromMinutes(10)
$client.DefaultRequestHeaders.Add('x-apikey', $ApiKey)
$client.DefaultRequestHeaders.Add('user-agent', 'wgime-vt-scan')

function Invoke-Vt([string]$method, [string]$url, [System.Net.Http.HttpContent]$body = $null) {
    if ($method -eq 'POST') { $resp = $client.PostAsync($url, $body).Result }
    else { $resp = $client.GetAsync($url).Result }
    $txt = $resp.Content.ReadAsStringAsync().Result
    if (-not $resp.IsSuccessStatusCode) { throw "VT HTTP $([int]$resp.StatusCode): $txt" }
    return ($txt | ConvertFrom-Json)
}

function Wait-Vt([double]$sec) { Start-Sleep -Milliseconds ([int]($sec * 1000)) }

function Get-Hash([string]$filePath) {
    return (Get-FileHash $filePath -Algorithm SHA256).Hash.ToLower()
}

function Show-Report([object]$data, [string]$name) {
    $stats = $data.attributes.last_analysis_stats
    $flagged = @()
    $results = $data.attributes.last_analysis_results
    foreach ($k in $results.PSObject.Properties.Name) {
        $r = $results.$k
        if ($r.category -eq 'malicious' -or $r.category -eq 'suspicious') { $flagged += ($k + '=' + $r.category) }
    }
    Write-Host ("{0,-16} {1}" -f $name, ('malicious={0} suspicious={1} undetected={2} harmless={3} timeout={4}' -f $stats.malicious, $stats.suspicious, $stats.undetected, $stats.harmless, $stats.timeout))
    if ($flagged.Count -gt 0) { Write-Host ("    flagged by: " + ($flagged -join ', ')) }
    else { Write-Host "    flagged by: (none)" }
}

foreach ($p in $Path) {
    $name = [IO.Path]::GetFileName($p)
    $sha = Get-Hash $p
    Write-Host ("=== {0}  sha256={1}" -f $name, $sha)
    # 1) already scanned?
    $known = $null
    try {
        $r = Invoke-Vt 'GET' ("https://www.virustotal.com/api/v3/files/" + $sha)
        $known = $r.data
    } catch { $known = $null }   # 404 = not scanned yet
    if ($known) {
        Show-Report $known $name
        Wait-Vt 15
        continue
    }
    # 2) upload
    Write-Host "    not scanned yet - uploading ..."
    $bytes = [IO.File]::ReadAllBytes($p)
    $fc = New-Object System.Net.Http.ByteArrayContent(,$bytes)
    $fc.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('application/octet-stream')
    $form = New-Object System.Net.Http.MultipartFormDataContent
    $form.Add($fc, 'file', $name)
    $up = Invoke-Vt 'POST' 'https://www.virustotal.com/api/v3/files' $form
    $analysisId = $up.data.id
    # 3) poll
    for ($i = 0; $i -lt 60; $i++) {
        Wait-Vt 20
        $an = Invoke-Vt 'GET' ("https://www.virustotal.com/api/v3/analyses/" + $analysisId)
        if ($an.data.attributes.status -eq 'completed') {
            $meta = New-Object PSObject
            $meta | Add-Member NoteProperty attributes @{ last_analysis_stats = $an.data.attributes.stats; last_analysis_results = $an.data.attributes.results }
            Show-Report $meta $name
            break
        }
        if ($i -eq 59) { Write-Host "    analysis not finished after ~20min - rerun the script (hash now cached)" }
    }
    Wait-Vt 15
}
Write-Host ""
Write-Host "DONE - full report table above. A clean run shows malicious=0 for every file."
