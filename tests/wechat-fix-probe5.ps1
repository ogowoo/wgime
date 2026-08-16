# ============================================================
#  wechat-fix-probe5.ps1  -  round 5: isolate the working fix pattern.
#
#  B8 worked:   [COMMA X] batch -> 80ms -> [BK] call -> 80ms -> text
#  C3 failed:   [COMMA COMMA BK] single batch ... text
#  Variables: throwaway char (X vs punct itself), backspace placement
#  (same batch vs separate call vs separate batch), delay length.
#
#  Tests (all followed by NIHAO unless noted):
#   D1: [COMMA X BK] single batch            -> X + same-batch back
#   D2: [COMMA COMMA] batch -> [BK] call     -> punct throwaway + separate back
#   D3: [COMMA X] batch -> [BK] call         -> B8 repeat (expect success)
#   D4: D3 but 30ms gaps                     -> shorter delay OK?
#   D5: D3 but 0ms gap (back-to-back calls)  -> call boundary enough?
#   D6: [COMMA] [X] [BK] three calls, 0ms    -> fully split
#   D7: D3 pattern + realistic stray keyups between punct and text
#   D8: mid-text: single commit "NI COMMA X" -> [BK] -> "HAO" (fixed)
#
#  Prereq: WeChat open on "File Transfer". Pure ASCII source file.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wechat-fix-probe5.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class FixProbe5
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

    public static void SendRaw(string text, bool xAfterPunct, bool backInSameBatch)
    {
        // build event list; optionally append X + BK after chars >= 0x3000
        var list = new System.Collections.Generic.List<INPUT>();
        foreach (char c in text) {
            list.Add(Key(0, c, KEYEVENTF_UNICODE));
            list.Add(Key(0, c, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            if (c >= 0x3000) {
                if (xAfterPunct) {
                    list.Add(Key(0, 'X', KEYEVENTF_UNICODE));
                    list.Add(Key(0, 'X', KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
                if (backInSameBatch) {
                    list.Add(Key(0x08, 0, 0));
                    list.Add(Key(0x08, 0, KEYEVENTF_KEYUP));
                }
            }
        }
        Fire(list.ToArray());
    }

    public static void Back() { Fire(new[] { Key(0x08, 0, 0), Key(0x08, 0, KEYEVENTF_KEYUP) }); }
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

function Step([string]$tag, [scriptblock]$body) {
    [FixProbe5]::SendUnicode(" ")
    Start-Sleep -Milliseconds 400
    [FixProbe5]::SendUnicode($tag)
    Start-Sleep -Milliseconds 400
    & $body
}

$hwnd = [FixProbe5]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat (Weixin) main window not found" }
Write-Output ("WeChat window: 0x{0:X}" -f $hwnd.ToInt64())
$fg = [FixProbe5]::ForceForeground($hwnd)
Write-Output ("ForceForeground: " + $(if ($fg) { "OK" } else { "FAILED" }))
Start-Sleep -Milliseconds 1200

Write-Output "injecting round-5 probes..."

Step "[D1]" { [FixProbe5]::SendRaw($COMMA, $true, $true)                            # [COMMA X BK] single batch
              Start-Sleep -Milliseconds 150
              [FixProbe5]::SendUnicode($NIHAO) }

Step "[D2]" { [FixProbe5]::SendUnicode($COMMA + $COMMA)                             # punct throwaway, separate back
              Start-Sleep -Milliseconds 80
              [FixProbe5]::Back()
              Start-Sleep -Milliseconds 80
              [FixProbe5]::SendUnicode($NIHAO) }

Step "[D3]" { [FixProbe5]::SendUnicode($COMMA + "X")                                # B8 repeat: X throwaway + separate back
              Start-Sleep -Milliseconds 80
              [FixProbe5]::Back()
              Start-Sleep -Milliseconds 80
              [FixProbe5]::SendUnicode($NIHAO) }

Step "[D4]" { [FixProbe5]::SendUnicode($COMMA + "X")                                # 30ms gaps
              Start-Sleep -Milliseconds 30
              [FixProbe5]::Back()
              Start-Sleep -Milliseconds 30
              [FixProbe5]::SendUnicode($NIHAO) }

Step "[D5]" { [FixProbe5]::SendUnicode($COMMA + "X")                                # 0ms: back-to-back separate calls
              [FixProbe5]::Back()
              [FixProbe5]::SendUnicode($NIHAO) }

Step "[D6]" { [FixProbe5]::SendUnicode($COMMA)                                      # fully split, 0ms
              [FixProbe5]::SendUnicode("X")
              [FixProbe5]::Back()
              [FixProbe5]::SendUnicode($NIHAO) }

Step "[D7]" { [FixProbe5]::SendUnicode($COMMA + "X")                                # B8 pattern + realistic stray ups
              Start-Sleep -Milliseconds 80
              [FixProbe5]::Back()
              foreach ($vk in 0x4E,0x49,0x48,0x41,0x4F) { Start-Sleep -Milliseconds 40; [FixProbe5]::StrayUp($vk) }
              Start-Sleep -Milliseconds 40
              [FixProbe5]::SendUnicode($NIHAO)
              Start-Sleep -Milliseconds 50; [FixProbe5]::StrayUp(0x20) }

Step "[D8]" { [FixProbe5]::SendUnicode($NI + $COMMA + "X")                          # mid-text: [NI COMMA X] -> [BK] -> [HAO]
              Start-Sleep -Milliseconds 80
              [FixProbe5]::Back()
              Start-Sleep -Milliseconds 80
              [FixProbe5]::SendUnicode($HAO) }

Start-Sleep -Milliseconds 600
$png = Join-Path $PSScriptRoot 'wechat-fix-probe5.png'
[FixProbe5]::CaptureWindow($hwnd, $png)
Write-Output "screenshot saved: $png"

[FixProbe5]::ClearDraft()
Write-Output "draft cleared. DONE"
