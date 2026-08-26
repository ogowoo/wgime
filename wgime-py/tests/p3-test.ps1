# Plugin launch test: lt -> ▶聊天 candidate -> pick -> chat window opens
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
[System.Windows.Forms.SendKeys]::SendWait('{F8}')
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait('lt')
Start-Sleep -Milliseconds 600
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\p3-plugin-cand.png -Force
[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Seconds 4
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\p3-plugin-open.png -Force
Stop-Process -Id $np.Id -Force
Write-Host 'done'
