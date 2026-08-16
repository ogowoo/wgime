# ============================================================
#  vkpacket-msg-dump.ps1  -  dump the exact window-message stream that
#  a KEYEVENTF_UNICODE batch produces, to pinpoint how Windows
#  translates VK_PACKET and where the "stale char" misalignment in
#  Qt's PeekMessage(WM_CHAR) comes from.
#
#  Creates a focusable WinForms window with a WndProc logger, injects:
#    batch 1: [COMMA down/up]
#    batch 2: [NI down/up, HAO down/up]
#  logs every WM_(SYS)KEYDOWN/KEYUP/CHAR/DEADCHAR/IME_* with wParam/lParam
#  hex + tick to tests\vkpacket-msg-dump.txt
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\vkpacket-msg-dump.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class MsgDumpForm : Form
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

    public StringBuilder Log = new StringBuilder();
    int lastTick = -1;

    static string MsgName(int m) {
        switch (m) {
            case 0x0100: return "KEYDOWN";
            case 0x0101: return "KEYUP";
            case 0x0102: return "CHAR";
            case 0x0103: return "DEADCHAR";
            case 0x0104: return "SYSKEYDOWN";
            case 0x0105: return "SYSKEYUP";
            case 0x0106: return "SYSCHAR";
            case 0x0281: return "IME_CHAR";
            case 0x0282: return "IME_COMPOSITION";
            case 0x010F: return "IME_REQUEST?";
            case 0x0286: return "IME_CHAR(286)";
            case 0x0290: return "IME_KEYLAST?";
            default: return null;
        }
    }

    protected override void WndProc(ref Message m)
    {
        string name = MsgName(m.Msg);
        if (name != null) {
            int tick = Environment.TickCount;
            int delta = lastTick < 0 ? 0 : tick - lastTick;
            lastTick = tick;
            Log.AppendLine(string.Format("{0,-8} +{1,4}ms  wParam=0x{2:X8}  lParam=0x{3:X8}",
                name, delta, (uint)m.WParam.ToInt64(), (uint)m.LParam.ToInt64()));
        }
        base.WndProc(ref m);
    }

    public void InjectBatch(string text)
    {
        Log.AppendLine("--- inject batch: " + BitConverter.ToString(Encoding.Unicode.GetBytes(text)) + " ---");
        lastTick = -1;
        var ins = new INPUT[text.Length * 2];
        int n = 0;
        foreach (char c in text) {
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4; n++;
            ins[n].type = 1; ins[n].u.ki.wVk = 0; ins[n].u.ki.wScan = c; ins[n].u.ki.dwFlags = 0x4 | 0x2; n++;
        }
        if (SendInput((uint)n, ins, Marshal.SizeOf(typeof(INPUT))) != n)
            Log.AppendLine("!! SendInput failed");
    }

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    public bool ForceForeground()
    {
        uint my = GetCurrentThreadId();
        IntPtr fg = GetForegroundWindow();
        uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
        AttachThreadInput(my, fgT, true);
        BringToFront();
        SetForegroundWindow(Handle);
        SetActiveWindow(Handle);
        AttachThreadInput(my, fgT, false);
        return GetForegroundWindow() == Handle;
    }
}

public static class MsgDump
{
    public static string Run()
    {
        var f = new MsgDumpForm();
        f.Text = "MsgDump";
        f.Size = new Size(320, 200);
        f.StartPosition = FormStartPosition.CenterScreen;
        f.TopMost = true;
        f.Show();
        Application.DoEvents();
        bool fg = f.ForceForeground();
        f.Log.AppendLine("ForceForeground: " + fg);
        Application.DoEvents();
        System.Threading.Thread.Sleep(500);
        Application.DoEvents();

        string COMMA = "\uFF0C", NIHAO = "\u4F60\u597D";   // CJK via unicode escapes (file is pure ASCII)

        f.Log.AppendLine("=== batch 1: COMMA ===");
        f.InjectBatch(COMMA);
        for (int i = 0; i < 10; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(30); }

        f.Log.AppendLine("=== batch 2: NIHAO ===");
        f.InjectBatch(NIHAO);
        for (int i = 0; i < 10; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(30); }

        string s = f.Log.ToString();
        f.Close();
        return s;
    }
}
'@

$out = [MsgDump]::Run()
$logPath = Join-Path $PSScriptRoot 'vkpacket-msg-dump.txt'
[IO.File]::WriteAllText($logPath, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "log written: $logPath"
Write-Output ""
Write-Output $out
