# ============================================================
#  WgTray - tray-only toolbox (NO IME): taskbar tray menu +
#  tools.txt toolbox + plugins\*.txt + config.txt apps
#  ps1 bootstrap -> load embedded prebuilt DLL payload
#  Errors are logged to %TEMP%\WgTray_error.log
#  Usage:
#    powershell -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File WgTray.ps1
# ============================================================
$env:WGTRAY_PATH = $PSCommandPath
$env:WGTRAY_DIR = $PSScriptRoot + '\'
# If this script's console is VISIBLE (right-click "Run with PowerShell",
# bare -File from a terminal), relaunch ourselves with a hidden console
# and exit - the visible window never stays around. When already started
# hidden (scheduled task / install.bat) IsWindowVisible is False and this
# whole block is skipped, so no extra process is spawned. The child is
# launched with -WindowStyle Hidden (its console is born hidden), and the
# WGHIDE env var guards against any recursion.
if ($env:WGHIDE -ne '1') {
    try {
        Add-Type -Name WgHide -Namespace Wg -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint uFlags);' -ErrorAction Stop
        $hw = [Wg.WgHide]::GetConsoleWindow()
        if ($hw -ne [IntPtr]::Zero -and [Wg.WgHide]::IsWindowVisible($hw)) {
            $env:WGHIDE = '1'
            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-NoLogo','-STA','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',('"' + $PSCommandPath + '"') -WindowStyle Hidden | Out-Null
            [Wg.WgHide]::ShowWindow($hw, 0) | Out-Null
            [Wg.WgHide]::ShowWindow($hw, 0) | Out-Null
            [Wg.WgHide]::SetWindowPos($hw, [IntPtr]::Zero, 0, 0, 0, 0, 0x0087) | Out-Null
            exit
        }
    } catch {}
}
# ================= WgTray bootstrap: extract embedded C# / DLL payload =================
$wgLog = Join-Path $env:TEMP 'WgTray_error.log'
function WgLog([string]$m) { try {
    if (Test-Path $wgLog) { $len = (Get-Item $wgLog).Length; if ($len -gt 1MB) { Move-Item $wgLog ($wgLog + '.old') -Force -ErrorAction SilentlyContinue } }
    [IO.File]::AppendAllText($wgLog, ("[{0}] {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m), [Text.Encoding]::UTF8)
} catch {} }
WgLog "---- WgTray starting ----"
WgLog ("OS: " + [Environment]::OSVersion.VersionString + " 64bit:" + [Environment]::Is64BitOperatingSystem)
WgLog ("PS: " + $PSVersionTable.PSVersion.ToString() + " CLR: " + $PSVersionTable.CLRVersion.ToString())
WgLog ("LanguageMode: " + $ExecutionContext.SessionState.LanguageMode)
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
WgLog "WinForms assemblies loaded"

# ---- embedded C# (tray-only, no IME) ----
$cs = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
// ===================== WgTray: 托盘工具箱 (无输入法) =====================
// 没有输入法功能: 只有任务栏托盘菜单 + tools.txt 工具箱 + plugins 插件 + config.txt 应用。
// 由 build-wgtray.ps1 从 wgime.bat 的内嵌 C# 切分生成 (工具箱/插件/内置工具部分原样复用)。
public class TrayApp
{
    static readonly bool Zh = System.Globalization.CultureInfo.CurrentUICulture.Name.StartsWith("zh");
    static string L(string zh, string en) { return Zh ? zh : en; }

    public static string DataDir;                                   // %LOCALAPPDATA%\wgime (与 WgIme 共用, 插件/便签/禁用记录互通)
    public static string BatDir;                                    // wgtray.bat 所在目录 (tools.txt / plugins / config.txt 在这里)
    public static string BatPath;                                   // wgtray.bat 自身全路径
    public static NotifyIcon trayRef;                               // 工具步骤 msg 气泡的目标

    // ---------- 托盘图标: 圆角方块 + 挖空"工"字 ----------
    static System.Drawing.Drawing2D.GraphicsPath RoundedRect(RectangleF r, float rad)
    {
        var p = new System.Drawing.Drawing2D.GraphicsPath();
        float d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    static Icon MakeIcon(string ch, Color c)
    {
        const int S = 64;
        using (var bmp = new Bitmap(S, S)) {
            using (var g = Graphics.FromImage(bmp)) {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (var path = RoundedRect(new RectangleF(0, 0, S, S), 14))
                using (var br = new SolidBrush(c)) g.FillPath(br, path);
                using (var gp = new System.Drawing.Drawing2D.GraphicsPath())
                using (var f = new Font("Microsoft YaHei UI", 52, FontStyle.Regular, GraphicsUnit.Pixel)) {
                    var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                    gp.AddString(ch, f.FontFamily, (int)FontStyle.Regular, 52, new RectangleF(0, 0, S, S), sf);
                    g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                    using (var tb = new SolidBrush(Color.Transparent)) g.FillPath(tb, gp);
                }
            }
            return Icon.FromHandle(bmp.GetHicon());
        }
    }

    // ---------- 托盘菜单 ----------
    ContextMenuStrip menu;
    ToolStripMenuItem miApps, miPlugins;                    // 动态子菜单 (config 应用 / 插件)
    ToolStripMenuItem[] hotItems = new ToolStripMenuItem[3];        // 全局快捷键信息行 (只读)
    NotifyIcon tray;
    HotKeyHost hkHost;                                              // 全局快捷键宿主窗口

    static uint HotToolboxMod, HotToolboxVk;                        // config.txt hotkey_toolbox (0,0 = 禁用)
    static uint HotPluginsMod, HotPluginsVk;                        // hotkey_plugins
    static uint HotMenuMod, HotMenuVk;                              // hotkey_menu (在光标处显示托盘菜单)

    static void TrayTip(string title, string text, ToolTipIcon icon) { try { trayRef.ShowBalloonTip(2600, title, text, icon); } catch {} }

    // 隐藏的 UI 线程控件: 工具步骤/插件的 confirm 弹窗通过它 Invoke 回 UI 线程
    // (TrayApp 不是 Form, 不像原 WordBoard 能直接传 this); 同时兼任全局快捷键宿主
    // (RegisterHotKey 需要窗口句柄接收 WM_HOTKEY)
    static HotKeyHost uiInvoker;
    static Control Ui()
    {
        try { if (uiInvoker == null || uiInvoker.IsDisposed) { uiInvoker = new HotKeyHost(); IntPtr h = uiInvoker.Handle; } } catch {}
        return uiInvoker;
    }

    class HotKeyHost : Control
    {
        public Action<int> OnHotKey;
        readonly Dictionary<int, bool> reg = new Dictionary<int, bool>();
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        public void Reg(int id, uint mod, uint vk)
        {
            if (!IsHandleCreated) return;
            bool ok = false;
            try { ok = RegisterHotKey(Handle, id, mod, vk); } catch {}
            reg[id] = ok;
        }
        public void Unreg(int id)
        {
            if (IsHandleCreated && reg.ContainsKey(id) && reg[id]) { try { UnregisterHotKey(Handle, id); } catch {} reg[id] = false; }
        }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x0312 && OnHotKey != null) {              // WM_HOTKEY
                OnHotKey(m.WParam.ToInt32());
            }
            base.WndProc(ref m);
        }
    }

    // ---------- 全局快捷键: config.txt 的 hotkey_* 键, 格式 ctrl+alt+t (none/off/空 = 禁用) ----------
    static bool ParseHotkey(string spec, out uint mod, out uint vk)
    {
        mod = 0; vk = 0;
        if (string.IsNullOrWhiteSpace(spec)) return false;
        string[] parts = spec.ToLower().Split('+');
        string key = parts[parts.Length - 1].Trim();
        for (int i = 0; i < parts.Length - 1; i++) {
            string m = parts[i].Trim();
            if (m == "ctrl" || m == "control") mod |= 0x2;
            else if (m == "alt") mod |= 0x1;
            else if (m == "shift") mod |= 0x4;
            else if (m == "win" || m == "cmd" || m == "meta") mod |= 0x8;
            else return false;
        }
        if (key.Length == 1 && key[0] >= 'a' && key[0] <= 'z') vk = (uint)(key[0] - 'a' + 0x41);
        else if (key.Length == 1 && key[0] >= '0' && key[0] <= '9') vk = (uint)(key[0] - '0' + 0x30);
        else {
            string[] names = { "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" };
            int fi = Array.IndexOf(names, key);
            if (fi >= 0) vk = (uint)(0x70 + fi);
            else switch (key) {
                case "space": vk = 0x20; break;
                case "enter": vk = 0x0D; break;
                case "esc": vk = 0x1B; break;
                case "backspace": vk = 0x08; break;
                case "tab": vk = 0x09; break;
                case "grave": vk = 0xC0; break;
                case "minus": vk = 0xBD; break;
                case "plus": vk = 0xBB; break;
                case "lbracket": vk = 0xDB; break;
                case "rbracket": vk = 0xDD; break;
                case "semicolon": vk = 0xBA; break;
                case "quote": vk = 0xDE; break;
                case "comma": vk = 0xBC; break;
                case "period": vk = 0xBE; break;
                case "slash": vk = 0xBF; break;
                case "backslash": vk = 0xDC; break;
                case "pgup": vk = 0x21; break;
                case "pgdn": vk = 0x22; break;
                case "home": vk = 0x24; break;
                case "end": vk = 0x23; break;
                case "left": vk = 0x25; break;
                case "right": vk = 0x27; break;
                case "up": vk = 0x26; break;
                case "down": vk = 0x28; break;
                default: return false;
            }
        }
        return mod != 0;                                            // RegisterHotKey 要求至少一个修饰键
    }
    static string HotkeyText(uint mod, uint vk)
    {
        if (mod == 0 && vk == 0) return L("(未设置)", "(none)");
        var sb = new StringBuilder();
        if ((mod & 0x2) != 0) sb.Append("Ctrl+");
        if ((mod & 0x1) != 0) sb.Append("Alt+");
        if ((mod & 0x4) != 0) sb.Append("Shift+");
        if ((mod & 0x8) != 0) sb.Append("Win+");
        if (vk >= 0x41 && vk <= 0x5A) sb.Append((char)('a' + vk - 0x41));
        else if (vk >= 0x30 && vk <= 0x39) sb.Append((char)('0' + vk - 0x30));
        else if (vk >= 0x70 && vk <= 0x7B) sb.Append('F').Append(vk - 0x70 + 1);
        else {
            string[] n2 = { "Space", "Enter", "Esc", "Backspace", "Tab", "`", "-", "=", "[", "]", ";", "'", ",", ".", "/", "\\", "PgUp", "PgDn", "Home", "End", "Left", "Right", "Up", "Down" };
            uint[] v2 = { 0x20, 0x0D, 0x1B, 0x08, 0x09, 0xC0, 0xBD, 0xBB, 0xDB, 0xDD, 0xBA, 0xDE, 0xBC, 0xBE, 0xBF, 0xDC, 0x21, 0x22, 0x24, 0x23, 0x25, 0x27, 0x26, 0x28 };
            int ix = Array.IndexOf(v2, vk);
            sb.Append(ix >= 0 ? n2[ix] : "0x" + vk.ToString("X"));
        }
        return sb.ToString();
    }
    void ApplyHotkeys()
    {
        if (hkHost == null) { hkHost = (HotKeyHost)Ui(); if (hkHost != null) hkHost.OnHotKey = HandleHotKey; }
        if (hkHost == null || !hkHost.IsHandleCreated) return;
        hkHost.Unreg(1); hkHost.Unreg(2); hkHost.Unreg(3);
        if (HotToolboxMod != 0 || HotToolboxVk != 0) hkHost.Reg(1, HotToolboxMod, HotToolboxVk);
        if (HotPluginsMod != 0 || HotPluginsVk != 0) hkHost.Reg(2, HotPluginsMod, HotPluginsVk);
        if (HotMenuMod != 0 || HotMenuVk != 0) hkHost.Reg(3, HotMenuMod, HotMenuVk);
    }
    void HandleHotKey(int id)
    {
        try {
            if (id == 1) LaunchApp("itools");
            else if (id == 2) LaunchApp("plugins");
            else if (id == 3) { if (menu != null) menu.Show(Cursor.Position); }
        } catch {}
    }

    // ---------- 应用注册表: 内置 + config.txt 的 app= + 插件 (编码 -> [名称, 命令, 参数]) ----------
    static Dictionary<string,string[]> Apps;

    static string DefaultConfigText()
    {
        return "; WgTray 配置文件 (UTF-8, 与 wgtray.bat 同目录)\r\n"
             + "; app: 托盘菜单 -> 应用 里的条目, 编码<TAB>名称<TAB>命令[<TAB>参数] (分隔符也接受空格, 含空格的命令用引号包住;\r\n"
             + ";      相对路径按 wgtray.bat 所在目录解析, 支持 %环境变量%)\r\n"
             + "; app = np\t记事本\tnotepad.exe\r\n"
             + "; app = gy\t仓库目录\tC:\\Tools\\WgIme\r\n"
             + "; app = bd\t百度\thttps://www.baidu.com\r\n"
             + "; 全局快捷键 (格式: ctrl/alt/shift/win 组合, 如 ctrl+alt+t; none/off 禁用):\r\n"
             + "; hotkey_toolbox = ctrl+alt+t   打开工具箱\r\n"
             + "; hotkey_plugins = ctrl+alt+p   打开插件管理\r\n"
             + "; hotkey_menu    = ctrl+alt+w   在光标处显示托盘菜单\r\n"
             + "; (WgIme 的 fuzzy/paste/keyfix 等输入法配置本工具不使用, 留着不影响)\r\n";
    }

    static void LoadConfig(string dir)
    {
        Apps = new Dictionary<string,string[]>();
        Apps["itools"]  = new string[] { L("工具箱", "Toolbox"), "builtin:tools", "" };         // tools.txt 驱动的多标签工具窗体
        Apps["tools"]   = new string[] { L("工具箱", "Toolbox"), "builtin:tools", "" };
        Apps["net"]     = new string[] { L("网络工具", "Network tools"), "builtin:nettools", "" };
        Apps["wlgj"]    = new string[] { L("网络工具", "Network tools"), "builtin:nettools", "" };
        Apps["clip"]    = new string[] { L("剪贴板历史", "Clipboard history"), "builtin:clip", "" };
        Apps["jlb"]     = new string[] { L("剪贴板历史", "Clipboard history"), "builtin:clip", "" };
        Apps["bj"]      = new string[] { L("便签", "Sticky notes"), "builtin:note", "" };
        Apps["notes"]   = new string[] { L("便签", "Sticky notes"), "builtin:note", "" };
        Apps["ys"]      = new string[] { L("颜色拾取", "Color picker"), "builtin:color", "" };
        Apps["color"]   = new string[] { L("颜色拾取", "Color picker"), "builtin:color", "" };
        Apps["plugins"] = new string[] { L("插件管理", "Plugin manager"), "builtin:pluginmgr", "" };
        Apps["cjgl"]    = new string[] { L("插件管理", "Plugin manager"), "builtin:pluginmgr", "" };
        ParseHotkey("ctrl+alt+t", out HotToolboxMod, out HotToolboxVk);
        ParseHotkey("ctrl+alt+p", out HotPluginsMod, out HotPluginsVk);
        ParseHotkey("ctrl+alt+w", out HotMenuMod, out HotMenuVk);
        try {
            string f = Path.Combine(dir, "config.txt");
            FixLegacyConfigIfBroken(f);
            if (File.Exists(f))
            foreach (string raw in File.ReadAllLines(f, Encoding.UTF8)) {
                string t = raw.Trim();
                if (t.Length == 0 || t[0] == '#' || t[0] == ';') continue;
                int eq = t.IndexOf('=');
                if (eq < 1) continue;
                string k = t.Substring(0, eq).Trim().ToLower();
                string v = t.Substring(eq + 1).Trim();
                if (k == "app") {                                   // 应用条目进托盘菜单 -> 应用
                    var ap = v.Split('\t');
                    string acode = null, aname = null, acmd = null, aargs = "";
                    if (ap.Length >= 3) { acode = ap[0]; aname = ap[1]; acmd = ap[2]; aargs = ap.Length > 3 ? ap[3] : ""; }
                    else {
                        var am = System.Text.RegularExpressions.Regex.Match(v, @"^(\S+)\s+(\S+)\s+(""(?:[^""]*)""|\S+)(?:\s+(.*))?$");
                        if (am.Success) { acode = am.Groups[1].Value; aname = am.Groups[2].Value; acmd = am.Groups[3].Value.Trim('"'); aargs = am.Groups[4].Value; }
                    }
                    if (acode != null) {
                        acode = acode.Trim().ToLower();
                        if (acode.Length > 0) Apps[acode] = new string[] { aname.Trim(), Environment.ExpandEnvironmentVariables(acmd.Trim()), Environment.ExpandEnvironmentVariables(aargs.Trim()) };
                    }
                }
                else if (k == "hotkey_toolbox") { if (!ParseHotkey(v, out HotToolboxMod, out HotToolboxVk)) { HotToolboxMod = 0; HotToolboxVk = 0; } }
                else if (k == "hotkey_plugins") { if (!ParseHotkey(v, out HotPluginsMod, out HotPluginsVk)) { HotPluginsMod = 0; HotPluginsVk = 0; } }
                else if (k == "hotkey_menu") { if (!ParseHotkey(v, out HotMenuMod, out HotMenuVk)) { HotMenuMod = 0; HotMenuVk = 0; } }
                // 其它键 (fuzzy/paste/keyfix/...) 是输入法专属: 本工具忽略, 不报错 (配置完全兼容)
            }
        } catch {}
        LoadDisabledPlugins();
        LoadPlugins(dir);                                           // plugins\*.txt -> 应用编码 (插件最后注册: 编码冲突时插件优先)
        string[] calcPlugin;
        if (Apps.TryGetValue("jsq", out calcPlugin)) Apps["calc"] = calcPlugin;   // 别名: 计算器在 plugins\calc.txt
    }

    void ReloadConfig()
    {
        LoadConfig(BatDir);
        LoadTools(BatDir);
        string f = Path.Combine(BatDir, "config.txt");
        if (!File.Exists(f)) { try { File.WriteAllText(f, DefaultConfigText(), new UTF8Encoding(false)); } catch {} }
        ApplyHotkeys();
        RebuildTrayMenu();
        RefreshMenuChecks();
    }

    void OpenConfigFile() { try { Process.Start(new ProcessStartInfo { FileName = Path.Combine(BatDir, "config.txt"), UseShellExecute = true }); } catch {} }
    void OpenDataDir()    { try { Process.Start(new ProcessStartInfo { FileName = DataDir, UseShellExecute = true }); } catch {} }

    // ---------- 托盘菜单 ----------
    void BuildMenu()
    {
        menu = new ContextMenuStrip();
        menu.Items.Add(L("工具箱…", "Toolbox…"), null, delegate { LaunchApp("itools"); });
        menu.Items.Add(new ToolStripSeparator());

        miPlugins = new ToolStripMenuItem(L("插件", "Plugins"));
        menu.Items.Add(miPlugins);

        var mTools = new ToolStripMenuItem(L("内置工具", "Built-in tools"));
        mTools.DropDownItems.Add(L("计算器", "Calculator"), null, delegate { LaunchApp("jsq"); });
        mTools.DropDownItems.Add(L("网络工具", "Network tools"), null, delegate { LaunchApp("net"); });
        mTools.DropDownItems.Add(L("剪贴板历史", "Clipboard history"), null, delegate { LaunchApp("clip"); });
        mTools.DropDownItems.Add(L("便签", "Sticky notes"), null, delegate { LaunchApp("bj"); });
        mTools.DropDownItems.Add(L("颜色拾取", "Color picker"), null, delegate { LaunchApp("ys"); });
        menu.Items.Add(mTools);

        miApps = new ToolStripMenuItem(L("应用 (config.txt)", "Apps (config.txt)"));
        menu.Items.Add(miApps);

        var mCfg = new ToolStripMenuItem(L("配置", "Config"));
        mCfg.DropDownItems.Add(L("编辑配置 (config.txt)…", "Edit config (config.txt)…"), null, delegate { OpenConfigFile(); });
        mCfg.DropDownItems.Add(L("重载配置", "Reload config"), null, delegate { ReloadConfig(); });
        mCfg.DropDownItems.Add(L("数据目录…", "Data folder…"), null, delegate { OpenDataDir(); });
        menu.Items.Add(mCfg);

        var mHot = new ToolStripMenuItem(L("全局快捷键", "Global hotkeys"));
        for (int i = 0; i < 3; i++) { hotItems[i] = new ToolStripMenuItem(); hotItems[i].Enabled = false; mHot.DropDownItems.Add(hotItems[i]); }
        mHot.DropDownItems.Add(new ToolStripSeparator());
        var mHotHint = new ToolStripMenuItem(L("在 config.txt 的 hotkey_* 键修改 (none 禁用)", "edit hotkey_* keys in config.txt (none to disable)"));
        mHotHint.Enabled = false;
        mHot.DropDownItems.Add(mHotHint);
        menu.Items.Add(mHot);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("退出", "Exit"), null, delegate { Application.Exit(); });
        menu.Opening += delegate { RefreshMenuChecks(); };
        tray.ContextMenuStrip = menu;
        RebuildTrayMenu();
        RefreshMenuChecks();
    }

    void RefreshMenuChecks()                                        // 菜单弹出时同步: 开机自启勾选 + 快捷键显示
    {
        if (hotItems != null && hotItems.Length == 3 && hotItems[0] != null) {   // BuildMenu 之前 hotItems 是空位
            hotItems[0].Text = L("打开工具箱", "Open toolbox") + ":  " + HotkeyText(HotToolboxMod, HotToolboxVk);
            hotItems[1].Text = L("插件管理", "Plugin manager") + ":  " + HotkeyText(HotPluginsMod, HotPluginsVk);
            hotItems[2].Text = L("显示托盘菜单", "Show tray menu") + ":  " + HotkeyText(HotMenuMod, HotMenuVk);
        }
    }

    void RebuildTrayMenu()                                          // 插件 / 应用子菜单随配置重载重建
    {
        if (miPlugins == null || miApps == null) return;
        miPlugins.DropDownItems.Clear();
        int n = 0;
        foreach (var kv in Apps) {
            string cmd = kv.Value[1];
            if (!cmd.StartsWith("plugin:") && !cmd.StartsWith("codeplugin:")) continue;
            string code = kv.Key;                                   // C#5: 不能捕获 foreach 变量, 必须复制到局部
            string nm = kv.Value[0];
            miPlugins.DropDownItems.Add(nm + "  (" + code + ")", null, delegate { LaunchApp(code); });
            n++;
        }
        if (n == 0) miPlugins.DropDownItems.Add(new ToolStripMenuItem(L("(无插件 — 放 plugins\\*.txt)", "(no plugins — put plugins\\*.txt)")) { Enabled = false });
        miPlugins.DropDownItems.Add(new ToolStripSeparator());
        miPlugins.DropDownItems.Add(L("插件管理…", "Plugin manager…"), null, delegate { LaunchApp("plugins"); });

        miApps.DropDownItems.Clear();
        int m = 0;
        foreach (var kv in Apps) {
            string cmd = kv.Value[1];
            if (cmd.StartsWith("builtin:") || cmd.StartsWith("plugin:") || cmd.StartsWith("codeplugin:")) continue;
            string code = kv.Key;
            string nm = kv.Value[0];
            miApps.DropDownItems.Add(nm + "  (" + code + ")", null, delegate { LaunchApp(code); });
            m++;
        }
        if (m == 0) miApps.DropDownItems.Add(new ToolStripMenuItem(L("(无 — config.txt 里加 app = 编码 名称 命令)", "(none — add 'app = code name command' in config.txt)")) { Enabled = false });
    }

    // ---------- 入口 ----------
    public static void Run(string dir, string batPath)
    {
        DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wgime");
        try { Directory.CreateDirectory(DataDir); } catch {}
        BatDir = dir; BatPath = batPath;
        Ui();                                                       // 在 UI 线程创建隐藏控件 (工具/插件 confirm 弹窗用它 Invoke)
        bool createdNew;
        using (var mutex = new System.Threading.Mutex(true, "WgTraySingleInstance", out createdNew)) {
            if (!createdNew) {
                MessageBox.Show(L("WgTray 已在运行 — 请先从托盘退出旧实例。", "WgTray is already running — exit the old instance from the tray first."), "WgTray");
                return;
            }
            var app = new TrayApp();
            app.tray = new NotifyIcon();
            app.tray.Icon = MakeIcon(L("工", "T"), Color.FromArgb(0, 120, 212));
            app.tray.Text = "WgTray";
            app.tray.Visible = true;
            trayRef = app.tray;
            app.ReloadConfig();
            app.BuildMenu();
            Application.ApplicationExit += delegate {
                app.tray.Visible = false;
                if (app.hkHost != null) { app.hkHost.Unreg(1); app.hkHost.Unreg(2); app.hkHost.Unreg(3); }
            };
            Application.Run();
        }
    }

    // ---------- 插件管理 (builtin:pluginmgr) ----------
    // 由 wgime.bat 内嵌 C# 的 PluginMgrForm 移植: 宿主改 TrayApp, 新增"运行"按钮
    // (wgtray 没有输入法, 无法靠输入编码启动插件, 管理器直接提供启动入口)
    class PluginMgrForm : Form
    {
        readonly TrayApp host;
        readonly ListView list;

        public PluginMgrForm(TrayApp host)
        {
            this.host = host;
            Text = L("插件管理  (WgTray)", "Plugin Manager  (WgTray)");
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            KeyPreview = true;
            ClientSize = new Size(640, 420);
            BackColor = ToolsForm.TC_BG;
            EventHandler rg = delegate { try { ToolsForm.TSetWindowRgn(Handle, ToolsForm.TCreateRoundRectRgn(0, 0, Width + 1, Height + 1, 20, 20), true); } catch {} };
            HandleCreated += delegate { rg(this, EventArgs.Empty); };
            Resize += delegate { rg(this, EventArgs.Empty); };
            Paint += delegate(object s, PaintEventArgs e) {
                var g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var path = ToolsForm.TRound(new Rectangle(1, 1, Width - 3, Height - 3), 9))
                using (var pen = new Pen(ToolsForm.TC_BORDER, 1)) { g.DrawPath(pen, path); }
            };

            var header = new Panel { Location = new Point(0, 0), Size = new Size(640, 38), BackColor = ToolsForm.TC_HEADER };
            var cap = new Label { Text = L("插件管理", "Plugin Manager"), AutoSize = true, Location = new Point(14, 9),
                Font = ToolsForm.TF(10F, FontStyle.Bold), ForeColor = ToolsForm.TC_TEXT, BackColor = Color.Transparent };
            var close = new Label { Text = "✕", Size = new Size(30, 26), Location = new Point(602, 6), TextAlign = ContentAlignment.MiddleCenter,
                Font = ToolsForm.TF(10F, FontStyle.Regular), ForeColor = ToolsForm.TC_TEXT, BackColor = Color.Transparent, Cursor = Cursors.Hand };
            close.MouseEnter += delegate { close.BackColor = Color.FromArgb(255, 232, 17, 35); close.ForeColor = Color.White; };
            close.MouseLeave += delegate { close.BackColor = Color.Transparent; close.ForeColor = ToolsForm.TC_TEXT; };
            close.Click += delegate { Close(); };
            header.Controls.Add(cap); header.Controls.Add(close);
            header.Paint += delegate(object s, PaintEventArgs e) {
                using (var pen = new Pen(ToolsForm.TC_BORDER)) e.Graphics.DrawLine(pen, 0, header.Height - 1, header.Width, header.Height - 1);
            };
            MouseEventHandler drag = delegate(object s, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                try { ToolsForm.TReleaseCapture(); ToolsForm.TSendMessage(Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } catch {}
            };
            header.MouseDown += drag; cap.MouseDown += drag;
            Controls.Add(header);

            var bar = new Panel { Location = new Point(0, 38), Size = new Size(640, 44), BackColor = ToolsForm.TC_BG };
            Controls.Add(bar);
            int x = 12;
            Action<string, int, EventHandler> add = delegate(string cap2, int w, EventHandler h) {
                var b = new ToolsForm.TBtn { Text = cap2, Font = ToolsForm.TF(9F, FontStyle.Regular), Location = new Point(x, 8), Size = new Size(w, 28) };
                b.Click += h;
                bar.Controls.Add(b);
                x += w + 8;
            };
            add(L("运行", "Run"), 66, delegate { RunSel(); });
            add(L("重载", "Reload"), 66, delegate { host.ReloadConfig(); RefreshList(); });
            add(L("启用/禁用", "On/Off"), 96, delegate { ToggleSel(); });
            add(L("打开目录", "Open folder"), 104, delegate { OpenDir(); });
            add(L("编辑", "Edit"), 66, delegate { EditSel(); });
            add(L("删除…", "Delete…"), 80, delegate { DelSel(); });
            add(L("新建模板…", "New…"), 96, delegate { NewPlugin(); });

            // list in a white rounded card (borderless ListView keeps native column/selection behavior)
            var card = new Panel { Location = new Point(12, 90), Size = new Size(616, 318), BackColor = ToolsForm.TC_SURFACE, Padding = new Padding(8) };
            card.Paint += delegate(object s, PaintEventArgs e) {
                var g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var path = ToolsForm.TRound(new Rectangle(0, 0, card.Width - 1, card.Height - 1), 8))
                using (var pen = new Pen(ToolsForm.TC_BORDER, 1)) { g.DrawPath(pen, path); }
            };
            list = new ListView { Dock = DockStyle.Fill, View = View.Details, FullRowSelect = true, MultiSelect = false, HideSelection = false,
                BorderStyle = BorderStyle.None, BackColor = ToolsForm.TC_SURFACE, ForeColor = ToolsForm.TC_TEXT, Font = ToolsForm.TF(9F, FontStyle.Regular) };
            list.Columns.Add(L("名称", "Name"), 128);
            list.Columns.Add(L("编码", "Code"), 66);
            list.Columns.Add(L("类型", "Type"), 46);
            list.Columns.Add(L("启停", "State"), 58);
            list.Columns.Add(L("状态", "Status"), 108);
            list.Columns.Add(L("文件", "File"), 180);
            card.Controls.Add(list);
            Controls.Add(card);
            list.DoubleClick += delegate { EditSel(); };
            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
            RefreshList();
        }

        string PluginDir() { return Path.Combine(BatDir, "plugins"); }

        void RefreshList()
        {
            list.BeginUpdate();
            list.Items.Clear();
            try {
                string pd = PluginDir();
                if (Directory.Exists(pd)) {
                    foreach (string f in Directory.GetFiles(pd, "*.txt")) {
                        string fn = Path.GetFileName(f);
                        if (fn.Equals("README.txt", StringComparison.OrdinalIgnoreCase)) continue;
                        string[] info;
                        if (PluginInfo == null || !PluginInfo.TryGetValue(f, out info)) continue;      // header parse failed: not a plugin
                        bool disabled = DisabledPlugins.Contains(fn.ToLower());
                        bool isCode = PluginCodeCache != null && PluginCodeCache.ContainsKey(f);
                        string status;
                        if (isCode) {
                            var pc = PluginCodeCache[f];
                            status = pc.Error != null ? L("编译失败", "compile error") : L("正常", "OK");
                        } else {
                            ToolAction a;
                            status = (PluginActions != null && PluginActions.TryGetValue(f, out a))
                                ? L("正常", "OK") + " (" + a.Steps.Count + L(" 步", " steps") + ")"
                                : L("解析失败", "parse error");
                        }
                        var it = new ListViewItem(info[1]);
                        it.SubItems.Add(info[0]);
                        it.SubItems.Add(isCode ? "C#" : L("步骤", "DSL"));
                        it.SubItems.Add(disabled ? L("已禁用", "disabled") : L("启用", "enabled"));
                        it.SubItems.Add(status);
                        it.SubItems.Add(fn);
                        it.Tag = f;
                        if (disabled) it.ForeColor = Color.Gray;
                        list.Items.Add(it);
                    }
                }
            } catch {}
            list.EndUpdate();
        }

        void RunSel()                                                // 运行选中的插件 (DSL 步骤 或 C# 代码插件)
        {
            string f = SelFile();
            if (f == null) { MessageBox.Show(this, L("请先选中一个插件", "Select a plugin first"), "WgTray"); return; }
            bool isCode = PluginCodeCache != null && PluginCodeCache.ContainsKey(f);
            if (isCode) host.RunCodePlugin(f); else host.RunPlugin(f);
        }

        void ToggleSel()
        {
            string f = SelFile();
            if (f == null) return;
            SetPluginDisabled(f, !DisabledPlugins.Contains(Path.GetFileName(f).ToLower()));
            host.ReloadConfig();
            RefreshList();
        }

        string SelFile()
        {
            if (list.SelectedItems.Count == 0) return null;
            return (string)list.SelectedItems[0].Tag;
        }
        void OpenDir()
        {
            try {
                Directory.CreateDirectory(PluginDir());
                Process.Start(new ProcessStartInfo { FileName = PluginDir(), UseShellExecute = true });
            } catch {}
        }
        void EditSel()
        {
            string f = SelFile();
            if (f == null) return;
            try { Process.Start(new ProcessStartInfo { FileName = f, UseShellExecute = true }); } catch {}
        }
        void DelSel()
        {
            string f = SelFile();
            if (f == null) return;
            if (MessageBox.Show(this, L("删除插件文件 ", "Delete plugin file ") + Path.GetFileName(f) + "?", "WgTray",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
            try { File.Delete(f); } catch {}
            host.ReloadConfig();
            RefreshList();
        }
        void NewPlugin()
        {
            try {
                Directory.CreateDirectory(PluginDir());
                string f = Path.Combine(PluginDir(), "new-" + DateTime.Now.ToString("HHmmss") + ".txt");
                File.WriteAllText(f,
                    "; WgTray plugin (spec: docs/WGIME_插件规范.md)\r\n" +
                    "code = mycode\r\n" +
                    "name = 我的插件\r\n" +
                    "desc = \r\n\r\n" +
                    "msg hello from my plugin\r\n", new UTF8Encoding(false));
                Process.Start(new ProcessStartInfo { FileName = f, UseShellExecute = true });
            } catch {}
        }
    }

    static void FixLegacyConfigIfBroken(string f)   // v1 wrote the template on ONE line (`n artifacts): repair it
    {
        try {
            if (!File.Exists(f)) return;
            string t = File.ReadAllText(f, Encoding.UTF8);
            if (t.Contains("`n") && t.TrimStart().StartsWith(";"))
                File.WriteAllText(f, DefaultConfigText(), new UTF8Encoding(false));
        } catch {}
    }
    void LaunchApp(string code)
    {
        string[] a;
        if (Apps == null || !Apps.TryGetValue(code, out a)) return;
        try {
            if (a[1] == "builtin:tools") { ShowTools(); return; }
            if (a[1] == "builtin:nettools") { ShowNetTools(); return; }
            if (a[1] == "builtin:clip") { ShowClip(); return; }
            if (a[1] == "builtin:note") { ShowNote(); return; }
            if (a[1] == "builtin:color") { ShowColor(); return; }
            if (a[1].StartsWith("plugin:")) { RunPlugin(a[1].Substring(7)); return; }
            if (a[1].StartsWith("codeplugin:")) { RunCodePlugin(a[1].Substring(11)); return; }
            if (a[1].StartsWith("tool:")) { RunToolCode(a[1].Substring(5)); return; }
            if (a[1] == "builtin:pluginmgr") { ShowPluginMgr(); return; }
            string target = a[1];
            // relative paths (those containing a path separator) resolve against the bat's folder, not the
            // process CWD; bare exe names still go through PATH/ShellExecute search, URLs untouched
            if (target.IndexOf("://") < 0 && (target.IndexOf('\\') >= 0 || target.IndexOf('/') >= 0) && !Path.IsPathRooted(target))
                target = Path.Combine(BatDir, target);
            var psi = new ProcessStartInfo { FileName = target, UseShellExecute = true };   // exe / path / folder / URL all work
            if (a.Length > 2 && a[2].Length > 0) psi.Arguments = a[2];
            Process.Start(psi);
        } catch (Exception ex) { TrayTip(L("启动失败", "Launch failed"), a[0] + ": " + ex.Message, ToolTipIcon.Error); }
    }
    // run a tools.txt action by its input-method code (mirrors the toolbox button click runner)
    void RunToolCode(string code)
    {
        ToolAction a = null;
        if (ToolTabs != null) {
            foreach (var t in ToolTabs) {
                if (t == null) continue;
                foreach (var x in t.Actions) {
                    if (x != null && x.Code == code) { a = x; break; }
                }
                if (a != null) break;
            }
        }
        if (a == null) { TrayTip(L("\u5DE5\u5177", "Tool"), "no tool action for code: " + code, ToolTipIcon.Warning); return; }
        var t2 = new System.Threading.Thread((System.Threading.ThreadStart)delegate {
            int errs = 0; bool aborted = false;
            var lines = new System.Collections.Generic.List<string>();
            for (int k = 0; k < a.Steps.Count; k++) {
                bool isBlock = a.Steps[k].Length == 1 && (a.Steps[k][0] == "shellblock" || a.Steps[k][0] == "psblock" || a.Steps[k][0] == "shellblockx" || a.Steps[k][0] == "psblockx");
                var sb = new StringBuilder();
                string r = ExecToolStep(a.Steps[k], isBlock ? a.Raw[k] : ToolRest(a.Raw[k]), sb, Ui());
                if (sb.Length > 0) lines.Add(sb.ToString().Trim());
                if (r == "abort") { aborted = true; break; }
                if (r != null) { errs++; }
            }
            string tail = aborted ? L("\u5DF2\u53D6\u6D88", "-- aborted --") : (errs == 0 ? L("\u5B8C\u6210", "-- done --") : L("\u5B8C\u6210, ", "-- done, ") + errs + L(" \u4E2A\u6B65\u9AA4\u5931\u8D25 --", " step(s) failed --"));
            string body = lines.Count > 0 ? string.Join(" | ", lines) : tail;
            try { if (trayRef != null) trayRef.ShowBalloonTip(2600, a.Name, body, ToolTipIcon.Info); } catch {}
        });
        t2.IsBackground = true;
        t2.Start();
    }
    class ToolAction { internal string Name; internal string Code;   // optional "code = xyz" under the button -> input-method trigger
    internal List<string[]> Steps = new List<string[]>(); internal List<string> Raw = new List<string>(); }
    class ToolTab { internal string Name; internal List<ToolAction> Actions = new List<ToolAction>(); internal int Cols; }   // Cols: tile columns from [cols N], 0 = default 2
    static List<ToolTab> ToolTabs;
    Form toolsForm;

    static List<string> ToolToks(string line)            // whitespace tokenizer with "double quote" grouping
    {
        var r = new List<string>();
        int i = 0;
        while (i < line.Length) {
            while (i < line.Length && char.IsWhiteSpace(line[i])) i++;
            if (i >= line.Length) break;
            if (line[i] == '"') {
                int j = line.IndexOf('"', i + 1);
                if (j < 0) j = line.Length;
                r.Add(line.Substring(i + 1, j - i - 1));
                i = j + 1;
            } else {
                int j = i;
                while (j < line.Length && !char.IsWhiteSpace(line[j])) j++;
                r.Add(line.Substring(i, j - i));
                i = j;
            }
        }
        return r;
    }

    static void LoadTools(string dir)
    {
        var tabs = new List<ToolTab>();
        ToolTabs = tabs;
        try {
            string f = Path.Combine(dir, "tools.txt");
            if (!File.Exists(f)) return;
            ToolTab tab = null; ToolAction act = null;
            string blockClose = null; string blockVerb = null; var blockLines = new List<string>();   // multi-line script block capture
            foreach (string raw in File.ReadAllLines(f, Encoding.UTF8)) {
                if (blockClose != null) {                                   // inside [shell]...[/shell] style block: keep lines raw
                    if (raw.Trim() == blockClose) {
                        if (act != null) { act.Steps.Add(new string[] { blockVerb }); act.Raw.Add(string.Join("\n", blockLines)); }
                        blockClose = null;
                    } else blockLines.Add(raw);
                    continue;
                }
                string t = raw.Trim();
                if (t.Length == 0 || t[0] == ';' || t[0] == '#') continue;
                if (t == "[shell]" || t == "[cmd]") { if (act != null) { blockVerb = "shellblock"; blockClose = t.Insert(1, "/"); blockLines.Clear(); } continue; }
                if (t == "[powershell]" || t == "[ps]") { if (act != null) { blockVerb = "psblock"; blockClose = (t == "[ps]" ? "[/ps]" : "[/powershell]"); blockLines.Clear(); } continue; }
                if (t == "[shellx]" || t == "[cmdx]") { if (act != null) { blockVerb = "shellblockx"; blockClose = t.Insert(1, "/"); blockLines.Clear(); } continue; }
                if (t == "[powershellx]" || t == "[psx]") { if (act != null) { blockVerb = "psblockx"; blockClose = t.Insert(1, "/"); blockLines.Clear(); } continue; }
                if (t.StartsWith("[") && t.EndsWith("]")) {
                    string c = t.Substring(1, t.Length - 2).Trim();
                    if (c.StartsWith("tab ")) { c = c.Substring(4).Trim(); tab = new ToolTab { Name = c.Length > 0 ? c : "?" }; tabs.Add(tab); act = null; continue; }
                    if (c.StartsWith("cols ")) {                               // [cols N]: tile columns for the current tab (1-6)
                        int cn;
                        if (int.TryParse(c.Substring(5).Trim(), out cn)) {
                            if (cn < 1) cn = 1; if (cn > 6) cn = 6;
                            if (tab == null) { tab = new ToolTab { Name = L("工具", "Tools") }; tabs.Add(tab); }
                            tab.Cols = cn;
                        }
                        continue;
                    }
                    if (c.StartsWith("button ")) c = c.Substring(7).Trim();
                    if (tab == null) { tab = new ToolTab { Name = L("工具", "Tools") }; tabs.Add(tab); }
                    act = new ToolAction { Name = c.Length > 0 ? c : "?" };
                    tab.Actions.Add(act);
                    continue;
                }
                if (act != null && t.StartsWith("code")) {                        // "code = xyz": input-method code for this button (not a step)
                    var ctoks = ToolToks(t);
                    if (ctoks.Count >= 3 && ctoks[2].Length > 0) act.Code = ctoks[2].ToLower();
                    continue;
                }                if (act == null) continue;                                   // steps before any button: ignore
                var toks = ToolToks(t);
                if (toks.Count > 0) { act.Steps.Add(toks.ToArray()); act.Raw.Add(t); }
            }
            // tool-action codes -> app launcher (overrides app= with the same code; picking the
            // "\u5DE5\u5177:\u540D\u79F0" candidate runs the action exactly like clicking its button)
            if (Apps == null) Apps = new Dictionary<string,string[]>();
            if (tabs != null) {
                foreach (var tabx in tabs) {
                    if (tabx == null) continue;
                    foreach (var actx in tabx.Actions) {
                        if (actx == null || string.IsNullOrEmpty(actx.Code)) continue;
                        Apps[actx.Code] = new string[] { "\u5DE5\u5177:" + actx.Name, "tool:" + actx.Code, "" };
                    }
                }
            }        } catch {}
    }

    static string ToolRest(string rawLine)               // the raw remainder after the verb (msg/confirm/shell keep original spacing)
    {
        int i = rawLine.IndexOf(' ');
        return i < 0 ? "" : rawLine.Substring(i + 1).Trim();
    }

    static string ToolPath(string rest, string[] tk)     // path/target arg: raw remainder (keeps spaces), quotes stripped, env vars expanded
    {
        string s = rest.Length > 0 ? rest : (tk.Length > 1 ? tk[1] : "");
        s = s.Trim();
        if (s.Length >= 2 && s[0] == '"' && s[s.Length - 1] == '"') s = s.Substring(1, s.Length - 2);
        return Environment.ExpandEnvironmentVariables(s);
    }

    static void ToolRegSplit(string full, out Microsoft.Win32.RegistryKey hive, out string sub)
    {
        string p = full.Replace('/', '\\');
        int s = p.IndexOf('\\');
        string h = (s < 0 ? p : p.Substring(0, s)).ToUpper();
        sub = s < 0 ? "" : p.Substring(s + 1);
        if (h == "HKCU" || h == "HKEY_CURRENT_USER") hive = Microsoft.Win32.Registry.CurrentUser;
        else if (h == "HKLM" || h == "HKEY_LOCAL_MACHINE") hive = Microsoft.Win32.Registry.LocalMachine;
        else if (h == "HKCR" || h == "HKEY_CLASSES_ROOT") hive = Microsoft.Win32.Registry.ClassesRoot;
        else if (h == "HKU" || h == "HKEY_USERS") hive = Microsoft.Win32.Registry.Users;
        else if (h == "HKCC" || h == "HKEY_CURRENT_CONFIG") hive = Microsoft.Win32.Registry.CurrentConfig;
        else throw new Exception("bad hive: " + full);
    }

    // hidden process runner with async stdout/stderr capture; returns null on exit code 0
    static string RunHidden(ProcessStartInfo psi, StringBuilder log)
    {
        psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        if (psi.StandardOutputEncoding == null) {   // console children (cmd/PS 5.1) emit OEM/ANSI by default; psblock overrides to UTF-8
            psi.StandardOutputEncoding = Encoding.Default; psi.StandardErrorEncoding = Encoding.Default;
        }
        var outp = new StringBuilder();
        var p = Process.Start(psi);
        p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e2) { if (e2.Data != null) outp.AppendLine(e2.Data); };
        p.ErrorDataReceived  += delegate(object s, DataReceivedEventArgs e2) { if (e2.Data != null) outp.AppendLine(e2.Data); };
        p.BeginOutputReadLine(); p.BeginErrorReadLine();
        p.WaitForExit();
        if (outp.Length > 0) log.AppendLine("  out: " + outp.ToString().Trim());
        log.AppendLine("  exit " + p.ExitCode);
        return p.ExitCode == 0 ? null : "exit code " + p.ExitCode;
    }

    // visible console runner for interactive tools/scripts: output goes to the new console window (not captured),
    // we still wait for it and log the exit code. UseShellExecute = visible window even though the IME itself is hidden.
    static string RunVisible(ProcessStartInfo psi, StringBuilder log)
    {
        psi.UseShellExecute = true;
        var p = Process.Start(psi);
        p.WaitForExit();
        log.AppendLine("  exit " + p.ExitCode);
        return p.ExitCode == 0 ? null : "exit code " + p.ExitCode;
    }

    // multi-line script block: write to a temp file, run it, clean up.
    // shellblock -> .cmd (ANSI, cmd's native); psblock -> .ps1 (UTF-8 *with BOM*: PS 5.1 misreads BOM-less UTF-8 as ANSI).
    // PS 5.1 with redirected output defaults to ASCII and mangles CJK into '?' -> force UTF-8 on both ends (prelude + ioEnc).
    // visible=true: interactive console window; tail keeps the window open after the script finishes (pause / Read-Host).
    static string RunScriptBlock(string script, string ext, string exe, string argsPrefix, Encoding enc, Encoding ioEnc, string prelude, StringBuilder log, bool visible = false, string tail = "")
    {
        string tmp = null;
        try {
            tmp = Path.Combine(Path.GetTempPath(), "wgime-tool-" + Guid.NewGuid().ToString("N") + ext);
            File.WriteAllText(tmp, prelude + script + tail, enc);
            var psi = new ProcessStartInfo { FileName = exe, Arguments = argsPrefix + "\"" + tmp + "\"" };
            if (ioEnc != null) { psi.StandardOutputEncoding = ioEnc; psi.StandardErrorEncoding = ioEnc; }
            return visible ? RunVisible(psi, log) : RunHidden(psi, log);
        } finally {
            if (tmp != null) { try { File.Delete(tmp); } catch {} }
        }
    }

    // delete one file/dir, never throwing: locked/in-use items are skipped so one bad entry can't abort the rest
    static void ToolDel(string path, bool isDir, ref int n, ref int fail, List<string> skipped)
    {
        try { if (isDir) Directory.Delete(path, true); else File.Delete(path); n++; }
        catch { fail++; if (skipped.Count < 8) skipped.Add(path); }
    }

    // returns null = OK, "abort" = user declined a confirm, otherwise the error text
    static string ExecToolStep(string[] tk, string rest, StringBuilder log, Control ui)
    {
        string v = tk[0].ToLower();
        try {
            if (v == "msg") { try { if (trayRef != null) trayRef.ShowBalloonTip(2400, "WgTray", rest, ToolTipIcon.Info); } catch {} return null; }
            if (v == "confirm") {
                // confirm 文本 [| title=标题] [| buttons=yesno|okcancel|ok] [| default=1|2]
                // yes/ok=继续, no/cancel=中止本按钮后续步骤; buttons=ok 为纯提示, 永不中止
                string msg = rest, title = "WgTray";
                var btns = MessageBoxButtons.YesNo;
                var def = MessageBoxDefaultButton.Button2;                       // 默认"否", 防误触
                int pipe = rest.IndexOf('|');
                if (pipe >= 0) {
                    msg = rest.Substring(0, pipe).Trim();
                    foreach (string opt in rest.Substring(pipe + 1).Split('|')) {
                        int eq = opt.IndexOf('='); if (eq < 1) continue;
                        string ok2 = opt.Substring(0, eq).Trim().ToLower(), ov = opt.Substring(eq + 1).Trim();
                        if (ok2 == "title") title = ov;
                        else if (ok2 == "buttons") btns = ov == "ok" ? MessageBoxButtons.OK : (ov == "okcancel" ? MessageBoxButtons.OKCancel : MessageBoxButtons.YesNo);
                        else if (ok2 == "default") def = ov == "1" ? MessageBoxDefaultButton.Button1 : MessageBoxDefaultButton.Button2;
                    }
                }
                DialogResult r = DialogResult.Yes;
                if (ui != null) r = (DialogResult)ui.Invoke((Func<DialogResult>)delegate {
                    return MessageBox.Show(msg, title, btns, MessageBoxIcon.Question, def);
                });
                if (btns == MessageBoxButtons.OK) return null;
                return (r == DialogResult.Yes || r == DialogResult.OK) ? null : "abort";
            }
            if (v == "wait") { System.Threading.Thread.Sleep(int.Parse(tk[1])); return null; }
            if (v == "kill") {
                int n = 0;
                foreach (var p in Process.GetProcessesByName(tk[1])) { try { p.Kill(); n++; } catch {} }
                log.AppendLine("  killed " + n + " x " + tk[1]);
                return null;
            }
            if (v == "run" || v == "shell") {
                var psi = v == "run"
                    ? new ProcessStartInfo { FileName = Environment.ExpandEnvironmentVariables(tk[1]) }
                    : new ProcessStartInfo { FileName = "cmd.exe", Arguments = "/c " + rest };
                if (v == "run" && tk.Length > 2) {
                    var sb = new StringBuilder();
                    for (int i = 2; i < tk.Length; i++) { if (sb.Length > 0) sb.Append(' '); sb.Append(tk[i].IndexOf(' ') >= 0 ? "\"" + tk[i] + "\"" : tk[i]); }
                    psi.Arguments = sb.ToString();
                }
                return RunHidden(psi, log);
            }
            if (v == "shellblock") return RunScriptBlock(rest, ".cmd", "cmd.exe", "/c ", Encoding.Default, null, "", log);
            if (v == "psblock")    return RunScriptBlock(rest, ".ps1", "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File ", new UTF8Encoding(true), new UTF8Encoding(false), "[Console]::OutputEncoding = [Text.Encoding]::UTF8\r\n", log);
            if (v == "shellx")      return RunVisible(new ProcessStartInfo { FileName = "cmd.exe", Arguments = "/c " + rest }, log);   // interactive: visible console, waits
            if (v == "shellblockx") return RunScriptBlock(rest, ".cmd", "cmd.exe", "/c ", Encoding.Default, null, "", log, true, "\r\necho.\r\npause\r\n");
            if (v == "psblockx")    return RunScriptBlock(rest, ".ps1", "powershell.exe", "-NoProfile -ExecutionPolicy Bypass -File ", new UTF8Encoding(true), null, "", log, true, "\r\nWrite-Host ''\r\nRead-Host 'press ENTER to close'\r\n");
            if (v == "open") {
                Process.Start(new ProcessStartInfo { FileName = ToolPath(rest, tk), UseShellExecute = true });
                return null;
            }
            if (v == "reg-set") {
                Microsoft.Win32.RegistryKey hive; string sub;
                ToolRegSplit(Environment.ExpandEnvironmentVariables(tk[1]), out hive, out sub);
                string vn = tk[2] == "-" ? "" : tk[2];
                string typ = tk[3].ToLower();
                string data = string.Join(" ", tk, 4, tk.Length - 4);
                object val; Microsoft.Win32.RegistryValueKind kind;
                if (typ == "dword") { kind = Microsoft.Win32.RegistryValueKind.DWord; val = int.Parse(data); }
                else if (typ == "qword") { kind = Microsoft.Win32.RegistryValueKind.QWord; val = long.Parse(data); }
                else if (typ == "expand") { kind = Microsoft.Win32.RegistryValueKind.ExpandString; val = data; }
                else if (typ == "multi") { kind = Microsoft.Win32.RegistryValueKind.MultiString; val = data.Split('|'); }
                else if (typ == "binary") {
                    kind = Microsoft.Win32.RegistryValueKind.Binary;
                    string hx = data.Replace(" ", "").Replace("-", "");
                    var bytes = new byte[hx.Length / 2];
                    for (int i = 0; i < bytes.Length; i++) bytes[i] = Convert.ToByte(hx.Substring(i * 2, 2), 16);
                    val = bytes;
                } else { kind = Microsoft.Win32.RegistryValueKind.String; val = data; }
                using (var k = hive.CreateSubKey(sub)) k.SetValue(vn, val, kind);
                return null;
            }
            if (v == "reg-del") {
                Microsoft.Win32.RegistryKey hive; string sub;
                ToolRegSplit(Environment.ExpandEnvironmentVariables(tk[1]), out hive, out sub);
                if (tk.Length > 2) {
                    using (var k = hive.OpenSubKey(sub, true)) { if (k != null) k.DeleteValue(tk[2] == "-" ? "" : tk[2], false); }
                } else {
                    hive.DeleteSubKeyTree(sub, false);
                }
                return null;
            }
            if (v == "file-del") {
                string spec = ToolPath(rest, tk);
                if (spec.TrimEnd('\\').Length <= 3) return "refuse to delete a drive root: " + spec;
                int n = 0, fail = 0; var skipped = new List<string>();
                if (spec.IndexOf('*') >= 0 || spec.IndexOf('?') >= 0) {
                    string dir = Path.GetDirectoryName(spec), pat = Path.GetFileName(spec);
                    if (Directory.Exists(dir)) {
                        foreach (var f2 in Directory.GetFiles(dir, pat)) ToolDel(f2, false, ref n, ref fail, skipped);
                        foreach (var d2 in Directory.GetDirectories(dir, pat)) ToolDel(d2, true, ref n, ref fail, skipped);
                    }
                } else if (Directory.Exists(spec)) ToolDel(spec, true, ref n, ref fail, skipped);
                else if (File.Exists(spec)) ToolDel(spec, false, ref n, ref fail, skipped);
                foreach (string s in skipped) log.AppendLine("  skip: " + s);
                log.AppendLine("  deleted " + n + (fail > 0 ? ", skipped " + fail + " (in use / locked)" : ""));
                return null;
            }
            if (v == "mkdir") { Directory.CreateDirectory(ToolPath(rest, tk)); return null; }
            return "unknown verb: " + v;
        } catch (Exception ex) { return ex.Message; }
    }

    void ShowTools()
    {
        if (ToolTabs == null || ToolTabs.Count == 0) {
            TrayTip(L("工具箱", "Toolbox"), L("tools.txt 为空或不存在——在 wgime.bat 同目录建一个即可添加功能", "tools.txt missing/empty - create it next to wgime.bat"), ToolTipIcon.Info);
        }
        if (toolsForm != null && !toolsForm.IsDisposed) { toolsForm.Show(); toolsForm.Activate(); return; }
        toolsForm = new ToolsForm(ToolTabs ?? new List<ToolTab>());
        toolsForm.Show();
    }
    class ToolsForm : Form
    {
        readonly TextBox log;
        readonly List<Panel> pages = new List<Panel>();
        Panel logWrap;
        IMessageFilter wheelFilter;

        // light blue-gray body + white cards: stands out from white desktop windows
        internal static readonly Color TC_BG = Color.FromArgb(255, 232, 237, 245);
        internal static readonly Color TC_SURFACE = Color.FromArgb(255, 255, 255, 255);
        internal static readonly Color TC_HEADER = Color.FromArgb(255, 220, 227, 239);   // deeper tint title bar: stands out from white windows
        internal static readonly Color TC_SURF2 = Color.FromArgb(255, 217, 224, 236);
        internal static readonly Color TC_BORDER = Color.FromArgb(255, 195, 204, 221);
        internal static readonly Color TC_TEXT = Color.FromArgb(255, 29, 29, 31);
        internal static readonly Color TC_SUB = Color.FromArgb(255, 110, 116, 133);
        internal static readonly Color TC_ACCENT = Color.FromArgb(255, 0, 122, 255);
        internal static readonly Color TC_CONBG = Color.FromArgb(255, 46, 48, 64);      // dark console: distinct from both body and white cards
        internal static readonly Color TC_CONFG = Color.FromArgb(255, 214, 217, 226);

        internal static Font TF(float size, FontStyle st)
        {
            string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
            foreach (string n in names) { try { return new Font(n, size, st, GraphicsUnit.Point); } catch {} }
            return new Font(FontFamily.GenericSansSerif, size, st, GraphicsUnit.Point);
        }
        internal static System.Drawing.Drawing2D.GraphicsPath TRound(Rectangle r, int rad)
        {
            var p = new System.Drawing.Drawing2D.GraphicsPath();
            int d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        [DllImport("user32.dll", EntryPoint = "ReleaseCapture")] internal static extern bool TReleaseCapture();
        [DllImport("user32.dll", EntryPoint = "SendMessage")] internal static extern IntPtr TSendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "SendMessage")] internal static extern IntPtr TSendMsgInt(IntPtr h, int msg, int w, int l);
        [DllImport("gdi32.dll", EntryPoint = "CreateRoundRectRgn")] internal static extern IntPtr TCreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
        [DllImport("user32.dll", EntryPoint = "SetWindowRgn")] internal static extern int TSetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);

        class VP : Panel { public VP() { DoubleBuffered = true; } }
        class SBar : Panel { public bool Drag; public int DragOff; public Panel Host, Vp; public SBar() { DoubleBuffered = true; } }
        class WheelFilter : IMessageFilter
        {
            readonly ToolsForm host;
            internal WheelFilter(ToolsForm h) { host = h; }
            public bool PreFilterMessage(ref Message m)
            {
                if (m.Msg != 0x20A) return false;                            // WM_MOUSEWHEEL
                return host.OnWheel((short)((m.WParam.ToInt64() >> 16) & 0xFFFF));
            }
        }

        internal class TBtn : Panel   // Panel base: zero native chrome (a Button's themed edge bleeds a dark top/left line on light themes)
        {
            public Color Bg = Color.FromArgb(255, 255, 255, 255);       // white card tile on the blue-gray body
            public Color BgHover = Color.FromArgb(255, 240, 243, 249);
            public Color BgDown = Color.FromArgb(255, 226, 232, 242);
            public bool AccentLine, Selected;
            bool hover, down;
            public TBtn()
            {
                DoubleBuffered = true;
                Cursor = Cursors.Hand;
            }
            protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
            protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
            protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
            protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
                var rect = new Rectangle(0, 0, Width - 1, Height - 1);
                Color fill = !Enabled ? Color.FromArgb(255, 243, 243, 246) : (down ? BgDown : (hover ? BgHover : Bg));
                using (var path = TRound(rect, 8))
                using (var br = new SolidBrush(fill)) { g.FillPath(br, path); }
                if (AccentLine && Selected) {
                    using (var br = new SolidBrush(TC_ACCENT)) g.FillRectangle(br, 12, Height - 4, Width - 24, 3);
                }
                using (var br = new SolidBrush(!Enabled ? TC_SUB : TC_TEXT))
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(Text, Font, br, new RectangleF(6, 0, Width - 12, Height), sf);
            }
        }

        internal ToolsForm(List<ToolTab> tabs)
        {
            Text = L("工具箱  (WgTray)", "Toolbox  (WgTray)");
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleMode = AutoScaleMode.None;                  // pixel-designed layout: no DPI autoscale distortion
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            KeyPreview = true;
            ClientSize = new Size(560, 470);
            BackColor = TC_BG;
            EventHandler rg = delegate { try { TSetWindowRgn(Handle, TCreateRoundRectRgn(0, 0, Width + 1, Height + 1, 20, 20), true); } catch {} };   // GDI rgn: no jagged corner stubs
            HandleCreated += delegate { rg(this, EventArgs.Empty); };
            Resize += delegate { rg(this, EventArgs.Empty); };
            Paint += delegate(object s, PaintEventArgs e) {
                var g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var path = TRound(new Rectangle(1, 1, Width - 3, Height - 3), 9))   // inset 1px: AA stays off the clip edge
                using (var pen = new Pen(TC_BORDER, 1)) { g.DrawPath(pen, path); }
            };

            // header (explicit coordinates everywhere: dock order proved fragile)
            var header = new Panel { Location = new Point(0, 0), Size = new Size(560, 38), BackColor = TC_HEADER };
            var cap = new Label { Text = L("工具箱", "Toolbox"), AutoSize = true, Location = new Point(14, 9),
                Font = TF(10F, FontStyle.Bold), ForeColor = TC_TEXT, BackColor = Color.Transparent };
            var close = new Label { Text = "✕", Size = new Size(30, 26), Location = new Point(522, 6), TextAlign = ContentAlignment.MiddleCenter,
                Font = TF(10F, FontStyle.Regular), ForeColor = TC_TEXT, BackColor = Color.Transparent, Cursor = Cursors.Hand };
            close.MouseEnter += delegate { close.BackColor = Color.FromArgb(255, 232, 17, 35); close.ForeColor = Color.White; };
            close.MouseLeave += delegate { close.BackColor = Color.Transparent; close.ForeColor = TC_TEXT; };
            close.Click += delegate { Close(); };
            header.Controls.Add(cap); header.Controls.Add(close);
            header.Paint += delegate(object s, PaintEventArgs e) {
                using (var pen = new Pen(TC_BORDER)) e.Graphics.DrawLine(pen, 0, header.Height - 1, header.Width, header.Height - 1);
            };
            MouseEventHandler drag = delegate(object s, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                try { TReleaseCapture(); TSendMessage(Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } catch {}
            };
            header.MouseDown += drag; cap.MouseDown += drag;
            Controls.Add(header);

            // flat tab strip + one tile page per tab ([cols N] tiles per row, wraps to rows)
            var strip = new Panel { Location = new Point(0, 38), Size = new Size(560, 40), BackColor = TC_BG };
            Controls.Add(strip);
            var tabBtns = new List<TBtn>();
            int contentH = 470 - 78 - 112;
            int tabW = tabs.Count > 0 ? Math.Min(110, (560 - 28) / tabs.Count) : 110;
            for (int i = 0; i < tabs.Count; i++) {
                var b = new TBtn { Text = tabs[i].Name, Font = TF(9.5F, FontStyle.Regular), AccentLine = true, Selected = (i == 0),
                    Bg = TC_BG, BgHover = TC_SURF2, BgDown = TC_SURF2,
                    Size = new Size(tabW, 28), Location = new Point(14 + i * (tabW + 6), 6) };
                int idx = i;
                b.Click += delegate {
                    for (int j = 0; j < tabBtns.Count; j++) { tabBtns[j].Selected = (j == idx); tabBtns[j].Invalidate(); pages[j].Visible = (j == idx); }
                };
                tabBtns.Add(b); strip.Controls.Add(b);

                // tile page: manual viewport scroll + slim custom scrollbar (native one is chunky)
                var page = new Panel { Location = new Point(0, 78), Size = new Size(560, contentH), BackColor = TC_BG, Visible = (i == 0) };
                int cols = tabs[i].Cols; if (cols < 1) cols = 2; if (cols > 6) cols = 6;
                int pad = 14, gap = 10, th = 46;
                int bw = (548 - 2 * pad - (cols - 1) * gap) / cols;
                int rows = (tabs[i].Actions.Count + cols - 1) / cols;
                var vp = new VP { Location = new Point(0, 0), Size = new Size(548, Math.Max(contentH, pad + rows * (th + gap))), BackColor = TC_BG };
                for (int k = 0; k < tabs[i].Actions.Count; k++) {
                    var a = tabs[i].Actions[k];
                    var tb = new TBtn { Text = a.Name, Tag = a, Font = TF(9.5F, FontStyle.Regular),
                        Size = new Size(bw, th), Location = new Point(pad + (k % cols) * (bw + gap), pad + (k / cols) * (th + gap)) };
                    tb.Click += RunAction;
                    vp.Controls.Add(tb);
                }
                var bar = new SBar { Dock = DockStyle.Right, Width = 10, BackColor = TC_BG, Host = page, Vp = vp };
                page.Controls.Add(vp); page.Controls.Add(bar);
                bar.Paint += PageSbPaint;
                bar.MouseDown += PageSbDown;
                bar.MouseMove += PageSbMove;
                bar.MouseUp += delegate(object s2, MouseEventArgs e2) { var bb = (SBar)s2; bb.Drag = false; bb.Capture = false; bb.Invalidate(); };
                pages.Add(page); Controls.Add(page);
            }

            // log console (dark, inset, slim custom scrollbar)
            logWrap = new Panel { Location = new Point(0, 358), Size = new Size(560, 112), BackColor = TC_CONBG, Padding = new Padding(12, 8, 4, 8) };
            logWrap.Paint += delegate(object s, PaintEventArgs e) {
                using (var pen = new Pen(TC_BORDER)) e.Graphics.DrawLine(pen, 0, 0, logWrap.Width, 0);
            };
            log = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.None,
                BackColor = TC_CONBG, ForeColor = TC_CONFG, Font = new Font("Consolas", 9F) };
            logWrap.Controls.Add(log);
            var logBar = new SBar { Dock = DockStyle.Right, Width = 10, BackColor = TC_CONBG };
            logWrap.Controls.Add(logBar);
            logBar.Paint += LogSbPaint;
            logBar.MouseDown += LogSbDown;
            logBar.MouseMove += LogSbMove;
            logBar.MouseUp += delegate(object s2, MouseEventArgs e2) { var bb = (SBar)s2; bb.Drag = false; bb.Capture = false; bb.Invalidate(); };
            Controls.Add(logWrap);

            wheelFilter = new WheelFilter(this);                 // wheel scrolls tile pages / log even unfocused
            Application.AddMessageFilter(wheelFilter);
            FormClosed += delegate { try { Application.RemoveMessageFilter(wheelFilter); } catch {} };

            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
            if (tabs.Count == 0) Log(L("tools.txt 为空或不存在。格式: [tab 标签页] / [cols 列数] / [按钮名] / 步骤行 (msg confirm run shell open kill wait reg-set reg-del file-del mkdir)", "tools.txt is empty or missing."));
        }

        // ---------- wheel + slim scrollbars ----------
        bool OnWheel(int delta)                                  // delta: +/-120 per notch
        {
            try {
                var p = PointToClient(Cursor.Position);
                foreach (var pg in pages) {
                    if (!pg.Visible || !pg.Bounds.Contains(p)) continue;
                    foreach (Control c in pg.Controls) {
                        var bar = c as SBar;
                        if (bar != null) { ScrollVp(bar, -delta / 120 * 48); return true; }
                    }
                    return false;
                }
                if (logWrap != null && logWrap.Bounds.Contains(p)) {
                    TSendMsgInt(log.Handle, 0xB6, 0, -delta / 120 * 3);    // EM_LINESCROLL on the log
                    InvalidateLogBar();
                    return true;
                }
            } catch {}
            return false;
        }
        void SetVpOffset(SBar bar, int off)
        {
            int max = bar.Vp.Height - bar.Host.Height;
            if (off < 0) off = 0; if (off > max) off = max;
            if (bar.Vp.Top != -off) { bar.Vp.Top = -off; bar.Invalidate(); }
        }
        void ScrollVp(SBar bar, int dy) { SetVpOffset(bar, -bar.Vp.Top + dy); }
        void PageSbPaint(object s, PaintEventArgs e)
        {
            var bar = (SBar)s;
            int max = bar.Vp.Height - bar.Host.Height;
            if (max <= 0) return;                                            // content fits: no thumb
            int lane = bar.Height;
            int th = Math.Max(24, lane * bar.Host.Height / bar.Vp.Height);
            int ty = (lane - th) * (-bar.Vp.Top) / max;
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (var path = TRound(new Rectangle(2, ty, 6, th), 3))
            using (var br = new SolidBrush(bar.Drag ? Color.FromArgb(255, 142, 151, 170) : Color.FromArgb(255, 180, 188, 203)))
                g.FillPath(br, path);
        }
        void PageSbDown(object s, MouseEventArgs e)
        {
            var bar = (SBar)s;
            if (e.Button != MouseButtons.Left) return;
            int max = bar.Vp.Height - bar.Host.Height; if (max <= 0) return;
            int lane = bar.Height;
            int th = Math.Max(24, lane * bar.Host.Height / bar.Vp.Height);
            int ty = (lane - th) * (-bar.Vp.Top) / max;
            if (e.Y >= ty && e.Y <= ty + th) { bar.Drag = true; bar.DragOff = e.Y - ty; bar.Capture = true; }
            else ScrollVp(bar, e.Y < ty ? -bar.Host.Height : bar.Host.Height);         // track click: page up/down
        }
        void PageSbMove(object s, MouseEventArgs e)
        {
            var bar = (SBar)s;
            if (!bar.Drag) return;
            int max = bar.Vp.Height - bar.Host.Height;
            int lane = bar.Height;
            int th = Math.Max(24, lane * bar.Host.Height / bar.Vp.Height);
            if (max <= 0 || lane <= th) return;
            SetVpOffset(bar, (e.Y - bar.DragOff) * max / (lane - th));
        }
        void LogSbMetrics(out int first, out int total, out int visible)
        {
            total = TSendMsgInt(log.Handle, 0xBA, 0, 0).ToInt32();                   // EM_GETLINECOUNT
            first = TSendMsgInt(log.Handle, 0xCE, 0, 0).ToInt32();                   // EM_GETFIRSTVISIBLELINE
            int lh = TextRenderer.MeasureText("Ag", log.Font).Height;
            visible = Math.Max(1, log.ClientSize.Height / Math.Max(1, lh));
        }
        void InvalidateLogBar()
        {
            foreach (Control c in logWrap.Controls) { var b = c as SBar; if (b != null) b.Invalidate(); }
        }
        void LogSbPaint(object s, PaintEventArgs e)
        {
            var bar = (SBar)s;
            int first, total, visible;
            LogSbMetrics(out first, out total, out visible);
            if (total <= visible) return;
            int lane = bar.Height;
            int th = Math.Max(20, lane * visible / total);
            int maxFirst = total - visible;
            int ty = maxFirst > 0 ? (lane - th) * first / maxFirst : 0;
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (var path = TRound(new Rectangle(2, ty, 6, th), 3))
            using (var br = new SolidBrush(bar.Drag ? Color.FromArgb(255, 122, 128, 153) : Color.FromArgb(255, 90, 95, 117)))
                g.FillPath(br, path);
        }
        void LogSbDown(object s, MouseEventArgs e)
        {
            var bar = (SBar)s;
            if (e.Button != MouseButtons.Left) return;
            int first, total, visible;
            LogSbMetrics(out first, out total, out visible);
            if (total <= visible) return;
            int lane = bar.Height;
            int th = Math.Max(20, lane * visible / total);
            int maxFirst = total - visible;
            int ty = maxFirst > 0 ? (lane - th) * first / maxFirst : 0;
            if (e.Y >= ty && e.Y <= ty + th) { bar.Drag = true; bar.DragOff = e.Y - ty; bar.Capture = true; }
            else { TSendMsgInt(log.Handle, 0xB6, 0, e.Y < ty ? -visible : visible); bar.Invalidate(); }
        }
        void LogSbMove(object s, MouseEventArgs e)
        {
            var bar = (SBar)s;
            if (!bar.Drag) return;
            int first, total, visible;
            LogSbMetrics(out first, out total, out visible);
            int lane = bar.Height;
            int th = Math.Max(20, lane * visible / total);
            int maxFirst = total - visible;
            if (maxFirst <= 0 || lane <= th) return;
            int target = (e.Y - bar.DragOff) * maxFirst / (lane - th);
            if (target < 0) target = 0; if (target > maxFirst) target = maxFirst;
            int delta = target - first;
            if (delta != 0) { TSendMsgInt(log.Handle, 0xB6, 0, delta); bar.Invalidate(); }
        }

        void Log(string s)
        {
            if (InvokeRequired) { BeginInvoke((Action)delegate { Log(s); }); return; }
            log.AppendText(s + "\r\n");
            if (logWrap != null) InvalidateLogBar();
        }

        void RunAction(object sender, EventArgs e)
        {
            var btn = (Control)sender;                                  // TBtn is a Panel-based custom button
            var a = (ToolAction)btn.Tag;
            btn.Enabled = false;
            Log("== " + a.Name + " ==");
            var t = new System.Threading.Thread((System.Threading.ThreadStart)delegate {
                int errs = 0; bool aborted = false;
                for (int i = 0; i < a.Steps.Count; i++) {
                    bool isBlock = a.Steps[i].Length == 1 && (a.Steps[i][0] == "shellblock" || a.Steps[i][0] == "psblock" || a.Steps[i][0] == "shellblockx" || a.Steps[i][0] == "psblockx");
                    string shown = isBlock ? ("[" + (a.Steps[i][0] == "shellblock" ? "shell" : a.Steps[i][0] == "shellblockx" ? "shellx" : a.Steps[i][0] == "psblockx" ? "psx" : "powershell") + L("] 多行脚本块", "] multi-line script")) : a.Raw[i];
                    var sb = new StringBuilder();
                    string r = ExecToolStep(a.Steps[i], isBlock ? a.Raw[i] : ToolRest(a.Raw[i]), sb, Ui());
                    if (sb.Length > 0) Log(sb.ToString().Trim());
                    if (r == "abort") { aborted = true; break; }
                    if (r != null) { errs++; Log("  [失败] " + shown + "  ->  " + r); }
                    else Log("  [ok] " + shown);
                }
                Log(aborted ? L("-- 已取消 --", "-- aborted --") : (errs == 0 ? L("-- 完成 --", "-- done --") : L("-- 完成, ", "-- done, ") + errs + L(" 个步骤失败 --", " step(s) failed --")));
                try { BeginInvoke((Action)delegate { btn.Enabled = true; }); } catch {}
            });
            t.IsBackground = true;
            t.Start();
        }
    }
    // ---------- embedded network tools (builtin:nettools) ----------
    Form netForm;

    void ShowNetTools()
    {
        if (netForm != null && !netForm.IsDisposed) { netForm.Show(); netForm.Activate(); return; }
        netForm = new NetToolsForm();
        netForm.Show();
    }

    // --- testable statics (no UI) ---
    internal static string PingOnce(string host, int timeoutMs)     // one ICMP echo -> result line
    {
        try {
            using (var p = new System.Net.NetworkInformation.Ping()) {
                var rep = p.Send(host, timeoutMs);
                if (rep.Status == System.Net.NetworkInformation.IPStatus.Success)
                    return string.Format("reply from {0}: time={1}ms ttl={2} bytes={3}", rep.Address, rep.RoundtripTime, rep.Options != null ? rep.Options.Ttl : -1, rep.Buffer.Length);
                return "status: " + rep.Status;
            }
        } catch (Exception ex) { return "error: " + ex.Message; }
    }

    internal static bool PingRtt(string host, int size, int timeoutMs, out long rtt)   // structured ping probe: success + roundtrip
    {
        rtt = -1;
        try {
            using (var p = new System.Net.NetworkInformation.Ping()) {
                if (size < 1) size = 1; if (size > 65500) size = 65500;
                var rep = p.Send(host, timeoutMs, new byte[size]);
                if (rep.Status == System.Net.NetworkInformation.IPStatus.Success) { rtt = rep.RoundtripTime; return true; }
                return false;
            }
        } catch { return false; }
    }

    internal static string HopOnce(string host, int ttl, int timeoutMs, out bool done)   // one traceroute hop
    {
        done = false;
        try {
            using (var p = new System.Net.NetworkInformation.Ping()) {
                var rep = p.Send(host, timeoutMs, new byte[32], new System.Net.NetworkInformation.PingOptions(ttl, true));
                if (rep.Status == System.Net.NetworkInformation.IPStatus.Success) { done = true; return ttl + "  " + rep.Address + "  " + rep.RoundtripTime + "ms  (done)"; }
                if (rep.Status == System.Net.NetworkInformation.IPStatus.TtlExpired || rep.Status == System.Net.NetworkInformation.IPStatus.TimeExceeded)
                    return ttl + "  " + rep.Address + "  " + rep.RoundtripTime + "ms";
                return ttl + "  " + rep.Status;
            }
        } catch (Exception ex) { return ttl + "  error: " + ex.Message; }
    }

    internal static string TestPort(string host, int port, int timeoutMs)   // TCP connect probe
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try {
            using (var tc = new System.Net.Sockets.TcpClient()) {
                var ar = tc.BeginConnect(host, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs)) return "closed (timeout " + timeoutMs + "ms)";
                tc.EndConnect(ar);
                return "open  " + sw.ElapsedMilliseconds + "ms";
            }
        } catch (Exception ex) { return "closed (" + ex.GetType().Name + ")"; }
    }

    static uint ParseIpV4(string s)
    {
        var b = System.Net.IPAddress.Parse(s.Trim()).GetAddressBytes();
        if (b.Length != 4) throw new Exception("IPv4 only");
        return ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
    }
    static string IpStr(uint v) { return ((v >> 24) & 255) + "." + ((v >> 16) & 255) + "." + ((v >> 8) & 255) + "." + (v & 255); }
    static int MaskToBits(uint m)
    {
        int bits = 0; bool zero = false;
        for (int i = 31; i >= 0; i--) {
            bool bit = (m & (1u << i)) != 0;
            if (bit && zero) return -1;         // non-contiguous mask
            if (!bit) zero = true; else bits++;
        }
        return bits;
    }

    static void ParseIpMask(string ipText, string maskText, out uint ip, out int bits, out uint mask)
    {
        ip = ParseIpV4(ipText);
        maskText = maskText.Trim();
        if (maskText.StartsWith("/")) maskText = maskText.Substring(1);
        if (maskText.IndexOf('.') >= 0) {
            mask = ParseIpV4(maskText);
            bits = MaskToBits(mask);
            if (bits < 0) throw new Exception(L("掩码不连续", "non-contiguous mask"));
        } else {
            bits = int.Parse(maskText);
            if (bits < 0 || bits > 32) throw new Exception("bad prefix");
            mask = bits == 0 ? 0u : 0xFFFFFFFFu << (32 - bits);
        }
    }
    internal static string IpType(uint v)
    {
        uint a = v >> 24, b = (v >> 16) & 255;
        if (v == 0) return L("未指定地址", "unspecified");
        if (a == 127) return L("回环地址 (loopback)", "loopback");
        if (a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)) return L("私有地址 (RFC1918)", "private (RFC1918)");
        if (a == 169 && b == 254) return L("链路本地 (APIPA)", "link-local (APIPA)");
        if (a == 100 && b >= 64 && b <= 127) return L("运营商级 NAT (CGNAT)", "carrier-grade NAT");
        if (a >= 224 && a <= 239) return L("组播 (multicast)", "multicast");
        if (a >= 240) return L("保留 (reserved)", "reserved");
        return L("公网地址", "public");
    }
    internal static string IpClass(uint v)
    {
        uint a = v >> 24;
        if (a < 128) return "A";
        if (a < 192) return "B";
        if (a < 224) return "C";
        if (a < 240) return "D";
        return "E";
    }

    internal static string[] SubnetCalc(string ipText, string maskText)     // "192.168.1.10" + "24" or "255.255.255.0"
    {
        uint ip, mask; int bits;
        ParseIpMask(ipText, maskText, out ip, out bits, out mask);
        uint net = ip & mask, bc = net | ~mask;
        uint first = bits >= 31 ? net : net + 1, last = bits >= 31 ? bc : bc - 1;
        long hosts = bits == 32 ? 1 : (bits == 31 ? 2 : (long)(bc - net - 1));
        string mb = System.Convert.ToString(mask, 2).PadLeft(32, '0');
        return new string[] {
            L("掩码", "Mask") + ":        " + IpStr(mask) + "  (/" + bits + ")",
            L("通配符", "Wildcard") + ":    " + IpStr(~mask),
            L("网络地址", "Network") + ":   " + IpStr(net),
            L("广播地址", "Broadcast") + ": " + IpStr(bc),
            L("可用范围", "Host range") + ":  " + IpStr(first) + " - " + IpStr(last),
            L("可用主机数", "Hosts") + ":     " + hosts,
            L("地址类型", "Type") + ":      " + IpType(ip) + "  (" + L("类别", "Class") + " " + IpClass(ip) + ")",
            L("二进制", "Binary") + ":      " + mb.Substring(0, 8) + "." + mb.Substring(8, 8) + "." + mb.Substring(16, 8) + "." + mb.Substring(24, 8),
        };
    }

    internal static string[] SubnetSplit(string ipText, string maskText, int count)   // split a network into >=count subnets
    {
        uint ip, mask; int bits;
        ParseIpMask(ipText, maskText, out ip, out bits, out mask);
        if (count < 2) count = 2;
        int extra = 0;
        while ((1 << extra) < count) extra++;
        int nb = bits + extra;
        if (nb > 30) throw new Exception(L("拆得太碎了 (主机数不足)", "too many subnets (no hosts left)"));
        uint net = ip & mask;
        long per = 1L << (32 - nb);
        var lines = new List<string>();
        lines.Add(L("拆分", "split") + " " + IpStr(net) + "/" + bits + L(" 为 ", " into ") + (1 << extra) + L(" 个 /", " x /") + nb + ":");
        for (int i = 0; i < (1 << extra); i++) {
            uint sn = (uint)(net + i * per);
            uint en = (uint)(sn + per - 1);
            long hosts = per - 2;
            lines.Add("  " + IpStr(sn) + "/" + nb + "   " + IpStr(sn + 1) + " - " + IpStr(en - 1) + "   (" + hosts + ")");
        }
        return lines.ToArray();
    }

    internal static string[] RangeToCidr(string a, string b)                 // minimal CIDR set covering an IP range
    {
        uint lo = ParseIpV4(a), hi = ParseIpV4(b);
        if (hi < lo) { uint t = lo; lo = hi; hi = t; }
        var lines = new List<string>();
        long cur = lo;
        while (cur <= hi) {
            int tz = 0;                                                      // largest aligned block at cur
            if (cur == 0) tz = 32;
            else { while (tz < 32 && (cur & (1L << tz)) == 0) tz++; }
            long remaining = hi - cur + 1;
            int fb = 0;                                                      // largest block fitting the remainder
            while ((1L << (fb + 1)) <= remaining) fb++;
            int size = Math.Min(tz, fb);
            lines.Add(IpStr((uint)cur) + "/" + (32 - size));
            cur += 1L << size;
        }
        return lines.ToArray();
    }

    internal static string[] MaskTable()                                     // common prefix cheat sheet
    {
        int[] bs = { 8, 16, 20, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32 };
        var lines = new List<string>();
        lines.Add(L("前缀    掩码              可用主机     通配符", "prefix  mask            hosts        wildcard"));
        foreach (int b in bs) {
            uint mask = b == 0 ? 0u : 0xFFFFFFFFu << (32 - b);
            long hosts = b == 32 ? 1 : (b == 31 ? 2 : ((1L << (32 - b)) - 2));
            lines.Add("/" + b.ToString().PadRight(7) + IpStr(mask).PadRight(16) + hosts.ToString().PadRight(13) + IpStr(~mask));
        }
        return lines.ToArray();
    }

    internal static string LocalNetInfo()
    {
        var sb = new StringBuilder();
        sb.AppendLine(L("主机名", "Host") + ": " + System.Net.Dns.GetHostName());
        foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()) {
            if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
            sb.AppendLine("[" + ni.Name + "] " + ni.NetworkInterfaceType);
            var props = ni.GetIPProperties();
            foreach (var ua in props.UnicastAddresses)
                if (ua.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                    sb.AppendLine("  IPv4: " + ua.Address + " / " + ua.IPv4Mask);
            foreach (var gw in props.GatewayAddresses) sb.AppendLine("  " + L("网关", "Gateway") + ": " + gw.Address);
            foreach (var dns in props.DnsAddresses) sb.AppendLine("  DNS: " + dns);
        }
        return sb.ToString();
    }

    // ---------- DNS / HTTP probes (raw implementations, no external deps) ----------
    internal static string[] DnsQuery(string name, string qtype, string server, int timeoutMs)
    {
        int qt;
        switch (qtype.ToUpper()) { case "A": qt = 1; break; case "NS": qt = 2; break; case "CNAME": qt = 5; break; case "PTR": qt = 12; break; case "MX": qt = 15; break; case "TXT": qt = 16; break; case "AAAA": qt = 28; break; default: throw new Exception("bad type"); }
        ushort id = (ushort)new Random().Next(65536);
        var ms = new MemoryStream();
        var bw = new BinaryWriter(ms);
        DnsBE16(bw, id); DnsBE16(bw, 0x0100); DnsBE16(bw, 1); DnsBE16(bw, 0); DnsBE16(bw, 0); DnsBE16(bw, 0);
        foreach (var label in name.Trim().TrimEnd('.').Split('.')) { var lb = Encoding.ASCII.GetBytes(label); bw.Write((byte)lb.Length); bw.Write(lb); }
        bw.Write((byte)0); DnsBE16(bw, (ushort)qt); DnsBE16(bw, 1);
        byte[] resp;
        using (var udp = new System.Net.Sockets.UdpClient()) {
            udp.Client.ReceiveTimeout = timeoutMs;
            udp.Send(ms.ToArray(), (int)ms.Length, server, 53);
            var ep = new System.Net.IPEndPoint(System.Net.IPAddress.Any, 0);
            resp = udp.Receive(ref ep);
        }
        int rcode = resp[3] & 15;
        if (rcode != 0) return new string[] { "DNS rcode=" + rcode + (rcode == 3 ? " (NXDOMAIN)" : "") };
        int qd = DnsU16(resp, 4), an = DnsU16(resp, 6);
        int pos = 12;
        for (int i = 0; i < qd; i++) { pos = DnsSkipName(resp, pos); pos += 4; }
        var lines = new List<string>();
        for (int i = 0; i < an; i++) {
            string owner = DnsReadName(resp, ref pos);
            int type = DnsU16(resp, pos);
            long ttl = DnsU32(resp, pos + 4);
            int rdlen = DnsU16(resp, pos + 8);
            int rstart = pos + 10;
            string val;
            if (type == 1) val = resp[rstart] + "." + resp[rstart + 1] + "." + resp[rstart + 2] + "." + resp[rstart + 3];
            else if (type == 28) { var b6 = new byte[16]; Array.Copy(resp, rstart, b6, 0, 16); val = new System.Net.IPAddress(b6).ToString(); }
            else if (type == 2 || type == 5 || type == 12) { int p2 = rstart; val = DnsReadName(resp, ref p2); }
            else if (type == 15) { int p2 = rstart + 2; val = DnsU16(resp, rstart) + " " + DnsReadName(resp, ref p2); }
            else if (type == 16) {
                var sb2 = new StringBuilder(); int p2 = rstart, end = rstart + rdlen;
                while (p2 < end) { int ln = resp[p2++]; sb2.Append(Encoding.UTF8.GetString(resp, p2, ln)); p2 += ln; if (p2 < end) sb2.Append(" | "); }
                val = sb2.ToString();
            }
            else val = "type " + type + " (" + rdlen + " bytes)";
            pos = rstart + rdlen;
            string tn = type == 1 ? "A" : type == 28 ? "AAAA" : type == 2 ? "NS" : type == 5 ? "CNAME" : type == 12 ? "PTR" : type == 15 ? "MX" : type == 16 ? "TXT" : type.ToString();
            lines.Add(owner + "   ttl=" + ttl + "   " + tn + "   " + val);
        }
        if (lines.Count == 0) lines.Add(L("无记录", "no records"));
        return lines.ToArray();
    }
    static void DnsBE16(BinaryWriter w, ushort v) { w.Write((byte)(v >> 8)); w.Write((byte)(v & 255)); }
    static int DnsU16(byte[] m, int p) { return (m[p] << 8) | m[p + 1]; }
    static long DnsU32(byte[] m, int p) { return ((long)m[p] << 24) | ((long)m[p + 1] << 16) | ((long)m[p + 2] << 8) | m[p + 3]; }
    static int DnsSkipName(byte[] m, int pos) { while (true) { int len = m[pos]; if (len == 0) return pos + 1; if ((len & 0xC0) == 0xC0) return pos + 2; pos += 1 + len; } }
    static string DnsReadName(byte[] m, ref int pos)
    {
        var sb = new StringBuilder();
        int p = pos; bool jumped = false; int guard = 0;
        while (true) {
            if (guard++ > 128) throw new Exception("dns name loop");
            int len = m[p];
            if (len == 0) { if (!jumped) pos = p + 1; break; }
            if ((len & 0xC0) == 0xC0) { int ptr = ((len & 0x3F) << 8) | m[p + 1]; if (!jumped) pos = p + 2; p = ptr; jumped = true; continue; }
            if (sb.Length > 0) sb.Append('.');
            sb.Append(Encoding.ASCII.GetString(m, p + 1, len));
            p += 1 + len;
            if (!jumped) pos = p;
        }
        return sb.ToString();
    }

    internal static string[] HttpCheck(string url, int timeoutMs)
    {
        if (url.IndexOf("://") < 0) url = "https://" + url;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        var lines = new List<string>();
        try {
            var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(url);
            req.Timeout = timeoutMs; req.ReadWriteTimeout = timeoutMs; req.UserAgent = "WgIme-NetTools";
            using (var resp = (System.Net.HttpWebResponse)req.GetResponse()) {
                long ttfb = sw.ElapsedMilliseconds;
                string redir = resp.ResponseUri.ToString() != url ? "  (-> " + resp.ResponseUri.Host + ")" : "";
                lines.Add("HTTP " + (int)resp.StatusCode + " " + resp.StatusDescription + redir);
                if (resp.Headers["Server"] != null) lines.Add("Server: " + resp.Headers["Server"]);
                if (resp.ContentType != null && resp.ContentType.Length > 0) lines.Add("Content-Type: " + resp.ContentType);
                using (var st = resp.GetResponseStream()) {
                    var buf = new byte[8192]; long total = 0; int n;
                    while ((n = st.Read(buf, 0, buf.Length)) > 0) total += n;
                    lines.Add("Body: " + total + " bytes");
                }
                lines.Add("TTFB: " + ttfb + "ms   Total: " + sw.ElapsedMilliseconds + "ms");
            }
        } catch (System.Net.WebException we) {
            var r2 = we.Response as System.Net.HttpWebResponse;
            if (r2 != null) lines.Add("HTTP " + (int)r2.StatusCode + " " + r2.StatusDescription);
            else lines.Add("Err: " + we.Message);
        } catch (Exception ex) { lines.Add("Err: " + ex.Message); }
        return lines.ToArray();
    }

    internal static string PublicIp(int timeoutMs)
    {
        try {
            var req = (System.Net.HttpWebRequest)System.Net.WebRequest.Create("https://api.ipify.org");
            req.Timeout = timeoutMs; req.UserAgent = "WgIme-NetTools";
            using (var resp = req.GetResponse())
            using (var rd = new StreamReader(resp.GetResponseStream())) return rd.ReadToEnd().Trim();
        } catch { return null; }
    }

    class NetToolsForm : Form
    {
        // ---------- palette (matches clock/toolbox: blue-gray body, white cards, dark console) ----------
        static readonly Color NC_BG = Color.FromArgb(255, 232, 237, 245);
        static readonly Color NC_HEADER = Color.FromArgb(255, 220, 227, 239);
        static readonly Color NC_CARD = Color.FromArgb(255, 255, 255, 255);
        static readonly Color NC_SURF2 = Color.FromArgb(255, 217, 224, 236);
        static readonly Color NC_BORDER = Color.FromArgb(255, 195, 204, 221);
        static readonly Color NC_TEXT = Color.FromArgb(255, 29, 29, 31);
        static readonly Color NC_SUB = Color.FromArgb(255, 110, 116, 133);
        static readonly Color NC_ACCENT = Color.FromArgb(255, 0, 122, 255);
        static readonly Color NC_CONBG = Color.FromArgb(255, 46, 48, 64);
        static readonly Color NC_CONFG = Color.FromArgb(255, 214, 217, 226);

        internal static Font TF(float size, FontStyle st)
        {
            string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
            foreach (string n in names) { try { return new Font(n, size, st, GraphicsUnit.Point); } catch {} }
            return new Font(FontFamily.GenericSansSerif, size, st, GraphicsUnit.Point);
        }
        static System.Drawing.Drawing2D.GraphicsPath NRound(Rectangle r, int rad)
        {
            var p = new System.Drawing.Drawing2D.GraphicsPath();
            int d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        [DllImport("user32.dll", EntryPoint = "ReleaseCapture")] static extern bool NReleaseCapture();
        [DllImport("user32.dll", EntryPoint = "SendMessage")] static extern IntPtr NSendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "SendMessage")] static extern IntPtr NSendMsgInt(IntPtr h, int msg, int w, int l);
        [DllImport("gdi32.dll", EntryPoint = "CreateRoundRectRgn")] static extern IntPtr NCreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
        [DllImport("user32.dll", EntryPoint = "SetWindowRgn")] static extern int NSetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);

        class NBtn : Panel
        {
            public Color Bg = Color.FromArgb(255, 255, 255, 255);
            public Color BgHover = Color.FromArgb(255, 240, 243, 249);
            public Color BgDown = Color.FromArgb(255, 226, 232, 242);
            public Color Fg = Color.FromArgb(255, 29, 29, 31);
            public bool AccentLine, Selected, Primary;
            bool hover, down;
            public NBtn() { DoubleBuffered = true; Cursor = Cursors.Hand; }
            protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
            protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
            protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
            protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
                var rect = new Rectangle(0, 0, Width - 1, Height - 1);
                Color fill;
                if (!Enabled) fill = Color.FromArgb(255, 243, 243, 246);
                else if (Primary) fill = down ? Color.FromArgb(255, 0, 108, 224) : (hover ? Color.FromArgb(255, 26, 134, 255) : NC_ACCENT);
                else fill = down ? BgDown : (hover ? BgHover : Bg);
                using (var path = NRound(rect, 7))
                using (var br = new SolidBrush(fill)) { g.FillPath(br, path); }
                if (AccentLine && Selected) { using (var br = new SolidBrush(NC_ACCENT)) g.FillRectangle(br, 10, Height - 4, Width - 20, 3); }
                Color fg = Primary ? Color.White : (!Enabled ? NC_SUB : (Selected ? NC_TEXT : Fg));
                using (var br = new SolidBrush(fg))
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                    g.DrawString(Text, Font, br, new RectangleF(2, 0, Width - 4, Height), sf);
            }
        }
        class NEdit : Panel
        {
            public readonly TextBox Box;
            public NEdit(int x, int y, int w, string text)
            {
                Location = new Point(x, y); Size = new Size(w, 28);
                DoubleBuffered = true; BackColor = NC_CARD; Cursor = Cursors.IBeam;
                Box = new TextBox { BorderStyle = BorderStyle.None, Font = TF(9.5F, FontStyle.Regular), Dock = DockStyle.Fill,
                    BackColor = NC_CARD, ForeColor = NC_TEXT, Text = text };
                Padding = new Padding(9, 4, 9, 3);
                Controls.Add(Box);
                Click += delegate { Box.Focus(); };
                Box.Enter += delegate { Invalidate(); };
                Box.Leave += delegate { Invalidate(); };
            }
            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
                var rect = new Rectangle(0, 0, Width - 1, Height - 1);
                using (var path = NRound(rect, 7))
                using (var br = new SolidBrush(NC_CARD)) { g.FillPath(br, path); }
                using (var path = NRound(rect, 7))
                using (var pen = new Pen(Box.Focused ? NC_ACCENT : NC_BORDER, Box.Focused ? 2F : 1F)) { g.DrawPath(pen, path); }
            }
        }
        class NLog : Panel                       // dark console with a slim self-drawn scrollbar
        {
            class DBP : Panel { public DBP() { DoubleBuffered = true; } }
            public readonly TextBox Box;
            readonly Panel bar;
            readonly Timer sync;
            bool drag; int dragOff;
            int lastFirst = -1, lastTotal = -1;              // repaint only when metrics change (no jitter)
            public NLog(int x, int y, int w, int h)
            {
                Location = new Point(x, y); Size = new Size(w, h);
                BackColor = NC_CONBG; Padding = new Padding(10, 8, 4, 8);
                Box = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, BorderStyle = BorderStyle.None, ScrollBars = ScrollBars.None,
                    BackColor = NC_CONBG, ForeColor = NC_CONFG, Font = new Font("Consolas", 9.5F) };
                Controls.Add(Box);
                bar = new DBP { Dock = DockStyle.Right, Width = 10, BackColor = NC_CONBG };
                Controls.Add(bar);
                bar.Paint += PaintBar;
                bar.MouseDown += delegate(object s, MouseEventArgs e) {
                    if (e.Button != MouseButtons.Left) return;
                    int first, total, visible; Metrics(out first, out total, out visible);
                    if (total <= visible) return;
                    int lane = bar.Height, th = Math.Max(20, lane * visible / total), maxF = total - visible;
                    int ty = maxF > 0 ? (lane - th) * first / maxF : 0;
                    if (e.Y >= ty && e.Y <= ty + th) { drag = true; dragOff = e.Y - ty; bar.Capture = true; }
                    else { NSendMsgInt(Box.Handle, 0xB6, 0, e.Y < ty ? -visible : visible); bar.Invalidate(); }
                };
                bar.MouseMove += delegate(object s, MouseEventArgs e) {
                    if (!drag) return;
                    int first, total, visible; Metrics(out first, out total, out visible);
                    int lane = bar.Height, th = Math.Max(20, lane * visible / total), maxF = total - visible;
                    if (maxF <= 0 || lane <= th) return;
                    int target = (e.Y - dragOff) * maxF / (lane - th);
                    if (target < 0) target = 0; if (target > maxF) target = maxF;
                    int delta = target - first;
                    if (delta != 0) { NSendMsgInt(Box.Handle, 0xB6, 0, delta); bar.Invalidate(); }
                };
                bar.MouseUp += delegate { drag = false; bar.Capture = false; bar.Invalidate(); };
                sync = new Timer { Interval = 150 };
                sync.Tick += delegate {
                    int f, t, v; Metrics(out f, out t, out v);
                    if (f != lastFirst || t != lastTotal) { lastFirst = f; lastTotal = t; bar.Invalidate(); }
                };
                HandleCreated += delegate { sync.Start(); };
                Disposed += delegate { sync.Stop(); sync.Dispose(); };
            }
            void Metrics(out int first, out int total, out int visible)
            {
                total = NSendMsgInt(Box.Handle, 0xBA, 0, 0).ToInt32();
                first = NSendMsgInt(Box.Handle, 0xCE, 0, 0).ToInt32();
                int lh = TextRenderer.MeasureText("Ag", Box.Font).Height;
                visible = Math.Max(1, Box.ClientSize.Height / Math.Max(1, lh));
            }
            void PaintBar(object s, PaintEventArgs e)
            {
                int first, total, visible; Metrics(out first, out total, out visible);
                if (total <= visible) return;
                int lane = bar.Height, th = Math.Max(20, lane * visible / total), maxF = total - visible;
                int ty = maxF > 0 ? (lane - th) * first / maxF : 0;
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var path = NRound(new Rectangle(2, ty, 6, th), 3))
                using (var br = new SolidBrush(drag ? Color.FromArgb(255, 122, 128, 153) : Color.FromArgb(255, 90, 95, 117)))
                    g.FillPath(br, path);
            }
            public void Line(string s)
            {
                if (IsDisposed) return;
                if (InvokeRequired) { try { BeginInvoke((Action)delegate { Line(s); }); } catch {} return; }
                Box.AppendText(s + "\r\n"); bar.Invalidate();
            }
            public void Set(string s) { Box.Text = s; bar.Invalidate(); }
            public void Save(Control owner)
            {
                using (var dlg = new SaveFileDialog { Filter = "log|*.txt", FileName = "netlog-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt" }) {
                    if (dlg.ShowDialog(owner) == DialogResult.OK) { try { File.WriteAllText(dlg.FileName, Box.Text, Encoding.UTF8); } catch {} }
                }
            }
        }

        readonly List<Panel> pages = new List<Panel>();
        readonly List<NBtn> chips = new List<NBtn>();

        public NetToolsForm()
        {
            Text = L("网络工具  (WgTray)", "Network Tools  (WgTray)");
            FormBorderStyle = FormBorderStyle.None;
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            KeyPreview = true;
            ClientSize = new Size(640, 520);
            BackColor = NC_BG;
            EventHandler rg = delegate { try { NSetWindowRgn(Handle, NCreateRoundRectRgn(0, 0, Width + 1, Height + 1, 20, 20), true); } catch {} };
            HandleCreated += delegate { rg(this, EventArgs.Empty); };
            Resize += delegate { rg(this, EventArgs.Empty); };
            Paint += delegate(object s, PaintEventArgs e) {
                var g = e.Graphics; g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var path = NRound(new Rectangle(1, 1, Width - 3, Height - 3), 9))
                using (var pen = new Pen(NC_BORDER, 1)) { g.DrawPath(pen, path); }
            };

            var header = new Panel { Location = new Point(0, 0), Size = new Size(640, 38), BackColor = NC_HEADER };
            var cap = new Label { Text = L("网络工具", "Network Tools"), AutoSize = true, Location = new Point(14, 9),
                Font = TF(10F, FontStyle.Bold), ForeColor = NC_TEXT, BackColor = Color.Transparent };
            var close = new Label { Text = "✕", Size = new Size(30, 26), Location = new Point(602, 6), TextAlign = ContentAlignment.MiddleCenter,
                Font = TF(10F, FontStyle.Regular), ForeColor = NC_TEXT, BackColor = Color.Transparent, Cursor = Cursors.Hand };
            close.MouseEnter += delegate { close.BackColor = Color.FromArgb(255, 232, 17, 35); close.ForeColor = Color.White; };
            close.MouseLeave += delegate { close.BackColor = Color.Transparent; close.ForeColor = NC_TEXT; };
            close.Click += delegate { Close(); };
            header.Controls.Add(cap); header.Controls.Add(close);
            header.Paint += delegate(object s, PaintEventArgs e) {
                using (var pen = new Pen(NC_BORDER)) e.Graphics.DrawLine(pen, 0, header.Height - 1, header.Width, header.Height - 1);
            };
            MouseEventHandler drag = delegate(object s, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                try { NReleaseCapture(); NSendMessage(Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } catch {}
            };
            header.MouseDown += drag; cap.MouseDown += drag;
            Controls.Add(header);

            var strip = new Panel { Location = new Point(0, 38), Size = new Size(640, 40), BackColor = NC_BG };
            Controls.Add(strip);

            int contentH = 520 - 78;
            Panel topPing, topTrace, topDns, topHttp, topPort, topSubnet, topLocal;
            NLog logPing, logTrace, logDns, logHttp, logPort, logSubnet, logLocal;
            pages.Add(MakePage(0, contentH, 44, out topPing, out logPing));
            pages.Add(MakePage(1, contentH, 44, out topTrace, out logTrace));
            pages.Add(MakePage(2, contentH, 76, out topDns, out logDns));
            pages.Add(MakePage(3, contentH, 44, out topHttp, out logHttp));
            pages.Add(MakePage(4, contentH, 44, out topPort, out logPort));
            pages.Add(MakePage(5, contentH, 76, out topSubnet, out logSubnet));
            pages.Add(MakePage(6, contentH, 44, out topLocal, out logLocal));

            string[] names = { "Ping", "Tracert", "DNS", "HTTP", L("端口", "Ports"), L("子网", "Subnet"), L("本机", "Local") };
            int chipW = (640 - 28) / names.Length;
            for (int i = 0; i < names.Length; i++) {
                var b = new NBtn { Text = names[i], Font = TF(9.5F, FontStyle.Regular), AccentLine = true, Selected = (i == 0),
                    Bg = NC_BG, BgHover = NC_SURF2, BgDown = NC_SURF2, Fg = NC_SUB,
                    Size = new Size(chipW, 28), Location = new Point(14 + i * chipW, 6) };
                int idx = i;
                b.Click += delegate {
                    for (int j = 0; j < chips.Count; j++) { chips[j].Selected = (j == idx); chips[j].Invalidate(); pages[j].Visible = (j == idx); }
                };
                chips.Add(b); strip.Controls.Add(b);
            }

            BuildPingTab(topPing, logPing);
            BuildTracertTab(topTrace, logTrace);
            BuildDnsTab(topDns, logDns);
            BuildHttpTab(topHttp, logHttp);
            BuildPortTab(topPort, logPort);
            BuildSubnetTab(topSubnet, logSubnet);
            BuildLocalTab(topLocal, logLocal);

            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
        }

        Panel MakePage(int idx, int contentH, int topH, out Panel top, out NLog log)
        {
            var page = new Panel { Location = new Point(0, 78), Size = new Size(640, contentH), BackColor = NC_BG, Visible = (idx == 0) };
            top = new Panel { Location = new Point(0, 0), Size = new Size(640, topH), BackColor = NC_BG };
            log = new NLog(0, topH, 640, contentH - topH);
            page.Controls.Add(top); page.Controls.Add(log);
            Controls.Add(page);
            return page;
        }
        NBtn MkBtn(Control parent, int x, int y, int w, string text, bool primary)
        {
            var b = new NBtn { Text = text, Font = TF(9F, FontStyle.Regular), Location = new Point(x, y), Size = new Size(w, 28), Primary = primary };
            parent.Controls.Add(b);
            return b;
        }
        void Bg(System.Threading.ThreadStart fn) { var t = new System.Threading.Thread(fn); t.IsBackground = true; t.Start(); }
        static string Stamp(string s) { return DateTime.Now.ToString("HH:mm:ss") + "  " + s; }

        void BuildPingTab(Panel top, NLog log)
        {
            var host = new NEdit(12, 8, 180, "223.5.5.5");
            var cnt = new NEdit(200, 8, 50, "4");
            var size = new NEdit(258, 8, 64, "32");
            var lblB = new Label { Text = "B", Location = new Point(326, 13), AutoSize = true, Font = TF(9F, FontStyle.Regular), ForeColor = NC_SUB, BackColor = Color.Transparent };
            var btn = MkBtn(top, 348, 8, 70, "Ping", true);
            var stop = MkBtn(top, 424, 8, 60, L("停止", "Stop"), false);
            var clear = MkBtn(top, 514, 8, 52, L("清除", "Clear"), false);
            var save = MkBtn(top, 572, 8, 56, L("保存", "Save"), false);
            top.Controls.Add(host); top.Controls.Add(cnt); top.Controls.Add(size); top.Controls.Add(lblB);
            bool[] cancel = new bool[1];
            btn.Click += delegate {
                btn.Enabled = false; cancel[0] = false;
                int n; if (!int.TryParse(cnt.Box.Text, out n) || n < 0) n = 4;
                int sz; if (!int.TryParse(size.Box.Text, out sz) || sz < 1) sz = 32;
                string h = host.Box.Text.Trim();
                log.Line(Stamp("-- ping " + h + " x" + (n == 0 ? "∞" : n.ToString()) + "  size=" + sz + "B --"));
                Bg(delegate {
                    int sent = 0, ok = 0;
                    long min = long.MaxValue, max = 0, sum = 0;
                    while (!cancel[0] && (n == 0 || sent < n)) {
                        sent++;
                        long rtt;
                        if (PingRtt(h, sz, 2000, out rtt)) {
                            ok++; sum += rtt; if (rtt < min) min = rtt; if (rtt > max) max = rtt;
                            log.Line(Stamp("reply: seq=" + sent + " time=" + rtt + "ms"));
                        } else log.Line(Stamp("timeout: seq=" + sent));
                        if (n == 0 || sent < n) System.Threading.Thread.Sleep(800);
                    }
                    if (sent > 0 && n != 0) {                                   // finite run: summary line
                        double loss = 100.0 * (sent - ok) / sent;
                        string stat = L("统计: 已发 ", "stats: sent ") + sent + L(" 已收 ", " recv ") + ok + L(" 丢包 ", " loss ") + loss.ToString("0.#") + "%";
                        if (ok > 0) stat += L(" 时延 min/avg/max = ", " rtt min/avg/max = ") + min + "/" + (sum / ok) + "/" + max + "ms";
                        log.Line(Stamp("-- " + stat + " --"));
                    }
                    try { btn.BeginInvoke((Action)delegate { btn.Enabled = true; }); } catch {}
                });
            };
            stop.Click += delegate { cancel[0] = true; };
            clear.Click += delegate { log.Set(""); };
            save.Click += delegate { log.Save(this); };
            log.Line(L("主机 + 次数 (0=持续) + 包大小(字节); 有限次数跑完输出 丢包率/时延统计", "host + count (0=loop) + packet bytes; finite runs end with loss/rtt stats"));
        }

        void BuildTracertTab(Panel top, NLog log)
        {
            var host = new NEdit(12, 8, 210, "223.5.5.5");
            var btn = MkBtn(top, 230, 8, 120, L("开始路由跟踪", "Trace route"), true);
            var clear = MkBtn(top, 514, 8, 52, L("清除", "Clear"), false);
            var save = MkBtn(top, 572, 8, 56, L("保存", "Save"), false);
            top.Controls.Add(host);
            btn.Click += delegate {
                btn.Enabled = false;
                log.Line(Stamp("-- tracert " + host.Box.Text.Trim() + " --"));
                Bg(delegate {
                    for (int ttl = 1; ttl <= 30; ttl++) {
                        bool done;
                        log.Line(HopOnce(host.Box.Text.Trim(), ttl, 2000, out done));
                        if (done) break;
                    }
                    try { btn.BeginInvoke((Action)delegate { btn.Enabled = true; }); } catch {}
                });
            };
            clear.Click += delegate { log.Set(""); };
            save.Click += delegate { log.Save(this); };
        }

        void BuildDnsTab(Panel top, NLog log)
        {
            var name = new NEdit(12, 8, 240, "www.baidu.com");
            var server = new NEdit(260, 8, 130, "223.5.5.5");
            var btn = MkBtn(top, 398, 8, 90, L("查询", "Query"), true);
            var clear = MkBtn(top, 514, 8, 52, L("清除", "Clear"), false);
            var save = MkBtn(top, 572, 8, 56, L("保存", "Save"), false);
            top.Controls.Add(name); top.Controls.Add(server);
            string[] types = { "A", "AAAA", "CNAME", "MX", "TXT", "NS", "PTR" };
            var toggles = new NBtn[types.Length];
            string[] cur = { "A" };
            for (int i = 0; i < types.Length; i++) {
                var t = new NBtn { Text = types[i], Font = TF(8.5F, FontStyle.Regular), Location = new Point(12 + i * 66, 42),
                    Size = new Size(60, 26), Selected = (i == 0), Bg = NC_CARD, Fg = NC_SUB };
                int ti = i;
                t.Click += delegate {
                    cur[0] = types[ti];
                    for (int j = 0; j < toggles.Length; j++) { toggles[j].Selected = (j == ti); toggles[j].Primary = (j == ti); toggles[j].Invalidate(); }
                };
                toggles[i] = t; top.Controls.Add(t);
            }
            toggles[0].Primary = true;
            btn.Click += delegate {
                btn.Enabled = false;
                string nm = name.Box.Text.Trim(), sv = server.Box.Text.Trim(), tp = cur[0];
                log.Line(Stamp("-- dns " + tp + " " + nm + "  @" + sv + " --"));
                Bg(delegate {
                    try { foreach (var ln in DnsQuery(nm, tp, sv, 3000)) log.Line(ln); }
                    catch (Exception ex) { log.Line("Err: " + ex.Message); }
                    try { btn.BeginInvoke((Action)delegate { btn.Enabled = true; }); } catch {}
                });
            };
            clear.Click += delegate { log.Set(""); };
            save.Click += delegate { log.Save(this); };
            log.Line(L("原始 DNS 协议查询 (UDP 53), 记录类型点选; 服务器默认阿里 223.5.5.5", "raw DNS over UDP/53; click a record type"));
        }

        void BuildHttpTab(Panel top, NLog log)
        {
            var url = new NEdit(12, 8, 330, "https://www.baidu.com");
            var btn = MkBtn(top, 350, 8, 90, L("请求", "Fetch"), true);
            var clear = MkBtn(top, 514, 8, 52, L("清除", "Clear"), false);
            var save = MkBtn(top, 572, 8, 56, L("保存", "Save"), false);
            top.Controls.Add(url);
            Action go = delegate {
                btn.Enabled = false;
                string u = url.Box.Text.Trim();
                log.Line(Stamp("-- http " + u + " --"));
                Bg(delegate {
                    foreach (var ln in HttpCheck(u, 6000)) log.Line(ln);
                    try { btn.BeginInvoke((Action)delegate { btn.Enabled = true; }); } catch {}
                });
            };
            btn.Click += delegate { go(); };
            url.Box.KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Return) { go(); e.SuppressKeyPress = true; } };
            clear.Click += delegate { log.Set(""); };
            save.Click += delegate { log.Save(this); };
            log.Line(L("状态码/Server/Content-Type/Body 大小/TTFB/总耗时; 自动跟随跳转, 无 scheme 默认 https://", "status/headers/size/TTFB; follows redirects"));
        }

        void BuildPortTab(Panel top, NLog log)
        {
            var host = new NEdit(12, 8, 190, "223.5.5.5");
            var port = new NEdit(210, 8, 64, "443");
            var btn = MkBtn(top, 282, 8, 76, L("检测", "Check"), true);
            var scan = MkBtn(top, 364, 8, 130, L("常用端口扫描", "Scan common"), false);
            var clear = MkBtn(top, 514, 8, 52, L("清除", "Clear"), false);
            var save = MkBtn(top, 572, 8, 56, L("保存", "Save"), false);
            top.Controls.Add(host); top.Controls.Add(port);
            btn.Click += delegate {
                btn.Enabled = false;
                int pt; if (!int.TryParse(port.Box.Text, out pt)) pt = 443;
                Bg(delegate {
                    log.Line(Stamp(host.Box.Text.Trim() + ":" + pt + "  " + TestPort(host.Box.Text.Trim(), pt, 2000)));
                    try { btn.BeginInvoke((Action)delegate { btn.Enabled = true; }); } catch {}
                });
            };
            scan.Click += delegate {
                scan.Enabled = false;
                string h = host.Box.Text.Trim();
                int[] ports = { 21, 22, 23, 25, 53, 80, 110, 143, 443, 445, 3306, 3389, 8080 };
                log.Line(Stamp("-- scan " + h + " (" + ports.Length + L(" 个常用端口", " ports) --")));
                Bg(delegate {
                    foreach (int pt in ports) log.Line("  " + pt + "  " + TestPort(h, pt, 600));
                    log.Line(Stamp(L("-- 扫描完成 --", "-- scan done --")));
                    try { scan.BeginInvoke((Action)delegate { scan.Enabled = true; }); } catch {}
                });
            };
            clear.Click += delegate { log.Set(""); };
            save.Click += delegate { log.Save(this); };
        }

        void BuildSubnetTab(Panel top, NLog log)
        {
            var lblIp = new Label { Text = "IP", Location = new Point(14, 13), AutoSize = true, Font = TF(9.5F, FontStyle.Regular), ForeColor = NC_SUB, BackColor = Color.Transparent };
            var ip = new NEdit(38, 8, 150, "192.168.1.10");
            var lblM = new Label { Text = L("前缀/掩码", "Prefix/Mask"), Location = new Point(198, 13), AutoSize = true, Font = TF(9.5F, FontStyle.Regular), ForeColor = NC_SUB, BackColor = Color.Transparent };
            var mk = new NEdit(280, 8, 120, "24");
            top.Controls.Add(lblIp); top.Controls.Add(ip); top.Controls.Add(lblM); top.Controls.Add(mk);
            EventHandler recompute = delegate {
                try { log.Set(string.Join("\r\n", SubnetCalc(ip.Box.Text, mk.Box.Text))); }
                catch (Exception ex) { log.Set("Err: " + ex.Message); }
            };
            ip.Box.TextChanged += recompute; mk.Box.TextChanged += recompute;

            var lblSplit = new Label { Text = L("拆分为", "Split into"), Location = new Point(14, 47), AutoSize = true, Font = TF(9.5F, FontStyle.Regular), ForeColor = NC_SUB, BackColor = Color.Transparent };
            var cnt = new NEdit(70, 42, 48, "4");
            var lblN = new Label { Text = L("个子网", "subnets"), Location = new Point(124, 47), AutoSize = true, Font = TF(9.5F, FontStyle.Regular), ForeColor = NC_SUB, BackColor = Color.Transparent };
            var btnSplit = MkBtn(top, 186, 42, 64, L("拆分", "Split"), true);
            var btnTable = MkBtn(top, 256, 42, 76, L("速查表", "Table"), false);
            var lblRange = new Label { Text = L("范围", "Range"), Location = new Point(344, 47), AutoSize = true, Font = TF(9.5F, FontStyle.Regular), ForeColor = NC_SUB, BackColor = Color.Transparent };
            var ip1 = new NEdit(384, 42, 106, "192.168.1.10");
            var ip2 = new NEdit(496, 42, 106, "192.168.1.99");
            var btnCidr = MkBtn(top, 608, 42, 24, "▶", true);
            top.Controls.Add(lblSplit); top.Controls.Add(cnt); top.Controls.Add(lblN);
            top.Controls.Add(lblRange); top.Controls.Add(ip1); top.Controls.Add(ip2);
            btnSplit.Click += delegate {
                int n; if (!int.TryParse(cnt.Box.Text, out n) || n < 2) n = 4;
                try { foreach (var ln in SubnetSplit(ip.Box.Text, mk.Box.Text, n)) log.Line(ln); }
                catch (Exception ex) { log.Line("Err: " + ex.Message); }
            };
            btnTable.Click += delegate { foreach (var ln in MaskTable()) log.Line(ln); };
            btnCidr.Click += delegate {
                try { log.Line(L("-- 范围转 CIDR --", "-- range to CIDR --")); foreach (var ln in RangeToCidr(ip1.Box.Text, ip2.Box.Text)) log.Line("  " + ln); }
                catch (Exception ex) { log.Line("Err: " + ex.Message); }
            };
            recompute(null, EventArgs.Empty);
        }

        void BuildLocalTab(Panel top, NLog log)
        {
            var btn = MkBtn(top, 12, 8, 100, L("刷新", "Refresh"), true);
            var copy = MkBtn(top, 120, 8, 100, L("复制全部", "Copy all"), false);
            Action refresh = delegate {
                btn.Enabled = false;
                Bg(delegate {
                    string info;
                    try {
                        info = LocalNetInfo();
                        string pub = PublicIp(3000);
                        info += "\r\n" + L("公网 IP", "Public IP") + ": " + (pub != null ? pub : L("查询失败 (需联网)", "query failed (offline)"));
                    } catch (Exception ex) { info = "Err: " + ex.Message; }
                    try { log.Box.BeginInvoke((Action)delegate { log.Set(info); btn.Enabled = true; }); } catch {}
                });
            };
            btn.Click += delegate { refresh(); };
            copy.Click += delegate { try { Clipboard.SetText(log.Box.Text); } catch {} };
            refresh();
        }
    }
    // ---------- embedded clipboard history (builtin:clip) ----------
    Form clipForm;

    internal static bool ClipPush(List<string> h, string t, int cap)   // dedupe + move-to-top + cap; returns true if changed
    {
        if (string.IsNullOrEmpty(t)) return false;
        if (h.Count > 0 && h[0] == t) return false;
        if (h.Remove(t)) { h.Insert(0, t); return true; }
        h.Insert(0, t);
        while (h.Count > cap) h.RemoveAt(h.Count - 1);
        return true;
    }

    void ShowClip()
    {
        if (clipForm != null && !clipForm.IsDisposed) { clipForm.Show(); clipForm.Activate(); return; }
        clipForm = new ClipForm();
        clipForm.Show();
    }

    class ClipForm : Form
    {
        [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr h);
        [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr h);
        const int WM_CLIPBOARDUPDATE = 0x031D;

        internal static readonly List<string> History = new List<string>();   // survives close/reopen (process lifetime)
        readonly ListBox list;
        bool selfSet;                                   // our own SetText must not re-enter history

        public ClipForm()
        {
            Text = L("剪贴板历史  (WgTray)", "Clipboard History  (WgTray)");
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            KeyPreview = true;
            ClientSize = new Size(520, 380);
            Font = new Font("Microsoft YaHei UI", 10F);
            list = new ListBox { Dock = DockStyle.Fill, Font = new Font("Microsoft YaHei UI", 10.5F), IntegralHeight = false };
            var top = new Panel { Dock = DockStyle.Top, Height = 40 };
            var btnCopy = new Button { Text = L("复制选中", "Copy"), Location = new Point(8, 6), Size = new Size(90, 28) };
            var btnClear = new Button { Text = L("清空历史", "Clear"), Location = new Point(104, 6), Size = new Size(90, 28) };
            var lbl = new Label { Text = L("点条目=复制回剪贴板; 本窗开着才监听", "click = copy back; listens while open"), Location = new Point(204, 12), AutoSize = true, ForeColor = Color.Gray };
            top.Controls.Add(btnCopy); top.Controls.Add(btnClear); top.Controls.Add(lbl);
            Controls.Add(list);
            Controls.Add(top);
            btnCopy.Click += delegate { CopySel(); };
            btnClear.Click += delegate { History.Clear(); RefreshList(); };
            list.DoubleClick += delegate { CopySel(); };
            list.Click += delegate { CopySel(); };
            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
            RefreshList();
        }
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); AddClipboardFormatListener(Handle); }
        protected override void OnFormClosed(FormClosedEventArgs e) { RemoveClipboardFormatListener(Handle); base.OnFormClosed(e); }

        void CopySel()
        {
            if (list.SelectedIndex < 0 || list.SelectedIndex >= History.Count) return;
            try { selfSet = true; Clipboard.SetText(History[list.SelectedIndex]); }
            catch {}
            finally { selfSet = false; }
        }
        void RefreshList()
        {
            list.BeginUpdate();
            list.Items.Clear();
            foreach (string h in History) list.Items.Add(h.Length > 80 ? h.Substring(0, 80) + "…" : h);
            list.EndUpdate();
        }
        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_CLIPBOARDUPDATE && !selfSet) {
                string t = null;
                for (int i = 0; i < 3; i++) {                       // clipboard can be briefly locked by the writer
                    try { t = Clipboard.GetText(); break; } catch { System.Threading.Thread.Sleep(30); }
                }
                if (t != null && t.Trim().Length > 0 && ClipPush(History, t, 200)) RefreshList();
            }
            base.WndProc(ref m);
        }
    }
    // ---------- embedded sticky note (builtin:note) ----------
    Form noteForm;

    internal static string NotesPath() { return Path.Combine(DataDir, "notes.txt"); }

    void ShowNote()
    {
        if (noteForm != null && !noteForm.IsDisposed) { noteForm.Show(); noteForm.Activate(); return; }
        noteForm = new NoteForm();
        noteForm.Show();
    }

    class NoteForm : Form
    {
        readonly TextBox box;
        readonly Label status;
        readonly Timer saver, sbSync;
        readonly Panel header, wrap, strip, sb;
        readonly List<string> files = new List<string>();       // note file paths in tab order
        readonly List<NTChip> chips = new List<NTChip>();
        int cur;                                                // active tab index
        int activeCi;
        bool sbDrag; int sbDragOff;

        // Win11-sticky-notes pastel themes (body / header pairs)
        static readonly string[] CN = { "yellow", "pink", "purple", "blue", "green", "white" };
        static readonly Color[] CBody = {
            Color.FromArgb(255, 255, 244, 194), Color.FromArgb(255, 252, 217, 228), Color.FromArgb(255, 233, 220, 247),
            Color.FromArgb(255, 212, 233, 250), Color.FromArgb(255, 217, 242, 220), Color.FromArgb(255, 255, 255, 255) };
        static readonly Color[] CHead = {
            Color.FromArgb(255, 252, 233, 168), Color.FromArgb(255, 248, 194, 212), Color.FromArgb(255, 219, 199, 241),
            Color.FromArgb(255, 191, 220, 247), Color.FromArgb(255, 197, 234, 203), Color.FromArgb(255, 240, 240, 243) };
        static readonly Color CText = Color.FromArgb(255, 58, 58, 63);
        static readonly Color CSub  = Color.FromArgb(255, 138, 138, 144);

        static Font NF(float size, FontStyle st)
        {
            string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
            foreach (string n in names) { try { return new Font(n, size, st, GraphicsUnit.Point); } catch {} }
            return new Font(FontFamily.GenericSansSerif, size, st, GraphicsUnit.Point);
        }
        static System.Drawing.Drawing2D.GraphicsPath NoteRound(Rectangle r, int rad)
        {
            var p = new System.Drawing.Drawing2D.GraphicsPath();
            int d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
        static string NoteColorPath() { return Path.Combine(DataDir, "note-color.txt"); }
        static string LoadNoteColor() { try { if (File.Exists(NoteColorPath())) return File.ReadAllText(NoteColorPath(), Encoding.UTF8).Trim(); } catch {} return "yellow"; }
        static string NotesDir() { return Path.Combine(DataDir, "notes"); }
        static string NoteMetaPath() { return Path.Combine(DataDir, "notes-meta.txt"); }
        [DllImport("user32.dll")] static extern bool ReleaseCapture();
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll", EntryPoint = "SendMessage")] static extern IntPtr SendMsgInt(IntPtr h, int msg, int w, int l);
        [DllImport("gdi32.dll")] static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
        [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);

        class NTChip : Panel
        {
            public string Title = "";
            public bool Active, Center;
            public NTChip() { DoubleBuffered = true; Cursor = Cursors.Hand; BackColor = Color.Transparent; }
            protected override void OnPaint(PaintEventArgs e)
            {
                var g = e.Graphics;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
                var host = Parent != null ? Parent.Parent as NoteForm : null;
                if (Active && host != null) {
                    using (var path = NoteRound(new Rectangle(0, 2, Width - 1, Height - 2), 7))
                    using (var br = new SolidBrush(CBody[host.activeCi])) { g.FillPath(br, path); }
                }
                using (var br = new SolidBrush(Active ? CText : CSub))
                using (var sf = new StringFormat { Alignment = Center ? StringAlignment.Center : StringAlignment.Near, LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
                    g.DrawString(Title, Font, br, new RectangleF(Center ? 0 : 8, 0, Width - (Center ? 0 : (Active ? 24 : 14)), Height), sf);
                if (Active) {
                    using (var br = new SolidBrush(CSub))
                    using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                        g.DrawString("✕", Font, br, new RectangleF(Width - 22, 0, 20, Height), sf);
                }
            }
        }
        class SBPanel : Panel { public SBPanel() { DoubleBuffered = true; } }

        public NoteForm()
        {
            Text = L("便签  (WgTray)", "Notes  (WgTray)");
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            KeyPreview = true;
            ClientSize = new Size(430, 330);
            string saved = LoadNoteColor();
            activeCi = 0;
            for (int i = 0; i < CN.Length; i++) if (CN[i] == saved) { activeCi = i; break; }
            BackColor = CBody[activeCi];
            LoadNotes();

            EventHandler rg = delegate { try { SetWindowRgn(Handle, CreateRoundRectRgn(0, 0, Width + 1, Height + 1, 20, 20), true); } catch {} };   // GDI rgn: no jagged corner stubs
            HandleCreated += delegate { rg(this, EventArgs.Empty); };
            Resize += delegate { rg(this, EventArgs.Empty); };

            // body container + slim custom scrollbar — added FIRST: last-added docks first
            wrap = new Panel { Dock = DockStyle.Fill, BackColor = CBody[activeCi], Padding = new Padding(16, 8, 4, 12) };
            box = new TextBox { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.None,
                BackColor = CBody[activeCi], ForeColor = CText, BorderStyle = BorderStyle.None, Font = NF(11F, FontStyle.Regular) };
            wrap.Controls.Add(box);
            sb = new SBPanel { Dock = DockStyle.Right, Width = 10, BackColor = CBody[activeCi] };
            wrap.Controls.Add(sb);
            Controls.Add(wrap);

            // tab strip (below header)
            strip = new Panel { Dock = DockStyle.Top, Height = 34, BackColor = CHead[activeCi] };
            Controls.Add(strip);

            // header: drag area + title + status + color dots + close (added LAST so it docks at the very top)
            header = new Panel { Dock = DockStyle.Top, Height = 38, BackColor = CHead[activeCi] };
            var cap = new Label { Text = L("便签", "Notes"), AutoSize = true, Location = new Point(14, 9),
                Font = NF(10F, FontStyle.Bold), ForeColor = CText, BackColor = Color.Transparent };
            status = new Label { Text = "", AutoSize = true, Location = new Point(56, 12),
                Font = NF(8F, FontStyle.Regular), ForeColor = CSub, BackColor = Color.Transparent };
            header.Controls.Add(cap); header.Controls.Add(status);
            var close = new Label { Text = "✕", Size = new Size(30, 26), Location = new Point(392, 6), TextAlign = ContentAlignment.MiddleCenter,
                Font = NF(10F, FontStyle.Regular), ForeColor = CText, BackColor = Color.Transparent, Cursor = Cursors.Hand };
            close.MouseEnter += delegate { close.BackColor = Color.FromArgb(255, 232, 17, 35); close.ForeColor = Color.White; };
            close.MouseLeave += delegate { close.BackColor = Color.Transparent; close.ForeColor = CText; };
            close.Click += delegate { Close(); };
            header.Controls.Add(close);
            for (int i = 0; i < CN.Length; i++) {
                var dot = new Panel { Size = new Size(15, 15), Location = new Point(246 + i * 23, 11), BackColor = CBody[i], Cursor = Cursors.Hand };
                try { var ep = new System.Drawing.Drawing2D.GraphicsPath(); ep.AddEllipse(0, 0, 14, 14); dot.Region = new Region(ep); } catch {}
                int ci = i;
                dot.Click += delegate { ApplyTheme(ci); };
                dot.Paint += delegate(object s, PaintEventArgs e) {
                    if (ci != activeCi) return;                 // ring on the active swatch
                    e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                    using (var pen = new Pen(CText, 2)) e.Graphics.DrawEllipse(pen, 1, 1, 11, 11);
                };
                header.Controls.Add(dot);
            }
            MouseEventHandler drag = delegate(object s, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                try { ReleaseCapture(); SendMessage(Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } catch {}
            };
            header.MouseDown += drag; cap.MouseDown += drag; status.MouseDown += drag;
            Controls.Add(header);

            // slim scrollbar: paint + drag + track page-scroll; a light sync timer follows wheel/keyboard scrolls
            sb.Paint += PaintSb;
            sb.MouseDown += SbDown;
            sb.MouseMove += SbMove;
            sb.MouseUp += delegate { sbDrag = false; sb.Capture = false; sb.Invalidate(); };
            sbSync = new Timer { Interval = 150 };
            sbSync.Tick += delegate { sb.Invalidate(); };
            sbSync.Start();

            saver = new Timer { Interval = 800 };                  // debounce: save 800ms after the last keystroke
            saver.Tick += delegate { saver.Stop(); SaveNow(); };
            box.TextChanged += delegate { saver.Stop(); saver.Start(); };
            LoadCur();
            RebuildTabs();
            FormClosing += delegate { saver.Stop(); sbSync.Stop(); SaveNow(); };
            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
        }

        // ---------- multi-note storage (DataDir\notes\N.txt + notes-meta.txt = active tab) ----------
        void LoadNotes()
        {
            files.Clear();
            try {
                var dir = NotesDir();
                Directory.CreateDirectory(dir);
                if (File.Exists(NotesPath()) && Directory.GetFiles(dir, "*.txt").Length == 0) {          // legacy single-file migration
                    try {
                        File.WriteAllText(Path.Combine(dir, "1.txt"), File.ReadAllText(NotesPath(), Encoding.UTF8), new UTF8Encoding(false));
                        File.Delete(NotesPath());
                    } catch {}
                }
                var nums = new SortedDictionary<int, string>();
                foreach (var f in Directory.GetFiles(dir, "*.txt")) {
                    int n;
                    if (int.TryParse(Path.GetFileNameWithoutExtension(f), out n) && !nums.ContainsKey(n)) nums[n] = f;
                }
                foreach (var kv in nums) files.Add(kv.Value);
                if (files.Count == 0) { var p = Path.Combine(dir, "1.txt"); File.WriteAllText(p, "", new UTF8Encoding(false)); files.Add(p); }
                cur = 0;
                try {
                    int a;
                    if (int.TryParse(File.ReadAllText(NoteMetaPath(), Encoding.UTF8).Trim(), out a) && a >= 1 && a <= files.Count) cur = a - 1;
                } catch {}
            } catch { if (files.Count == 0) files.Add(null); cur = 0; }
        }
        void SaveMeta() { try { File.WriteAllText(NoteMetaPath(), (cur + 1).ToString(), new UTF8Encoding(false)); } catch {} }
        void LoadCur()
        {
            try { box.Text = (cur >= 0 && cur < files.Count && files[cur] != null && File.Exists(files[cur])) ? File.ReadAllText(files[cur], Encoding.UTF8) : ""; }
            catch { box.Text = ""; }
            box.SelectionStart = box.Text.Length;
        }
        static string TitleOf(string path, int idx)
        {
            try {
                if (path != null && File.Exists(path)) {
                    using (var rd = new StreamReader(path, Encoding.UTF8)) {
                        string ln = rd.ReadLine();
                        while (ln != null && ln.Trim().Length == 0) ln = rd.ReadLine();
                        if (ln != null) { ln = ln.Trim(); if (ln.Length > 0) return ln; }   // chip width truncates with ellipsis
                    }
                }
            } catch {}
            return L("便签 ", "Note ") + (idx + 1);
        }
        void RebuildTabs()
        {
            strip.Controls.Clear();
            chips.Clear();
            int w = files.Count > 0 ? (ClientSize.Width - 20 - 36) / files.Count : 96;
            if (w > 96) w = 96; if (w < 56) w = 56;
            int x = 10;
            for (int i = 0; i < files.Count; i++) {
                var chip = new NTChip { Title = TitleOf(files[i], i), Active = (i == cur),
                    Location = new Point(x, 4), Size = new Size(w, 26), Font = NF(8.5F, FontStyle.Regular) };
                int ci = i;
                chip.MouseClick += delegate(object s, MouseEventArgs e) {
                    if (e.Button != MouseButtons.Left) return;
                    var c = (NTChip)s;
                    if (ci == cur && e.X >= c.Width - 22) { DeleteNote(ci); return; }       // ✕ zone on the active tab
                    SwitchTo(ci);
                };
                chips.Add(chip); strip.Controls.Add(chip);
                x += w + 4;
            }
            if (files.Count < 9) {
                var plus = new NTChip { Title = "+", Active = false, Center = true, Location = new Point(x, 4), Size = new Size(30, 26), Font = NF(10F, FontStyle.Bold) };
                plus.MouseClick += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) AddNote(); };
                strip.Controls.Add(plus);
            }
            strip.Invalidate(true);
        }
        void SwitchTo(int i)
        {
            if (i < 0 || i >= files.Count || i == cur) return;
            saver.Stop(); SaveNow();
            cur = i; SaveMeta();
            LoadCur();
            for (int k = 0; k < chips.Count; k++) { chips[k].Active = (k == cur); chips[k].Invalidate(); }
        }
        void AddNote()
        {
            if (files.Count >= 9) return;
            saver.Stop(); SaveNow();
            string p = null;
            try { p = Path.Combine(NotesDir(), (files.Count + 1) + ".txt"); File.WriteAllText(p, "", new UTF8Encoding(false)); } catch {}
            files.Add(p);
            cur = files.Count - 1; SaveMeta();
            LoadCur();
            RebuildTabs();
        }
        void DeleteNote(int i)
        {
            if (i < 0 || i >= files.Count) return;
            if (files.Count <= 1) { box.Clear(); saver.Stop(); SaveNow(); return; }         // last tab: clear instead of delete
            try { if (files[i] != null && File.Exists(files[i])) File.Delete(files[i]); } catch {}
            files.RemoveAt(i);
            try {                                                                          // renumber to dense 1..n
                var dir = NotesDir();
                for (int k = 0; k < files.Count; k++) {
                    if (files[k] == null) continue;
                    var tmp = Path.Combine(dir, "tmp_" + k + ".txt");
                    File.Move(files[k], tmp); files[k] = tmp;
                }
                for (int k = 0; k < files.Count; k++) {
                    if (files[k] == null) continue;
                    var fin = Path.Combine(dir, (k + 1) + ".txt");
                    File.Move(files[k], fin); files[k] = fin;
                }
            } catch {}
            if (cur >= files.Count) cur = files.Count - 1;
            else if (i < cur) cur--;
            SaveMeta();
            LoadCur();
            RebuildTabs();
        }

        // ---------- slim scrollbar ----------
        void SbMetrics(out int first, out int total, out int visible)
        {
            total = SendMsgInt(box.Handle, 0xBA, 0, 0).ToInt32();                          // EM_GETLINECOUNT
            first = SendMsgInt(box.Handle, 0xCE, 0, 0).ToInt32();                          // EM_GETFIRSTVISIBLELINE
            int lh = TextRenderer.MeasureText("Ag", box.Font).Height;
            visible = Math.Max(1, box.ClientSize.Height / Math.Max(1, lh));
        }
        void PaintSb(object s, PaintEventArgs e)
        {
            int first, total, visible;
            SbMetrics(out first, out total, out visible);
            if (total <= visible) return;                                                  // content fits: no thumb
            int lane = sb.Height;
            int th = Math.Max(24, lane * visible / total);
            int maxFirst = total - visible;
            int ty = maxFirst > 0 ? (lane - th) * first / maxFirst : 0;
            var g = e.Graphics;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (var path = NoteRound(new Rectangle(2, ty, 6, th), 3))
            using (var br = new SolidBrush(sbDrag ? Color.FromArgb(255, 118, 118, 126) : Color.FromArgb(255, 172, 172, 180)))
                g.FillPath(br, path);
        }
        void SbDown(object s, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            int first, total, visible;
            SbMetrics(out first, out total, out visible);
            if (total <= visible) return;
            int lane = sb.Height;
            int th = Math.Max(24, lane * visible / total);
            int maxFirst = total - visible;
            int ty = maxFirst > 0 ? (lane - th) * first / maxFirst : 0;
            if (e.Y >= ty && e.Y <= ty + th) { sbDrag = true; sbDragOff = e.Y - ty; sb.Capture = true; }
            else { SendMsgInt(box.Handle, 0xB6, 0, e.Y < ty ? -visible : visible); sb.Invalidate(); }   // EM_LINESCROLL: track page
        }
        void SbMove(object s, MouseEventArgs e)
        {
            if (!sbDrag) return;
            int first, total, visible;
            SbMetrics(out first, out total, out visible);
            int lane = sb.Height;
            int th = Math.Max(24, lane * visible / total);
            int maxFirst = total - visible;
            if (maxFirst <= 0 || lane <= th) return;
            int target = (e.Y - sbDragOff) * maxFirst / (lane - th);
            if (target < 0) target = 0; if (target > maxFirst) target = maxFirst;
            int delta = target - first;
            if (delta != 0) { SendMsgInt(box.Handle, 0xB6, 0, delta); sb.Invalidate(); }
        }

        void ApplyTheme(int i)
        {
            activeCi = i;
            try { File.WriteAllText(NoteColorPath(), CN[i], new UTF8Encoding(false)); } catch {}
            BackColor = CBody[i]; wrap.BackColor = CBody[i]; box.BackColor = CBody[i]; sb.BackColor = CBody[i];
            header.BackColor = CHead[i]; strip.BackColor = CHead[i];
            header.Invalidate(true); strip.Invalidate(true);
        }
        void SaveNow()
        {
            try {
                if (cur >= 0 && cur < files.Count && files[cur] != null) {
                    File.WriteAllText(files[cur], box.Text, new UTF8Encoding(false));
                    status.Text = L("已保存 ", "saved ") + DateTime.Now.ToString("HH:mm:ss");
                    if (cur < chips.Count) { chips[cur].Title = TitleOf(files[cur], cur); chips[cur].Invalidate(); }
                }
            } catch (Exception ex) { status.Text = "Err: " + ex.Message; }
        }
    }
    // ---------- embedded color picker (builtin:color) ----------
    Form colorForm;

    internal static string ColorHex(Color c) { return "#" + c.R.ToString("X2") + c.G.ToString("X2") + c.B.ToString("X2"); }
    internal static string ColorHsv(Color c)   // "H 210 S 78 V 100" (H deg 0-360, S/V %)
    {
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        double d = max - min, h = 0;
        if (d > 0) {
            if (max == r) h = 60 * (((g - b) / d) % 6);
            else if (max == g) h = 60 * ((b - r) / d + 2);
            else h = 60 * ((r - g) / d + 4);
        }
        if (h < 0) h += 360;
        double s = max == 0 ? 0 : d / max;
        return "H " + (int)Math.Round(h) + "  S " + (int)Math.Round(s * 100) + "%  V " + (int)Math.Round(max * 100) + "%";
    }

    void ShowColor()
    {
        if (colorForm != null && !colorForm.IsDisposed) { colorForm.Show(); colorForm.Activate(); return; }
        colorForm = new ColorForm();
        colorForm.Show();
    }
    class ColorForm : Form
    {
        [StructLayout(LayoutKind.Sequential)] struct PT { public int x, y; }
        [StructLayout(LayoutKind.Sequential)] struct MSLL { public PT pt; public uint mouseData, flags, time; public UIntPtr extra; }
        delegate IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, MouseProc cb, IntPtr mod, uint tid);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int nCode, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")] static extern bool GetCursorPos(out PT p);

        readonly Panel swatch;
        readonly Label lbl;
        IntPtr mouseHook;
        MouseProc proc;                                     // keep the delegate alive while hooked

        public ColorForm()
        {
            Text = L("颜色拾取  (WgTray)", "Color Picker  (WgTray)");
            StartPosition = FormStartPosition.CenterScreen;
            TopMost = true;
            KeyPreview = true;
            ClientSize = new Size(320, 210);
            Font = new Font("Microsoft YaHei UI", 10F);
            swatch = new Panel { Location = new Point(14, 14), Size = new Size(290, 90), BackColor = Color.White, BorderStyle = BorderStyle.FixedSingle };
            lbl = new Label { Location = new Point(14, 116), Size = new Size(290, 44), Font = new Font("Consolas", 10.5F), Text = "—" };
            var btnPick = new Button { Text = L("拾取 (点屏幕)", "Pick (click screen)"), Location = new Point(14, 168), Size = new Size(150, 30) };
            var btnCopy = new Button { Text = L("复制 HEX", "Copy HEX"), Location = new Point(172, 168), Size = new Size(132, 30) };
            Controls.Add(swatch); Controls.Add(lbl); Controls.Add(btnPick); Controls.Add(btnCopy);
            btnPick.Click += delegate { StartPick(); };
            btnCopy.Click += delegate { if (lbl.Tag is Color) { try { Clipboard.SetText(ColorHex((Color)lbl.Tag)); } catch {} } };
            KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) Close(); };
            FormClosed += delegate { StopPick(); };
        }

        void StartPick()
        {
            if (mouseHook != IntPtr.Zero) return;
            proc = MouseHookProc;
            mouseHook = SetWindowsHookEx(14, proc, GetModuleHandle(null), 0);   // WH_MOUSE_LL
            lbl.Text = L("点击屏幕任意处取色, 右键取消", "click anywhere to pick, right-click to cancel");
        }
        void StopPick()
        {
            if (mouseHook != IntPtr.Zero) { UnhookWindowsHookEx(mouseHook); mouseHook = IntPtr.Zero; }
        }
        IntPtr MouseHookProc(int nCode, IntPtr wParam, IntPtr lParam)
        {
            if (nCode >= 0) {
                int wm = wParam.ToInt32();
                if (wm == 0x0201) {                     // WM_LBUTTONDOWN: pick and swallow the click
                    var st = (MSLL)Marshal.PtrToStructure(lParam, typeof(MSLL));
                    PickAt(st.pt.x, st.pt.y);
                    StopPick();
                    return (IntPtr)1;
                }
                if (wm == 0x0204) { StopPick(); return (IntPtr)1; }   // WM_RBUTTONDOWN: cancel
            }
            return CallNextHookEx(mouseHook, nCode, wParam, lParam);
        }
        void PickAt(int x, int y)
        {
            Color c;
            using (var bmp = new Bitmap(1, 1))
            using (var g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(x, y, 0, 0, new Size(1, 1));
                c = bmp.GetPixel(0, 0);
            }
            swatch.BackColor = c;
            lbl.Tag = c;
            lbl.Text = ColorHex(c) + "   rgb(" + c.R + "," + c.G + "," + c.B + ")\r\n" + ColorHsv(c);
        }
    }
    // ---------- plugins: plugins\*.txt extend the launcher with the tools.txt step DSL ----------
    static Dictionary<string, ToolAction> PluginActions;   // file -> parsed action (spec: docs/WGIME_插件规范.md)

    static void ParseToolSteps(IEnumerable<string> lines, List<string[]> steps, List<string> raws)   // shared step parser (blocks keep lines raw)
    {
        string blockClose = null, blockVerb = null; var blockLines = new List<string>();
        foreach (string raw in lines) {
            if (blockClose != null) {
                if (raw.Trim() == blockClose) { steps.Add(new string[] { blockVerb }); raws.Add(string.Join("\n", blockLines)); blockClose = null; }
                else blockLines.Add(raw);
                continue;
            }
            string t = raw.Trim();
            if (t.Length == 0 || t[0] == ';' || t[0] == '#') continue;
            if (t == "[shell]" || t == "[cmd]") { blockVerb = "shellblock"; blockClose = t.Insert(1, "/"); blockLines.Clear(); continue; }
            if (t == "[powershell]" || t == "[ps]") { blockVerb = "psblock"; blockClose = (t == "[ps]" ? "[/ps]" : "[/powershell]"); blockLines.Clear(); continue; }
            if (t == "[shellx]" || t == "[cmdx]") { blockVerb = "shellblockx"; blockClose = t.Insert(1, "/"); blockLines.Clear(); continue; }
            if (t == "[powershellx]" || t == "[psx]") { blockVerb = "psblockx"; blockClose = t.Insert(1, "/"); blockLines.Clear(); continue; }
            var toks = ToolToks(t);
            if (toks.Count > 0) { steps.Add(toks.ToArray()); raws.Add(t); }
        }
    }

    static string ExtractPluginBlock(List<string> body, string tag)   // "[tag]...[/tag]" top-level block -> inner text (null when absent)
    {
        string open = "[" + tag + "]", close = "[/" + tag + "]";
        var sb = new StringBuilder();
        bool inside = false, found = false;
        foreach (string raw in body) {
            string t = raw.Trim();
            if (!inside && t == open) { inside = true; found = true; continue; }
            if (inside && t == close) { inside = false; continue; }
            if (inside) sb.Append(raw).Append("\n");
        }
        return found ? sb.ToString() : null;
    }

    static void LoadPlugins(string dir)
    {
        PluginActions = new Dictionary<string, ToolAction>();
        PluginInfo = new Dictionary<string, string[]>();
        try {
            string pd = Path.Combine(dir, "plugins");
            if (!Directory.Exists(pd)) return;
            foreach (string f in Directory.GetFiles(pd, "*.txt")) {
                string code = null, name = null;
                var body = new List<string>();
                bool headerDone = false;
                foreach (string raw in File.ReadAllLines(f, Encoding.UTF8)) {
                    string t = raw.Trim();
                    if (!headerDone) {
                        if (t.Length == 0 || t[0] == ';' || t[0] == '#') continue;
                        var m = System.Text.RegularExpressions.Regex.Match(t, "^(code|name|desc)\\s*[=:]\\s*(.+)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                        if (m.Success) {
                            string k2 = m.Groups[1].Value.ToLower(), v2 = m.Groups[2].Value.Trim();
                            if (k2 == "code") code = v2.ToLower(); else if (k2 == "name") name = v2;
                            continue;
                        }
                        headerDone = true;
                    }
                    body.Add(raw);
                }
                if (code == null || name == null || code.Length == 0 || body.Count == 0) continue;
                PluginInfo[f] = new string[] { code, name };              // every parseable plugin, enabled or not
                bool disabled = DisabledPlugins.Contains(Path.GetFileName(f).ToLower());
                string cs = ExtractPluginBlock(body, "csharp");          // [csharp]...[/csharp] -> code plugin (no step DSL)
                if (cs != null) {
                    if (PluginCodeCache == null) PluginCodeCache = new Dictionary<string, PluginCode>();
                    PluginCodeCache[f] = CompilePlugin(cs);              // still compiled: manager shows its status
                    if (!disabled) Apps[code] = new string[] { name, "codeplugin:" + f, "" };
                    continue;
                }
                var a = new ToolAction { Name = name };
                ParseToolSteps(body, a.Steps, a.Raw);
                if (a.Steps.Count == 0) continue;
                PluginActions[f] = a;
                if (!disabled) Apps[code] = new string[] { name, "plugin:" + f, "" };   // plugins load last: they override builtins/config on code collision
            }
        } catch {}
    }

    static Dictionary<string, string[]> PluginInfo;    // file -> [code, name] for every parseable plugin (enabled or not)
    static HashSet<string> DisabledPlugins = new HashSet<string>();   // lowercase file names

    static void LoadDisabledPlugins()
    {
        DisabledPlugins = new HashSet<string>();
        try {
            string dp = Path.Combine(DataDir, "plugins-disabled.txt");
            if (File.Exists(dp))
                foreach (string ln in File.ReadAllLines(dp, Encoding.UTF8)) {
                    string t = ln.Trim().ToLower();
                    if (t.Length > 0) DisabledPlugins.Add(t);
                }
        } catch {}
    }
    static void SetPluginDisabled(string file, bool disabled)
    {
        string fn = Path.GetFileName(file).ToLower();
        if (disabled) DisabledPlugins.Add(fn); else DisabledPlugins.Remove(fn);
        try { File.WriteAllLines(Path.Combine(DataDir, "plugins-disabled.txt"), new List<string>(DisabledPlugins).ToArray(), new UTF8Encoding(false)); } catch {}
    }

    void RunPlugin(string file)
    {
        ToolAction a;
        if (PluginActions == null || !PluginActions.TryGetValue(file, out a)) return;
        TrayTip(a.Name, L("开始执行…", "running…"), ToolTipIcon.Info);
        var t = new System.Threading.Thread((System.Threading.ThreadStart)delegate {
            int errs = 0; bool aborted = false;
            for (int i = 0; i < a.Steps.Count; i++) {
                bool isBlock = a.Steps[i].Length == 1 && (a.Steps[i][0] == "shellblock" || a.Steps[i][0] == "psblock" || a.Steps[i][0] == "shellblockx" || a.Steps[i][0] == "psblockx");
                var sb = new StringBuilder();
                string r = ExecToolStep(a.Steps[i], isBlock ? a.Raw[i] : ToolRest(a.Raw[i]), sb, Ui());
                if (r == "abort") { aborted = true; break; }
                if (r != null) errs++;
            }
            string msg = aborted ? L("已取消", "aborted") : (errs == 0 ? L("执行完成", "done") : L("完成, ", "done, ") + errs + L(" 个步骤失败", " step(s) failed"));
            try { Ui().BeginInvoke((Action)delegate { TrayTip(a.Name, msg, errs == 0 && !aborted ? ToolTipIcon.Info : ToolTipIcon.Warning); }); } catch {}
        });
        t.IsBackground = true;
        t.Start();
    }

    // ---------- code plugins: [csharp] block, CodeDom in-memory compile, Run() entry ----------
    class PluginCode { internal System.Reflection.Assembly Asm; internal System.Reflection.MethodInfo Entry; internal string Error; }
    static Dictionary<string, PluginCode> PluginCodeCache;   // file -> compiled plugin (compiled at load; errors surface on invoke)
    static readonly string[] PluginRefs = new string[] { "System.dll", "System.Windows.Forms.dll", "System.Drawing.dll", "System.Core.dll", "System.Data.dll" };

    // contract: the source must contain a class with "public static void Run()" (C# 5 syntax: CodeDom on .NET 4.x)
    static string[] PluginRefsFull()                          // base refs + WPF assemblies (resolved from the GAC by load)
    {
        var list = new List<string>(PluginRefs);
        foreach (string n in new string[] { "WindowsBase", "PresentationCore", "PresentationFramework" }) {
            try {
                var asm = System.Reflection.Assembly.Load(new System.Reflection.AssemblyName(n + ", Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35"));
                if (asm != null && asm.Location.Length > 0) list.Add(asm.Location);
            } catch {}
        }
        try {                                                                                  // System.Xaml has the framework token, not the WPF one
            var xaml = System.Reflection.Assembly.Load(new System.Reflection.AssemblyName("System.Xaml, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089"));
            if (xaml != null && xaml.Location.Length > 0) list.Add(xaml.Location);
        } catch {}
        return list.ToArray();
    }

    static PluginCode CompilePlugin(string source)
    {
        var pc = new PluginCode();
        try {
            var cp = new Microsoft.CSharp.CSharpCodeProvider();
            var par = new System.CodeDom.Compiler.CompilerParameters { GenerateInMemory = true, GenerateExecutable = false };
            par.ReferencedAssemblies.AddRange(PluginRefsFull());
            var res = cp.CompileAssemblyFromSource(par, source);
            if (res.Errors.HasErrors) {
                var sb = new StringBuilder();
                foreach (System.CodeDom.Compiler.CompilerError ce in res.Errors) {
                    sb.Append("line ").Append(ce.Line).Append(": ").Append(ce.ErrorText).Append("; ");
                    if (sb.Length > 400) break;
                }
                pc.Error = sb.ToString();
                return pc;
            }
            pc.Asm = res.CompiledAssembly;
            foreach (var t in pc.Asm.GetTypes()) {
                var m = t.GetMethod("Run", System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static, null, Type.EmptyTypes, null);
                if (m != null && m.ReturnType == typeof(void)) { pc.Entry = m; break; }
            }
            if (pc.Entry == null) pc.Error = "no 'public static void Run()' entry point found";
        } catch (Exception ex) { pc.Error = ex.Message; }
        return pc;
    }

    void RunCodePlugin(string file)
    {
        PluginCode pc;
        if (PluginCodeCache == null || !PluginCodeCache.TryGetValue(file, out pc)) return;
        if (pc.Error != null) { TrayTip(L("插件编译失败", "Plugin compile failed"), pc.Error, ToolTipIcon.Error); return; }
        EnsurePluginThread();
        try {
            pluginInvoker.BeginInvoke((Action)delegate {     // dedicated plugin thread: a plugin that blocks only stalls its own windows, never the IME
                try { pc.Entry.Invoke(null, null); }
                catch (Exception ex) { TrayTip(L("插件运行出错", "Plugin error"), ex.GetBaseException().Message, ToolTipIcon.Error); }
            });
        } catch {}
    }

    // ---------- dedicated plugin UI thread (C# plugins get their own STA message loop) ----------
    static System.Threading.Thread pluginThread;
    static Control pluginInvoker;                            // hidden control on the plugin thread: BeginInvoke marshals calls there

    static void EnsurePluginThread()
    {
        if (pluginThread != null) return;
        pluginThread = new System.Threading.Thread((System.Threading.ThreadStart)delegate {
            pluginInvoker = new Control();
            IntPtr h = pluginInvoker.Handle;                 // reading Handle forces creation, so BeginInvoke targets this thread
            Application.Run();                               // message loop until the process exits (background thread)
        });
        pluginThread.IsBackground = true;
        pluginThread.SetApartmentState(System.Threading.ApartmentState.STA);
        pluginThread.Name = "WgTrayPlugins";
        pluginThread.Start();
        while (pluginInvoker == null || !pluginInvoker.IsHandleCreated) System.Threading.Thread.Sleep(10);
    }

    // ---------- plugin manager (builtin:pluginmgr; launcher-only, intentionally NOT in the tray menu) ----------
    Form pluginMgr;

    void ShowPluginMgr()
    {
        if (pluginMgr != null && !pluginMgr.IsDisposed) { pluginMgr.Show(); pluginMgr.Activate(); return; }
        pluginMgr = new PluginMgrForm(this);
        pluginMgr.Show();
    }
}
'@

# ---- load prebuilt DLL from embedded payload, in-memory compile only as fallback ----
# The loader block below is replaced wholesale by build-wgtray.ps1:
# default = full prebuilt-DLL loader; -NoPayload build = just "$wgLoaded = $false"
$wgDll = $null
try {
    $all = [IO.File]::ReadAllText($env:WGTRAY_PATH, [Text.Encoding]::UTF8)
    $tag = '###WGTRAY_DLL' + '###'
    $ts = $all.LastIndexOf($tag)
    if ($ts -ge 0) {
        $b64 = (($all.Substring($ts + $tag.Length).Trim()) -replace '\s') -replace "'"
        $md5 = [Security.Cryptography.MD5]::Create()
        $h = ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($b64)))).Replace('-','').Substring(0,8)
        $wgDllDir = Join-Path $env:LOCALAPPDATA 'wgime'
        New-Item $wgDllDir -ItemType Directory -Force | Out-Null
        $cand = Join-Path $wgDllDir ("WgTray." + $h + ".dll")
        if (-not (Test-Path $cand)) {
            [IO.File]::WriteAllBytes($cand, [Convert]::FromBase64String($b64))
            Get-ChildItem (Join-Path $wgDllDir 'WgTray.*.dll') -EA SilentlyContinue | Where-Object Name -ne (Split-Path $cand -Leaf) | Remove-Item -Force -Confirm:$false -EA SilentlyContinue
        }
        $wgDll = $cand
    }
} catch { WgLog ("payload extract failed: " + $_.Exception.Message) }
$wgLoaded = $false
if ($wgDll) {
    try { Add-Type -Path $wgDll -ErrorAction Stop; $wgLoaded = $true; WgLog ("prebuilt DLL loaded: " + $wgDll) }
    catch { WgLog ("DLL load failed: " + ($_ | Out-String)) }
}
if (-not $wgLoaded) {
    try {
        Add-Type -TypeDefinition $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        WgLog "C# compiled OK (in-memory fallback)"
    } catch {
        WgLog ("Add-Type FAILED: " + ($_ | Out-String))
        if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
            WgLog "HINT: PowerShell is in ConstrainedLanguage mode (AppLocker/WDAC policy). In-memory C# compile is blocked by policy - ask admin to allow the wgime DLL folder, or sign the script."
        }
        throw
    }
}

WgLog "launching TrayApp"

# ---- first-run seeding: sample tools/plugins for fresh users ----
# Guarded by %LOCALAPPDATA%\wgime\provisioned-tray.done: runs ONCE. Users may delete the
# samples permanently; to re-seed, delete the marker. Nothing is ever overwritten.
$seedTools = @'
; ============================================================
;  WgTray 工具箱配置 (UTF-8, 与 wgtray.bat 同目录)
;  唤出: 右键托盘图标 -> 工具箱 (托盘菜单)
;
;  结构:
;    [tab 标签页名]        新开一个标签页
;    [cols N]              当前标签页按钮按 N 列平铺 (1-6, 默认 2), 多了自动换行
;    [按钮名]              在当前标签页加一个按钮
;    code = xxx            按钮名下可加一行启动编码 (WgIme 输入法版专用):
;                          输入 xxx 后候选条出现 ▶工具:按钮名, 选中即执行 (同点击);
;                          编码与 app= 冲突时 tools 的优先; WgTray 托盘版不适用
;    <步骤行>              按钮点击后从上到下依次执行
;
;  步骤动词 (参数支持 "引号" 包裹含空格的项, 路径支持 %环境变量%):
;    msg 文本                          气泡提示
;    confirm 文本                      确认框, 选"否"则中止本按钮的后续步骤
;                                      扩展: confirm 文本 | title=标题 | buttons=yesno|okcancel|ok | default=1|2
;                                      (ok=纯提示不中止; 默认 default=2 即"否", 防误触)
;    run <程序> [参数...]              静默运行并等待结束 (输出与退出码记入日志)
;    shell <cmd 命令行原文>            cmd /c 单行静默执行并等待
;    shellx <cmd 命令行原文>           同 shell 但弹出可见控制台窗口 (交互式命令用, 等窗口关闭)
;    open <目标>                       用系统默认方式打开 (程序/文件夹/网址), 不等待
;    kill <进程名>                     结束进程 (如 kill Teams)
;    wait <毫秒>                       等待
;    reg-set <键> <值名> <类型> <数据> 写注册表; 键以 HKCU/HKLM/HKCR/HKU/HKCC 开头;
;                                      值名用 - 表示"(默认)"; 类型 string/expand/dword/qword/multi(用|分隔)/binary(十六进制)
;    reg-del <键> [值名]               给了值名=删该值; 不给=删除整个键(含子键)
;    file-del <路径>                   删文件/目录 (支持 * ? 通配; 目录递归删除; 占用/无权限的自动跳过
;                                      并记入日志, 不会中断; 拒绝删盘符根目录)
;    mkdir <路径>                      建目录
;
;  多行脚本块 (块内每行【不需要】加动词前缀, 原样保留空行/缩进/注释):
;    [shell] ... [/shell]              多行 cmd 批处理, 写入临时 .cmd 执行 (ANSI 编码)
;    [powershell] ... [/powershell]    多行 PowerShell, 写入临时 .ps1 执行 (UTF-8 BOM 保存, 中文安全)
;                                      ([cmd] / [ps] 为简写)
;    [shellx] ... [/shellx]            交互式版本: 弹出可见控制台窗口, 可 read/choice/pause,
;    [psx] ... [/psx]                  脚本结束后窗口停留, 按键关闭 (等窗口关闭后再记退出码)
;
;  失败步骤只记日志不中断; confirm 选"否"才中断。改完后托盘"配置 -> 重载配置"即时生效。
;
;  注意:
;    1. 块标记必须各自独占一行 ([powershell] ... [/powershell]); 忘记写结束标记会吞掉后面所有内容
;    2. 单行 PowerShell 也用块 (内容只有一行也行); 没有单行 ps 动词;
;       shell powershell -Command "..." 里中文/引号转义容易出错, 推荐块 (UTF-8 BOM 保存, 中文安全)
;    3. [shellx]/[psx] 脚本结束后窗口自动停驻、按键关闭——脚本里不要再写 pause/Read-Host (否则要按两次)
;    4. 排障: [shellx]/[psx] 的控制台里直接显示报错行号; 静默块 ([shell]/[powershell]) 的输出与退出码收进下方日志区
; ============================================================

[tab 办公]

[重置 Teams]
confirm 这会关闭 Teams 并清空它的缓存目录, 确定吗?
kill Teams
wait 1000
file-del %LOCALAPPDATA%\Microsoft\Teams\Cache
file-del %LOCALAPPDATA%\Microsoft\Teams\GPUCache
file-del %LOCALAPPDATA%\Microsoft\Teams\Code Cache
msg Teams 缓存已清理, 可以重新启动了

[修复 Outlook (重置导航窗格)]
confirm 将关闭 Outlook 并重置导航窗格配置, 确定吗?
kill OUTLOOK
wait 800
shell outlook.exe /resetnavpane

[tab 系统]
[cols 2]

[打开 WgIme 数据目录]
open %LOCALAPPDATA%\wgime

[清理我的临时文件]
confirm 将删除 %TEMP% 下的临时文件 (占用中的会自动跳过), 确定吗?
file-del %TEMP%\*
msg 临时文件清理完成

[刷新 DNS 缓存]
shell ipconfig /flushdns

[本机 IPv4 地址]
[powershell]
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
  Select-Object InterfaceAlias, IPAddress |
  Out-String | Write-Output
[/powershell]
'@
$seedPluginReadme = @'
============================================================
 WgTray 插件速览 (plugins\*.txt)
============================================================

插件 = 纯文本文件, 把一个启动编码绑定到一组动作:

  code = qls            ; 启动编码 (小写 a-z, 必填, 唯一)
  name = 清空回收站      ; 显示名 (必填)
  desc = 说明            ; 可选

  <步骤>                 ; 头部之后直到文件末尾都是步骤

用法 (WgTray): 右键托盘图标 -> 插件 -> 点插件名执行, 后台运行, 气泡报结果。
       (WgIme):   输入编码 -> 候选条出现 ▶<name> -> 空格选中执行。
改完/新增后: 托盘"配置 -> 重载配置"即时生效。
管理 (WgTray): 托盘 -> 插件 -> 插件管理… (列表/运行/编辑/删除/新建/重载)。

步骤动词 (与 tools.txt 工具箱完全一致):
  msg / confirm / run / shell / open / kill / wait
  shellx <cmd 命令行>                     (同 shell 但弹可见控制台, 交互式命令用)
  reg-set <键> <值名> <类型> <数据>     (HKCU/HKLM/HKCR/HKU/HKCC; string/expand/dword/qword/multi/binary)
  reg-del <键> [值名]                   (不给值名=删整键)
  file-del <路径>                       (通配符/递归; 占用/无权限自动跳过; 拒绝盘符根目录)
  mkdir <路径>

多行脚本块 (块内每行不用加前缀):
  [shell] ... [/shell]              cmd 批处理 (临时 .cmd)
  [powershell] ... [/powershell]    PowerShell (临时 .ps1, 中文安全)
  [shellx] ... [/shellx]            交互式版本: 可见控制台窗口, 可 read/pause, 按键关闭
  [psx] ... [/psx]

块注意:
  1. 块标记各自独占一行; 忘记结束标记会吞掉后面所有内容
  2. 单行 PowerShell 也用块 (一行也行); 没有单行 ps 动词, shell 里包 powershell -Command 的中文/引号转义容易出错
  3. [shellx]/[psx] 结束自动停驻按键关闭, 脚本里不要再写 pause (会按两次)
  4. 排障: x 版控制台直接显示报错; 静默块的输出与退出码收进启动器气泡/日志

C# 代码插件 (要窗体就用它):
  [csharp] ... [/csharp]            内嵌 C# 源码, 加载时内存编译, 选中运行
  契约: 含一个 public static void Run(); 跑在插件专用线程 (WgImePlugins), 可直接 new Form().Show(),
        插件阻塞不影响输入法打字
  引用: System / Windows.Forms / Drawing / Core / Data + WPF (PresentationCore/PresentationFramework/
        WindowsBase/System.Xaml —— 可直接 new System.Windows.Window 建 WPF 窗体);
        注意是 C# 5 语法 (.NET 4.x CodeDom)
  示例: clock.txt (输入 sz 弹现代风悬浮时钟: 时钟/闹钟/倒计时/秒表计次/番茄统计)
        chat.txt  (输入 lt 弹局域网聊天: 与 itools-chat (chat.bat) 互通, 无需服务器)

建议: 破坏性操作先 confirm; 步骤幂等; 长任务 msg 报进度。
完整规范见仓库 docs\WGIME_插件规范.md; 窗体设计语言见 docs\WGIME_窗体设计语言.md。

(本文件与两个示例插件是首次运行时自动播种的; 删掉不会复活。想重新播种: 删除
 %LOCALAPPDATA%\wgime\provisioned-tray.done 后重启 wgtray.bat。)'@







$seedCalc = @'
; ============================================================
;  WgIme C# 插件: 计算器 (由内嵌升级为插件, 现代 UI)
;  输入 jsq (或 calc) 选 ▶计算器: 圆角磁贴按键, 可点按也可键盘直输
;  回车求值, 退格删字符, Esc 关闭; 支持 + - * / % 括号, 兼容全角 ×÷（）
; ============================================================
code = jsq
name = 计算器
desc = 迷你计算器: 四则/括号/取余, 全角符号兼容, 键盘直输回车求值

[csharp]
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class CalcPlugin
{
    // palette: light blue-gray body + white cards (matches the clock / toolbox)
    static Color C_BG     = Color.FromArgb(255, 232, 237, 245);
    static Color C_HEADER = Color.FromArgb(255, 220, 227, 239);
    static Color C_CARD   = Color.FromArgb(255, 255, 255, 255);
    static Color C_BORDER = Color.FromArgb(255, 195, 204, 221);
    static Color C_TEXT   = Color.FromArgb(255, 29, 29, 31);
    static Color C_SUB    = Color.FromArgb(255, 110, 116, 133);
    static Color C_ACCENT = Color.FromArgb(255, 0, 122, 255);
    static Color C_OP     = Color.FromArgb(255, 227, 234, 244);    // operator tile tint
    static Color C_RED    = Color.FromArgb(255, 255, 55, 95);

    static Font F(float size, FontStyle st)
    {
        string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
        foreach (string n in names) { try { return new Font(n, size, st, GraphicsUnit.Point); } catch {} }
        return new Font(FontFamily.GenericSansSerif, size, st, GraphicsUnit.Point);
    }
    static GraphicsPath RoundRect(Rectangle r, int rad)
    {
        var p = new GraphicsPath();
        int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    internal class TBtn : Panel   // Panel base: zero native chrome
    {
        public Color Bg = Color.FromArgb(255, 255, 255, 255);
        public Color BgHover = Color.FromArgb(255, 240, 243, 249);
        public Color BgDown = Color.FromArgb(255, 226, 232, 242);
        public Color Fg = Color.FromArgb(255, 29, 29, 31);
        bool hover, down;
        public TBtn() { DoubleBuffered = true; Cursor = Cursors.Hand; }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = RoundRect(rect, 8))
            using (var br = new SolidBrush(down ? BgDown : (hover ? BgHover : Bg))) { g.FillPath(br, path); }
            using (var br = new SolidBrush(Fg))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(Text, Font, br, new RectangleF(0, 0, Width, Height), sf);
        }
    }

    // ---------- expression parser (unchanged from the built-in version) ----------
    class P { internal string s; internal int i; }
    static double ParseExpr(P p) { double v = ParseTerm(p); while (p.i < p.s.Length) { char c = p.s[p.i]; if (c == '+') { p.i++; v += ParseTerm(p); } else if (c == '-') { p.i++; v -= ParseTerm(p); } else break; } return v; }
    static double ParseTerm(P p) { double v = ParseFac(p);  while (p.i < p.s.Length) { char c = p.s[p.i]; if (c == '*') { p.i++; v *= ParseFac(p); } else if (c == '/') { p.i++; v /= ParseFac(p); } else if (c == '%') { p.i++; v = (double)((long)v % (long)ParseFac(p)); } else break; } return v; }
    static double ParseFac(P p)
    {
        while (p.i < p.s.Length && p.s[p.i] == ' ') p.i++;
        if (p.i >= p.s.Length) throw new Exception("eof");
        char c = p.s[p.i];
        if (c == '(') { p.i++; double v = ParseExpr(p); if (p.i >= p.s.Length || p.s[p.i] != ')') throw new Exception("paren"); p.i++; return v; }
        if (c == '-') { p.i++; return -ParseFac(p); }
        if (c == '+') { p.i++; return ParseFac(p); }
        int st = p.i;
        while (p.i < p.s.Length && (char.IsDigit(p.s[p.i]) || p.s[p.i] == '.')) p.i++;
        if (st == p.i) throw new Exception("num");
        return double.Parse(p.s.Substring(st, p.i - st), System.Globalization.CultureInfo.InvariantCulture);
    }
    public static string Calc(string s)
    {
        s = s.Replace(" ", "").Replace('×', '*').Replace('÷', '/').Replace('（', '(').Replace('）', ')');
        if (s.Length == 0) return "";
        try {
            var p = new P { s = s };
            double v = ParseExpr(p);
            if (p.i != s.Length || double.IsNaN(v) || double.IsInfinity(v)) return "Err";
            return (v == Math.Floor(v) && Math.Abs(v) < 1e15) ? ((long)v).ToString() : v.ToString("G10");
        } catch { return "Err"; }
    }

    public static void Run()
    {
        var f = new Form();
        f.Text = "WgIme Calc";
        f.FormBorderStyle = FormBorderStyle.None;
        f.AutoScaleMode = AutoScaleMode.None;
        f.StartPosition = FormStartPosition.CenterScreen;
        f.TopMost = true;
        f.KeyPreview = true;
        f.ShowInTaskbar = false;
        f.ClientSize = new Size(264, 356);
        f.BackColor = C_BG;
        EventHandler rg = delegate { try { SetWindowRgn(f.Handle, CreateRoundRectRgn(0, 0, f.Width + 1, f.Height + 1, 20, 20), true); } catch {} };
        f.HandleCreated += delegate { rg(f, EventArgs.Empty); };
        f.Resize += delegate { rg(f, EventArgs.Empty); };
        f.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = RoundRect(new Rectangle(1, 1, f.Width - 3, f.Height - 3), 9))
            using (var pen = new Pen(C_BORDER, 1)) { g.DrawPath(pen, path); }
        };

        var fontTitle = F(9.5F, FontStyle.Bold);
        var fontKey = F(11F, FontStyle.Regular);

        // title bar
        var title = new Panel { Location = new Point(0, 0), Size = new Size(264, 32), BackColor = C_HEADER };
        var capLbl = new Label { Text = "计算器", Font = fontTitle, ForeColor = C_TEXT, AutoSize = true, Location = new Point(12, 7), BackColor = Color.Transparent };
        var close = new Label { Text = "✕", Size = new Size(28, 22), Location = new Point(228, 5), TextAlign = ContentAlignment.MiddleCenter,
            Font = fontTitle, ForeColor = C_TEXT, BackColor = Color.Transparent, Cursor = Cursors.Hand };
        close.MouseEnter += delegate { close.BackColor = Color.FromArgb(255, 232, 17, 35); close.ForeColor = Color.White; };
        close.MouseLeave += delegate { close.BackColor = Color.Transparent; close.ForeColor = C_TEXT; };
        close.Click += delegate { f.Close(); };
        title.Controls.Add(capLbl); title.Controls.Add(close);
        title.Paint += delegate(object s, PaintEventArgs e) {
            using (var pen = new Pen(C_BORDER)) e.Graphics.DrawLine(pen, 0, title.Height - 1, title.Width, title.Height - 1);
        };
        MouseEventHandler drag = delegate(object s, MouseEventArgs e) {
            if (e.Button != MouseButtons.Left) return;
            try { ReleaseCapture(); SendMessage(f.Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } catch {}
        };
        title.MouseDown += drag; capLbl.MouseDown += drag;
        f.Controls.Add(title);

        // display card
        var card = new Panel { Location = new Point(12, 42), Size = new Size(240, 58), BackColor = C_CARD };
        var lblExpr = new Label { Text = "", Location = new Point(10, 5), Size = new Size(220, 16), TextAlign = ContentAlignment.MiddleRight,
            Font = F(8F, FontStyle.Regular), ForeColor = C_SUB, BackColor = Color.Transparent };
        var lblMain = new Label { Text = "0", Location = new Point(10, 20), Size = new Size(220, 34), TextAlign = ContentAlignment.MiddleRight,
            Font = F(17F, FontStyle.Regular), ForeColor = C_TEXT, BackColor = Color.Transparent };
        card.Controls.Add(lblExpr); card.Controls.Add(lblMain);
        card.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            if (card.Parent != null) { using (var pb = new SolidBrush(card.Parent.BackColor)) g.FillRectangle(pb, card.ClientRectangle); }
            var rect = new Rectangle(0, 0, card.Width - 1, card.Height - 1);
            using (var path = RoundRect(rect, 8))
            using (var br = new SolidBrush(C_CARD)) { g.FillPath(br, path); }
            using (var path = RoundRect(rect, 8))
            using (var pen = new Pen(C_BORDER, 1)) { g.DrawPath(pen, path); }
        };
        f.Controls.Add(card);

        string expr = "";
        Action Refresh = delegate { lblMain.Text = expr.Length > 0 ? expr : "0"; };
        Action Evaluate = delegate {
            if (expr.Length == 0) return;
            string r = Calc(expr);
            lblExpr.Text = expr + " =";
            expr = r == "Err" ? "" : r;
            if (r == "Err") { lblMain.Text = "Err"; expr = ""; } else Refresh();
        };
        Action<string> Press = delegate(string cap) {
            if (cap == "C") { expr = ""; lblExpr.Text = ""; }
            else if (cap == "<-") { if (expr.Length > 0) expr = expr.Substring(0, expr.Length - 1); }
            else if (cap == "=") { Evaluate(); return; }
            else expr += cap;
            Refresh();
        };

        // key grid 4x5
        string[,] caps = new string[,] {
            { "C", "<-", "(", ")" },
            { "7", "8", "9", "/" },
            { "4", "5", "6", "*" },
            { "1", "2", "3", "-" },
            { "0", ".", "=", "+" },
        };
        int pad = 12, gap = 8, bw = (264 - 2 * pad - 3 * gap) / 4, bh = 38;
        for (int r = 0; r < 5; r++)
            for (int c = 0; c < 4; c++) {
                string cap2 = caps[r, c];
                var b = new TBtn { Text = cap2, Font = fontKey, TabStop = false,
                    Size = new Size(bw, bh), Location = new Point(pad + c * (bw + gap), 110 + r * (bh + gap)) };
                if (cap2 == "=") { b.Bg = C_ACCENT; b.BgHover = Color.FromArgb(255, 26, 134, 255); b.BgDown = Color.FromArgb(255, 0, 108, 224); b.Fg = Color.White; }
                else if (cap2 == "C") { b.Fg = C_RED; }
                else if (cap2 == "(" || cap2 == ")" || cap2 == "/" || cap2 == "*" || cap2 == "-" || cap2 == "+") { b.Bg = C_OP; }
                b.Click += delegate { Press(cap2); f.Focus(); };
                f.Controls.Add(b);
            }

        // keyboard input
        f.KeyPress += delegate(object s, KeyPressEventArgs e) {
            char c = e.KeyChar;
            if (c == '\r') { Evaluate(); e.Handled = true; return; }
            if (c == '\b') { Press("<-"); e.Handled = true; return; }
            if (c == 27) return;                                     // Esc handled in KeyDown
            if ("0123456789.+-*/%()".IndexOf(c) >= 0) { expr += c; Refresh(); e.Handled = true; }
        };
        f.KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) f.Close(); };
        f.Show();
    }
}
[/csharp]
'@
$seedCalc = @'
; ============================================================
;  WgIme C# 插件: 计算器 (由内嵌升级为插件, 现代 UI)
;  输入 jsq (或 calc) 选 ▶计算器: 圆角磁贴按键, 可点按也可键盘直输
;  回车求值, 退格删字符, Esc 关闭; 支持 + - * / % 括号, 兼容全角 ×÷（）
; ============================================================
code = jsq
name = 计算器
desc = 迷你计算器: 四则/括号/取余, 全角符号兼容, 键盘直输回车求值

[csharp]
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

public class CalcPlugin
{
    // palette: light blue-gray body + white cards (matches the clock / toolbox)
    static Color C_BG     = Color.FromArgb(255, 232, 237, 245);
    static Color C_HEADER = Color.FromArgb(255, 220, 227, 239);
    static Color C_CARD   = Color.FromArgb(255, 255, 255, 255);
    static Color C_BORDER = Color.FromArgb(255, 195, 204, 221);
    static Color C_TEXT   = Color.FromArgb(255, 29, 29, 31);
    static Color C_SUB    = Color.FromArgb(255, 110, 116, 133);
    static Color C_ACCENT = Color.FromArgb(255, 0, 122, 255);
    static Color C_OP     = Color.FromArgb(255, 227, 234, 244);    // operator tile tint
    static Color C_RED    = Color.FromArgb(255, 255, 55, 95);

    static Font F(float size, FontStyle st)
    {
        string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
        foreach (string n in names) { try { return new Font(n, size, st, GraphicsUnit.Point); } catch {} }
        return new Font(FontFamily.GenericSansSerif, size, st, GraphicsUnit.Point);
    }
    static GraphicsPath RoundRect(Rectangle r, int rad)
    {
        var p = new GraphicsPath();
        int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    internal class TBtn : Panel   // Panel base: zero native chrome
    {
        public Color Bg = Color.FromArgb(255, 255, 255, 255);
        public Color BgHover = Color.FromArgb(255, 240, 243, 249);
        public Color BgDown = Color.FromArgb(255, 226, 232, 242);
        public Color Fg = Color.FromArgb(255, 29, 29, 31);
        bool hover, down;
        public TBtn() { DoubleBuffered = true; Cursor = Cursors.Hand; }
        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = RoundRect(rect, 8))
            using (var br = new SolidBrush(down ? BgDown : (hover ? BgHover : Bg))) { g.FillPath(br, path); }
            using (var br = new SolidBrush(Fg))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(Text, Font, br, new RectangleF(0, 0, Width, Height), sf);
        }
    }

    // ---------- expression parser (unchanged from the built-in version) ----------
    class P { internal string s; internal int i; }
    static double ParseExpr(P p) { double v = ParseTerm(p); while (p.i < p.s.Length) { char c = p.s[p.i]; if (c == '+') { p.i++; v += ParseTerm(p); } else if (c == '-') { p.i++; v -= ParseTerm(p); } else break; } return v; }
    static double ParseTerm(P p) { double v = ParseFac(p);  while (p.i < p.s.Length) { char c = p.s[p.i]; if (c == '*') { p.i++; v *= ParseFac(p); } else if (c == '/') { p.i++; v /= ParseFac(p); } else if (c == '%') { p.i++; v = (double)((long)v % (long)ParseFac(p)); } else break; } return v; }
    static double ParseFac(P p)
    {
        while (p.i < p.s.Length && p.s[p.i] == ' ') p.i++;
        if (p.i >= p.s.Length) throw new Exception("eof");
        char c = p.s[p.i];
        if (c == '(') { p.i++; double v = ParseExpr(p); if (p.i >= p.s.Length || p.s[p.i] != ')') throw new Exception("paren"); p.i++; return v; }
        if (c == '-') { p.i++; return -ParseFac(p); }
        if (c == '+') { p.i++; return ParseFac(p); }
        int st = p.i;
        while (p.i < p.s.Length && (char.IsDigit(p.s[p.i]) || p.s[p.i] == '.')) p.i++;
        if (st == p.i) throw new Exception("num");
        return double.Parse(p.s.Substring(st, p.i - st), System.Globalization.CultureInfo.InvariantCulture);
    }
    public static string Calc(string s)
    {
        s = s.Replace(" ", "").Replace('×', '*').Replace('÷', '/').Replace('（', '(').Replace('）', ')');
        if (s.Length == 0) return "";
        try {
            var p = new P { s = s };
            double v = ParseExpr(p);
            if (p.i != s.Length || double.IsNaN(v) || double.IsInfinity(v)) return "Err";
            return (v == Math.Floor(v) && Math.Abs(v) < 1e15) ? ((long)v).ToString() : v.ToString("G10");
        } catch { return "Err"; }
    }

    public static void Run()
    {
        var f = new Form();
        f.Text = "WgIme Calc";
        f.FormBorderStyle = FormBorderStyle.None;
        f.AutoScaleMode = AutoScaleMode.None;
        f.StartPosition = FormStartPosition.CenterScreen;
        f.TopMost = true;
        f.KeyPreview = true;
        f.ShowInTaskbar = false;
        f.ClientSize = new Size(264, 356);
        f.BackColor = C_BG;
        EventHandler rg = delegate { try { SetWindowRgn(f.Handle, CreateRoundRectRgn(0, 0, f.Width + 1, f.Height + 1, 20, 20), true); } catch {} };
        f.HandleCreated += delegate { rg(f, EventArgs.Empty); };
        f.Resize += delegate { rg(f, EventArgs.Empty); };
        f.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = RoundRect(new Rectangle(1, 1, f.Width - 3, f.Height - 3), 9))
            using (var pen = new Pen(C_BORDER, 1)) { g.DrawPath(pen, path); }
        };

        var fontTitle = F(9.5F, FontStyle.Bold);
        var fontKey = F(11F, FontStyle.Regular);

        // title bar
        var title = new Panel { Location = new Point(0, 0), Size = new Size(264, 32), BackColor = C_HEADER };
        var capLbl = new Label { Text = "计算器", Font = fontTitle, ForeColor = C_TEXT, AutoSize = true, Location = new Point(12, 7), BackColor = Color.Transparent };
        var close = new Label { Text = "✕", Size = new Size(28, 22), Location = new Point(228, 5), TextAlign = ContentAlignment.MiddleCenter,
            Font = fontTitle, ForeColor = C_TEXT, BackColor = Color.Transparent, Cursor = Cursors.Hand };
        close.MouseEnter += delegate { close.BackColor = Color.FromArgb(255, 232, 17, 35); close.ForeColor = Color.White; };
        close.MouseLeave += delegate { close.BackColor = Color.Transparent; close.ForeColor = C_TEXT; };
        close.Click += delegate { f.Close(); };
        title.Controls.Add(capLbl); title.Controls.Add(close);
        title.Paint += delegate(object s, PaintEventArgs e) {
            using (var pen = new Pen(C_BORDER)) e.Graphics.DrawLine(pen, 0, title.Height - 1, title.Width, title.Height - 1);
        };
        MouseEventHandler drag = delegate(object s, MouseEventArgs e) {
            if (e.Button != MouseButtons.Left) return;
            try { ReleaseCapture(); SendMessage(f.Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } catch {}
        };
        title.MouseDown += drag; capLbl.MouseDown += drag;
        f.Controls.Add(title);

        // display card
        var card = new Panel { Location = new Point(12, 42), Size = new Size(240, 58), BackColor = C_CARD };
        var lblExpr = new Label { Text = "", Location = new Point(10, 5), Size = new Size(220, 16), TextAlign = ContentAlignment.MiddleRight,
            Font = F(8F, FontStyle.Regular), ForeColor = C_SUB, BackColor = Color.Transparent };
        var lblMain = new Label { Text = "0", Location = new Point(10, 20), Size = new Size(220, 34), TextAlign = ContentAlignment.MiddleRight,
            Font = F(17F, FontStyle.Regular), ForeColor = C_TEXT, BackColor = Color.Transparent };
        card.Controls.Add(lblExpr); card.Controls.Add(lblMain);
        card.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            if (card.Parent != null) { using (var pb = new SolidBrush(card.Parent.BackColor)) g.FillRectangle(pb, card.ClientRectangle); }
            var rect = new Rectangle(0, 0, card.Width - 1, card.Height - 1);
            using (var path = RoundRect(rect, 8))
            using (var br = new SolidBrush(C_CARD)) { g.FillPath(br, path); }
            using (var path = RoundRect(rect, 8))
            using (var pen = new Pen(C_BORDER, 1)) { g.DrawPath(pen, path); }
        };
        f.Controls.Add(card);

        string expr = "";
        Action Refresh = delegate { lblMain.Text = expr.Length > 0 ? expr : "0"; };
        Action Evaluate = delegate {
            if (expr.Length == 0) return;
            string r = Calc(expr);
            lblExpr.Text = expr + " =";
            expr = r == "Err" ? "" : r;
            if (r == "Err") { lblMain.Text = "Err"; expr = ""; } else Refresh();
        };
        Action<string> Press = delegate(string cap) {
            if (cap == "C") { expr = ""; lblExpr.Text = ""; }
            else if (cap == "<-") { if (expr.Length > 0) expr = expr.Substring(0, expr.Length - 1); }
            else if (cap == "=") { Evaluate(); return; }
            else expr += cap;
            Refresh();
        };

        // key grid 4x5
        string[,] caps = new string[,] {
            { "C", "<-", "(", ")" },
            { "7", "8", "9", "/" },
            { "4", "5", "6", "*" },
            { "1", "2", "3", "-" },
            { "0", ".", "=", "+" },
        };
        int pad = 12, gap = 8, bw = (264 - 2 * pad - 3 * gap) / 4, bh = 38;
        for (int r = 0; r < 5; r++)
            for (int c = 0; c < 4; c++) {
                string cap2 = caps[r, c];
                var b = new TBtn { Text = cap2, Font = fontKey, TabStop = false,
                    Size = new Size(bw, bh), Location = new Point(pad + c * (bw + gap), 110 + r * (bh + gap)) };
                if (cap2 == "=") { b.Bg = C_ACCENT; b.BgHover = Color.FromArgb(255, 26, 134, 255); b.BgDown = Color.FromArgb(255, 0, 108, 224); b.Fg = Color.White; }
                else if (cap2 == "C") { b.Fg = C_RED; }
                else if (cap2 == "(" || cap2 == ")" || cap2 == "/" || cap2 == "*" || cap2 == "-" || cap2 == "+") { b.Bg = C_OP; }
                b.Click += delegate { Press(cap2); f.Focus(); };
                f.Controls.Add(b);
            }

        // keyboard input
        f.KeyPress += delegate(object s, KeyPressEventArgs e) {
            char c = e.KeyChar;
            if (c == '\r') { Evaluate(); e.Handled = true; return; }
            if (c == '\b') { Press("<-"); e.Handled = true; return; }
            if (c == 27) return;                                     // Esc handled in KeyDown
            if ("0123456789.+-*/%()".IndexOf(c) >= 0) { expr += c; Refresh(); e.Handled = true; }
        };
        f.KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) f.Close(); };
        f.Show();
    }
}
[/csharp]
'@
try {
    $seedDir = Join-Path $env:LOCALAPPDATA 'wgime'
    $seedMark = Join-Path $seedDir 'provisioned-tray.done'
    if (-not (Test-Path $seedMark)) {
        $utf8n = New-Object System.Text.UTF8Encoding($false)
        $toolsPath = Join-Path $env:WGTRAY_DIR 'tools.txt'
        if (-not (Test-Path $toolsPath)) { [IO.File]::WriteAllText($toolsPath, $seedTools, $utf8n) }
        $pdir = Join-Path $env:WGTRAY_DIR 'plugins'
        if (-not (Test-Path $pdir)) { [IO.Directory]::CreateDirectory($pdir) | Out-Null }
        $rf = Join-Path $pdir 'README.txt'
        if (-not (Test-Path $rf)) { [IO.File]::WriteAllText($rf, $seedPluginReadme, $utf8n) }
        $jf = Join-Path $pdir 'calc.txt'
        if (-not (Test-Path $jf)) { [IO.File]::WriteAllText($jf, $seedCalc, $utf8n) }
        try { [IO.Directory]::CreateDirectory($seedDir) | Out-Null } catch {}
        [IO.File]::WriteAllText($seedMark, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $utf8n)
        WgLog "first-run seeding done (tools.txt + plugins samples)"
    }
} catch { WgLog ("seeding failed: " + ($_ | Out-String)) }

[TrayApp]::Run($env:WGTRAY_DIR, $env:WGTRAY_PATH)
WgLog "TrayApp exited"
} catch {
    WgLog ("FATAL: " + ($_ | Out-String))
    throw
}

###WGTRAY_DLL###
'TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAA4fug4AtAnNIbgBTM0hVGhpcyBwcm9ncmFtIGNhbm5vdCBiZSBydW4gaW4gRE9TIG1vZGUuDQ0KJAAAAAAAAABQRQAATAEDACOjjGoAAAAAAAAAAOAAAiELAQsAALwBAAAGAAAAAAAAztsBAAAgAAAA4AEAAAAAEAAgAAAAAgAABAAAAAAAAAAEAAAAAAAAAAAgAgAAAgAAAAAAAAMAQIUAABAAABAAAAAAEAAAEAAAAAAAABAAAAAAAAAAAAAAAHTbAQBXAAAAAOABALACAAAAAAAAAAAAAAAAAAAAAAAAAAACAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAACAAAAAAAAAAAAAAACCAAAEgAAAAAAAAAAAAAAC50ZXh0AAAA1LsBAAAgAAAAvAEAAAIAAAAAAAAAAAAAAAAAACAAAGAucnNyYwAAALACAAAA4AEAAAQAAAC+AQAAAAAAAAAAAAAAAABAAABALnJlbG9jAAAMAAAAAAACAAACAAAAwgEAAAAAAAAAAAAAAAAAQAAAQgAAAAAAAAAAAAAAAAAAAACw2wEAAAAAAEgAAAACAAUAjAwBAOjOAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC5+AQAABC0CAyoCKhMwBwCeAAAAAQAAEXMEAAAKCgMiAAAAQFoLBg8AKAUAAAoPACgGAAAKBwciAAA0QyIAALRCbwcAAAoGDwAoCAAACgdZDwAoBgAACgcHIgAAh0MiAAC0Qm8HAAAKBg8AKAgAAAoHWQ8AKAkAAAoHWQcHIgAAAAAiAAC0Qm8HAAAKBg8AKAUAAAoPACgJAAAKB1kHByIAALRCIgAAtEJvBwAACgZvCgAACgYqAAAbMAkAQgEAAAIAABEfQB9AcwsAAAoKBigMAAAKCwcabw0AAAoHKA4AAApvDwAACiIAAAAAIgAAAAAiAACAQiIAAIBCcxAAAAoiAABgQSgCAAAGDANzEQAACg0HCQhvEgAACt4KCSwGCW8TAAAK3N4KCCwGCG8TAAAK3HMEAAAKEwRyAQAAcCIAAFBCFhhzFAAAChMFcxUAAAoTCBEIF28WAAAKEQgXbxcAAAoRCBMGEQQCEQVvGAAAChYiAABQQiIAAAAAIgAAAAAiAACAQiIAAIBCcxAAAAoRBm8ZAAAKBxdvGgAACigOAAAKcxEAAAoTBwcRBxEEbxIAAAreDBEHLAcRB28TAAAK3N4MEQUsBxEFbxMAAArc3gwRBCwHEQRvEwAACtzeCgcsBgdvEwAACtwGbxsAAAooHAAAChMJ3goGLAYGbxMAAArcEQkqAABBrAAAAgAAAE4AAAAKAAAAWAAAAAoAAAAAAAAAAgAAAEcAAAAdAAAAZAAAAAoAAAAAAAAAAgAAAOYAAAAMAAAA8gAAAAwAAAAAAAAAAgAAAIgAAAB4AAAAAAEAAAwAAAAAAAAAAgAAAHUAAACZAAAADgEAAAwAAAAAAAAAAgAAABEAAAALAQAAHAEAAAoAAAAAAAAAAgAAAAoAAAArAQAANQEAAAoAAAAAAAAACzAFABgAAAAAAAAAfgUAAAQgKAoAAAIDBG8dAAAK3gMm3gAqARAAAAAAAAAUFAADAQAAAQswAQAzAAAAAAAAAH4SAAAELAx+EgAABG8eAAAKLBVzXwAABoASAAAEfhIAAARvHwAACibeAybeAH4SAAAEKgABEAAAAAAAACoqAAMBAAABEzAEAHUEAAADAAARAxZUBBZUAiggAAAKLAIWKgJvIQAACheNPQAAARMGEQYWHyudEQZvIgAACgoGBo5pF1mabyMAAAoLFgw4igAAAAYImm8jAAAKDQlyJwAAcCgkAAAKLQ0JcjEAAHAoJAAACiwIAyVLGGBUK1sJckEAAHAoJAAACiwIAyVLF2BUK0YJckkAAHAoJAAACiwIAyVLGmBUKzEJclUAAHAoJAAACi0aCXJdAABwKCQAAAotDQlyZQAAcCgkAAAKLAgDJUseYFQrAhYqCBdYDAgGjmkXWT9r////B28lAAAKFzMqBxZvJgAACh9hMh8HFm8mAAAKH3owFAQHFm8mAAAKH2FZH0FYVDhkAwAAB28lAAAKFzMqBxZvJgAACh8wMh8HFm8mAAAKHzkwFAQHFm8mAAAKHzBZHzBYVDgxAwAAHwyNPAAAARMHEQcWcm8AAHCiEQcXcnUAAHCiEQcYcnsAAHCiEQcZcoEAAHCiEQcacocAAHCiEQcbco0AAHCiEQcccpMAAHCiEQcdcpkAAHCiEQcecp8AAHCiEQcfCXKlAABwohEHHwpyrQAAcKIRBx8LcrUAAHCiEQcTBBEEBygBAAArEwURBRYyDAQfcBEFWFQ4mgIAAAclEwg5jwIAAP4TfpAAAAQ6PQEAAB8YcykAAAolcr0AAHAWKCoAAAolcskAAHAXKCoAAAolctUAAHAYKCoAAAolct0AAHAZKCoAAAolcvEAAHAaKCoAAAolcvkAAHAbKCoAAAolcgUBAHAcKCoAAAolchEBAHAdKCoAAAolchsBAHAeKCoAAAolci0BAHAfCSgqAAAKJXI/AQBwHwooKgAACiVyUwEAcB8LKCoAAAolcl8BAHAfDCgqAAAKJXJrAQBwHw0oKgAACiVyeQEAcB8OKCoAAAolcoUBAHAfDygqAAAKJXKZAQBwHxAoKgAACiVyowEAcB8RKCoAAAolcq0BAHAfEigqAAAKJXK3AQBwHxMoKgAACiVyvwEAcB8UKCoAAAolcskBAHAfFSgqAAAKJXLVAQBwHxYoKgAACiVy2wEAcB8XKCoAAAr+E4CQAAAE/hN+kAAABBEIEgkoKwAACjkxAQAAEQlFGAAAAAUAAAAOAAAAFwAAACAAAAAoAAAAMQAAAD0AAABJAAAAUgAAAFsAAABkAAAAbQAAAHYAAAB/AAAAiAAAAJEAAACaAAAAoAAAAKYAAACsAAAAsgAAALgAAAC+AAAAxAAAADjFAAAABB8gVDi+AAAABB8NVDi1AAAABB8bVDisAAAABB5UOKQAAAAEHwlUOJsAAAAEIMAAAABUOI8AAAAEIL0AAABUOIMAAAAEILsAAABUK3oEINsAAABUK3EEIN0AAABUK2gEILoAAABUK18EIN4AAABUK1YEILwAAABUK00EIL4AAABUK0QEIL8AAABUKzsEINwAAABUKzIEHyFUKywEHyJUKyYEHyRUKyAEHyNUKxoEHyVUKxQEHydUKw4EHyZUKwgEHyhUKwIWKgNLFv4BFv4BKgAAAAAAAAAgAAAADQAAABsAAAAIAAAACQAAAMAAAAC9AAAAuwAAANsAAADdAAAAugAAAN4AAAC8AAAAvgAAAL8AAADcAAAAIQAAACIAAAAkAAAAIwAAACUAAAAnAAAAJgAAACgAAAATMAQA+gEAAAQAABECLRMDLRBy5QEAcHLxAQBwKAEAAAYqcywAAAoKAhhfLAwGcv8BAHBvLQAACiYCF18sDAZyCwIAcG8tAAAKJgIaXywMBnIVAgBwby0AAAomAh5fLAwGciMCAHBvLQAACiYDH0E3GQMfWjUUBh9hA1gfQVnRby4AAAomOHUBAAADHzA3GQMfOTUUBh8wA1gfMFnRby4AAAomOFcBAAADH3A3HgMfezUZBh9Gby4AAAoDH3BZF1hvLwAACiY4NAEAAB8YjTwAAAETBBEEFnItAgBwohEEF3I5AgBwohEEGHJFAgBwohEEGXJNAgBwohEEGnJhAgBwohEEG3JpAgBwohEEHHJtAgBwohEEHXJxAgBwohEEHnJ1AgBwohEEHwlyeQIAcKIRBB8Kcn0CAHCiEQQfC3KBAgBwohEEHwxyhQIAcKIRBB8NcokCAHCiEQQfDnKNAgBwohEEHw9ykQIAcKIRBB8QcpUCAHCiEQQfEXKfAgBwohEEHxJyqQIAcKIRBB8TcrMCAHCiEQQfFHK7AgBwohEEHxVyxQIAcKIRBB8WctECAHCiEQQfF3LXAgBwohEECx8YjUAAAAEl0JEAAAQoMAAACgwIAygCAAArDQYJFi8YcuECAHAPAXLnAgBwKDEAAAooMgAACisDBwmaby0AAAomBm8zAAAKKgAAAzAEAN4AAAAAAAAAAnsLAAAELS8CKAUAAAZ0AwAAAn0LAAAEAnsLAAAELBcCewsAAAQC/gYJAAAGczQAAAp9JAAABAJ7CwAABCwNAnsLAAAEbzUAAAotASoCewsAAAQXb10AAAYCewsAAAQYb10AAAYCewsAAAQZb10AAAZ+DAAABC0Hfg0AAAQsFgJ7CwAABBd+DAAABH4NAAAEb1wAAAZ+DgAABC0Hfg8AAAQsFgJ7CwAABBh+DgAABH4PAAAEb1wAAAZ+EAAABC0HfhEAAAQsFgJ7CwAABBl+EAAABH4RAAAEb1wAAAYqAAALMAIARAAAAAAAAAADFzMNAnLrAgBwKBQAAAYrLQMYMw0CcvkCAHAoFAAABiscAxkzGAJ7BgAABCwQAnsGAAAEKDYAAApvNwAACt4DJt4AKgEQAAAAAAAAQEAAAwEAAAEacgkDAHAqABswBgDpBQAABQAAEXM4AAAKgBMAAAR+EwAABHLrAgBwGY08AAABEw0RDRZy7gYAcHL2BgBwKAEAAAaiEQ0XcgYHAHCiEQ0YciIHAHCiEQ1vOQAACn4TAAAEciQHAHAZjTwAAAETDhEOFnLuBgBwcvYGAHAoAQAABqIRDhdyBgcAcKIRDhhyIgcAcKIRDm85AAAKfhMAAARyMAcAcBmNPAAAARMPEQ8WcjgHAHByQgcAcCgBAAAGohEPF3JeBwBwohEPGHIiBwBwohEPbzkAAAp+EwAABHKABwBwGY08AAABExAREBZyOAcAcHJCBwBwKAEAAAaiERAXcl4HAHCiERAYciIHAHCiERBvOQAACn4TAAAEcooHAHAZjTwAAAETERERFnKUBwBwcqAHAHAoAQAABqIRERdyxAcAcKIRERhyIgcAcKIREW85AAAKfhMAAARy3gcAcBmNPAAAARMSERIWcpQHAHByoAcAcCgBAAAGohESF3LEBwBwohESGHIiBwBwohESbzkAAAp+EwAABHLmBwBwGY08AAABExMRExZy7AcAcHLyBwBwKAEAAAaiERMXcgwIAHCiERMYciIHAHCiERNvOQAACn4TAAAEciYIAHAZjTwAAAETFBEUFnLsBwBwcvIHAHAoAQAABqIRFBdyDAgAcKIRFBhyIgcAcKIRFG85AAAKfhMAAARyMggAcBmNPAAAARMVERUWcjgIAHByQggAcCgBAAAGohEVF3JcCABwohEVGHIiBwBwohEVbzkAAAp+EwAABHJ4CABwGY08AAABExYRFhZyOAgAcHJCCABwKAEAAAaiERYXclwIAHCiERYYciIHAHCiERZvOQAACn4TAAAEcvkCAHAZjTwAAAETFxEXFnKECABwco4IAHAoAQAABqIRFxdyrAgAcKIRFxhyIgcAcKIRF285AAAKfhMAAARy0AgAcBmNPAAAARMYERgWcoQIAHByjggAcCgBAAAGohEYF3KsCABwohEYGHIiBwBwohEYbzkAAApy2ggAcH8MAAAEfw0AAAQoBgAABiZy8AgAcH8OAAAEfw8AAAQoBgAABiZyBgkAcH8QAAAEfxEAAAQoBgAABiYCchwJAHAoOgAACgoGKBMAAAYGKDsAAAo5ZgIAAAYoPAAACig9AAAKExkWExo4RgIAABEZERqaCwdvIwAACgwIbyUAAAo5KAIAAAgWbyYAAAofIzsaAgAACBZvJgAACh87OwwCAAAIHz1vPgAACg0JFz/8AQAACBYJbz8AAApvIwAACm8hAAAKEwQI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FgQAABtvEwAACtwRBS0xAnsHAAAEb1cAAApyoA0AcHLmDQBwKAEAAAZzVgAAChMLEQsWb1kAAAoRC29VAAAKJioAAAABHAAAAgAvAKDPAA4AAAAAAgBzAbYpAg4AAAAAHgIoXwAACioDMAIAUgAAAAAAAAACe5kAAAR7CgAABBZvaAAACgJ7mQAABHsLAAAELDMCe5kAAAR7CwAABBdvXQAABgJ7mQAABHsLAAAEGG9dAAAGAnuZAAAEewsAAAQZb10AAAYqAAAbMAUAKQEAAAoAABEfHChpAAAKclAOAHAoOgAACoACAAAEfgIAAAQoagAACibeAybeAAKAAwAABAOABAAABCgFAAAGJhdyXA4AcBIAc2sAAAoLcx8BAAYMBi0fcoYOAHByug4AcCgBAAAGckkPAHAobAAACibdugAAAAhzSwAABn2ZAAAECHuZAAAEc20AAAp9CgAABAh7mQAABHsKAAAEclcPAHByWw8AcCgBAAAGFh94INQAAAAobgAACigDAAAGb28AAAoIe5kAAAR7CgAABHJJDwBwb3AAAAoIe5kAAAR7CgAABBdvaAAACgh7mQAABHsKAAAEgAUAAAQIe5kAAARvDAAABgh7mQAABG8PAAAGCP4GIAEABnNSAAAKKHEAAAoocgAACt4KBywGB28TAAAK3CoAAAABHAAAAAAWAA0jAAMBAAABAgBGANgeAQoAAAAAGzADAFIAAAAGAAARAig7AAAKLQLeRwIoPAAACihzAAAKCgZyXw8AcG90AAAKLCkGFo09AAABb3UAAApyfQIAcG9kAAAKLBECKAoAAAYWc0kAAAooSgAACt4DJt4AKgAAARAAAAAAAABOTgADAQAAARswBADAAQAACwAAEX4TAAAELA9+EwAABAMSAG9IAAAKLQEqBheacgYHAHAoJAAACiwLAiggAAAG3Y4BAAAGF5pyXgcAcCgkAAAKLAsCKCEAAAbddAEAAAYXmnLEBwBwKCQAAAosCwIoOgAABt1aAQAABheacgwIAHAoJAAACiwLAig8AAAG3UABAAAGF5pyXAgAcCgkAAAKLAsCKD8AAAbdJgEAAAYXmnK8DABwb2QAAAosFAIGF5odb0AAAAooRQAABt0DAQAABheacswMAHBvZAAACiwVAgYXmh8Lb0AAAAooSAAABt3fAAAABheacmUPAHBvZAAA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jQEAChEhe7AAAARvjAEAChEhe7EAAARvjQEAChEhe7AAAAQRIf4GPQEABnOYAQAKb5kBAAoRJS0OAv4GkAAABnOiAQAKEyURJQsRIXuwAAAEB2+jAQAKBgdvowEACgIojAEAChEhe7AAAARvjQEACnOaAQAKEx0RHRYfJnOHAQAKb4gBAAoRHSAwAgAAHyhziQEACm+KAQAKER1+MwAABG98AQAKER0MAiiMAQAKCG+NAQAKESFz2wEACn2yAAAEIBgBAAANA2/RAAAKFjAEH24rEx9uIBQCAAADb9EAAApbKO4AAAoTBBYTBTheAwAAcz4BAAYTGBEYESF9tAAABHObAAAGExQRFAMRBW/cAQAKeywAAARvhQEAChEUIgAAGEEWKHgAAAZvhgEAChEUF31HAAAEERQRBRb+AX1IAAAEERR+MwAABH1EAAAEERR+NgAABH1FAAAEERR+NgAABH1GAAAEERQRBB8cc4kBAApvigEAChEUHw4RBREEHFhaWBxzhwEACm+IAQAKERQTBhEYEQV9tQAABBEGERj+Bj8BAAZzUgAACm+LAQAKESF7sgAABBEGb90BAAoIb4wBAAoRBm+NAQAKc5oBAAoTFREVFh9Oc4cBAApviAEAChEVIDACAAAJc4kBAApvigEAChEVfjMAAARvfAEAChEVEQUW/gFv1gEAChEVEwcDEQVv3AEACnsuAAAEEwgRCBcvAxgTCBEIHDEDHBMIHw4TCR8KEwofLhMLICQCAAAYEQlaWREIF1kRClpZEQhbEwwDEQVv3AEACnstAAAEb94BAAoRCFgXWREIWxMNc5cAAAYTFhEWFhZzhwEACm+IAQAKERYgJAIAAAkRCRENEQsRClhaWCjfAQAKc4kBAApvigEAChEWfjMAAARvfAEAChEWEw4WEw84qQAAAAMRBW/cAQAKey0AAAQRD2/gAQAKExBzmwAABhMSERIREHsoAAAEb4UBAAoREhEQb+EBAAoREiIAABhBFih4AAAGb4YBAAoREhEMEQtziQEACm+KAQAKERIRCREPEQhdEQwRClhaWBEJEQ8RCFsRCxEKWFpYc4cBAApviAEAChESExEREQL+BowAAAZzUgAACm+LAQAKEQ5vjAEAChERb40BAAoRDxdYEw8RDwMRBW/cAQAKey0AAARv3gEACj8+////c5gAAAYTFxEXGm+pAQAKERcfCm/iAQAKERd+MwAABG98AQAKERcRB31BAAAEERcRDn1CAAAEERcTExEHb4wBAAoRDm+NAQAKEQdvjAEAChETb40BAAoREwL+BoMAAAZzmAEACm+ZAQAKERMC/gaEAAAGc6IBAApvowEAChETAv4GhQAABnOiAQAKb+MBAAoRE349AAAELREU/gaRAAAGc6IBAAqAPQAABH49AAAEb+QBAAoCezAAAAQRB2/lAQAKAiiMAQAKEQdvjQEAChEFF1gTBREFA2/RAAAKP5X8//8Cc5oBAAoTHhEeFiBmAQAAc4cBAApviAEAChEeIDACAAAfcHOJAQAKb4oBAAoRHn47AAAEb3wBAAoRHh8MHhoec+YBAApvpwEAChEefTEAAAQCezEAAAQRJi0OAv4GkgAABnOYAQAKEyYRJm+ZAQAKAnPnAQAKEx8RHxtvqQEAChEfF2/oAQAKER8Xb+kBAAoRHxZv6gEAChEfFm/rAQAKER9+OwAABG98AQAKER9+PAAABG9+AQAKER9y+icAcCIAABBBc+wBAApvhgEAChEffS8AAAQCezEAAARvjAEACgJ7LwAABG+NAQAKc5gAAAYTIBEgGm+pAQAKESAfCm/iAQAKESB+OwAABG98AQAKESATGQJ7MQAABG+MAQAKERlvjQEAChEZAv4GiAAABnOYAQAKb5kBAAoRGQL+BokAAAZzogEACm+jAQAKERkC/gaKAAAGc6IBAApv4wEAChEZfj4AAAQtERT+BpMAAAZzogEACoA+AAAEfj4AAARv5AEACgIojAEACgJ7MQAABG+NAQAKAgJzmQAABn0yAAAEAnsyAAAEKO0BAAoCESctDgL+BpQAAAZz7gEAChMnESco7wEACgIRKC0OAv4GlQAABnOyAQAKEygRKCizAQAKA2/RAAAKLRUCcgwoAHByCykAcCgBAAAGKIsAAAYqABswBQAQAQAAQwAAEQIoNgAACijwAQAKCgJ7MAAABG/xAQAKEwU4hAAAABIFKPIBAAoLB2/zAQAKLHQHb/QBAAoTBhIGBij1AQAKLGIHb4wBAApv9gEAChMHKy4RB29UAQAKdAIAAAEMCHUJAAACDQksFwIJA2UfeFsfMFooggAABhcTBN2QAAAAEQdv/gAACi3J3hURB3U2AAABEwgRCCwHEQhvEwAACtwWEwTeaxIFKPcBAAo6cP///94OEgX+FhoAABtvEwAACtwCezEAAAQsQAJ7MQAABG/0AQAKEwkSCQYo9QEACiwpAnsvAAAEbx8AAAogtgAAABYDZR94WxlaKHwAAAYmAiiHAAAGFxME3gfeAybeABYqEQQqQUwAAAIAAABNAAAAOwAAAIgAAAAVAAAAAAAAAAIAAAAZAAAAlwAAALAAAAAOAAAAAAAAAAAAAAAAAAAACAEAAAgBAAADAAAAAQAAARMwAgBJAAAAEAAAEQN7QgAABG90AQAKA3tBAAAEb3QBAApZCgQWLwMWEAIEBjEDBhACA3tCAAAEb/gBAAoEZS4TA3tCAAAEBGVv+QEACgNv1AEACipaAgMDe0IAAARv+AEACmUEWCiBAAAGKhswBADtAAAARAAAEQN0CQAAAgoGe0IAAARvdAEACgZ7QQAABG90AQAKWQsHFjABKgZvdAEACgwfGAgGe0EAAARvdAEACloGe0IAAARvdAEAClso3wEACg0ICVkGe0IAAARv+AEACmVaB1sTBARvdwEAChMFEQUabw0AAAoYEQQcCXN4AQAKGSh5AAAGEwYGez8AAAQtGyD/AAAAILQAAAAgvAAAACDLAAAAKHsBAAorGSD/AAAAII4AAAAglwAAACCqAAAAKHsBAApzEQAAChMHEQURBxEGbxIAAAreDBEHLAcRB28TAAAK3N4MEQYsBxEGbxMAAArcKgAAAAEcAAACAMUADdIADAAAAAACAIIAXuAADAAAAAATMAQAzQAAAEUAABEDdAkAAAIKBG+CAQAKIAAAEAAuASoGe0IAAARvdAEACgZ7QQAABG90AQAKWQsHFjABKgZvdAEACgwfGAgGe0EAAARvdAEACloGe0IAAARvdAEAClso3wEACg0ICVkGe0IAAARv+AEACmVaB1sTBARv+gEAChEEMioEb/oBAAoRBAlYMB4GF30/AAAEBgRv+gEAChEEWX1AAAAEBhdv2AEACioCBgRv+gEAChEEMg0Ge0EAAARvdAEACisMBntBAAAEb3QBAAplKIIAAAYqAAAAEzAFAHQAAABGAAARA3QJAAACCgZ7PwAABC0BKgZ7QgAABG90AQAKBntBAAAEb3QBAApZCwZvdAEACgwfGAgGe0EAAARvdAEACloGe0IAAARvdAEAClso3wEACg0HFjEECAkwASoCBgRv+gEA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ACBBFiihAAAGb4YBAAoRGn5QAAAEb34BAAoRGigOAAAKb3wBAAoRGiieAQAKb58BAAoRGn29AAAEERx7vQAABBEc/gZIAQAGc1IAAApvoAEAChEce70AAAQRHP4GSQEABnNSAAAKb6EBAAoRHHu9AAAEER8tDgL+BrYAAAZzUgAAChMfER9viwEAChEce7wAAARvjAEACgZvjQEAChEce7wAAARvjAEAChEce70AAARvjQEAChEce7wAAAQRHP4GSgEABnOYAQAKb5kBAAoRIC0OAv4GtwAABnOiAQAKEyARIAsRHHu8AAAEB2+jAQAKBgdvowEACgIojAEAChEce7wAAARvjQEACnOaAQAKExsRGxYfJnOHAQAKb4gBAAoRGyCAAgAAHyhziQEACm+KAQAKERt+SwAABG98AQAKERsMAiiMAQAKCG+NAQAKILoBAAANAntVAAAEAhYJHywSBBILKKkAAAZv5QEACgJ7VQAABAIXCR8sEgUSDCipAAAGb+UBAAoCe1UAAAQCGAkfTBIGEg0oqQAABm/lAQAKAntVAAAEAhkJHywSBxIOKKkAAAZv5QEACgJ7VQAABAIaCR8sEggSDyipAAAGb+UBAAoCe1UAAAQCGwkfTBIJEhAoqQAABm/lAQAKAntVAAAEAhwJHywSChIRKKkAAAZv5QEACh2NPAAAARMiESIWcokqAHCiESIXcpMqAHCiESIYcqMqAHCiESIZcqsqAHCiESIacrUqAHByuyoAcCgBAAAGohEiG3LHKgBwcs0qAHAoAQAABqIRIhxy2yoAcHLhKgBwKAEAAAaiESITEiBkAgAAERKOaVsTExYTFDjfAAAAc0sBAAYTFxEXERx9vwAABHO6AAAGExYRFhESERSab4UBAAoRFiIAABhBFiihAAAGb4YBAAoRFhd9WwAABBEWERQW/gF9XAAABBEWfksAAAR9VwAABBEWfk4AAAR9WAAABBEWfk4AAAR9WQAABBEWflEAAAR9WgAABBEWERMfHHOJAQAKb4oBAAoRFh8OERQRE1pYHHOHAQAKb4gBAAoRFhMVERcRFH3AAAAEERURF/4GTAEABnNSAAAKb4sBAAoCe1YAAAQRFW8UAgAKCG+MAQAKERVvjQEAChEUF1gTFBEUERKOaT8W////AhEEEQsorQAABgIRBREMKK4AAAYCEQYRDSiv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QAAAEXMEAAAKCgMYWgsGDwAozgEACg8AKM8BAAoHByIAADRDIgAAtEJv0AEACgYPACjRAQAKB1kPACjPAQAKBwciAACHQyIAALRCb9ABAAoGDwAo0QEACgdZDwAo0gEACgdZBwciAAAAACIAALRCb9ABAAoGDwAozgEACg8AKNIBAAoHWQcHIgAAtEIiAAC0Qm/QAQAKBm8KAAAKBipCfgIAAARyazMAcCg6AAAKKgAbMAIAMAAAAAYAABEo4gAABig7AAAKLBco4gAABig8AAAKKHMAAApvIwAACgreC94DJt4AcokzAHAqBioBEAAAAAAAACUlAAMBAAABQn4CAAAEciYIAHAoOgAACipCfgIAAARylzMAcCg6AAAKKh4CKF8AAAoqHgIoXwAACioAAAswBwAuAAAAAAAAAAIoHwAAChYWAihzAQAKF1gCKHQBAAoXWB8UHxQo6QAABhco6gAABibeAybeACoAAAEQAAAAAAAAKioAAwEAAAFeAnv+AAAEAnsAAQAEfnUBAApvdgEACipeAnv+AAAEAnsAAQAEfnUBAApvdgEACiq+Anv/AAAEIP8AAAAg6AAAAB8RHyMoewEACm98AQAKAnv/AAAEKH0BAApvfgEACiqGAnv/AAAEKA4AAApvfAEACgJ7/wAABH59AAAEb34BAAoqHgIofwEACipeAnsBAQAEewABAAQCewIBAAQo+AAABioAABswBgBUAAAAOAAAEQJ7AgEABAJ7AQEABHsAAQAEe3cAAAQuASoEb3cBAAoabw0AAAp+fQAABCIAAABAc3kBAAoKBG93AQAKBhcXHwsfC287AgAK3goGLAYGbxMAAArcKgEQAAACADUAFEkACgAAAAALMAQANgAAAAAAAAAEb4IBAAogAAAQAC4BKijmAAAGJgIoHwAACiChAAAAGCiDAQAKfoQBAAoo5wAABibeAybeACoAAAEQAAAAAA4AJDIAAwEAAAF+AhZ9eAAABAJ7cwAABBZv2AEACgJ7cwAABG/UAQAKKjICe3MAAARv1AEACipKAntuAAAEbyECAAoCKPkAAAYqXgJ7bgAABG8hAgAKAntuAAAEbyACAAoqdgJ7bgAABG8hAgAKAntvAAAEbyECAAoCKPkAAAYqRgRvjgEACh8bMwYCKH8BAAoqGzAGABQHAAB4AAARFBMUFBMVFBMWFBMXFBMYFBMZFBMaFBMbFBMcAnN6AAAKfXQAAAQCczwCAAp9dQAABAIojwEACnOGAQAGExMREwJ9AAEABAJytTMAcHLPMwBwKAEAAAZvhQEACgIWKJABAAoCFyiSAQAKAhcokwEACgIXKJQBAAoCIK4BAAAgSgEAAHOJAQAKKJUBAAoo4wAABgoCFn13AAAEFgsrHH56AAAEB5oGKCQAAAosCQIHfXcAAAQrDgcXWAsHfnoAAASOaTLaAn57AAAEAnt3AAAEjwwAAAFxDAAAAW98AQAKAijsAAAGERMRFC0OAv4G+gAABnNSAAAKExQRFH3+AAAEAhET/gaHAQAGc1IAAAoolgEACgIRE/4GiAEABnNSAAAKKJcBAAoCc5oBAAoTCREJG2+pAQAKEQl+ewAABAJ7dwAABI8MAAABcQwAAAFvfAEAChEJHxAeGh8Mc+YBAApvpwEAChEJfXEAAAQCc+cBAAoTChEKG2+pAQAKEQoXb+gBAAoRChZv6wEAChEKfnsAAAQCe3cAAASPDAAAAXEMAAABb3wBAAoRCn59AAAEb34BAAoRChZv6gEAChEKIgAAMEEWKOAAAAZvhgEAChEKfWwAAAQCe3EAAARvjAEACgJ7bAAABG+NAQAKAnMHAQAGEwsRCxpvqQEAChELHwpv4gEAChELfnsAAAQCe3cAAASPDAAAAXEMAAABb3wBAAoRC31zAAAEAntxAAAEb4wBAAoCe3MAAARvjQEACgIojAEACgJ7cQAABG+NAQAKAnOaAQAKEwwRDBdvqQEAChEMHyJvLgIAChEMfnwAAAQCe3cAAASPDAAAAXEMAAABb3wBAAoRDH1yAAAEAiiMAQAKAntyAAAEb40BAAoCc5oBAAoTDRENF2+pAQAKEQ0fJm8uAgAKEQ1+fAAABAJ7dwAABI8MAAABcQwAAAFvfAEAChENfXAAAARzmwEAChMOEQ5y7AcAcHLvMwBwKAEAAAZvhQEAChEOF2+cAQAKEQ4fDh8Jc4cBAApviAEAChEOIgAAIEEXKOAAAAZvhgEAChEOfn0AAARvfgEAChEOKA4AAApvfAEAChEODAJzmwEAChMPEQ9yIgcAcG+FAQAKEQ8Xb5wBAAoRDx84HwxzhwEACm+IAQAKEQ8iAAAAQRYo4AAABm+GAQAKEQ9+fgAABG9+AQAKEQ8oDgAACm98AQAKEQ99bQAABAJ7cAAABG+MAQAKCG+NAQAKAntwAAAEb4wBAAoCe20AAARvjQEAChETc5sBAAoTEBEQckkkAHBvhQEAChEQHx4fGnOJAQAKb4oBAAoRECCIAQAAHHOHAQAKb4gBAAoREB8gb50BAAoRECIAACBBFijgAAAGb4YBAAoREH59AAAEb34BAAoRECgOAAAKb3wBAAoRECieAQAKb58BAAoREH3/AAAEERN7/wAABBET/gaJAQAGc1IAAApvoAEAChETe/8AAAQRE/4GigEABnNSAAAKb6EBAAoRE3v/AAAEERUtDgL+BvsAAAZzUgAAChMVERVviwEACgJ7cAAABG+MAQAKERN7/wAABG+NAQAKFg040wAAAHOLAQAGEwcRBxETfQEBAARzmgEAChMGEQYfDx8Pc4kBAApvigEAChEGIPYAAAAJHxdaWB8Lc4cBAApviAEAChEGfnsAAAQJjwwAAAFxDAAAAW98AQAKEQYongEACm+fAQAKEQYTBHMEAAAKEwURBRYWHw4fDm89AgAKEQQRBXM+AgAKbz8CAAreAybeABEHCX0CAQAEEQQRB/4GjAEABnNSAAAKb4sBAAoRBBEH/gaNAQAGc5gBAApvmQEACgJ7cAAABG+MAQAKEQRvjQEACgkXWA0JfnoAAASOaT8g////ERYtDgL+BvwAAAZzogEAChMWERYTCAJ7cAAABBEIb6MBAAoIEQhvowEACgJ7bQAABBEIb6MBAAoCKIwBAAoCe3AAAARvjQEACgJ7cwAABAL+BvUAAAZzmAEACm+ZAQAKAntzAAAEAv4G9gAABnOiAQAKb6MBAAoCe3MAAAQC/gb3AAAGc6IBAApv4wEACgJ7cwAABBEXLQ4C/gb9AAAGc6IBAAoTFxEXb+QBAAoCcyMCAAoTERERIJYAAABvJAIAChERfW8AAAQCe28AAAQRGC0OAv4G/gAABnNSAAAKExgRGG8lAgAKAntvAAAEbyACAAoCcyMCAAoTEhESICADAABvJAIAChESfW4AAAQCe24AAAQRGS0OAv4G/wAABnNSAAAKExkRGW8lAgAKAntsAAAEERotDgL+BgABAAZzUgAAChMaERpvGQIACgIo7gAABgIo8AAABgIRGy0OAv4GAQEABnNAAgAKExsRGyhBAgAKAhEcLQ4C/gYCAQAGc7IBAAoTHBEcKLMBAAoqARAAAAAADgUkMgUDAQAAARswAwCXAQAAeQAAEQJ7dAAABG+SAAAKKOQAAAYKBihqAAAKJig7AAAGKDsAAAosQwZykx8AcCjMAAAKjmktNAZy+zMAcCg6AAAKKDsAAAYoPAAACihzAAAKFnNJAAAKKEoAAAooOwAABii1AAAK3gMm3gBzQgIACgsGcpMfAHAozAAAChMHFhMIKywRBxEImgwIKEMCAAoSAyiVAAAKLBEHCW9EAgAKLQgHCQhvRQIAChEIF1gTCBEIEQeOaTLMB29GAgAKEwkrGxIJKEcCAAoTBAJ7dAAABBIEKEgCAApvfgAAChIJKEkCAAot3N4OEgn+Fh4AABtvEwAACtwCe3QAAARvgQAACi0sBnL7MwBwKDoAAAoTBREFciIHAHAWc0kAAAooSgAACgJ7dAAABBEFb34AAAoCFn12AAAEKOUAAAYoPAAACihzAAAKbyMAAAoSBiiVAAAKLB4RBhcyGREGAnt0AAAEb4EAAAowCgIRBhdZfXYAAATeAybeAN4jJgJ7dAAABG+BAAAKLQwCe3QAAAQUb34AAAoCFn12AAAE3gAqAEFkAAAAAAAAMwAAADEAAABkAAAAAwAAAAEAAAECAAAAuwAAACgAAADjAAAADgAAAAAAAAAAAAAAMQEAAD0AAABuAQAAAwAAAAEAAAEAAAAACwAAAGgBAABzAQAAIwAAAAEAAAEbMAMAJgAAABAAABEo5QAABgJ7dgAABBdYChIAKO8AAAoWc0kAAAooSgAACt4DJt4AKgAAARAAAAAAAAAiIgADAQAAAQswAwClAAAAAAAAAAJ7bAAABAJ7dgAABBYyPgJ7dgAABAJ7dAAABG+BAAAKLysCe3QAAAQCe3YAAARvfAAACiwYAnt0AAAEAnt2AAAEb3wAAAooOwAACi0HciIHAHArGwJ7dAAABAJ7dgAABG98AAAKKDwAAAoocwAACm+FAQAK3hMmAntsAAAEciIHAHBvhQEACt4AAntsAAAEAntsAAAEbw8CAApvJQAACm9KAgAKKgAAAAEQAAAAAAAAdnYAEwEAAAEbMAMAfgAAAHoAABECLFcCKDsAAAosTwIoPAAACnNLAgAKCgZvTAIACgsrBwZvTAIACgsHLA0HbyMAAApvJQAACizpBywUB28jAAAKCwdvJQAAChYxBAcM3i7eCgYsBgZvEwAACtzeAybeAHIHNABwcg80AHAoAQAABgMXWIxiAAABKLEAAAoqCCoAAAEcAAACABcAOVAACgAAAAAAAAAAXFwAAwEAAAEeAihfAAAKKhMwAwBdAAAAewAAEQRvggEACiAAABAALgEqA3QTAAACCgJ7AwEABAJ7BAEABHt2AAAEMyMEb00CAAoGb3MBAAofFlkyEgJ7BAEABAJ7AwEABCjzAAAGKgJ7BAEABAJ7AwEABCjxAAAGKlIEb4IBAAogAAAQADMGAijyAAAGKgAAEzADANMBAAB8AAARFBMIAntyAAAEb4wBAApvTgIACgJ7dQAABG9PAgAKAnt0AAAEb4EAAAoWMAQfYCshAihQAgAKEwkSCShRAgAKHxRZHyRZAnt0AAAEb4EAAApbCgYfYDEDH2AKBh84LwMfOAofCgsWDDizAAAAc44BAAYTBREFAn0EAQAEcwUBAAYTBBEEAnt0AAAECG98AAAKCCjvAAAGfX8AAAQRBAgCe3YAAAT+AX2AAAAEEQQHGnOHAQAKb4gBAAoRBAYfGnOJAQAKb4oBAAoRBCIAAAhBFijgAAAGb4YBAAoRBA0RBQh9AwEABAkRBf4GjwEABnOiAQAKb1ICAAoCe3UAAAQJb1MCAAoCe3IAAARvjAEACglvjQEACgcGGlhYCwgXWAwIAnt0AAAEb4EAAAo/PP///wJ7dAAABG+BAAAKHwk8hAAAAHMFAQAGEwcRB3IbNABwfX8AAAQRBxZ9gAAABBEHF32BAAAEEQcHGnOHAQAKb4gBAAoRBx8eHxpziQEACm+KAQAKEQciAAAgQRco4AAABm+GAQAKEQcTBhEGEQgtDgL+BgMBAAZzogEAChMIEQhvUgIACgJ7cgAABG+MAQAKEQZvjQEACgJ7cgAABBdvVAIACioAEzADAIIAAAAQAAARAxYyFwMCe3QAAARvgQAACi8JAwJ7dgAABDMBKgJ7bgAABG8hAgAKAij5AAAGAgN9dgAABAIo7QAABgIo7gAABhYKKy8Ce3UAAAQGb1UCAAoGAnt2AAAE/gF9gAAABAJ7dQAABAZvVQIACm/UAQAKBhdYCgYCe3UAAARvVgIACjLDKgAAGzADAJIAAAAGAAARAnt0AAAEb4EAAAofCTIBKgJ7bgAABG8hAgAKAij5AAAGFAoo5AAABgJ7dAAABG+BAAAKF1iMYgAAAXKNJgBwKLEAAAooOgAACgoGciIHAHAWc0kAAAooSgAACt4DJt4AAnt0AAAEBm9+AAAKAgJ7dAAABG+BAAAKF1l9dgAABAIo7QAABgIo7gAABgIo8AAABioAAAEQAAAAACMAOl0AAwEAAAEbMAQAnAEAAH0AABEDFjIOAwJ7dAAABG+BAAAKMgEqAnt0AAAEb4EAAAoXMB0Ce2wAAARvVwIACgJ7bgAABG8hAgAKAij5AAAGKgJ7dAAABANvfAAACiwkAnt0AAAEA298AAAKKDsAAAosEQJ7dAAABANvfAAACii1AAAK3gMm3gACe3QAAAQDby4BAAoo5AAABgoWCytNAnt0AAAEB298AAAKLDsGch80AHAHjGIAAAFyjSYAcCiAAAAKKDoAAAoMAnt0AAAEB298AAAKCChYAgAKAnt0AAAEBwhvWQIACgcXWAsHAnt0AAAEb4EAAAoypRYNK00Ce3QAAAQJb3wAAAosOwYJF1iMYgAAAXKNJgBwKLEAAAooOgAAChMEAnt0AAAECW98AAAKEQQoWAIACgJ7dAAABAkRBG9ZAgAKCRdYDQkCe3QAAARvgQAACjKl3gMm3gACe3YAAAQCe3QAAARvgQAACjIVAgJ7dAAABG+BAAAKF1l9dgAABCsXAwJ7dgAABC8OAiV7dgAABBdZfXYAAAQCKO0AAAYCKO4AAAYCKPAAAAYqARwAAAAAPgA0cgADAQAAAQAAgQDGRwEDAQAAARMwBQCFAAAARwAAEQQCe2wAAARvHwAACiC6AAAAFhYo6AAABgsSAShvAQAKVAMCe2wAAARvHwAACiDOAAAAFhYo6AAABgwSAihvAQAKVHJJKQBwAntsAAAEb/sBAAoo/AEACg0SAyj9AQAKCgUXAntsAAAEb/4BAAoTBBIEKP0BAAoXBijfAQAKWyjfAQAKVCoAAAAbMAQAyAAAAHIAABECEgASARICKPQAAAYHCDABKgJ7cwAABG90AQAKDR8YCQhaB1so3wEAChMEBwhZEwURBRYwAxYrCQkRBFkGWhEFWxMGBG93AQAKEwcRBxpvDQAAChgRBhwRBHN4AQAKGSjhAAAGEwgCe3gAAAQtGyD/AAAAIKwAAAAgrAAAACC0AAAAKHsBAAorECD/AAAAH3Yfdh9+KHsBAApzEQAAChMJEQcRCREIbxIAAAreDBEJLAcRCW8TAAAK3N4MEQgsBxEIbxMAAArcKgEcAAACAKAADa0ADAAAAAACAGYAVbsADAAAAAATMAUAvQAAAG4AABEEb4IBAAogAAAQAC4BKgISABIBEgIo9AAABgcIMAEqAntzAAAEb3QBAAoNHxgJCFoHWyjfAQAKEwQHCFkTBREFFjADFisJCREEWQZaEQVbEwYEb/oBAAoRBjIwBG/6AQAKEQYRBFgwIwIXfXgAAAQCBG/6AQAKEQZZfXkAAAQCe3MAAAQXb9gBAAoqAntsAAAEbx8AAAogtgAAABYEb/oBAAoRBjIDCCsCCGUo6AAABiYCe3MAAARv1AEACioAAAATMAQAlwAAAG8AABECe3gAAAQtASoCEgASARICKPQAAAYCe3MAAARvdAEACg0fGAkIWgdbKN8BAAoTBAcIWRMFEQUWMQUJEQQwASoEb/oBAAoCe3kAAARZEQVaCREEWVsTBhEGFi8DFhMGEQYRBTEEEQUTBhEGBlkTBxEHLCQCe2wAAARvHwAACiC2AAAAFhEHKOgAAAYmAntzAAAEb9QBAAoqAAswAwDZAAAAAAAAAAIDfXcAAAQo4gAABn56AAAEA5oWc0kAAAooSgAACt4DJt4AAn57AAAEA48MAAABcQwAAAFvfAEACgJ7cQAABH57AAAEA48MAAABcQwAAAFvfAEACgJ7bAAABH57AAAEA48MAAABcQwAAAFvfAEACgJ7cwAABH57AAAEA48MAAABcQwAAAFvfAEACgJ7cAAABH58AAAEA48MAAABcQwAAAFvfAEACgJ7cgAABH58AAAEA48MAAABcQwAAAFvfAEACgJ7cAAABBdvVAIACgJ7cgAABBdvVAIACioAAAABEAAAAAAHABkgAAMBAAABGzAEAAwBAAB+AAARAnt2AAAEFj/fAAAAAnt2AAAEAnt0AAAEb4EAAAo8yQAAAAJ7dAAABAJ7dgAABG98AAAKObMAAAACe3QAAAQCe3YAAARvfAAACgJ7bAAABG8PAgAKFnNJAAAKKEoAAAoCe20AAARyKTQAcHIzNABwKAEAAAYoyAEACgsSAXLtKgBwKMkBAAooMgAACm+FAQAKAnt2AAAEAnt1AAAEb1YCAAovSAJ7dQAABAJ7dgAABG9VAgAKAnt0AAAEAnt2AAAEb3wAAAoCe3YAAAQo7wAABn1/AAAEAnt1AAAEAnt2AAAEb1UCAApv1AEACt4eCgJ7bQAABHIXHwBwBm95AAAKKDIAAApvhQEACt4AKgEQAAAAAAAA7e0AHmEAAAETMAUARwIAAH8AABEcjTwAAAEKBhZyiTMAcKIGF3JBNABwogYYcks0AHCiBhlyWTQAcKIGGnJjNABwogYbcm80AHCiBoB6AAAEHI0MAAABCwcWjwwAAAEg/wAAACD/AAAAIPQAAAAgwgAAACh7AQAKgQwAAAEHF48MAAABIP8AAAAg/AAAACDZAAAAIOQAAAAoewEACoEMAAABBxiPDAAAASD/AAAAIOkAAAAg3AAAACD3AAAAKHsBAAqBDAAAAQcZjwwAAAEg/wAAACDUAAAAIOkAAAAg+gAAACh7AQAKgQwAAAEHGo8MAAABIP8AAAAg2QAAACDyAAAAINwAAAAoewEACoEMAAABBxuPDAAAASD/AAAAIP8AAAAg/wAAACD/AAAAKHsBAAqBDAAAAQeAewAABByNDAAAAQwIFo8MAAABIP8AAAAg/AAAACDpAAAAIKgAAAAoewEACoEMAAABCBePDAAAASD/AAAAIPgAAAAgwgAAACDUAAAAKHsBAAqBDAAAAQgYjwwAAAEg/wAAACDbAAAAIMcAAAAg8QAAACh7AQAKgQwAAAEIGY8MAAABIP8AAAAgvwAAACDcAAAAIPcAAAAoewEACoEMAAABCBqPDAAAASD/AAAAIMUAAAAg6gAAACDLAAAAKHsBAAqBDAAAAQgbjwwAAAEg/wAAACDwAAAAIPAAAAAg8wAAACh7AQAKgQwAAAEIgHwAAAQg/wAAAB86HzofPyh7AQAKgH0AAAQg/wAAACCKAAAAIIoAAAAgkAAAACh7AQAKgH4AAAQqvgJyIgcAcH1/AAAEAiiaAQAKAhdvAwIACgIongEACm+fAQAKAigOAAAKb3wBAAoqABswCAALAgAAgAAAEQNvdwEACgoGGm8NAAAKAigJAgAKLCoCKAkCAApvCgIACnMRAAAKCwYHAigLAgAKbwwCAAreCgcsBgdvEwAACtwCKAkCAAotAxQrEAIoCQIACm8JAgAKdRIAAAIMAnuAAAAELGAILF0WGAIocwEAChdZAih0AQAKGFlzeAEACh0o4QAABg1+ewAABAh7dwAABI8MAAABcQwAAAFzEQAAChMEBhEECW8SAAAK3gwRBCwHEQRvEwAACtzeCgksBglvEwAACtwCe4AAAAQtB35+AAAEKwV+fQAABHMRAAAKEwVzFQAAChMHEQcCe4EAAAQtAxYrARdvFgAAChEHF28XAAAKEQcZb1oCAAoRByAAEAAAb1sCAAoRBxMGBgJ7fwAABAJv+wEAChEFAnuBAAAELQMeKwEWayIAAAAAAihzAQAKAnuBAAAELRACe4AAAAQtBB8OKwUfGCsBFllrAih0AQAKa3MQAAAKEQZvEAIACt4MEQYsBxEGbxMAAArc3gwRBSwHEQVvEwAACtwCe4AAAAQseH5+AAAEcxEAAAoTCHMVAAAKEwoRChdvFgAAChEKF28XAAAKEQoTCQZySSQAcAJv+wEAChEIAihzAQAKHxZZayIAAAAAIgAAoEECKHQBAAprcxAAAAoRCW8QAgAK3gwRCSwHEQlvEwAACtzeDBEILAcRCG8TAAAK3CoAAVgAAAIAJwAPNgAKAAAAAAIAoQALrAAMAAAAAAIAhQA1ugAKAAAAAAIAGQFXcAEMAAAAAAIA3wCffgEMAAAAAAIAuQE38AEMAAAAAAIAngFg/gEMAAAAADoCKJoBAAoCF28DAgAKKh4CKA4BAAYqAAswAQAyAAAAAAAAAAJ7gwAABG8CAgAKdQwAAAEsHwJ7gwAABG8CAgAKpQwAAAEoPQAABigaAgAK3gMm3gAqAAABEAAAAAASABwuAAMBAAABRgRvjgEACh8bMwYCKH8BAAoqHgIoDwEABioAABMwBAAmAgAAgQAAERQTBhQTBxQTCBQTCQIojwEACgJyezQAcHKZNABwKAEAAAZvhQEACgIXKJIBAAoCFyiTAQAKAhcolAEACgIgQAEAACDSAAAAc4kBAAoolQEACgJyAQAAcCIAACBBc+wBAApvhgEACgJzmgEACgwIHw4fDnOHAQAKb4gBAAoIICIBAAAfWnOJAQAKb4oBAAoIKH0BAApvfAEACggXb1wCAAoIfYIAAAQCc5sBAAoNCR8OH3RzhwEACm+IAQAKCSAiAQAAHyxziQEACm+KAQAKCXL6JwBwIgAAKEFz7AEACm+GAQAKCXLHNABwb4UBAAoJfYMAAARzLwIAChMEEQRyyzQAcHLdNABwKAEAAAZvhQEAChEEHw4gqAAAAHOHAQAKb4gBAAoRBCCWAAAAHx5ziQEACm+KAQAKEQQKcy8CAAoTBREFcgU1AHByEzUAcCgBAAAGb4UBAAoRBSCsAAAAIKgAAABzhwEACm+IAQAKEQUghAAAAB8ec4kBAApvigEAChEFCwIojAEACgJ7ggAABG+NAQAKAiiMAQAKAnuDAAAEb40BAAoCKIwBAAoGb40BAAoCKIwBAAoHb40BAAoGEQYtDgL+BhIBAAZzUgAAChMGEQZviwEACgcRBy0OAv4GEwEABnNSAAAKEwcRB2+LAQAKAhEILQ4C/gYUAQAGc7IBAAoTCBEIKLMBAAoCEQktDgL+BhUBAAZz7gEAChMJEQko7wEACioAAAMwBQBaAAAAAAAAAAJ7hAAABH6EAQAKKF0CAAosASoCAv4GEAEABnMWAQAGfYUAAAQCHw4Ce4UAAAQUKAsBAAYWKAgBAAZ9hAAABAJ7gwAABHIlNQBwckU1AHAoAQAABm+FAQAKKqoCe4QAAAR+hAEACihdAgAKLBcCe4QAAAQoCQEABiYCfoQBAAp9hAAABCoAAAATMAQAeQAAAIIAABEDFjJmDwIobwEACgoGIAECAAAzQQXQFwAAAiheAQAKKF4CAAqlFwAAAgsCEgF8iAAABHuGAAAEEgF8iAAABHuHAAAEKBEBAAYCKA8BAAYXKIMBAAoqBiAEAgAAMw0CKA8BAAYXKIMBAAoqAnuEAAAEAwQFKAoBAAYqAAAAGzAHANcAAACDAAARFxdzCwAACgsHKAwAAAoMCAMEFhYXF3OJAQAKb18CAAoHFhZvYAIACgreCggsBghvEwAACtzeCgcsBgdvEwAACtwCe4IAAAQGb3wBAAoCe4MAAAQGjAwAAAFv4QEACgJ7gwAABB8JjQEAAAENCRYGKD0AAAaiCRdyoTUAcKIJGBIAKC8BAAqMbgAAAaIJGXKFAgBwogkaEgAoMQEACoxuAAABogkbcoUCAHCiCRwSACgyAQAKjG4AAAGiCR1ysTUAcKIJHgYoPgAABqIJKL4AAApvhQEACioAARwAAAIADwAcKwAKAAAAAAIACAAvNwAKAAAAAB4CKF8AAAoqQlNKQgEAAQAAAAAADAAAAHY0LjAuMzAzMTkAAAAABQBsAAAA5EYAACN+AABQRwAA4DsAACNTdHJpbmdzAAAAADCDAAC8NQAAI1VTAOy4AAAQAAAAI0dVSUQAAAD8uAAA7BUAACNCbG9iAAAAAAAAAAIAAAFXnwI8CQoAAAD6JTMAFgAAAQAAAOYAAABAAAAABAEAAI8BAAA0AgAAAQAAAGECAAADAAAAZgAAAAMAAACDAAAAAgAAAB8AAAAYAAAAAwAAAAEAAAAFAAAAPQAAAAIAAAAAAAoAAQAAAAAABgDpAOIACgAFAfAACgANAfAACgASAfAACgAYAfAABgAnAeIABgAxAeIACgBfAfAADgCaAYEBDgCnAXIBDgC+AXIBDgDDAXIBCgDSAfAACgDoAfAACgBrAvAABgDYAr0CBgCNA70CBgDcA8wDEgAIBPUDBgAlBBkEBgBIBBkEBgA5BS8FBgDyBb0CFgBFBr0CBgDmBtUGBgA5B+IACgB5B/AACgCOB/AACgANCPAADgCMCHIBDgCRCHIBDgCeCHIBCgAXCfAACgAyCfAABgCYCeIABgD4CtUGCgB9C/AACgAcDPAACgA8DPAACgBpDPAABgCpDuIABgC2DuIABgDsDtoOBgD5DtoOBgBZDzoPBgCBEWERBgChEWERDgD+EXIBDgAFEnIBDgAOEnIBDgAeEoEBDgBUEnIBDgBfEnIBBgBuEuIADgCCEnIBDgCPEnIBDgCcEnIBDgDMEnIBDgDwEoEBBgBRE+IABgBzE+IABgCkE+IABgD3E2ERBgA9FOIABgB1FGERBgCEFOIACgDLFPAADgDSFHIBCgDlFPAABgAFFS8FBgASFS8FEgBdFT4VEgBjFT4VEgBpFT4VEgB7FT4VEgCfFT4VBgCxFeIABgDYFRkEEgATFvUDBgDPFuIAEgAZFwMXCgA5F/AACgBKF/AACgBUF/AACgB2F/AACgCEF/AACgCXF/AAEgDLFwMXQwB/GAAABgCYGL0CNwH+GAAABgAaGS8FBgAkGS8FBgBCGdUGCgBIGfAACgBTGfAABgDAGeIABgAHGuIARwB/GAAABgBvGswDEgDKGvUDEgC9G/UDBgBPHOIACgB3HPAACgCOHPAACgC+HPAABgDNHOIABgDUHOIABgABHeIABgAHHeIABgAMHeIABgAoHcwDEgDPHbEdEgDUHbEdEgDjHbEdEgACHvcdEgAqHrEdEgBcHvUDEgCCHm8eBgCZHtUGBgDjHuIABgDwHtoOBgAcH+IAEgBfH/cdEgBvH7EdEgCYH7EdEgDAH7EdEgDuH7EdEgAUILEdBgBPIL0CEgBdILEdEgB5ILEdEgCOIG8eBgDOILsgEgDaILEdEgAVIbEdEgAxIbEdBgBqIeIABgB2IS8FBgCDIS8FEgCjIW8eEgCtIW8eEgDWIfcdEgD4IfcdEgAKIvcdEgBIIvcdEgBgIvcdEgBwIuIAEgCbIvcdEgDPIvcdEgAOI+8iEgBJI/cdBgBjIy8FBgBwIy8FEgCxIz4VBgA0JOIABgA7JNoOEgBrJFokEgCWJH4kEgDVJO8iEgAIJX4kEgAYJX4kEgBCJX4kBgBzJbsgEgCCJX4kBgDQJdoOBgDdJdoOBgDkJdoOBgAPJuIABgAUJuIABgBkJtoOBgDCJtUGBgAIJ/MmBgApJzoPBgBmJ+IACgC4KPAADgD6KHIBCgA8KfAADgB7KXIBCwCTKQAACgCyKfAACgDDKfAACgDnKfAACgD4KfAACgAYKvAACgCDKvAADgCsKnIBCgDLKvAACgAFK/AABgAlK+IACgAuK/AACgBCK/AACgBVK/AACgCXK/AAcwCzKwAACgDWK/AACgDzK/AAcwAbLAAABgAyLOIACgBKLPAAIwNXLAAAIwN+LAAACgCpLPAAcwC2LAAABgDvLOIACgDFLvAACgDsLvAACgAXL/AACgB+L2IvCgCxL/AABgBNMuIABgBUMuIACgAFN/AAEgDKNwMXCgAZOPAACgAoOPAACgA+OPAACgDHOPAACgDOOPAAmwDsOAAACgD6OfAADgBCOnIBCgBUOvAAEgB8Or0CgwN/GAAADgAYO3IBDgA0O3IBBgCOOzoPBgC9OzoPBgDTOzoPAAAAAAEAAAAAAAEAAQABABAAGQAAAAUAAQABAAMAEAAhAAAACQAkAFoAAwAQACwAAAANACYAYAADABAAOgAAAAUAKAB2AAMAEABFAAAABQAsAHcAAwAQAE0AAAANAC8AeAADABAAVwAAABEAPwCXAAMAEABaAAAAEQA/AJgAAwAQAF8AAAAFAEMAmQAFABAAawAAABEARACbAAMAEABwAAAADQBLAKEAAwAQAH0AAAARAFcAugADABAAggAAABEAYADAAAMAEACIAAAAEQBhAMUAAwAQAI0AAAARAGgA0QADABAAkQAAAA0AaADSAAMAEACaAAAADQBsAOAAAwAQAKMAAAARAH8ABQEDABAAqgAAABEAggAHAQMAEACyAAAADQCCAAgBCwEQALwAAAAZAIYAFgELARAAvwAAABkAiAAWAQMBAADEAAAAHQCNABYBAwAQAM4AAAAFAI0AGgEAAAAAshMAAAUAkAAbARMBAABEFAAAGQCVABsBAwEQAAgYAAAFAJUAGwEDARAAPRgAAAUAlwAdAQMBEADPGAAABQCZAB8BAwEQANYZAAAFAJoAIQEDARAAsRoAAAUAmwAjAQMBEABjHAAABQCcACYBEwEAACUfAAAZAKAAKAEDARAAzCMAAAUAoAAoAQMBEADgIwAABQChACoBAwEQADgmAAAFAKUALAEDARAAdScAAAUApgAuAQMBEACWJwAABQCoADABAwEQAB8tAAAFAK8AOAEDARAAfC0AAAUAtAA+AQMBEADZLwAABQC2AEABAwEQABYwAAAFALgAQgEDARAAxjAAAAUAuwBFAQMBEAAbMQAABQC/AEsBAwEQAI4xAAAFAMEATQEDARAAojEAAAUAyABSAQMBEABcMgAABQDMAFUBAwEQAOMyAAAFANAAWwEDARAA9zIAAAUA2ABfAQMBEACSMwAABQDcAGIBAwEQALwzAAAFAN4AZAEDARAA0DMAAAUA4wBqAQMBEACbNAAABQDlAG0BAwEQAK80AAAFAOsAcgEDARAAwzQAAAUA7QB1ARMBAACTNQAAGQDwAHgBAwEQAMQ1AAAFAPAAeAEDARAATjYAAAUA9gB9AQMBEABjNgAABQD6AIIBAwEQAPc3AAAFAPwAhAEDARAABTkAAAUA/gCGAQMBEABSOQAABQABAYsBAwEQAMc6AAAFAAMBjgExAEMBCgAWAEgBEwAWAFABEwAWAFcBEwAWAGoBFgABAOMBMwABAPoBNwABAAECNwABAAsCOwABABQCFgABABkCQAARACACRAARAC4CRAARADsCRAARAEkCRAARAFYCRAARAGECRAARAH8CQAARAOUCbAARAJQDiQABAJ0DkQABAH8EkQABAIcFkQABAKIFkQABAL4FkQARAOQFeAERAC4GbAARAE8GnwERAI8GsAExAJ8GuQERAO0GwwERAPoGxwEBABsHkQARANwWfAURAJomcg0GAEIHywEhAEsH0gEhAIkH9gEhAJcH+gEDAOwHEwADAPEHEwADAPYHCAIDAPwHEAIDAOwHEwADAAAIFwIDAAgIHwIhABUIIgIhABkIJgIBAB8ILgIBACcIMgIzADMINgIzADkINgIzAEQINgIzAE4INgIzAFcINgIzAGEINgIzAGkINgIzAHAINgIzAHoINgIzAIMINgIRAPItwQ8RADQuwQ8GAKwJCgAGALEJHwIGALkJLgIGAL4JLgIhAIkHqAIGANIJNgIGANUJNgIGAN0JNgIGAOQJCgAGAO8JCgABAPgJCgABAP4JCgAxADsKNgIxAEEKNgIxAEsKNgIxAFMKNgIxAFwKNgIxAGYKNgIxAG4KNgIxAHUKNgIxAH8KNgIxAIgKNgIhABkIJgIhAOMKzgIGANIJNgIGANUJNgIGAN0JNgIGAGoLNgIGAOQJCgAGAO8JCgAGAG0LCgABAPgJCgABAP4JCgAmAHULIgImAHULIgIhAHkLLgIhAIMLBwMBAIgLCgABAI0LHwIBAJULHwIBAJ8LHwJRgMgLHwIzABQMEAIhAJcHJAMBACQMCgAhAGUMIgIhAG8MMAMhAHYMBwMhAHwMBwMhAIMMLgIhAIoMLgIhAI8MLgIhAJUMLgIhAJgMEAIhAOMKNQMBAJ4MHwIBAKIMHwIBAKsMCgABALIMHwIxALwMuQExAL8MPQMxAMUMPQMxAMsMNgIxANEMNgIGANkNEwAGAN8NCgAGAOYNCgAhAD4OLgIhAEUOMAMBAEkOVwMBAFMOWgMGAIAOHwIGAIIOHwIGAIQOawMGAIcORAAGAJEORAAGAJcORAAGAJwObwMDAPUOjAMDAAQPkQMDAAoPEwATABIUaAQTAWEUqwQTAUIf1AkTAFYhaAQTAbA1xxIGAHoPEwAGABwY9gEGAHoPEwAGABwY9gEGAOMY9gEGAEYQigYGAMUaiwcGALMQEwAGACEPEwAGAIkc0AcGAKYc1QcGAEYQigYGAAUkZwwGABYkHwIGABskCgAGALMQEwAGAEwmUg0GABwYnw0GAIkH9gEGAKonow0GALsnfAUGAIMMLgIGAL4nMAMGAHkLLgIGAIAOHwIGAMQnLgIGALsnfAUGAIMMLgIGAL4nMAMGADMtrA8GABwYqAIGAJAttA8GAAYRHwIGABwYqAIGAB0QEwAGACowxwEGAEYQigYGABwYqAIGALsnfAUGAIMMLgIGAL4nMAMGABwYeREGAC8xfREGAAYRHwIGAIkH9REGALYx9REGAAYQ9REGACow+REGALox/REGABwYeREGABUIARIGABEyBRIGAOoPHwIGACIyHwIGAGgQEwAGAIkH9REGACow+REGABwYeREGABUIARIGAEoQ9REGAFUQ9REGACow+REGAAszuQEGABEzSxIGAJ4MuQEGABwYeREGABUIARIGAFIzUBIGAGMzEwAGAGYzEwAGAGkzEwAGAFIzUBIGAKYzHwIGAGQQ9REGACow+REGAOQzgBIGABwYeREGABUIARIGAEs0hRIGAFw0EwAGAIkH9REGABgQ9REGACow+REGANc0+REGABwYeREGABUIARIGACw1pBIGAIQOHwIGACw1pBIGAGgQEwAGAGU1qRIGADMQ9REGANk19REGALYx9REGANw19REGAOA19REGABUIARIGACow+REGAHg2gBIGABwYeREGABUIARIGANg2JxMGAOo2EwAGABwYARIGAB0QEwAGALsnfAUGAL4nMAMGABwYNRQGAGc5ORQGAHk5HwIGAHk5HwIGABwYNRRQIAAAAACRAEYBDQABAFwgAAAAAJEAsgEjAAMACCEAAAAAkQDJASsABQAEIwAAAACRAHcCRwAHADgjAAAAAJEAiQJPAAoAiCMAAAAAkQCMAlQACgBwKAAAAACRAJgCXQANAHgqAAAAAIEAowJjAA8AZCsAAAAAgQCwAmcADwDEKwAAAACRAOoCdQAQAMwrAAAAAJEA/AJ5ABAA4DEAAAAAgQAHA2MAEQBUMgAAAACBABQDYwARAKAyAAAAAIEAIwNjABEAXDMAAAAAgQAvA2MAEQDQNgAAAACBADkDYwARAOg3AAAAAIEASwNjABEA6DoAAAAAlgBbA34AEQA8PAAAAACRAF8DeQATAKw8AAAAAIEAdwOEABQAnEAAAAAAgQCBA4QAFQCoQQAAAACRAKcDlQAWAGBCAAAAAJEAsAN5ABcAoEcAAAAAkQC6A54AGADQRwAAAACRAMMDowAZAEBIAAAAAJEA6AOqABsAiEkAAAAAkQAzBLQAHgCISgAAAACRAD0EtAAgAORKAAAAAJEAUQS8ACIAsEsAAAAAkQBgBM0ALAAwTAAAAACRAGgE3AAxAKxVAAAAAIEAdQRjADUAQFYAAAAAgQCHBGMANQCQVgAAAACTAJQE5wA1AGhXAAAAAJMAnQTtADcA6FcAAAAAkwClBPYAOwBUWQAAAACTAK0E/wA/AAxaAAAAAJEAtgQGAUIAVFoAAAAAkQDABAsBQwDMWgAAAACRAMYEEAFEABBbAAAAAJEA0QQVAUUAsFsAAAAAkwDdBAsBSgC0XAAAAACTAOQECwFLAARdAAAAAJMA7AQhAUwAoF8AAAAAkwD3BCgBTgB0YQAAAACTAAMFIQFRAHhiAAAAAJMADwUwAVMAbGMAAAAAkwAZBXUAUwB8ZQAAAACTACYFNQFTAORqAAAAAJEARgU+AVcA/moAAAAAkQBOBUUBWQALawAAAACRAFUFTAFbADBrAAAAAJEAXAVFAV0AZGsAAAAAkQBoBVMBXwAcbAAAAACTAHQFWwFhABRvAAAAAJMAfgViAWMAqG8AAAAAkwCQBWcBZAAQcAAAAACBAJkFYwBnAF9wAAAAAJMAqwV1AGcAcHAAAAAAgQC1BWMAZwDAcAAAAACTAMgFcgFnABRxAAAAAJMA0QVyAWgAqHIAAAAAgQDaBWMAaQD4cgAAAACRAAAGgQFpAPR0AAAAAJEADwaVAWwAvHUAAAAAkQAiBnkAbgB8eAAAAACRAF8GpgFvAAR5AAAAAJEAcwaqAW8AvHsAAAAAgQCFBoQAcQAsfAAAAACRAKoGMAFyABx9AAAAAJEAuQa9AXIAYH8AAAAAgQDHBoQAcwAQgAAAAACRAAgHpgF0AJiAAAAAAIEAJQdjAHQATYEAAAAAhhgzB2MAdADkMgAAAACBACEWoAJ0APEyAAAAAIEAPxagAnYA/jIAAAAAgQBPFqACeAALMwAAAACBAF8WoAJ6ABgzAAAAAIEAbxagAnwAJTMAAAAAgQB/FqACfgAyMwAAAACBAI8WoAKAADozAAAAAIEAnxagAoIAQjMAAAAAgQCvFqAChABKMwAAAACRAL8WdAWGAFEzAAAAAIEAKReBBYgAxTcAAAAAgQBoGKACigD0fwAAAACRAIAmpgGMAOiAAAAAAJEY7CamAYwAAAAAAIAAkSBPB9oBjAAAAAAAgACRIF4H4gGQAGSBAAAAAIYAbwfoAZIAsIEAAAAAhgBzB2cAlQAQggAAAADEAIEH7wGWAFKCAAAAAIYYMwdjAJcADIYAAAAAhhgzB/4BlwC0jAAAAACBAJwHBAKYAMiMAAAAAIEApgdjAJgAOI8AAAAAgQCyB2MAmACgjwAAAACBALkHYwCYAOePAAAAAIEAwwcEApgAGJAAAAAAgQDLB2MAmABokAAAAACBANMHYwCYALCQAAAAAIEA2wdjAJgALJEAAAAAgQDiB2MAmAB4ggAAAACBACkooAKYAACDAAAAAIEANiiGApoA2oMAAAAAgQBDKKACnABMhAAAAACBAFAojgKeABWFAAAAAIEAXSigAqAANYUAAAAAgQBqKKACogA9hQAAAACBAHcooAKkAEWFAAAAAIEAhCigAqYATYUAAAAAgQCRKKACqABVhQAAAACBAJ4ooAKqAPCFAAAAAIEAqyigAqwA+IUAAAAAgQDFKLENrgC0kQAAAACGGDMHYwCwANKRAAAAAIYYMwdjALAA6JEAAAAAkwCbCDoCsABgkgAAAACTAKgIQgKyAAAAAACAAJMgrwhLArQAAAAAAIAAkyC/CE8CtAAAAAAAgACTIMwIVwK4AAAAAACAAJMg2AhfArwAAAAAAIAAkyDsCGkCwgCclgAAAACDGDMHcALFAGSfAAAAAIEA+gh6AsYAzKAAAAAAgQACCX8CxwAhoQAAAACBAA4JfwLJADihAAAAAIEAJgmGAssAUKIAAAAAgQBBCY4CzQAsowAAAACBAEwJjgLPAKyjAAAAAIEAVwmWAtEAQKQAAAAAgQBkCWMA1ACopAAAAACBAHUJhgLUAJylAAAAAIEAgAmOAtYAYKYAAAAAgQCKCY4C2AAgpwAAAACBAJQJhADaAHCqAAAAAIEAogmgAtsAGJMAAAAAgQCuLaAC3QCUkwAAAACBALsthgLfAG6UAAAAAIEAyC2gAuEA4JQAAAAAgQDVLY4C4wC4lQAAAACRAOItuQ/lAOCVAAAAAIEAGi6GAucAMJYAAAAAkQAnLrkP6QBYlgAAAACBAFwuxg/rAIiWAAAAAIEAaS6xDe0A+KoAAAAAkRjsJqYB7wASrAAAAACGGDMHYwDvACGsAAAAAIYYMwdjAO8AMKwAAAAAgxgzB6wC7wBArAAAAADmAcEJsgLwAICsAAAAAIYYMwdjAPEAAq0AAAAAxAADCrkC8QAYrQAAAADEABAKuQLyAC6tAAAAAMQAHQrAAvMARK0AAAAAxAApCsAC9ABcrQAAAADEADMKxwL1AGCvAAAAAJMAmwg6AvYA2K8AAAAAkQCRCkIC+AAAAAAAgACRIJgKSwL6AAAAAACAAJEgqApPAvoAAAAAAIAAkSC1ClcC/gAAAAAAgACRIMEKXwICAQAAAACAAJEg1QppAggBULMAAAAAhhgzB2MACwH4uAAAAACBAOkK1gILAbC5AAAAAIEA8grkAhABELoAAAAAgQDSCfACFgE0ugAAAACRAAQLngAXAXC+AAAAAIEACgv3AhgBlMEAAAAAgQAXC/cCGgH0xAAAAACBACcL9wIcAQDJAAAAAIEAMwv3Ah4BpM0AAAAAgQBAC/cCIAH80AAAAACBAE0L9wIiAYTWAAAAAIEAXAv3AiQBkLAAAAAAgQBNMaACJgEMsQAAAACBAFoxhgIoAeaxAAAAAIEAZzGgAioBWLIAAAAAgQB0MY4CLAE8swAAAACBAIExsQ0uASzXAAAAAJEY7CamATABSNgAAAAAhhgzB2MAMAHg2AAAAADEAAMKuQIwAfbYAAAAAMQAEAq5AjEBDNkAAAAAxAAdCsACMgEi2QAAAADEACkKwAIzATjZAAAAAMQAMwrHAjQByNsAAAAAhhgzB/8CNQHU3AAAAADEADMKxwI5AajbAAAAAIEAFzegAjoBttsAAAAAgQAlN6ACPAG+2wAAAACBADM3oAI+ARjgAAAAAIYYMwcMA0ABAOIAAAAAgQCpC5YCRAGU4gAAAACBALELhgJHAaDjAAAAAIYAuguEAEkBKOQAAAAAhgC/C4QASgFE5AAAAACGAMMLFANLARzeAAAAAIEAcTeOAkwB6N4AAAAAgQB/N44CTgGL3wAAAACBAI03jgJQAazfAAAAAIEAmzegAlIB8N8AAAAAgQCpN6ACVAH93wAAAACBALc3oAJWAeDkAAAAAIYYMwdjAFgBAAAAAIAAkSDbCx8DWAEAAAAAgACRIPYLHwNZASzlAAAAAIYYMwdjAFoBiecAAAAAxAAsDLkCWgGe5wAAAADEAFAMKQNbAbTnAAAAAIEAXQxjAFwBNOgAAAAAgQCmB2MAXAHY6AAAAADEAIEH7wFcAe/kAAAAAIEAYzigAl0B9+QAAAAAgQBxOKACXwEJ5QAAAACBAH84oAJhARHlAAAAAIEAjTigAmMBGeUAAAAAgQCbOLENZQFc6QAAAACRGOwmpgFnAWjpAAAAAJEA1gw6AmcB4OkAAAAAkQDZDEICaQGG6gAAAACRAOMMdQBrAZjqAAAAAJEA8Qx1AGsB5OoAAAAAkQD/DHUAawH16gAAAACRAAgNdQBrAQAAAACAAJEgFQ1LAmsBAAAAAIAAkSAkDU8CawEAAAAAgACRIDANVwJvAQAAAACAAJEgOw1fAnMBAAAAAIAAkSBODWkCeQFU7QAAAACGGDMHYwB8AYT0AAAAAIEAWw1jAHwBjPYAAAAAgQBlDWMAfAHQ9gAAAACBAG4NYwB8AZT3AAAAAJEAdg3nAHwBxPgAAAAAgQB+DWMAfgGk+gAAAACBAIoNZwB+ATT7AAAAAIEAkw1jAH8B5PsAAAAAgQCbDWcAfwGo/QAAAACBAKYNlgKAATz+AAAAAIEAsA2GAoMBLP8AAAAAgQC4DY4ChQH4/wAAAACBAL8NjgKHAZwAAQAAAIEAxg1nAIkBlAEBAAAAgQDRDWMAigEY6wAAAACBAJg5oAKKAebrAAAAAIEApjmgAowBeOwAAAAAgQC0OY4CjgHM7AAAAACBAMI5jgKQAezsAAAAAIEA0DmgApIB+ewAAAAAgQDeOaAClAEM7QAAAACBAOw5oAKWASTtAAAAAIEADzo+FJgBQu0AAAAAgQAdOrENmgGt+AAAAACBAPA6jgKcAbwCAQAAAJEY7CamAZ4BDwUBAAAAhhgzB2MAngFABQEAAADEADMKxwKeAbAHAQAAAIYYMwdjAJ8BAAAAAIAAkSDtDUIDnwEAAAAAgACRIP4NHwOjAQAAAACAAJEgEg5PAqQBAAAAAIAAkSAhDksDqAEAAAAAgACRIDEOUAOpATQIAQAAAIYYMwdjAKoBaAoBAAAAgQBYDmMAqgHOCgEAAACBAGIOYwCqAfwKAQAAAIEAaw5eA6oBhAsBAAAAgQB5DmUDrQG/BwEAAACBAFY7oAKvAcgHAQAAAIEAZDugArEBGAgBAAAAgQByO7ENswEqCAEAAACBAIA7xg+1AQAAAAADAIYYMwdyA7cBAAAAAAMAxgGiDl4DuQEAAAAAAwDGAcQOeAO8AQAAAAADAMYB0A6FA8EBhAwBAAAAhhgzB2MAwgGiNwAAAACGGDMHYwDCAbI3AAAAAIYAJhigAsIBqjcAAAAAhhgzB2MAxAHSNwAAAACGAFEYoALEAYA6AAAAAIYYMwdjAMYBiDoAAAAAhgDnGKACxgGUPgAAAACGGDMHYwDIAZw+AAAAAIYA6hljAMgBRkkAAAAAhhgzB2MAyAFOSQAAAACGAOAajwfIAWpJAAAAAIYA8RqPB8oBBEwAAAAAhhgzB2MAzAEMTAAAAACGAKoc2gfMAXh5AAAAAIYYMwdjAMwBvHkAAAAAhgD0I2MAzAGAeQAAAACGGDMHYwDMAYh5AAAAAIYAIyRjAMwBAH8AAAAAhhgzB2MAzAEIfwAAAACGAE8mYwDMAWWCAAAAAIYYMwdjAMwBHYUAAAAAhgCJJ6ACzAFtggAAAACGGDMHYwDOAcSCAAAAAIYAySegAs4B4YIAAAAAhgDWJ6AC0AGIgwAAAACGAOMnoALSAbiDAAAAAIYA8CegAtQB5IMAAAAAhgD9J4YC1gGghAAAAACGAAooqA3YAWCFAAAAAIYAFyiGAtsBBpMAAAAAhhgzB2MA3QFkkwAAAACGADstoALdAXyTAAAAAIYASC2gAt8BHJQAAAAAhgBVLaAC4QFMlAAAAACGAGItoALjAXiUAAAAAIYAby2GAuUBDpMAAAAAhhgzB2MA5wE0lQAAAACGAKEtoALnAQSnAAAAAIYYMwdjAOkBDKcAAAAAhgDtL2MA6QGNpwAAAACGGDMHYwDpAaSnAAAAAIYALjBjAOkBlacAAAAAhgA/MGMA6QF+sAAAAACGGDMHYwDpAdywAAAAAIYA2jCgAukB9LAAAAAAhgDnMKAC6wGUsQAAAACGAPQwoALtAcSxAAAAAIYAATGgAu8B8LEAAAAAhgAOMYYC8QGGsAAAAACGGDMHYwDzAayyAAAAAIYAQDGgAvMBXroAAAAAhhgzB2MA9QEQvQAAAACGAMExoAL1AT2+AAAAAIYA1TGgAvcBSL4AAAAAhgDpMaAC+QFavgAAAACGAP0xoAL7AWa6AAAAAIYYMwdjAP0BhLoAAAAAhgAlMmMA/QFuugAAAACGADkyYwD9AXLAAAAAAIYYMwdjAP0BCMEAAAAAhgBwMqAC/QFswQAAAACGAIcyoAL/AX7BAAAAAIYAnjKgAgECiMAAAAAAhgC1MmMAAwJ6wAAAAACGAMwyYwADAn7CAAAAAIYYMwdjAAMC9MMAAAAAhgAZM6ACAwLNxAAAAACGACwzoAIFAt/EAAAAAIYAPzOgAgcCHMMAAAAAhhgzB2MACQI4wwAAAACGAGwzYwAJAiTDAAAAAIYAfzNjAAkChsIAAAAAhhgzB2MACQKQwgAAAACGAKkzoAIJAo7HAAAAAIYYMwdjAAsCMMgAAAAAhgDnM2MACwKtyAAAAACGAPszoAILArrIAAAAAIYADzSxDQ0C2MgAAAAAhgAjNKACDwLqyAAAAACGADc0oAIRApbHAAAAAIYYMwdjABMCtMcAAAAAhgBeNGMAEwKexwAAAACGAHI0YwATAjLKAAAAAIYYMwdjABMCMMsAAAAAhgDcNKACEwK0zAAAAACGAPA0oAIVAnzNAAAAAIYABDWgAhcCjs0AAAAAhgAYNaACGQI6ygAAAACGGDMHYwAbAmDKAAAAAIYAPTVjABsCSsoAAAAAhgBRNWMAGwJCygAAAACGGDMHYwAbAqjLAAAAAIYAazVjABsClcsAAAAAhgB/NWMAGwL2zgAAAACGGDMHYwAbAgDPAAAAAIYA5DWgAhsCeM8AAAAAhgD6NaACHQIg0AAAAACGABA2oAIfAlTQAAAAAIYAJzagAiEC69QAAAAAhhgzB2MAIwIY1gAAAACGAIA2YwAjAj3WAAAAAIYAljagAiMCTNYAAAAAhgCsNqACJQIk1QAAAACGAMI2YwAnAvPUAAAAAIYYMwdjACcC+9QAAAAAhgDvNmMAJwKE4wAAAACGGDMHYwAnAozjAAAAAIYADDhjACcCBusAAAAAhhgzB2MAJwJk6wAAAACGABo5oAInAnzrAAAAAIYAKDmgAikClOsAAAAAhgA2OaACKwLE6wAAAACGAEQ5oAItAg7rAAAAAIYYMwdjAC8C7usAAAAAhgB8OaACLwII7AAAAACGAIo5hgIxAjz4AAAAAIYYMwdjADMCRPgAAAAAhgDcOo4CMwIAAAEAEA8AAAIAEw8AAAEAFg8AAAIAGA8AAAEAHA8AAAIAHw8AAAEAIQ8AAAIAJw8AAAMALA8AAAEAMQ8CAAIANg8CAAMAZg8AAAEANg8AAAIAZg8AAAEAaQ8AAAEAbA8AAAEAbA8AAAIAcA8AAAEAeA8AAAEAeg8AAAEAeg8AAAEAfw8AAAEAbA8AAAEAhA8AAAEAjA8AAAIAkQ8AAAEAlA8CAAIAmQ8CAAMAng8AAAEAog8AAAIAFQgAAAEAog8AAAIAFQgAAAEApg8AAAIArQ8AAAMAsQ8AAAQAtQ8AAAUAwA8AAAYAxA8AAAcAyg8AAAgAFQgQEAkA0g8QEAoA2g8AAAEA3w8AAAIA5A8AAAMA6g8AAAQA7A8AAAUA8Q8AAAEAkQ8AAAIAjA8AAAMAFQgAAAQA+Q8AAAEAiQcAAAIA/A8AAAEAiQcAAAIABhAAAAMA/A8CAAQACxAAAAEAiQcAAAIADxAAAAMA/A8CAAQAExAAAAEAiQcAAAIAGBAAAAMA/A8AAAEAHRAAAAEAHxAAAAEAIRAAAAEAIxAAAAIAKhACAAMAMxACAAQANhACAAUAOxAAAAEAHxAAAAEAHxAAAAEAIxAAAAIAKhAAAAEAIxAAAAIAKhAAAAMAQBAAAAEARhAAAAIASBAAAAEAShAAAAIATxAAAAMAVRAAAAQA/A8AAAEAXBAAAAIAHxAAAAEAIRAAAAIAXhAAAAEAIRAAAAIAXhAAAAEAIRAAAAIAYBAAAAEAIRAAAAIAYBAAAAEAZBAAAAIA/A8AAAEA/A8AAAEAaBAAAAIAahAAAAMAbBAAAAEAHw8AAAEAHw8AAAEAcBAAAAIAdhAAAAMAfBAAAAEAgRAAAAIAhhAAAAEAbA8AAAEAihAAAAIAjxAAAAEAihAAAAEAmBAAAAEAihAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAnxAAAAIAaQ8AAAMApBAAAAQAZg8AAAEAnxAAAAIAaQ8AAAEAaQ8AAAIANg8AAAMAZg8AAAEAaQ8AAAEAIRAAAAEAiQcAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEABhAAAAIAsBAAAAEAFg8AAAIAGA8AAAEAnxAAAAIAsxAAAAMAtxAAAAQAvhAAAAEAaBAAAAIAsxAAAAMAXBAAAAQAxRAAAAEAxxAAAAIAyhAAAAMAzRAAAAQA0BAAAAUAXBAAAAYAaBAAAAEAnxAAAAIA0xAAAAMA2BAAAAEA3xAAAAEA5BAAAAEAeQsAAAIA6hAAAAEAeQsAAAIA7hAAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RACAAEA8xACAAIA+RACAAMA0g8AAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEAHRAAAAEA/xAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEA7y0AAAIAAhsAAAEAHRAAAAIA8RAAAAEA7y0AAAIAAhsAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAaBAAAAEAIRAAAAEA8RAAAAEA8RAAAAEA8RAAAAEA8RAAAAEA8RAAAAEABhAAAAIAsBAAAAEAFg8AAAIAGA8AAAEAnxAAAAIAsxAAAAMAtxAAAAQAvhAAAAEAaBAAAAIAsxAAAAMAXBAAAAQAxRAAAAEAxxAAAAIAyhAAAAMAzRAAAAQA0BAAAAUAXBAAAAYAaBAAAAEAnxAAAAIA0xAAAAMA2BAAAAEABhEAAAIAChEAAAMAExECAAQAGBECAAUAFQgAAAEAHBEAAAIAgA4AAAMAgg4AAAQAXBAAAAUAJw8AAAYAIxEAAAEAKxEAAAEAHRAAAAEAGBEAAAIAFQgAAAEAGBEAAAIAFQgAAAEAGBEAAAIAFQgAAAEAGBEAAAIAFQgAAAEAGBEAAAIAFQgAAAEAGBEAAAIAFQgAAAEAGBEAAAIAFQgAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEA8RAAAAEA8RAAAAEA8RAAAAEA8RAAAAEA8RAAAAEAgA4AAAIAgg4AAAMAXBAAAAQAJw8AAAEA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAgA4AAAIAgg4AAAMAXBAAAAQAaBACAAEA8xACAAIA+RACAAMA0g8AAAEAHRAAAAIA8RAAAAEAHRAAAAEAHRAAAAEALhEAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAaBAAAAEAaBAAAAEA8RAAAAEA8RAAAAEAIRAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEABhAAAAIAsBAAAAEAFg8AAAIAGA8AAAEAnxAAAAIAsxAAAAMAtxAAAAQAvhAAAAEAaBAAAAIAsxAAAAMAXBAAAAQAxRAAAAEAxxAAAAIAyhAAAAMAzRAAAAQA0BAAAAUAXBAAAAYAaBAAAAEAnxAAAAIA0xAAAAMA2BAAAAEA3w8AAAIABhEAAAEANBEAAAEANBECAAEA8xACAAIA+RACAAMA0g8AAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEANBEAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAHRAAAAIA8RAAAAEA8RAAAAEAaQ8AAAIANhEAAAMANg8AAAQAOREAAAEAaBAAAAEAaBAAAAIAPREAAAMAtxAAAAQAvhAAAAEAShACAAEAXhAAAAEAPREAAAIAtxAAAAMAvhAAAAEAgA4AAAIAgg4AAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAQxEAAAIAShEAAAEAPREAAAIAtxAAAAMAvhAAAAEAPREAAAIAtxAAAAMAvhAAAAQAUREAAAUAQxEAAAEAWhEAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIAAhsAAAEAHRAAAAIAAhsAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAJCgAAAIAXBAAAAMAaBAAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAHRAAAAIA8RAAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEAMRYAAAIAOBYAAAEA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JQACACYABAAnAAQAKAAHACkABwAqAAcAKwAHACwADAAtAAwALgAMAC8ALgAwAAwAMQAMADIAMQAzAAwANAAMADUANAA2AAwANwA2ADgANgA5ABoAOgAMADsADAA8ADsAPQAPAD4AEgA/ABIAQAASAE8AXwRPALkEAAAAAAA8TW9kdWxlPgB3Z3RyYXlfbmV3LmRsbABUcmF5QXBwAEhvdEtleUhvc3QAUGx1Z2luTWdyRm9ybQBUb29sQWN0aW9uAFRvb2xUYWIAVG9vbHNGb3JtAFZQAFNCYXIAV2hlZWxGaWx0ZXIAVEJ0bgBOZXRUb29sc0Zvcm0ATkJ0bgBORWRpdABOTG9nAERCUABDbGlwRm9ybQBOb3RlRm9ybQBOVENoaXAAU0JQYW5lbABDb2xvckZvcm0AUFQATVNMTABNb3VzZVByb2MAUGx1Z2luQ29kZQBtc2NvcmxpYgBTeXN0ZW0AT2JqZWN0AFN5c3RlbS5XaW5kb3dzLkZvcm1zAENvbnRyb2wARm9ybQBQYW5lbABJTWVzc2FnZUZpbHRlcgBWYWx1ZVR5cGUATXVsdGljYXN0RGVsZWdhdGUAWmgATABEYXRhRGlyAEJhdERpcgBCYXRQYXRoAE5vdGlmeUljb24AdHJheVJlZgBTeXN0ZW0uRHJhd2luZwBTeXN0ZW0uRHJhd2luZy5EcmF3aW5nMkQAR3JhcGhpY3NQYXRoAFJlY3RhbmdsZUYAUm91bmRlZFJlY3QASWNvbgBDb2xvcgBNYWtlSWNvbgBDb250ZXh0TWVudVN0cmlwAG1lbnUAVG9vbFN0cmlwTWVudUl0ZW0AbWlBcHBzAG1pUGx1Z2lucwBob3RJdGVtcwB0cmF5AGhrSG9zdABIb3RUb29sYm94TW9kAEhvdFRvb2xib3hWawBIb3RQbHVnaW5zTW9kAEhvdFBsdWdpbnNWawBIb3RNZW51TW9kAEhvdE1lbnVWawBUb29sVGlwSWNvbgBUcmF5VGlwAHVpSW52b2tlcgBVaQBQYXJzZUhvdGtleQBIb3RrZXlUZXh0AEFwcGx5SG90a2V5cwBIYW5kbGVIb3RLZXkAU3lzdGVtLkNvbGxlY3Rpb25zLkdlbmVyaWMARGljdGlvbmFyeWAyAEFwcHMARGVmYXVsdENvbmZpZ1RleHQATG9hZENvbmZpZwBSZWxvYWRDb25maWcAT3BlbkNvbmZpZ0ZpbGUAT3BlbkRhdGFEaXIAQnVpbGRNZW51AFJlZnJlc2hNZW51Q2hlY2tzAFJlYnVpbGRUcmF5TWVudQBSdW4ARml4TGVnYWN5Q29uZmlnSWZCcm9rZW4ATGF1bmNoQXBwAFJ1blRvb2xDb2RlAExpc3RgMQBUb29sVGFicwB0b29sc0Zvcm0AVG9vbFRva3MATG9hZFRvb2xzAFRvb2xSZXN0AFRvb2xQYXRoAE1pY3Jvc29mdC5XaW4zMgBSZWdpc3RyeUtleQBUb29sUmVnU3BsaXQAU3lzdGVtLkRpYWdub3N0aWNzAFByb2Nlc3NTdGFydEluZm8AU3lzdGVtLlRleHQAU3RyaW5nQnVpbGRlcgBSdW5IaWRkZW4AUnVuVmlzaWJsZQBFbmNvZGluZwBSdW5TY3JpcHRCbG9jawBUb29sRGVsAEV4ZWNUb29sU3RlcABTaG93VG9vbHMAbmV0Rm9ybQBTaG93TmV0VG9vbHMAUGluZ09uY2UAUGluZ1J0dABIb3BPbmNlAFRlc3RQb3J0AFBhcnNlSXBWNABJcFN0cgBNYXNrVG9CaXRzAFBhcnNlSXBNYXNrAElwVHlwZQBJcENsYXNzAFN1Ym5ldENhbGMAU3VibmV0U3BsaXQAUmFuZ2VUb0NpZHIATWFza1RhYmxlAExvY2FsTmV0SW5mbwBEbnNRdWVyeQBTeXN0ZW0uSU8AQmluYXJ5V3JpdGVyAERuc0JFMTYARG5zVTE2AERuc1UzMgBEbnNTa2lwTmFtZQBEbnNSZWFkTmFtZQBIdHRwQ2hlY2sAUHVibGljSXAAY2xpcEZvcm0AQ2xpcFB1c2gAU2hvd0NsaXAAbm90ZUZvcm0ATm90ZXNQYXRoAFNob3dOb3RlAGNvbG9yRm9ybQBDb2xvckhleABDb2xvckhzdgBTaG93Q29sb3IAUGx1Z2luQWN0aW9ucwBJRW51bWVyYWJsZWAxAFBhcnNlVG9vbFN0ZXBzAEV4dHJhY3RQbHVnaW5CbG9jawBMb2FkUGx1Z2lucwBQbHVnaW5JbmZvAFN5c3RlbS5Db3JlAEhhc2hTZXRgMQBEaXNhYmxlZFBsdWdpbnMATG9hZERpc2FibGVkUGx1Z2lucwBTZXRQbHVnaW5EaXNhYmxlZABSdW5QbHVnaW4AUGx1Z2luQ29kZUNhY2hlAFBsdWdpblJlZnMAUGx1Z2luUmVmc0Z1bGwAQ29tcGlsZVBsdWdpbgBSdW5Db2RlUGx1Z2luAFN5c3RlbS5UaHJlYWRpbmcAVGhyZWFkAHBsdWdpblRocmVhZABwbHVnaW5JbnZva2VyAEVuc3VyZVBsdWdpblRocmVhZABwbHVnaW5NZ3IAU2hvd1BsdWdpbk1ncgAuY3RvcgBBY3Rpb25gMQBPbkhvdEtleQByZWcAUmVnaXN0ZXJIb3RLZXkAVW5yZWdpc3RlckhvdEtleQBSZWcAVW5yZWcATWVzc2FnZQBXbmRQcm9jAGhvc3QATGlzdFZpZXcAbGlzdABQbHVnaW5EaXIAUmVmcmVzaExpc3QAUnVuU2VsAFRvZ2dsZVNlbABTZWxGaWxlAE9wZW5EaXIARWRpdFNlbABEZWxTZWwATmV3UGx1Z2luAE5hbWUAQ29kZQBTdGVwcwBSYXcAQWN0aW9ucwBDb2xzAFRleHRCb3gAbG9nAHBhZ2VzAGxvZ1dyYXAAd2hlZWxGaWx0ZXIAVENfQkcAVENfU1VSRkFDRQBUQ19IRUFERVIAVENfU1VSRjIAVENfQk9SREVSAFRDX1RFWFQAVENfU1VCAFRDX0FDQ0VOVABUQ19DT05CRwBUQ19DT05GRwBGb250AEZvbnRTdHlsZQBURgBSZWN0YW5nbGUAVFJvdW5kAFRSZWxlYXNlQ2FwdHVyZQBUU2VuZE1lc3NhZ2UAVFNlbmRNc2dJbnQAVENyZWF0ZVJvdW5kUmVjdFJnbgBUU2V0V2luZG93UmduAE9uV2hlZWwAU2V0VnBPZmZzZXQAU2Nyb2xsVnAAUGFpbnRFdmVudEFyZ3MAUGFnZVNiUGFpbnQATW91c2VFdmVudEFyZ3MAUGFnZVNiRG93bgBQYWdlU2JNb3ZlAExvZ1NiTWV0cmljcwBJbnZhbGlkYXRlTG9nQmFyAExvZ1NiUGFpbnQATG9nU2JEb3duAExvZ1NiTW92ZQBMb2cARXZlbnRBcmdzAFJ1bkFjdGlvbgBEcmFnAERyYWdPZmYASG9zdABWcABQcmVGaWx0ZXJNZXNzYWdlAEJnAEJnSG92ZXIAQmdEb3duAEFjY2VudExpbmUAU2VsZWN0ZWQAaG92ZXIAZG93bgBPbk1vdXNlRW50ZXIAT25Nb3VzZUxlYXZlAE9uTW91c2VEb3duAE9uTW91c2VVcABPblBhaW50AE5DX0JHAE5DX0hFQURFUgBOQ19DQVJEAE5DX1NVUkYyAE5DX0JPUkRFUgBOQ19URVhUAE5DX1NVQgBOQ19BQ0NFTlQATkNfQ09OQkcATkNfQ09ORkcATlJvdW5kAE5SZWxlYXNlQ2FwdHVyZQBOU2VuZE1lc3NhZ2UATlNlbmRNc2dJbnQATkNyZWF0ZVJvdW5kUmVjdFJnbgBOU2V0V2luZG93UmduAGNoaXBzAE1ha2VQYWdlAE1rQnRuAFRocmVhZFN0YXJ0AFN0YW1wAEJ1aWxkUGluZ1RhYgBCdWlsZFRyYWNlcnRUYWIAQnVpbGREbnNUYWIAQnVpbGRIdHRwVGFiAEJ1aWxkUG9ydFRhYgBCdWlsZFN1Ym5ldFRhYgBCdWlsZExvY2FsVGFiAEZnAFByaW1hcnkAQm94AGJhcgBUaW1lcgBzeW5jAGRyYWcAZHJhZ09mZgBsYXN0Rmlyc3QAbGFzdFRvdGFsAE1ldHJpY3MAUGFpbnRCYXIATGluZQBTZXQAU2F2ZQBXTV9DTElQQk9BUkRVUERBVEUAQWRkQ2xpcGJvYXJkRm9ybWF0TGlzdGVuZXIAUmVtb3ZlQ2xpcGJvYXJkRm9ybWF0TGlzdGVuZXIASGlzdG9yeQBMaXN0Qm94AHNlbGZTZXQAT25IYW5kbGVDcmVhdGVkAEZvcm1DbG9zZWRFdmVudEFyZ3MAT25Gb3JtQ2xvc2VkAENvcHlTZWwAYm94AExhYmVsAHN0YXR1cwBzYXZlcgBzYlN5bmMAaGVhZGVyAHdyYXAAc3RyaXAAc2IAZmlsZXMAY3VyAGFjdGl2ZUNpAHNiRHJhZwBzYkRyYWdPZmYAQ04AQ0JvZHkAQ0hlYWQAQ1RleHQAQ1N1YgBORgBOb3RlUm91bmQATm90ZUNvbG9yUGF0aABMb2FkTm90ZUNvbG9yAE5vdGVzRGlyAE5vdGVNZXRhUGF0aABSZWxlYXNlQ2FwdHVyZQBTZW5kTWVzc2FnZQBTZW5kTXNnSW50AENyZWF0ZVJvdW5kUmVjdFJnbgBTZXRXaW5kb3dSZ24ATG9hZE5vdGVzAFNhdmVNZXRhAExvYWRDdXIAVGl0bGVPZgBSZWJ1aWxkVGFicwBTd2l0Y2hUbwBBZGROb3RlAERlbGV0ZU5vdGUAU2JNZXRyaWNzAFBhaW50U2IAU2JEb3duAFNiTW92ZQBBcHBseVRoZW1lAFNhdmVOb3cAVGl0bGUAQWN0aXZlAENlbnRlcgBTZXRXaW5kb3dzSG9va0V4AFVuaG9va1dpbmRvd3NIb29rRXgAQ2FsbE5leHRIb29rRXgAR2V0TW9kdWxlSGFuZGxlAEdldEN1cnNvclBvcwBzd2F0Y2gAbGJsAG1vdXNlSG9vawBwcm9jAFN0YXJ0UGljawBTdG9wUGljawBNb3VzZUhvb2tQcm9jAFBpY2tBdAB4AHkAcHQAbW91c2VEYXRhAGZsYWdzAHRpbWUAZXh0cmEASW52b2tlAElBc3luY1Jlc3VsdABBc3luY0NhbGxiYWNrAEJlZ2luSW52b2tlAEVuZEludm9rZQBTeXN0ZW0uUmVmbGVjdGlvbgBBc3NlbWJseQBBc20ATWV0aG9kSW5mbwBFbnRyeQBFcnJvcgB6aABlbgByAHJhZABjaABjAHRpdGxlAHRleHQAaWNvbgBzcGVjAG1vZABTeXN0ZW0uUnVudGltZS5JbnRlcm9wU2VydmljZXMAT3V0QXR0cmlidXRlAHZrAGlkAGRpcgBiYXRQYXRoAGYAY29kZQBsaW5lAHJhd0xpbmUAcmVzdAB0awBmdWxsAGhpdmUAc3ViAHBzaQBzY3JpcHQAZXh0AGV4ZQBhcmdzUHJlZml4AGVuYwBpb0VuYwBwcmVsdWRlAHZpc2libGUAdGFpbABwYXRoAGlzRGlyAG4AZmFpbABza2lwcGVkAHVpAHRpbWVvdXRNcwBzaXplAHJ0dAB0dGwAZG9uZQBwb3J0AHMAdgBtAGlwVGV4dABtYXNrVGV4dABpcABiaXRzAG1hc2sAY291bnQAYQBiAG5hbWUAcXR5cGUAc2VydmVyAHcAcABwb3MAdXJsAGgAdABjYXAAbGluZXMAc3RlcHMAcmF3cwBib2R5AHRhZwBmaWxlAGRpc2FibGVkAHNvdXJjZQBoV25kAGZzTW9kaWZpZXJzAHN0AG1zZwB3UGFyYW0AbFBhcmFtAGwAeDEAeTEAeDIAeTIAaFJnbgByZWRyYXcAdGFicwBkZWx0YQBvZmYAZHkAZQBmaXJzdAB0b3RhbABzZW5kZXIAaWR4AGNvbnRlbnRIAHRvcEgAdG9wAHBhcmVudABwcmltYXJ5AGZuAG93bmVyAGkAY2IAdGlkAG5Db2RlAG9iamVjdABtZXRob2QAY2FsbGJhY2sAcmVzdWx0AFN5c3RlbS5SdW50aW1lLkNvbXBpbGVyU2VydmljZXMAQ29tcGlsYXRpb25SZWxheGF0aW9uc0F0dHJpYnV0ZQBSdW50aW1lQ29tcGF0aWJpbGl0eUF0dHJpYnV0ZQB3Z3RyYXlfbmV3AGdldF9YAGdldF9ZAEFkZEFyYwBnZXRfUmlnaHQAZ2V0X0JvdHRvbQBDbG9zZUZpZ3VyZQBCaXRtYXAAR3JhcGhpY3MASW1hZ2UARnJvbUltYWdlAFNtb290aGluZ01vZGUAc2V0X1Ntb290aGluZ01vZGUAZ2V0X1RyYW5zcGFyZW50AENsZWFyAFNvbGlkQnJ1c2gAQnJ1c2gARmlsbFBhdGgASURpc3Bvc2FibGUARGlzcG9zZQBHcmFwaGljc1VuaXQAU3RyaW5nRm9ybWF0AFN0cmluZ0FsaWdubWVudABzZXRfQWxpZ25tZW50AHNldF9MaW5lQWxpZ25tZW50AEZvbnRGYW1pbHkAZ2V0X0ZvbnRGYW1pbHkAQWRkU3RyaW5nAENvbXBvc2l0aW5nTW9kZQBzZXRfQ29tcG9zaXRpbmdNb2RlAEdldEhpY29uAEZyb21IYW5kbGUAU2hvd0JhbGxvb25UaXAAZ2V0X0lzRGlzcG9zZWQAZ2V0X0hhbmRsZQBTdHJpbmcASXNOdWxsT3JXaGl0ZVNwYWNlAFRvTG93ZXIAQ2hhcgBTcGxpdABUcmltAG9wX0VxdWFsaXR5AGdldF9MZW5ndGgAZ2V0X0NoYXJzAEFycmF5AEluZGV4T2YAPFByaXZhdGVJbXBsZW1lbnRhdGlvbkRldGFpbHM+e0NFMTBGNUJFLThDOUItNDRFRS05NTcyLTYyRkVDNUE5RUZDMX0AQ29tcGlsZXJHZW5lcmF0ZWRBdHRyaWJ1dGUAJCRtZXRob2QweDYwMDAwMDYtMQBBZGQAVHJ5R2V0VmFsdWUAQXBwZW5kAFVJbnQzMgBfX1N0YXRpY0FycmF5SW5pdFR5cGVTaXplPTk2ACQkbWV0aG9kMHg2MDAwMDA3LTEAUnVudGltZUhlbHBlcnMAUnVudGltZUZpZWxkSGFuZGxlAEluaXRpYWxpemVBcnJheQBUb1N0cmluZwBDb25jYXQAZ2V0X0lzSGFuZGxlQ3JlYXRlZABDdXJzb3IAUG9pbnQAZ2V0X1Bvc2l0aW9uAFRvb2xTdHJpcERyb3BEb3duAFNob3cAc2V0X0l0ZW0AUGF0aABDb21iaW5lAEZpbGUARXhpc3RzAGdldF9VVEY4AFJlYWRBbGxMaW5lcwBTdWJzdHJpbmcAU3lzdGVtLlRleHQuUmVndWxhckV4cHJlc3Npb25zAFJlZ2V4AE1hdGNoAEdyb3VwAGdldF9TdWNjZXNzAEdyb3VwQ29sbGVjdGlvbgBnZXRfR3JvdXBzAGdldF9JdGVtAENhcHR1cmUAZ2V0X1ZhbHVlAEVudmlyb25tZW50AEV4cGFuZEVudmlyb25tZW50VmFyaWFibGVzAFVURjhFbmNvZGluZwBXcml0ZUFsbFRleHQAc2V0X0ZpbGVOYW1lAHNldF9Vc2VTaGVsbEV4ZWN1dGUAUHJvY2VzcwBTdGFydAA8QnVpbGRNZW51PmJfXzMAcGFyYW0wAHBhcmFtMQA8QnVpbGRNZW51PmJfXzQAPEJ1aWxkTWVudT5iX181ADxCdWlsZE1lbnU+Yl9fNgA8QnVpbGRNZW51PmJfXzcAPEJ1aWxkTWVudT5iX184ADxCdWlsZE1lbnU+Yl9fOQA8QnVpbGRNZW51PmJfX2EAPEJ1aWxkTWVudT5iX19iADxCdWlsZE1lbnU+Yl9fYwBFdmVudEhhbmRsZXIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZWUAU3lzdGVtLkNvbXBvbmVudE1vZGVsAENhbmNlbEV2ZW50QXJncwA8QnVpbGRNZW51PmJfX2QAQXBwbGljYXRpb24ARXhpdABUb29sU3RyaXAAVG9vbFN0cmlwSXRlbUNvbGxlY3Rpb24AZ2V0X0l0ZW1zAFRvb2xTdHJpcEl0ZW0AVG9vbFN0cmlwU2VwYXJhdG9yAFRvb2xTdHJpcERyb3BEb3duSXRlbQBnZXRfRHJvcERvd25JdGVtcwBzZXRfRW5hYmxlZABDYW5jZWxFdmVudEhhbmRsZXIAYWRkX09wZW5pbmcAc2V0X0NvbnRleHRNZW51U3RyaXAAc2V0X1RleHQAPD5jX19EaXNwbGF5Q2xhc3MxNAA8PjRfX3RoaXMAPFJlYnVpbGRUcmF5TWVudT5iX18xMQA8PmNfX0Rpc3BsYXlDbGFzczE2ADxSZWJ1aWxkVHJheU1lbnU+Yl9fMTMAPFJlYnVpbGRUcmF5TWVudT5iX18xMgBFbnVtZXJhdG9yAEdldEVudW1lcmF0b3IAS2V5VmFsdWVQYWlyYDIAZ2V0X0N1cnJlbnQAU3RhcnRzV2l0aABnZXRfS2V5AE1vdmVOZXh0ADw+Y19fRGlzcGxheUNsYXNzMTkAYXBwADxSdW4+Yl9fMTgAc2V0X1Zpc2libGUAU3BlY2lhbEZvbGRlcgBHZXRGb2xkZXJQYXRoAERpcmVjdG9yeQBEaXJlY3RvcnlJbmZvAENyZWF0ZURpcmVjdG9yeQBNdXRleABNZXNzYWdlQm94AERpYWxvZ1Jlc3VsdABGcm9tQXJnYgBzZXRfSWNvbgBhZGRfQXBwbGljYXRpb25FeGl0AFJlYWRBbGxUZXh0AENvbnRhaW5zAFRyaW1TdGFydABJc1BhdGhSb290ZWQAc2V0X0FyZ3VtZW50cwBFeGNlcHRpb24AZ2V0X01lc3NhZ2UAPD5jX19EaXNwbGF5Q2xhc3MxZAA8UnVuVG9vbENvZGU+Yl9fMWMAZ2V0X0NvdW50AEludDMyAEpvaW4Ac2V0X0lzQmFja2dyb3VuZABJc1doaXRlU3BhY2UASW5zZXJ0AEVuZHNXaXRoAFRyeVBhcnNlAFRvQXJyYXkASXNOdWxsT3JFbXB0eQBSZXBsYWNlAFRvVXBwZXIAUmVnaXN0cnkAQ3VycmVudFVzZXIATG9jYWxNYWNoaW5lAENsYXNzZXNSb290AFVzZXJzAEN1cnJlbnRDb25maWcAPD5jX19EaXNwbGF5Q2xhc3MyNQBvdXRwAERhdGFSZWNlaXZlZEV2ZW50QXJncwA8UnVuSGlkZGVuPmJfXzIzADxSdW5IaWRkZW4+Yl9fMjQAZTIAZ2V0X0RhdGEAQXBwZW5kTGluZQBzZXRfQ3JlYXRlTm9XaW5kb3cAc2V0X1JlZGlyZWN0U3RhbmRhcmRPdXRwdXQAc2V0X1JlZGlyZWN0U3RhbmRhcmRFcnJvcgBnZXRfU3RhbmRhcmRPdXRwdXRFbmNvZGluZwBnZXRfRGVmYXVsdABzZXRfU3RhbmRhcmRPdXRwdXRFbmNvZGluZwBzZXRfU3RhbmRhcmRFcnJvckVuY29kaW5nAERhdGFSZWNlaXZlZEV2ZW50SGFuZGxlcgBhZGRfT3V0cHV0RGF0YVJlY2VpdmVkAGFkZF9FcnJvckRhdGFSZWNlaXZlZABCZWdpbk91dHB1dFJlYWRMaW5lAEJlZ2luRXJyb3JSZWFkTGluZQBXYWl0Rm9yRXhpdABnZXRfRXhpdENvZGUAR2V0VGVtcFBhdGgAR3VpZABOZXdHdWlkAERlbGV0ZQA8PmNfX0Rpc3BsYXlDbGFzczJkAE1lc3NhZ2VCb3hCdXR0b25zAGJ0bnMATWVzc2FnZUJveERlZmF1bHRCdXR0b24AZGVmADxFeGVjVG9vbFN0ZXA+Yl9fMmMATWVzc2FnZUJveEljb24ARnVuY2AxAERlbGVnYXRlAFBhcnNlAFNsZWVwAEdldFByb2Nlc3Nlc0J5TmFtZQBLaWxsAEludDY0AEJ5dGUAQ29udmVydABUb0J5dGUAQ3JlYXRlU3ViS2V5AFJlZ2lzdHJ5VmFsdWVLaW5kAFNldFZhbHVlAE9wZW5TdWJLZXkARGVsZXRlVmFsdWUARGVsZXRlU3ViS2V5VHJlZQBUcmltRW5kAEdldERpcmVjdG9yeU5hbWUAR2V0RmlsZU5hbWUAR2V0RmlsZXMAR2V0RGlyZWN0b3JpZXMAQWN0aXZhdGUAU3lzdGVtLk5ldC5OZXR3b3JrSW5mb3JtYXRpb24AUGluZwBQaW5nUmVwbHkAU2VuZABJUFN0YXR1cwBnZXRfU3RhdHVzAFN5c3RlbS5OZXQASVBBZGRyZXNzAGdldF9BZGRyZXNzAGdldF9Sb3VuZHRyaXBUaW1lAFBpbmdPcHRpb25zAGdldF9PcHRpb25zAGdldF9UdGwAZ2V0X0J1ZmZlcgBGb3JtYXQAU3RvcHdhdGNoAFN0YXJ0TmV3AFN5c3RlbS5OZXQuU29ja2V0cwBUY3BDbGllbnQAQmVnaW5Db25uZWN0AFdhaXRIYW5kbGUAZ2V0X0FzeW5jV2FpdEhhbmRsZQBXYWl0T25lAEVuZENvbm5lY3QAZ2V0X0VsYXBzZWRNaWxsaXNlY29uZHMAVHlwZQBHZXRUeXBlAE1lbWJlckluZm8AZ2V0X05hbWUAR2V0QWRkcmVzc0J5dGVzAFBhZExlZnQATWF0aABNaW4AX19TdGF0aWNBcnJheUluaXRUeXBlU2l6ZT01NgAkJG1ldGhvZDB4NjAwMDAyZi0xAFBhZFJpZ2h0AERucwBHZXRIb3N0TmFtZQBOZXR3b3JrSW50ZXJmYWNlAEdldEFsbE5ldHdvcmtJbnRlcmZhY2VzAE9wZXJhdGlvbmFsU3RhdHVzAGdldF9PcGVyYXRpb25hbFN0YXR1cwBOZXR3b3JrSW50ZXJmYWNlVHlwZQBnZXRfTmV0d29ya0ludGVyZmFjZVR5cGUASVBJbnRlcmZhY2VQcm9wZXJ0aWVzAEdldElQUHJvcGVydGllcwBVbmljYXN0SVBBZGRyZXNzSW5mb3JtYXRpb25Db2xsZWN0aW9uAGdldF9VbmljYXN0QWRkcmVzc2VzAElFbnVtZXJhdG9yYDEAVW5pY2FzdElQQWRkcmVzc0luZm9ybWF0aW9uAElQQWRkcmVzc0luZm9ybWF0aW9uAEFkZHJlc3NGYW1pbHkAZ2V0X0FkZHJlc3NGYW1pbHkAZ2V0X0lQdjRNYXNrAFN5c3RlbS5Db2xsZWN0aW9ucwBJRW51bWVyYXRvcgBHYXRld2F5SVBBZGRyZXNzSW5mb3JtYXRpb25Db2xsZWN0aW9uAGdldF9HYXRld2F5QWRkcmVzc2VzAEdhdGV3YXlJUEFkZHJlc3NJbmZvcm1hdGlvbgBJUEFkZHJlc3NDb2xsZWN0aW9uAGdldF9EbnNBZGRyZXNzZXMAJCRtZXRob2QweDYwMDAwMzEtMQBSYW5kb20ATmV4dABNZW1vcnlTdHJlYW0AU3RyZWFtAGdldF9BU0NJSQBHZXRCeXRlcwBXcml0ZQBVZHBDbGllbnQAU29ja2V0AGdldF9DbGllbnQAc2V0X1JlY2VpdmVUaW1lb3V0AEFueQBJUEVuZFBvaW50AFJlY2VpdmUAQ29weQBHZXRTdHJpbmcAV2ViUmVxdWVzdABDcmVhdGUASHR0cFdlYlJlcXVlc3QAc2V0X1RpbWVvdXQAc2V0X1JlYWRXcml0ZVRpbWVvdXQAc2V0X1VzZXJBZ2VudABXZWJSZXNwb25zZQBHZXRSZXNwb25zZQBIdHRwV2ViUmVzcG9uc2UAVXJpAGdldF9SZXNwb25zZVVyaQBvcF9JbmVxdWFsaXR5AGdldF9Ib3N0AEh0dHBTdGF0dXNDb2RlAGdldF9TdGF0dXNDb2RlAGdldF9TdGF0dXNEZXNjcmlwdGlvbgBXZWJIZWFkZXJDb2xsZWN0aW9uAGdldF9IZWFkZXJzAFN5c3RlbS5Db2xsZWN0aW9ucy5TcGVjaWFsaXplZABOYW1lVmFsdWVDb2xsZWN0aW9uAGdldF9Db250ZW50VHlwZQBHZXRSZXNwb25zZVN0cmVhbQBSZWFkAFdlYkV4Y2VwdGlvbgBnZXRfUmVzcG9uc2UAU3RyZWFtUmVhZGVyAFRleHRSZWFkZXIAUmVhZFRvRW5kAFJlbW92ZQBSZW1vdmVBdABnZXRfUgBnZXRfRwBnZXRfQgBNYXgAUm91bmQAUmVnZXhPcHRpb25zAFdyaXRlQWxsTGluZXMAPD5jX19EaXNwbGF5Q2xhc3MzMgA8PmNfX0Rpc3BsYXlDbGFzczM1ADxSdW5QbHVnaW4+Yl9fMzAAQ1MkPD44X19sb2NhbHMzMwBlcnJzAGFib3J0ZWQAPFJ1blBsdWdpbj5iX18zMQBBY3Rpb24AQXNzZW1ibHlOYW1lAExvYWQAZ2V0X0xvY2F0aW9uAE1pY3Jvc29mdC5DU2hhcnAAQ1NoYXJwQ29kZVByb3ZpZGVyAFN5c3RlbS5Db2RlRG9tLkNvbXBpbGVyAENvbXBpbGVyUGFyYW1ldGVycwBzZXRfR2VuZXJhdGVJbk1lbW9yeQBzZXRfR2VuZXJhdGVFeGVjdXRhYmxlAFN0cmluZ0NvbGxlY3Rpb24AZ2V0X1JlZmVyZW5jZWRBc3NlbWJsaWVzAEFkZFJhbmdlAENvZGVEb21Qcm92aWRlcgBDb21waWxlclJlc3VsdHMAQ29tcGlsZUFzc2VtYmx5RnJvbVNvdXJjZQBDb21waWxlckVycm9yQ29sbGVjdGlvbgBnZXRfRXJyb3JzAGdldF9IYXNFcnJvcnMAQ29sbGVjdGlvbkJhc2UAQ29tcGlsZXJFcnJvcgBnZXRfTGluZQBnZXRfRXJyb3JUZXh0AGdldF9Db21waWxlZEFzc2VtYmx5AEdldFR5cGVzAEVtcHR5VHlwZXMAQmluZGluZ0ZsYWdzAEJpbmRlcgBQYXJhbWV0ZXJNb2RpZmllcgBHZXRNZXRob2QAZ2V0X1JldHVyblR5cGUAVm9pZABSdW50aW1lVHlwZUhhbmRsZQBHZXRUeXBlRnJvbUhhbmRsZQA8PmNfX0Rpc3BsYXlDbGFzczNhAHBjADxSdW5Db2RlUGx1Z2luPmJfXzM4AE1ldGhvZEJhc2UAR2V0QmFzZUV4Y2VwdGlvbgA8RW5zdXJlUGx1Z2luVGhyZWFkPmJfXzNjAENTJDw+OV9fQ2FjaGVkQW5vbnltb3VzTWV0aG9kRGVsZWdhdGUzZABBcGFydG1lbnRTdGF0ZQBTZXRBcGFydG1lbnRTdGF0ZQBzZXRfTmFtZQAuY2N0b3IAU3lzdGVtLkdsb2JhbGl6YXRpb24AQ3VsdHVyZUluZm8AZ2V0X0N1cnJlbnRVSUN1bHR1cmUARGxsSW1wb3J0QXR0cmlidXRlAHVzZXIzMi5kbGwAQ29udGFpbnNLZXkAZ2V0X01zZwBnZXRfV1BhcmFtAEludFB0cgBUb0ludDMyADw+Y19fRGlzcGxheUNsYXNzNjYAPC5jdG9yPmJfXzUwADw+Y19fRGlzcGxheUNsYXNzNjgAQ1MkPD44X19sb2NhbHM2NwByZwBjbG9zZQBjYXJkADwuY3Rvcj5iX180NgA8LmN0b3I+Yl9fNDcAPC5jdG9yPmJfXzQ5ADwuY3Rvcj5iX180YQA8LmN0b3I+Yl9fNGMAPC5jdG9yPmJfXzRlADwuY3Rvcj5iX181NgBjYXAyADwuY3Rvcj5iX180NQA8LmN0b3I+Yl9fNDgAPC5jdG9yPmJfXzRiADwuY3Rvcj5iX180ZAA8LmN0b3I+Yl9fNGYAPC5jdG9yPmJfXzUxADwuY3Rvcj5iX181MgA8LmN0b3I+Yl9fNTMAPC5jdG9yPmJfXzU0ADwuY3Rvcj5iX181NQA8LmN0b3I+Yl9fNTcAS2V5RXZlbnRBcmdzADwuY3Rvcj5iX181OABnZXRfV2lkdGgAZ2V0X0hlaWdodABFbXB0eQBnZXRfR3JhcGhpY3MAUGVuAERyYXdQYXRoAHNldF9CYWNrQ29sb3IAZ2V0X1doaXRlAHNldF9Gb3JlQ29sb3IAQ2xvc2UARHJhd0xpbmUATW91c2VCdXR0b25zAGdldF9CdXR0b24Ab3BfRXhwbGljaXQAWmVybwBzZXRfRm9udABzZXRfTG9jYXRpb24AU2l6ZQBzZXRfU2l6ZQBhZGRfQ2xpY2sAQ29udHJvbENvbGxlY3Rpb24AZ2V0X0NvbnRyb2xzAEtleXMAZ2V0X0tleUNvZGUARm9ybUJvcmRlclN0eWxlAHNldF9Gb3JtQm9yZGVyU3R5bGUAQ29udGFpbmVyQ29udHJvbABBdXRvU2NhbGVNb2RlAHNldF9BdXRvU2NhbGVNb2RlAEZvcm1TdGFydFBvc2l0aW9uAHNldF9TdGFydFBvc2l0aW9uAHNldF9Ub3BNb3N0AHNldF9LZXlQcmV2aWV3AHNldF9DbGllbnRTaXplAGFkZF9IYW5kbGVDcmVhdGVkAGFkZF9SZXNpemUAUGFpbnRFdmVudEhhbmRsZXIAYWRkX1BhaW50AHNldF9BdXRvU2l6ZQBDb250ZW50QWxpZ25tZW50AHNldF9UZXh0QWxpZ24AQ3Vyc29ycwBnZXRfSGFuZABzZXRfQ3Vyc29yAGFkZF9Nb3VzZUVudGVyAGFkZF9Nb3VzZUxlYXZlAE1vdXNlRXZlbnRIYW5kbGVyAGFkZF9Nb3VzZURvd24AQWN0aW9uYDMAUGFkZGluZwBzZXRfUGFkZGluZwBEb2NrU3R5bGUAc2V0X0RvY2sAVmlldwBzZXRfVmlldwBzZXRfRnVsbFJvd1NlbGVjdABzZXRfTXVsdGlTZWxlY3QAc2V0X0hpZGVTZWxlY3Rpb24AQm9yZGVyU3R5bGUAc2V0X0JvcmRlclN0eWxlAENvbHVtbkhlYWRlckNvbGxlY3Rpb24AZ2V0X0NvbHVtbnMAQ29sdW1uSGVhZGVyAGFkZF9Eb3VibGVDbGljawBLZXlFdmVudEhhbmRsZXIAYWRkX0tleURvd24AQmVnaW5VcGRhdGUATGlzdFZpZXdJdGVtQ29sbGVjdGlvbgBTdHJpbmdDb21wYXJpc29uAEVxdWFscwBMaXN0Vmlld0l0ZW0ATGlzdFZpZXdTdWJJdGVtQ29sbGVjdGlvbgBnZXRfU3ViSXRlbXMATGlzdFZpZXdTdWJJdGVtAHNldF9UYWcAZ2V0X0dyYXkARW5kVXBkYXRlAElXaW4zMldpbmRvdwBTZWxlY3RlZExpc3RWaWV3SXRlbUNvbGxlY3Rpb24AZ2V0X1NlbGVjdGVkSXRlbXMAZ2V0X1RhZwBEYXRlVGltZQBnZXRfTm93AGdldF9HZW5lcmljU2Fuc1NlcmlmAGdkaTMyLmRsbAA8PmNfX0Rpc3BsYXlDbGFzczkxAHRhYkJ0bnMAPC5jdG9yPmJfXzdhADwuY3Rvcj5iX183YgA8LmN0b3I+Yl9fN2QAPC5jdG9yPmJfXzdlADwuY3Rvcj5iX184MAA8PmNfX0Rpc3BsYXlDbGFzczkzAENTJDw+OF9fbG9jYWxzOTIAPC5jdG9yPmJfXzgyADwuY3Rvcj5iX183OQA8LmN0b3I+Yl9fN2MAPC5jdG9yPmJfXzdmADwuY3Rvcj5iX184MQA8LmN0b3I+Yl9fODMAczIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZThjADwuY3Rvcj5iX184NAA8LmN0b3I+Yl9fODUAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZThlADwuY3Rvcj5iX184NgA8LmN0b3I+Yl9fODcASW52YWxpZGF0ZQBzZXRfQ2FwdHVyZQBSZW1vdmVNZXNzYWdlRmlsdGVyAHNldF9XaWR0aABhZGRfTW91c2VNb3ZlAGFkZF9Nb3VzZVVwAFRleHRCb3hCYXNlAHNldF9NdWx0aWxpbmUAc2V0X1JlYWRPbmx5AFNjcm9sbEJhcnMAc2V0X1Njcm9sbEJhcnMAQWRkTWVzc2FnZUZpbHRlcgBGb3JtQ2xvc2VkRXZlbnRIYW5kbGVyAGFkZF9Gb3JtQ2xvc2VkAFBvaW50VG9DbGllbnQAZ2V0X1Zpc2libGUAZ2V0X0JvdW5kcwBTeXN0ZW0uV2luZG93cy5Gb3Jtcy5MYXlvdXQAQXJyYW5nZWRFbGVtZW50Q29sbGVjdGlvbgBnZXRfVG9wAHNldF9Ub3AAZ2V0X0ZvbnQAVGV4dFJlbmRlcmVyAE1lYXN1cmVUZXh0AGdldF9DbGllbnRTaXplADw+Y19fRGlzcGxheUNsYXNzOTcAPExvZz5iX185NQBnZXRfSW52b2tlUmVxdWlyZWQAQXBwZW5kVGV4dAA8PmNfX0Rpc3BsYXlDbGFzczliAGJ0bgA8UnVuQWN0aW9uPmJfXzk5ADxSdW5BY3Rpb24+Yl9fOWEAc2V0X0RvdWJsZUJ1ZmZlcmVkAFRvSW50NjQAZ2V0X1BhcmVudABnZXRfQmFja0NvbG9yAGdldF9DbGllbnRSZWN0YW5nbGUARmlsbFJlY3RhbmdsZQBnZXRfRW5hYmxlZABnZXRfVGV4dABEcmF3U3RyaW5nADw+Y19fRGlzcGxheUNsYXNzYjQAPC5jdG9yPmJfX2E1ADwuY3Rvcj5iX19hNgA8LmN0b3I+Yl9fYTgAPC5jdG9yPmJfX2E5ADwuY3Rvcj5iX19hYgA8PmNfX0Rpc3BsYXlDbGFzc2I2AENTJDw+OF9fbG9jYWxzYjUAPC5jdG9yPmJfX2FkADwuY3Rvcj5iX19hNAA8LmN0b3I+Yl9fYTcAPC5jdG9yPmJfX2FhADwuY3Rvcj5iX19hYwA8LmN0b3I+Yl9fYWUAPD5jX19EaXNwbGF5Q2xhc3NjMgA8PmNfX0Rpc3BsYXlDbGFzc2M0AGNudABjYW5jZWwAPEJ1aWxkUGluZ1RhYj5iX19iYwA8QnVpbGRQaW5nVGFiPmJfX2JmADxCdWlsZFBpbmdUYWI+Yl9fYzAAPEJ1aWxkUGluZ1RhYj5iX19jMQBDUyQ8PjhfX2xvY2Fsc2MzAHN6ADxCdWlsZFBpbmdUYWI+Yl9fYmQAPEJ1aWxkUGluZ1RhYj5iX19iZQBEb3VibGUAQm9vbGVhbgA8PmNfX0Rpc3BsYXlDbGFzc2NjADxCdWlsZFRyYWNlcnRUYWI+Yl9fYzcAPEJ1aWxkVHJhY2VydFRhYj5iX19jYQA8QnVpbGRUcmFjZXJ0VGFiPmJfX2NiADxCdWlsZFRyYWNlcnRUYWI+Yl9fYzgAPEJ1aWxkVHJhY2VydFRhYj5iX19jOQA8PmNfX0Rpc3BsYXlDbGFzc2Q2ADw+Y19fRGlzcGxheUNsYXNzZGEAdHlwZXMAdG9nZ2xlcwA8QnVpbGREbnNUYWI+Yl9fZDEAPEJ1aWxkRG5zVGFiPmJfX2Q0ADxCdWlsZERuc1RhYj5iX19kNQBDUyQ8PjhfX2xvY2Fsc2Q3AG5tAHN2AHRwADxCdWlsZERuc1RhYj5iX19kMgA8QnVpbGREbnNUYWI+Yl9fZDMAPD5jX19EaXNwbGF5Q2xhc3NkOAB0aQA8QnVpbGREbnNUYWI+Yl9fZDAAPD5jX19EaXNwbGF5Q2xhc3NlNAA8PmNfX0Rpc3BsYXlDbGFzc2U2AGdvADxCdWlsZEh0dHBUYWI+Yl9fZGQAPEJ1aWxkSHR0cFRhYj5iX19lMAA8QnVpbGRIdHRwVGFiPmJfX2UxADxCdWlsZEh0dHBUYWI+Yl9fZTIAPEJ1aWxkSHR0cFRhYj5iX19lMwBDUyQ8PjhfX2xvY2Fsc2U1AHUAPEJ1aWxkSHR0cFRhYj5iX19kZQA8QnVpbGRIdHRwVGFiPmJfX2RmAHNldF9TdXBwcmVzc0tleVByZXNzADw+Y19fRGlzcGxheUNsYXNzZjEAPD5jX19EaXNwbGF5Q2xhc3NmMwA8PmNfX0Rpc3BsYXlDbGFzc2Y2AHNjYW4APEJ1aWxkUG9ydFRhYj5iX19lOQA8QnVpbGRQb3J0VGFiPmJfX2VjADxCdWlsZFBvcnRUYWI+Yl9fZWYAPEJ1aWxkUG9ydFRhYj5iX19mMABDUyQ8PjhfX2xvY2Fsc2YyADxCdWlsZFBvcnRUYWI+Yl9fZWEAPEJ1aWxkUG9ydFRhYj5iX19lYgBwb3J0cwA8QnVpbGRQb3J0VGFiPmJfX2VkADxCdWlsZFBvcnRUYWI+Yl9fZWUAX19TdGF0aWNBcnJheUluaXRUeXBlU2l6ZT01MgAkJG1ldGhvZDB4NjAwMDE1MC0xADw+Y19fRGlzcGxheUNsYXNzMTAyAG1rAGlwMQBpcDIAPEJ1aWxkU3VibmV0VGFiPmJfX2ZlADxCdWlsZFN1Ym5ldFRhYj5iX19mZgA8QnVpbGRTdWJuZXRUYWI+Yl9fMTAwADxCdWlsZFN1Ym5ldFRhYj5iX18xMDEAYWRkX1RleHRDaGFuZ2VkADw+Y19fRGlzcGxheUNsYXNzMTA5ADw+Y19fRGlzcGxheUNsYXNzMTBjAHJlZnJlc2gAPEJ1aWxkTG9jYWxUYWI+Yl9fMTA0ADxCdWlsZExvY2FsVGFiPmJfXzEwNwA8QnVpbGRMb2NhbFRhYj5iX18xMDgAPEJ1aWxkTG9jYWxUYWI+Yl9fMTA1AENTJDw+OF9fbG9jYWxzMTBhAGluZm8APEJ1aWxkTG9jYWxUYWI+Yl9fMTA2AENsaXBib2FyZABTZXRUZXh0ADwuY3Rvcj5iX18xMTAAPC5jdG9yPmJfXzExMQA8LmN0b3I+Yl9fMTEyAEZvY3VzAGdldF9JQmVhbQBhZGRfRW50ZXIAYWRkX0xlYXZlAGdldF9Gb2N1c2VkADwuY3Rvcj5iX18xMTkAPC5jdG9yPmJfXzExYQA8LmN0b3I+Yl9fMTFiADwuY3Rvcj5iX18xMWMAPC5jdG9yPmJfXzExZAA8LmN0b3I+Yl9fMTFlAFN0b3AAQ29tcG9uZW50AHNldF9JbnRlcnZhbABhZGRfVGljawBhZGRfRGlzcG9zZWQAPD5jX19EaXNwbGF5Q2xhc3MxMjcAPExpbmU+Yl9fMTI1AFNhdmVGaWxlRGlhbG9nAEZpbGVEaWFsb2cAc2V0X0ZpbHRlcgBDb21tb25EaWFsb2cAU2hvd0RpYWxvZwBnZXRfRmlsZU5hbWUAPC5jdG9yPmJfXzEyZgA8LmN0b3I+Yl9fMTMwADwuY3Rvcj5iX18xMzEAPC5jdG9yPmJfXzEzMgA8LmN0b3I+Yl9fMTMzAHNldF9JbnRlZ3JhbEhlaWdodABzZXRfSGVpZ2h0AEJ1dHRvbgBMaXN0Q29udHJvbABnZXRfU2VsZWN0ZWRJbmRleABPYmplY3RDb2xsZWN0aW9uAEdldFRleHQAPD5jX19EaXNwbGF5Q2xhc3MxNWMAPC5jdG9yPmJfXzE0NQA8LmN0b3I+Yl9fMTQ2ADwuY3Rvcj5iX18xNDcAPC5jdG9yPmJfXzE0OAA8PmNfX0Rpc3BsYXlDbGFzczE1ZQBDUyQ8PjhfX2xvY2FsczE1ZABjaQA8LmN0b3I+Yl9fMTRhADwuY3Rvcj5iX18xNGIAPC5jdG9yPmJfXzE0NAA8LmN0b3I+Yl9fMTQ5ADwuY3Rvcj5iX18xNGMAPC5jdG9yPmJfXzE0ZAA8LmN0b3I+Yl9fMTRlADwuY3Rvcj5iX18xNGYAPC5jdG9yPmJfXzE1MABGb3JtQ2xvc2luZ0V2ZW50QXJncwA8LmN0b3I+Yl9fMTUxADwuY3Rvcj5iX18xNTIARHJhd0VsbGlwc2UAQWRkRWxsaXBzZQBSZWdpb24Ac2V0X1JlZ2lvbgBGb3JtQ2xvc2luZ0V2ZW50SGFuZGxlcgBhZGRfRm9ybUNsb3NpbmcAU29ydGVkRGljdGlvbmFyeWAyAEdldEZpbGVOYW1lV2l0aG91dEV4dGVuc2lvbgBzZXRfU2VsZWN0aW9uU3RhcnQAUmVhZExpbmUAPD5jX19EaXNwbGF5Q2xhc3MxNjUAPFJlYnVpbGRUYWJzPmJfXzE2MgA8UmVidWlsZFRhYnM+Yl9fMTYzAGFkZF9Nb3VzZUNsaWNrAE1vdmUAU3RyaW5nVHJpbW1pbmcAc2V0X1RyaW1taW5nAFN0cmluZ0Zvcm1hdEZsYWdzAHNldF9Gb3JtYXRGbGFncwA8LmN0b3I+Yl9fMTZkADwuY3Rvcj5iX18xNmUAPC5jdG9yPmJfXzE2ZgA8LmN0b3I+Yl9fMTcwAE1hcnNoYWwAUHRyVG9TdHJ1Y3R1cmUAQ29weUZyb21TY3JlZW4AR2V0UGl4ZWwAU3RydWN0TGF5b3V0QXR0cmlidXRlAExheW91dEtpbmQAAAAAJU0AaQBjAHIAbwBzAG8AZgB0ACAAWQBhAEgAZQBpACAAVQBJAAAJYwB0AHIAbAAAD2MAbwBuAHQAcgBvAGwAAAdhAGwAdAAAC3MAaABpAGYAdAAAB3cAaQBuAAAHYwBtAGQAAAltAGUAdABhAAAFZgAxAAAFZgAyAAAFZgAzAAAFZgA0AAAFZgA1AAAFZgA2AAAFZgA3AAAFZgA4AAAFZgA5AAAHZgAxADAAAAdmADEAMQAAB2YAMQAyAAALcwBwAGEAYwBlAAALZQBuAHQAZQByAAAHZQBzAGMAABNiAGEAYwBrAHMAcABhAGMAZQAAB3QAYQBiAAALZwByAGEAdgBlAAALbQBpAG4AdQBzAAAJcABsAHUAcwAAEWwAYgByAGEAYwBrAGUAdAAAEXIAYgByAGEAYwBrAGUAdAAAE3MAZQBtAGkAYwBvAGwAbwBuAAALcQB1AG8AdABlAAALYwBvAG0AbQBhAAANcABlAHIAaQBvAGQAAAtzAGwAYQBzAGgAABNiAGEAYwBrAHMAbABhAHMAaAAACXAAZwB1AHAAAAlwAGcAZABuAAAJaABvAG0AZQAAB2UAbgBkAAAJbABlAGYAdAAAC3IAaQBnAGgAdAAABXUAcAAACWQAbwB3AG4AAAsoACpnvotufykAAQ0oAG4AbwBuAGUAKQAAC0MAdAByAGwAKwAACUEAbAB0ACsAAA1TAGgAaQBmAHQAKwAACVcAaQBuACsAAAtTAHAAYQBjAGUAAAtFAG4AdABlAHIAAAdFAHMAYwAAE0IAYQBjAGsAcwBwAGEAYwBlAAAHVABhAGIAAANgAAADLQABAz0AAANbAAADXQAAAzsAAAMnAAEDLAAAAy4AAAMvAAADXAAACVAAZwBVAHAAAAlQAGcARABuAAAJSABvAG0AZQAAB0UAbgBkAAAJTABlAGYAdAAAC1IAaQBnAGgAdAAABVUAcAAACUQAbwB3AG4AAAUwAHgAAANYAAANaQB0AG8AbwBsAHMAAA9wAGwAdQBnAGkAbgBzAACD4zsAIABXAGcAVAByAGEAeQAgAE2Rbn+HZfZOIAAoAFUAVABGAC0AOAAsACAADk4gAHcAZwB0AHIAYQB5AC4AYgBhAHQAIAAMVO52VV8pAA0ACgA7ACAAYQBwAHAAOgAgAFhi2Hbcg1VTIAAtAD4AIACUXih1IADMkYR2YWfudiwAIAAWfwF4PABUAEEAQgA+AA1U8Hk8AFQAQQBCAD4AfVTkTlsAPABUAEEAQgA+AMJTcGVdACAAKAAGUpSWJntfTqVj11N6ejxoLAAgACtUeno8aIR2fVTkTih1FV/3UwVTT087AA0ACgA7ACAAIAAgACAAIAAgAPh2+VvvjYRfCWMgAHcAZwB0AHIAYQB5AC4AYgBhAHQAIABAYihX7nZVX+OJkGcsACAAL2UBYyAAJQCvc4NY2FPPkSUAKQANAAoAOwAgAGEAcABwACAAPQAgAG4AcAAJALCLi04sZwkAbgBvAHQAZQBwAGEAZAAuAGUAeABlAA0ACgA7ACAAYQBwAHAAIAA9ACAAZwB5AAkA006TXu52VV8JAEMAOgBcAFQAbwBvAGwAcwBcAFcAZwBJAG0AZQANAAoAOwAgAGEAcABwACAAPQAgAGIAZAAJAH52pl4JAGgAdAB0AHAAcwA6AC8ALwB3AHcAdwAuAGIAYQBpAGQAdQAuAGMAbwBtAA0ACgA7ACAAaFFAXOtfd2MulSAAKAA8aA9fOgAgAGMAdAByAGwALwBhAGwAdAAvAHMAaABpAGYAdAAvAHcAaQBuACAAxH4IVCwAIACCWSAAYwB0AHIAbAArAGEAbAB0ACsAdAA7ACAAbgBvAG4AZQAvAG8AZgBmACAAgXkodSkAOgANAAoAOwAgAGgAbwB0AGsAZQB5AF8AdABvAG8AbABiAG8AeAAgAD0AIABjAHQAcgBsACsAYQBsAHQAKwB0ACAAIAAgAFNiAF/lXXdRsXsNAAoAOwAgAGgAbwB0AGsAZQB5AF8AcABsAHUAZwBpAG4AcwAgAD0AIABjAHQAcgBsACsAYQBsAHQAKwBwACAAIAAgAFNiAF/SY/ZOoXsGdA0ACgA7ACAAaABvAHQAawBlAHkAXwBtAGUAbgB1ACAAIAAgACAAPQAgAGMAdAByAGwAKwBhAGwAdAArAHcAIAAgACAAKFdJUQdoBFk+Zjp5WGLYdtyDVVMNAAoAOwAgACgAVwBnAEkAbQBlACAAhHYgAGYAdQB6AHoAeQAvAHAAYQBzAHQAZQAvAGsAZQB5AGYAaQB4ACAASXuTj2VR1WxNkW5/LGflXXdRDU5/Tyh1LAAgAFl1QHcNTnFfzVQpAA0ACgABB+Vdd1GxewEPVABvAG8AbABiAG8AeAAAG2IAdQBpAGwAdABpAG4AOgB0AG8AbwBsAHMAAAEAC3QAbwBvAGwAcwAAB24AZQB0AAAJUX/cfuVdd1EBG04AZQB0AHcAbwByAGsAIAB0AG8AbwBsAHMAACFiAHUAaQBsAHQAaQBuADoAbgBlAHQAdABvAG8AbABzAAAJdwBsAGcAagAACWMAbABpAHAAAAtqUjSNf2eGU/JTASNDAGwAaQBwAGIAbwBhAHIAZAAgAGgAaQBzAHQAbwByAHkAABliAHUAaQBsAHQAaQBuADoAYwBsAGkAcAAAB2oAbABiAAAFYgBqAAAFv09+ewEZUwB0AGkAYwBrAHkAIABuAG8AdABlAHMAABliAHUAaQBsAHQAaQBuADoAbgBvAHQAZQAAC24AbwB0AGUAcwAABXkAcwAACZyYcoL+YtZTARlDAG8AbABvAHIAIABwAGkAYwBrAGUAcgAAG2IAdQBpAGwAdABpAG4AOgBjAG8AbABvAHIAAAtjAG8AbABvAHIAAAnSY/ZOoXsGdAEdUABsAHUAZwBpAG4AIABtAGEAbgBhAGcAZQByAAAjYgB1AGkAbAB0AGkAbgA6AHAAbAB1AGcAaQBuAG0AZwByAAAJYwBqAGcAbAAAFWMAdAByAGwAKwBhAGwAdAArAHQAABVjAHQAcgBsACsAYQBsAHQAKwBwAAAVYwB0AHIAbAArAGEAbAB0ACsAdwAAFWMAbwBuAGYAaQBnAC4AdAB4AHQAAAdhAHAAcAAAX14AKABcAFMAKwApAFwAcwArACgAXABTACsAKQBcAHMAKwAoACIAKAA/ADoAWwBeACIAXQAqACkAIgB8AFwAUwArACkAKAA/ADoAXABzACsAKAAuACoAKQApAD8AJAAAHWgAbwB0AGsAZQB5AF8AdABvAG8AbABiAG8AeAAAHWgAbwB0AGsAZQB5AF8AcABsAHUAZwBpAG4AcwAAF2gAbwB0AGsAZQB5AF8AbQBlAG4AdQAAB2oAcwBxAAAJYwBhAGwAYwAACeVdd1GxeyYgARFUAG8AbwBsAGIAbwB4ACYgAQXSY/ZOAQ9QAGwAdQBnAGkAbgBzAAAJhVFuf+Vdd1EBHUIAdQBpAGwAdAAtAGkAbgAgAHQAbwBvAGwAcwABB6GLl3toVgEVQwBhAGwAYwB1AGwAYQB0AG8AcgAAH5ReKHUgACgAYwBvAG4AZgBpAGcALgB0AHgAdAApAAEjQQBwAHAAcwAgACgAYwBvAG4AZgBpAGcALgB0AHgAdAApAAAFTZFufwENQwBvAG4AZgBpAGcAACUWf5GPTZFufyAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAJiABM0UAZABpAHQAIABjAG8AbgBmAGkAZwAgACgAYwBvAG4AZgBpAGcALgB0AHgAdAApACYgAQnNkX2PTZFufwEbUgBlAGwAbwBhAGQAIABjAG8AbgBmAGkAZwAAC3BlbmPudlVfJiABGUQAYQB0AGEAIABmAG8AbABkAGUAcgAmIAELaFFAXOtfd2MulQEdRwBsAG8AYgBhAGwAIABoAG8AdABrAGUAeQBzAABLKFcgAGMAbwBuAGYAaQBnAC4AdAB4AHQAIACEdiAAaABvAHQAawBlAHkAXwAqACAALpXuTzllIAAoAG4AbwBuAGUAIACBeSh1KQABZWUAZABpAHQAIABoAG8AdABrAGUAeQBfACoAIABrAGUAeQBzACAAaQBuACAAYwBvAG4AZgBpAGcALgB0AHgAdAAgACgAbgBvAG4AZQAgAHQAbwAgAGQAaQBzAGEAYgBsAGUAKQAABQCQ+lEBCUUAeABpAHQAAAtTYgBf5V13UbF7ARlPAHAAZQBuACAAdABvAG8AbABiAG8AeAAABzoAIAAgAAANPmY6eVhi2Hbcg1VTAR1TAGgAbwB3ACAAdAByAGEAeQAgAG0AZQBuAHUAAA9wAGwAdQBnAGkAbgA6AAAXYwBvAGQAZQBwAGwAdQBnAGkAbgA6AAAHIAAgACgAAAMpAAAvKADgZdJj9k4gABQgIAA+ZSAAcABsAHUAZwBpAG4AcwBcACoALgB0AHgAdAApAAFBKABuAG8AIABwAGwAdQBnAGkAbgBzACAAFCAgAHAAdQB0ACAAcABsAHUAZwBpAG4AcwBcACoALgB0AHgAdAApAAEL0mP2TqF7BnQmIAEfUABsAHUAZwBpAG4AIABtAGEAbgBhAGcAZQByACYgARFiAHUAaQBsAHQAaQBuADoAAEUoAOBlIAAUICAAYwBvAG4AZgBpAGcALgB0AHgAdAAgAMyRoFIgAGEAcABwACAAPQAgABZ/AXggAA1U8HkgAH1U5E4pAAFpKABuAG8AbgBlACAAFCAgAGEAZABkACAAJwBhAHAAcAAgAD0AIABjAG8AZABlACAAbgBhAG0AZQAgAGMAbwBtAG0AYQBuAGQAJwAgAGkAbgAgAGMAbwBuAGYAaQBnAC4AdAB4AHQAKQABC3cAZwBpAG0AZQAAKVcAZwBUAHIAYQB5AFMAaQBuAGcAbABlAEkAbgBzAHQAYQBuAGMAZQAAM1cAZwBUAHIAYQB5ACAA8l0oV9CPTIggABQgIAD3i0hRzk5YYth2AJD6UedlnluLTwIwAYCNVwBnAFQAcgBhAHkAIABpAHMAIABhAGwAcgBlAGEAZAB5ACAAcgB1AG4AbgBpAG4AZwAgABQgIABlAHgAaQB0ACAAdABoAGUAIABvAGwAZAAgAGkAbgBzAHQAYQBuAGMAZQAgAGYAcgBvAG0AIAB0AGgAZQAgAHQAcgBhAHkAIABmAGkAcgBzAHQALgABDVcAZwBUAHIAYQB5AAAD5V0BA1QAAAVgAG4AAAt0AG8AbwBsADoAAAc6AC8ALwAACS9UqFIxWSWNARtMAGEAdQBuAGMAaAAgAGYAYQBpAGwAZQBkAAAFOgAgAAAVcwBoAGUAbABsAGIAbABvAGMAawAAD3AAcwBiAGwAbwBjAGsAABdzAGgAZQBsAGwAYgBsAG8AYwBrAHgAABFwAHMAYgBsAG8AYwBrAHgAAAthAGIAbwByAHQAAAmMWxBiLAAgAAETLQAtACAAZABvAG4AZQAsACAAARMgACpOZWukmjFZJY0gAC0ALQABJSAAcwB0AGUAcAAoAHMAKQAgAGYAYQBpAGwAZQBkACAALQAtAAEFjFsQYgEVLQAtACAAZABvAG4AZQAgAC0ALQABB/Jd1lOIbQEbLQAtACAAYQBiAG8AcgB0AGUAZAAgAC0ALQABByAAfAAgAAAF5V13UQEJVABvAG8AbAAAM24AbwAgAHQAbwBvAGwAIABhAGMAdABpAG8AbgAgAGYAbwByACAAYwBvAGQAZQA6ACAAABN0AG8AbwBsAHMALgB0AHgAdAAAAwoAAA9bAHMAaABlAGwAbABdAAALWwBjAG0AZABdAAAZWwBwAG8AdwBlAHIAcwBoAGUAbABsAF0AAAlbAHAAcwBdAAAbWwAvAHAAbwB3AGUAcgBzAGgAZQBsAGwAXQAAC1sALwBwAHMAXQAAEVsAcwBoAGUAbABsAHgAXQAADVsAYwBtAGQAeABdAAAbWwBwAG8AdwBlAHIAcwBoAGUAbABsAHgAXQAAC1sAcABzAHgAXQAACXQAYQBiACAAAAM/AAALYwBvAGwAcwAgAAALVABvAG8AbABzAAAPYgB1AHQAdABvAG4AIAAACWMAbwBkAGUAAAflXXdROgABCUgASwBDAFUAACNIAEsARQBZAF8AQwBVAFIAUgBFAE4AVABfAFUAUwBFAFIAAAlIAEsATABNAAAlSABLAEUAWQBfAEwATwBDAEEATABfAE0AQQBDAEgASQBOAEUAAAlIAEsAQwBSAAAjSABLAEUAWQBfAEMATABBAFMAUwBFAFMAXwBSAE8ATwBUAAAHSABLAFUAABVIAEsARQBZAF8AVQBTAEUAUgBTAAAJSABLAEMAQwAAJ0gASwBFAFkAXwBDAFUAUgBSAEUATgBUAF8AQwBPAE4ARgBJAEcAABViAGEAZAAgAGgAaQB2AGUAOgAgAAAPIAAgAG8AdQB0ADoAIAAADyAAIABlAHgAaQB0ACAAABVlAHgAaQB0ACAAYwBvAGQAZQAgAAAXdwBnAGkAbQBlAC0AdABvAG8AbAAtAAEDTgAAAyIAAAdtAHMAZwAAD2MAbwBuAGYAaQByAG0AAAt0AGkAdABsAGUAAA9iAHUAdAB0AG8AbgBzAAAFbwBrAAARbwBrAGMAYQBuAGMAZQBsAAAPZABlAGYAYQB1AGwAdAAAAzEAAAl3AGEAaQB0AAAJawBpAGwAbAAAEyAAIABrAGkAbABsAGUAZAAgAAAHIAB4ACAAAAdyAHUAbgAAC3MAaABlAGwAbAAAD2MAbQBkAC4AZQB4AGUAAAcvAGMAIAAACS4AYwBtAGQAAAkuAHAAcwAxAAAdcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlAABTLQBOAG8AUAByAG8AZgBpAGwAZQAgAC0ARQB4AGUAYwB1AHQAaQBvAG4AUABvAGwAaQBjAHkAIABCAHkAcABhAHMAcwAgAC0ARgBpAGwAZQAgAAFnWwBDAG8AbgBzAG8AbABlAF0AOgA6AE8AdQB0AHAAdQB0AEUAbgBjAG8AZABpAG4AZwAgAD0AIABbAFQAZQB4AHQALgBFAG4AYwBvAGQAaQBuAGcAXQA6ADoAVQBUAEYAOAANAAoAAA1zAGgAZQBsAGwAeAAAIQ0ACgBlAGMAaABvAC4ADQAKAHAAYQB1AHMAZQANAAoAAGcNAAoAVwByAGkAdABlAC0ASABvAHMAdAAgACcAJwANAAoAUgBlAGEAZAAtAEgAbwBzAHQAIAAnAHAAcgBlAHMAcwAgAEUATgBUAEUAUgAgAHQAbwAgAGMAbABvAHMAZQAnAA0ACgABCW8AcABlAG4AAA9yAGUAZwAtAHMAZQB0AAEDIAAAC2QAdwBvAHIAZAAAC3EAdwBvAHIAZAAADWUAeABwAGEAbgBkAAALbQB1AGwAdABpAAANYgBpAG4AYQByAHkAAA9yAGUAZwAtAGQAZQBsAAERZgBpAGwAZQAtAGQAZQBsAAE/cgBlAGYAdQBzAGUAIAB0AG8AIABkAGUAbABlAHQAZQAgAGEAIABkAHIAaQB2AGUAIAByAG8AbwB0ADoAIAAAESAAIABzAGsAaQBwADoAIAAAFSAAIABkAGUAbABlAHQAZQBkACAAABUsACAAcwBrAGkAcABwAGUAZAAgAAAlIAAoAGkAbgAgAHUAcwBlACAALwAgAGwAbwBjAGsAZQBkACkAAAttAGsAZABpAHIAAB11AG4AawBuAG8AdwBuACAAdgBlAHIAYgA6ACAAAFV0AG8AbwBsAHMALgB0AHgAdAAgADpOenoWYg1OWFsoVxQgFCAoVyAAdwBnAGkAbQBlAC4AYgBhAHQAIAAMVO52VV/6XgBOKk5zU+9T+22gUp9S/YABa3QAbwBvAGwAcwAuAHQAeAB0ACAAbQBpAHMAcwBpAG4AZwAvAGUAbQBwAHQAeQAgAC0AIABjAHIAZQBhAHQAZQAgAGkAdAAgAG4AZQB4AHQAIAB0AG8AIAB3AGcAaQBtAGUALgBiAGEAdAABWXIAZQBwAGwAeQAgAGYAcgBvAG0AIAB7ADAAfQA6ACAAdABpAG0AZQA9AHsAMQB9AG0AcwAgAHQAdABsAD0AewAyAH0AIABiAHkAdABlAHMAPQB7ADMAfQAAEXMAdABhAHQAdQBzADoAIAAAD2UAcgByAG8AcgA6ACAAAAUgACAAABVtAHMAIAAgACgAZABvAG4AZQApAAAFbQBzAAATIAAgAGUAcgByAG8AcgA6ACAAACFjAGwAbwBzAGUAZAAgACgAdABpAG0AZQBvAHUAdAAgAAAHbQBzACkAAA1vAHAAZQBuACAAIAAAEWMAbABvAHMAZQBkACAAKAAAE0kAUAB2ADQAIABvAG4AbAB5AAALqWMBeA1O3o/tfgEnbgBvAG4ALQBjAG8AbgB0AGkAZwB1AG8AdQBzACAAbQBhAHMAawABFWIAYQBkACAAcAByAGUAZgBpAHgAAAsqZwdjmlswV0BXARd1AG4AcwBwAGUAYwBpAGYAaQBlAGQAAB/eVq9zMFdAVyAAKABsAG8AbwBwAGIAYQBjAGsAKQABEWwAbwBvAHAAYgBhAGMAawAAHcF5CWcwV0BXIAAoAFIARgBDADEAOQAxADgAKQABI3AAcgBpAHYAYQB0AGUAIAAoAFIARgBDADEAOQAxADgAKQAAGf6U740sZzBXIAAoAEEAUABJAFAAQQApAAElbABpAG4AawAtAGwAbwBjAGEAbAAgACgAQQBQAEkAUABBACkAASHQjyWERlWnfiAATgBBAFQAIAAoAEMARwBOAEEAVAApAAEjYwBhAHIAcgBpAGUAcgAtAGcAcgBhAGQAZQAgAE4AQQBUAAEdxH6tZCAAKABtAHUAbAB0AGkAYwBhAHMAdAApAAETbQB1AGwAdABpAGMAYQBzAHQAABvdT1l1IAAoAHIAZQBzAGUAcgB2AGUAZAApAAERcgBlAHMAZQByAHYAZQBkAAAJbFFRfzBXQFcBDXAAdQBiAGwAaQBjAAADQQAAA0IAAANDAAADRAAAA0UAAAWpYwF4AQlNAGEAcwBrAAATOgAgACAAIAAgACAAIAAgACAAAAkgACAAKAAvAAAHGpBNkSZ7ARFXAGkAbABkAGMAYQByAGQAAAs6ACAAIAAgACAAAAlRf9x+MFdAVwEPTgBlAHQAdwBvAHIAawAACToAIAAgACAAAAl/Xq1kMFdAVwETQgByAG8AYQBkAGMAYQBzAHQAAAnvUyh1A4P0VgEVSABvAHMAdAAgAHIAYQBuAGcAZQAAByAALQAgAAEL71ModTtOOmdwZQELSABvAHMAdABzAAANOgAgACAAIAAgACAAAAkwV0BXe3yLVwEJVAB5AHAAZQAADzoAIAAgACAAIAAgACAAAAV7fCtSAQtDAGwAYQBzAHMAAAeMTtuPNlIBDUIAaQBuAGEAcgB5AAAbxmKXXypZjniGTiAAKAA7TjpncGUNTrONKQABQXQAbwBvACAAbQBhAG4AeQAgAHMAdQBiAG4AZQB0AHMAIAAoAG4AbwAgAGgAbwBzAHQAcwAgAGwAZQBmAHQAKQAABcZiBlIBC3MAcABsAGkAdAAAByAAOk4gAAENIABpAG4AdABvACAAAAkgACpOIAAvAAEJIAB4ACAALwAAAzoAAAcgACAAIAAACSAAIAAgACgAAEVNUgB/IAAgACAAIACpYwF4IAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAO9TKHU7TjpnIAAgACAAIAAgABqQTZEmewFbcAByAGUAZgBpAHgAIAAgAG0AYQBzAGsAIAAgACAAIAAgACAAIAAgACAAIAAgACAAaABvAHMAdABzACAAIAAgACAAIAAgACAAIAB3AGkAbABkAGMAYQByAGQAAAc7TjpnDVQBCUgAbwBzAHQAAAVdACAAABEgACAASQBQAHYANAA6ACAAAAcgAC8AIAAABVF/c1EBD0cAYQB0AGUAdwBhAHkAAA8gACAARABOAFMAOgAgAAAFTgBTAAALQwBOAEEATQBFAAAHUABUAFIAAAVNAFgAAAdUAFgAVAAACUEAQQBBAEEAABFiAGEAZAAgAHQAeQBwAGUAABVEAE4AUwAgAHIAYwBvAGQAZQA9AAAXIAAoAE4AWABEAE8ATQBBAEkATgApAAALdAB5AHAAZQAgAAAFIAAoAAAPIABiAHkAdABlAHMAKQAADyAAIAAgAHQAdABsAD0AAAfgZbCLVV8BFW4AbwAgAHIAZQBjAG8AcgBkAHMAABtkAG4AcwAgAG4AYQBtAGUAIABsAG8AbwBwAAARaAB0AHQAcABzADoALwAvAAAdVwBnAEkAbQBlAC0ATgBlAHQAVABvAG8AbABzAAENIAAgACgALQA+ACAAAQtIAFQAVABQACAAAA1TAGUAcgB2AGUAcgAAEVMAZQByAHYAZQByADoAIAAAHUMAbwBuAHQAZQBuAHQALQBUAHkAcABlADoAIAABDUIAbwBkAHkAOgAgAAANIABiAHkAdABlAHMAAA1UAFQARgBCADoAIAAAGW0AcwAgACAAIABUAG8AdABhAGwAOgAgAAALRQByAHIAOgAgAAAraAB0AHQAcABzADoALwAvAGEAcABpAC4AaQBwAGkAZgB5AC4AbwByAGcAABNuAG8AdABlAHMALgB0AHgAdAAAAyMAAAVYADIAAAVIACAAAAkgACAAUwAgAAALJQAgACAAVgAgAAADJQAABVsALwAACyoALgB0AHgAdAAAQV4AKABjAG8AZABlAHwAbgBhAG0AZQB8AGQAZQBzAGMAKQBcAHMAKgBbAD0AOgBdAFwAcwAqACgALgArACkAJAAACW4AYQBtAGUAAA1jAHMAaABhAHIAcAAAKXAAbAB1AGcAaQBuAHMALQBkAGkAcwBhAGIAbABlAGQALgB0AHgAdAABDWQAbwBuAGUALAAgAAANIAAqTmVrpJoxWSWNAR8gAHMAdABlAHAAKABzACkAIABmAGEAaQBsAGUAZAAACWdiTIiMWxBiAQlkAG8AbgBlAAAPYQBiAG8AcgB0AGUAZAAACwBfy1lnYkyIJiABEXIAdQBuAG4AaQBuAGcAJiABF1cAaQBuAGQAbwB3AHMAQgBhAHMAZQAAIVAAcgBlAHMAZQBuAHQAYQB0AGkAbwBuAEMAbwByAGUAACtQAHIAZQBzAGUAbgB0AGEAdABpAG8AbgBGAHIAYQBtAGUAdwBvAHIAawAAgIcsACAAVgBlAHIAcwBpAG8AbgA9ADQALgAwAC4AMAAuADAALAAgAEMAdQBsAHQAdQByAGUAPQBuAGUAdQB0AHIAYQBsACwAIABQAHUAYgBsAGkAYwBLAGUAeQBUAG8AawBlAG4APQAzADEAYgBmADMAOAA1ADYAYQBkADMANgA0AGUAMwA1AACAnVMAeQBzAHQAZQBtAC4AWABhAG0AbAAsACAAVgBlAHIAcwBpAG8AbgA9ADQALgAwAC4AMAAuADAALAAgAEMAdQBsAHQAdQByAGUAPQBuAGUAdQB0AHIAYQBsACwAIABQAHUAYgBsAGkAYwBLAGUAeQBUAG8AawBlAG4APQBiADcANwBhADUAYwA1ADYAMQA5ADMANABlADAAOAA5AAALbABpAG4AZQAgAAAFOwAgAAAHUgB1AG4AAF9uAG8AIAAnAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIAB2AG8AaQBkACAAUgB1AG4AKAApACcAIABlAG4AdAByAHkAIABwAG8AaQBuAHQAIABmAG8AdQBuAGQAAQ3SY/ZO0I9MiPpRGZUBGVAAbAB1AGcAaQBuACAAZQByAHIAbwByAAAN0mP2ThZ/0YsxWSWNAStQAGwAdQBnAGkAbgAgAGMAbwBtAHAAaQBsAGUAIABmAGEAaQBsAGUAZAAAG1cAZwBUAHIAYQB5AFAAbAB1AGcAaQBuAHMAAAV6AGgAABVTAHkAcwB0AGUAbQAuAGQAbABsAAAxUwB5AHMAdABlAG0ALgBXAGkAbgBkAG8AdwBzAC4ARgBvAHIAbQBzAC4AZABsAGwAACVTAHkAcwB0AGUAbQAuAEQAcgBhAHcAaQBuAGcALgBkAGwAbAAAH1MAeQBzAHQAZQBtAC4AQwBvAHIAZQAuAGQAbABsAAAfUwB5AHMAdABlAG0ALgBEAGEAdABhAC4AZABsAGwAAB3SY/ZOoXsGdCAAIAAoAFcAZwBUAHIAYQB5ACkAATFQAGwAdQBnAGkAbgAgAE0AYQBuAGEAZwBlAHIAIAAgACgAVwBnAFQAcgBhAHkAKQAAHVAAbAB1AGcAaQBuACAATQBhAG4AYQBnAGUAcgAAAxUnAQXQj0yIAQXNkX2PAQ1SAGUAbABvAGEAZAAACy9UKHUvAIF5KHUBDU8AbgAvAE8AZgBmAAAJU2IAX+52VV8BF08AcABlAG4AIABmAG8AbABkAGUAcgAABRZ/kY8BCUUAZABpAHQAAAcgUmSWJiABD0QAZQBsAGUAdABlACYgAQuwZfpeIWp/ZyYgAQlOAGUAdwAmIAEFDVTweQEJTgBhAG0AZQAABRZ/AXgBCUMAbwBkAGUAAAV7fItXAQUvVFxQAQtTAHQAYQB0AGUAAAW2cgFgAQ1TAHQAYQB0AHUAcwAABYdl9k4BCUYAaQBsAGUAABVSAEUAQQBEAE0ARQAuAHQAeAB0AAAFY2s4XgEFTwBLAAAJFn/RizFZJY0BG2MAbwBtAHAAaQBsAGUAIABlAHIAcgBvAHIAAAnjiZBnMVkljQEXcABhAHIAcwBlACAAZQByAHIAbwByAAAFIABlawENIABzAHQAZQBwAHMAAAVla6SaAQdEAFMATAAABUMAIwAABS9UKHUBD2UAbgBhAGIAbABlAGQAAAfyXYF5KHUBEWQAaQBzAGEAYgBsAGUAZAAAEfeLSFEJkC1OAE4qTtJj9k4BK1MAZQBsAGUAYwB0ACAAYQAgAHAAbAB1AGcAaQBuACAAZgBpAHIAcwB0AAAPIFJkltJj9k6HZfZOIAABJ0QAZQBsAGUAdABlACAAcABsAHUAZwBpAG4AIABmAGkAbABlACAAAAluAGUAdwAtAAENSABIAG0AbQBzAHMAAAkuAHQAeAB0AACA2zsAIABXAGcAVAByAGEAeQAgAHAAbAB1AGcAaQBuACAAKABzAHAAZQBjADoAIABkAG8AYwBzAC8AVwBHAEkATQBFAF8A0mP2TsSJA4MuAG0AZAApAA0ACgBjAG8AZABlACAAPQAgAG0AeQBjAG8AZABlAA0ACgBuAGEAbQBlACAAPQAgABFihHbSY/ZODQAKAGQAZQBzAGMAIAA9ACAADQAKAA0ACgBtAHMAZwAgAGgAZQBsAGwAbwAgAGYAcgBvAG0AIABtAHkAIABwAGwAdQBnAGkAbgANAAoAATNTAGUAZwBvAGUAIABVAEkAIABWAGEAcgBpAGEAYgBsAGUAIABEAGkAcwBwAGwAYQB5AAARUwBlAGcAbwBlACAAVQBJAAAb5V13UbF7IAAgACgAVwBnAFQAcgBhAHkAKQABI1QAbwBvAGwAYgBvAHgAIAAgACgAVwBnAFQAcgBhAHkAKQAAEUMAbwBuAHMAbwBsAGEAcwAAgP10AG8AbwBsAHMALgB0AHgAdAAgADpOenoWYg1OWFsoVwIwPGgPXzoAIABbAHQAYQBiACAAB2h+e3WYXQAgAC8AIABbAGMAbwBsAHMAIAAXUnBlXQAgAC8AIABbAAljrpQNVF0AIAAvACAAZWukmkyIIAAoAG0AcwBnACAAYwBvAG4AZgBpAHIAbQAgAHIAdQBuACAAcwBoAGUAbABsACAAbwBwAGUAbgAgAGsAaQBsAGwAIAB3AGEAaQB0ACAAcgBlAGcALQBzAGUAdAAgAHIAZQBnAC0AZABlAGwAIABmAGkAbABlAC0AZABlAGwAIABtAGsAZABpAHIAKQABPXQAbwBvAGwAcwAuAHQAeAB0ACAAaQBzACAAZQBtAHAAdAB5ACAAbwByACAAbQBpAHMAcwBpAG4AZwAuAAAFQQBnAAAFDQAKAAAVcABvAHcAZQByAHMAaABlAGwAbAAAB3AAcwB4AAAPXQAgABpZTIgagSxnV1cBJ10AIABtAHUAbAB0AGkALQBsAGkAbgBlACAAcwBjAHIAaQBwAHQAAQ8gACAAWwAxWSWNXQAgAAENIAAgAC0APgAgACAAAQ8gACAAWwBvAGsAXQAgAAAPLQAtACAAjFsQYiwAIAABES0ALQAgAIxbEGIgAC0ALQABEy0ALQAgAPJd1lOIbSAALQAtAAEHPQA9ACAAAAcgAD0APQAAHVF/3H7lXXdRIAAgACgAVwBnAFQAcgBhAHkAKQABL04AZQB0AHcAbwByAGsAIABUAG8AbwBsAHMAIAAgACgAVwBnAFQAcgBhAHkAKQAAG04AZQB0AHcAbwByAGsAIABUAG8AbwBsAHMAAAlQAGkAbgBnAAAPVAByAGEAYwBlAHIAdAAAB0QATgBTAAAJSABUAFQAUAAABe9641MBC1AAbwByAHQAcwAABVBbUX8BDVMAdQBiAG4AZQB0AAAFLGc6ZwELTABvAGMAYQBsAAARSABIADoAbQBtADoAcwBzAAAXcgBlAHAAbAB5ADoAIABzAGUAcQA9AAANIAB0AGkAbQBlAD0AABt0AGkAbQBlAG8AdQB0ADoAIABzAGUAcQA9AAAP336hizoAIADyXdFTIAABGXMAdABhAHQAcwA6ACAAcwBlAG4AdAAgAAAJIADyXTZlIAABDSAAcgBlAGMAdgAgAAAJIAAiTgVTIAABDSAAbABvAHMAcwAgAAAHMAAuACMAACUgAPZl9l4gAG0AaQBuAC8AYQB2AGcALwBtAGEAeAAgAD0AIAABJyAAcgB0AHQAIABtAGkAbgAvAGEAdgBnAC8AbQBhAHgAIAA9ACAAAActAC0AIAABByAALQAtAAERLQAtACAAcABpAG4AZwAgAAEFIAB4AAADHiIBDyAAIABzAGkAegBlAD0AAAlCACAALQAtAAETMgAyADMALgA1AC4ANQAuADUAAAM0AAAFMwAyAAAFXFBiawEJUwB0AG8AcAAABQVuZJYBC0MAbABlAGEAcgAABd1PWFsBCVMAYQB2AGUAAFc7TjpnIAArACAAIWtwZSAAKAAwAD0AAWPtfikAIAArACAABVMnWQ9cKABXW4KCKQA7ACAACWdQliFrcGXRjYxbk4/6USAAIk4FU4dzLwD2ZfZe336hiwGAk2gAbwBzAHQAIAArACAAYwBvAHUAbgB0ACAAKAAwAD0AbABvAG8AcAApACAAKwAgAHAAYQBjAGsAZQB0ACAAYgB5AHQAZQBzADsAIABmAGkAbgBpAHQAZQAgAHIAdQBuAHMAIABlAG4AZAAgAHcAaQB0AGgAIABsAG8AcwBzAC8AcgB0AHQAIABzAHQAYQB0AHMAABctAC0AIAB0AHIAYQBjAGUAcgB0ACAAAQ0AX8tZ740xdd+NKo4BF1QAcgBhAGMAZQAgAHIAbwB1AHQAZQAADy0ALQAgAGQAbgBzACAAAQcgACAAQAAAG3cAdwB3AC4AYgBhAGkAZAB1AC4AYwBvAG0AAAXlZ+KLAQtRAHUAZQByAHkAAF+fU8tZIABEAE4AUwAgAE9TrovlZ+KLIAAoAFUARABQACAANQAzACkALAAgALCLVV97fItXuXAJkDsAIAANZ6FSaFbYnqSLP5bMkSAAMgAyADMALgA1AC4ANQAuADUAAVFyAGEAdwAgAEQATgBTACAAbwB2AGUAcgAgAFUARABQAC8ANQAzADsAIABjAGwAaQBjAGsAIABhACAAcgBlAGMAbwByAGQAIAB0AHkAcABlAAARLQAtACAAaAB0AHQAcAAgAAEraAB0AHQAcABzADoALwAvAHcAdwB3AC4AYgBhAGkAZAB1AC4AYwBvAG0AAAX3i0JsAQtGAGUAdABjAGgAAICNtnIBYAF4LwBTAGUAcgB2AGUAcgAvAEMAbwBuAHQAZQBuAHQALQBUAHkAcABlAC8AQgBvAGQAeQAgACdZD1wvAFQAVABGAEIALwA7YBeA9mU7ACAA6oGoUt+Nj5bzjWyPLAAgAOBlIABzAGMAaABlAG0AZQAgANiepIsgAGgAdAB0AHAAcwA6AC8ALwABV3MAdABhAHQAdQBzAC8AaABlAGEAZABlAHIAcwAvAHMAaQB6AGUALwBUAFQARgBCADsAIABmAG8AbABsAG8AdwBzACAAcgBlAGQAaQByAGUAYwB0AHMAABUtAC0AIABrYs9jjFsQYiAALQAtAAEfLQAtACAAcwBjAGEAbgAgAGQAbwBuAGUAIAAtAC0AAREtAC0AIABzAGMAYQBuACAAAQ0gACpOOF4ode9641MBFSAAcABvAHIAdABzACkAIAAtAC0AAQc0ADQAMwAABcBoS20BC0MAaABlAGMAawAADTheKHXveuNTa2LPYwEXUwBjAGEAbgAgAGMAbwBtAG0AbwBuAAAdLQAtACAAA4P0VmyPIABDAEkARABSACAALQAtAAEnLQAtACAAcgBhAG4AZwBlACAAdABvACAAQwBJAEQAUgAgAC0ALQABBUkAUAAAGTEAOQAyAC4AMQA2ADgALgAxAC4AMQAwAAALTVIAfy8AqWMBeAEXUAByAGUAZgBpAHgALwBNAGEAcwBrAAAFMgA0AAAHxmIGUjpOARVTAHAAbABpAHQAIABpAG4AdABvAAAHKk5QW1F/AQ9zAHUAYgBuAGUAdABzAAALUwBwAGwAaQB0AAAHH5DlZ2iIAQtUAGEAYgBsAGUAAAUDg/RWAQtSAGEAbgBnAGUAABkxADkAMgAuADEANgA4AC4AMQAuADkAOQAAA7YlAQtsUVF/IABJAFAAARNQAHUAYgBsAGkAYwAgAEkAUAAAFeVn4osxWSWNIAAoAACXVIBRfykAAS1xAHUAZQByAHkAIABmAGEAaQBsAGUAZAAgACgAbwBmAGYAbABpAG4AZQApAAAFN1KwZQEPUgBlAGYAcgBlAHMAaAAACQ1ZNlJoUeiQARFDAG8AcAB5ACAAYQBsAGwAABNsAG8AZwB8ACoALgB0AHgAdAAAD24AZQB0AGwAbwBnAC0AAR95AHkAeQB5AE0ATQBkAGQALQBIAEgAbQBtAHMAcwABH2pSNI1/Z4ZT8lMgACAAKABXAGcAVAByAGEAeQApAAE3QwBsAGkAcABiAG8AYQByAGQAIABIAGkAcwB0AG8AcgB5ACAAIAAoAFcAZwBUAHIAYQB5ACkAAAkNWTZSCZAtTgEJQwBvAHAAeQAACQVuenqGU/JTASe5cGFn7nY9AA1ZNlLeVmpSNI1/ZzsAIAAsZ5d6AF9Ad01i0XYsVAFLYwBsAGkAYwBrACAAPQAgAGMAbwBwAHkAIABiAGEAYwBrADsAIABsAGkAcwB0AGUAbgBzACAAdwBoAGkAbABlACAAbwBwAGUAbgAAAyYgAR1uAG8AdABlAC0AYwBvAGwAbwByAC4AdAB4AHQAAQ15AGUAbABsAG8AdwAAHW4AbwB0AGUAcwAtAG0AZQB0AGEALgB0AHgAdAABGb9PfnsgACAAKABXAGcAVAByAGEAeQApAAEfTgBvAHQAZQBzACAAIAAoAFcAZwBUAHIAYQB5ACkAAAtOAG8AdABlAHMAAAsxAC4AdAB4AHQAAAe/T357IAABC04AbwB0AGUAIAAAAysAAAl0AG0A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ANABAAwAAADQOwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
