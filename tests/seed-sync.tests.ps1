# ============================================================
#  seed-sync.tests.ps1  -  verify the first-run seeding embedded in
#  wgime.bat:
#   1. seed here-strings ($seedTools/$seedCleanBin/$seedClock) exist and
#      match the repo files byte-for-byte (modulo line endings)
#   2. provisioning block exists, guarded by provisioned.done marker,
#      writes tools.txt + plugins\README.txt + 2 samples
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\seed-sync.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$bat = [IO.File]::ReadAllText((Join-Path $root 'wgime.bat'), [Text.Encoding]::UTF8)

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name  $detail"; $script:fail++ }
}

function GetHereString([string]$name) {
    $open = "`$$name = @'"
    $i = $bat.IndexOf($open)
    if ($i -lt 0) { return $null }
    $start = $bat.IndexOf("`n", $i) + 1
    $end = $bat.IndexOf("`n'@", $start)
    if ($end -lt 0) { return $null }
    return $bat.Substring($start, $end - $start)
}
function Norm([string]$s) { return ($s -replace "`r`n", "`n").TrimEnd("`n", "`r") }

# ---- 1) seeds match repo files ----
$st = GetHereString 'seedTools'
Check "seedTools exists"        ($st -ne $null)
Check "seedTools == tools.txt"  ((Norm $st) -ceq (Norm ([IO.File]::ReadAllText((Join-Path $root 'tools.txt'), [Text.Encoding]::UTF8))))

$sc = GetHereString 'seedCleanBin'
Check "seedCleanBin exists"           ($sc -ne $null)
Check "seedCleanBin == clean-bin.txt" ((Norm $sc) -ceq (Norm ([IO.File]::ReadAllText((Join-Path $root 'plugins\clean-bin.txt'), [Text.Encoding]::UTF8))))

$sk = GetHereString 'seedClock'
Check "seedClock exists"          ($sk -ne $null)
Check "seedClock == clock.txt"    ((Norm $sk) -ceq (Norm ([IO.File]::ReadAllText((Join-Path $root 'plugins\clock.txt'), [Text.Encoding]::UTF8))))

$sr = GetHereString 'seedPluginReadme'
Check "seedPluginReadme exists"   ($sr -ne $null -and $sr.Length -gt 500)

# ---- 2) provisioning block ----
Check "marker guard"        ($bat.Contains('provisioned.done'))
Check "writes tools.txt"    ($bat -match 'WGIME_DIR .tools\.txt.')
Check "writes README"       ($bat.Contains("README.txt"))
Check "writes clean-bin"    ($bat.Contains("clean-bin.txt"))
Check "writes clock"        ($bat.Contains("clock.txt"))
Check "never overwrites"    (($bat -match 'seedMark' ) -and ($bat -split 'Test-Path').Count -ge 5)
Check "before RunApp"       ($bat.IndexOf('provisioned.done') -lt $bat.IndexOf('[WordBoard]::RunApp'))

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
