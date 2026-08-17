# ============================================================
#  sync-seeds.ps1  -  rewrite the first-run seed here-strings inside
#  wgime.bat from the repo source files:
#     $seedTools        <- tools.txt
#     $seedPluginReadme <- plugins\README.txt
#     $seedCleanBin     <- plugins\clean-bin.txt
#     $seedClock        <- plugins\clock.txt
#
#  Run after editing any of those files, then verify with
#  tests\seed-sync.tests.ps1. Backs up the bat first (timestamped),
#  keeps UTF-8 no BOM; the batch header must stay CRLF (cmd.exe
#  requires it), here-string bodies may be LF.
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File sync-seeds.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$batPath = Join-Path $root 'wgime.bat'
$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

$pairs = @(
    @('seedTools',        'tools.txt'),
    @('seedPluginReadme', 'plugins\README.txt'),
    @('seedCleanBin',     'plugins\clean-bin.txt'),
    @('seedClock',        'plugins\clock.txt')
)

function ReplaceHereString([string]$text, [string]$varName, [string]$newBody) {
    $open = "`$$varName = @'"
    $i = $text.IndexOf($open)
    if ($i -lt 0) { throw "seed variable $varName not found" }
    $bodyStart = $text.IndexOf("`n", $i) + 1
    $end = $text.IndexOf("`n'@", $bodyStart)
    if ($end -lt 0) { throw "terminator for $varName not found" }
    return $text.Substring(0, $bodyStart) + $newBody + $text.Substring($end + 1)
}

$work = $bat
foreach ($p in $pairs) {
    $file = Join-Path $root $p[1]
    if (-not (Test-Path $file)) { throw "source file missing: $file" }
    $body = ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)) -replace "`r`n", "`n"
    $body = $body.TrimEnd("`n") + "`n"
    if ($body -match "(?m)^'@") { throw "source $($p[1]) contains a line starting with '@ - would break the here-string" }
    $work = ReplaceHereString $work $p[0] $body
    Write-Output ("synced {0} <- {1} ({2} bytes)" -f $p[0], $p[1], $body.Length)
}

$bak = $batPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
[IO.File]::WriteAllText($bak, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "backup: $bak"
[IO.File]::WriteAllText($batPath, $work, (New-Object System.Text.UTF8Encoding($false)))

$bytes = [IO.File]::ReadAllBytes($batPath)
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { throw "BOM appeared - abort" }
$check = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$hdr = $check.Substring(0, $check.LastIndexOf('###PWSH###'))
$loneLf = ([regex]::Matches($hdr, "(?<!`r)`n")).Count
if ($loneLf -gt 0) { throw "FAIL: $loneLf lone LF in batch header - cmd.exe requires CRLF" }
Write-Output "DONE - run tests\seed-sync.tests.ps1 to verify"
