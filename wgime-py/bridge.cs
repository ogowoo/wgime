// wgime-py bridge: Win32 interop layer compiled at runtime via CodeDom (.NET Framework 4.x).
// Python owns all IME logic; this layer owns: keyboard hook, SendInput, caret-follow candidate bar.
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WgBridge
{
public class KeyEvt : EventArgs { public int Vk; public bool Down; public bool Swallow; }

// 钩子的实时判定层: C# 内只做 "激活 && 相关键 -> 吞掉并入队", 不跨 Python/GIL
public static class ImeBus
{
    public static volatile bool Active;
    public static readonly System.Collections.Concurrent.ConcurrentQueue<KeyEvt> Q = new System.Collections.Concurrent.ConcurrentQueue<KeyEvt>();
    public static KeyEvt Next() { KeyEvt e; return Q.TryDequeue(out e) ? e : null; }
    public static bool IsImeKey(int vk)
    {
        if (vk >= 0x41 && vk <= 0x5A) return true;   // A-Z
        if (vk >= 0x30 && vk <= 0x39) return true;   // 0-9
        return vk == 0x20 || vk == 0x08 || vk == 0x1B || vk == 0x0D || vk == 0xBD || vk == 0xBB
            || vk == 0xDB || vk == 0xDD;             // space back esc enter - = [ ]
    }
    public const int VK_TOGGLE = 0x77;               // F8 (硬开关)
    public const int VK_TAP = 0xF8;                  // 合成: Shift 轻拍 (中/英切换)
    public const int VK_MODE = 0xF9;                 // 合成: Ctrl+` (模式循环)
    public const int VK_TRAD = 0xFA;                 // 合成: Ctrl+Shift+F (繁简)
}

public class KeyHook
{
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hInstance, int threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr idHook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr idHook, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    IntPtr hhook = IntPtr.Zero;
    HookProc del;                                        // 防 GC 回收
    DateTime shiftDownAt = DateTime.MinValue;
    bool dirtySinceShift = true;                         // shift 按下后有其它键介入 -> 不算轻拍

    public void Install()                                // 必须在将跑消息循环的线程上调用
    {
        del = Proc;
        hhook = SetWindowsHookEx(13, del, IntPtr.Zero, 0);   // WH_KEYBOARD_LL, hMod 必须 NULL
    }
    public void Uninstall() { if (hhook != IntPtr.Zero) { UnhookWindowsHookEx(hhook); hhook = IntPtr.Zero; } }
    IntPtr Proc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0) {
            int m = wParam.ToInt32();
            int vk = Marshal.ReadInt32(lParam);
            bool down = (m == 0x100 || m == 0x104);
            if (down) {
                // Ctrl+` 模式循环 / Ctrl+Shift+F 繁简 (组合键, 吞掉)
                bool ctrl = (GetKeyState(0x11) & 0x8000) != 0;
                bool shift = (GetKeyState(0x10) & 0x8000) != 0;
                if (ctrl && vk == 0xC0) { ImeBus.Q.Enqueue(new KeyEvt { Vk = ImeBus.VK_MODE, Down = true }); dirtySinceShift = true; return (IntPtr)1; }
                if (ctrl && shift && vk == 0x46) { ImeBus.Q.Enqueue(new KeyEvt { Vk = ImeBus.VK_TRAD, Down = true }); dirtySinceShift = true; return (IntPtr)1; }
                if (vk == 0xA0 || vk == 0xA1) { shiftDownAt = DateTime.Now; dirtySinceShift = false; }
                else if (vk == ImeBus.VK_TOGGLE) { ImeBus.Q.Enqueue(new KeyEvt { Vk = vk, Down = true }); dirtySinceShift = true; return (IntPtr)1; }
                else {
                    if (shiftDownAt != DateTime.MinValue) dirtySinceShift = true;
                    if (ImeBus.Active && ImeBus.IsImeKey(vk)) {
                        ImeBus.Q.Enqueue(new KeyEvt { Vk = vk, Down = true });
                        return (IntPtr)1;                // 吞键
                    }
                }
            } else if (m == 0x101 || m == 0x105) {       // keyup: Shift 轻拍检测
                if ((vk == 0xA0 || vk == 0xA1) && !dirtySinceShift && shiftDownAt != DateTime.MinValue
                    && (DateTime.Now - shiftDownAt).TotalMilliseconds < 400) {
                    ImeBus.Q.Enqueue(new KeyEvt { Vk = ImeBus.VK_TAP, Down = true });
                }
                if (vk == 0xA0 || vk == 0xA1) shiftDownAt = DateTime.MinValue;
            }
        }
        return CallNextHookEx(hhook, nCode, wParam, lParam);
    }
    public static void Pump() { Application.Run(); }     // 钩子线程的消息泵
}

