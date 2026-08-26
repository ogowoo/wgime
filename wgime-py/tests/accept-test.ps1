# Phase-1 full acceptance: one deterministic sequence in one notepad.
# Initial state: fresh app (active=False, mode=0 mix, trad=False)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
$log = 'C:\Tools\wgime-py\accept.log'
Remove-Item $log -ErrorAction SilentlyContinue
function Step($m) { "$(Get-Date -Format 'HH:mm:ss.fff') $m" | Out-File $log -Append }
function Snap($name) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1 | Out-Null
    Move-Item C:\Tools\wgime-py\inject-after.png "C:\Tools\wgime-py\$name" -Force
}
function K($s) { [System.Windows.Forms.SendKeys]::SendWait($s) }

Add-Type @"
using System; using System.Runtime.InteropServices;
public class Kbd { [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra); }
"@
function ShiftTap() {
    [Kbd]::keybd_event(0xA0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [Kbd]::keybd_event(0xA0, 0, 2, [IntPtr]::Zero)
}

$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
# 等应用就绪 (debug.log 出现 started 标记)
$dbg = "$env:LOCALAPPDATA\wgime-py\debug.log"
$waited = 0
while ($waited -lt 30) {
    if ((Test-Path $dbg) -and ((Get-Content $dbg -Raw) -match 'started')) { break }
    Start-Sleep -Seconds 1; $waited++
}
Step "app ready after ${waited}s"
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1

K('{F8}'); Step 'ime on'
Start-Sleep -Milliseconds 300

# S1: pinyin mix mode
K('zhongguo'); Start-Sleep -Milliseconds 400; Snap 's1-bar.png'
K(' '); Start-Sleep -Milliseconds 400; Step 's1 committed'

# S2: mode -> 拼音, nihao
K('^`'); Start-Sleep -Milliseconds 250
K('nihao'); Start-Sleep -Milliseconds 400; Snap 's2-bar.png'
K(' '); Start-Sleep -Milliseconds 400; Step 's2 committed (expect nihao word)'

# S3: mode -> 五笔, wqvb auto-commit
K('^`'); Start-Sleep -Milliseconds 250
K('wqvb'); Start-Sleep -Milliseconds 600; Snap 's3-wubi.png'; Step 's3 auto-commit (expect 你好)'

# S4: mode -> 词典, apple
K('^`'); Start-Sleep -Milliseconds 250
K('apple'); Start-Sleep -Milliseconds 400; Snap 's4-bar.png'
K(' '); Start-Sleep -Milliseconds 400; Step 's4 committed (expect 苹果)'

# S5: mode -> 混合, trad on, zhongguo -> 中國
K('^`'); Start-Sleep -Milliseconds 250
K('^+f'); Start-Sleep -Milliseconds 250
K('zhongguo'); Start-Sleep -Milliseconds 400
K(' '); Start-Sleep -Milliseconds 400; Snap 's5-trad.png'; Step 's5 committed (expect 中國)'
K('^+f'); Step 'trad off'

# S6: shift tap -> off, raw typing, shift tap -> on
ShiftTap
Start-Sleep -Milliseconds 400
K('abc'); Start-Sleep -Milliseconds 400; Step 's6 raw abc typed (expect literal abc)'
ShiftTap
Start-Sleep -Milliseconds 400
Snap 's6-final.png'
Step 'done'
Stop-Process -Id $np.Id -Force
Get-Content $log
