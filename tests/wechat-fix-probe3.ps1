# ============================================================
#  wechat-fix-probe3.ps1  -  round 3: characterize trigger scope and
#  test the "absorb + delete" workaround for the WeChat 4.x (Qt)
#  VK_PACKET stale-char bug.
#
#  Bug model so far: after a fullwidth punct (U+FF0C/U+3002) is
#  injected via KEYEVENTF_UNICODE, the NEXT injected char (any gap,
#  any batching) is replaced by that punct. Exactly one char.
#
#  Tests:
#   B1: "de"(U+7684, high byte 0x76) + 150ms + NIHAO  -> is a common CJK also a trigger?
#   B2: HAO + 150ms + NI                               -> CJK non-punct control
#   B7: COMMA + 150ms + JUHAO                          -> punct after punct?
#   B3: COMMA + "X" + VK_BACK                          -> absorb+delete, expect just COMMA
#   B8: COMMA + "X" + VK_BACK + NIHAO                  -> full workaround, expect COMMA+NIHAO
#   B9: COMMA + VK_BACK (no throwaway)                 -> what does backspace after punct do
#   B0: control COMMA + NIHAO (expect stale fail)
#
#  Prereq: WeChat open on "File Transfer". Pure ASCII source file.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wechat-fix-probe3.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class FixProbe3
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

    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);

    const uint KEYEVENTF_UNICODE = 0x4, KEYEVENTF_KEYUP = 0x2;

    static INPUT Key(ushort vk, ushort scan, uint flags) {
        var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; i.u.ki.wScan = scan; i.u.ki.dwFlags = flags; return i;
    }
    static void Fire(INPUT[] ins) {
        if (SendInput((uint)ins.Length, ins, Marshal.SizeOf(typeof(INPUT))) != ins.Length)
            throw new InvalidOperationException("SendInput failed");
    }

    public static void SendUnicode(string text)
    {
        var ins = new INPUT[text.Length * 2];
        int n = 0;
        foreach (char c in text) {
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE);
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        }
        Fire(ins);
    }

    public static void TapKey(ushort vk) { Fire(new[] { Key(vk, 0, 0), Key(vk, 0, KEYEVENTF_KEYUP) }); }

    public static IntPtr FindWeChat()
    {
        IntPtr best = IntPtr.Zero;
        foreach (var p in Process.GetProcessesByName("Weixin")) {
            try { if (p.MainWindowHandle != IntPtr.Zero && best == IntPtr.Zero) best = p.MainWindowHandle; } catch {}
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

$NI    = [string][char]0x4F60
$HAO   = [string][char]0x597D
$NIHAO = $NI + $HAO
$DE    = [string][char]0x7684          # "de" - common CJK, high byte 0x76
$COMMA = [string][char]0xFF0C
$JUHAO = [string][char]0x3002

function Step([string]$tag, [scriptblock]$body) {
    [FixProbe3]::SendUnicode(" ")
    Start-Sleep -Milliseconds 400
    [FixProbe3]::SendUnicode($tag)
    Start-Sleep -Milliseconds 400
    & $body
}

$hwnd = [FixProbe3]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat (Weixin) main window not found" }
Write-Output ("WeChat window: 0x{0:X}" -f $hwnd.ToInt64())
$fg = [FixProbe3]::ForceForeground($hwnd)
Write-Output ("ForceForeground: " + $(if ($fg) { "OK" } else { "FAILED" }))
Start-Sleep -Milliseconds 1200

Write-Output "injecting round-3 probes..."

Step "[B0]" { [FixProbe3]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe3]::SendUnicode($NIHAO) }                                   # control: expect stale fail

Step "[B1]" { [FixProbe3]::SendUnicode($DE); Start-Sleep -Milliseconds 150
              [FixProbe3]::SendUnicode($NIHAO) }                                   # common CJK trigger? expect de+NIHAO if only puncts trigger

Step "[B2]" { [FixProbe3]::SendUnicode($HAO); Start-Sleep -Milliseconds 150
              [FixProbe3]::SendUnicode($NI) }                                      # CJK non-punct control

Step "[B7]" { [FixProbe3]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe3]::SendUnicode($JUHAO) }                                   # punct after punct

Step "[B3]" { [FixProbe3]::SendUnicode($COMMA + "X"); Start-Sleep -Milliseconds 80
              [FixProbe3]::TapKey(0x08) }                                          # absorb+delete: expect COMMA only

Step "[B8]" { [FixProbe3]::SendUnicode($COMMA + "X"); Start-Sleep -Milliseconds 80
              [FixProbe3]::TapKey(0x08); Start-Sleep -Milliseconds 80
              [FixProbe3]::SendUnicode($NIHAO) }                                   # full workaround: expect COMMA+NIHAO

Step "[B9]" { [FixProbe3]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe3]::TapKey(0x08) }                                          # backspace right after punct

Start-Sleep -Milliseconds 600
$png = Join-Path $PSScriptRoot 'wechat-fix-probe3.png'
[FixProbe3]::CaptureWindow($hwnd, $png)
Write-Output "screenshot saved: $png"

[FixProbe3]::ClearDraft()
Write-Output "draft cleared. DONE"
