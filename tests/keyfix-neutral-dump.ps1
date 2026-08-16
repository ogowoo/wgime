# ============================================================
#  keyfix-neutral-dump.ps1  -  dump the exact message stream a WinForms
#  TextBox receives for the keyfix pattern, to understand the reorder.
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\keyfix-neutral-dump.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public class LogTextBox : TextBox
{
    public StringBuilder Log = new StringBuilder();
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0102 || m.Msg == 0x0100 || m.Msg == 0x0101) {   // CHAR / KEYDOWN / KEYUP
            string name = m.Msg == 0x0102 ? "CHAR" : (m.Msg == 0x0100 ? "KEYDOWN" : "KEYUP");
            Log.AppendLine(string.Format("{0,-8} wParam=0x{1:X4} lParam=0x{2:X8}  text_before=[{3}]",
                name, (uint)m.WParam.ToInt64() & 0xFFFF, (uint)m.LParam.ToInt64(), Text));
        }
        base.WndProc(ref m);
    }
}

public class DumpForm : Form
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
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    public LogTextBox Box;

    public DumpForm()
    {
        Text = "DumpForm";
        Size = new Size(420, 220);
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        Box = new LogTextBox { Multiline = true, Dock = DockStyle.Fill, Font = new Font("Microsoft YaHei UI", 12F) };
        Controls.Add(Box);
    }

    public void ForceForeground()
    {
        uint my = GetCurrentThreadId();
        IntPtr fg = GetForegroundWindow();
        uint fgT = GetWindowThreadProcessId(fg, IntPtr.Zero);
        AttachThreadInput(my, fgT, true);
        BringToFront();
        SetForegroundWindow(Handle);
        SetActiveWindow(Handle);
        AttachThreadInput(my, fgT, false);
    }

    static INPUT UKey(char c, uint flags) {
        var i = new INPUT(); i.type = 1; i.u.ki.wVk = 0; i.u.ki.wScan = c; i.u.ki.dwFlags = flags; return i;
    }
    static INPUT VKey(ushort vk, uint flags) {
        var i = new INPUT(); i.type = 1; i.u.ki.wVk = vk; i.u.ki.dwFlags = flags; return i;
    }

    public void InjectFixed(string text)
    {
        var ins = new INPUT[text.Length * 6 + 2];
        int n = 0;
        foreach (char c in text) {
            ins[n++] = UKey(c, 0x4);
            ins[n++] = UKey(c, 0x4 | 0x2);
            if (c >= 0x3000) {
                ins[n++] = UKey('X', 0x4);
                ins[n++] = UKey('X', 0x4 | 0x2);
                ins[n++] = VKey(0x08, 0);
                ins[n++] = VKey(0x08, 0x2);
            }
        }
        string shown = text.Replace(new string((char)0xFF0C, 1), "<COMMA>")
                           .Replace(new string((char)0x4F60, 1), "<NI>")
                           .Replace(new string((char)0x597D, 1), "<HAO>");
        Box.Log.AppendLine("--- inject [" + shown + "] ---");
        if (SendInput((uint)n, ins, Marshal.SizeOf(typeof(INPUT))) != n)
            throw new InvalidOperationException("SendInput failed");
    }
}

public static class NeutralDump
{
    public static string Run()
    {
        var f = new DumpForm();
        f.Show();
        Application.DoEvents();
        f.ForceForeground();
        f.Box.Focus();
        Application.DoEvents();
        System.Threading.Thread.Sleep(400);
        Application.DoEvents();

        string COMMA = new string((char)0xFF0C, 1);
        string NI = new string((char)0x4F60, 1);
        string HAO = new string((char)0x597D, 1);

        f.InjectFixed(COMMA);
        System.Threading.Thread.Sleep(200); Application.DoEvents();
        f.InjectFixed(NI + HAO);
        System.Threading.Thread.Sleep(200); Application.DoEvents();
        f.InjectFixed(NI + COMMA + HAO);
        System.Threading.Thread.Sleep(200); Application.DoEvents();

        for (int i = 0; i < 10; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(30); }
        string result = "FINAL TEXT BYTES: " + BitConverter.ToString(Encoding.Unicode.GetBytes(f.Box.Text));
        string s = f.Box.Log.ToString() + result;
        f.Close();
        return s;
    }
}
'@

$out = [NeutralDump]::Run()
$logPath = Join-Path $PSScriptRoot 'keyfix-neutral-dump.txt'
[IO.File]::WriteAllText($logPath, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Output $out
