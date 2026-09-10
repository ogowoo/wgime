# build-release-assets.ps1 -- build the three release zips (bat / ps1 / python) for a version.
#
# ASCII only (PS 5.1 reads scripts as ANSI; non-ASCII lives in the .md sources).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\build-release-assets.ps1 -Version 1.2.7
#
# Layout follows the published v1.2.6 assets:
#   bat zip    : release\wgime.bat   + config.txt + tools.txt + README.txt + plugins\*.txt
#   ps1 zip    : release\WgIme.ps1   + the same companions
#   python zip : wgime-py-pure\package\** (wgime-py.py + dicts\ + plugins\ + config/tools/README)
# Entries are relative to the staged folder (no bat/ or ps1/ prefix).
#
# NOTE: every path here is built from $repo (a long path). Never build the zip from a
# Resolve-Path / %TEMP% source: 8.3 short paths (ADMINI~1) leak into entry names.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir,
    [switch]$SkipPython,
    [switch]$OnlyPython
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
if (-not $OutDir) { $OutDir = Join-Path $repo ('.release-stage-v' + ($Version -replace '\.', '')) }
$rel = Join-Path $repo 'release'
$pkg = Join-Path $repo 'wgime-py-pure\package'

New-Item -ItemType Directory -Force $OutDir | Out-Null

function New-Zip([string]$srcDir, [string]$zipPath) {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    # .NET Framework's ZipFile.CreateFromDirectory writes '\' separators on Windows, so
    # entries are added one by one with '/' (matches the published assets and every
    # unzip tool). $srcFull must be a long path -- a short 8.3 root would leak
    # ADMINI~1 into entry names.
    $srcFull = (Get-Item -LiteralPath $srcDir).FullName
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')   # 'Create' string: ZipArchiveMode lives in another assembly
    try {
        Get-ChildItem -LiteralPath $srcFull -Recurse -File | Sort-Object FullName | ForEach-Object {
            $rel = $_.FullName.Substring($srcFull.Length + 1).Replace('\', '/')
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $_.FullName, $rel, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally { $zip.Dispose() }
    $z = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $bad = @($z.Entries | Where-Object { $_.FullName -like '*\*' })
    $n = $z.Entries.Count
    $z.Dispose()
    if ($bad.Count -gt 0) { throw "zip $zipPath has backslash entries: $($bad[0].FullName)" }
    "  built $zipPath ($n entries, $([math]::Round((Get-Item $zipPath).Length / 1MB, 2)) MB)"
}

# 1) bat / ps1: main file + shared companions from release\
foreach ($kind in @('bat', 'ps1')) {
    if ($OnlyPython) { break }
    $main = if ($kind -eq 'bat') { 'wgime.bat' } else { 'WgIme.ps1' }
    if (-not (Test-Path (Join-Path $rel $main))) { throw "missing release\$main" }
    $src = Join-Path $OutDir $kind
    if (Test-Path $src) { Remove-Item $src -Recurse -Force }
    New-Item -ItemType Directory -Force $src | Out-Null
    foreach ($n in @('config.txt', 'tools.txt', 'README.txt')) {
        Copy-Item (Join-Path $rel $n) $src -Force
    }
    Copy-Item (Join-Path $rel 'plugins') (Join-Path $src 'plugins') -Recurse -Force
    Copy-Item (Join-Path $rel $main) $src -Force
    New-Zip $src (Join-Path $OutDir "wgime-v$Version-$kind.zip")
}

# 2) python: the ready-to-copy package folder, verbatim
if (-not $SkipPython) {
    if (-not (Test-Path (Join-Path $pkg 'wgime-py.py'))) {
        throw "missing wgime-py-pure\package\wgime-py.py - run build-package.ps1 first"
    }
    # Guard: package\ is a build output refreshed by build-package.ps1. Shipping a stale
    # one silently publishes the previous build (happened once), so refuse unless it is
    # byte-identical to the current dist\ build.
    $distFile = Join-Path $repo 'wgime-py-pure\dist\wgime-py.py'
    $pkgFile = Join-Path $pkg 'wgime-py.py'
    if (Test-Path $distFile) {
        $h1 = (Get-FileHash $distFile -Algorithm SHA256).Hash
        $h2 = (Get-FileHash $pkgFile -Algorithm SHA256).Hash
        if ($h1 -ne $h2) {
            throw "package\wgime-py.py is stale (differs from dist\wgime-py.py) - run wgime-py-pure\build-package.ps1 first"
        }
    }
    New-Zip $pkg (Join-Path $OutDir "wgime-v$Version-python.zip")
}

"assets ready in $OutDir"
Get-ChildItem $OutDir -Filter '*.zip' | ForEach-Object { "  $($_.Name)  $([math]::Round($_.Length / 1MB, 2)) MB" }
