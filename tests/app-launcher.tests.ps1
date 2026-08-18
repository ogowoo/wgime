# ============================================================
#  app-launcher.tests.ps1  -  tests for the IME app launcher:
#   1. calculator expression parser (compiles plugins\calc.txt [csharp] block)
#   2. Apps registry: config.txt "app =" parsing + jsq/calc plugin registration from the repo
#   3. calc plugin form renders (screen capture -> tests\calc-form.png)
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

# ---- 1) expression parser (now lives in the plugins\calc.txt [csharp] plugin) ----
$calcFile = Join-Path $PSScriptRoot '..\plugins\calc.txt'
$ctxt = [IO.File]::ReadAllText($calcFile, [Text.Encoding]::UTF8)
$ci = $ctxt.IndexOf('[csharp]'); $cs0 = $ctxt.IndexOf("`n", $ci) + 1; $ce = $ctxt.IndexOf('[/csharp]', $cs0)
$csrc = $ctxt.Substring($cs0, $ce - $cs0)
$ccp = New-Object Microsoft.CSharp.CSharpCodeProvider
$cpar = New-Object System.CodeDom.Compiler.CompilerParameters
$cpar.GenerateInMemory = $true
$cpar.ReferencedAssemblies.AddRange([string[]]@('System.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll', 'System.Core.dll', 'System.Data.dll'))
$cres = $ccp.CompileAssemblyFromSource($cpar, $csrc)
if ($cres.Errors.HasErrors) { foreach ($err in $cres.Errors) { Write-Output "COMPILE ERR line $($err.Line): $($err.ErrorText)" }; throw "calc plugin compile failed" }
$calcM = $cres.CompiledAssembly.GetType('CalcPlugin').GetMethod('Calc')
$runM  = $cres.CompiledAssembly.GetType('CalcPlugin').GetMethod('Run')
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
    ('app = bd' + "`t" + 'Search' + "`t" + 'https://www.baidu.com'),
    'app = mm Mspaint mspaint.exe',                                                             # space-separated (no TABs)
    ('app = pp Pwsh "C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile'),              # quoted path with spaces + args
    ('app = ev' + "`t" + 'EnvPath' + "`t" + '%WINDIR%\notepad.exe'),                            # env var in command
    'app = broken OnlyTwoParts'                                                                 # must be ignored
)
[IO.File]::WriteAllText((Join-Path $tmp 'config.txt'), ($cfgLines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
$loadConfig.Invoke($null, @([string]$tmp))
$apps = $appsF.GetValue($null)
Check "config np registered"    ($apps.ContainsKey('np') -and $apps['np'][1] -eq 'notepad.exe')    "True"
Check "config bd url"           ($apps.ContainsKey('bd') -and $apps['bd'][1] -eq 'https://www.baidu.com') "True"
Check "space-separated mm"      ($apps.ContainsKey('mm') -and $apps['mm'][1] -eq 'mspaint.exe' -and $apps['mm'][0] -eq 'Mspaint') "True"
Check "quoted path + args"      ($apps.ContainsKey('pp') -and $apps['pp'][1] -eq 'C:\Program Files\PowerShell\7\pwsh.exe' -and $apps['pp'][2] -eq '-NoLogo -NoProfile') "True"
Check "two-part line ignored"   ($apps.ContainsKey('broken'))                                      "False"
Check "env var expanded"        ($apps.ContainsKey('ev') -and $apps['ev'][1] -like 'C:\*notepad.exe')    "True"
$srcB = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\wgime.bat'), [Text.Encoding]::UTF8)
Check "app relative path resolution" ($srcB -match 'IsPathRooted\(target\)')                       "True"
Remove-Item $tmp -Recurse -Force

# calculator registrations come from the repo plugins\calc.txt (jsq direct, calc = alias)
$repoDir = [string](Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$loadConfig.Invoke($null, @($repoDir))
$apps = $appsF.GetValue($null)
Check "jsq plugin registered"  ($apps.ContainsKey('jsq') -and $apps['jsq'][1].StartsWith('codeplugin:'))   "True"
Check "calc alias registered"  ($apps.ContainsKey('calc') -and $apps['calc'][1] -eq $apps['jsq'][1])       "True"

# ---- 3) calc plugin form renders ----
$runM.Invoke($null, @())
Start-Sleep -Milliseconds 500
$form = $null
foreach ($fr in [System.Windows.Forms.Application]::OpenForms) { if ($fr.Text -eq 'WgIme Calc') { $form = $fr; break } }
Check "calc form opened" ($form -ne $null) "True"
if ($form -ne $null) {
    [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($form.Left, $form.Top, 0, 0, $bmp.Size)
    $png = Join-Path $PSScriptRoot 'calc-form.png'
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $form.Close()
    Check "calc form rendered" (Test-Path $png) "True"
    Write-Output "calc form screenshot: $png"
}

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
