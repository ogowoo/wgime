# ============================================================
#  plugins-applets.tests.ps1  -  tests for the plugin system and the
#  three new embedded applets (clipboard history / note / color picker):
#   1. ClipPush: dedupe / move-to-top / cap
#   2. NotesPath under DataDir
#   3. ColorHex / ColorHsv
#   4. LoadPlugins: header parse, step parse (incl. [powershell] block),
#      Apps registration with plugin: command, collision override
#   5. new builtins registered (clip/bj/ys)
#   6. ClipForm / NoteForm / ColorForm render (screenshots)
#
#  Prereq: rebuild.ps1 has run (%TEMP%\wgime_new.dll is current).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\plugins-applets.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;
public static class FormShot
{   // pure C# delegates: PS scriptblocks cannot run on a foreign thread (no runspace there)
    public static void InvokeSave(Form f, string path)
    {
        f.Invoke(new MethodInvoker(delegate {
            var bmp = new Bitmap(f.Width, f.Height);
            f.DrawToBitmap(bmp, new Rectangle(0, 0, f.Width, f.Height));
            bmp.Save(path, ImageFormat.Png);
        }));
    }
    public static void InvokeClose(Form f) { f.Invoke(new MethodInvoker(delegate { f.Close(); })); }
    public static int TabCount(Form f)
    {
        return (int)f.Invoke(new Func<int>(delegate {
            foreach (Control c in f.Controls) { var tc = c as TabControl; if (tc != null) return tc.TabPages.Count; }
            return -1;
        }));
    }
    public static int NamedButtonCount(Form f, string names)   // flat-UI tab strips (no TabControl): count controls with these texts anywhere in the tree (custom buttons may be Panel-based)
    {
        return (int)f.Invoke(new Func<int>(delegate {
            int n = 0;
            var stack = new System.Collections.Generic.List<Control>();
            Collect(f, stack);
            foreach (Control c in stack) {
                if (c.Text != null && ("," + names + ",").Contains("," + c.Text + ",")) n++;
            }
            return n;
        }));
    }
    static void Collect(Control c, System.Collections.Generic.List<Control> acc)
    {
        foreach (Control cc in c.Controls) { acc.Add(cc); Collect(cc, acc); }
    }
}
'@
$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'
$fln = [Reflection.BindingFlags] 'Instance, Public, NonPublic'

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected [$expected], got [$actual])"; $script:fail++ }
}

# ---- 1) ClipPush ----
$pushM = $wbType.GetMethod('ClipPush', $fl)
[System.Collections.Generic.List[string]]$h = New-Object 'System.Collections.Generic.List[string]'
$pushM.Invoke($null, @($h, 'aaa', 200)) | Out-Null
$pushM.Invoke($null, @($h, 'bbb', 200)) | Out-Null
$pushM.Invoke($null, @($h, 'ccc', 200)) | Out-Null
Check "clip order"            (($h -join '|'))                    "ccc|bbb|aaa"
Check "clip dup no-change"    ($pushM.Invoke($null, @($h, 'ccc', 200)))  "False"
Check "clip dup move-top"     ($pushM.Invoke($null, @($h, 'aaa', 200)))  "True"
Check "clip moved top"        (($h -join '|'))                    "aaa|ccc|bbb"
Check "clip empty ignored"    ($pushM.Invoke($null, @($h, '', 200)))     "False"
[System.Collections.Generic.List[string]]$cap = New-Object 'System.Collections.Generic.List[string]'
foreach ($i in 1..5) { $pushM.Invoke($null, @($cap, "item$i", 3)) | Out-Null }
Check "clip cap"              (($cap -join '|'))                  "item5|item4|item3"

# ---- 2) NotesPath ----
$dataDirF = $wbType.GetField('DataDir', 'Public, Static')
$dataDirF.SetValue($null, 'C:\SomeDir')
$notesM = $wbType.GetMethod('NotesPath', $fl)
Check "notes path"            ([string]$notesM.Invoke($null, @()))  "C:\SomeDir\notes.txt"

