# ============================================================
#  prep-pywords.ps1  -  ONE-OFF vendor data generator:
#  joins jieba dict.txt (word freq, MIT) with mozillazg
#  phrase-pinyin-data large_pinyin.txt (word -> pinyin, MIT):
#
#    tests\pywords-jieba.txt   code<TAB>word<TAB>freq   (2-8 hanzi words, top 60k by freq)
#    tests\pywfreq-jieba.txt   word<TAB>freq            (those words + all single-hanzi chars; lattice scoring)
#
#  Inputs (download first):
#    $env:TEMP\jieba.dict.txt     https://raw.githubusercontent.com/fxsjy/jieba/master/jieba/dict.txt
#    $env:TEMP\phrase-pinyin.txt  https://raw.githubusercontent.com/mozillazg/phrase-pinyin-data/master/large_pinyin.txt
#
#  Run:  pwsh -NoProfile -File tests\prep-pywords.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$jieba = Join-Path $env:TEMP 'jieba.dict.txt'
$phr   = Join-Path $env:TEMP 'phrase-pinyin.txt'
if (-not (Test-Path $jieba)) { throw "missing $jieba" }
if (-not (Test-Path $phr))   { throw "missing $phr" }

function IsHanzi([string]$s) { foreach ($c in $s.ToCharArray()) { if ($c -lt [char]0x4E00 -or $c -gt [char]0x9FFF) { return $false } } return $s.Length -gt 0 }

# ---- pinyin: word -> concatenated lowercase toneless code (ü -> v) ----
$py = @{}
foreach ($ln in [IO.File]::ReadAllLines($phr, [Text.Encoding]::UTF8)) {
    if ($ln.Length -eq 0 -or $ln[0] -eq '#') { continue }
    $c = $ln.IndexOf(':')
    if ($c -lt 1) { continue }
    $w = $ln.Substring(0, $c).Trim()
    if (-not (IsHanzi $w)) { continue }
    if ($py.ContainsKey($w)) { continue }                    # first entry wins (overwrites file order: most common reading first)
    $syl = $ln.Substring($c + 1).Trim().ToLower()
    $syl = $syl -replace [char]0x00FC, 'v'                   # ü
    $syl = $syl.Normalize([Text.NormalizationForm]::FormD)   # strip tone marks
    $syl = [regex]::Replace($syl, '\p{M}', '')
    $syl = $syl -replace '[^a-z]', ''                        # drop spaces/apostrophes between syllables
    if ($syl.Length -gt 0) { $py[$w] = $syl }
}
Write-Output ("pinyin entries: " + $py.Count)

# ---- jieba freq: word -> freq (hanzi only) ----
$fq = @{}
foreach ($ln in [IO.File]::ReadAllLines($jieba, [Text.Encoding]::UTF8)) {
    if ($ln.Length -eq 0) { continue }
    $p1 = $ln.IndexOf(' '); if ($p1 -lt 1) { continue }
    $p2 = $ln.IndexOf(' ', $p1 + 1); if ($p2 -lt 0) { $p2 = $ln.Length }
    $w = $ln.Substring(0, $p1)
    if (-not (IsHanzi $w)) { continue }
    $f = 0
    if (-not [int]::TryParse($ln.Substring($p1 + 1, $p2 - $p1 - 1), [ref]$f)) { continue }
    $fq[$w] = $f
}
Write-Output ("jieba hanzi entries: " + $fq.Count)

# ---- join ----
$words = New-Object 'System.Collections.Generic.List[string]'   # "code`tword`tfreq"
$wf    = New-Object 'System.Collections.Generic.List[string]'   # "word`tfreq"
foreach ($kv in $fq.GetEnumerator()) {
    $w = $kv.Key
    if ($w.Length -eq 1) { $wf.Add($w + "`t" + $kv.Value); continue }         # single chars: scoring only
    if ($w.Length -gt 8) { continue }
    if ($py.Contains($w)) {
        $code = [string]$py[$w]
        $words.Add($code + "`t" + $w + "`t" + $kv.Value)
        $wf.Add($w + "`t" + $kv.Value)
    }
}
Write-Output ("joined words: " + $words.Count + ", scoring entries: " + $wf.Count)

# top 60k words by freq
$sorted = $words | Sort-Object { [int]($_.Split("`t")[2]) } -Descending
$top = $sorted | Select-Object -First 60000
$topSet = @{}
foreach ($t in $top) { $topSet[$t.Split("`t")[1]] = $true }
$wf2 = $wf | Where-Object { $w = $_.Split("`t")[0]; $w.Length -eq 1 -or $topSet.ContainsKey($w) }

$enc = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllLines((Join-Path $root 'tests\pywords-jieba.txt'), [string[]]$top, $enc)
[IO.File]::WriteAllLines((Join-Path $root 'tests\pywfreq-jieba.txt'), [string[]]$wf2, $enc)
Write-Output ("vendor: pywords-jieba.txt=" + $top.Count + " lines, pywfreq-jieba.txt=" + $wf2.Count + " lines")
