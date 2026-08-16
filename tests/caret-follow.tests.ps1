# ============================================================
#  caret-follow.tests.ps1  -  tests for the candidate-board caret
#  following (config followcaret=):
#   1. LoadConfig defaults: FollowCaret = true; followcaret=0 -> false
#   2. TryGetCaretScreenRect against a real focused TextBox (native
#      Win32 caret path): rect non-empty and inside the form bounds
#
#  Prereq: rebuild.ps1 has run (%TEMP%\wgime_new.dll is current).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\caret-follow.tests.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class CaretForm : Form
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    public TextBox Box;
    public CaretForm()
    {
        Text = "CaretProbe";
        Size = new Size(400, 200);
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        Box = new TextBox { Dock = DockStyle.Top, Height = 32, Font = new Font("Consolas", 12F), Text = "hello world" };
        Controls.Add(Box);
    }
    public void ForceForeground()
    {
        uint my = GetCurrentThreadId();
        IntPtr fg = GetForegroundWindow();
        uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
        AttachThreadInput(my, fgT, true);
        BringToFront();
        SetForegroundWindow(Handle);
        SetActiveWindow(Handle);
        AttachThreadInput(my, fgT, false);
    }
    public bool IsForeground() { return GetForegroundWindow() == Handle; }
}
'@

$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'

$pass = 0; $fail = 0
function Check([string]$name, $actual, $expected) {
    if ("$actual" -ceq "$expected") { Write-Output "PASS  $name"; $script:pass++ }
    else { Write-Output "FAIL  $name (expected [$expected], got [$actual])"; $script:fail++ }
}

# ---- 1) config ----
$followF = $wbType.GetField('FollowCaret', $fl)
$hideIdleF = $wbType.GetField('HideIdle', $fl)
$loadC = $wbType.GetMethod('LoadConfig', $fl)
$tmp = [string](Join-Path $env:TEMP ('wgime-caret-test-' + [guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Path $tmp | Out-Null
$loadC.Invoke($null, @($tmp))                                   # no config.txt -> defaults
Check "FollowCaret default on"  ($followF.GetValue($null))      "True"
Check "HideIdle default on"     ($hideIdleF.GetValue($null))    "True"
[IO.File]::WriteAllText((Join-Path $tmp 'config.txt'), "followcaret = 0`nhideidle = 0`n", (New-Object System.Text.UTF8Encoding($false)))
$loadC.Invoke($null, @($tmp))
Check "followcaret=0 parsed"  ($followF.GetValue($null))        "False"
Check "hideidle=0 parsed"     ($hideIdleF.GetValue($null))      "False"
Remove-Item $tmp -Recurse -Force

# ---- 2) native caret rect from a real focused TextBox ----
$tryM = $wbType.GetMethod('TryGetCaretScreenRect', $fl)
$f = New-Object CaretForm
$f.Show()
[System.Windows.Forms.Application]::DoEvents()
$f.ForceForeground()
$f.Box.Focus()
$f.Box.SelectionStart = 5
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 400
[System.Windows.Forms.Application]::DoEvents()
Write-Output ("foreground: " + $f.IsForeground())

$rectType = [System.Drawing.Rectangle]
$args = @([System.Drawing.Rectangle]::Empty)
$ok = $tryM.Invoke($null, $args)
$r = $args[0]
Write-Output ("caret rect: " + $r)
Check "TryGetCaretScreenRect ok"  ($ok)                                            "True"
Check "rect non-empty"            (($r.Width -ge 1) -and ($r.Height -ge 4))        "True"
Check "rect within form X"        (($r.X -ge $f.Left) -and ($r.X -le $f.Right))    "True"
Check "rect within form Y"        (($r.Y -ge $f.Top) -and ($r.Y -le $f.Bottom))    "True"
$f.Close()

Write-Output ""
Write-Output "== $pass passed, $fail failed =="
if ($fail -gt 0) { exit 1 }
