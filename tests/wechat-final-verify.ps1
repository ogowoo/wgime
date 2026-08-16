# ============================================================
#  wechat-final-verify.ps1  -  verify the SHIPPED fix: loads the freshly
#  rebuilt WgIme DLL (%TEMP%\wgime_new.dll) and invokes the real
#  WordBoard.UnicodeCommitQtFix via reflection (uninitialized instance:
#  the method uses no instance state) against the WeChat draft box.
#
#  Expectation in the draft: [F1]，你好 [F2]你，好 [F3]abc
#
#  Prereq: WeChat open on "File Transfer". Pure ASCII source file.
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wechat-final-verify.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

$dll = Join-Path $env:TEMP 'wgime_new.dll'
if (-not (Test-Path $dll)) { throw "rebuilt DLL not found: $dll (run rebuild.ps1 first)" }

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class FinalProbe
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

    public static void SendAscii(string text)            // tags: plain unicode, ASCII never triggers the bug
    {
        var ins = new INPUT[text.Length * 2];
        int n = 0;
        foreach (char c in text) {
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4; n++;
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4 | 0x2; n++;
        }
        if (SendInput((uint)n, ins, Marshal.SizeOf(typeof(INPUT))) != n) throw new InvalidOperationException("SendInput failed");
    }

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

    public static void ClickInputBox(IntPtr hWnd)      // focus the draft box: click near the bottom of the chat pane
    {
        RECT r; GetWindowRect(hWnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return;
        // input box occupies the bottom strip of the right ~2/3 of the window
        int px = r.Left + (int)(w * 0.75), py = r.Bottom - 70;
        var ins = new INPUT[2];
        ins[0].type = 0; ins[0].u.mi.dx = (int)((px * 65535.0) / (SystemInformation.VirtualScreen.Width - 1));
        ins[0].u.mi.dy = (int)((py * 65535.0) / (SystemInformation.VirtualScreen.Height - 1));
        ins[0].u.mi.dwFlags = 0x8000 | 0x0001 | 0x0002;   // ABSOLUTE|MOVE|LEFTDOWN
        ins[1].type = 0; ins[1].u.mi.dx = ins[0].u.mi.dx; ins[1].u.mi.dy = ins[0].u.mi.dy;
        ins[1].u.mi.dwFlags = 0x8000 | 0x0001 | 0x0004;   // ABSOLUTE|MOVE|LEFTUP
        if (SendInput(2, ins, Marshal.SizeOf(typeof(INPUT))) != 2) throw new InvalidOperationException("SendInput failed");
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
        if (SendInput(6, ins, Marshal.SizeOf(typeof(INPUT))) != 6) throw new InvalidOperationException("SendInput failed");
    }
}
'@

$asm = [Reflection.Assembly]::LoadFile($dll)
$wbType = $asm.GetType('WordBoard')
if ($wbType -eq $null) { throw "WordBoard type not found in $dll" }
$mi = $wbType.GetMethod('UnicodeCommitQtFix', [Reflection.BindingFlags] 'Instance, NonPublic')
if ($mi -eq $null) { throw "UnicodeCommitQtFix not found - rebuild did not include the fix" }
$board = [Runtime.Serialization.FormatterServices]::GetUninitializedObject($wbType)
Write-Output "loaded WordBoard.UnicodeCommitQtFix from rebuilt DLL"

$COMMA = [string][char]0xFF0C
$NI    = [string][char]0x4F60
$HAO   = [string][char]0x597D

$hwnd = [FinalProbe]::FindWeChat()
if ($hwnd -eq [IntPtr]::Zero) { throw "WeChat (Weixin) main window not found" }
$fg = [FinalProbe]::ForceForeground($hwnd)
Write-Output ("ForceForeground: " + $(if ($fg) { "OK" } else { "FAILED" }))
Start-Sleep -Milliseconds 800
[FinalProbe]::ClickInputBox($hwnd)        # ensure the draft box actually has keyboard focus
Start-Sleep -Milliseconds 700

Write-Output "invoking shipped UnicodeCommitQtFix against WeChat draft..."

[FinalProbe]::SendAscii("[F1]")
$mi.Invoke($board, @($COMMA))                    # punct commit alone
Start-Sleep -Milliseconds 150
$mi.Invoke($board, @($NI + $HAO))                # next commit: must NOT be staled
Start-Sleep -Milliseconds 400
[FinalProbe]::SendAscii(" [F2]")
$mi.Invoke($board, @($NI + $COMMA + $HAO))       # mid-string punct
Start-Sleep -Milliseconds 400
[FinalProbe]::SendAscii(" [F3]")
$mi.Invoke($board, @("abc"))                     # ASCII control

Start-Sleep -Milliseconds 600
$png = Join-Path $PSScriptRoot 'wechat-final-verify.png'
[FinalProbe]::CaptureWindow($hwnd, $png)
Write-Output "screenshot saved: $png"

[FinalProbe]::ClearDraft()
Write-Output "draft cleared. DONE"
