# perf probe: time TryLoadMb against the real cache
$ErrorActionPreference = 'Stop'
$dll = Join-Path $env:TEMP 'wgime-perf-test\WgIme.dll'
$asm = [Reflection.Assembly]::LoadFile($dll)
$wb = $asm.GetType('WordBoard')
$mbPath = Join-Path $env:LOCALAPPDATA 'wgime\wgime.mb'
Write-Host "mb: $mbPath exists=$(Test-Path $mbPath) size=$((Get-Item $mbPath -EA SilentlyContinue).Length)"
$m = $wb.GetMethod('TryLoadMb', [Reflection.BindingFlags]'Static,NonPublic,Public')
Write-Host "TryLoadMb found: $($null -ne $m)"

# if no cache, build it via BuildDicts (needs SrcPy etc. set - set from wgime.bat manually)
if (-not (Test-Path $mbPath)) {
    Write-Host "no cache - building via BuildDicts..."
    $bt = $wb.GetMethod('BuildDicts', [Reflection.BindingFlags]'Static,NonPublic,Public')
    # set SrcPy/SrcWb/SrcEc/SrcPyWords/SrcPyWf from wgime.bat here-strings (reuse Get-HereString logic)
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
    $wb.GetField('DataDir', [Reflection.BindingFlags]'Static,Public,NonPublic').SetValue($null, (Join-Path $env:LOCALAPPDATA 'wgime'))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = $bt.Invoke($null, [object[]]@('C:\Tools\WgIme'))
    $sw.Stop()
    Write-Host ("BuildDicts (fresh): {0} ms" -f $sw.ElapsedMilliseconds)
}

if (Test-Path $mbPath) {
    $fs = [IO.File]::OpenRead($mbPath)
    $br = New-Object IO.BinaryReader($fs)
    $magic = $br.ReadBytes(5)
    $md5 = $br.ReadBytes(16)
    $br.Close(); $fs.Close()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $md5Bytes = [byte[]]@($md5)   # unwrap PSObject
    $res = $m.Invoke($null, [object[]]@([string]$mbPath, $md5Bytes))
    $sw.Stop()
    Write-Host ("TryLoadMb total: {0} ms  null={1}" -f $sw.ElapsedMilliseconds, ($null -eq $res))
    if ($res) {
        Write-Host ("  Py keys: {0}" -f $res.Pk.Length)
        Write-Host ("  Wb keys: {0}" -f $res.Wk.Length)
        Write-Host ("  Ec keys: {0}" -f $res.Ek.Length)
        Write-Host ("  Acro:    {0}" -f $res.Acro.Count)
        Write-Host ("  Wf:      {0}" -f $res.WfK.Length)
        # time ToMap alone
        $sw3 = [Diagnostics.Stopwatch]::StartNew()
        $d1 = $res.Pk; $d2 = $res.Pv
        $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([int]$d1.Length)
        for ($i=0; $i -lt $d1.Length; $i++) { $map[$d1[$i]] = $d2[$i] }
        $sw3.Stop()
        Write-Host ("  ToMap(Py {0}): {1} ms" -f $d1.Length, $sw3.ElapsedMilliseconds)
    }
    # measure raw deflate decompression of the payload only
    $fs2 = [IO.File]::OpenRead($mbPath)
    $r0 = New-Object IO.BinaryReader($fs2)
    $null = $r0.ReadBytes(5); $null = $r0.ReadBytes(16)
    $sw2 = [Diagnostics.Stopwatch]::StartNew()
    $ds = New-Object IO.Compression.DeflateStream($fs2, [IO.Compression.CompressionMode]::Decompress, $true)
    $ms = New-Object IO.MemoryStream
    $ds.CopyTo($ms)
    $sw2.Stop()
    Write-Host ("deflate decompress: {0} ms, payload {1:N1} MB" -f $sw2.ElapsedMilliseconds, ($ms.Length/1MB))
    $ds.Close(); $r0.Close(); $fs2.Close()
    if ($res) {
        Write-Host ("  Py keys: {0}" -f $res.Pk.Length)
        Write-Host ("  Wb keys: {0}" -f $res.Wk.Length)
        Write-Host ("  Ec keys: {0}" -f $res.Ek.Length)
        Write-Host ("  Acro:    {0}" -f $res.Acro.Count)
        Write-Host ("  Wf:      {0}" -f $res.WfK.Length)
    }
}
