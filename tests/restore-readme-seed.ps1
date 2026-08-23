# Restore seedPluginReadme (plugins README.txt) - user wants it kept
$ErrorActionPreference = 'Stop'
$batPath = 'C:\Tools\WgIme\wgime.bat'
$readme = [IO.File]::ReadAllText('C:\Tools\WgIme\plugins\README.txt', [Text.Encoding]::UTF8)
$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

# 1) insert $seedPluginReadme here-string after seedTools closing '@
$si = $bat.IndexOf("$seedTools = @'")
$si = $bat.IndexOf("`$seedTools = @'")
if ($si -lt 0) { throw 'seedTools not found' }
$ei = $bat.IndexOf("`n'@", $si)
if ($ei -lt 0) { throw 'seedTools close not found' }
$insertAt = $ei + 4   # after "\n'@" + newline
$readmeLf = $readme -replace "`r`n", "`n"
$block = "`n`$seedPluginReadme = @'`n" + $readmeLf + "'@"
$bat = $bat.Insert($insertAt, $block)

# 2) insert the seeding line for plugins\README.txt (before the calc one)
$anchor = "        `$jf = Join-Path `$pdir 'calc.txt'"
$ai = $bat.IndexOf($anchor)
if ($ai -lt 0) { throw 'calc seed anchor not found' }
$seedLine = "        `$rf = Join-Path `$pdir 'README.txt'`n        if (-not (Test-Path `$rf)) { [IO.File]::WriteAllText(`$rf, `$seedPluginReadme, `$utf8n) }`n"
$bat = $bat.Insert($ai, $seedLine)

[IO.File]::WriteAllText($batPath, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "README seed restored"
