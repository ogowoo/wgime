# caret-follow precise test: commit text to move caret, then type, screenshot bar position
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB8 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB8]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB8]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 3
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
ShiftTap; Start-Sleep -Milliseconds 400   # activate IME
# commit chinese to move caret right
[System.Windows.Forms.SendKeys]::SendWait('nihao'); Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait('zhongguo'); Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Milliseconds 400
# now caret is after 中国你好 (right side), type more -> bar should follow
[System.Windows.Forms.SendKeys]::SendWait('pc')
Start-Sleep -Milliseconds 500
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\caret-precise.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