# ---- 3) color helpers ----
$hexM = $wbType.GetMethod('ColorHex', $fl)
$hsvM = $wbType.GetMethod('ColorHsv', $fl)
Check "hex red"    ([string]$hexM.Invoke($null, @([System.Drawing.Color]::FromArgb(255, 0, 0))))    "#FF0000"
Check "hex blue"   ([string]$hexM.Invoke($null, @([System.Drawing.Color]::FromArgb(0, 0, 255))))    "#0000FF"
Check "hsv red"    ([string]$hsvM.Invoke($null, @([System.Drawing.Color]::FromArgb(255, 0, 0))))    "H 0  S 100%  V 100%"
Check "hsv blue"   ([string]$hsvM.Invoke($null, @([System.Drawing.Color]::FromArgb(0, 0, 255))))    "H 240  S 100%  V 100%"
Check "hsv white"  ([string]$hsvM.Invoke($null, @([System.Drawing.Color]::White)))                  "H 0  S 0%  V 100%"

# ---- 4) LoadPlugins ----
$loadP  = $wbType.GetMethod('LoadPlugins', $fl)
$loadC  = $wbType.GetMethod('LoadConfig', $fl)
$appsF  = $wbType.GetField('Apps', $fl)
$pactF  = $wbType.GetField('PluginActions', $fl)

$tmp = [string](Join-Path $env:TEMP ('wgime-plugin-test-' + [guid]::NewGuid().ToString('N')))
$pdir = Join-Path $tmp 'plugins'
New-Item -ItemType Directory -Path $pdir | Out-Null
$QN = [char]0x6E05 + [char]0x7406     # 清理
$plugin = @"
; sample plugin
code = tq
name = $QN demo
desc = test

msg hello
[shell]
echo a
echo b
[/shell]
"@
[IO.File]::WriteAllText((Join-Path $pdir 'demo.txt'), $plugin, (New-Object System.Text.UTF8Encoding($false)))
$loadC.Invoke($null, @($tmp))        # LoadConfig calls LoadPlugins at the end
$apps = $appsF.GetValue($null)
Check "plugin registered"    ($apps.ContainsKey('tq') -and $apps['tq'][1].StartsWith('plugin:'))  "True"
Check "plugin name"          ($apps['tq'][0])                                                    "$QN demo"
$pacts = $pactF.GetValue($null)
$pfile = Join-Path $pdir 'demo.txt'
Check "plugin parsed"        ($pacts.ContainsKey($pfile))                                         "True"
$act = $pacts[$pfile]
$steps = $act.GetType().GetField('Steps', $fln).GetValue($act)
Check "plugin steps"         ($steps.Count)                                                       "2"
Check "plugin step1 verb"    ($steps[0][0])                                                       "msg"
Check "plugin step2 block"   ($steps[1][0])                                                       "shellblock"

# collision: plugin overrides builtin
$plugin2 = "code = net`nname = override`n`nmsg x`n"
[IO.File]::WriteAllText((Join-Path $pdir 'override.txt'), $plugin2, (New-Object System.Text.UTF8Encoding($false)))
$loadC.Invoke($null, @($tmp))
$apps = $appsF.GetValue($null)
Check "plugin overrides builtin"  ($apps['net'][1].StartsWith('plugin:'))                          "True"
Remove-Item $tmp -Recurse -Force

# ---- 4b) code plugins ([csharp] block) ----
$compileM = $wbType.GetMethod('CompilePlugin', $fl)
$pccF     = $wbType.GetField('PluginCodeCache', $fl)

$marker = Join-Path $env:TEMP ('wgime-plugin-marker-' + [guid]::NewGuid().ToString('N') + '.txt')
$goodSrc = @"
using System;
public class P { public static void Run() { System.IO.File.WriteAllText(@"$($marker -replace '\\','\\')", "ran"); } }
"@
$pc = $compileM.Invoke($null, @($goodSrc))
Check "codeplugin compiles"   ($pc.GetType().GetField('Error', $fln).GetValue($pc) -eq $null)   "True"
$entry = $pc.GetType().GetField('Entry', $fln).GetValue($pc)
Check "codeplugin entry"      ($entry -ne $null)                                                "True"
$entry.Invoke($null, @())
Check "codeplugin Run works"  ((Test-Path $marker) -and ((Get-Content $marker -Raw) -eq 'ran')) "True"
Remove-Item $marker -Force

$badSrc = "public class P { public static void Run() { broken broken } }"
$pc2 = $compileM.Invoke($null, @($badSrc))
Check "compile error caught"  ($pc2.GetType().GetField('Error', $fln).GetValue($pc2) -ne $null) "True"

$noRun = "public class P { public static void NotRun() {} }"
$pc3 = $compileM.Invoke($null, @($noRun))
Check "no Run() detected"     ([string]$pc3.GetType().GetField('Error', $fln).GetValue($pc3) -match 'Run')  "True"

