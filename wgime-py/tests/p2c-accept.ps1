# Paste-mode + keyfix acceptance: pin notepad to clipboard mode, commit, check clipboard restored
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class KK { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap() {
    [Kbd]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Kbd]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}

# preserve current clipboard for verification
$origClip = [System.Windows.Forms.Clipboard]::GetText()
Write-Host "orig clip: [$origClip]"

# pin notepad to clipboard mode via pastemode.txt (app reads at startup; write then it's picked on load)
$pm = "$env:LOCALAPPDATA\wgime-py\pastemode.txt"
Set-Content $pm 'notepad=clipboard' -Encoding ASCII

# restart app so it loads the pin
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'wgime\.py' } | ForEach-Object { Stop-Process $_.ProcessId -Force }
Start-Sleep -Seconds 1
$dbg = "$env:LOCALAPPDATA\wgime-py\debug.log"
Remove-Item $dbg -ErrorAction SilentlyContinue
$app = Start-Process C:\Tools\py38\python.exe -ArgumentList 'C:\Tools\wgime-py\wgime.py' -WindowStyle Hidden -PassThru
$w = 0
while ($w -lt 30) { if ((Test-Path $dbg) -and ((Get-Content $dbg -Raw -ErrorAction SilentlyContinue) -match 'started')) { break }; Start-Sleep 1; $w++ }
Write-Host "app ready after ${w}s"

$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
[System.Windows.Forms.SendKeys]::SendWait('{F8}')
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait('nihao')
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Milliseconds 800
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\p2c-paste.png -Force
Start-Sleep -Milliseconds 800   # wait for restore (300ms timer)
$newClip = [System.Windows.Forms.Clipboard]::GetText()
Write-Host "after clip: [$newClip]"
Write-Host ("restore ok: " + ($newClip -eq $origClip))
Stop-Process -Id $np.Id -Force
