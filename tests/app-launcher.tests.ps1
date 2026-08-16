# ============================================================
#  app-launcher.tests.ps1  -  tests for the IME app launcher prototype:
#   1. CalcForm.Calc expression parser (reflection on the rebuilt DLL)
#   2. Apps registry: built-in jsq/calc + config.txt "app =" parsing
#   3. CalcForm renders (DrawToBitmap -> tests\calc-form.png)
#
#  Prereq: rebuild.ps1 has run (%TEMP%\wgime_new.dll is current).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\app-launcher.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl  = [Reflection.BindingFlags] 'Static, Public, NonPublic'
$fln = [Reflection.BindingFlags] 'Static, Public, NonPublic, FlattenHierarchy'

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected [$expected], got [$actual])"; $script:fail++ }
}

# ---- 1) expression parser ----
$calcType = $wbType.GetNestedType('CalcForm', 'NonPublic')
if ($calcType -eq $null) { throw "nested CalcForm not found" }
$calcM = $calcType.GetMethod('Calc', $fl)
function Calc([string]$s) { return $calcM.Invoke($null, @($s)) }

Check "1+2*3"      (Calc "1+2*3")     "7"
Check "(1+2)*3"    (Calc "(1+2)*3")   "9"
Check "10/4"       (Calc "10/4")      "2.5"
Check "-3+1"       (Calc "-3+1")      "-2"
Check "1.5+1.5"    (Calc "1.5+1.5")   "3"
Check "7%3"        (Calc "7%3")       "1"
Check "unclosed (" (Calc "(1+2")      "Err"
Check "1/0"        (Calc "1/0")       "Err"
Check "garbage"    (Calc "abc")       "Err"
Check "empty"      (Calc "")          ""

# fullwidth operators (typed with IME on): 2*(3+4) and 12/4
$fx = [string]([char]0xFF08) + "1+2" + [string]([char]0xFF09)       # fullwidth parens
$cx = "2" + [string]([char]0x00D7) + "3"                            # multiplication sign
$dx = "12" + [string]([char]0x00F7) + "4"                           # division sign
Check "fullwidth parens"  (Calc $fx)  "3"
Check "times sign 2x3"    (Calc $cx)  "6"
Check "divide sign 12/4"  (Calc $dx)  "3"

# ---- 2) Apps registry ----
$appsF = $wbType.GetField('Apps', $fl)
$loadConfig = $wbType.GetMethod('LoadConfig', $fl)
$tmp = Join-Path $env:TEMP ('wgime-app-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$cfgLines = @(
    'paste = key',
    ('app = np' + "`t" + [char]0x4E8B + [char]0x8BB0 + [char]0x672C + "`t" + 'notepad.exe'),   # ji-shi-ben
    ('app = bd' + "`t" + 'Search' + "`t" + 'https://www.baidu.com')
)
[IO.File]::WriteAllText((Join-Path $tmp 'config.txt'), ($cfgLines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
$loadConfig.Invoke($null, @([string]$tmp))
$apps = $appsF.GetValue($null)
Check "builtin jsq registered"  ($apps.ContainsKey('jsq') -and $apps['jsq'][1] -eq 'builtin:calc')  "True"
Check "builtin calc registered" ($apps.ContainsKey('calc'))                                        "True"
Check "config np registered"    ($apps.ContainsKey('np') -and $apps['np'][1] -eq 'notepad.exe')    "True"
Check "config bd url"           ($apps.ContainsKey('bd') -and $apps['bd'][1] -eq 'https://www.baidu.com') "True"
Remove-Item $tmp -Recurse -Force

# ---- 3) CalcForm renders ----
$form = [Activator]::CreateInstance($calcType, $true)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()
$bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
$form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
$png = Join-Path $PSScriptRoot 'calc-form.png'
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$form.Close()
Check "calc form rendered" (Test-Path $png) "True"
Write-Output "calc form screenshot: $png"

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
