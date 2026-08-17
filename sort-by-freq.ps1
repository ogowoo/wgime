# ============================================================
#  sort-by-freq.ps1  -  reorder the embedded $pyData / $wbData
#  single-char candidates by an external character-frequency table
#  (default: tests\charfreq-junda.csv, Jun Da's Modern Chinese
#  Character Frequency List, simplified, 9900 chars, rank-ordered).
#
#  Rules:
#   - embedded tables are "packed single chars" lines: `code XXXX...`
#     (no space inside the value; runtime splits them char by char)
#   - each line's value chars are sorted by frequency rank (stable):
#     chars missing from the table keep their original relative order
#     and sink to the end of that line
#   - surrogate pairs (ext-B hanzi) are handled as whole text elements
#   - ecData (EN-CN) is NOT touched; keys/order of lines unchanged
#
#  Safety: timestamped .bak backup first; per-line char multiset must
#  be a pure permutation of the original (verified before write);
#  UTF-8 no BOM; batch header stays CRLF (cmd.exe requires it).
#  The .mb cache auto-invalidates via InputMd5 on next start.
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File sort-by-freq.ps1 [-CsvPath tests\charfreq-junda.csv]
# ============================================================
param([string]$CsvPath = (Join-Path $PSScriptRoot 'tests\charfreq-junda.csv'))
$ErrorActionPreference = 'Stop'

$root    = $PSScriptRoot
$batPath = Join-Path $root 'wgime.bat'
if (-not (Test-Path $CsvPath)) { throw "frequency csv missing: $CsvPath" }

# ---- 1) char -> rank map (rank starts at 1; smaller = more frequent) ----
$rank = @{}
foreach ($ln in [IO.File]::ReadAllLines($CsvPath, [Text.Encoding]::UTF8)) {
    $m = [regex]::Match($ln, '^(\d+),(.+?),')
    if (-not $m.Success) { continue }                     # header / malformed
    $ch = $m.Groups[2].Value
    if (-not $rank.ContainsKey($ch)) { $rank[$ch] = [int]$m.Groups[1].Value }
}
Write-Output ("freq table: {0} chars" -f $rank.Count)

# ---- 2) sort one packed value (surrogate-pair safe, stable by original index) ----
function SplitTextElements([string]$val) {
    $list = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $val.Length; $i++) {
        if ([char]::IsHighSurrogate($val[$i]) -and $i + 1 -lt $val.Length -and [char]::IsLowSurrogate($val[$i + 1])) {
            $list.Add($val.Substring($i, 2)); $i++
        } else { $list.Add([string]$val[$i]) }
    }
    return $list
}
function SortPacked([string]$val) {
    $elems = SplitTextElements $val
    $n = $elems.Count
    $keys = New-Object 'int[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $r = 0
        if ($rank.ContainsKey($elems[$i])) { $r = [int]$rank[$elems[$i]] } else { $r = [int]::MaxValue }
        $keys[$i] = $r
    }
    $idx = New-Object 'int[]' $n
    for ($i = 0; $i -lt $n; $i++) { $idx[$i] = $i }
    # stable: sort (rank, originalIndex)
    $ord = New-Object 'System.Collections.Generic.List[int]'
    $ord.AddRange($idx)
    $ord.Sort([System.Comparison[int]]{ param($a, $b) if ($keys[$a] -ne $keys[$b]) { return $keys[$a].CompareTo($keys[$b]) } return $a.CompareTo($b) })
    $sb = New-Object System.Text.StringBuilder
    foreach ($i in $ord) { [void]$sb.Append($elems[$i]) }
    return $sb.ToString()
}

