# ============================================================
#  keyfix-neutral-check.ps1  -  verify the absorb+erase pattern is
#  self-neutralizing in a NORMAL (non-Qt) control: a WinForms TextBox.
#  Injects the exact keyfix pattern (", X BK" then "ni hao") plus a
#  mid-string variant and an ASCII control, then asserts TextBox.Text.
#
#  Expect: ",nihao" + "ni,hao" + "abc" all exact, no stray X anywhere.
#
#  Run:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\keyfix-neutral-check.ps1
# ============================================================
$ErrorActionPreference = 'Stop'

Add-Type -ReferencedAssemblies System.Drawing,System.Windows.Forms -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class NeutralForm : Form
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

    public TextBox Box;

    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetActiveWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint attach, uint attachTo, bool fAttach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

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

    public NeutralForm()
    {
        Text = "NeutralCheck";
        Size = new Size(420, 220);
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        Box = new TextBox { Multiline = true, Dock = DockStyle.Fill, Font = new Font("Microsoft YaHei UI", 12F) };
        Controls.Add(Box);
    }

    static INPUT UKey(char c, uint flags) {
        var i = new INPUT(); i.type = 1; i.u.ki.wVk = 0; i.u.ki.wScan = c; i.u.ki.dwFlags = flags; return i;
    }

    // the shipped keyfix pattern: after each trigger char append X + VK_BACK, one batch
    public void InjectFlush()          // harmless shift tap to push pending injected input through
    {
        var ins = new INPUT[2];
        ins[0].type = 1; ins[0].u.ki.wVk = 0x10;
        ins[1].type = 1; ins[1].u.ki.wVk = 0x10; ins[1].u.ki.dwFlags = 0x2;
        SendInput(2, ins, Marshal.SizeOf(typeof(INPUT)));
    }

    public bool IsForeground() { return GetForegroundWindow() == Handle; }

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
                ins[n++] = new INPUT { type = 1 }; ins[n - 1].u.ki.wVk = 0x08;
                ins[n++] = new INPUT { type = 1 }; ins[n - 1].u.ki.wVk = 0x08; ins[n - 1].u.ki.dwFlags = 0x2;
            }
        }
        if (SendInput((uint)n, ins, Marshal.SizeOf(typeof(INPUT))) != n)
            throw new InvalidOperationException("SendInput failed");
    }
}

public static class NeutralCheck
{
    public static string Run()
    {
        var f = new NeutralForm();
        f.Show();
        Application.DoEvents();
        f.ForceForeground();
        f.Box.Focus();
        Application.DoEvents();
        System.Threading.Thread.Sleep(400);
        Application.DoEvents();

        var log = new System.Text.StringBuilder();
        string COMMA = new string((char)0xFF0C, 1);   // fullwidth comma
        string NI = new string((char)0x4F60, 1);
        string HAO = new string((char)0x597D, 1);
        string[] batches = { COMMA, NI + HAO, NI + COMMA + HAO, "abc" };
        foreach (string b in batches) {
            if (!f.IsForeground()) { log.AppendLine("!! lost foreground before batch, re-forcing"); f.ForceForeground(); f.Box.Focus(); Application.DoEvents(); System.Threading.Thread.Sleep(200); }
            f.InjectFixed(b);
            System.Threading.Thread.Sleep(150); Application.DoEvents();
        }
        f.InjectFlush();   // same-thread injection is delivered one SendInput late: flush the last batch
        System.Threading.Thread.Sleep(150); Application.DoEvents();
        f.InjectFlush();

        // pump a fixed 3s: same-thread injected input arrives with a long lag, stability heuristics get fooled
        for (int i = 0; i < 60; i++) { Application.DoEvents(); System.Threading.Thread.Sleep(50); }
        log.AppendLine("foreground at end: " + f.IsForeground());
        string s = f.Box.Text;
        f.Close();
        return log.ToString() + "|" + s;
    }
}
'@

$raw = [NeutralCheck]::Run()
$sep = $raw.IndexOf('|')
$dbg = $raw.Substring(0, $sep)
$got = $raw.Substring($sep + 1)
Write-Output $dbg
$COMMA = [string][char]0xFF0C
$NIHAO = [string][char]0x4F60 + [char]0x597D
$want  = $COMMA + $NIHAO + ([string][char]0x4F60) + $COMMA + ([string][char]0x597D) + "abc"

Write-Output ("got  bytes: " + ([BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes($got))))
Write-Output ("want bytes: " + ([BitConverter]::ToString([Text.Encoding]::Unicode.GetBytes($want))))
Write-Output ("length: " + $got.Length + " (want " + $want.Length + ")")
if ($got -ceq $want) { Write-Output "PASS  keyfix pattern is self-neutralizing in a normal control (no stray X, no lost chars)" }
else { Write-Output "FAIL  pattern NOT neutral in a normal control"; exit 1 }
