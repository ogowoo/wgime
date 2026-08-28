# Ctrl/Alt/Win shortcuts pass through; >9 candidates show page indicator, no gray
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB3 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB3]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB3]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
function Key($vk, $ctrl, $shift, $alt, $win) {
    if ($ctrl) { [SB3]::keybd_event(0x11, 0, 0, [IntPtr]::Zero) }
    if ($alt) { [SB3]::keybd_event(0x12, 0, 0, [IntPtr]::Zero) }
    if ($shift) { [SB3]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero) }
    if ($win) { [SB3]::keybd_event(0x5B, 0, 0, [IntPtr]::Zero) }
    [SB3]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
    [SB3]::keybd_event($vk, 0, 2, [IntPtr]::Zero)
    if ($win) { [SB3]::keybd_event(0x5B, 0, 2, [IntPtr]::Zero) }
    if ($shift) { [SB3]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero) }
    if ($alt) { [SB3]::keybd_event(0x12, 0, 2, [IntPtr]::Zero) }
    if ($ctrl) { [SB3]::keybd_event(0x11, 0, 2, [IntPtr]::Zero) }
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
ShiftTap; Start-Sleep -Milliseconds 400
# type 'z' -> many candidates, page indicator
[System.Windows.Forms.SendKeys]::SendWait('z')
Start-Sleep -Milliseconds 500
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\many-cands.png -Force
# page next with '='
[System.Windows.Forms.SendKeys]::SendWait('=')
Start-Sleep -Milliseconds 400
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\many-cands-p2.png -Force
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Start-Sleep -Milliseconds 300
# Ctrl+S should pass through (notepad save dialog or no swallow)
Key 0x53 $true $false $false $false
Start-Sleep -Milliseconds 500
Stop-Process -Id $np.Id -Force
Write-Host done
