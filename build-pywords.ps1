# ============================================================
#  build-pywords.ps1  -  regenerate the embedded $pyWords / $pyWFreq
#  here-strings in wgime.bat from the vendor files:
#
#    tests\pywords-jieba.txt   code<TAB>word<TAB>freq  (top 60k words, freq desc)
#       -> $pyWords: "code w1 w2 ..." per line (code asc, words freq desc, cap 8/code)
#    tests\pywfreq-jieba.txt   word<TAB>freq           (words + single chars)
#       -> $pyWFreq: "word:freq" per line (sentence lattice scoring)
#
#  Vendor files are produced once by tests\prep-pywords.ps1 (jieba x phrase-pinyin-data).
#
#  Safety: timestamped .bak backup first; UTF-8 no BOM; batch header stays
#  CRLF; ###WGIME_DLL### payload untouched. The .mb cache auto-invalidates
#  (pyWords/pyWFreq feed InputMd5). No rebuild.ps1 run needed (data only).
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-pywords.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$root    = $PSScriptRoot
$batPath = Join-Path $root 'wgime.bat'
$wordsF  = Join-Path $root 'tests\pywords-jieba.txt'
$wfF     = Join-Path $root 'tests\pywfreq-jieba.txt'
if (-not (Test-Path $wordsF)) { throw "vendor file missing: $wordsF (run tests\prep-pywords.ps1 first)" }
if (-not (Test-Path $wfF))    { throw "vendor file missing: $wfF" }

# ---- $pyWords body: group by code, words stay in global freq order, cap 8 per code ----
$byCode = New-Object 'System.Collections.Generic.SortedDictionary[string,System.Collections.Generic.List[string]]'
$n = 0
foreach ($ln in [IO.File]::ReadAllLines($wordsF, [Text.Encoding]::UTF8)) {
    $p = $ln.Split("`t")
    if ($p.Length -lt 2) { continue }
    $lst = $null
    if (-not $byCode.TryGetValue($p[0], [ref]$lst)) { $lst = New-Object 'System.Collections.Generic.List[string]'; $byCode[$p[0]] = $lst }
    if ($lst.Count -lt 8 -and -not $lst.Contains($p[1])) { $lst.Add($p[1]); $n++ }
}
$sb = New-Object System.Text.StringBuilder
foreach ($kv in $byCode.GetEnumerator()) { [void]$sb.Append($kv.Key).Append(' ').Append([string]::Join(' ', $kv.Value.ToArray())).Append("`n") }
$pyWordsBody = $sb.ToString()
Write-Output ("pyWords: {0} codes, {1} words" -f $byCode.Count, $n)

# ---- $pyWFreq body: "word:freq" lines as-is ----
$sb2 = New-Object System.Text.StringBuilder
$n2 = 0
foreach ($ln in [IO.File]::ReadAllLines($wfF, [Text.Encoding]::UTF8)) {
    $p = $ln.Split("`t")
    if ($p.Length -lt 2) { continue }
    [void]$sb2.Append($p[0]).Append(':').Append($p[1]).Append("`n"); $n2++
}
Write-Output ("pyWFreq: {0} entries" -f $n2)

function ReplaceHereString([string]$text, [string]$varName, [string]$newBody) {
    $open = "`$$varName = @'"
    $i = $text.IndexOf($open)
    if ($i -lt 0) { throw "marker $varName not found" }
    $bodyStart = $text.IndexOf("`n", $i) + 1
    $end = $text.IndexOf("'@", $bodyStart)          # '@ never appears inside these data tables; empty body -> end == bodyStart
    if ($end -lt 0) { throw "terminator $varName not found" }
    return $text.Substring(0, $bodyStart) + $newBody + $text.Substring($end)
}

$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$work = ReplaceHereString $bat 'pyWords' $pyWordsBody
$work = ReplaceHereString $work 'pyWFreq' $sb2.ToString()

$bak = $batPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
[IO.File]::WriteAllText($bak, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "backup: $bak"
[IO.File]::WriteAllText($batPath, $work, (New-Object System.Text.UTF8Encoding($false)))

# ---- verify: no BOM / batch header pure CRLF / payload marker intact ----
$bytes = [IO.File]::ReadAllBytes($batPath)
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { throw "BOM appeared - abort" }
$check = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$hdr = $check.Substring(0, $check.LastIndexOf('###PWSH###'))
$loneLf = ([regex]::Matches($hdr, "(?<!`r)`n")).Count
if ($loneLf -gt 0) { throw "FAIL: $loneLf lone LF in batch header - cmd.exe requires CRLF" }
if ($check.IndexOf('###WGIME_DLL###') -lt 0) { throw "payload marker lost" }
Write-Output "DONE - dictionary cache rebuilds automatically on next start (InputMd5 mismatch)"
