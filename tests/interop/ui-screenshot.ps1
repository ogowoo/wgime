# UI screenshot verification: shows the real chat window (no join), captures it with
# CopyFromScreen, saves PNG + pixel-checks rounded corners. Requires interactive desktop.
param(
    [string]$PluginPath = "$PSScriptRoot\..\..\plugins\chat.txt",
    [string]$Out = "$PSScriptRoot\uishot.png",
    [switch]$Demo
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

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
if ($Demo) { [ChatUiShot]::InjectDemo(); if ([ChatUiShot]::Err) { Write-Host ("DEMO-ERR: " + [ChatUiShot]::Err) } }
Start-Sleep -Milliseconds 1500   # let it fully paint

$x = [ChatUiShot]::FormX; $y = [ChatUiShot]::FormY; $w = [ChatUiShot]::FormW; $h = [ChatUiShot]::FormH
Write-Host "form at $x,$y ${w}x${h}"
$bmp = New-Object System.Drawing.Bitmap($w, $h)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)

# pixel checks: corners must NOT be C_BG (#E8EDF5) if the rounded region is applied;
# header center must be C_HEADER; message area must be white card.
$cbg = [System.Drawing.Color]::FromArgb(255, 232, 237, 245)
$chdr = [System.Drawing.Color]::FromArgb(255, 220, 227, 239)
function Eq($a, $b) { return ($a.R -eq $b.R -and $a.G -eq $b.G -and $a.B -eq $b.B) }
$tl = $bmp.GetPixel(1, 1); $tr = $bmp.GetPixel($w - 2, 1); $bl = $bmp.GetPixel(1, $h - 2); $br = $bmp.GetPixel($w - 2, $h - 2)
$hdr = $bmp.GetPixel([int]($w / 2), 19)
$card = $bmp.GetPixel(180, 300)
$canvas = [System.Drawing.Color]::FromArgb(255, 244, 247, 251)
Write-Host ("corner TL=" + $tl.ToArgb() + " TR=" + $tr.ToArgb() + " BL=" + $bl.ToArgb() + " BR=" + $br.ToArgb())
$roundOk = (-not (Eq $tl $cbg)) -and (-not (Eq $tr $cbg)) -and (-not (Eq $bl $cbg)) -and (-not (Eq $br $cbg))
Write-Host ("rounded corners: " + $(if ($roundOk) { 'OK' } else { 'FAIL (corners still bg-colored)' }))
Write-Host ("header color: " + $(if (Eq $hdr $chdr) { 'OK' } else { 'FAIL ' + $hdr.ToArgb() }))
Write-Host ("canvas color: " + $(if ((Eq $card $canvas)) { 'OK' } else { 'FAIL ' + $card.ToArgb() }))
[ChatUiShot]::Close()
Start-Sleep -Milliseconds 500
$bmp.Dispose()
Write-Host ("screenshot: " + $Out)
