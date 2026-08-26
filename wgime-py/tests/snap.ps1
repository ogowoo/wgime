Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap(1200, 700)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen(0, 0, 0, 0, $bmp.Size)
$g.Dispose()
$bmp.Save('C:\Tools\wgime-py\inject-after.png')
$bmp.Dispose()
Write-Host 'saved'
