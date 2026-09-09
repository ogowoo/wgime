# sync-dist.ps1 - one-shot sync of config / plugins / dicts / docs from root
# to the single distribution folder (release = full pack).
#
# What it copies (root -> release):
#   config.txt, tools.txt
#   plugins\*.txt                    -> release\plugins\
#   py/wb/ec/import_py/import_wb      (dict txt, offline distribution)
#   docs\WGIME_*.md                  -> release\docs\   (user docs; NOT AGENTS/CHANGELOG)
#   wgime.bat
#
# NOT copied (build scripts handle these): WgIme.ps1 / DLL payloads.
# NOT copied (hand-maintained): README.txt.
#
# Usage: powershell.exe -NoProfile -ExecutionPolicy Bypass -File sync-dist.ps1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$rel = Join-Path $root 'release'

function Copy-To([string]$src, [string]$dst) {
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    Copy-Item $src $dst -Force
    Write-Host ("  {0} -> release\{1}" -f $src.Substring($root.Length + 1), $dst.Substring($rel.Length + 1))
}

# 1) config + tools
foreach ($f in @('config.txt', 'tools.txt')) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-To $src (Join-Path $rel $f) }
}

# 2) plugins
$pdir = Join-Path $root 'plugins'
if (Test-Path $pdir) {
    Get-ChildItem $pdir -File -Filter *.txt | ForEach-Object {
        Copy-To $_.FullName (Join-Path $rel "plugins\$($_.Name)")
    }
}

# 3) dict txt
foreach ($f in @('py.txt', 'wb.txt', 'ec.txt', 'import_py.txt', 'import_wb.txt')) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-To $src (Join-Path $rel $f) }
}

# 4) user docs (WGIME_*.md, skip AGENTS.md / CHANGELOG.md)
$ddir = Join-Path $root 'docs'
if (Test-Path $ddir) {
    Get-ChildItem $ddir -File -Filter 'WGIME_*.md' | ForEach-Object {
        Copy-To $_.FullName (Join-Path $rel "docs\$($_.Name)")
    }
}

# 5) wgime.bat
$bat = Join-Path $root 'wgime.bat'
if (Test-Path $bat) { Copy-To $bat (Join-Path $rel 'wgime.bat') }

Write-Host 'sync-dist done.'
