# Single-file wgime-py.py acceptance: typing + plugin launchers
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
[System.Windows.Forms.SendKeys]::SendWait('{F8}')
Start-Sleep -Milliseconds 400
# typing
[System.Windows.Forms.SendKeys]::SendWait('nihao')
Start-Sleep -Milliseconds 500
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Milliseconds 500
# plugin: sk clock
[System.Windows.Forms.SendKeys]::SendWait('sk'); Start-Sleep -Milliseconds 400
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\single-sk-cand.png -Force
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Seconds 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\single-sk.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
