# build-package.ps1 -- rebuild the single-file and refresh the ready-to-copy package folder.
# ASCII only (PS 5.1 reads scripts as ANSI). Run: powershell -NoProfile -File build-package.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist = Join-Path $here 'dist'
$pkg = Join-Path $here 'package'
$dicts = Join-Path $pkg 'dicts'

# 1. rebuild single file
python (Join-Path $here 'build-wgime-pure.py')
if (-not (Test-Path (Join-Path $dist 'wgime-py.py'))) { throw 'dist\wgime-py.py missing after build' }

# 2. refresh package
New-Item -ItemType Directory -Force $pkg | Out-Null
New-Item -ItemType Directory -Force $dicts | Out-Null
Copy-Item (Join-Path $dist 'wgime-py.py') $pkg -Force
Copy-Item (Join-Path $here 'run-csharp-plugin.ps1') $pkg -Force   # [csharp] sidecar

# 3. refresh dicts from the repo (C:\Tools\wgime)
$src = 'C:\Tools\wgime'
foreach ($n in @('py.txt', 'wb.txt', 'ec.txt', 'trad.txt', 'pywfreq.txt', 'config.txt', 'tools.txt')) {
    $p = Join-Path $src $n
    if (Test-Path $p) { Copy-Item $p $dicts -Force } else { Write-Warning "missing $n in $src" }
}

$size = [math]::Round((Get-ChildItem -Recurse $pkg | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host ('package ready: ' + $pkg + ' (' + $size + ' MB)')
Write-Host ('  wgime-py.py: ' + (Get-Item (Join-Path $pkg 'wgime-py.py')).Length + ' bytes')
