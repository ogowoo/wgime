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

# 2. refresh package (先清空再重建, 避免旧结构残留)
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force $pkg | Out-Null
New-Item -ItemType Directory -Force $dicts | Out-Null
Copy-Item (Join-Path $dist 'wgime-py.py') $pkg -Force
Copy-Item (Join-Path $here 'run-csharp-plugin.ps1') $pkg -Force   # [csharp] sidecar

# 3. refresh dicts (码表 + import 产物) from the repo root -> package\dicts\
$src = Split-Path $here -Parent
foreach ($n in @('py.txt', 'wb.txt', 'ec.txt', 'trad.txt', 'pywfreq.txt', 'import_py.txt', 'import_wb.txt', 'import_ec.txt')) {
    $p = Join-Path $src $n
    if (Test-Path $p) { Copy-Item $p $dicts -Force } else { Write-Warning "missing $n in $src" }
}
# 4. config/tools/plugins 平级 -> package 根 (与 dicts 平级, 不与码表混)
foreach ($n in @('config.txt', 'tools.txt')) {
    $p = Join-Path $src $n
    if (Test-Path $p) { Copy-Item $p $pkg -Force } else { Write-Warning "missing $n in $src" }
}
$pd = Join-Path $pkg 'plugins'
New-Item -ItemType Directory -Force $pd | Out-Null
Copy-Item (Join-Path $src 'plugins\*.txt') $pd -Force -ErrorAction SilentlyContinue

$size = [math]::Round((Get-ChildItem -Recurse $pkg | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Host ('package ready: ' + $pkg + ' (' + $size + ' MB)')
Write-Host ('  wgime-py.py: ' + (Get-Item (Join-Path $pkg 'wgime-py.py')).Length + ' bytes')
