// wgime-py bridge: Win32 interop layer compiled at runtime via CodeDom (.NET Framework 4.x).
// Python owns all IME logic; this layer owns: keyboard hook, SendInput, caret-follow candidate bar.
using System;
using System.Collections.Generic;
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
    public static volatile bool SemiAsCode;              // 微软双拼: ; 作 ing 码
    public static readonly System.Collections.Concurrent.ConcurrentQueue<KeyEvt> Q = new System.Collections.Concurrent.ConcurrentQueue<KeyEvt>();
    public static KeyEvt Next() { KeyEvt e; return Q.TryDequeue(out e) ? e : null; }
    public static bool IsImeKey(int vk)
    {
        if (vk >= 0x41 && vk <= 0x5A) return true;   // A-Z
        if (vk >= 0x30 && vk <= 0x39) return true;   // 0-9
        return vk == 0x20 || vk == 0x08 || vk == 0x1B || vk == 0x0D || vk == 0xBD || vk == 0xBB
            || vk == 0xDB || vk == 0xDD              // space back esc enter - = [ ]
            || (vk == 0xBA && SemiAsCode);           // ; (仅微软双拼)
    }
    public const int VK_TOGGLE = 0x77;               // F8 (硬开关)
    public const int VK_TAP = 0xF8;                  // 合成: Shift 轻拍 (中/英切换)
    public const int VK_MODE = 0xF9;                 // 合成: Ctrl+` (模式循环)
    public const int VK_TRAD = 0xFA;                 // 合成: Ctrl+Shift+F (繁简)
    public const int VK_MAKEWORD = 0xFB;             // 合成: Ctrl+Alt+C (剪贴板造词)
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
            int flags = Marshal.ReadInt32(lParam, 8);
            IntPtr extra = Marshal.ReadIntPtr(lParam, 16);
            if ((flags & 0x10) != 0 && extra == Injector.MAGIC)       // 自家注入: 放行不处理 (LLKHF_INJECTED)
                return CallNextHookEx(hhook, nCode, wParam, lParam);
            int m = wParam.ToInt32();
            int vk = Marshal.ReadInt32(lParam);
            bool down = (m == 0x100 || m == 0x104);
            if (down) {
                // Ctrl+` 模式循环 / Ctrl+Shift+F 繁简 (组合键, 吞掉)
                bool ctrl = (GetKeyState(0x11) & 0x8000) != 0;
                bool shift = (GetKeyState(0x10) & 0x8000) != 0;
                bool alt = (GetKeyState(0x12) & 0x8000) != 0;
                if (ctrl && vk == 0xC0) { ImeBus.Q.Enqueue(new KeyEvt { Vk = ImeBus.VK_MODE, Down = true }); dirtySinceShift = true; return (IntPtr)1; }
                if (ctrl && shift && vk == 0x46) { ImeBus.Q.Enqueue(new KeyEvt { Vk = ImeBus.VK_TRAD, Down = true }); dirtySinceShift = true; return (IntPtr)1; }
                if (ctrl && alt && vk == 0x43) { ImeBus.Q.Enqueue(new KeyEvt { Vk = ImeBus.VK_MAKEWORD, Down = true }); dirtySinceShift = true; return (IntPtr)1; }
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
    public static string ClipboardText()           // STA 安全 (任意线程可调)
    {
        string t = null;
        var th = new System.Threading.Thread(delegate() { try { t = Clipboard.GetText(); } catch {} });
        th.SetApartmentState(System.Threading.ApartmentState.STA);
        th.Start();
        th.Join(1500);
        return t;
    }
    public static void SetClipboardText(string s)  // STA 安全
    {
        var th = new System.Threading.Thread(delegate() { try { Clipboard.SetText(s); } catch {} });
        th.SetApartmentState(System.Threading.ApartmentState.STA);
        th.Start();
        th.Join(1500);
    }

    // ---------- 提权检测 (UIPI: 向管理员窗口注入需要剪贴板粘贴) ----------
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr tok);
    [DllImport("advapi32.dll")] static extern bool GetTokenInformation(IntPtr tok, int cls, out int info, int len, out int retLen);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    public static bool SelfElevated()
    {
        try {
            using (var id = System.Security.Principal.WindowsIdentity.GetCurrent())
                return new System.Security.Principal.WindowsPrincipal(id).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
        } catch { return false; }
    }
    public static bool ForegroundElevated()
    {
        try {
            int pid;
            GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            IntPtr h = OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return false;
            try {
                IntPtr tok;
                if (!OpenProcessToken(h, 0x8, out tok)) return false;
                try {
                    int elev, size;
                    return GetTokenInformation(tok, 20, out elev, 4, out size) && elev != 0;   // TokenElevation
                } finally { CloseHandle(tok); }
            } finally { CloseHandle(h); }
        } catch { return false; }
    }
    public static string ForegroundProcessName()
    {
        try {
            int pid;
            GetWindowThreadProcessId(GetForegroundWindow(), out pid);
            using (var p = System.Diagnostics.Process.GetProcessById(pid)) return p.ProcessName.ToLower();
        } catch { return ""; }
    }

    // ---------- Qt stale-char fix (微信4.x 等全角标点后吞下一字符: X 吸收 + Back 擦除) ----------
    static bool StaleTrigger(char c)
    {
        if (c < 0x3000) return false;
        if (c >= 0x4E00 && c <= 0x9FFF) return false;
        if (c >= 0x3400 && c <= 0x4DBF) return false;
        if (c >= 0xF900 && c <= 0xFAFF) return false;
        return true;
    }
    public static uint TextQtFix(string s)
    {
        var list = new List<INPUT>();
        foreach (char c in s) {
            INPUT d = new INPUT(), u = new INPUT();
            d.type = 1; d.ki.wScan = c; d.ki.dwFlags = 0x4;
            u.type = 1; u.ki.wScan = c; u.ki.dwFlags = 0x4 | 0x2;
            list.Add(d); list.Add(u);
            if (StaleTrigger(c)) {
                INPUT xd = new INPUT(), xu = new INPUT(), bd = new INPUT(), bu = new INPUT();
                xd.type = 1; xd.ki.wScan = 'X'; xd.ki.dwFlags = 0x4;
                xu.type = 1; xu.ki.wScan = 'X'; xu.ki.dwFlags = 0x4 | 0x2;
                bd.type = 1; bd.ki.wVk = 0x08;
                bu.type = 1; bu.ki.wVk = 0x08; bu.ki.dwFlags = 0x2;
                list.Add(xd); list.Add(xu); list.Add(bd); list.Add(bu);
            }
        }
        if (list.Count == 0) return 0;
        for (int i = 0; i < list.Count; i++) { var e = list[i]; e.ki.extra = MAGIC; list[i] = e; }
        return SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(INPUT)));
    }

    // ---------- 剪贴板粘贴上屏 (提权窗口回退; 保存/恢复原剪贴板) ----------
    public static void Paste(string text)
    {
        string prev = ClipboardText();
        if (prev != null && prev.Length == 0) prev = null;   // 空原文不恢复
        SetClipboardText(text);
        System.Threading.Thread.Sleep(60);                   // 让剪贴板监视器读完
        var ins = new INPUT[4];
        for (int i = 0; i < 4; i++) { ins[i].type = 1; ins[i].ki.extra = MAGIC; }
        ins[0].ki.wVk = 0x11; ins[1].ki.wVk = 0x56;
        ins[2].ki.wVk = 0x56; ins[2].ki.dwFlags = 2;
        ins[3].ki.wVk = 0x11; ins[3].ki.dwFlags = 2;
        SendInput(4, ins, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(150);
        if (prev != null) {
            var t = new System.Threading.Thread(delegate() {
                System.Threading.Thread.Sleep(300);
                try { if (ClipboardText() == text) SetClipboardText(prev); } catch {}
            });
            t.IsBackground = true;
            t.Start();
        }
    }
    [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public KEYBDINPUT ki; public long pad; }  // x64: 4+4pad+24+8 = 40 = sizeof(INPUT)
    public static readonly IntPtr MAGIC = new IntPtr(0x5747494D);   // 'WGIM': 自家注入事件的 dwExtraInfo 标记 (钩子据此放行)
    public static uint Text(string s)
    {
        var arr = new INPUT[s.Length * 2];
        for (int i = 0; i < s.Length; i++) {
            arr[2 * i].type = 1; arr[2 * i].ki.wScan = s[i]; arr[2 * i].ki.dwFlags = 0x4;              // UNICODE down
            arr[2 * i + 1].type = 1; arr[2 * i + 1].ki.wScan = s[i]; arr[2 * i + 1].ki.dwFlags = 0x4 | 0x2; // up
            arr[2 * i].ki.extra = MAGIC; arr[2 * i + 1].ki.extra = MAGIC;
        }
        return SendInput((uint)arr.Length, arr, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void Backspaces(int n)
    {
        var arr = new INPUT[n * 2];
        for (int i = 0; i < n; i++) {
            arr[2 * i].type = 1; arr[2 * i].ki.wVk = 0x08; arr[2 * i].ki.dwFlags = 0;
            arr[2 * i + 1].type = 1; arr[2 * i + 1].ki.wVk = 0x08; arr[2 * i + 1].ki.dwFlags = 0x2;
            arr[2 * i].ki.extra = MAGIC; arr[2 * i + 1].ki.extra = MAGIC;
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
