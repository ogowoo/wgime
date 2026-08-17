# ============================================================
#  build-full-singles.ps1  -  rebuild the embedded $pyData/$wbData
#  blocks in wgime.bat with FULL single-char coverage:
#
#    pinyin singles = embedded order, then py.txt singles, then fill
#                     every remaining CJK char from pinyin-data.txt
#                     (Unihan-derived; tests\pinyin-data.txt, download:
#                      https://raw.githubusercontent.com/mozillazg/pinyin-data/master/pinyin.txt)
#    wubi singles   = embedded order, then wb.txt singles
#                     (no public wubi source for ultra-rare chars; gaps
#                      stay reachable via pinyin)
#
#  Char ranges covered: U+3007, U+3400-4DBF (ext-A), U+4E00-9FFF (BMP).
#  Compat ideographs (F900-FAFF) are skipped on purpose (visual dupes).
#  Multi-char word entries already embedded are preserved.
#
#  Safety: timestamped .bak backup first; byte-identical outside the
#  two here-string blocks; UTF-8 no BOM, batch header stays CRLF (cmd.exe
#  requires it) - verified after write.
#  The .mb cache auto-invalidates via InputMd5 on next start.
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-full-singles.ps1
# ============================================================
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$batPath = Join-Path $root 'wgime.bat'
$pinPath = Join-Path $root 'tests\pinyin-data.txt'
if (-not (Test-Path $pinPath)) { throw "pinyin-data.txt missing: $pinPath" }

$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

function GetBlock([string]$name) {
    $m = [regex]::new("(?m)^\`$$name = @'\r?\n")
    $mm = $m.Match($bat)
    if (-not $mm.Success) { throw "block $name not found" }
    $start = $mm.Index + $mm.Length
    $end = $bat.IndexOf("`n'@", $start)
    if ($end -lt 0) { throw "block $name terminator not found" }
    return $bat.Substring($start, $end - $start)
}

function InScope([int]$cp) {
    return $cp -eq 0x3007 -or ($cp -ge 0x3400 -and $cp -le 0x4DBF) -or ($cp -ge 0x4E00 -and $cp -le 0x9FFF)
}

# ---- tone-marked pinyin -> plain ascii (u-umlaut -> v, matches py.txt convention) ----
# NOTE: pure codepoints only - PS 5.1 reads this file as ANSI, non-ASCII literals get mangled
$tonePairs = @(
    @(0x101,'a'),@(0xE1,'a'),@(0x1CE,'a'),@(0xE0,'a'),
    @(0x113,'e'),@(0xE9,'e'),@(0x11B,'e'),@(0xE8,'e'),@(0xEA,'e'),
    @(0x12B,'i'),@(0xED,'i'),@(0x1D0,'i'),@(0xEC,'i'),
    @(0x14D,'o'),@(0xF3,'o'),@(0x1D2,'o'),@(0xF2,'o'),
    @(0x16B,'u'),@(0xFA,'u'),@(0x1D4,'u'),@(0xF9,'u'),
    @(0x1D6,'v'),@(0x1D8,'v'),@(0x1DA,'v'),@(0x1DC,'v'),@(0xFC,'v'),
    @(0x144,'n'),@(0x148,'n'),@(0x1F9,'n'),@(0x1E3F,'m')
)
$toneMap = @{}
foreach ($p in $tonePairs) { $toneMap[$p[0]] = [char]$p[1] }
function NormalizeReading([string]$s) {
    $s = $s.Normalize([Text.NormalizationForm]::FormC).ToLower().Trim()
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $cp = [int]$ch
        if ($toneMap.ContainsKey($cp)) { [void]$sb.Append($toneMap[$cp]); continue }
        if ($cp -ge 0x300 -and $cp -le 0x36F) { continue }          # stray combining marks
        [void]$sb.Append($ch)
    }
    $r = $sb.ToString()
    if ($r -notmatch '^[a-z]+$') { return $null }
    return $r
}

