# Phase-2 acceptance: sentence / dynamic rq / v-mode amount / assoc chain.
# Assumes: fresh app state (active off, mode=0 mix, trad off). App must be RUNNING and ready.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
$log = 'C:\Tools\wgime-py\p2-accept.log'
Remove-Item $log -ErrorAction SilentlyContinue
function Step($m) { "$(Get-Date -Format 'HH:mm:ss.fff') $m" | Out-File $log -Append }
function Snap($name) {
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Tools\wgime-py\snap.ps1 | Out-Null
    Move-Item C:\Tools\wgime-py\inject-after.png "C:\Tools\wgime-py\$name" -Force
}
function K($s) { [System.Windows.Forms.SendKeys]::SendWait($s) }

$np = Start-Process notepad -PassThru
Start-Sleep -Seconds 2
$null = (New-Object -ComObject WScript.Shell).AppActivate($np.Id)
Start-Sleep -Seconds 1

K('{F8}'); Step 'ime on'
Start-Sleep -Milliseconds 400

# S1: sentence lattice (long pinyin string)
K('zhonghuarenmingongheguo'); Start-Sleep -Milliseconds 500; Snap 'p2-s1-sentence.png'
K('{ESC}'); Start-Sleep -Milliseconds 300; Step 's1 done'

# S2: rq dynamic date
K('rq'); Start-Sleep -Milliseconds 400; Snap 'p2-s2-rq.png'
K('{ESC}'); Start-Sleep -Milliseconds 300

# S3: v-mode amount (v2024)
K('v2024'); Start-Sleep -Milliseconds 400; Snap 'p2-s3-vmode.png'
K(' '); Start-Sleep -Milliseconds 500; Step 's3 committed v2024'

# S4: assoc chain: zhongguo -> meiguo, then zhongguo again -> assoc row
K('zhongguo'); Start-Sleep -Milliseconds 300; K(' '); Start-Sleep -Milliseconds 400
K('meiguo'); Start-Sleep -Milliseconds 300; K(' '); Start-Sleep -Milliseconds 400
K('{ESC}'); Start-Sleep -Milliseconds 200
K('zhongguo'); Start-Sleep -Milliseconds 300; K(' '); Start-Sleep -Milliseconds 600
Snap 'p2-s4-assoc.png'; Step 's4 assoc row shown'
K('1'); Start-Sleep -Milliseconds 500; Step 's4 picked assoc 1'
Snap 'p2-s5-final.png'
Stop-Process -Id $np.Id -Force
Get-Content $log
