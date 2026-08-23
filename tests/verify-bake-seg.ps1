$ErrorActionPreference = 'Stop'
$t = [IO.File]::ReadAllText('C:\Tools\WgIme\wgime.bat', [Text.Encoding]::UTF8)

function GetSeg([string]$text, [string]$name) {
    $open = "###" + $name + "###"
    $a = $text.IndexOf($open)
    if ($a -lt 0) { return "" }
    $a = $text.IndexOf("`n", $a) + 1
    $b = $text.IndexOf("`n###", $a)
    if ($b -lt 0) { $b = $text.Length }
    return $text.Substring($a, $b - $a).TrimEnd("`r", "`n")
}

# simulate ReplaceDictSeg('PYDATA', 'NEW: 1\nNEW: 2\n')
$newBody = "NEW: 1`nNEW: 2`n"
$open = '###PYDATA###'
$i = $t.IndexOf($open)
$bodyStart = $t.IndexOf("`n", $i) + 1
$end = $t.IndexOf("`n###", $bodyStart)
$result = $t.Substring(0, $bodyStart) + $newBody + $t.Substring($end + 1)

$pyBack = GetSeg $result 'PYDATA'
$wbBack = GetSeg $result 'WBDATA'
$ecBack = GetSeg $result 'ECDATA'
$pwBack = GetSeg $result 'PYWORDS'
$wfBack = GetSeg $result 'PYWFREQ'
Write-Host ("py_back=[" + $pyBack + "] (expect [NEW: 1\nNEW: 2])")
Write-Host ("wb_len=" + $wbBack.Length + " ec_len=" + $ecBack.Length + " pw_len=" + $pwBack.Length + " wf_len=" + $wfBack.Length)
# markers still standalone
foreach ($m in @('###PYDATA###','###WBDATA###','###ECDATA###','###PYWORDS###','###PYWFREQ###')) {
    $idx = $result.IndexOf($m)
    $lineNo = ($result.Substring(0,$idx) -split "`n").Count
    Write-Host ($m + " standalone_check done (idx=" + $idx + ")")
}
# verify the new body followed by a newline then next marker
$j = $result.IndexOf('###PYDATA###')
Write-Host ("after_pydata_marker_next_40=" + ($result.Substring($j, 40) -replace "`n","<NL>"))
