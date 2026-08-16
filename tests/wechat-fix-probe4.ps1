# ============================================================
#  wechat-fix-probe4.ps1  -  round 4: decisive tests for the fix design.
#
#  Model: after a fullwidth punct injected via KEYEVENTF_UNICODE,
#  WeChat 4.x replaces the NEXT injected char with that punct
#  (stale char). Fix candidate: after each trigger char, append a
#  throwaway char + VK_BACK inside the same commit batch.
#
#  Tests:
#   C1: realistic typing interleave: COMMA, stray ups of N I H A O,
#       NIHAO batch, SPACE up  -> drop or replace?
#   C2: stray keyup INSIDE the victim batch (between ni-down and ni-up)
#   C3: fix under realistic interleave: [COMMA x BACK], stray ups, NIHAO
#   C4: YEN U+00A5 as trigger?
#   C5: LEFT DOUBLE QUOTE U+201C as trigger?
#   C6: IDEOGRAPHIC COMMA U+3001 as trigger?
#   C7: emoji U+1F600 (surrogate pair) as trigger?
#   C8: mid-text punct, control: "ni COMMA hao" plain  (expect ni,,?)
#   C9: mid-text punct, fixed: "ni COMMA x BACK hao"   (expect ni,hao)
#   C0: control COMMA + NIHAO (expect stale fail)
#
#  Prereq: WeChat open on "File Transfer". Pure ASCII source file.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wechat-fix-probe4.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class FixProbe4
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

    public static void SendUnicode(string text)          // WgIme-style batch (handles surrogate pairs like FillUnicodeEvents)
    {
        var ins = new INPUT[text.Length * 2 + 2];
        int n = 0;
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) {
                ins[n++] = Key(0, c, KEYEVENTF_UNICODE);
                ins[n++] = Key(0, text[i + 1], KEYEVENTF_UNICODE);
                ins[n++] = Key(0, text[i + 1], KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
                ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
                i++;
                continue;
            }
            if (char.IsSurrogate(c)) continue;
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE);
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
        }
        if (n > 0) { var t = new INPUT[n]; Array.Copy(ins, t, n); Fire(t); }
    }

    // the fix transform: trigger char followed by throwaway(=same char) + VK_BACK, all in one batch
    public static void SendUnicodeFixed(string text)
    {
        var ins = new INPUT[text.Length * 6 + 2];
        int n = 0;
        for (int i = 0; i < text.Length; i++) {
            char c = text[i];
            if (char.IsSurrogate(c)) {                       // keep test simple: skip astral here
                ins[n++] = Key(0, c, KEYEVENTF_UNICODE);
                ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
                continue;
            }
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE);
            ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
            if (c >= 0x2000 || c == 0xA5) {                  // trigger range (puncts/symbols/fullwidth)
                ins[n++] = Key(0, c, KEYEVENTF_UNICODE);                       // throwaway absorbs the stale hit
                ins[n++] = Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP);
                ins[n++] = Key(0x08, 0, 0);                                    // VK_BACK removes it
                ins[n++] = Key(0x08, 0, KEYEVENTF_KEYUP);
            }
        }
        if (n > 0) { var t = new INPUT[n]; Array.Copy(ins, t, n); Fire(t); }
    }

    public static void StrayUp(ushort vk) { Fire(new[] { Key(vk, 0, KEYEVENTF_KEYUP) }); }

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
$COMMA = [string][char]0xFF0C
$DCOMMA= [string][char]0x3001          # ideographic comma
$JUHAO = [string][char]0x3002
$YEN   = [string][char]0x00A5
$LQ    = [string][char]0x201C          # left double quote
$EMOJI = [char]::ConvertFromUtf32(0x1F600)

function Step([string]$tag, [scriptblock]$body) {
    [FixProbe4]::SendUnicode(" ")
    Start-Sleep -Milliseconds 400
    [FixProbe4]::SendUnicode($tag)
    Start-Sleep -Milliseconds 400
    & $body
}

$hwnd = [FixProbe4]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat (Weixin) main window not found" }
Write-Output ("WeChat window: 0x{0:X}" -f $hwnd.ToInt64())
$fg = [FixProbe4]::ForceForeground($hwnd)
Write-Output ("ForceForeground: " + $(if ($fg) { "OK" } else { "FAILED" }))
Start-Sleep -Milliseconds 1200

Write-Output "injecting round-4 probes..."

Step "[C0]" { [FixProbe4]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe4]::SendUnicode($NIHAO) }                                    # control: expect stale fail

Step "[C1]" { [FixProbe4]::SendUnicode($COMMA)                                      # realistic interleave
              foreach ($vk in 0x4E,0x49,0x48,0x41,0x4F) { Start-Sleep -Milliseconds 40; [FixProbe4]::StrayUp($vk) }
              Start-Sleep -Milliseconds 40
              [FixProbe4]::SendUnicode($NIHAO)
              Start-Sleep -Milliseconds 50; [FixProbe4]::StrayUp(0x20) }            # space released after commit

Step "[C2]" { [FixProbe4]::SendUnicode($COMMA); Start-Sleep -Milliseconds 150
              [FixProbe4]::SendUnicode($NI)                                          # victim ni...
              [FixProbe4]::StrayUp(0x20)                                             # ...space-up right after its batch
              [FixProbe4]::SendUnicode($HAO) }

Step "[C3]" { [FixProbe4]::SendUnicodeFixed($COMMA)                                 # fix + realistic interleave
              foreach ($vk in 0x4E,0x49,0x48,0x41,0x4F) { Start-Sleep -Milliseconds 40; [FixProbe4]::StrayUp($vk) }
              Start-Sleep -Milliseconds 40
              [FixProbe4]::SendUnicodeFixed($NIHAO)
              Start-Sleep -Milliseconds 50; [FixProbe4]::StrayUp(0x20) }

Step "[C4]" { [FixProbe4]::SendUnicode($YEN); Start-Sleep -Milliseconds 150
              [FixProbe4]::SendUnicode($NIHAO) }                                    # yen trigger?

Step "[C5]" { [FixProbe4]::SendUnicode($LQ); Start-Sleep -Milliseconds 150
              [FixProbe4]::SendUnicode($NIHAO) }                                    # quote trigger?

Step "[C6]" { [FixProbe4]::SendUnicode($DCOMMA); Start-Sleep -Milliseconds 150
              [FixProbe4]::SendUnicode($NIHAO) }                                    # ideographic comma trigger?

Step "[C7]" { [FixProbe4]::SendUnicode($EMOJI); Start-Sleep -Milliseconds 150
              [FixProbe4]::SendUnicode($NIHAO) }                                    # emoji trigger?

Step "[C8]" { [FixProbe4]::SendUnicode($NI + $COMMA + $HAO) }                       # mid-text punct, plain

Step "[C9]" { [FixProbe4]::SendUnicodeFixed($NI + $COMMA + $HAO) }                  # mid-text punct, fixed

Start-Sleep -Milliseconds 600
$png = Join-Path $PSScriptRoot 'wechat-fix-probe4.png'
[FixProbe4]::CaptureWindow($hwnd, $png)
Write-Output "screenshot saved: $png"

[FixProbe4]::ClearDraft()
Write-Output "draft cleared. DONE"
