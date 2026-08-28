$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB5 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB5]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB5]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
ShiftTap; Start-Sleep -Milliseconds 400
# vest should show candidates (bar stays)
foreach ($ch in @('v','e','s','t')) { [System.Windows.Forms.SendKeys]::SendWait($ch); Start-Sleep -Milliseconds 250 }
Start-Sleep -Milliseconds 400
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\vest-fixed.png -Force
[System.Windows.Forms.SendKeys]::SendWait('{ESC}'); Start-Sleep -Milliseconds 300
# commit a word -> assoc shows -> backspace should delete + clear assoc
[System.Windows.Forms.SendKeys]::SendWait('nihao'); Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Milliseconds 400   # commit, assoc shows
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')                        # assoc backspace
Start-Sleep -Milliseconds 400
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\assoc-backspace.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
