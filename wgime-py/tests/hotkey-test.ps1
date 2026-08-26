# Live Ctrl+Alt+C makeword test (ASCII only; clipboard set via python)
C:\Tools\py38\python.exe -c "import subprocess; subprocess.run(['powershell.exe','-NoProfile','-Command','Set-Clipboard -Value ([char]0x795e + [char]0x7ecf + [char]0x7f51 + [char]0x7edc)'], check=True)"
Add-Type @"
using System; using System.Runtime.InteropServices;
public class KK { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
Start-Sleep -Milliseconds 300
[KK]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
[KK]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
[KK]::keybd_event(0x43, 0, 0, [IntPtr]::Zero)
Start-Sleep -Milliseconds 100
[KK]::keybd_event(0x43, 0, 2, [IntPtr]::Zero)
[KK]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
[KK]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
Start-Sleep -Seconds 1
Write-Host 'hotkey sent'
