# ============================================================
#  caret-probe2.ps1  -  deeper probe of WeChat's input field WITH text:
#   - does TextPattern GetBoundingRectangles appear once text exists?
#   - FontSize / FontName attributes for width estimation
#   - native fake caret position vs text length (does it track text?)
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\caret-probe2.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms,UIAutomationClient,UIAutomationTypes,WindowsBase -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using System.Windows.Automation;
using System.Windows.Automation.Text;

public static class Probe2
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
    public static void TypeAscii(string s)
    {
        var ins = new INPUT[s.Length * 2];
        int n = 0;
        foreach (char c in s) {
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4; n++;
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4 | 0x2; n++;
        }
        SendInput((uint)n, ins, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void ClearDraft()
    {
        var ins = new INPUT[6];
        ins[0].type = 1; ins[0].u.ki.wVk = 0x11;
        ins[1].type = 1; ins[1].u.ki.wVk = 0x41;
        ins[2].type = 1; ins[2].u.ki.wVk = 0x41; ins[2].u.ki.dwFlags = 0x2;
        ins[3].type = 1; ins[3].u.ki.wVk = 0x11; ins[3].u.ki.dwFlags = 0x2;
        ins[4].type = 1; ins[4].u.ki.wVk = 0x2E;
        ins[5].type = 1; ins[5].u.ki.wVk = 0x2E; ins[5].u.ki.dwFlags = 0x2;
        SendInput(6, ins, Marshal.SizeOf(typeof(INPUT)));
    }

    public static string Dump(string tag)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("--- " + tag + " ---");
        IntPtr fg = GetForegroundWindow();
        int pid; uint tid = GetWindowThreadProcessId(fg, out pid);

        var g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        if (GetGUIThreadInfo(tid, ref g) && g.hwndCaret != IntPtr.Zero) {
            var pt = new POINT { x = g.rcCaret.left, y = g.rcCaret.top };
            ClientToScreen(g.hwndCaret, ref pt);
            sb.AppendLine(string.Format("native caret screen: ({0},{1}) {2}x{3}", pt.x, pt.y,
                g.rcCaret.right - g.rcCaret.left, g.rcCaret.bottom - g.rcCaret.top));
        } else sb.AppendLine("native caret: none");

        try {
            var el = AutomationElement.FocusedElement;
            if (el == null) { sb.AppendLine("UIA: no focus"); return sb.ToString(); }
            sb.AppendLine("element rect: " + el.Current.BoundingRectangle);
            object pat;
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out pat)) {
                var tp = (TextPattern)pat;
                sb.AppendLine("document text: [" + tp.DocumentRange.GetText(200).Replace("\r", "\\r").Replace("\n", "\\n") + "]");
                var sel = tp.GetSelection();
                if (sel != null && sel.Length > 0) {
                    var rr = sel[0].GetBoundingRectangles();
                    if (rr == null || rr.Length == 0) sb.AppendLine("selection rects: none");
                    else foreach (var w in rr) sb.AppendLine("selection rect: " + w);
                    object fsz = sel[0].GetAttributeValue(TextPattern.FontSizeAttribute);
                    object fnm = sel[0].GetAttributeValue(TextPattern.FontNameAttribute);
                    sb.AppendLine("FontSize attr: " + fsz + "   FontName attr: " + fnm);
                } else sb.AppendLine("selection: none");
            } else sb.AppendLine("no TextPattern");
        } catch (Exception ex) { sb.AppendLine("UIA err: " + ex.Message); }
        return sb.ToString();
    }
}
'@

$hwnd = [Probe2]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat not running" }
[Probe2]::ForceForeground($hwnd)
Start-Sleep -Milliseconds 700
[Probe2]::ClickInputBox($hwnd)
Start-Sleep -Milliseconds 600
[Probe2]::ClearDraft()
Start-Sleep -Milliseconds 400

Write-Output ([Probe2]::Dump("empty draft"))
[Probe2]::TypeAscii("abcdefghij")          # 10 narrow ascii
Start-Sleep -Milliseconds 500
Write-Output ([Probe2]::Dump("10 ascii chars"))
[Probe2]::TypeAscii("abcdefghij")          # 10 more (20 total)
Start-Sleep -Milliseconds 500
Write-Output ([Probe2]::Dump("20 ascii chars"))
[Probe2]::ClearDraft()
Write-Output "draft cleared"
