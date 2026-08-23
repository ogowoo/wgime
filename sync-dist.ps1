# sync-dist.ps1 - one-shot sync of config / plugins / dicts / docs from root
# to the two distribution folders (wg-all = ps1-only pack, release = full pack).
#
# What it copies (root -> target):
#   config.txt, tools.txt        -> wg-all\ + release\
#   plugins\*.txt                -> wg-all\plugins\ + release\plugins\
#   py/wb/ec/import_py/import_wb -> release\        (dict txt, offline distribution)
#   docs\WGIME_*.md              -> release\docs\   (user docs; NOT AGENTS/CHANGELOG)
#   wgime.bat                    -> release\
#
# NOT copied (build scripts handle these): WgIme.ps1 / WgTray.ps1 / wgtray.bat / DLL payloads.
# NOT copied (hand-maintained per folder): install.bat, README.txt.
#
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File sync-dist.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Copy-To([string]$src, [string]$dst) {
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    Copy-Item $src $dst -Force
    Write-Host ("  {0} -> {1}" -f $src.Substring($root.Length + 1), $dst.Substring($root.Length + 1))
}

# 1) config + tools -> both folders
foreach ($f in @('config.txt', 'tools.txt')) {
    $src = Join-Path $root $f
    if (Test-Path $src) {
        Copy-To $src (Join-Path $root "wg-all\$f")
        Copy-To $src (Join-Path $root "release\$f")
    }
}

# 2) plugins -> both folders
$pdir = Join-Path $root 'plugins'
if (Test-Path $pdir) {
    Get-ChildItem $pdir -File -Filter *.txt | ForEach-Object {
        Copy-To $_.FullName (Join-Path $root "wg-all\plugins\$($_.Name)")
        Copy-To $_.FullName (Join-Path $root "release\plugins\$($_.Name)")
    }
}

# 3) dict txt -> release only
foreach ($f in @('py.txt', 'wb.txt', 'ec.txt', 'import_py.txt', 'import_wb.txt')) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-To $src (Join-Path $root "release\$f") }
}

# 4) user docs (WGIME_*.md, skip AGENTS.md / CHANGELOG.md) -> release\docs only
$ddir = Join-Path $root 'docs'
if (Test-Path $ddir) {
    Get-ChildItem $ddir -File -Filter 'WGIME_*.md' | ForEach-Object {
        Copy-To $_.FullName (Join-Path $root "release\docs\$($_.Name)")
    }
}

# 5) wgime.bat -> release
$bat = Join-Path $root 'wgime.bat'
if (Test-Path $bat) { Copy-To $bat (Join-Path $root 'release\wgime.bat') }

Write-Host 'sync-dist done.'