# ---- source 1+2: embedded block + spaced txt -> ordered code -> List[string] tokens ----
function MergeSingles([string]$embBlock, [string]$txtPath, [bool]$useUnihan, [hashtable]$unihan, [ref]$stats) {
    $codes = New-Object 'System.Collections.Generic.SortedDictionary[string, System.Collections.Generic.List[string]]' ([StringComparer]::Ordinal)
    $covered = @{}

    # source 1: embedded (preserve order; packed singles -> chars; spaced tokens kept as-is)
    foreach ($line in ($embBlock -split "`n")) {
        $t = $line.Trim()
        if ($t.Length -lt 3) { continue }
        $sp = $t.IndexOf(' ')
        if ($sp -lt 1) { continue }
        $code = $t.Substring(0, $sp).ToLower()
        $val = $t.Substring($sp + 1).Trim()
        if ($val.Length -eq 0) { continue }
        $lst = $null
        if (-not $codes.TryGetValue($code, [ref]$lst)) { $lst = New-Object 'System.Collections.Generic.List[string]'; $codes[$code] = $lst }
        if ($val.IndexOf(' ') -lt 0) {                       # packed single chars
            foreach ($ch in $val.ToCharArray()) { $lst.Add([string]$ch); $covered[[int]$ch] = $true }
        } else {
            foreach ($tok in $val.Split(' ')) { if ($tok.Length -gt 0) { $lst.Add($tok); if ($tok.Length -eq 1) { $covered[[int]($tok[0])] = $true } } }
        }
    }
    $embCount = $covered.Count

    # source 2: txt singles (1-char tokens only, in file order; word-only code lines skipped entirely)
    foreach ($line in [IO.File]::ReadLines($txtPath, [Text.Encoding]::UTF8)) {
        $t = $line.Trim()
        if ($t.Length -lt 3 -or $t[0] -eq '#') { continue }
        $parts = $t.Split(@(' ', "`t"), [StringSplitOptions]::RemoveEmptyEntries)
        if ($parts.Length -lt 2) { continue }
        $code = $parts[0].ToLower()
        if ($code -notmatch '^[a-z]+$') { continue }
        $lst = $null
        for ($i = 1; $i -lt $parts.Length; $i++) {
            $w = $parts[$i]
            if ($w.Length -ne 1) { continue }
            $cp = [int]($w[0])
            if (-not (InScope $cp)) { continue }
            if ($lst -eq $null) {
                if (-not $codes.TryGetValue($code, [ref]$lst)) { $lst = New-Object 'System.Collections.Generic.List[string]'; $codes[$code] = $lst }
            }
            if ($lst.Contains($w)) { continue }
            $lst.Add($w)
            $covered[$cp] = $true
        }
    }
    $txtCount = $covered.Count

    # source 3: unihan fill - add EVERY listed reading even if a noisy txt already covered
    # the char elsewhere (py.txt misfiles some rare chars under a wrong code, e.g. U+4F07 under yi)
    $fillCount = 0
    if ($useUnihan) {
        foreach ($kv in $unihan.GetEnumerator()) {
            $cp = $kv.Key
            if (-not (InScope $cp)) { continue }
            $ch = [string]([char]$cp)
            $fresh = -not $covered.ContainsKey($cp)
            foreach ($rd in $kv.Value) {
                $lst = $null
                if (-not $codes.TryGetValue($rd, [ref]$lst)) { $lst = New-Object 'System.Collections.Generic.List[string]'; $codes[$rd] = $lst }
                if (-not $lst.Contains($ch)) { $lst.Add($ch) }
            }
            if ($fresh) { $covered[$cp] = $true; $fillCount++ }
        }
    }
    $stats.Value = @($embCount, $txtCount, $fillCount)
    return $codes
}

