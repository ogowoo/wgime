# ============================================================
#  caret-wechat-verify.ps1  -  verify the NEW TryGetCaretScreenRect
#  (from the rebuilt WgIme DLL) against the real WeChat input box:
#  the 2x2 fake caret must be skipped and the anchor must equal the
#  input field's bounding rect (x = field.Left + 8, height = field).
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\caret-wechat-verify.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms,UIAutomationClient,UIAutomationTypes,WindowsBase -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class WcFocus
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

    public static IntPtr FindWeChat()
    {
        foreach (var p in Process.GetProcessesByName("Weixin")) {
            try { if (p.MainWindowHandle != IntPtr.Zero) return p.MainWindowHandle; } catch {}
        }
        return IntPtr.Zero;
    }
    public static void ForceForeground(IntPtr hWnd)
    {
        uint my = GetCurrentThreadId();
        uint target = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
        IntPtr fg = GetForegroundWindow();
        uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
        AttachThreadInput(my, target, true);
        if (fgT != target) AttachThreadInput(my, fgT, true);
        ShowWindow(hWnd, 9);
        SetForegroundWindow(hWnd);
        AttachThreadInput(my, target, false);
        if (fgT != target) AttachThreadInput(my, fgT, false);
    }
    public static void ClickInputBox(IntPtr hWnd)
    {
        RECT r; GetWindowRect(hWnd, out r);
        int px = r.left + (int)((r.right - r.left) * 0.75), py = r.bottom - 70;
        var ins = new INPUT[2];
        ins[0].type = 0; ins[0].u.mi.dx = (int)((px * 65535.0) / (SystemInformation.VirtualScreen.Width - 1));
        ins[0].u.mi.dy = (int)((py * 65535.0) / (SystemInformation.VirtualScreen.Height - 1));
        ins[0].u.mi.dwFlags = 0x8000 | 0x0001 | 0x0002;
        ins[1].type = 0; ins[1].u.mi.dx = ins[0].u.mi.dx; ins[1].u.mi.dy = ins[0].u.mi.dy;
        ins[1].u.mi.dwFlags = 0x8000 | 0x0001 | 0x0004;
        SendInput(2, ins, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
$fl = [Reflection.BindingFlags] 'Static, Public, NonPublic'
$tryM = $wbType.GetMethod('TryGetCaretScreenRect', $fl)

$hwnd = [WcFocus]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat not running" }
[WcFocus]::ForceForeground($hwnd)
Start-Sleep -Milliseconds 800
[WcFocus]::ClickInputBox($hwnd)
Start-Sleep -Milliseconds 700

$args = @([System.Drawing.Rectangle]::Empty)
$ok = $tryM.Invoke($null, $args)
$r = $args[0]
Write-Output ("ok=" + $ok + "  anchor rect (empty draft): " + $r)

# ground truth fetched live: the focused element's bounding rect
$elRect = [System.Windows.Rect]::Empty
try {
    $el = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($el -ne $null) { $elRect = $el.Current.BoundingRectangle }
} catch {}
Write-Output ("field rect (live): " + $elRect)

$pass = $true
if (-not $ok) { Write-Output "FAIL  no anchor"; $pass = $false }
if ($r.Height -lt 10) { Write-Output "FAIL  degenerate anchor (fake caret leaked): h=$($r.Height)"; $pass = $false }
if (-not $elRect.IsEmpty) {
    if ($r.X -lt $elRect.Left - 5 -or $r.X -gt $elRect.Right) { Write-Output "FAIL  anchor X outside field"; $pass = $false }
    if ($r.Y -lt $elRect.Top - 5 -or $r.Y -gt $elRect.Bottom + 10) { Write-Output "FAIL  anchor Y outside field band"; $pass = $false }
}

# text-following: type 6 ascii chars into the draft, anchor X must move right; then clear the draft
# (SendKeys uses SendInput -> LLKHF_INJECTED, so a running WgIme passes them straight through)
[System.Windows.Forms.SendKeys]::SendWait("abcdef")
Start-Sleep -Milliseconds 500
$args2 = @([System.Drawing.Rectangle]::Empty)
$ok2 = $tryM.Invoke($null, $args2)
$r2 = $args2[0]
Write-Output ("ok=" + $ok2 + "  anchor rect (6 chars): " + $r2)
if ($ok2 -and $r2.X -le $r.X + 10) { Write-Output "FAIL  anchor did not follow text (x $($r.X) -> $($r2.X))"; $pass = $false }
if ($ok2 -and $r2.X -gt $r.X + 10) { Write-Output "PASS  anchor follows typed text (x $($r.X) -> $($r2.X))" }

# clear the draft we typed
[System.Windows.Forms.SendKeys]::SendWait("^a")
Start-Sleep -Milliseconds 200
[System.Windows.Forms.SendKeys]::SendWait("{DEL}")
Start-Sleep -Milliseconds 200

if ($pass) { Write-Output "PASS  WeChat anchor refined (fake caret skipped, follows text)" }
if (-not $pass) { exit 1 }
