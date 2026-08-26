# Phase-2b acceptance: vf panel / clipboard makeword / auto makeword
# Assumes fresh app (active off, mode 0, trad off), config starton=0.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
function Snap($name) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1 | Out-Null
    Move-Item C:\Tools\wgime-py\inject-after.png "C:\Tools\wgime-py\$name" -Force
}
function K($s) { [System.Windows.Forms.SendKeys]::SendWait($s) }
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Kbd2 { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function Combo($vk) {   # Ctrl+Alt+vk down/up
    [Kbd2]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)
    [Kbd2]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
    [Kbd2]::keybd_event($vk, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [Kbd2]::keybd_event($vk, 0, 2, [IntPtr]::Zero)
    [Kbd2]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    [Kbd2]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)
}

$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1

K('{F8}')   # ime on
Start-Sleep -Milliseconds 400

# S1: vf panel
K('vf'); Start-Sleep -Milliseconds 500; Snap 'p2b-vf-root.png'
K('2'); Start-Sleep -Milliseconds 500; Snap 'p2b-vf-cat2.png'
K('1'); Start-Sleep -Milliseconds 500   # pick first punct symbol
Snap 'p2b-vf-picked.png'

# S2: clipboard makeword (Ctrl+Alt+C)
powershell.exe -NoProfile -Command "Set-Clipboard -Value '深度学习框架'"
Start-Sleep -Milliseconds 300
Combo 0x43
Start-Sleep -Milliseconds 800
Snap 'p2b-makeword.png'

# S3: use the new word via pinyin
K('shendukuangjia'); Start-Sleep -Milliseconds 500; Snap 'p2b-newword.png'
K(' '); Start-Sleep -Milliseconds 500

# S4: auto makeword from consecutive single-char commits: 神 经 网 络
foreach ($c in @('shen', 'jing', 'wang', 'luo')) {
    K($c); Start-Sleep -Milliseconds 250
    K(' '); Start-Sleep -Milliseconds 350
}
Start-Sleep -Milliseconds 600
Snap 'p2b-auto.png'

Stop-Process -Id $np.Id -Force
Write-Host 'done'