function SerializeCodes($codes) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($kv in $codes.GetEnumerator()) {
        $tokens = $kv.Value
        $allSingle = $true
        foreach ($tk in $tokens) { if ($tk.Length -gt 1) { $allSingle = $false; break } }
        if ($allSingle) {
            [void]$sb.Append($kv.Key).Append(' ')
            foreach ($tk in $tokens) { [void]$sb.Append($tk) }
            [void]$sb.Append("`n")
        } else {
            [void]$sb.Append($kv.Key).Append(' ').Append([string]::Join(' ', $tokens.ToArray())).Append("`n")
        }
    }
    return $sb.ToString()
}

# ---- load unihan-derived pinyin-data ----
Write-Output "loading pinyin-data..."
$unihan = @{}
foreach ($line in [IO.File]::ReadLines($pinPath, [Text.Encoding]::UTF8)) {
    if ($line.Length -lt 8 -or $line[0] -eq '#') { continue }
    $m = [regex]::Match($line, '^U\+([0-9A-F]+):\s+(\S+)')
    if (-not $m.Success) { continue }
    $cp = [Convert]::ToInt32($m.Groups[1].Value, 16)
    if (-not (InScope $cp)) { continue }
    $readings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rd in $m.Groups[2].Value.Split(',')) {
        $n = NormalizeReading $rd
        if ($n -ne $null -and -not $readings.Contains($n)) { $readings.Add($n) }
    }
    if ($readings.Count -gt 0 -and -not $unihan.ContainsKey($cp)) { $unihan[$cp] = $readings }
}
Write-Output ("unihan readings loaded: " + $unihan.Count)

# ---- build ----
$stats = $null
$pyCodes = MergeSingles (GetBlock 'pyData') (Join-Path $root 'py.txt') $true $unihan ([ref]$stats)
Write-Output ("pyData: embedded {0} + txt -> {1} + unihan fill {2} = {3} chars, {4} codes" -f $stats[0], $stats[1], $stats[2], ($stats[1] + $stats[2]), $pyCodes.Count)
$pyBody = SerializeCodes $pyCodes

$wbCodes = MergeSingles (GetBlock 'wbData') (Join-Path $root 'wb.txt') $false $null ([ref]$stats)
Write-Output ("wbData: embedded {0} + txt -> {1} chars, {2} codes (no unihan fill for wubi)" -f $stats[0], $stats[1], $wbCodes.Count)
$wbBody = SerializeCodes $wbCodes

# ---- replace blocks (same semantics as the in-app baker) ----
function ReplaceHereString([string]$text, [string]$varName, [string]$newBody) {
    $open = "`$$varName = @'"
    $i = $text.IndexOf($open)
    if ($i -lt 0) { throw "marker $varName not found" }
    $bodyStart = $text.IndexOf("`n", $i) + 1
    $end = $text.IndexOf("`n'@", $bodyStart)
    if ($end -lt 0) { throw "terminator $varName not found" }
    return $text.Substring(0, $bodyStart) + $newBody + $text.Substring($end + 1)
}

$work = ReplaceHereString $bat 'pyData' $pyBody
$work = ReplaceHereString $work 'wbData' $wbBody

$bak = $batPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
[IO.File]::WriteAllText($bak, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "backup: $bak"
[IO.File]::WriteAllText($batPath, $work, (New-Object System.Text.UTF8Encoding($false)))

# ---- verify: no BOM / batch header pure CRLF / payload line intact ----
$bytes = [IO.File]::ReadAllBytes($batPath)
if ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) { throw "BOM appeared - abort" }
$check = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
$hdr = $check.Substring(0, $check.LastIndexOf('###PWSH###'))
$loneLf = ([regex]::Matches($hdr, "(?<!`r)`n")).Count
if ($loneLf -gt 0) { throw "FAIL: $loneLf lone LF in batch header - cmd.exe requires CRLF" }
if ($check.IndexOf('###WGIME_DLL###') -lt 0) { throw "payload marker lost" }
Write-Output ("new bat size: " + $bytes.Length + " bytes (was " + $bat.Length + ")")
Write-Output "DONE - dictionary cache rebuilds automatically on next start (InputMd5 mismatch)"
