# Replace the $seedClock here-string in wgime.bat with the current plugins\clock.txt
$ErrorActionPreference = 'Stop'
$bat = [IO.File]::ReadAllText('C:\Tools\WgIme\wgime.bat', [Text.Encoding]::UTF8)
$new = [IO.File]::ReadAllText('C:\Tools\WgIme\plugins\clock.txt', [Text.Encoding]::UTF8)

$startMark = '; ============================================================'
$anchor = 'code = sz'
$si = $bat.IndexOf($anchor)
if ($si -lt 0) { throw "anchor 'code = sz' not found" }
$hdr = $bat.LastIndexOf($startMark, $si)
if ($hdr -lt 0) { throw "block header not found" }
$endMark = $bat.IndexOf('[/csharp]', $si)
if ($endMark -lt 0) { throw "[/csharp] not found" }
$end = $bat.IndexOf([Environment]::NewLine, $endMark)
if ($end -lt 0) { $end = $endMark + 10 }
$end = $end + 1  # include the newline after [/csharp]

$old = $bat.Substring($hdr, $end - $hdr)
Write-Host ("old block len: {0}" -f $old.Length)
Write-Host ("old first: {0}" -f $old.Substring(0, 40))
Write-Host ("old has CRLF: {0}" -f $old.Contains("`r`n"))
Write-Host ("new has CRLF: {0}" -f $new.Contains("`r`n"))

# normalize new content to match the old block's line endings (CRLF if old is CRLF)
$newBody = $new
if ($old.Contains("`r`n")) { $newBody = $newBody -replace "`r`n", "`n" -replace "`n", "`r`n" }

$bat2 = $bat.Substring(0, $hdr) + $newBody + $bat.Substring($end)
[IO.File]::WriteAllText('C:\Tools\WgIme\wgime.bat', $bat2, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "replaced OK"
