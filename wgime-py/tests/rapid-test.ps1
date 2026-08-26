# Rapid repeated commits: ni+space x6 -> expect 6x 你 (first candidate of ni)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
[System.Windows.Forms.SendKeys]::SendWait('{F8}')   # fresh instance starts OFF
Start-Sleep -Milliseconds 400
1..6 | ForEach-Object {
    [System.Windows.Forms.SendKeys]::SendWait('ni')
    Start-Sleep -Milliseconds 150
    [System.Windows.Forms.SendKeys]::SendWait(' ')
    Start-Sleep -Milliseconds 250
}
Start-Sleep -Seconds 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\rapid.png -Force
Stop-Process -Id $np.Id -Force
Get-Content "$env:LOCALAPPDATA\wgime-py\debug.log" -Tail 8
