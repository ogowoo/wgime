# Insert $seedChat here-string and seeding logic into wgime.bat
$ErrorActionPreference = 'Stop'
$batPath = 'C:\Tools\WgIme\wgime.bat'
$chat = [IO.File]::ReadAllText('C:\Tools\WgIme\plugins\chat.txt', [Text.Encoding]::UTF8)
$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

# chat.txt must not contain '@ at line start inside the C# (would break the here-string)
if ($chat -match "(?m)^'@") { throw "chat.txt contains a line starting with '@ - would break the here-string" }

# 1) build the $seedChat here-string (normalize to LF; here-strings don't care)
$chatLf = $chat -replace "`r`n", "`n"
$seedBlock = "`$seedChat = @'`n" + $chatLf + "'@"

# 2) insert right after the $seedCalc closing '@
$calcIdx = $bat.IndexOf('$seedCalc')
if ($calcIdx -lt 0) { throw 'seedCalc not found' }
$calcEnd = $bat.IndexOf("'@", $calcIdx)   # the closing '@ line of $seedCalc
if ($calcEnd -lt 0) { throw 'seedCalc close not found' }
$calcEndLine = $bat.IndexOf("`n", $calcEnd) + 1
$bat = $bat.Substring(0, $calcEndLine) + $seedBlock + "`n" + $bat.Substring($calcEndLine)

# 3) add seeding call after calc.txt seeding
$anchor = 'if (-not (Test-Path $jf)) { [IO.File]::WriteAllText($jf, $seedCalc, $utf8n) }'
$ai = $bat.IndexOf($anchor)
if ($ai -lt 0) { throw 'seed anchor not found' }
$aiEnd = $ai + $anchor.Length
$seedLine = "`n        `$cf2 = Join-Path `$pdir 'chat.txt'" +
            "`n        if (-not (Test-Path `$cf2)) { [IO.File]::WriteAllText(`$cf2, `$seedChat, `$utf8n) }"
$bat = $bat.Substring(0, $aiEnd) + $seedLine + $bat.Substring($aiEnd)

[IO.File]::WriteAllText($batPath, $bat, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "seedChat inserted OK"
