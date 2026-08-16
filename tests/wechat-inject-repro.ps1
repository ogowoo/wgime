# ============================================================
#  wechat-inject-repro.ps1  -  WeChat 4.x VK_PACKET char-swallow repro
#
#  Prereq: WeChat open on the "File Transfer" chat.
#  Does: activates WeChat -> injects 8 tagged test sequences into the
#        input draft (pure VK_PACKET unicode, never presses Enter)
#        -> screenshots the window.
#  Output: tests\wechat-repro-result.png
#
#  NOTE: this file is PURE ASCII on purpose - PS 5.1 misreads BOM-less
#        UTF-8 scripts as ANSI, which mojibake'd the first run. All CJK
#        chars are built from code points / \u escapes instead.
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wechat-inject-repro.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class WechatProbe
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
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }

    public static void SendUnicode(string text)      // exactly what WgIme UnicodeCommit does: one batch, down+up per char
    {
        var ins = new INPUT[text.Length * 2];
        int n = 0;
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            if (char.IsSurrogate(c)) continue;       // test strings are BMP only
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4; n++;
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4 | 0x2; n++;
        }
        if (n == 0) return;
        if (SendInput((uint)n, ins, Marshal.SizeOf(typeof(INPUT))) != n)
            throw new InvalidOperationException("SendInput failed");
    }

    public static void SendStrayKeyUp(ushort vk)     // a physical-style keyup with no matching keydown (WgIme lets these through)
    {
        var ins = new INPUT[1];
        ins[0].type = 1; ins[0].u.ki.wVk = vk; ins[0].u.ki.dwFlags = 0x2;   // KEYUP
        if (SendInput(1, ins, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new InvalidOperationException("SendInput failed");
    }

    public static IntPtr FindWeChat()
    {
        IntPtr best = IntPtr.Zero;
        foreach (var p in Process.GetProcessesByName("Weixin")) {
            try {
                if (p.MainWindowHandle != IntPtr.Zero) {
                    string t = p.MainWindowTitle ?? "";
                    if (t.Contains("微信") || t.Contains("Weixin") || t.Contains("文件传输")) return p.MainWindowHandle;   // titles: WeChat / File Transfer
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
        ShowWindow(hWnd, 9);                 // SW_RESTORE
        BringWindowToTop(hWnd);
        SetForegroundWindow(hWnd);
        SetActiveWindow(hWnd);
        AttachThreadInput(my, target, false);
        if (fgT != target) AttachThreadInput(my, fgT, false);
        return GetForegroundWindow() == hWnd;
    }

    public static bool IsForeground(IntPtr hWnd) { return GetForegroundWindow() == hWnd; }

    public static void CaptureWindow(IntPtr hWnd, string path)
    {
        RECT r; GetWindowRect(hWnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        int x = r.Left, y = r.Top;
        if (w <= 0 || h <= 0 || !IsWindow(hWnd)) {   // fallback: virtual screen
            x = SystemInformation.VirtualScreen.Left; y = SystemInformation.VirtualScreen.Top;
            w = SystemInformation.VirtualScreen.Width; h = SystemInformation.VirtualScreen.Height;
        }
        using (var bmp = new Bitmap(w, h))
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(x, y, 0, 0, new Size(w, h));
            bmp.Save(path, ImageFormat.Png);
        }
    }

    public static void ClearDraft()                  // injected Ctrl+A then Delete (clears the input draft if it has focus)
    {
        var ins = new INPUT[6];
        ins[0].type = 1; ins[0].u.ki.wVk = 0x11;                       // Ctrl down
        ins[1].type = 1; ins[1].u.ki.wVk = 0x41;                       // A down
        ins[2].type = 1; ins[2].u.ki.wVk = 0x41; ins[2].u.ki.dwFlags = 0x2;
        ins[3].type = 1; ins[3].u.ki.wVk = 0x11; ins[3].u.ki.dwFlags = 0x2;
        ins[4].type = 1; ins[4].u.ki.wVk = 0x2E;                       // Del down
        ins[5].type = 1; ins[5].u.ki.wVk = 0x2E; ins[5].u.ki.dwFlags = 0x2;
        SendInput(6, ins, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

# ---- CJK test strings built from code points (file stays pure ASCII) ----
$NI    = [string][char]0x4F60          # ni
$HAO   = [string][char]0x597D          # hao
$NIHAO = $NI + $HAO
$COMMA = [string][char]0xFF0C          # fullwidth comma
$JUHAO = [string][char]0x3002          # ideographic full stop (U+3002, tdesktop stale range)

function Step([string]$tag, [scriptblock]$body) {
    [WechatProbe]::SendUnicode(" ")      # separator
    Start-Sleep -Milliseconds 400
    [WechatProbe]::SendUnicode($tag)     # ASCII label, e.g. [T1]
    Start-Sleep -Milliseconds 400
    & $body
}

$hwnd = [WechatProbe]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat (Weixin) main window not found" }
Write-Output ("WeChat window: 0x{0:X}" -f $hwnd.ToInt64())

$fg = [WechatProbe]::ForceForeground($hwnd)
Write-Output ("ForceForeground: " + $(if ($fg) { "OK" } else { "FAILED (continuing - hopefully window is already focused)" }))
Start-Sleep -Milliseconds 1200

Write-Output "injecting tests..."

Step "[T5]" { [WechatProbe]::SendUnicode($NIHAO) }                                        # control: no punct before

Step "[T1]" { [WechatProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 100
              [WechatProbe]::SendUnicode($NIHAO) }                                        # repro: fast after punct

Step "[T7]" { [WechatProbe]::SendUnicode($COMMA); [WechatProbe]::SendUnicode($NIHAO) }    # back-to-back batches

Step "[T2]" { [WechatProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 1500
              [WechatProbe]::SendUnicode($NIHAO) }                                        # long gap

Step "[T3]" { [WechatProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 100
              [WechatProbe]::SendUnicode($NI); Start-Sleep -Milliseconds 80
              [WechatProbe]::SendUnicode($HAO) }                                          # per-char batches

Step "[T4]" { [WechatProbe]::SendUnicode($JUHAO); Start-Sleep -Milliseconds 100
              [WechatProbe]::SendUnicode($NIHAO) }                                        # U+3002 (tdesktop stale range)

Step "[T6]" { [WechatProbe]::SendUnicode($COMMA); Start-Sleep -Milliseconds 100
              [WechatProbe]::SendStrayKeyUp(0x4E); Start-Sleep -Milliseconds 50           # stray N keyup (real typing lets these through)
              [WechatProbe]::SendUnicode($NIHAO) }

Step "[T8]" { [WechatProbe]::SendUnicode($COMMA + $NIHAO) }                               # single batch

Start-Sleep -Milliseconds 600
$png = Join-Path $PSScriptRoot 'wechat-repro-result.png'
[WechatProbe]::CaptureWindow($hwnd, $png)
Write-Output "screenshot saved: $png"

[WechatProbe]::ClearDraft()     # clean the draft box for the user
Write-Output "draft cleared. DONE"