# end-to-end: plugin file with a [csharp] block
$tmp3 = [string](Join-Path $env:TEMP ('wgime-cplugin-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path (Join-Path $tmp3 'plugins') | Out-Null
$marker3 = Join-Path $env:TEMP ('wgime-cplugin-marker-' + [guid]::NewGuid().ToString('N') + '.txt')
$csPlugin = @"
code = csx
name = cs demo

[csharp]
using System;
public class CsDemo { public static void Run() { System.IO.File.WriteAllText(@"$($marker3 -replace '\\','\\')", "cs-ok"); } }
[/csharp]
"@
[IO.File]::WriteAllText((Join-Path $tmp3 'plugins\csdemo.txt'), $csPlugin, (New-Object System.Text.UTF8Encoding($false)))
$loadC.Invoke($null, @($tmp3))
$apps = $appsF.GetValue($null)
Check "codeplugin registered"  ($apps.ContainsKey('csx') -and $apps['csx'][1].StartsWith('codeplugin:'))  "True"
$pcc = $pccF.GetValue($null)
$pcFile = Join-Path $tmp3 'plugins\csdemo.txt'
Check "codeplugin cached"      ($pcc.ContainsKey($pcFile))                                              "True"
$pcE = $pcc[$pcFile].GetType().GetField('Error', $fln).GetValue($pcc[$pcFile])
Check "codeplugin no error"    ($pcE -eq $null)                                                         "True"
$pcc[$pcFile].GetType().GetField('Entry', $fln).GetValue($pcc[$pcFile]).Invoke($null, @())
Check "codeplugin end-to-end"  ((Get-Content $marker3 -Raw) -eq 'cs-ok')                                "True"
Remove-Item $tmp3, $marker3 -Recurse -Force -ErrorAction SilentlyContinue

# ---- 4c) code plugins run on the DEDICATED plugin thread ----
$tmp4 = [string](Join-Path $env:TEMP ('wgime-cthread-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path (Join-Path $tmp4 'plugins') | Out-Null
$marker4 = Join-Path $env:TEMP ('wgime-cthread-' + [guid]::NewGuid().ToString('N') + '.txt')
$threadPlugin = @"
code = cth
name = thread probe

[csharp]
using System;
public class ThreadProbe { public static void Run() { System.IO.File.WriteAllText(@"$($marker4 -replace '\\','\\')", System.Threading.Thread.CurrentThread.Name); } }
[/csharp]
"@
[IO.File]::WriteAllText((Join-Path $tmp4 'plugins\tp.txt'), $threadPlugin, (New-Object System.Text.UTF8Encoding($false)))
$loadC.Invoke($null, @($tmp4))
$runCodeM = $wbType.GetMethod('RunCodePlugin', $fln)
$hostObj = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($wbType)
[string]$tpFile = Join-Path $tmp4 'plugins\tp.txt'
$runCodeM.Invoke($hostObj, @($tpFile))
$ok4 = $false
for ($i = 0; $i -lt 30; $i++) { if (Test-Path $marker4) { $ok4 = $true; break } Start-Sleep -Milliseconds 100 }
Check "codeplugin executed"      $ok4                                                          "True"
Check "runs on WgImePlugins"     ((Get-Content $marker4 -Raw) -eq 'WgImePlugins')                "True"
Check "not the main thread"      ((Get-Content $marker4 -Raw) -ne ([System.Threading.Thread]::CurrentThread.Name))  "True"
Remove-Item $tmp4, $marker4 -Recurse -Force -ErrorAction SilentlyContinue

# ---- 5) new builtins ----
$loadC.Invoke($null, @($tmp))        # dir no longer exists -> defaults only
$apps = $appsF.GetValue($null)
Check "clip builtin"   ($apps.ContainsKey('clip')  -and $apps['clip'][1]  -eq 'builtin:clip')   "True"
Check "note builtin"   ($apps.ContainsKey('bj')    -and $apps['bj'][1]    -eq 'builtin:note')   "True"
Check "color builtin"  ($apps.ContainsKey('ys')    -and $apps['ys'][1]    -eq 'builtin:color')  "True"

# ---- 5b) plugin manager builtin + form ----
$loadC.Invoke($null, @('C:\Tools\WgIme'))        # real repo: clean-bin.txt + clock.txt present
$apps = $appsF.GetValue($null)
Check "plugins builtin"  ($apps.ContainsKey('plugins') -and $apps['plugins'][1] -eq 'builtin:pluginmgr') "True"
Check "cjgl builtin"     ($apps.ContainsKey('cjgl')    -and $apps['cjgl'][1]    -eq 'builtin:pluginmgr') "True"

$mt = $wbType.GetNestedType('PluginMgrForm', 'NonPublic')
$ctor = $mt.GetConstructors([Reflection.BindingFlags]'Instance, Public, NonPublic')[0]
$mgr = $ctor.Invoke(@($null))                    # host not needed for listing
$mgr.Show()
[System.Windows.Forms.Application]::DoEvents()
$lv = $mt.GetField('list', $fln).GetValue($mgr)
Check "mgr lists plugins"  ($lv.Items.Count -ge 2)                                                  "True"
$bmp = New-Object System.Drawing.Bitmap($mgr.Width, $mgr.Height)
$mgr.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $mgr.Width, $mgr.Height)))
$png = Join-Path $PSScriptRoot 'pluginmgr-form.png'
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$mgr.Close()
Check "mgr form rendered"  (Test-Path $png)                                                         "True"

# ---- 5c) clock plugin end-to-end: dedicated thread, 4 tabs, renders ----
$hostObj = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($wbType)
$runCodeM = $wbType.GetMethod('RunCodePlugin', $fln)
$runCodeM.Invoke($hostObj, @('C:\Tools\WgIme\plugins\clock.txt'))
$clockForm = $null
for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Milliseconds 150
    $clockForm = [System.Windows.Forms.Application]::OpenForms | Where-Object { $_.Text -eq 'WgIme Clock' } | Select-Object -First 1
    if ($clockForm -ne $null) { break }
}
Check "clock plugin form"      ($clockForm -ne $null)                                               "True"
if ($clockForm -ne $null) {
    $tabNames = [string][char]0x65F6 + [char]0x949F + ',' + [string][char]0x5012 + [char]0x8BA1 + [char]0x65F6 + ',' + [string][char]0x79D2 + [char]0x8868 + ',' + [string][char]0x756A + [char]0x8304   # clock/countdown/stopwatch/pomodoro
    Check "clock has 4 tabs"   ([FormShot]::NamedButtonCount($clockForm, $tabNames))                    "4"
    $cpng = Join-Path $PSScriptRoot 'clock-form.png'
    [FormShot]::InvokeSave($clockForm, $cpng)
    Check "clock rendered"     (Test-Path $cpng)                                                    "True"
    [FormShot]::InvokeClose($clockForm)
}

