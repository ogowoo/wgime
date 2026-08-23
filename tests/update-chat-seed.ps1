# Replace the $seedChat here-string content in wgime.bat with plugins\chat.txt
$ErrorActionPreference = 'Stop'
$batPath = 'C:\Tools\WgIme\wgime.bat'
$chat = [IO.File]::ReadAllText('C:\Tools\WgIme\plugins\chat.txt', [Text.Encoding]::UTF8)
$bat = [IO.File]::ReadAllText($batPath, [Text.Encoding]::UTF8)

if ($chat -match "(?m)^'@") { throw "chat.txt contains a line starting with '@ - would break the here-string" }

$si = $bat.IndexOf('$seedChat')
if ($si -lt 0) { throw 'seedChat not found' }
# the here-string: $seedChat = @'<newline>...<newline>'@
$openIdx = $bat.IndexOf("@'", $si) + 2              # after "@'"
$openNl = $bat.IndexOf("`n", $openIdx) + 1          # content starts after the newline
$closeIdx = $bat.IndexOf("`n'@", $openNl)           # closing "'@" at line start
if ($closeIdx -lt 0) { throw 'seedChat close not found' }

$chatLf = $chat -replace "`r`n", "`n"
$bat2 = $bat.Substring(0, $openNl) + $chatLf + $bat.Substring($closeIdx)
[IO.File]::WriteAllText($batPath, $bat2, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "seedChat content replaced OK"
