$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
[System.Windows.Forms.SendKeys]::SendWait('{F8}')
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait('zhongguo')
Start-Sleep -Milliseconds 600
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\pure-bar.png -Force
[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Milliseconds 800
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\pure-commit.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