function SortBody([string]$body, [string]$name) {
    $lines = $body -split "`n"
    $changed = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $ln = $lines[$i].TrimEnd("`r")
        if ($ln.Length -lt 3) { continue }
        $sp = $ln.IndexOf(' ')
        if ($sp -lt 1) { continue }
        $val = $ln.Substring($sp + 1)
        if ($val.Contains(' ')) { continue }                # spaced value = explicit candidates, leave alone
        $sorted = SortPacked $val
        if ($sorted -ne $val) {
            # permutation guard: same chars, same counts
            $a = $val.ToCharArray(); $b = $sorted.ToCharArray()
            [Array]::Sort($a); [Array]::Sort($b)
            if ((New-Object string(,$a)) -ne (New-Object string(,$b))) { throw ("permutation check failed at {0} line {1}" -f $name, ($i + 1)) }
            $lines[$i] = $ln.Substring(0, $sp + 1) + $sorted
            $changed++
        }
    }
    Write-Output ("{0}: {1} lines, {2} reordered" -f $name, $lines.Length, $changed)
    return [string]::Join("`n", $lines)
}

# ---- 3) replace here-string bodies (same semantics as the in-app baker) ----
function ReplaceHereString([string]$text, [string]$varName, [string]$newBody) {
    $open = "`$$varName = @'"
    $i = $text.IndexOf($open)
    if ($i -lt 0) { throw "marker $varName not found" }
    $bodyStart = $text.IndexOf("`n", $i) + 1
    $end = $text.IndexOf("`n'@", $bodyStart)
    if ($end -lt 0) { throw "terminator $varName not found" }
    return $text.Substring(0, $bodyStart) + $newBody + "`n" + $text.Substring($end + 1)
}
function GetHereString([string]$text, [string]$varName) {
    $open = "`$$varName = @'"
    $i = $text.IndexOf($open)
    if ($i -lt 0) { throw "marker $varName not found" }
    $bodyStart = $text.IndexOf("`n", $i) + 1
    $end = $text.IndexOf("`n'@", $bodyStart)
    if ($end -lt 0) { throw "terminator $varName not found" }
    return $text.Substring($bodyStart, $end - $bodyStart)
}

$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

# sample preview: a few high-traffic codes before sorting
foreach ($code in @('de', 'yi', 'wo', 'shi')) {
    foreach ($ln in (($pyOld = GetHereString $bat 'pyData') -split "`n")) {
        if ($ln.StartsWith($code + ' ')) { Write-Output ("before  {0}" -f ($ln.Substring(0, [Math]::Min(46, $ln.Length)) + ' ...')); break }
    }
}

$pyNew = SortBody (GetHereString $bat 'pyData') 'pyData'
$wbNew = SortBody (GetHereString $bat 'wbData') 'wbData'

$work = ReplaceHereString $bat 'pyData' ($pyNew.TrimEnd("`n"))
$work = ReplaceHereString $work 'wbData' ($wbNew.TrimEnd("`n"))

$bak = $batPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
[IO.File]::WriteAllText($bak, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "backup: $bak"
[IO.File]::WriteAllText($batPath, $work, (New-Object System.Text.UTF8Encoding($false)))

foreach ($code in @('de', 'yi', 'wo', 'shi')) {
    foreach ($ln in ((GetHereString $work 'pyData') -split "`n")) {
        if ($ln.StartsWith($code + ' ')) { Write-Output ("after   {0}" -f ($ln.Substring(0, [Math]::Min(46, $ln.Length)) + ' ...')); break }
    }
}

# ---- verify: no BOM / batch header pure CRLF / payload marker intact ----
$bytes = [IO.File]::ReadAllBytes($batPath)
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { throw "BOM appeared - abort" }
$check = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$hdr = $check.Substring(0, $check.LastIndexOf('###PWSH###'))
$loneLf = ([regex]::Matches($hdr, "(?<!`r)`n")).Count
if ($loneLf -gt 0) { throw "FAIL: $loneLf lone LF in batch header - cmd.exe requires CRLF" }
if ($check.IndexOf('###WGIME_DLL###') -lt 0) { throw "payload marker lost" }
Write-Output "DONE - dictionary cache rebuilds automatically on next start (InputMd5 mismatch)"
