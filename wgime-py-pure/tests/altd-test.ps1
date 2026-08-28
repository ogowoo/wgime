# Alt+D / Ctrl+L passthrough test
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB9 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB9]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB9]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
function AltKey($vk) {
    [SB9]::keybd_event(0xA4, 0, 0, [IntPtr]::Zero)   # VK_LMENU
    Start-Sleep -Milliseconds 50
    [SB9]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 50
    [SB9]::keybd_event($vk, 0, 2, [IntPtr]::Zero)
    [SB9]::keybd_event(0xA4, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
ShiftTap; Start-Sleep -Milliseconds 400
AltKey 0x44   # Alt+D
Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait('hi')   # verify IME still composes
Start-Sleep -Milliseconds 400
Stop-Process -Id $np.Id -Force
Write-Host done
