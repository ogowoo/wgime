# ============================================================
#  dict-coverage.ps1  -  analyze single-char coverage of the embedded
#  tables in wgime.bat vs the full CJK BMP block (U+4E00..U+9FFF +
#  U+3007 ideographic zero), and how much the repo's py.txt / wb.txt
#  can fill. Pure analysis; writes a summary. PS 5.1 safe (ASCII only).
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\dict-coverage.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$bat = Join-Path $root 'wgime.bat'

$txt = [IO.File]::ReadAllText($bat, [Text.Encoding]::UTF8)

function GetBlock([string]$name) {
    $m = [regex]::new("(?m)^\`$$name = @'\r?\n")
    $mm = $m.Match($txt)
    if (-not $mm.Success) { throw "block $name not found" }
    $start = $mm.Index + $mm.Length
    $end = $txt.IndexOf("`n'@", $start)
    return $txt.Substring($start, $end - $start)
}

# char set of a packed "code chars" table (embedded format: no spaces between chars)
function CharsOfPacked([string]$block) {
    $set = @{}
    foreach ($line in $block -split "`n") {
        $t = $line.TrimEnd("`r")
        $sp = $t.IndexOf(' ')
        if ($sp -lt 1) { continue }
        foreach ($ch in $t.Substring($sp + 1).ToCharArray()) { $set[[int]$ch] = $true }
    }
    return $set
}

# char set of a spaced txt table (py.txt/wb.txt format: code word1 word2 ...; keep SINGLE chars only)
function SingleCharsOfSpaced([string]$path) {
    $set = @{}
    foreach ($line in [IO.File]::ReadLines($path, [Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t.Length -eq 0 -or $t[0] -eq '#') { continue }
        $parts = $t.Split(@(' ', "`t"), [StringSplitOptions]::RemoveEmptyEntries)
        for ($i = 1; $i -lt $parts.Length; $i++) {
            if ($parts[$i].Length -eq 1) { $set[[int]($parts[$i][0])] = $true }
        }
    }
    return $set
}

# target: U+4E00..U+9FFF + U+3007
$target = New-Object 'System.Collections.Generic.List[int]'
for ($cp = 0x4E00; $cp -le 0x9FFF; $cp++) { $target.Add($cp) }
$target.Add(0x3007)

$embPy = CharsOfPacked (GetBlock 'pyData')
$embWb = CharsOfPacked (GetBlock 'wbData')
$pyTxt = SingleCharsOfSpaced (Join-Path $root 'py.txt')
$wbTxt = SingleCharsOfSpaced (Join-Path $root 'wb.txt')

Write-Output ("embedded pyData single chars: " + $embPy.Count)
Write-Output ("embedded wbData single chars: " + $embWb.Count)
Write-Output ("py.txt single chars: " + $pyTxt.Count)
Write-Output ("wb.txt single chars: " + $wbTxt.Count)

$missPy = New-Object 'System.Collections.Generic.List[int]'
$missAll = New-Object 'System.Collections.Generic.List[int]'
foreach ($cp in $target) {
    $inEmb = $embPy.ContainsKey($cp)
    $inTxt = $pyTxt.ContainsKey($cp)
    if (-not $inEmb -and -not $inTxt) { $missPy.Add($cp) }
    if (-not $inEmb) { $missAll.Add($cp) }
}
Write-Output ("")
Write-Output ("target chars (U+4E00-9FFF + U+3007): " + $target.Count)
Write-Output ("missing from embedded pyData: " + $missAll.Count)
Write-Output ("missing from embedded AND py.txt (need external source): " + $missPy.Count)
Write-Output ("missing from embedded wbData AND wb.txt: " + ($target | Where-Object { -not $embWb.ContainsKey($_) -and -not $wbTxt.ContainsKey($_) }).Count)

# sample of the still-missing chars
$sample = ($missPy | Select-Object -First 40 | ForEach-Object { [char]$_ }) -join ''
Write-Output ("sample missing-from-both: " + $sample)