public static class Injector
{
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int max);
    public static string ForegroundInfo()
    {
        var h = GetForegroundWindow();
        var sb = new System.Text.StringBuilder(256);
        GetClassName(h, sb, 256);
        return h.ToString("X") + ":" + sb;
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }  // x64: 4+4pad+24+8 = 40 = sizeof(INPUT)
    public static uint Text(string s)
    {
        var arr = new INPUT[s.Length * 2];
        for (int i = 0; i < s.Length; i++) {
            arr[2 * i].type = 1; arr[2 * i].ki.wScan = s[i]; arr[2 * i].ki.dwFlags = 0x4;              // UNICODE down
            arr[2 * i + 1].type = 1; arr[2 * i + 1].ki.wScan = s[i]; arr[2 * i + 1].ki.dwFlags = 0x4 | 0x2; // up
        }
        return SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Backspaces(int n)
    {
        var arr = new INPUT[n * 2];
        for (int i = 0; i < n; i++) {
            arr[2 * i].type = 1; arr[2 * i].ki.wVk = 0x08; arr[2 * i].ki.dwFlags = 0;
            arr[2 * i + 1].type = 1; arr[2 * i + 1].ki.wVk = 0x08; arr[2 * i + 1].ki.dwFlags = 0x2;
        }
        SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
    }
}

// 候选条: 无边框置顶圆角, 跟随前台光标 (GUIThreadInfo)
public class CandForm : Form
{
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint idThread, ref GUITHREADINFO g);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int cx, int cy);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] struct GUITHREADINFO { public int cbSize; public uint flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret; public RECT rcCaret; }

    string head = "";                                      // 模式标签, 如 [拼音]
    string code = "";
    string[] cands = new string[0];
    int sel = 0;
    Font fCode, fCand;

    public CandForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        TopMost = true; ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        BackColor = Color.White;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint, true);
        fCode = new Font("Microsoft YaHei UI", 8.5F, FontStyle.Regular, GraphicsUnit.Point);
        fCand = new Font("Microsoft YaHei UI", 10.5F, FontStyle.Regular, GraphicsUnit.Point);
        HandleCreated += delegate { try { SetWindowRgn(Handle, CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 14, 14), true); } catch {} };
        Resize += delegate { try { if (IsHandleCreated) SetWindowRgn(Handle, CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 14, 14), true); } catch {} };
    }
    protected override bool ShowWithoutActivation { get { return true; } }   // 不抢焦点
    protected override CreateParams CreateParams {
        get {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x80 | 0x8 | 0x8000000;   // TOOLWINDOW | TOPMOST | NOACTIVATE
            return cp;
        }
    }

    public void ShowCands(string head, string code, string[] cands, int sel)
    {
        if (InvokeRequired) { BeginInvoke(new Action<string, string, string[], int>(ShowCands), head, code, cands, sel); return; }
        this.head = head; this.code = code; this.cands = cands; this.sel = sel;
        LocateCaret();
        Measure();
        Invalidate();
        if (!Visible) Show();
    }
    public void HideBar()
    {
        if (InvokeRequired) { BeginInvoke(new Action(HideBar)); return; }
        if (Visible) Hide();
    }
    void Measure()
    {
        using (var g = CreateGraphics()) {
            int w = 20 + (int)g.MeasureString(head + code, fCode).Width;
            for (int i = 0; i < cands.Length; i++) w += (int)g.MeasureString((i + 1) + "." + cands[i], fCand).Width + 16;
            Size = new Size(Math.Max(w, 90), 56);
        }
    }
    void LocateCaret()
    {
        try {
            var fg = GetForegroundWindow();
            uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
            var g = new GUITHREADINFO(); g.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
            if (GetGUIThreadInfo(tid, ref g) && g.hwndCaret != IntPtr.Zero) {
                var p = new POINT { x = g.rcCaret.left, y = g.rcCaret.bottom };
                ClientToScreen(g.hwndCaret, ref p);
                Location = new Point(p.x, p.y + 6);
                return;
            }
        } catch {}
        var wa = Screen.PrimaryScreen.WorkingArea;
        Location = new Point(wa.X + (wa.Width - Width) / 2, wa.Bottom - 160);   // 兜底: 屏幕底部居中
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
        using (var pen = new Pen(Color.FromArgb(255, 195, 204, 221), 1))
        using (var path = Round(new Rectangle(0, 0, Width - 1, Height - 1), 7)) g.DrawPath(pen, path);
        using (var br = new SolidBrush(Color.FromArgb(255, 0, 122, 255)))
            g.DrawString(head, fCode, br, 10, 6);
        int hw = string.IsNullOrEmpty(head) ? 0 : (int)g.MeasureString(head, fCode).Width;
        g.DrawString(code, fCode, Brushes.Gray, 10 + hw, 6);
        int x = 10;
        for (int i = 0; i < cands.Length; i++) {
            string s = (i + 1) + "." + cands[i];
            int w = (int)g.MeasureString(s, fCand).Width + 12;
            if (i == sel) {
                using (var path = Round(new Rectangle(x - 4, 24, w + 4, 26), 6))
                using (var br = new SolidBrush(Color.FromArgb(255, 0, 122, 255))) g.FillPath(br, path);
                g.DrawString(s, fCand, Brushes.White, x + 2, 27);
            } else {
                g.DrawString(s, fCand, Brushes.Black, x + 2, 27);
            }
            x += w + 8;
        }
    }
    static GraphicsPath Round(Rectangle r, int rad)
    {
        var p = new GraphicsPath();
        int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure(); return p;
    }
}
}
