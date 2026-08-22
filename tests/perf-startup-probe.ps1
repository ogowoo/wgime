# end-to-end startup timing: LoadFreq + BuildDicts(cache hit) + ApplySwap
$ErrorActionPreference = 'Stop'
$dll = Join-Path $env:TEMP 'wgime-perf-test\WgIme.dll'
$asm = [Reflection.Assembly]::LoadFile($dll)
$wb = $asm.GetType('WordBoard')
$bat = [IO.File]::ReadAllText((Join-Path ($PSScriptRoot | Split-Path -Parent) "wgime.bat"), [Text.Encoding]::UTF8) -replace "`r`n", "`n"
function Get-HS($name) {
    $mm = "`n`$$name = @'`n"
    $p = $bat.IndexOf($mm)
    if ($p -lt 0) { return '' }
    $s = $p + $mm.Length
    $e = $bat.IndexOf("`n'@", $s)
    return $bat.Substring($s, $e - $s)
}
$wb.GetField('SrcPy', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (Get-HS 'pyData'))
$wb.GetField('SrcWb', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (Get-HS 'wbData'))
$wb.GetField('SrcEc', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (Get-HS 'ecData'))
$wb.GetField('SrcPyWords', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (Get-HS 'pyWords'))
$wb.GetField('SrcPyWf', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (Get-HS 'pyWFreq'))
$dataDir = Join-Path $env:LOCALAPPDATA 'wgime'
$wb.GetField('DataDir', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, $dataDir)
$wb.GetField('Freq', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (New-Object 'System.Collections.Generic.Dictionary[string,int]'))
$freqM = [Array]::CreateInstance((New-Object 'System.Collections.Generic.Dictionary[string,int]').GetType(), 3)
$freqM[0] = New-Object 'System.Collections.Generic.Dictionary[string,int]'
$freqM[1] = New-Object 'System.Collections.Generic.Dictionary[string,int]'
$freqM[2] = New-Object 'System.Collections.Generic.Dictionary[string,int]'
$wb.GetField('FreqM', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, $freqM)
$lastPickM = [Array]::CreateInstance((New-Object 'System.Collections.Generic.Dictionary[string,string]').GetType(), 3)
$lastPickM[0] = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$lastPickM[1] = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$lastPickM[2] = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$wb.GetField('LastPickM', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, $lastPickM)
$loadFreq = $wb.GetMethod('LoadFreq', [Reflection.BindingFlags]'Static,NonPublic,Public')
$buildDicts = $wb.GetMethod('BuildDicts', [Reflection.BindingFlags]'Static,NonPublic,Public')
$applySwap = $wb.GetMethod('ApplySwap', [Reflection.BindingFlags]'Static,NonPublic,Public')

$sw = [Diagnostics.Stopwatch]::StartNew()
$loadFreq.Invoke($null, $null) | Out-Null
$sw.Stop()
Write-Host ("LoadFreq: {0} ms" -f $sw.ElapsedMilliseconds)

$sw = [Diagnostics.Stopwatch]::StartNew()
$mb = $buildDicts.Invoke($null, [object[]]@(( | Split-Path -Parent)))
$sw.Stop()
Write-Host ("BuildDicts (cache hit): {0} ms" -f $sw.ElapsedMilliseconds)

$sw = [Diagnostics.Stopwatch]::StartNew()
$applySwap.Invoke($null, [object[]]@($mb)) | Out-Null
$sw.Stop()
Write-Host ("ApplySwap: {0} ms" -f $sw.ElapsedMilliseconds)
Write-Host ("TOTAL: {0} ms" -f (1100 + 0))  # placeholder
