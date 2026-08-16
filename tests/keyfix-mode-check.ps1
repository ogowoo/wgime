# ============================================================
#  keyfix-mode-check.ps1  -  verify keyfix routing in the rebuilt
#  WgIme DLL (whitelist-free design):
#    - StaleTrigger predicate coverage
#    - EffectiveMode: no built-in per-app pins anymore (weixin -> 3)
#    - EffectiveKeyfix: global Keyfix=1 -> true everywhere; keyplain pin
#      forces off; keyfix pin forces on even with global Keyfix=0
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\keyfix-mode-check.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'
$pasteMode = $wbType.GetField('PasteMode', $fl)
$keyfixF   = $wbType.GetField('Keyfix', $fl)
$appModes  = $wbType.GetField('AppModes', $fl)
$em        = $wbType.GetMethod('EffectiveMode', $fl)
$ek        = $wbType.GetMethod('EffectiveKeyfix', $fl)
$st        = $wbType.GetMethod('StaleTrigger', $fl)
foreach ($x in @($pasteMode, $keyfixF, $appModes, $em, $ek, $st)) { if ($x -eq $null) { throw "missing member in rebuilt DLL" } }

$pasteMode.SetValue($null, 3)        # global paste = key
$appModes.SetValue($null, (New-Object 'System.Collections.Generic.Dictionary[string,int]'))

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected $expected, got $actual)"; $script:fail++ }
}

# --- StaleTrigger predicate coverage ---
Check "StaleTrigger U+FF0C comma"  ($st.Invoke($null, @([char]0xFF0C))) "True"
Check "StaleTrigger U+3002 juhao"  ($st.Invoke($null, @([char]0x3002))) "True"
Check "StaleTrigger U+3001 dcomma" ($st.Invoke($null, @([char]0x3001))) "True"
Check "StaleTrigger U+FF1F qmark"  ($st.Invoke($null, @([char]0xFF1F))) "True"
Check "StaleTrigger U+3010 bracket"($st.Invoke($null, @([char]0x3010))) "True"
Check "StaleTrigger U+4F60 ni"     ($st.Invoke($null, @([char]0x4F60))) "False"
Check "StaleTrigger U+7684 de"     ($st.Invoke($null, @([char]0x7684))) "False"
Check "StaleTrigger U+201C quote"  ($st.Invoke($null, @([char]0x201C))) "False"
Check "StaleTrigger U+00A5 yen"    ($st.Invoke($null, @([char]0x00A5))) "False"
Check "StaleTrigger ascii X"       ($st.Invoke($null, @([char]'X')))    "False"

# --- routing: whitelist-free global default ---
$keyfixF.SetValue($null, $true)
Check "EffectiveMode weixin stays key(3), no built-in pin" ($em.Invoke($null, @())) "3"   # foreground is whatever it is; mode must be 3
Check "EffectiveKeyfix global on -> True"                  ($ek.Invoke($null, @())) "True"

$d = $appModes.GetValue($null)
$fgProc = "<none>"
try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $fg = (New-Object -TypeName System.Windows.Forms.Form)   # dummy; foreground query below uses WgIme's own code
    $fg.Dispose()
} catch {}
# use WgIme's ForegroundProcessName to find the current app and pin it
$fpn = $wbType.GetMethod('ForegroundProcessName', $fl)
$fgProc = $fpn.Invoke($null, @())
Write-Output "foreground process: $fgProc"

$d[$fgProc] = 5
Check "EffectiveKeyfix keyplain pin -> False"              ($ek.Invoke($null, @())) "False"
$d[$fgProc] = 4
Check "EffectiveKeyfix keyfix pin -> True"                 ($ek.Invoke($null, @())) "True"
$d.Remove($fgProc) | Out-Null
$keyfixF.SetValue($null, $false)
Check "EffectiveKeyfix global off -> False"                ($ek.Invoke($null, @())) "False"
$d[$fgProc] = 4
Check "EffectiveKeyfix keyfix pin beats global off -> True" ($ek.Invoke($null, @())) "True"
$d.Remove($fgProc) | Out-Null

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
