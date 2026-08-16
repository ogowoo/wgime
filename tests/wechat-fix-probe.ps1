# ============================================================
#  wechat-fix-probe.ps1  -  round 2: sender-side workarounds for the
#  WeChat 4.x (Qt) VK_PACKET stale-char bug.
#
#  Confirmed bug: the char injected right after a fullwidth punct
#  (U+FF0C / U+3002 ...) is replaced by that punct ("你好" after ","
#  renders as ",,hao"). Timing/batching irrelevant.
#
#  This script tests candidate workarounds (tagged, screenshotted):
#   A1: punct + SHIFT tap cleanser + text
#   A2: punct + text, every down/up event in its OWN SendInput call
#   A3: punct + VK_PACKET U+0000 cleanser + text
#   A4: punct injected, text via PostMessage(WM_CHAR) to focused hwnd
#   A5: punct + text with down/up split 250ms apart per char
#   A6: control (punct + plain unicode text, expect failure)
#   A7: punct + VK_PACKET U+200B (zero-width space) cleanser + text
#
#  Prereq: WeChat open on "File Transfer". Pure ASCII source file.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wechat-fix-probe.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class FixProbe
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public UIntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT { public uint uMsg; public ushort wParamL; public ushort wParamH; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public HARDWAREINPUT hi; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion u; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    struct GUITHREADINFO {
        public int cbSize; public uint flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
        public RECT rcCaret;
    }

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO info);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

    const uint KEYEVENTF_UNICODE = 0x4, KEYEVENTF_KEYUP = 0x2, WM_CHAR = 0x0102;

    static INPUT Key(ushort vk, ushort scan, uint flags) {
        var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; i.u.ki.wScan = scan; i.u.ki.dwFlags = flags; return i;
    }
    static void Fire(INPUT[] ins) {
        if (SendInput((uint)ins.Length, ins, Marshal.SizeOf(typeof(INPUT))) != ins.Length)
            throw new InvalidOperationException("SendInput failed");
    }

    public static void SendUnicode(string text)            // WgIme-style: one batch per string
    {
        var ins = new INPUT[text.Length * 2];
        int n = 0;
        foreach (char c in text) {
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE);
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        }
        Fire(ins);
    }

    public static void SendUnicodeSplitEvents(string text) // every single event in its own SendInput call
    {
        foreach (char c in text) {
            Fire(new[] { Key(0, c, KEYEVENTF_UNICODE) });
            Fire(new[] { Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP) });
        }
    }

    public static void SendUnicodeSlowUp(string text, int ms)  // down ... ms ... up, per char
    {
        foreach (char c in text) {
            Fire(new[] { Key(0, c, KEYEVENTF_UNICODE) });
            System.Threading.Thread.Sleep(ms);
            Fire(new[] { Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP) });
        }
    }

    public static void TapKey(ushort vk) { Fire(new[] { Key(vk, 0, 0), Key(vk, 0, KEYEVENTF_KEYUP) }); }   // modifier cleanser

    public static void SendCharWm(string text)             // PostMessage WM_CHAR to the focused control
    {
        IntPtr fg = GetForegroundWindow();
        uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
        var g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
        IntPtr target = fg;
        if (GetGUIThreadInfo(tid, ref g) && g.hwndFocus != IntPtr.Zero) target = g.hwndFocus;
        foreach (char c in text) PostMessage(target, WM_CHAR, (IntPtr)c, IntPtr.Zero);
    }

    public static IntPtr FindWeChat()
    {
        IntPtr best = IntPtr.Zero;
        foreach (var p in Process.GetProcessesByName("Weixin")) {
            try {
                if (p.MainWindowHandle != IntPtr.Zero) {
                    if (best == IntPtr.Zero) best = p.MainWindowHandle;
                }
            } catch {}
        }
        return best;
    }

    public static bool ForceForeground(IntPtr hWnd)
    {
        uint my = GetCurrentThreadId();
        uint target = GetWindowThreadProcessId(hWnd, IntPtr.Zero);
        IntPtr fg = GetForegroundWindow();
        uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
        AttachThreadInput(my, target, true);
        if (fgT != target) AttachThreadInput(my, fgT, true);
        ShowWindow(hWnd, 9);
        BringWindowToTop(hWnd);
        SetForegroundWindow(hWnd);
        SetActiveWindow(hWnd);
        AttachThreadInput(my, target, false);
        if (fgT != target) AttachThreadInput(my, fgT, false);
        return GetForegroundWindow() == hWnd;
    }

    public static void CaptureWindow(IntPtr hWnd, string path)
    {
        RECT r; GetWindowRect(hWnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        int x = r.Left, y = r.Top;
        if (w <= 0 || h <= 0 || !IsWindow(hWnd)) {
            x = SystemInformation.VirtualScreen.Left; y = SystemInformation.VirtualScreen.Top;
            w = SystemInformation.VirtualScreen.Width; h = SystemInformation.VirtualScreen.Height;
        }
        using (var bmp = new Bitmap(w, h))
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
            bmp.Save(path, ImageFormat.Png);
        }
    }

    public static void ClearDraft()
    {
        var ins = new INPUT[6];
        ins[0] = Key(0x11, 0, 0); ins[1] = Key(0x41, 0, 0); ins[2] = Key(0x41, 0, KEYEVENTF_KEYUP);
        ins[3] = Key(0x11, 0, KEYEVENTF_KEYUP); ins[4] = Key(0x2E, 0, 0); ins[5] = Key(0x2E, 0, KEYEVENTF_KEYUP);
        Fire(ins);
    }
}
'@

