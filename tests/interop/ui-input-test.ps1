# UI input test: show the real chat window, focus nick/room/input and SendKeys,
# verify the text actually lands in the fields. Requires interactive desktop.
param(
    [string]$PluginPath = "$PSScriptRoot\..\..\plugins\chat.txt"
)
$ErrorActionPreference = 'Stop'
$t = [IO.File]::ReadAllText($PluginPath, [Text.Encoding]::UTF8)
$m = [regex]::Match($t, '(?s)\[csharp\]\s*(.*)')
$cs = $m.Groups[1].Value
$end = $cs.IndexOf('[/csharp]')
if ($end -gt 0) { $cs = $cs.Substring(0, $end) }
$driver = [IO.File]::ReadAllText("$PSScriptRoot\uishot.cs.txt", [Text.Encoding]::UTF8)
Add-Type -TypeDefinition ($cs + "`n" + $driver) -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Net

[ChatUiShot]::Show()
$deadline = (Get-Date).AddSeconds(15)
while (-not [ChatUiShot]::FormShown -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
if (-not [ChatUiShot]::FormShown) { Write-Host ("FAIL: form not shown. " + [ChatUiShot]::Err); exit 1 }
Start-Sleep -Milliseconds 800

$fail = 0
foreach ($tc in @(@('edNick', 'abc123'), @('edRoom', 'testroom42'), @('inputBox', 'hello'))) {
    $field = $tc[0]; $text = $tc[1]
    $got = [ChatUiShot]::TypeInto($field, $text)
    $ok = ($got -eq $text)
    if (-not $ok) { $fail++ }
    Write-Host ("{0}: typed '{1}' -> field contains '{2}' => {3}" -f $field, $text, $got, $(if ($ok) { 'OK' } else { 'FAIL' }))
}
[ChatUiShot]::Close()
Start-Sleep -Milliseconds 400
exit $fail
