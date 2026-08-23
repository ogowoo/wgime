# Refactor wgime.bat: move the 5 dict here-strings out of the PS parse path
# into a "###WGIME_DATA###" data block at the end, extracted via ReadAllText+Substring.
# This eliminates the multi-second PowerShell parse of the 30MB here-strings.
# ONE-SHOT: already applied (wgime.bat is now in data-block form). Do NOT run again.
$ErrorActionPreference = 'Stop'
$batPath = 'C:\Tools\WgIme\wgime.bat'
$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

# ---- 1) locate the 5 dict here-strings and the C# ($cs) start ----
$dictOpen = $bat.IndexOf("`$pyData = @'")
if ($dictOpen -lt 0) { throw 'pyData here-string not found' }
$csOpen = $bat.IndexOf("`$cs = @'")
if ($csOpen -lt 0) { throw '$cs not found' }

# extract each here-string body (between the var line and the next line-start '@)
function Extract-HS([string]$varName) {
    $open = "`$" + $varName + " = @'"
    $i = $bat.IndexOf($open, $dictOpen)
    if ($i -lt 0) { throw "$varName not found" }
    $bodyStart = $bat.IndexOf("`n", $i) + 1
    $end = $bat.IndexOf("`n'@", $bodyStart)
    if ($end -lt 0) { throw "$varName close not found" }
    return $bat.Substring($bodyStart, $end - $bodyStart)
}
$py = Extract-HS 'pyData'
$wb = Extract-HS 'wbData'
$ec = Extract-HS 'ecData'
$pw = Extract-HS 'pyWords'
$wf = Extract-HS 'pyWFreq'
Write-Host ("extracted: py={0} wb={1} ec={2} pw={3} wf={4}" -f $py.Length, $wb.Length, $ec.Length, $pw.Length, $wf.Length)

$nl = "`n"

# ---- 2) build the extraction logic (replaces the 5 here-strings) ----
# Single-quoted here-string: $all/$open/$pyData etc. stay literal for wgime.bat runtime.
$extractLogic = (@'
# ---- built-in dicts: extracted from the ###WGIME_DATA### block at EOF (no here-string parse) ----
$all = [IO.File]::ReadAllText($env:WGIME_PATH, [Text.Encoding]::UTF8)
function Get-DictSeg([string]$name) {
    $open = "###" + $name + "###"
    $a = $all.IndexOf($open)
    if ($a -lt 0) { return "" }
    $a = $all.IndexOf("`n", $a) + 1
    $b = $all.IndexOf("`n###", $a)
    if ($b -lt 0) { $b = $all.Length }
    return $all.Substring($a, $b - $a).TrimEnd("`r", "`n")
}
$pyData  = Get-DictSeg 'PYDATA'
$wbData  = Get-DictSeg 'WBDATA'
$ecData  = Get-DictSeg 'ECDATA'
$pyWords = Get-DictSeg 'PYWORDS'
$pyWFreq = Get-DictSeg 'PYWFREQ'
# dicts are parsed on a background thread inside the DLL (UI starts instantly)
WgLog "dicts: parsing in background"
'@ + $nl)

# ---- 3) build the data block: each marker on its own line, body + newline ----
$dataBlock = "###WGIME_DATA###" + $nl +
             "###PYDATA###" + $nl + $py + $nl +
             "###WBDATA###" + $nl + $wb + $nl +
             "###ECDATA###" + $nl + $ec + $nl +
             "###PYWORDS###" + $nl + $pw + $nl +
             "###PYWFREQ###" + $nl + $wf + $nl

# ---- 4) assemble: head + extractLogic + (C#..RunApp) + dataBlock + (###WGIME_DLL###..) ----
$dllMarker = $bat.IndexOf('###WGIME_DLL###')
if ($dllMarker -lt 0) { throw 'DLL marker not found' }
$head = $bat.Substring(0, $dictOpen)            # up to "$pyData = @'"
$mid  = $bat.Substring($csOpen, $dllMarker - $csOpen)   # $cs..seed..RunApp (before DLL marker)
$tail = $bat.Substring($dllMarker)              # ###WGIME_DLL### + base64

$newBat = $head + $extractLogic + $mid + $dataBlock + $tail

# ---- 5) fix the cmd bootstrap: $p only takes the code up to ###WGIME_DATA### ----
# Must use LastIndexOf('###WGIME_DATA###') because the marker also appears in
# the bootstrap line itself and in the extract-logic comment; the data-block
# marker is the LAST occurrence (the DLL base64 contains no '#', so nothing
# after it can match).
$newBat = $newBat.Replace(
  '$i=$s.LastIndexOf(''###PWSH###''); $p=$s.Substring($i+10);',
  '$i=$s.LastIndexOf(''###PWSH###''); $j=$s.LastIndexOf(''###WGIME_DATA###''); $p=$s.Substring($i+10,$j-$i-10);')

[IO.File]::WriteAllText($batPath, $newBat, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("wgime.bat rewritten: {0:N1} MB" -f ((Get-Item $batPath).Length/1MB))