# ---- 5d) WPF plugin: PresentationFramework refs available to [csharp] plugins ----
$wtmp = [string](Join-Path $env:TEMP ('wgime-wpf-test-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path (Join-Path $wtmp 'plugins') -Force | Out-Null
$wps = @'
code = wt
name = WpfT
desc = wpf smoke

[csharp]
using System;
using System.Windows;
using System.Windows.Controls;
public class WpfT { public static void Run() { var w = new Window { Title = "t" }; w.Content = new TextBlock { Text = "x" }; w.Show(); } }
[/csharp]
'@
[IO.File]::WriteAllText((Join-Path $wtmp 'plugins\wt.txt'), $wps, (New-Object System.Text.UTF8Encoding($false)))
$loadP = $wbType.GetMethod('LoadPlugins', $fl)
$loadP.Invoke($null, @($wtmp))
$cacheF2 = $wbType.GetField('PluginCodeCache', $fl)
$wpfErr = "no-cache"
foreach ($key in $cacheF2.GetValue($null).Keys) { $pc2 = $cacheF2.GetValue($null)[$key]; $wpfErr = $pc2.GetType().GetField('Error', 'Instance, Public, NonPublic').GetValue($pc2) }
Check "wpf plugin compiles" ($wpfErr -eq $null)                                                          "True"
Remove-Item $wtmp -Recurse -Force

# ---- 6) forms render ----
function Shot($typeName, $pngName) {
    $t = $wbType.GetNestedType($typeName, 'NonPublic')
    $ctor = $t.GetConstructors([Reflection.BindingFlags]'Instance, Public, NonPublic')[0]
    $form = $ctor.Invoke(@())
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $png = Join-Path $PSScriptRoot $pngName
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $form.Close()
    return (Test-Path $png)
}
Check "clip form rendered"   (Shot 'ClipForm'  'clip-form.png')    "True"
Check "note form rendered"   (Shot 'NoteForm'  'note-form.png')    "True"
Check "color form rendered"  (Shot 'ColorForm' 'color-form.png')   "True"

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
