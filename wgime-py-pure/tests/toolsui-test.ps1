# Test the redesigned tool forms (clipboard history + toolbox)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SBT { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SBT]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SBT]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
ShiftTap; Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait('itools')
Start-Sleep -Milliseconds 500
[System.Windows.Forms.SendKeys]::SendWait(' ')
Start-Sleep -Seconds 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\toolbox-ui.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
