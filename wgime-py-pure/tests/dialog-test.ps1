# makeword dialog + caret-follow test
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB7 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB7]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB7]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
function ComboCtrlAltC {
    [SB7]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
    [SB7]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
    [SB7]::keybd_event(0x43, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [SB7]::keybd_event(0x43, 0, 2, [IntPtr]::Zero)
    [SB7]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    [SB7]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
# caret-follow: type to right side of notepad
[System.Windows.Forms.SendKeys]::SendWait('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')
Start-Sleep -Milliseconds 400
ShiftTap; Start-Sleep -Milliseconds 400
[System.Windows.Forms.SendKeys]::SendWait('zhong')
Start-Sleep -Milliseconds 500
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\caret-follow.png -Force
[System.Windows.Forms.SendKeys]::SendWait('{ESC}'); Start-Sleep -Milliseconds 300
# makeword dialog: set clipboard via python then Ctrl+Alt+C
C:\Tools\py38\python.exe -c "import subprocess; subprocess.run(['powershell.exe','-NoProfile','-Command','Set-Clipboard -Value ([char]0x795e + [char]0x7ecf + [char]0x7f51 + [char]0x7edc)'])"
Start-Sleep -Milliseconds 300
ComboCtrlAltC
Start-Sleep -Seconds 2
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\makeword-dialog.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
