$ErrorActionPreference = 'Stop'
$bat = [IO.File]::ReadAllText('C:\Tools\WgIme\wgime.bat', [Text.Encoding]::UTF8)
$i = $bat.LastIndexOf('###PWSH###')
$j = $bat.LastIndexOf('###WGIME_DATA###')
$p = $bat.Substring($i+10, $j-$i-10)
Write-Host ("bat_len=" + $bat.Length)
Write-Host ("p_len=" + $p.Length)
Write-Host ("data_block_len=" + ($bat.Length - $j))

function Get-DictSeg([string]$name) {
    $open = "###" + $name + "###"
    $a = $bat.IndexOf($open)
    if ($a -lt 0) { return "" }
    $a = $bat.IndexOf("`n", $a) + 1
    $b = $bat.IndexOf("`n###", $a)
    if ($b -lt 0) { $b = $bat.Length }
    return $bat.Substring($a, $b - $a).TrimEnd("`r", "`n")
}
$py = Get-DictSeg 'PYDATA'
$wb = Get-DictSeg 'WBDATA'
$ec = Get-DictSeg 'ECDATA'
$pw = Get-DictSeg 'PYWORDS'
$wf = Get-DictSeg 'PYWFREQ'
Write-Host ("py={0} wb={1} ec={2} pw={3} wf={4}" -f $py.Length, $wb.Length, $ec.Length, $pw.Length, $wf.Length)

Write-Host ("p_has_RunApp=" + ($p.Contains('[WordBoard]::RunApp')))
Write-Host ("p_has_pyData_body=" + ($p.Contains('pyData: 427 lines')))
Write-Host ("p_has_cs_open=" + ($p.Contains("`$cs = @'")))
Write-Host ("p_has_dllmarker_literal=" + ($p.Contains('###WGIME_DLL###')))

$errors = $null
$null = [System.Management.Automation.PSParser]::Tokenize($p, [ref]$errors)
Write-Host ("parse_errors=" + $errors.Count)
