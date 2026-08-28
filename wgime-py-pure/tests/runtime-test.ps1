# Active+empty-buffer control keys pass through; composing swallows; Shift+Enter passes
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public class SB2 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap {
    [SB2]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [SB2]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}
$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1
# activate
ShiftTap; Start-Sleep -Milliseconds 400
# ACTIVE, empty buffer: type 'a' then backspace (buffered swallow), then space (empty -> passthrough)
[System.Windows.Forms.SendKeys]::SendWait('a')      # buffer 'a'
Start-Sleep -Milliseconds 250
[System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}')  # clears buffer
Start-Sleep -Milliseconds 250
# now empty buffer: space should pass through (insert space)
[System.Windows.Forms.SendKeys]::SendWait(' ')      # passthrough
Start-Sleep -Milliseconds 250
[System.Windows.Forms.SendKeys]::SendWait('xyz')    # passthrough (empty buffer, but letters compose! -> buffer 'xyz')
Start-Sleep -Milliseconds 250
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')  # cancel buffer
Start-Sleep -Milliseconds 250
# Shift+Enter (shift held) -> passthrough newline
[SB2]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
[SB2]::keybd_event(0x0D, 0, 0, [IntPtr]::Zero)
[SB2]::keybd_event(0x0D, 0, 2, [IntPtr]::Zero)
[SB2]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
Start-Sleep -Milliseconds 400
# compose: nihao + space -> 你好
[System.Windows.Forms.SendKeys]::SendWait('nihao'); Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait(' '); Start-Sleep -Milliseconds 400
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1
Move-Item C:\Tools\wgime-py\inject-after.png C:\Tools\wgime-py\runtime-keys.png -Force
Stop-Process -Id $np.Id -Force
Write-Host done