# ---- strings from code points (file stays pure ASCII) ----
$NIHAO = [string][char]0x4F60 + [char]0x597D
$COMMA = [string][char]0xFF0C
$NULLC = [string][char]0x0000
$ZWSP  = [string][char]0x200B

function Step([string]$tag, [scriptblock]$body) {
    [FixProbe]::SendUnicode(" ")
    Start-Sleep -Milliseconds 400
    [FixProbe]::SendUnicode($tag)
    Start-Sleep -Milliseconds 400
    & $body
}

$hwnd = [FixProbe]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat (Weixin) main window not found" }
Write-Output ("WeChat window: 0x{0:X}" -f $hwnd.ToInt64())
$fg = [FixProbe]::ForceForeground($hwnd)
Write-Output ("ForceForeground: " + $(if ($fg) { "OK" } else { "FAILED" }))
Start-Sleep -Milliseconds 1200

Write-Output "injecting workaround probes..."

Step "[A6]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::SendUnicode($NIHAO) }                                   # control: expect stale fail

Step "[A1]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::TapKey(0x10); Start-Sleep -Milliseconds 50              # SHIFT tap cleanser
              [FixProbe]::SendUnicode($NIHAO) }

Step "[A2]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::SendUnicodeSplitEvents($NIHAO) }                        # one SendInput per event

Step "[A3]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::SendUnicode($NULLC); Start-Sleep -Milliseconds 50       # U+0000 cleanser
              [FixProbe]::SendUnicode($NIHAO) }

Step "[A4]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::SendCharWm($NIHAO) }                                    # WM_CHAR posted to focus

Step "[A5]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::SendUnicodeSlowUp($NIHAO, 250) }                        # down/up 250ms apart

Step "[A7]" { [FixProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe]::SendUnicode($ZWSP); Start-Sleep -Milliseconds 50        # zero-width space cleanser
              [FixProbe]::SendUnicode($NIHAO) }

Start-Sleep -Milliseconds 600
$png = Join-Path $PSScriptRoot 'wechat-fix-probe.png'
[FixProbe]::CaptureWindow($hwnd, $png)
Write-Output "screenshot saved: $png"

[FixProbe]::ClearDraft()
Write-Output "draft cleared. DONE"
