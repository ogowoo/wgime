# Rebuild the embedded DLL payload inside wgime.bat (the bat edition's runtime DLL)
# Steps: 1) compile fresh WgIme.dll via build-wgime-dll.ps1 into a temp dir
#        2) replace the base64 after ###WGIME_DLL### in wgime.bat with the new DLL
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot | Split-Path -Parent

# 1) build the DLL (temp) - temporarily hide ext dicts so the DLL stays THIN
#    (no trailer: wgime.bat carries base tables in its $cs here-strings and
#     reads py/wb/ec txt from its own folder at runtime)
$ext = @('py.txt','wb.txt','ec.txt','import_py.txt','import_wb.txt','import_ec.txt')
$moved = @()
foreach ($f in $ext) {
    $p = Join-Path $root $f
    if (Test-Path $p) { Move-Item $p ($p + '.embed-tmp') -Force; $moved += $f }
}
$tmpOut = Join-Path $env:TEMP ("wgime-embed-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item $tmpOut -ItemType Directory -Force | Out-Null
try {
    & (Join-Path $root 'build-wgime-dll.ps1') -OutDir $tmpOut | Out-Null
    $dll = Join-Path $tmpOut 'WgIme.dll'
    if (-not (Test-Path $dll)) { throw "DLL not produced" }
    Write-Host ("built THIN DLL: {0:N1} KB" -f ((Get-Item $dll).Length / 1KB))

    # 2) replace payload in wgime.bat
    $batPath = Join-Path $root 'wgime.bat'
    $bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)
    $tag = '###WGIME_DLL###'
    $ti = $bat.LastIndexOf($tag)
    if ($ti -lt 0) { throw 'marker not found in wgime.bat' }
    $head = $bat.Substring(0, $ti + $tag.Length)
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($dll))
    $newBat = $head + "`n'" + $b64 + "'"
    [IO.File]::WriteAllText($batPath, $newBat, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("wgime.bat payload replaced, new size {0:N1} MB" -f ((Get-Item $batPath).Length / 1MB))
} finally {
    Remove-Item $tmpOut -Recurse -Force -EA SilentlyContinue
    foreach ($f in $moved) {
        $src = (Join-Path $root ($f + '.embed-tmp'))
        $dst = Join-Path $root $f
        if (Test-Path $src) { Move-Item $src $dst -Force }
    }
}
