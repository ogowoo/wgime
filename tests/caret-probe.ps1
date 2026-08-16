# ============================================================
#  caret-probe.ps1  -  dump all caret sources for the focused app:
#    1) native Win32 caret (GetGUIThreadInfo + ClientToScreen)
#    2) UIA TextPattern selection bounding rect
#    3) UIA focused element bounding rect
#    4) the known click point (ground truth for an empty draft)
#
#  Targets: WeChat (Weixin) if running, else Notepad (spawns one).
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\caret-probe.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms,UIAutomationClient,UIAutomationTypes,WindowsBase -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Windows.Automation;

public static class CaretProbe
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct GUITHREADINFO {
        public int cbSize; public uint flags;
        public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion u; }

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT pt);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out int pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

    public static IntPtr FindAppWindow(string procName)
    {
        foreach (var p in Process.GetProcessesByName(procName)) {
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

    public static Point ClickIntoInputBox(IntPtr hWnd)   // returns the click point (ground truth)
    {
        RECT r; GetWindowRect(hWnd, out r);
        int px = r.left + (int)((r.right - r.left) * 0.75);
        int py = r.bottom - 70;
        var ins = new INPUT[2];
        ins[0].type = 0; ins[0].u.mi.dx = (int)((px * 65535.0) / (SystemInformation.VirtualScreen.Width - 1));
        ins[0].u.mi.dy = (int)((py * 65535.0) / (SystemInformation.VirtualScreen.Height - 1));
        ins[0].u.mi.dwFlags = 0x8000 | 0x0001 | 0x0002;
        ins[1].type = 0; ins[1].u.mi.dx = ins[0].u.mi.dx; ins[1].u.mi.dy = ins[0].u.mi.dy;
        ins[1].u.mi.dwFlags = 0x8000 | 0x0001 | 0x0004;
        SendInput(2, ins, Marshal.SizeOf(typeof(INPUT)));
        return new Point(px, py);
    }

    public static string Dump()
    {
        var sb = new System.Text.StringBuilder();
        IntPtr fg = GetForegroundWindow();
        int pid; uint tid = GetWindowThreadProcessId(fg, out pid);
        string proc = "?";
        try { proc = Process.GetProcessById(pid).ProcessName; } catch {}
        sb.AppendLine("foreground: " + proc + " hwnd=0x" + fg.ToInt64().ToString("X"));

        // 1) native caret
        var g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (GetGUIThreadInfo(tid, ref g)) {
            sb.AppendLine(string.Format("native: hwndCaret=0x{0:X} rcCaret=({1},{2},{3},{4})",
                g.hwndCaret.ToInt64(), g.rcCaret.left, g.rcCaret.top, g.rcCaret.right, g.rcCaret.bottom));
            if (g.hwndCaret != IntPtr.Zero) {
                var pt = new POINT { x = g.rcCaret.left, y = g.rcCaret.top };
                if (ClientToScreen(g.hwndCaret, ref pt))
                    sb.AppendLine(string.Format("native screen: ({0},{1}) size {2}x{3}", pt.x, pt.y,
                        g.rcCaret.right - g.rcCaret.left, g.rcCaret.bottom - g.rcCaret.top));
            }
        } else sb.AppendLine("native: GetGUIThreadInfo failed");

        // 2) UIA
        try {
            var el = AutomationElement.FocusedElement;
            if (el == null) { sb.AppendLine("UIA: no focused element"); }
            else {
                sb.AppendLine("UIA element: class=" + el.Current.ClassName + " type=" + el.Current.ControlType.ProgrammaticName);
                sb.AppendLine("UIA element rect: " + el.Current.BoundingRectangle);
                object pat;
                if (el.TryGetCurrentPattern(TextPattern.Pattern, out pat)) {
                    var sel = ((TextPattern)pat).GetSelection();
                    sb.AppendLine("UIA TextPattern ranges: " + (sel == null ? "null" : sel.Length.ToString()));
                    if (sel != null && sel.Length > 0) {
                        var rr = sel[0].GetBoundingRectangles();
                        if (rr == null) sb.AppendLine("UIA selection rect: null");
                        else foreach (var w in rr) sb.AppendLine("UIA selection rect: " + w);
                    }
                } else sb.AppendLine("UIA: no TextPattern");
            }
        } catch (Exception ex) { sb.AppendLine("UIA: " + ex.Message); }
        return sb.ToString();
    }
}
'@

$hwnd = [CaretProbe]::FindAppWindow('Weixin')
$target = 'WeChat'
if ($hwnd -eq [IntPtr]::Zero) {
    $p = Start-Process notepad.exe -PassThru
    Start-Sleep -Milliseconds 900
    $hwnd = [CaretProbe]::FindAppWindow('notepad')
    $target = 'Notepad(spawned)'
}
if ($hwnd -eq [IntPtr]::Zero) { throw "no target window" }
Write-Output "target: $target"

[CaretProbe]::ForceForeground($hwnd)
Start-Sleep -Milliseconds 800
$click = [CaretProbe]::ClickIntoInputBox($hwnd)
Start-Sleep -Milliseconds 700
Write-Output ("clicked at: " + $click.X + "," + $click.Y)
Write-Output ""
Write-Output ([CaretProbe]::Dump())
