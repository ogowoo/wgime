# Shift-wake test
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
# inactive: type abc (should pass through)
[System.Windows.Forms.SendKeys]::SendWait('abc')
Start-Sleep -Milliseconds 400
# inactive: lone shift tap -> wake
ShiftTap
Start-Sleep -Milliseconds 500
# active: type nihao
[System.Windows.Forms.SendKeys]::SendWait('nihao')
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Milliseconds 400
# active: lone shift tap -> sleep
ShiftTap
Start-Sleep -Milliseconds 500
# inactive: type xyz (should pass through)
[System.Windows.Forms.SendKeys]::SendWait('xyz')
Start-Sleep -Milliseconds 400
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\shift-final.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
