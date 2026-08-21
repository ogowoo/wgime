# ============================================================
#  WgTray - tray-only toolbox (NO IME): taskbar tray menu +
#  tools.txt toolbox + plugins\*.txt + config.txt apps
#  ps1 bootstrap -> load embedded prebuilt DLL payload
#  Errors are logged to %TEMP%\WgTray_error.log
#  Usage:
#    powershell -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File WgTray.ps1
#    powershell ... -File WgTray.ps1 -Install       # + register logon autostart task
#    powershell ... -File WgTray.ps1 -RemoveTask    # - delete the autostart task
# ============================================================
param([switch]$Install, [switch]$RemoveTask)
$env:WGTRAY_PATH = $PSCommandPath
$env:WGTRAY_DIR = $PSScriptRoot + '\'
$env:WGTRAY_AUTOSTART = ''
if ($Install) {
    $inner = 'powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $tr = '"' + $inner.Replace('"', '\"') + '"'
    & schtasks.exe /Create /F /TN WgTray /SC ONLOGON /TR $tr 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'WgTray autostart task registered (logon)' }
    else { Write-Host 'WgTray autostart task registration failed (try as admin)' }
    $env:WGTRAY_AUTOSTART = '1'
}
if ($RemoveTask) {
    & schtasks.exe /Delete /F /TN WgTray 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host 'WgTray autostart task removed' }
    else { Write-Host 'WgTray autostart task not found' }
    exit 0
}
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
    ToolStripMenuItem miApps, miPlugins, miAuto;                    // 动态子菜单 (config 应用 / 插件) + 开机自启勾选项
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

    // ---------- 开机自启 (计划任务, schtasks ONLOGON; 不再用 Startup 快捷方式) ----------
    static bool IsAutoStart()
    {
        try {
            var p = Process.Start(new ProcessStartInfo("schtasks.exe", "/Query /TN WgTray") {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true });
            p.WaitForExit();
            return p.ExitCode == 0;
        } catch { return false; }
    }
    static void SetAutoStart(bool on)
    {
        try {
            if (!on) {
                Process.Start(new ProcessStartInfo("schtasks.exe", "/Delete /F /TN WgTray") {
                    UseShellExecute = false, CreateNoWindow = true }).WaitForExit();
                TrayTip(L("开机自启", "Startup"), L("已关闭 (计划任务)", "off (task)"), ToolTipIcon.Info);
                return;
            }
            // /TR 值: "powershell.exe ... -File "C:\...\WgTray.ps1"" (内层引号反斜杠转义, 与 build 脚本一致)
            string inner = "powershell.exe -NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + BatPath + "\"";
            string tr = "\"" + inner.Replace("\"", "\\\"") + "\"";
            Process.Start(new ProcessStartInfo("schtasks.exe", "/Create /F /TN WgTray /SC ONLOGON /TR " + tr) {
                UseShellExecute = false, CreateNoWindow = true }).WaitForExit();
            TrayTip(L("开机自启", "Startup"), L("已开启 (计划任务, 登录时启动)", "on (task, at logon)"), ToolTipIcon.Info);
        } catch (Exception ex) { TrayTip(L("开机自启失败", "Startup failed"), ex.Message, ToolTipIcon.Error); }
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
        mCfg.DropDownItems.Add(new ToolStripSeparator());
        miAuto = new ToolStripMenuItem(L("开机自启", "Start with Windows"));
        miAuto.Click += delegate { SetAutoStart(!IsAutoStart()); RefreshMenuChecks(); };
        mCfg.DropDownItems.Add(miAuto);
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
        if (miAuto != null) miAuto.Checked = IsAutoStart();
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

用法: 右键托盘图标 -> 插件 -> 点插件名, 后台执行, 气泡报结果。
改完/新增后: 托盘"配置 -> 重载配置"即时生效。
管理: 托盘 -> 插件 -> 插件管理… (列表/编辑/删除/新建/重载)。

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

建议: 破坏性操作先 confirm; 步骤幂等; 长任务 msg 报进度。
完整规范见仓库 docs\WGIME_插件规范.md; 窗体 UI 风格见 docs\WGIME_插件UI规范.md。

(本文件与两个示例插件是首次运行时自动播种的; 删掉不会复活。想重新播种: 删除
 %LOCALAPPDATA%\wgime\provisioned-tray.done 后重启 wgtray.bat。)
'@
$seedCleanBin = @'
; ============================================================
;  WgIme 插件示例: 清空回收站
;  放在 plugins\ 目录下即自动注册; 输入 qls 选 ▶清空回收站 执行
;  规范详见 plugins\README.txt 或 docs\WGIME_插件规范.md
; ============================================================
code = qls
name = 清空回收站
desc = confirm 后调用 PowerShell Clear-RecycleBin

confirm 确定清空回收站吗?
[powershell]
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
Write-Output "recycle bin cleared"
[/powershell]
msg 回收站已清空
'@
$seedClock = @'
; ============================================================
;  WgIme C# 插件: 悬浮时钟 (现代重制版)
;  输入 sz 选 ▶悬浮时钟, 弹出置顶无边框窗体 (Esc / ✕ 关闭, 拖标题栏移动)
;  时钟(秒环/闹钟/整点报时) + 倒计时(圆环/预设/自定义提醒) + 秒表(计次) + 番茄(统计/7日图)
;  设置与统计存 %LOCALAPPDATA%\wgime\clock.cfg / pomodoro.txt (格式兼容旧版)
;  规范详见 plugins\README.txt 或 docs\WGIME_插件规范.md
; ============================================================
code = sz
name = 悬浮时钟
desc = 现代风时钟: 秒环/闹钟/整点报时/倒计时圆环/预设/秒表计次/番茄统计与7日图

[csharp]
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Windows.Forms;
using System.Collections.Generic;

public class ClockPlugin
{
    // ---------- palette (light blue-gray body + white cards: stands out from white desktop windows) ----------
    static Color C_BG      = Color.FromArgb(255, 232, 237, 245);   // #E8EDF5 light blue-gray
    static Color C_HEADER  = Color.FromArgb(255, 220, 227, 239);   // deeper tint: title bar stands out from white windows
    static Color C_SURFACE = Color.FromArgb(255, 255, 255, 255);   // white title bar / cards
    static Color C_SURF2   = Color.FromArgb(255, 217, 224, 236);   // tracks / wells
    static Color C_BORDER  = Color.FromArgb(255, 195, 204, 221);   // visible hairline
    static Color C_TEXT    = Color.FromArgb(255, 29, 29, 31);
    static Color C_SUB     = Color.FromArgb(255, 110, 116, 133);
    static Color C_ACCENT  = Color.FromArgb(255, 0, 122, 255);     // systemBlue
    static Color C_GREEN   = Color.FromArgb(255, 52, 199, 89);     // systemGreen
    static Color C_ORANGE  = Color.FromArgb(255, 255, 149, 0);     // systemOrange
    static Color C_BLUE    = Color.FromArgb(255, 48, 176, 199);    // systemTeal
    static Color C_RED     = Color.FromArgb(255, 255, 55, 95);     // systemPink

    // ---------- persisted settings & stats ----------
    static string CfgDir() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wgime"); }
    static string CfgPath() { return Path.Combine(CfgDir(), "clock.cfg"); }
    static string PomoPath() { return Path.Combine(CfgDir(), "pomodoro.txt"); }

    static bool hourly = true;
    static string reminder = "休息一下, 喝点水";
    static string alarmTime = "";
    static bool alarmOn = false;

    static void LoadCfg()
    {
        try {
            if (!File.Exists(CfgPath())) return;
            foreach (string raw in File.ReadAllLines(CfgPath(), System.Text.Encoding.UTF8)) {
                string t = raw.Trim();
                int eq = t.IndexOf('=');
                if (eq < 1) continue;
                string k = t.Substring(0, eq).Trim().ToLower(), v = t.Substring(eq + 1).Trim();
                if (k == "hourly") hourly = v != "0";
                else if (k == "reminder") reminder = v;
                else if (k == "alarm") alarmTime = v;
                else if (k == "alarmon") alarmOn = v == "1";
            }
        } catch {}
    }
    static void SaveCfg()
    {
        try {
            Directory.CreateDirectory(CfgDir());
            File.WriteAllText(CfgPath(),
                "hourly = " + (hourly ? "1" : "0") + "\nreminder = " + reminder + "\nalarm = " + alarmTime + "\nalarmon = " + (alarmOn ? "1" : "0") + "\n",
                new System.Text.UTF8Encoding(false));
        } catch {}
    }

    // ---------- resident watcher: hourly chime + alarm (works after first sz, no window needed) ----------
    static void StartChimeWatcher()
    {
        bool createdNew;
        var mx = new System.Threading.Mutex(true, "WgImeClockChime", out createdNew);
        if (!createdNew) return;
        var t = new System.Threading.Thread((System.Threading.ThreadStart)delegate {
            int lastHour = -1;
            string lastAlarmMin = "";
            while (true) {
                System.Threading.Thread.Sleep(5000);
                try {
                    LoadCfg();
                    var now = DateTime.Now;
                    if (hourly && now.Minute == 0 && now.Hour != lastHour) {
                        lastHour = now.Hour;
                        System.Media.SystemSounds.Asterisk.Play();
                    }
                    if (alarmOn && alarmTime.Length == 5) {
                        string hm = now.ToString("HH:mm");
                        if (hm == alarmTime && lastAlarmMin != hm) {
                            lastAlarmMin = hm;
                            System.Media.SystemSounds.Exclamation.Play();
                            System.Threading.Thread.Sleep(700);
                            System.Media.SystemSounds.Exclamation.Play();
                        }
                    }
                } catch {}
            }
        });
        t.IsBackground = true;
        t.Name = "ClockChime";
        t.Start();
    }

    // ---------- ui helpers ----------
    static Font F(float size, FontStyle style)
    {
        string[] names = { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" };
        foreach (string n in names) { try { return new Font(n, size, style, GraphicsUnit.Point); } catch {} }
        return new Font(FontFamily.GenericSansSerif, size, style, GraphicsUnit.Point);
    }

    static GraphicsPath RoundRect(Rectangle r, int rad)
    {
        var p = new GraphicsPath();
        int d = rad * 2;
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }

    class DBPanel : Panel { public DBPanel() { DoubleBuffered = true; } }

    class RoundedEdit : Panel      // rounded text field: native TextBox is always square, so wrap a borderless one
    {
        public readonly TextBox Box;
        public RoundedEdit(int w, int h, Font f)
        {
            Size = new Size(w, h);
            DoubleBuffered = true;
            BackColor = C_SURFACE;
            Box = new TextBox { BorderStyle = BorderStyle.None, Font = f, Dock = DockStyle.Fill,
                BackColor = C_SURFACE, ForeColor = C_TEXT, TextAlign = HorizontalAlignment.Center };
            Padding = new Padding(9, 4, 9, 3);
            Controls.Add(Box);
            Cursor = Cursors.IBeam;
            Click += delegate { Box.Focus(); };
            Box.Enter += delegate { Invalidate(); };
            Box.Leave += delegate { Invalidate(); };
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = RoundRect(rect, 7))
            using (var br = new SolidBrush(C_SURFACE)) { g.FillPath(br, path); }
            using (var path = RoundRect(rect, 7))
            using (var pen = new Pen(Box.Focused ? C_ACCENT : C_BORDER, Box.Focused ? 2F : 1F)) { g.DrawPath(pen, path); }
        }
    }

    class FlatBtn : Panel    // Panel base: zero native chrome (a Button's themed edge bleeds back over time)
    {
        public Color Bg = Color.FromArgb(255, 255, 255, 255);       // white card button on the blue-gray body
        public Color BgHover = Color.FromArgb(255, 240, 243, 249);
        public Color BgDown = Color.FromArgb(255, 226, 232, 242);
        public Color Fg = Color.FromArgb(255, 29, 29, 31);
        public bool AccentLine;                       // tab mode: 3px accent underline when Selected
        public bool Selected;
        public bool Primary;                          // solid systemBlue fill (macOS accent button)
        bool hover, down;
        static Color PriA  = Color.FromArgb(255, 10, 132, 255);     // #0A84FF
        static Color PriB  = Color.FromArgb(255, 0, 122, 255);      // #007AFF, near-solid gradient = macOS flat accent
        static Color Lighten(Color c, int d) { return Color.FromArgb(255,
            Math.Max(0, Math.Min(255, c.R + d)), Math.Max(0, Math.Min(255, c.G + d)), Math.Max(0, Math.Min(255, c.B + d))); }
        public FlatBtn()
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
            g.SmoothingMode = SmoothingMode.AntiAlias;
            // fill the full rect with the parent's background first: pixels outside the rounded
            // path are otherwise never painted and show whatever sits underneath (corner notches)
            if (Parent != null) { using (var pb = new SolidBrush(Parent.BackColor)) g.FillRectangle(pb, ClientRectangle); }
            var rect = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = RoundRect(rect, 7)) {
                if (Primary) {
                    int d = down ? -12 : (hover ? 18 : 0);
                    using (var lb = new LinearGradientBrush(new Rectangle(0, 0, Width, Height), Lighten(PriA, d), Lighten(PriB, d), 25F))
                        g.FillPath(lb, path);
                } else {
                    using (var br = new SolidBrush(down ? BgDown : (hover ? BgHover : Bg))) { g.FillPath(br, path); }
                }
            }
            if (AccentLine && Selected) {
                using (var br = new SolidBrush(C_ACCENT)) g.FillRectangle(br, 12, Height - 4, Width - 24, 3);
            }
            using (var br = new SolidBrush(Selected ? C_TEXT : Fg))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
            { g.DrawString(Text, Font, br, new RectangleF(0, 0, Width, Height), sf); }
        }
    }

    static Label MkLabel(string text, Font f, Color fg, int x, int y, int w, int h, ContentAlignment align)
    {
        return new Label { Text = text, Font = f, ForeColor = fg, Location = new Point(x, y), Size = new Size(w, h),
            TextAlign = align, BackColor = Color.Transparent };
    }

    static string FmtCd(TimeSpan t)
    {
        if (t.TotalHours >= 1) return (int)t.TotalHours + ":" + t.Minutes.ToString("00") + ":" + t.Seconds.ToString("00");
        return t.Minutes.ToString("00") + ":" + t.Seconds.ToString("00");
    }
    static string FmtSw(TimeSpan t)
    {
        if (t.TotalMinutes >= 60) return ((int)t.TotalMinutes / 60) + ":" + t.Minutes.ToString("00") + ":" + t.Seconds.ToString("00") + "." + t.Milliseconds.ToString("000");
        return t.Minutes.ToString("00") + ":" + t.Seconds.ToString("00") + "." + t.Milliseconds.ToString("000");
    }
    static string FmtMinutes(double min)
    {
        if (min >= 60) return ((int)(min / 60)) + "小时" + ((int)(min % 60)) + "分";
        return ((int)min) + "分钟";
    }
    static string WeekCn(DateTime d) { return "星期" + "日一二三四五六"[(int)d.DayOfWeek]; }

    public static void Run()
    {
        LoadCfg();
        StartChimeWatcher();

        var f = new Form();
        f.Text = "WgIme Clock";                 // window identity (alt-tab / tests); caption is drawn by the custom title bar
        f.AutoScaleMode = AutoScaleMode.None;   // pixel-designed layout: no font/DPI autoscaling distortion
        f.FormBorderStyle = FormBorderStyle.None;
        f.TopMost = true;
        f.StartPosition = FormStartPosition.CenterScreen;
        f.ClientSize = new Size(400, 400);
        f.BackColor = C_BG;
        f.ForeColor = C_TEXT;
        f.KeyPreview = true;
        f.ShowInTaskbar = false;
        // rounded outer frame via GDI CreateRoundRectRgn: cleaner corners than GraphicsPath->Region
        // (no jagged stub pixels); corner pixels outside the rgn are see-through (inherent to rounded windows)
        EventHandler applyRegion = delegate { try { SetWindowRgn(f.Handle, CreateRoundRectRgn(0, 0, f.Width + 1, f.Height + 1, 24, 24), true); } catch {} };
        f.HandleCreated += delegate { applyRegion(f, EventArgs.Empty); };
        f.Resize += delegate { applyRegion(f, EventArgs.Empty); };
        f.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var path = RoundRect(new Rectangle(1, 1, f.Width - 3, f.Height - 3), 11))   // inset 1px: AA never touches the clip boundary
            using (var pen = new Pen(C_BORDER, 1)) { g.DrawPath(pen, path); }
        };

        var fontTitle = F(9.5F, FontStyle.Bold);
        var fontSub = F(8.5F, FontStyle.Regular);
        var fontBtn = F(9F, FontStyle.Regular);
        var fontBig = F(40F, FontStyle.Regular);
        var fontMid = F(26F, FontStyle.Regular);
        var fontTab = F(9.5F, FontStyle.Regular);

        // ---------- title bar ----------
        // explicit bounds, no Dock: dock order depends on z-order and silently scrambled once
        // (title ended up below the tab strip). Fixed-size form => fixed coordinates.
        var title = new Panel { Location = new Point(0, 0), Size = new Size(400, 38), BackColor = C_HEADER };
        var lblCap = new Label { Text = "悬浮时钟", Font = fontTitle, ForeColor = C_TEXT, AutoSize = true, Location = new Point(30, 9), BackColor = Color.Transparent };
        var btnClose = new FlatBtn { Text = "✕", Font = fontTitle, Size = new Size(34, 26), Location = new Point(356, 6),
            Bg = C_HEADER, BgHover = Color.FromArgb(255, 200, 60, 70), BgDown = Color.FromArgb(255, 170, 40, 50) };
        btnClose.Click += delegate { f.Close(); };
        title.Controls.Add(lblCap); title.Controls.Add(btnClose);
        title.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            using (var br = new SolidBrush(C_ACCENT)) g.FillEllipse(br, 14, 15, 8, 8);
            using (var pen = new Pen(C_BORDER)) g.DrawLine(pen, 0, title.Height - 1, title.Width, title.Height - 1);
        };
        // drag to move
        EventHandler drag = delegate {
            try {
                ReleaseCapture();
                SendMessage(f.Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero);
            } catch {}
        };
        title.MouseDown += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) drag(s, e); };
        lblCap.MouseDown += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) drag(s, e); };
        f.Controls.Add(title);

        // ---------- tab strip ----------
        var strip = new Panel { Location = new Point(0, 38), Size = new Size(400, 40), BackColor = C_BG };
        string[] names = { "时钟", "倒计时", "秒表", "番茄" };
        var tabBtns = new FlatBtn[4];
        var pages = new Panel[4];
        var timer = new Timer { Interval = 100 };   // declared early: stopwatch handlers speed it up while running
        for (int i = 0; i < 4; i++) {
            var b = new FlatBtn { Text = names[i], Font = fontTab, Size = new Size(88, 28), Location = new Point(14 + i * 94, 6),
                AccentLine = true, Selected = (i == 0), Fg = C_SUB, Bg = C_BG, BgHover = C_SURF2, BgDown = C_SURF2 };
            int idx = i;
            b.Click += delegate {
                for (int j = 0; j < 4; j++) { tabBtns[j].Selected = (j == idx); tabBtns[j].Invalidate(); pages[j].Visible = (j == idx); }
            };
            tabBtns[i] = b; strip.Controls.Add(b);
        }
        f.Controls.Add(strip);

        for (int i = 0; i < 4; i++) {
            pages[i] = new Panel { Location = new Point(0, 78), Size = new Size(400, 322), BackColor = C_BG, Visible = (i == 0), Padding = new Padding(0) };
            f.Controls.Add(pages[i]);
        }
        pages[0].BringToFront();

        // =========================================================
        //  page 0: clock (seconds ring / alarm / hourly chime)
        // =========================================================
        var lblTime = MkLabel("00:00:00", fontBig, C_GREEN, 0, 16, 400, 58, ContentAlignment.MiddleCenter);
        var lblDate = MkLabel("", F(10.5F, FontStyle.Regular), C_SUB, 0, 78, 400, 22, ContentAlignment.MiddleCenter);
        var lblDayOf = MkLabel("", fontSub, C_SUB, 0, 100, 400, 18, ContentAlignment.MiddleCenter);
        var ringClock = new DBPanel { Location = new Point(130, 126), Size = new Size(140, 140), BackColor = Color.Transparent };
        ringClock.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(8, 8, 124, 124);
            using (var pen = new Pen(C_SURF2, 7)) g.DrawEllipse(pen, r);
            var now = DateTime.Now;
            double pct = (now.Second * 1000.0 + now.Millisecond) / 60000.0;
            using (var pen = new Pen(C_GREEN, 7)) { pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                g.DrawArc(pen, r, -90, (float)(360.0 * pct)); }
            // draw the seconds number inside the ring: a transparent panel paints AFTER sibling labels
            // (z-order) and would overdraw them on screen, so the text must live in this Paint handler
            using (var br = new SolidBrush(C_TEXT))
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(now.Second.ToString(), fontMid, br, new RectangleF(0, 0, 140, 140), sf);
        };

        var chkHourly = new FlatBtn { Text = hourly ? "整点报时: 开" : "整点报时: 关", Font = fontBtn,
            Location = new Point(16, 282), Size = new Size(118, 32), Fg = hourly ? C_GREEN : C_SUB };
        chkHourly.Click += delegate { hourly = !hourly; SaveCfg(); chkHourly.Text = hourly ? "整点报时: 开" : "整点报时: 关"; chkHourly.Fg = hourly ? C_GREEN : C_SUB; chkHourly.Invalidate(); };
        var lblAl = MkLabel("闹钟", fontBtn, C_SUB, 144, 288, 40, 22, ContentAlignment.MiddleLeft);
        var edAlarm = new RoundedEdit(58, 28, fontBtn); edAlarm.Location = new Point(186, 284);
        var txtAlarm = edAlarm.Box; txtAlarm.Text = alarmTime.Length == 5 ? alarmTime : "07:30";
        var chkAlarm = new FlatBtn { Text = alarmOn ? "开" : "关", Font = fontBtn, Location = new Point(252, 282), Size = new Size(46, 32), Fg = alarmOn ? C_ORANGE : C_SUB };
        chkAlarm.Click += delegate {
            alarmOn = !alarmOn;
            var t = txtAlarm.Text.Trim();
            if (System.Text.RegularExpressions.Regex.IsMatch(t, @"^([01]\d|2[0-3]):[0-5]\d$")) { alarmTime = t; txtAlarm.Text = t; }
            chkAlarm.Text = alarmOn ? "开" : "关"; chkAlarm.Fg = alarmOn ? C_ORANGE : C_SUB; chkAlarm.Invalidate();
            SaveCfg();
        };
        var lblAlNote = MkLabel(alarmTime.Length == 5 ? "每天 " + alarmTime + " 响" : "格式 HH:mm", fontSub, C_SUB, 306, 288, 90, 22, ContentAlignment.MiddleLeft);
        txtAlarm.LostFocus += delegate {
            var t = txtAlarm.Text.Trim();
            if (System.Text.RegularExpressions.Regex.IsMatch(t, @"^([01]\d|2[0-3]):[0-5]\d$")) { alarmTime = t; lblAlNote.Text = "每天 " + t + " 响"; SaveCfg(); }
        };
        var p0 = pages[0];
        p0.Controls.Add(lblTime); p0.Controls.Add(lblDate); p0.Controls.Add(lblDayOf);
        p0.Controls.Add(ringClock);
        p0.Controls.Add(chkHourly); p0.Controls.Add(lblAl); p0.Controls.Add(edAlarm); p0.Controls.Add(chkAlarm); p0.Controls.Add(lblAlNote);

        // =========================================================
        //  page 1: countdown (ring / presets / custom reminder)
        // =========================================================
        var cdTotal = TimeSpan.FromMinutes(25);
        var cdRemain = cdTotal;
        var cdTarget = DateTime.MinValue;
        bool cdRunning = false, cdPaused = false;
        int cdFlash = 0;
        string cdState = "就绪";

        var ringCd = new DBPanel { Location = new Point(110, 8), Size = new Size(180, 180), BackColor = Color.Transparent };
        ringCd.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(9, 9, 162, 162);
            using (var pen = new Pen(C_SURF2, 9)) g.DrawEllipse(pen, r);
            double pct = cdTotal.TotalSeconds > 0 ? cdRemain.TotalSeconds / cdTotal.TotalSeconds : 0;
            using (var pen = new Pen(cdFlash > 0 && cdFlash % 2 == 1 ? C_RED : C_ORANGE, 9)) { pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                g.DrawArc(pen, r, -90, (float)(360.0 * pct)); }
            // countdown digits + state drawn inside the ring Paint (see clock page note about z-order)
            string main = cdFlash > 0 ? reminder : FmtCd(cdRemain);
            Color mc = cdFlash > 0 ? (cdFlash % 2 == 1 ? C_RED : C_ORANGE) : C_ORANGE;
            using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center }) {
                using (var br = new SolidBrush(mc)) g.DrawString(main, fontMid, br, new RectangleF(0, 50, 180, 44), sf);
                using (var br = new SolidBrush(C_SUB)) g.DrawString(cdState, fontSub, br, new RectangleF(0, 100, 180, 20), sf);
            }
        };

        var edMin = new RoundedEdit(46, 28, fontBtn); edMin.Location = new Point(16, 201); edMin.Box.Text = "25";
        var txtMin = edMin.Box;
        var lblMinNote = MkLabel("分", fontBtn, C_SUB, 68, 206, 20, 20, ContentAlignment.MiddleLeft);
        var edRm = new RoundedEdit(368, 28, fontBtn); edRm.Location = new Point(16, 237);
        var txtRm = edRm.Box; txtRm.TextAlign = HorizontalAlignment.Left; txtRm.Text = reminder;
        txtRm.LostFocus += delegate { reminder = txtRm.Text.Trim(); if (reminder.Length == 0) reminder = "休息一下"; SaveCfg(); };
        var btnCdGo = new FlatBtn { Text = "开始", Font = fontBtn, Location = new Point(16, 276), Size = new Size(180, 36), Primary = true };
        var btnCdReset = new FlatBtn { Text = "重置", Font = fontBtn, Location = new Point(204, 276), Size = new Size(180, 36), Fg = C_SUB };
        var p1 = pages[1];
        p1.Controls.Add(ringCd);
        p1.Controls.Add(edMin); p1.Controls.Add(lblMinNote);
        p1.Controls.Add(edRm); p1.Controls.Add(btnCdGo); p1.Controls.Add(btnCdReset);

        Action<double> CdPreset = delegate(double m) {          // preset chip: set minutes + show it ready (press 开始 to run)
            txtMin.Text = ((int)m).ToString();
            cdRunning = false; cdPaused = false; cdFlash = 0;
            cdTotal = TimeSpan.FromMinutes(m); cdRemain = cdTotal;
            btnCdGo.Text = "开始"; cdState = "就绪";
        };
        int[] presets = { 5, 10, 15, 25, 45 };
        for (int i = 0; i < presets.Length; i++) {
            var chip = new FlatBtn { Text = presets[i] + "", Font = fontSub, Size = new Size(38, 26), Location = new Point(86 + i * 44, 202), Fg = C_SUB };
            int mm = presets[i];
            chip.Click += delegate { CdPreset(mm); };
            p1.Controls.Add(chip);
        }

        btnCdGo.Click += delegate {
            if (cdRunning) { cdRunning = false; cdPaused = true; btnCdGo.Text = "继续"; cdState = "已暂停"; return; }
            if (cdPaused) { cdTarget = DateTime.Now + cdRemain; cdRunning = true; cdPaused = false; btnCdGo.Text = "暂停"; cdState = "进行中"; return; }
            double m;
            if (!double.TryParse(txtMin.Text, out m) || m <= 0) m = 25;
            reminder = txtRm.Text.Trim(); if (reminder.Length == 0) reminder = "休息一下"; SaveCfg();
            cdTotal = TimeSpan.FromMinutes(m); cdRemain = cdTotal;
            cdTarget = DateTime.Now + cdRemain;
            cdRunning = true; cdPaused = false; btnCdGo.Text = "暂停"; cdState = "进行中";
        };
        btnCdReset.Click += delegate {
            cdRunning = false; cdPaused = false; cdFlash = 0;
            double m;
            if (!double.TryParse(txtMin.Text, out m) || m <= 0) m = 25;
            cdTotal = TimeSpan.FromMinutes(m); cdRemain = cdTotal;
            btnCdGo.Text = "开始"; cdState = "就绪";
        };

        // =========================================================
        //  page 2: stopwatch (laps)
        // =========================================================
        var swStart = DateTime.MinValue;
        var swAcc = TimeSpan.Zero;
        bool swRunning = false;
        var laps = new List<TimeSpan>();

        var lblSw = MkLabel("00:00.0", fontBig, C_BLUE, 0, 22, 400, 60, ContentAlignment.MiddleCenter);
        var btnSwGo = new FlatBtn { Text = "开始", Font = fontBtn, Location = new Point(16, 96), Size = new Size(118, 36), Primary = true };
        var btnSwLap = new FlatBtn { Text = "计次", Font = fontBtn, Location = new Point(141, 96), Size = new Size(118, 36), Fg = C_SUB };
        var btnSwReset = new FlatBtn { Text = "重置", Font = fontBtn, Location = new Point(266, 96), Size = new Size(118, 36), Fg = C_SUB };
        var lstLaps = new ListBox { Location = new Point(16, 146), Size = new Size(368, 158),
            BackColor = C_SURFACE, ForeColor = C_SUB, Font = F(9F, FontStyle.Regular), BorderStyle = BorderStyle.None, IntegralHeight = false };
        var p2 = pages[2];
        p2.Controls.Add(lblSw); p2.Controls.Add(btnSwGo); p2.Controls.Add(btnSwLap); p2.Controls.Add(btnSwReset); p2.Controls.Add(lstLaps);

        Action RefreshLaps = delegate {
            lstLaps.Items.Clear();
            for (int i = laps.Count - 1; i >= 0; i--) {
                string diff = i > 0 ? "  (+" + FmtSw(laps[i] - laps[i - 1]) + ")" : "";
                lstLaps.Items.Add("  #" + (i + 1) + "   " + FmtSw(laps[i]) + diff);
            }
        };
        btnSwGo.Click += delegate {
            if (swRunning) { swAcc += DateTime.Now - swStart; swRunning = false; btnSwGo.Text = "继续"; timer.Interval = 100; }
            else { swStart = DateTime.Now; swRunning = true; btnSwGo.Text = "暂停"; timer.Interval = 30; }   // 30ms tick so the millisecond digits actually move
        };
        btnSwLap.Click += delegate {
            if (!swRunning && swAcc == TimeSpan.Zero) return;
            laps.Add(swAcc + (swRunning ? DateTime.Now - swStart : TimeSpan.Zero));
            RefreshLaps();
        };
        btnSwReset.Click += delegate { swAcc = TimeSpan.Zero; swRunning = false; btnSwGo.Text = "开始"; timer.Interval = 100; laps.Clear(); RefreshLaps(); };

        // =========================================================
        //  page 3: pomodoro (count-up focus / stats / 7-day chart)
        // =========================================================
        var pmStart = DateTime.MinValue;
        bool pmRunning = false;

        var lblPm = MkLabel("00:00", fontBig, C_RED, 0, 14, 400, 56, ContentAlignment.MiddleCenter);
        var btnPmGo = new FlatBtn { Text = "开始专注", Font = fontBtn, Location = new Point(16, 78), Size = new Size(118, 34), Primary = true };
        var lblToday = MkLabel("今日 0 次 / 0分钟", fontBtn, C_TEXT, 146, 84, 240, 22, ContentAlignment.MiddleLeft);
        var lblTotal = MkLabel("总计 0 次 / 0分钟", fontSub, C_SUB, 146, 106, 240, 18, ContentAlignment.MiddleLeft);
        var chart = new DBPanel { Location = new Point(16, 136), Size = new Size(368, 108), BackColor = C_SURFACE };
        var lstPomo = new ListBox { Location = new Point(16, 252), Size = new Size(368, 56),
            BackColor = C_SURFACE, ForeColor = C_SUB, Font = F(8.5F, FontStyle.Regular), BorderStyle = BorderStyle.None, IntegralHeight = false };
        var p3 = pages[3];
        p3.Controls.Add(lblPm); p3.Controls.Add(btnPmGo); p3.Controls.Add(lblToday); p3.Controls.Add(lblTotal);
        p3.Controls.Add(chart); p3.Controls.Add(lstPomo);

        var dayMin = new double[7];
        var fontChart = F(7.5F, FontStyle.Regular);
        chart.Paint += delegate(object s, PaintEventArgs e) {
            var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            double max = 25;
            foreach (double v in dayMin) if (v > max) max = v;
            int bw = 28, gap = (368 - 7 * bw) / 8;
            for (int i = 0; i < 7; i++) {
                int x = gap + i * (bw + gap);
                int bh = (int)(70 * dayMin[i] / max);
                if (bh < 2 && dayMin[i] > 0) bh = 2;
                var rect = new Rectangle(x, 80 - bh, bw, Math.Max(bh, 1));
                using (var path = RoundRect(rect, 4))
                using (var br = new SolidBrush(i == 6 ? C_RED : C_SURF2)) { g.FillPath(br, path); }
                var day = DateTime.Today.AddDays(i - 6);
                using (var br = new SolidBrush(i == 6 ? C_TEXT : C_SUB))
                using (var sf = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Near, FormatFlags = StringFormatFlags.NoWrap })
                    g.DrawString("周" + "日一二三四五六"[(int)day.DayOfWeek], fontChart, br, new RectangleF(x - 20, 88, bw + 40, 16), sf);   // rect-centered: point-draw ignores Alignment
            }
        };

        Action RefreshPomo = delegate {
            try {
                for (int i = 0; i < 7; i++) dayMin[i] = 0;
                if (!File.Exists(PomoPath())) { lstPomo.Items.Clear(); lblToday.Text = "今日 0 次 / 0分钟"; lblTotal.Text = "总计 0 次 / 0分钟"; chart.Invalidate(); return; }
                string[] lines = File.ReadAllLines(PomoPath(), System.Text.Encoding.UTF8);
                string today = DateTime.Now.ToString("yyyy-MM-dd");
                int nToday = 0, nAll = 0; double mToday = 0, mAll = 0;
                foreach (string ln in lines) {
                    var m = System.Text.RegularExpressions.Regex.Match(ln, @"^(\d{4}-\d{2}-\d{2}).*\+(\d+)m");
                    if (!m.Success) continue;
                    nAll++; mAll += double.Parse(m.Groups[2].Value);
                    if (m.Groups[1].Value == today) { nToday++; mToday += double.Parse(m.Groups[2].Value); }
                    try {
                        var d = DateTime.ParseExact(m.Groups[1].Value, "yyyy-MM-dd", null);
                        int ago = (int)(DateTime.Today - d).TotalDays;
                        if (ago >= 0 && ago < 7) dayMin[6 - ago] += double.Parse(m.Groups[2].Value);
                    } catch {}
                }
                lblToday.Text = "今日 " + nToday + " 次 / " + FmtMinutes(mToday);
                lblTotal.Text = "总计 " + nAll + " 次 / " + FmtMinutes(mAll);
                lstPomo.Items.Clear();
                for (int i = lines.Length - 1; i >= 0 && i >= lines.Length - 3; i--) lstPomo.Items.Add("  " + lines[i]);
                chart.Invalidate();
            } catch {}
        };
        RefreshPomo();

        btnPmGo.Click += delegate {
            if (!pmRunning) { pmStart = DateTime.Now; pmRunning = true; btnPmGo.Text = "结束专注"; return; }
            pmRunning = false; btnPmGo.Text = "开始专注";
            var span = DateTime.Now - pmStart;
            int mins = (int)Math.Round(span.TotalMinutes);
            if (mins < 1) mins = 1;
            try {
                Directory.CreateDirectory(CfgDir());
                File.AppendAllText(PomoPath(), pmStart.ToString("yyyy-MM-dd HH:mm") + " +" + mins + "m\n", System.Text.Encoding.UTF8);
            } catch {}
            RefreshPomo();
            lblPm.Text = "00:00";
        };

        // ---------- main timer ----------
        timer.Tick += delegate {
            var now = DateTime.Now;
            lblTime.Text = now.ToString("HH:mm:ss");
            lblDate.Text = now.ToString("yyyy年M月d日 ") + WeekCn(now);
            lblDayOf.Text = "今年第 " + now.DayOfYear + " 天 · 第 " + ((now.DayOfYear - 1) / 7 + 1) + " 周";
            ringClock.Invalidate();
            if (cdRunning) {
                var left = cdTarget - now;
                if (left <= TimeSpan.Zero) {
                    cdRunning = false; cdRemain = TimeSpan.Zero;
                    btnCdGo.Text = "开始";
                    System.Media.SystemSounds.Exclamation.Play();
                    cdFlash = 12;
                    cdState = reminder;
                    f.Activate();
                } else cdRemain = left;
            }
            if (cdFlash > 0) cdFlash--;
            ringCd.Invalidate();
            var el = swAcc + (swRunning ? DateTime.Now - swStart : TimeSpan.Zero);
            lblSw.Text = FmtSw(el);
            if (pmRunning) lblPm.Text = FmtCd(DateTime.Now - pmStart);
        };
        timer.Start();

        f.KeyDown += delegate(object s, KeyEventArgs e) { if (e.KeyCode == Keys.Escape) f.Close(); };
        f.FormClosed += delegate { timer.Stop(); timer.Dispose(); };
        f.Show();
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern bool ReleaseCapture();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("gdi32.dll")]
    static extern IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool redraw);
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
        $cf = Join-Path $pdir 'clean-bin.txt'
        if (-not (Test-Path $cf)) { [IO.File]::WriteAllText($cf, $seedCleanBin, $utf8n) }
        $kf = Join-Path $pdir 'clock.txt'
        if (-not (Test-Path $kf)) { [IO.File]::WriteAllText($kf, $seedClock, $utf8n) }
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
'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ERNYExsrPhEGERolF1gTGpETHBEZKEcAAAoRBhEaERxvHAEACm8tAAAKJhEaERxYExoRGhEbLw0RGXL2EgBwby0AAAomERoRGzK8ERlvMwAAChMVK0IbjQEAAAETJhEmFnI4IABwohEmFxERjGIAAAGiESYYckQgAHCiESYZEROMYgAAAaIRJhpySiAAcKIRJijCAAAKExURFBETWBMMEREXLlURER8cLkgRERguPBERGy4wEREfDC4jEREfDy4WEREfEC4JEhEo8gAACisvcuYfAHArKHLgHwBwKyFy2B8AcCsacswfAHArE3LGHwBwKwxy7h8AcCsFctgcAHATHREOHY0BAAABEycRJxYREKIRJxdyWiAAcKIRJxgREoxtAAABohEnGXK6HgBwohEnGhEdohEnG3K6HgBwohEnHBEVohEnKMIAAApvhwAAChEPF1gTDxEPEQs/Xf3//xEOb4oAAAotFhEOcmogAHByciAAcCgBAAAGb4cAAAoRDm+gAAAKKgEQAAACALABP+8BDAAAAABmAgMeY9JvDwEACgIDIP8AAABf0m8PAQAKKjICA5EeYgIDF1iRYCqKAgORbh8YYgIDF1iRbh8QYmACAxhYkW4eYmACAxlYkW5gKgAAEzADACYAAAASAAARAgORCgYtBAMXWCoGIMAAAABfIMAAAAAzBAMYWCoDFwZYWBABK9oAABMwBQCpAAAAJwAAEXMsAAAKCgNKCxYMFg0JJRdYDSCAAAAAMQtyiCAAcHOpAAAKegIHkRMEEQQtCggtcgMHF1hUK2sRBCDAAAAAXyDAAAAAMx4RBB8/Xx5iAgcXWJFgEwUILQUDBxhYVBEFCxcMK6kGb4YAAAoWMQkGHy5vLgAACiYGKA0BAAoCBxdYEQRvHAEACm8tAAAKJgcXEQRYWAsIOnP///8DB1Q4a////wZvMwAACioAAAAbMAQAiAIAACgAABECcs4RAHBvgAAAChYvDXKkIABwAigyAAAKEAAo4wAACgpzgwAACgsCKB0BAAp0kQAAAQwIA28eAQAKCANvHwEACghytiAAcG8gAQAKCG8hAQAKdJMAAAENBm/pAAAKEwQJbyIBAApvMwAACgIoIwEACi0HclkJAHArGnLUIABwCW8iAQAKbyQBAApySQ8AcChAAAAKEwUHG40BAAABEw0RDRZy4iAAcKIRDRcJ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rAAABm/oAQAKAntWAAAEAhgJH0wSBhINKKwAAAZv6AEACgJ7VgAABAIZCR8sEgcSDiisAAAGb+gBAAoCe1YAAAQCGgkfLBIIEg8orAAABm/oAQAKAntWAAAEAhsJH0wSCRIQKKwAAAZv6AEACgJ7VgAABAIcCR8sEgoSESisAAAGb+gBAAodjTwAAAETIhEiFnLiLABwohEiF3LsLABwohEiGHL8LABwohEiGXIELQBwohEiGnIOLQBwchQtAHAoAQAABqIRIhtyIC0AcHImLQBwKAEAAAaiESIccjQtAHByOi0AcCgBAAAGohEiExIgZAIAABESjmlbExMWExQ43wAAAHNOAQAGExcRFxEcfcAAAARzvQAABhMWERYREhEUmm+IAQAKERYiAAAYQRYopAAABm+JAQAKERYXfVwAAAQRFhEUFv4BfV0AAAQRFn5MAAAEfVgAAAQRFn5PAAAEfVkAAAQRFn5PAAAEfVoAAAQRFn5SAAAEfVsAAAQRFhETHxxzjAEACm+NAQAKERYfDhEUERNaWBxzigEACm+LAQAKERYTFREXERR9wQAABBEVERf+Bk8BAAZzWwAACm+OAQAKAntXAAAEERVvFwIACghvjwEAChEVb5ABAAoRFBdYExQRFBESjmk/Fv///wIRBBELKLAAAAYCEQURDCixAAAGAhEGEQ0osgAABgIRBxEOKLMAAAYCEQgRDyi0AAAGAhEJERAotQAABgIRChERKLYAAAYCESEtDgL+BrsAAAZztQEAChMhESEotgEACioAABMwBgCrAAAAUwAAEXOdAQAKCwcWH05zigEACm+LAQAKByCAAgAABHOMAQAKb40BAAoHfkwAAARvfwEACgcDFv4Bb9kBAAoHCg4Ec50BAAoMCBYWc4oBAApviwEACggggAIAAAVzjAEACm+NAQAKCH5MAAAEb38BAAoIUQ4FFgUggAIAAAQFWXPIAAAGUQZvjwEACg4EUG+QAQAKBm+PAQAKDgVQb5ABAAoCKI8BAAoGb5ABAAoGKgATMAMAUwAAAFQAABFzvQAABgsHDgVviAEACgciAAAQQRYopAAABm+JAQAKBwQFc4oBAApviwEACgcOBB8cc4wBAApvjQEACgcOBn1eAAAEBwoDb48BAAoGb5ABAAoGKgATMAIAFQAAAFUAABEDc5MAAAoKBhdvlAAACgZv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AAAAAIYAMzdjACoCjOUAAAAAhhhTB2MAKgKU5QAAAACGAFA4YwAqAg7tAAAAAIYYUwdjACoCbO0AAAAAhgBeOaUCKgKE7QAAAACGAGw5pQIsApztAAAAAIYAejmlAi4CzO0AAAAAhgCIOaUCMAIW7QAAAACGGFMHYwAyAvbtAAAAAIYAwDmlAjICEO4AAAAAhgDOOYsCNAJE+gAAAACGGFMHYwA2Akz6AAAAAIYAIDuTAjYCAAABADAPAAACADMPAAABADYPAAACADgPAAABADwPAAACAD8PAAABAEEPAAACAEcPAAADAEwPAAABAFEPAgACAFYPAgADAIYPAAABAFYPAAACAIYPAAABAIkPAAABAIwPAAABAI8PAAABAI8PAAACAJMPAAABAJsPAAABAJ0PAAABAJ0PAAABAKIPAAABAI8PAAABAKcPAAABAK8PAAACALQPAAABALcPAgACALwPAgADAMEPAAABAMUPAAACADUIAAABAMUPAAACADUIAAABAMkPAAACANAPAAADANQPAAAEANgPAAAFAOMPAAAGAOcPAAAHAO0PAAAIADUIEBAJAPUPEBAKAP0PAAABAAIQAAACAAcQAAADAA0QAAAEAA8QAAAFABQQAAABALQPAAACAK8PAAADADUIAAAEABwQAAABAKkHAAACAB8QAAABAKkHAAACACkQAAADAB8QAgAEAC4QAAABAKkHAAACADIQAAADAB8QAgAEADYQAAABAKkHAAACADsQAAADAB8QAAABAEAQAAABAEIQAAABAEQQAAABAEYQAAACAE0QAgADAFYQAgAEAFkQAgAFAF4QAAABAEIQAAABAEIQAAABAEYQAAACAE0QAAABAEYQAAACAE0QAAADAGMQAAABAGkQAAACAGsQAAABAG0QAAACAHIQAAADAHgQAAAEAB8QAAABAH8QAAACAEIQAAABAEQQAAACAIEQAAABAEQQAAACAIEQAAABAEQQAAACAIMQAAABAEQQAAACAIMQAAABAIcQAAACAB8QAAABAB8QAAABAIsQAAACAI0QAAADAI8QAAABAD8PAAABAD8PAAABAJMQAAACAJkQAAADAJ8QAAABAKQQAAACAKkQAAABAI8PAAABAK0QAAACALIQAAABAK0QAAABALsQAAABAK0QAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAMIQAAACAIkPAAADAMcQAAAEAIYPAAABAMIQAAACAIkPAAABAIkPAAACAFYPAAADAIYPAAABAIkPAAABAEQQAAABAKkHAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABACkQAAACANMQAAABADYPAAACADgPAAABAMIQAAACANYQAAADANoQAAAEAOEQAAABAIsQAAACANYQAAADAH8QAAAEAOgQAAABAOoQAAACAO0QAAADAPAQAAAEAPMQAAAFAH8QAAAGAIsQAAABAMIQAAACAPYQAAADAPsQAAABAAIRAAABAAcRAAABAJkLAAACAA0RAAABAJkLAAACABERAAABAEAQAAACABQRAAABAEAQAAACABQRAAABAEAQAAACABQRAgABABYRAgACABwRAgADAPUPAAABAEAQAAACABQRAAABAEAQAAACABQRAAABAEAQAAACABQRAAABAEAQAAABACIRAAACABQRAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABAEAQAAACABQRAAABADEuAAACAK8bAAABAEAQAAACABQRAAABADEuAAACAK8bAAABANMWAAACANoWAAABAEAQAAACABQRAAABAIsQAAABAEQQAAABABQRAAABABQRAAABABQRAAABABQRAAABABQRAAABACkQAAACANMQAAABADYPAAACADgPAAABAMIQAAACANYQAAADANoQAAAEAOEQAAABAIsQAAACANYQAAADAH8QAAAEAOgQAAABAOoQAAACAO0QAAADAPAQAAAEAPMQAAAFAH8QAAAGAIsQAAABAMIQAAACAPYQAAADAPsQAAABACkRAAACAC0RAAADADYRAgAEADsRAgAFADUIAAABAD8RAAACAKAOAAADAKIOAAAEAH8QAAAFAEcPAAAGAEYRAAABAE4RAAABAEAQAAABADsRAAACADUIAAABADsRAAACADUIAAABADsRAAACADUIAAABADsRAAACADUIAAABADsRAAACADUIAAABADsRAAACADUIAAABADsRAAACADUIAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABAEAQAAACABQRAAABAEAQAAACABQRAAABABQRAAABABQRAAABABQRAAABABQRAAABABQRAAABAKAOAAACAKIOAAADAH8QAAAEAEcPAAABABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAKAOAAACAKIOAAADAH8QAAAEAIsQAgABABYRAgACABwRAgADAPUPAAABAEAQAAACABQRAAABAEAQAAABAEAQAAABAFERAAABAEAQAAACABQRAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAIsQAAABAIsQAAABABQRAAABABQRAAABAEQQAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABACkQAAACANMQAAABADYPAAACADgPAAABAMIQAAACANYQAAADANoQAAAEAOEQAAABAIsQAAACANYQAAADAH8QAAAEAOgQAAABAOoQAAACAO0QAAADAPAQAAAEAPMQAAAFAH8QAAAGAIsQAAABAMIQAAACAPYQAAADAPsQAAABAAIQAAACACkRAAABAFcRAAABAFcRAgABABYRAgACABwRAgADAPUPAAABAEAQAAACABQRAAABAEAQAAACABQRAAABAEAQAAACABQRAAABAFcRAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABAEAQAAACABQRAAABABQRAAABAIkPAAACAFkRAAADAFYPAAAEAFwRAAABAIsQAAABAIsQAAACAGARAAADANoQAAAEAOEQAAABAG0QAgABAIEQAAABAGARAAACANoQAAADAOEQAAABAKAOAAACAKIOAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABAGYRAAACAG0RAAABAGARAAACANoQAAADAOEQAAABAGARAAACANoQAAADAOEQAAAEAHQRAAAFAGYRAAABAH0RAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACAK8bAAABAEAQAAACAK8bAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABAHAoAAACAH8QAAADAIsQAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABANMWAAACANoWAAABAEAQAAACABQRAAABAEAQAAACABQRCgAVAGkBUwdjAHEBUwdnAHkB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VENoaXAAU0JQYW5lbABDb2xvckZvcm0AUFQATVNMTABNb3VzZVByb2MAUGx1Z2luQ29kZQBtc2NvcmxpYgBTeXN0ZW0AT2JqZWN0AFN5c3RlbS5XaW5kb3dzLkZvcm1zAENvbnRyb2wARm9ybQBQYW5lbABJTWVzc2FnZUZpbHRlcgBWYWx1ZVR5cGUATXVsdGljYXN0RGVsZWdhdGUAWmgATABEYXRhRGlyAEJhdERpcgBCYXRQYXRoAE5vdGlmeUljb24AdHJheVJlZgBTeXN0ZW0uRHJhd2luZwBTeXN0ZW0uRHJhd2luZy5EcmF3aW5nMkQAR3JhcGhpY3NQYXRoAFJlY3RhbmdsZUYAUm91bmRlZFJlY3QASWNvbgBDb2xvcgBNYWtlSWNvbgBDb250ZXh0TWVudVN0cmlwAG1lbnUAVG9vbFN0cmlwTWVudUl0ZW0AbWlBcHBzAG1pUGx1Z2lucwBtaUF1dG8AaG90SXRlbXMAdHJheQBoa0hvc3QASG90VG9vbGJveE1vZABIb3RUb29sYm94VmsASG90UGx1Z2luc01vZABIb3RQbHVnaW5zVmsASG90TWVudU1vZABIb3RNZW51VmsAVG9vbFRpcEljb24AVHJheVRpcAB1aUludm9rZXIAVWkAUGFyc2VIb3RrZXkASG90a2V5VGV4dABBcHBseUhvdGtleXMASGFuZGxlSG90S2V5AElzQXV0b1N0YXJ0AFNldEF1dG9TdGFydABTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYwBEaWN0aW9uYXJ5YDIAQXBwcwBEZWZhdWx0Q29uZmlnVGV4dABMb2FkQ29uZmlnAFJlbG9hZENvbmZpZwBPcGVuQ29uZmlnRmlsZQBPcGVuRGF0YURpcgBCdWlsZE1lbnUAUmVmcmVzaE1lbnVDaGVja3MAUmVidWlsZFRyYXlNZW51AFJ1bgBGaXhMZWdhY3lDb25maWdJZkJyb2tlbgBMYXVuY2hBcHAAUnVuVG9vbENvZGUATGlzdGAxAFRvb2xUYWJzAHRvb2xzRm9ybQBUb29sVG9rcwBMb2FkVG9vbHMAVG9vbFJlc3QAVG9vbFBhdGgATWljcm9zb2Z0LldpbjMyAFJlZ2lzdHJ5S2V5AFRvb2xSZWdTcGxpdABTeXN0ZW0uRGlhZ25vc3RpY3MAUHJvY2Vzc1N0YXJ0SW5mbwBTeXN0ZW0uVGV4dABTdHJpbmdCdWlsZGVyAFJ1bkhpZGRlbgBSdW5WaXNpYmxlAEVuY29kaW5nAFJ1blNjcmlwdEJsb2NrAFRvb2xEZWwARXhlY1Rvb2xTdGVwAFNob3dUb29scwBuZXRGb3JtAFNob3dOZXRUb29scwBQaW5nT25jZQBQaW5nUnR0AEhvcE9uY2UAVGVzdFBvcnQAUGFyc2VJcFY0AElwU3RyAE1hc2tUb0JpdHMAUGFyc2VJcE1hc2sASXBUeXBlAElwQ2xhc3MAU3VibmV0Q2FsYwBTdWJuZXRTcGxpdABSYW5nZVRvQ2lkcgBNYXNrVGFibGUATG9jYWxOZXRJbmZvAERuc1F1ZXJ5AFN5c3RlbS5JTwBCaW5hcnlXcml0ZXIARG5zQkUxNgBEbnNVMTYARG5zVTMyAERuc1NraXBOYW1lAERuc1JlYWROYW1lAEh0dHBDaGVjawBQdWJsaWNJcABjbGlwRm9ybQBDbGlwUHVzaABTaG93Q2xpcABub3RlRm9ybQBOb3Rlc1BhdGgAU2hvd05vdGUAY29sb3JGb3JtAENvbG9ySGV4AENvbG9ySHN2AFNob3dDb2xvcgBQbHVnaW5BY3Rpb25zAElFbnVtZXJhYmxlYDEAUGFyc2VUb29sU3RlcHMARXh0cmFjdFBsdWdpbkJsb2NrAExvYWRQbHVnaW5zAFBsdWdpbkluZm8AU3lzdGVtLkNvcmUASGFzaFNldGAxAERpc2FibGVkUGx1Z2lucwBMb2FkRGlzYWJsZWRQbHVnaW5zAFNldFBsdWdpbkRpc2FibGVkAFJ1blBsdWdpbgBQbHVnaW5Db2RlQ2FjaGUAUGx1Z2luUmVmcwBQbHVnaW5SZWZzRnVsbABDb21waWxlUGx1Z2luAFJ1bkNvZGVQbHVnaW4AU3lzdGVtLlRocmVhZGluZwBUaHJlYWQAcGx1Z2luVGhyZWFkAHBsdWdpbkludm9rZXIARW5zdXJlUGx1Z2luVGhyZWFkAHBsdWdpbk1ncgBTaG93UGx1Z2luTWdyAC5jdG9yAEFjdGlvbmAxAE9uSG90S2V5AHJlZwBSZWdpc3RlckhvdEtleQBVbnJlZ2lzdGVySG90S2V5AFJlZwBVbnJlZwBNZXNzYWdlAFduZFByb2MAaG9zdABMaXN0VmlldwBsaXN0AFBsdWdpbkRpcgBSZWZyZXNoTGlzdABSdW5TZWwAVG9nZ2xlU2VsAFNlbEZpbGUAT3BlbkRpcgBFZGl0U2VsAERlbFNlbABOZXdQbHVnaW4ATmFtZQBDb2RlAFN0ZXBzAFJhdwBBY3Rpb25zAENvbHMAVGV4dEJveABsb2cAcGFnZXMAbG9nV3JhcAB3aGVlbEZpbHRlcgBUQ19CRwBUQ19TVVJGQUNFAFRDX0hFQURFUgBUQ19TVVJGMgBUQ19CT1JERVIAVENfVEVYVABUQ19TVUIAVENfQUNDRU5UAFRDX0NPTkJHAFRDX0NPTkZHAEZvbnQARm9udFN0eWxlAFRGAFJlY3RhbmdsZQBUUm91bmQAVFJlbGVhc2VDYXB0dXJlAFRTZW5kTWVzc2FnZQBUU2VuZE1zZ0ludABUQ3JlYXRlUm91bmRSZWN0UmduAFRTZXRXaW5kb3dSZ24AT25XaGVlbABTZXRWcE9mZnNldABTY3JvbGxWcABQYWludEV2ZW50QXJncwBQYWdlU2JQYWludABNb3VzZUV2ZW50QXJncwBQYWdlU2JEb3duAFBhZ2VTYk1vdmUATG9nU2JNZXRyaWNzAEludmFsaWRhdGVMb2dCYXIATG9nU2JQYWludABMb2dTYkRvd24ATG9nU2JNb3ZlAExvZwBFdmVudEFyZ3MAUnVuQWN0aW9uAERyYWcARHJhZ09mZgBIb3N0AFZwAFByZUZpbHRlck1lc3NhZ2UAQmcAQmdIb3ZlcgBCZ0Rvd24AQWNjZW50TGluZQBTZWxlY3RlZABob3ZlcgBkb3duAE9uTW91c2VFbnRlcgBPbk1vdXNlTGVhdmUAT25Nb3VzZURvd24AT25Nb3VzZVVwAE9uUGFpbnQATkNfQkcATkNfSEVBREVSAE5DX0NBUkQATkNfU1VSRjIATkNfQk9SREVSAE5DX1RFWFQATkNfU1VCAE5DX0FDQ0VOVABOQ19DT05CRwBOQ19DT05GRwBOUm91bmQATlJlbGVhc2VDYXB0dXJlAE5TZW5kTWVzc2FnZQBOU2VuZE1zZ0ludABOQ3JlYXRlUm91bmRSZWN0UmduAE5TZXRXaW5kb3dSZ24AY2hpcHMATWFrZVBhZ2UATWtCdG4AVGhyZWFkU3RhcnQAU3RhbXAAQnVpbGRQaW5nVGFiAEJ1aWxkVHJhY2VydFRhYgBCdWlsZERuc1RhYgBCdWlsZEh0dHBUYWIAQnVpbGRQb3J0VGFiAEJ1aWxkU3VibmV0VGFiAEJ1aWxkTG9jYWxUYWIARmcAUHJpbWFyeQBCb3gAYmFyAFRpbWVyAHN5bmMAZHJhZwBkcmFnT2ZmAGxhc3RGaXJzdABsYXN0VG90YWwATWV0cmljcwBQYWludEJhcgBMaW5lAFNldABTYXZlAFdNX0NMSVBCT0FSRFVQREFURQBBZGRDbGlwYm9hcmRGb3JtYXRMaXN0ZW5lcgBSZW1vdmVDbGlwYm9hcmRGb3JtYXRMaXN0ZW5lcgBIaXN0b3J5AExpc3RCb3gAc2VsZlNldABPbkhhbmRsZUNyZWF0ZWQARm9ybUNsb3NlZEV2ZW50QXJncwBPbkZvcm1DbG9zZWQAQ29weVNlbABib3gATGFiZWwAc3RhdHVzAHNhdmVyAHNiU3luYwBoZWFkZXIAd3JhcABzdHJpcABzYgBmaWxlcwBjdXIAYWN0aXZlQ2kAc2JEcmFnAHNiRHJhZ09mZgBDTgBDQm9keQBDSGVhZABDVGV4dABDU3ViAE5GAE5vdGVSb3VuZABOb3RlQ29sb3JQYXRoAExvYWROb3RlQ29sb3IATm90ZXNEaXIATm90ZU1ldGFQYXRoAFJlbGVhc2VDYXB0dXJlAFNlbmRNZXNzYWdlAFNlbmRNc2dJbnQAQ3JlYXRlUm91bmRSZWN0UmduAFNldFdpbmRvd1JnbgBMb2FkTm90ZXMAU2F2ZU1ldGEATG9hZEN1cgBUaXRsZU9mAFJlYnVpbGRUYWJzAFN3aXRjaFRvAEFkZE5vdGUARGVsZXRlTm90ZQBTYk1ldHJpY3MAUGFpbnRTYgBTYkRvd24AU2JNb3ZlAEFwcGx5VGhlbWUAU2F2ZU5vdwBUaXRsZQBBY3RpdmUAQ2VudGVyAFNldFdpbmRvd3NIb29rRXgAVW5ob29rV2luZG93c0hvb2tFeABDYWxsTmV4dEhvb2tFeABHZXRNb2R1bGVIYW5kbGUAR2V0Q3Vyc29yUG9zAHN3YXRjaABsYmwAbW91c2VIb29rAHByb2MAU3RhcnRQaWNrAFN0b3BQaWNrAE1vdXNlSG9va1Byb2MAUGlja0F0AHgAeQBwdABtb3VzZURhdGEAZmxhZ3MAdGltZQBleHRyYQBJbnZva2UASUFzeW5jUmVzdWx0AEFzeW5jQ2FsbGJhY2sAQmVnaW5JbnZva2UARW5kSW52b2tlAFN5c3RlbS5SZWZsZWN0aW9uAEFzc2VtYmx5AEFzbQBNZXRob2RJbmZvAEVudHJ5AEVycm9yAHpoAGVuAHIAcmFkAGNoAGMAdGl0bGUAdGV4dABpY29uAHNwZWMAbW9kAFN5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlcwBPdXRBdHRyaWJ1dGUAdmsAaWQAb24AZGlyAGJhdFBhdGgAZgBjb2RlAGxpbmUAcmF3TGluZQByZXN0AHRrAGZ1bGwAaGl2ZQBzdWIAcHNpAHNjcmlwdABleHQAZXhlAGFyZ3NQcmVmaXgAZW5jAGlvRW5jAHByZWx1ZGUAdmlzaWJsZQB0YWlsAHBhdGgAaXNEaXIAbgBmYWlsAHNraXBwZWQAdWkAdGltZW91dE1zAHNpemUAcnR0AHR0bABkb25lAHBvcnQAcwB2AG0AaXBUZXh0AG1hc2tUZXh0AGlwAGJpdHMAbWFzawBjb3VudABhAGIAbmFtZQBxdHlwZQBzZXJ2ZXIAdwBwAHBvcwB1cmwAaAB0AGNhcABsaW5lcwBzdGVwcwByYXdzAGJvZHkAdGFnAGZpbGUAZGlzYWJsZWQAc291cmNlAGhXbmQAZnNNb2RpZmllcnMAc3QAbXNnAHdQYXJhbQBsUGFyYW0AbAB4MQB5MQB4MgB5MgBoUmduAHJlZHJhdwB0YWJzAGRlbHRhAG9mZgBkeQBlAGZpcnN0AHRvdGFsAHNlbmRlcgBpZHgAY29udGVudEgAdG9wSAB0b3AAcGFyZW50AHByaW1hcnkAZm4Ab3duZXIAaQBjYgB0aWQAbkNvZGUAb2JqZWN0AG1ldGhvZABjYWxsYmFjawByZXN1bHQAU3lzdGVtLlJ1bnRpbWUuQ29tcGlsZXJTZXJ2aWNlcwBDb21waWxhdGlvblJlbGF4YXRpb25zQXR0cmlidXRlAFJ1bnRpbWVDb21wYXRpYmlsaXR5QXR0cmlidXRlAHdndHJheV9uZXcAZ2V0X1gAZ2V0X1kAQWRkQXJjAGdldF9SaWdodABnZXRfQm90dG9tAENsb3NlRmlndXJlAEJpdG1hcABHcmFwaGljcwBJbWFnZQBGcm9tSW1hZ2UAU21vb3RoaW5nTW9kZQBzZXRfU21vb3RoaW5nTW9kZQBnZXRfVHJhbnNwYXJlbnQAQ2xlYXIAU29saWRCcnVzaABCcnVzaABGaWxsUGF0aABJRGlzcG9zYWJsZQBEaXNwb3NlAEdyYXBoaWNzVW5pdABTdHJpbmdGb3JtYXQAU3RyaW5nQWxpZ25tZW50AHNldF9BbGlnbm1lbnQAc2V0X0xpbmVBbGlnbm1lbnQARm9udEZhbWlseQBnZXRfRm9udEZhbWlseQBBZGRTdHJpbmcAQ29tcG9zaXRpbmdNb2RlAHNldF9Db21wb3NpdGluZ01vZGUAR2V0SGljb24ARnJvbUhhbmRsZQBTaG93QmFsbG9vblRpcABnZXRfSXNEaXNwb3NlZABnZXRfSGFuZGxlAFN0cmluZwBJc051bGxPcldoaXRlU3BhY2UAVG9Mb3dlcgBDaGFyAFNwbGl0AFRyaW0Ab3BfRXF1YWxpdHkAZ2V0X0xlbmd0aABnZXRfQ2hhcnMAQXJyYXkASW5kZXhPZgA8UHJpdmF0ZUltcGxlbWVudGF0aW9uRGV0YWlscz57NTUwNjM2QzctMkQ3MS00RURGLUI2ODYtNTUwMTcxMjQxRURBfQBDb21waWxlckdlbmVyYXRlZEF0dHJpYnV0ZQAkJG1ldGhvZDB4NjAwMDAwNi0xAEFkZABUcnlHZXRWYWx1ZQBBcHBlbmQAVUludDMyAF9fU3RhdGljQXJyYXlJbml0VHlwZVNpemU9OTYAJCRtZXRob2QweDYwMDAwMDctMQBSdW50aW1lSGVscGVycwBSdW50aW1lRmllbGRIYW5kbGUASW5pdGlhbGl6ZUFycmF5AFRvU3RyaW5nAENvbmNhdABnZXRfSXNIYW5kbGVDcmVhdGVkAEN1cnNvcgBQb2ludABnZXRfUG9zaXRpb24AVG9vbFN0cmlwRHJvcERvd24AU2hvdwBzZXRfVXNlU2hlbGxFeGVjdXRlAHNldF9DcmVhdGVOb1dpbmRvdwBzZXRfUmVkaXJlY3RTdGFuZGFyZE91dHB1dABzZXRfUmVkaXJlY3RTdGFuZGFyZEVycm9yAFByb2Nlc3MAU3RhcnQAV2FpdEZvckV4aXQAZ2V0X0V4aXRDb2RlAFJlcGxhY2UARXhjZXB0aW9uAGdldF9NZXNzYWdlAHNldF9JdGVtAFBhdGgAQ29tYmluZQBGaWxlAEV4aXN0cwBnZXRfVVRGOABSZWFkQWxsTGluZXMAU3Vic3RyaW5nAFN5c3RlbS5UZXh0LlJlZ3VsYXJFeHByZXNzaW9ucwBSZWdleABNYXRjaABHcm91cABnZXRfU3VjY2VzcwBHcm91cENvbGxlY3Rpb24AZ2V0X0dyb3VwcwBnZXRfSXRlbQBDYXB0dXJlAGdldF9WYWx1ZQBFbnZpcm9ubWVudABFeHBhbmRFbnZpcm9ubWVudFZhcmlhYmxlcwBVVEY4RW5jb2RpbmcAV3JpdGVBbGxUZXh0AHNldF9GaWxlTmFtZQA8QnVpbGRNZW51PmJfXzYAcGFyYW0wAHBhcmFtMQA8QnVpbGRNZW51PmJfXzcAPEJ1aWxkTWVudT5iX184ADxCdWlsZE1lbnU+Yl9fOQA8QnVpbGRNZW51PmJfX2EAPEJ1aWxkTWVudT5iX19iADxCdWlsZE1lbnU+Yl9fYwA8QnVpbGRNZW51PmJfX2QAPEJ1aWxkTWVudT5iX19lADxCdWlsZE1lbnU+Yl9fZgA8QnVpbGRNZW51PmJfXzEwAEV2ZW50SGFuZGxlcgBDUyQ8PjlfX0NhY2hlZEFub255bW91c01ldGhvZERlbGVnYXRlMTIAU3lzdGVtLkNvbXBvbmVudE1vZGVsAENhbmNlbEV2ZW50QXJncwA8QnVpbGRNZW51PmJfXzExAEFwcGxpY2F0aW9uAEV4aXQAVG9vbFN0cmlwAFRvb2xTdHJpcEl0ZW1Db2xsZWN0aW9uAGdldF9JdGVtcwBUb29sU3RyaXBJdGVtAFRvb2xTdHJpcFNlcGFyYXRvcgBUb29sU3RyaXBEcm9wRG93bkl0ZW0AZ2V0X0Ryb3BEb3duSXRlbXMAYWRkX0NsaWNrAHNldF9FbmFibGVkAENhbmNlbEV2ZW50SGFuZGxlcgBhZGRfT3BlbmluZwBzZXRfQ29udGV4dE1lbnVTdHJpcABzZXRfQ2hlY2tlZABzZXRfVGV4dAA8PmNfX0Rpc3BsYXlDbGFzczE4ADw+NF9fdGhpcwA8UmVidWlsZFRyYXlNZW51PmJfXzE1ADw+Y19fRGlzcGxheUNsYXNzMWEAPFJlYnVpbGRUcmF5TWVudT5iX18xNwA8UmVidWlsZFRyYXlNZW51PmJfXzE2AEVudW1lcmF0b3IAR2V0RW51bWVyYXRvcgBLZXlWYWx1ZVBhaXJgMgBnZXRfQ3VycmVudABTdGFydHNXaXRoAGdldF9LZXkATW92ZU5leHQAPD5jX19EaXNwbGF5Q2xhc3MxZABhcHAAPFJ1bj5iX18xYwBzZXRfVmlzaWJsZQBTcGVjaWFsRm9sZGVyAEdldEZvbGRlclBhdGgARGlyZWN0b3J5AERpcmVjdG9yeUluZm8AQ3JlYXRlRGlyZWN0b3J5AE11dGV4AE1lc3NhZ2VCb3gARGlhbG9nUmVzdWx0AEZyb21BcmdiAHNldF9JY29uAGFkZF9BcHBsaWNhdGlvbkV4aXQAUmVhZEFsbFRleHQAQ29udGFpbnMAVHJpbVN0YXJ0AElzUGF0aFJvb3RlZABzZXRfQXJndW1lbnRzADw+Y19fRGlzcGxheUNsYXNzMjEAPFJ1blRvb2xDb2RlPmJfXzIwAGdldF9Db3VudABJbnQzMgBKb2luAHNldF9Jc0JhY2tncm91bmQASXNXaGl0ZVNwYWNlAEluc2VydABFbmRzV2l0aABUcnlQYXJzZQBUb0FycmF5AElzTnVsbE9yRW1wdHkAVG9VcHBlcgBSZWdpc3RyeQBDdXJyZW50VXNlcgBMb2NhbE1hY2hpbmUAQ2xhc3Nlc1Jvb3QAVXNlcnMAQ3VycmVudENvbmZpZwA8PmNfX0Rpc3BsYXlDbGFzczI5AG91dHAARGF0YVJlY2VpdmVkRXZlbnRBcmdzADxSdW5IaWRkZW4+Yl9fMjcAPFJ1bkhpZGRlbj5iX18yOABlMgBnZXRfRGF0YQBBcHBlbmRMaW5lAGdldF9TdGFuZGFyZE91dHB1dEVuY29kaW5nAGdldF9EZWZhdWx0AHNldF9TdGFuZGFyZE91dHB1dEVuY29kaW5nAHNldF9TdGFuZGFyZEVycm9yRW5jb2RpbmcARGF0YVJlY2VpdmVkRXZlbnRIYW5kbGVyAGFkZF9PdXRwdXREYXRhUmVjZWl2ZWQAYWRkX0Vycm9yRGF0YVJlY2VpdmVkAEJlZ2luT3V0cHV0UmVhZExpbmUAQmVnaW5FcnJvclJlYWRMaW5lAEdldFRlbXBQYXRoAEd1aWQATmV3R3VpZABEZWxldGUAPD5jX19EaXNwbGF5Q2xhc3MzMQBNZXNzYWdlQm94QnV0dG9ucwBidG5zAE1lc3NhZ2VCb3hEZWZhdWx0QnV0dG9uAGRlZgA8RXhlY1Rvb2xTdGVwPmJfXzMwAE1lc3NhZ2VCb3hJY29uAEZ1bmNgMQBEZWxlZ2F0ZQBQYXJzZQBTbGVlcABHZXRQcm9jZXNzZXNCeU5hbWUAS2lsbABJbnQ2NABCeXRlAENvbnZlcnQAVG9CeXRlAENyZWF0ZVN1YktleQBSZWdpc3RyeVZhbHVlS2luZABTZXRWYWx1ZQBPcGVuU3ViS2V5AERlbGV0ZVZhbHVlAERlbGV0ZVN1YktleVRyZWUAVHJpbUVuZABHZXREaXJlY3RvcnlOYW1lAEdldEZpbGVOYW1lAEdldEZpbGVzAEdldERpcmVjdG9yaWVzAEFjdGl2YXRlAFN5c3RlbS5OZXQuTmV0d29ya0luZm9ybWF0aW9uAFBpbmcAUGluZ1JlcGx5AFNlbmQASVBTdGF0dXMAZ2V0X1N0YXR1cwBTeXN0ZW0uTmV0AElQQWRkcmVzcwBnZXRfQWRkcmVzcwBnZXRfUm91bmR0cmlwVGltZQBQaW5nT3B0aW9ucwBnZXRfT3B0aW9ucwBnZXRfVHRsAGdldF9CdWZmZXIARm9ybWF0AFN0b3B3YXRjaABTdGFydE5ldwBTeXN0ZW0uTmV0LlNvY2tldHMAVGNwQ2xpZW50AEJlZ2luQ29ubmVjdABXYWl0SGFuZGxlAGdldF9Bc3luY1dhaXRIYW5kbGUAV2FpdE9uZQBFbmRDb25uZWN0AGdldF9FbGFwc2VkTWlsbGlzZWNvbmRzAFR5cGUAR2V0VHlwZQBNZW1iZXJJbmZvAGdldF9OYW1lAEdldEFkZHJlc3NCeXRlcwBQYWRMZWZ0AE1hdGgATWluAF9fU3RhdGljQXJyYXlJbml0VHlwZVNpemU9NTYAJCRtZXRob2QweDYwMDAwMzEtMQBQYWRSaWdodABEbnMAR2V0SG9zdE5hbWUATmV0d29ya0ludGVyZmFjZQBHZXRBbGxOZXR3b3JrSW50ZXJmYWNlcwBPcGVyYXRpb25hbFN0YXR1cwBnZXRfT3BlcmF0aW9uYWxTdGF0dXMATmV0d29ya0ludGVyZmFjZVR5cGUAZ2V0X05ldHdvcmtJbnRlcmZhY2VUeXBlAElQSW50ZXJmYWNlUHJvcGVydGllcwBHZXRJUFByb3BlcnRpZXMAVW5pY2FzdElQQWRkcmVzc0luZm9ybWF0aW9uQ29sbGVjdGlvbgBnZXRfVW5pY2FzdEFkZHJlc3NlcwBJRW51bWVyYXRvcmAxAFVuaWNhc3RJUEFkZHJlc3NJbmZvcm1hdGlvbgBJUEFkZHJlc3NJbmZvcm1hdGlvbgBBZGRyZXNzRmFtaWx5AGdldF9BZGRyZXNzRmFtaWx5AGdldF9JUHY0TWFzawBTeXN0ZW0uQ29sbGVjdGlvbnMASUVudW1lcmF0b3IAR2F0ZXdheUlQQWRkcmVzc0luZm9ybWF0aW9uQ29sbGVjdGlvbgBnZXRfR2F0ZXdheUFkZHJlc3NlcwBHYXRld2F5SVBBZGRyZXNzSW5mb3JtYXRpb24ASVBBZGRyZXNzQ29sbGVjdGlvbgBnZXRfRG5zQWRkcmVzc2VzACQkbWV0aG9kMHg2MDAwMDMzLTEAUmFuZG9tAE5leHQATWVtb3J5U3RyZWFtAFN0cmVhbQBnZXRfQVNDSUkAR2V0Qnl0ZXMAV3JpdGUAVWRwQ2xpZW50AFNvY2tldABnZXRfQ2xpZW50AHNldF9SZWNlaXZlVGltZW91dABBbnkASVBFbmRQb2ludABSZWNlaXZlAENvcHkAR2V0U3RyaW5nAFdlYlJlcXVlc3QAQ3JlYXRlAEh0dHBXZWJSZXF1ZXN0AHNldF9UaW1lb3V0AHNldF9SZWFkV3JpdGVUaW1lb3V0AHNldF9Vc2VyQWdlbnQAV2ViUmVzcG9uc2UAR2V0UmVzcG9uc2UASHR0cFdlYlJlc3BvbnNlAFVyaQBnZXRfUmVzcG9uc2VVcmkAb3BfSW5lcXVhbGl0eQBnZXRfSG9zdABIdHRwU3RhdHVzQ29kZQBnZXRfU3RhdHVzQ29kZQBnZXRfU3RhdHVzRGVzY3JpcHRpb24AV2ViSGVhZGVyQ29sbGVjdGlvbgBnZXRfSGVhZGVycwBTeXN0ZW0uQ29sbGVjdGlvbnMuU3BlY2lhbGl6ZWQATmFtZVZhbHVlQ29sbGVjdGlvbgBnZXRfQ29udGVudFR5cGUAR2V0UmVzcG9uc2VTdHJlYW0AUmVhZABXZWJFeGNlcHRpb24AZ2V0X1Jlc3BvbnNlAFN0cmVhbVJlYWRlcgBUZXh0UmVhZGVyAFJlYWRUb0VuZABSZW1vdmUAUmVtb3ZlQXQAZ2V0X1IAZ2V0X0cAZ2V0X0IATWF4AFJvdW5kAFJlZ2V4T3B0aW9ucwBXcml0ZUFsbExpbmVzADw+Y19fRGlzcGxheUNsYXNzMzYAPD5jX19EaXNwbGF5Q2xhc3MzOQA8UnVuUGx1Z2luPmJfXzM0AENTJDw+OF9fbG9jYWxzMzcAZXJycwBhYm9ydGVkADxSdW5QbHVnaW4+Yl9fMzUAQWN0aW9uAEFzc2VtYmx5TmFtZQBMb2FkAGdldF9Mb2NhdGlvbgBNaWNyb3NvZnQuQ1NoYXJwAENTaGFycENvZGVQcm92aWRlcgBTeXN0ZW0uQ29kZURvbS5Db21waWxlcgBDb21waWxlclBhcmFtZXRlcnMAc2V0X0dlbmVyYXRlSW5NZW1vcnkAc2V0X0dlbmVyYXRlRXhlY3V0YWJsZQBTdHJpbmdDb2xsZWN0aW9uAGdldF9SZWZlcmVuY2VkQXNzZW1ibGllcwBBZGRSYW5nZQBDb2RlRG9tUHJvdmlkZXIAQ29tcGlsZXJSZXN1bHRzAENvbXBpbGVBc3NlbWJseUZyb21Tb3VyY2UAQ29tcGlsZXJFcnJvckNvbGxlY3Rpb24AZ2V0X0Vycm9ycwBnZXRfSGFzRXJyb3JzAENvbGxlY3Rpb25CYXNlAENvbXBpbGVyRXJyb3IAZ2V0X0xpbmUAZ2V0X0Vycm9yVGV4dABnZXRfQ29tcGlsZWRBc3NlbWJseQBHZXRUeXBlcwBFbXB0eVR5cGVzAEJpbmRpbmdGbGFncwBCaW5kZXIAUGFyYW1ldGVyTW9kaWZpZXIAR2V0TWV0aG9kAGdldF9SZXR1cm5UeXBlAFZvaWQAUnVudGltZVR5cGVIYW5kbGUAR2V0VHlwZUZyb21IYW5kbGUAPD5jX19EaXNwbGF5Q2xhc3MzZQBwYwA8UnVuQ29kZVBsdWdpbj5iX18zYwBNZXRob2RCYXNlAEdldEJhc2VFeGNlcHRpb24APEVuc3VyZVBsdWdpblRocmVhZD5iX180MABDUyQ8PjlfX0NhY2hlZEFub255bW91c01ldGhvZERlbGVnYXRlNDEAQXBhcnRtZW50U3RhdGUAU2V0QXBhcnRtZW50U3RhdGUAc2V0X05hbWUALmNjdG9yAFN5c3RlbS5HbG9iYWxpemF0aW9uAEN1bHR1cmVJbmZvAGdldF9DdXJyZW50VUlDdWx0dXJlAERsbEltcG9ydEF0dHJpYnV0ZQB1c2VyMzIuZGxsAENvbnRhaW5zS2V5AGdldF9Nc2cAZ2V0X1dQYXJhbQBJbnRQdHIAVG9JbnQzMgA8PmNfX0Rpc3BsYXlDbGFzczZhADwuY3Rvcj5iX181NAA8PmNfX0Rpc3BsYXlDbGFzczZjAENTJDw+OF9fbG9jYWxzNmIAcmcAY2xvc2UAY2FyZAA8LmN0b3I+Yl9fNGEAPC5jdG9yPmJfXzRiADwuY3Rvcj5iX180ZAA8LmN0b3I+Yl9fNGUAPC5jdG9yPmJfXzUwADwuY3Rvcj5iX181MgA8LmN0b3I+Yl9fNWEAY2FwMgA8LmN0b3I+Yl9fNDkAPC5jdG9yPmJfXzRjADwuY3Rvcj5iX180ZgA8LmN0b3I+Yl9fNTEAPC5jdG9yPmJfXzUzADwuY3Rvcj5iX181NQA8LmN0b3I+Yl9fNTYAPC5jdG9yPmJfXzU3ADwuY3Rvcj5iX181OAA8LmN0b3I+Yl9fNTkAPC5jdG9yPmJfXzViAEtleUV2ZW50QXJncwA8LmN0b3I+Yl9fNWMAZ2V0X1dpZHRoAGdldF9IZWlnaHQARW1wdHkAZ2V0X0dyYXBoaWNzAFBlbgBEcmF3UGF0aABzZXRfQmFja0NvbG9yAGdldF9XaGl0ZQBzZXRfRm9yZUNvbG9yAENsb3NlAERyYXdMaW5lAE1vdXNlQnV0dG9ucwBnZXRfQnV0dG9uAG9wX0V4cGxpY2l0AFplcm8Ac2V0X0ZvbnQAc2V0X0xvY2F0aW9uAFNpemUAc2V0X1NpemUAQ29udHJvbENvbGxlY3Rpb24AZ2V0X0NvbnRyb2xzAEtleXMAZ2V0X0tleUNvZGUARm9ybUJvcmRlclN0eWxlAHNldF9Gb3JtQm9yZGVyU3R5bGUAQ29udGFpbmVyQ29udHJvbABBdXRvU2NhbGVNb2RlAHNldF9BdXRvU2NhbGVNb2RlAEZvcm1TdGFydFBvc2l0aW9uAHNldF9TdGFydFBvc2l0aW9uAHNldF9Ub3BNb3N0AHNldF9LZXlQcmV2aWV3AHNldF9DbGllbnRTaXplAGFkZF9IYW5kbGVDcmVhdGVkAGFkZF9SZXNpemUAUGFpbnRFdmVudEhhbmRsZXIAYWRkX1BhaW50AHNldF9BdXRvU2l6ZQBDb250ZW50QWxpZ25tZW50AHNldF9UZXh0QWxpZ24AQ3Vyc29ycwBnZXRfSGFuZABzZXRfQ3Vyc29yAGFkZF9Nb3VzZUVudGVyAGFkZF9Nb3VzZUxlYXZlAE1vdXNlRXZlbnRIYW5kbGVyAGFkZF9Nb3VzZURvd24AQWN0aW9uYDMAUGFkZGluZwBzZXRfUGFkZGluZwBEb2NrU3R5bGUAc2V0X0RvY2sAVmlldwBzZXRfVmlldwBzZXRfRnVsbFJvd1NlbGVjdABzZXRfTXVsdGlTZWxlY3QAc2V0X0hpZGVTZWxlY3Rpb24AQm9yZGVyU3R5bGUAc2V0X0JvcmRlclN0eWxlAENvbHVtbkhlYWRlckNvbGxlY3Rpb24AZ2V0X0NvbHVtbnMAQ29sdW1uSGVhZGVyAGFkZF9Eb3VibGVDbGljawBLZXlFdmVudEhhbmRsZXIAYWRkX0tleURvd24AQmVnaW5VcGRhdGUATGlzdFZpZXdJdGVtQ29sbGVjdGlvbgBTdHJpbmdDb21wYXJpc29uAEVxdWFscwBMaXN0Vmlld0l0ZW0ATGlzdFZpZXdTdWJJdGVtQ29sbGVjdGlvbgBnZXRfU3ViSXRlbXMATGlzdFZpZXdTdWJJdGVtAHNldF9UYWcAZ2V0X0dyYXkARW5kVXBkYXRlAElXaW4zMldpbmRvdwBTZWxlY3RlZExpc3RWaWV3SXRlbUNvbGxlY3Rpb24AZ2V0X1NlbGVjdGVkSXRlbXMAZ2V0X1RhZwBEYXRlVGltZQBnZXRfTm93AGdldF9HZW5lcmljU2Fuc1NlcmlmAGdkaTMyLmRsbAA8PmNfX0Rpc3BsYXlDbGFzczk1AHRhYkJ0bnMAPC5jdG9yPmJfXzdlADwuY3Rvcj5iX183ZgA8LmN0b3I+Yl9fODEAPC5jdG9yPmJfXzgyADwuY3Rvcj5iX184NAA8PmNfX0Rpc3BsYXlDbGFzczk3AENTJDw+OF9fbG9jYWxzOTYAPC5jdG9yPmJfXzg2ADwuY3Rvcj5iX183ZAA8LmN0b3I+Yl9fODAAPC5jdG9yPmJfXzgzADwuY3Rvcj5iX184NQA8LmN0b3I+Yl9fODcAczIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTkwADwuY3Rvcj5iX184OAA8LmN0b3I+Yl9fODkAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTkyADwuY3Rvcj5iX184YQA8LmN0b3I+Yl9fOGIASW52YWxpZGF0ZQBzZXRfQ2FwdHVyZQBSZW1vdmVNZXNzYWdlRmlsdGVyAHNldF9XaWR0aABhZGRfTW91c2VNb3ZlAGFkZF9Nb3VzZVVwAFRleHRCb3hCYXNlAHNldF9NdWx0aWxpbmUAc2V0X1JlYWRPbmx5AFNjcm9sbEJhcnMAc2V0X1Njcm9sbEJhcnMAQWRkTWVzc2FnZUZpbHRlcgBGb3JtQ2xvc2VkRXZlbnRIYW5kbGVyAGFkZF9Gb3JtQ2xvc2VkAFBvaW50VG9DbGllbnQAZ2V0X1Zpc2libGUAZ2V0X0JvdW5kcwBTeXN0ZW0uV2luZG93cy5Gb3Jtcy5MYXlvdXQAQXJyYW5nZWRFbGVtZW50Q29sbGVjdGlvbgBnZXRfVG9wAHNldF9Ub3AAZ2V0X0ZvbnQAVGV4dFJlbmRlcmVyAE1lYXN1cmVUZXh0AGdldF9DbGllbnRTaXplADw+Y19fRGlzcGxheUNsYXNzOWIAPExvZz5iX185OQBnZXRfSW52b2tlUmVxdWlyZWQAQXBwZW5kVGV4dAA8PmNfX0Rpc3BsYXlDbGFzczlmAGJ0bgA8UnVuQWN0aW9uPmJfXzlkADxSdW5BY3Rpb24+Yl9fOWUAc2V0X0RvdWJsZUJ1ZmZlcmVkAFRvSW50NjQAZ2V0X1BhcmVudABnZXRfQmFja0NvbG9yAGdldF9DbGllbnRSZWN0YW5nbGUARmlsbFJlY3RhbmdsZQBnZXRfRW5hYmxlZABnZXRfVGV4dABEcmF3U3RyaW5nADw+Y19fRGlzcGxheUNsYXNzYjgAPC5jdG9yPmJfX2E5ADwuY3Rvcj5iX19hYQA8LmN0b3I+Yl9fYWMAPC5jdG9yPmJfX2FkADwuY3Rvcj5iX19hZgA8PmNfX0Rpc3BsYXlDbGFzc2JhAENTJDw+OF9fbG9jYWxzYjkAPC5jdG9yPmJfX2IxADwuY3Rvcj5iX19hOAA8LmN0b3I+Yl9fYWIAPC5jdG9yPmJfX2FlADwuY3Rvcj5iX19iMAA8LmN0b3I+Yl9fYjIAPD5jX19EaXNwbGF5Q2xhc3NjNgA8PmNfX0Rpc3BsYXlDbGFzc2M4AGNudABjYW5jZWwAPEJ1aWxkUGluZ1RhYj5iX19jMAA8QnVpbGRQaW5nVGFiPmJfX2MzADxCdWlsZFBpbmdUYWI+Yl9fYzQAPEJ1aWxkUGluZ1RhYj5iX19jNQBDUyQ8PjhfX2xvY2Fsc2M3AHN6ADxCdWlsZFBpbmdUYWI+Yl9fYzEAPEJ1aWxkUGluZ1RhYj5iX19jMgBEb3VibGUAQm9vbGVhbgA8PmNfX0Rpc3BsYXlDbGFzc2QwADxCdWlsZFRyYWNlcnRUYWI+Yl9fY2IAPEJ1aWxkVHJhY2VydFRhYj5iX19jZQA8QnVpbGRUcmFjZXJ0VGFiPmJfX2NmADxCdWlsZFRyYWNlcnRUYWI+Yl9fY2MAPEJ1aWxkVHJhY2VydFRhYj5iX19jZAA8PmNfX0Rpc3BsYXlDbGFzc2RhADw+Y19fRGlzcGxheUNsYXNzZGUAdHlwZXMAdG9nZ2xlcwA8QnVpbGREbnNUYWI+Yl9fZDUAPEJ1aWxkRG5zVGFiPmJfX2Q4ADxCdWlsZERuc1RhYj5iX19kOQBDUyQ8PjhfX2xvY2Fsc2RiAG5tAHN2AHRwADxCdWlsZERuc1RhYj5iX19kNgA8QnVpbGREbnNUYWI+Yl9fZDcAPD5jX19EaXNwbGF5Q2xhc3NkYwB0aQA8QnVpbGREbnNUYWI+Yl9fZDQAPD5jX19EaXNwbGF5Q2xhc3NlOAA8PmNfX0Rpc3BsYXlDbGFzc2VhAGdvADxCdWlsZEh0dHBUYWI+Yl9fZTEAPEJ1aWxkSHR0cFRhYj5iX19lNAA8QnVpbGRIdHRwVGFiPmJfX2U1ADxCdWlsZEh0dHBUYWI+Yl9fZTYAPEJ1aWxkSHR0cFRhYj5iX19lNwBDUyQ8PjhfX2xvY2Fsc2U5AHUAPEJ1aWxkSHR0cFRhYj5iX19lMgA8QnVpbGRIdHRwVGFiPmJfX2UzAHNldF9TdXBwcmVzc0tleVByZXNzADw+Y19fRGlzcGxheUNsYXNzZjUAPD5jX19EaXNwbGF5Q2xhc3NmNwA8PmNfX0Rpc3BsYXlDbGFzc2ZhAHNjYW4APEJ1aWxkUG9ydFRhYj5iX19lZAA8QnVpbGRQb3J0VGFiPmJfX2YwADxCdWlsZFBvcnRUYWI+Yl9fZjMAPEJ1aWxkUG9ydFRhYj5iX19mNABDUyQ8PjhfX2xvY2Fsc2Y2ADxCdWlsZFBvcnRUYWI+Yl9fZWUAPEJ1aWxkUG9ydFRhYj5iX19lZgBwb3J0cwA8QnVpbGRQb3J0VGFiPmJfX2YxADxCdWlsZFBvcnRUYWI+Yl9fZjIAX19TdGF0aWNBcnJheUluaXRUeXBlU2l6ZT01MgAkJG1ldGhvZDB4NjAwMDE1My0xADw+Y19fRGlzcGxheUNsYXNzMTA2AG1rAGlwMQBpcDIAPEJ1aWxkU3VibmV0VGFiPmJfXzEwMgA8QnVpbGRTdWJuZXRUYWI+Yl9fMTAzADxCdWlsZFN1Ym5ldFRhYj5iX18xMDQAPEJ1aWxkU3VibmV0VGFiPmJfXzEwNQBhZGRfVGV4dENoYW5nZWQAPD5jX19EaXNwbGF5Q2xhc3MxMGQAPD5jX19EaXNwbGF5Q2xhc3MxMTAAcmVmcmVzaAA8QnVpbGRMb2NhbFRhYj5iX18xMDgAPEJ1aWxkTG9jYWxUYWI+Yl9fMTBiADxCdWlsZExvY2FsVGFiPmJfXzEwYwA8QnVpbGRMb2NhbFRhYj5iX18xMDkAQ1MkPD44X19sb2NhbHMxMGUAaW5mbwA8QnVpbGRMb2NhbFRhYj5iX18xMGEAQ2xpcGJvYXJkAFNldFRleHQAPC5jdG9yPmJfXzExNAA8LmN0b3I+Yl9fMTE1ADwuY3Rvcj5iX18xMTYARm9jdXMAZ2V0X0lCZWFtAGFkZF9FbnRlcgBhZGRfTGVhdmUAZ2V0X0ZvY3VzZWQAPC5jdG9yPmJfXzExZAA8LmN0b3I+Yl9fMTFlADwuY3Rvcj5iX18xMWYAPC5jdG9yPmJfXzEyMAA8LmN0b3I+Yl9fMTIxADwuY3Rvcj5iX18xMjIAU3RvcABDb21wb25lbnQAc2V0X0ludGVydmFsAGFkZF9UaWNrAGFkZF9EaXNwb3NlZAA8PmNfX0Rpc3BsYXlDbGFzczEyYgA8TGluZT5iX18xMjkAU2F2ZUZpbGVEaWFsb2cARmlsZURpYWxvZwBzZXRfRmlsdGVyAENvbW1vbkRpYWxvZwBTaG93RGlhbG9nAGdldF9GaWxlTmFtZQA8LmN0b3I+Yl9fMTMzADwuY3Rvcj5iX18xMzQAPC5jdG9yPmJfXzEzNQA8LmN0b3I+Yl9fMTM2ADwuY3Rvcj5iX18xMzcAc2V0X0ludGVncmFsSGVpZ2h0AHNldF9IZWlnaHQAQnV0dG9uAExpc3RDb250cm9sAGdldF9TZWxlY3RlZEluZGV4AE9iamVjdENvbGxlY3Rpb24AR2V0VGV4dAA8PmNfX0Rpc3BsYXlDbGFzczE2MAA8LmN0b3I+Yl9fMTQ5ADwuY3Rvcj5iX18xNGEAPC5jdG9yPmJfXzE0YgA8LmN0b3I+Yl9fMTRjADw+Y19fRGlzcGxheUNsYXNzMTYyAENTJDw+OF9fbG9jYWxzMTYxAGNpADwuY3Rvcj5iX18xNGUAPC5jdG9yPmJfXzE0ZgA8LmN0b3I+Yl9fMTQ4ADwuY3Rvcj5iX18xNGQAPC5jdG9yPmJfXzE1MAA8LmN0b3I+Yl9fMTUxADwuY3Rvcj5iX18xNTIAPC5jdG9yPmJfXzE1MwA8LmN0b3I+Yl9fMTU0AEZvcm1DbG9zaW5nRXZlbnRBcmdzADwuY3Rvcj5iX18xNTUAPC5jdG9yPmJfXzE1NgBEcmF3RWxsaXBzZQBBZGRFbGxpcHNlAFJlZ2lvbgBzZXRfUmVnaW9uAEZvcm1DbG9zaW5nRXZlbnRIYW5kbGVyAGFkZF9Gb3JtQ2xvc2luZwBTb3J0ZWREaWN0aW9uYXJ5YDIAR2V0RmlsZU5hbWVXaXRob3V0RXh0ZW5zaW9uAHNldF9TZWxlY3Rpb25TdGFydABSZWFkTGluZQA8PmNfX0Rpc3BsYXlDbGFzczE2OQA8UmVidWlsZFRhYnM+Yl9fMTY2ADxSZWJ1aWxkVGFicz5iX18xNjcAYWRkX01vdXNlQ2xpY2sATW92ZQBTdHJpbmdUcmltbWluZwBzZXRfVHJpbW1pbmcAU3RyaW5nRm9ybWF0RmxhZ3MAc2V0X0Zvcm1hdEZsYWdzADwuY3Rvcj5iX18xNzEAPC5jdG9yPmJfXzE3MgA8LmN0b3I+Yl9fMTczADwuY3Rvcj5iX18xNzQATWFyc2hhbABQdHJUb1N0cnVjdHVyZQBDb3B5RnJvbVNjcmVlbgBHZXRQaXhlbABTdHJ1Y3RMYXlvdXRBdHRyaWJ1dGUATGF5b3V0S2luZAAAAAAlTQBpAGMAcgBvAHMAbwBmAHQAIABZAGEASABlAGkAIABVAEkAAAljAHQAcgBsAAAPYwBvAG4AdAByAG8AbAAAB2EAbAB0AAALcwBoAGkAZgB0AAAHdwBpAG4AAAdjAG0AZAAACW0AZQB0AGEAAAVmADEAAAVmADIAAAVmADMAAAVmADQAAAVmADUAAAVmADYAAAVmADcAAAVmADgAAAVmADkAAAdmADEAMAAAB2YAMQAxAAAHZgAxADIAAAtzAHAAYQBjAGUAAAtlAG4AdABlAHIAAAdlAHMAYwAAE2IAYQBjAGsAcwBwAGEAYwBlAAAHdABhAGIAAAtnAHIAYQB2AGUAAAttAGkAbgB1AHMAAAlwAGwAdQBzAAARbABiAHIAYQBjAGsAZQB0AAARcgBiAHIAYQBjAGsAZQB0AAATcwBlAG0AaQBjAG8AbABvAG4AAAtxAHUAbwB0AGUAAAtjAG8AbQBtAGEAAA1wAGUAcgBpAG8AZAAAC3MAbABhAHMAaAAAE2IAYQBjAGsAcwBsAGEAcwBoAAAJcABnAHUAcAAACXAAZwBkAG4AAAloAG8AbQBlAAAHZQBuAGQAAAlsAGUAZgB0AAALcgBpAGcAaAB0AAAFdQBwAAAJZABvAHcAbgAACygAKme+i25/KQABDSgAbgBvAG4AZQApAAALQwB0AHIAbAArAAAJQQBsAHQAKwAADVMAaABpAGYAdAArAAAJVwBpAG4AKwAAC1MAcABhAGMAZQAAC0UAbgB0AGUAcgAAB0UAcwBjAAATQgBhAGMAawBzAHAAYQBjAGUAAAdUAGEAYgAAA2AAAAMtAAEDPQAAA1sAAANdAAADOwAAAycAAQMsAAADLgAAAy8AAANcAAAJUABnAFUAcAAACVAAZwBEAG4AAAlIAG8AbQBlAAAHRQBuAGQAAAlMAGUAZgB0AAALUgBpAGcAaAB0AAAFVQBwAAAJRABvAHcAbgAABTAAeAAAA1gAAA1pAHQAbwBvAGwAcwAAD3AAbAB1AGcAaQBuAHMAABlzAGMAaAB0AGEAcwBrAHMALgBlAHgAZQAAIy8AUQB1AGUAcgB5ACAALwBUAE4AIABXAGcAVAByAGEAeQAAKy8ARABlAGwAZQB0AGUAIAAvAEYAIAAvAFQATgAgAFcAZwBUAHIAYQB5AAAJAF86Z+qBL1QBD1MAdABhAHIAdAB1AHAAABXyXXNR7ZUgACgAoYsSUvtOoVIpAAEVbwBmAGYAIAAoAHQAYQBzAGsAKQAAgLVwAG8AdwBlAHIAcwBoAGUAbABsAC4AZQB4AGUAIAAtAE4AbwBQAHIAbwBmAGkAbABlACAALQBOAG8ATABvAGcAbwAgAC0AUwBUAEEAIAAtAFcAaQBuAGQAbwB3AFMAdAB5AGwAZQAgAEgAaQBkAGQAZQBuACAALQBFAHgAZQBjAHUAdABpAG8AbgBQAG8AbABpAGMAeQAgAEIAeQBwAGEAcwBzACAALQBGAGkAbABlACAAIgABAyIAAAVcACIAAE0vAEMAcgBlAGEAdABlACAALwBGACAALwBUAE4AIABXAGcAVAByAGEAeQAgAC8AUwBDACAATwBOAEwATwBHAE8ATgAgAC8AVABSACAAACPyXQBfL1QgACgAoYsSUvtOoVIsACAAe3ZVX/ZlL1SoUikAASdvAG4AIAAoAHQAYQBzAGsALAAgAGEAdAAgAGwAbwBnAG8AbgApAAANAF86Z+qBL1QxWSWNAR1TAHQAYQByAHQAdQBwACAAZgBhAGkAbABlAGQAAIPjOwAgAFcAZwBUAHIAYQB5ACAATZFuf4dl9k4gACgAVQBUAEYALQA4ACwAIAAOTiAAdwBnAHQAcgBhAHkALgBiAGEAdAAgAAxU7nZVXykADQAKADsAIABhAHAAcAA6ACAAWGLYdtyDVVMgAC0APgAgAJReKHUgAMyRhHZhZ+52LAAgABZ/AXg8AFQAQQBCAD4ADVTweTwAVABBAEIAPgB9VOROWwA8AFQAQQBCAD4AwlNwZV0AIAAoAAZSlJYme19OpWPXU3p6PGgsACAAK1R6ejxohHZ9VOROKHUVX/dTBVNPTzsADQAKADsAIAAgACAAIAAgACAA+Hb5W++NhF8JYyAAdwBnAHQAcgBhAHkALgBiAGEAdAAgAEBiKFfudlVf44mQZywAIAAvZQFjIAAlAK9zg1jYU8+RJQApAA0ACgA7ACAAYQBwAHAAIAA9ACAAbgBwAAkAsIuLTixnCQBuAG8AdABlAHAAYQBkAC4AZQB4AGUADQAKADsAIABhAHAAcAAgAD0AIABnAHkACQDTTpNe7nZVXwkAQwA6AFwAVABvAG8AbABzAFwAVwBnAEkAbQBlAA0ACgA7ACAAYQBwAHAAIAA9ACAAYgBkAAkAfnamXgkAaAB0AHQAcABzADoALwAvAHcAdwB3AC4AYgBhAGkAZAB1AC4AYwBvAG0ADQAKADsAIABoUUBc6193Yy6VIAAoADxoD186ACAAYwB0AHIAbAAvAGEAbAB0AC8AcwBoAGkAZgB0AC8AdwBpAG4AIADEfghULAAgAIJZIABjAHQAcgBsACsAYQBsAHQAKwB0ADsAIABuAG8AbgBlAC8AbwBmAGYAIACBeSh1KQA6AA0ACgA7ACAAaABvAHQAawBlAHkAXwB0AG8AbwBsAGIAbwB4ACAAPQAgAGMAdAByAGwAKwBhAGwAdAArAHQAIAAgACAAU2IAX+Vdd1Gxew0ACgA7ACAAaABvAHQAawBlAHkAXwBwAGwAdQBnAGkAbgBzACAAPQAgAGMAdAByAGwAKwBhAGwAdAArAHAAIAAgACAAU2IAX9Jj9k6hewZ0DQAKADsAIABoAG8AdABrAGUAeQBfAG0AZQBuAHUAIAAgACAAIAA9ACAAYwB0AHIAbAArAGEAbAB0ACsAdwAgACAAIAAoV0lRB2gEWT5mOnlYYth23INVUw0ACgA7ACAAKABXAGcASQBtAGUAIACEdiAAZgB1AHoAegB5AC8AcABhAHMAdABlAC8AawBlAHkAZgBpAHgAIABJe5OPZVHVbE2Rbn8sZ+Vdd1ENTn9PKHUsACAAWXVAdw1OcV/NVCkADQAKAAEH5V13UbF7AQ9UAG8AbwBsAGIAbwB4AAAbYgB1AGkAbAB0AGkAbgA6AHQAbwBvAGwAcwAAAQALdABvAG8AbABzAAAHbgBlAHQAAAlRf9x+5V13UQEbTgBlAHQAdwBvAHIAawAgAHQAbwBvAGwAcwAAIWIAdQBpAGwAdABpAG4AOgBuAGUAdAB0AG8AbwBsAHMAAAl3AGwAZwBqAAAJYwBsAGkAcAAAC2pSNI1/Z4ZT8lMBI0MAbABpAHAAYgBvAGEAcgBkACAAaABpAHMAdABvAHIAeQAAGWIAdQBpAGwAdABpAG4AOgBjAGwAaQBwAAAHagBsAGIAAAViAGoAAAW/T357ARlTAHQAaQBjAGsAeQAgAG4AbwB0AGUAcwAAGWIAdQBpAGwAdABpAG4AOgBuAG8AdABlAAALbgBvAHQAZQBzAAAFeQBzAAAJnJhygv5i1lMBGUMAbwBsAG8AcgAgAHAAaQBjAGsAZQByAAAbYgB1AGkAbAB0AGkAbgA6AGMAbwBsAG8AcgAAC2MAbwBsAG8AcgAACdJj9k6hewZ0AR1QAGwAdQBnAGkAbgAgAG0AYQBuAGEAZwBlAHIAACNiAHUAaQBsAHQAaQBuADoAcABsAHUAZwBpAG4AbQBnAHIAAAljAGoAZwBsAAAVYwB0AHIAbAArAGEAbAB0ACsAdAAAFWMAdAByAGwAKwBhAGwAdAArAHAAABVjAHQAcgBsACsAYQBsAHQAKwB3AAAVYwBvAG4AZgBpAGcALgB0AHgAdAAAB2EAcABwAABfXgAoAFwAUwArACkAXABzACsAKABcAFMAKwApAFwAcwArACgAIgAoAD8AOgBbAF4AIgBdACoAKQAiAHwAXABTACsAKQAoAD8AOgBcAHMAKwAoAC4AKgApACkAPwAkAAAdaABvAHQAawBlAHkAXwB0AG8AbwBsAGIAbwB4AAAdaABvAHQAawBlAHkAXwBwAGwAdQBnAGkAbgBzAAAXaABvAHQAawBlAHkAXwBtAGUAbgB1AAAHagBzAHEAAAljAGEAbABjAAAJ5V13UbF7JiABEVQAbwBvAGwAYgBvAHgAJiABBdJj9k4BD1AAbAB1AGcAaQBuAHMAAAmFUW5/5V13UQEdQgB1AGkAbAB0AC0AaQBuACAAdABvAG8AbABzAAEHoYuXe2hWARVDAGEAbABjAHUAbABhAHQAbwByAAAflF4odSAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAASNBAHAAcABzACAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAAAVNkW5/AQ1DAG8AbgBmAGkAZwAAJRZ/kY9NkW5/IAAoAGMAbwBuAGYAaQBnAC4AdAB4AHQAKQAmIAEzRQBkAGkAdAAgAGMAbwBuAGYAaQBnACAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAJiABCc2RfY9NkW5/ARtSAGUAbABvAGEAZAAgAGMAbwBuAGYAaQBnAAAlUwB0AGEAcgB0ACAAdwBpAHQAaAAgAFcAaQBuAGQAbwB3AHMAAAtwZW5j7nZVXyYgARlEAGEAdABhACAAZgBvAGwAZABlAHIAJiABC2hRQFzrX3djLpUBHUcAbABvAGIAYQBsACAAaABvAHQAawBlAHkAcwAASyhXIABjAG8AbgBmAGkAZwAuAHQAeAB0ACAAhHYgAGgAbwB0AGsAZQB5AF8AKgAgAC6V7k85ZSAAKABuAG8AbgBlACAAgXkodSkAAWVlAGQAaQB0ACAAaABvAHQAawBlAHkAXwAqACAAawBlAHkAcwAgAGkAbgAgAGMAbwBuAGYAaQBnAC4AdAB4AHQAIAAoAG4AbwBuAGUAIAB0AG8AIABkAGkAcwBhAGIAbABlACkAAAUAkPpRAQlFAHgAaQB0AAALU2IAX+Vdd1GxewEZTwBwAGUAbgAgAHQAbwBvAGwAYgBvAHgAAAc6ACAAIAAADT5mOnlYYth23INVUwEdUwBoAG8AdwAgAHQAcgBhAHkAIABtAGUAbgB1AAAPcABsAHUAZwBpAG4AOgAAF2MAbwBkAGUAcABsAHUAZwBpAG4AOgAAByAAIAAoAAADKQAALygA4GXSY/ZOIAAUICAAPmUgAHAAbAB1AGcAaQBuAHMAXAAqAC4AdAB4AHQAKQABQSgAbgBvACAAcABsAHUAZwBpAG4AcwAgABQgIABwAHUAdAAgAHAAbAB1AGcAaQBuAHMAXAAqAC4AdAB4AHQAKQABC9Jj9k6hewZ0JiABH1AAbAB1AGcAaQBuACAAbQBhAG4AYQBnAGUAcgAmIAERYgB1AGkAbAB0AGkAbgA6AABFKADgZSAAFCAgAGMAbwBuAGYAaQBnAC4AdAB4AHQAIADMkaBSIABhAHAAcAAgAD0AIAAWfwF4IAANVPB5IAB9VOROKQABaSgAbgBvAG4AZQAgABQgIABhAGQAZAAgACcAYQBwAHAAIAA9ACAAYwBvAGQAZQAgAG4AYQBtAGUAIABjAG8AbQBtAGEAbgBkACcAIABpAG4AIABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAAQt3AGcAaQBtAGUAAClXAGcAVAByAGEAeQBTAGkAbgBnAGwAZQBJAG4AcwB0AGEAbgBjAGUAADNXAGcAVAByAGEAeQAgAPJdKFfQj0yIIAAUICAA94tIUc5OWGLYdgCQ+lHnZZ5bi08CMAGAjVcAZwBUAHIAYQB5ACAAaQBzACAAYQBsAHIAZQBhAGQAeQAgAHIAdQBuAG4AaQBuAGcAIAAUICAAZQB4AGkAdAAgAHQAaABlACAAbwBsAGQAIABpAG4AcwB0AGEAbgBjAGUAIABmAHIAbwBtACAAdABoAGUAIAB0AHIAYQB5ACAAZgBpAHIAcwB0AC4AAQ1XAGcAVAByAGEAeQAAA+VdAQNUAAAFYABuAAALdABvAG8AbAA6AAAHOgAvAC8AAAkvVKhSMVkljQEbTABhAHUAbgBjAGgAIABmAGEAaQBsAGUAZAAABToAIAAAFXMAaABlAGwAbABiAGwAbwBjAGsAAA9wAHMAYgBsAG8AYwBrAAAXcwBoAGUAbABsAGIAbABvAGMAawB4AAARcABzAGIAbABvAGMAawB4AAALYQBiAG8AcgB0AAAJjFsQYiwAIAABEy0ALQAgAGQAbwBuAGUALAAgAAETIAAqTmVrpJoxWSWNIAAtAC0AASUgAHMAdABlAHAAKABzACkAIABmAGEAaQBsAGUAZAAgAC0ALQABBYxbEGIBFS0ALQAgAGQAbwBuAGUAIAAtAC0AAQfyXdZTiG0BGy0ALQAgAGEAYgBvAHIAdABlAGQAIAAtAC0AAQcgAHwAIAAABeVdd1EBCVQAbwBvAGwAADNuAG8AIAB0AG8AbwBsACAAYQBjAHQAaQBvAG4AIABmAG8AcgAgAGMAbwBkAGUAOgAgAAATdABvAG8AbABzAC4AdAB4AHQAAAMKAAAPWwBzAGgAZQBsAGwAXQAAC1sAYwBtAGQAXQAAGVsAcABvAHcAZQByAHMAaABlAGwAbABdAAAJWwBwAHMAXQAAG1sALwBwAG8AdwBlAHIAcwBoAGUAbABsAF0AAAtbAC8AcABzAF0AABFbAHMAaABlAGwAbAB4AF0AAA1bAGMAbQBkAHgAXQAAG1sAcABvAHcAZQByAHMAaABlAGwAbAB4AF0AAAtbAHAAcwB4AF0AAAl0AGEAYgAgAAADPwAAC2MAbwBsAHMAIAAAC1QAbwBvAGwAcwAAD2IAdQB0AHQAbwBuACAAAAljAG8AZABlAAAH5V13UToAAQlIAEsAQwBVAAAjSABLAEUAWQBfAEMAVQBSAFIARQBOAFQAXwBVAFMARQBSAAAJSABLAEwATQAAJUgASwBFAFkAXwBMAE8AQwBBAEwAXwBNAEEAQwBIAEkATgBFAAAJSABLAEMAUgAAI0gASwBFAFkAXwBDAEwAQQBTAFMARQBTAF8AUgBPAE8AVAAAB0gASwBVAAAVSABLAEUAWQBfAFUAUwBFAFIAUwAACUgASwBDAEMAACdIAEsARQBZAF8AQwBVAFIAUgBFAE4AVABfAEMATwBOAEYASQBHAAAVYgBhAGQAIABoAGkAdgBlADoAIAAADyAAIABvAHUAdAA6ACAAAA8gACAAZQB4AGkAdAAgAAAVZQB4AGkAdAAgAGMAbwBkAGUAIAAAF3cAZwBpAG0AZQAtAHQAbwBvAGwALQABA04AAAdtAHMAZwAAD2MAbwBuAGYAaQByAG0AAAt0AGkAdABsAGUAAA9iAHUAdAB0AG8AbgBzAAAFbwBrAAARbwBrAGMAYQBuAGMAZQBsAAAPZABlAGYAYQB1AGwAdAAAAzEAAAl3AGEAaQB0AAAJawBpAGwAbAAAEyAAIABrAGkAbABsAGUAZAAgAAAHIAB4ACAAAAdyAHUAbgAAC3MAaABlAGwAbAAAD2MAbQBkAC4AZQB4AGUAAAcvAGMAIAAACS4AYwBtAGQAAAkuAHAAcwAxAAAdcABvAHcAZQByAHMAaABlAGwAbAAuAGUAeABlAABTLQBOAG8AUAByAG8AZgBpAGwAZQAgAC0ARQB4AGUAYwB1AHQAaQBvAG4AUABvAGwAaQBjAHkAIABCAHkAcABhAHMAcwAgAC0ARgBpAGwAZQAgAAFnWwBDAG8AbgBzAG8AbABlAF0AOgA6AE8AdQB0AHAAdQB0AEUAbgBjAG8AZABpAG4AZwAgAD0AIABbAFQAZQB4AHQALgBFAG4AYwBvAGQAaQBuAGcAXQA6ADoAVQBUAEYAOAANAAoAAA1zAGgAZQBsAGwAeAAAIQ0ACgBlAGMAaABvAC4ADQAKAHAAYQB1AHMAZQANAAoAAGcNAAoAVwByAGkAdABlAC0ASABvAHMAdAAgACcAJwANAAoAUgBlAGEAZAAtAEgAbwBzAHQAIAAnAHAAcgBlAHMAcwAgAEUATgBUAEUAUgAgAHQAbwAgAGMAbABvAHMAZQAnAA0ACgABCW8AcABlAG4AAA9yAGUAZwAtAHMAZQB0AAEDIAAAC2QAdwBvAHIAZAAAC3EAdwBvAHIAZAAADWUAeABwAGEAbgBkAAALbQB1AGwAdABpAAANYgBpAG4AYQByAHkAAA9yAGUAZwAtAGQAZQBsAAERZgBpAGwAZQAtAGQAZQBsAAE/cgBlAGYAdQBzAGUAIAB0AG8AIABkAGUAbABlAHQAZQAgAGEAIABkAHIAaQB2AGUAIAByAG8AbwB0ADoAIAAAESAAIABzAGsAaQBwADoAIAAAFSAAIABkAGUAbABlAHQAZQBkACAAABUsACAAcwBrAGkAcABwAGUAZAAgAAAlIAAoAGkAbgAgAHUAcwBlACAALwAgAGwAbwBjAGsAZQBkACkAAAttAGsAZABpAHIAAB11AG4AawBuAG8AdwBuACAAdgBlAHIAYgA6ACAAAFV0AG8AbwBsAHMALgB0AHgAdAAgADpOenoWYg1OWFsoVxQgFCAoVyAAdwBnAGkAbQBlAC4AYgBhAHQAIAAMVO52VV/6XgBOKk5zU+9T+22gUp9S/YABa3QAbwBvAGwAcwAuAHQAeAB0ACAAbQBpAHMAcwBpAG4AZwAvAGUAbQBwAHQAeQAgAC0AIABjAHIAZQBhAHQAZQAgAGkAdAAgAG4AZQB4AHQAIAB0AG8AIAB3AGcAaQBtAGUALgBiAGEAdAABWXIAZQBwAGwAeQAgAGYAcgBvAG0AIAB7ADAAfQA6ACAAdABpAG0AZQA9AHsAMQB9AG0AcwAgAHQAdABsAD0AewAyAH0AIABiAHkAdABlAHMAPQB7ADMAfQAAEXMAdABhAHQAdQBzADoAIAAAD2UAcgByAG8AcgA6ACAAAAUgACAAABVtAHMAIAAgACgAZABvAG4AZQApAAAFbQBzAAATIAAgAGUAcgByAG8AcgA6ACAAACFjAGwAbwBzAGUAZAAgACgAdABpAG0AZQBvAHUAdAAgAAAHbQBzACkAAA1vAHAAZQBuACAAIAAAEWMAbABvAHMAZQBkACAAKAAAE0kAUAB2ADQAIABvAG4AbAB5AAALqWMBeA1O3o/tfgEnbgBvAG4ALQBjAG8AbgB0AGkAZwB1AG8AdQBzACAAbQBhAHMAawABFWIAYQBkACAAcAByAGUAZgBpAHgAAAsqZwdjmlswV0BXARd1AG4AcwBwAGUAYwBpAGYAaQBlAGQAAB/eVq9zMFdAVyAAKABsAG8AbwBwAGIAYQBjAGsAKQABEWwAbwBvAHAAYgBhAGMAawAAHcF5CWcwV0BXIAAoAFIARgBDADEAOQAxADgAKQABI3AAcgBpAHYAYQB0AGUAIAAoAFIARgBDADEAOQAxADgAKQAAGf6U740sZzBXIAAoAEEAUABJAFAAQQApAAElbABpAG4AawAtAGwAbwBjAGEAbAAgACgAQQBQAEkAUABBACkAASHQjyWERlWnfiAATgBBAFQAIAAoAEMARwBOAEEAVAApAAEjYwBhAHIAcgBpAGUAcgAtAGcAcgBhAGQAZQAgAE4AQQBUAAEdxH6tZCAAKABtAHUAbAB0AGkAYwBhAHMAdAApAAETbQB1AGwAdABpAGMAYQBzAHQAABvdT1l1IAAoAHIAZQBzAGUAcgB2AGUAZAApAAERcgBlAHMAZQByAHYAZQBkAAAJbFFRfzBXQFcBDXAAdQBiAGwAaQBjAAADQQAAA0IAAANDAAADRAAAA0UAAAWpYwF4AQlNAGEAcwBrAAATOgAgACAAIAAgACAAIAAgACAAAAkgACAAKAAvAAAHGpBNkSZ7ARFXAGkAbABkAGMAYQByAGQAAAs6ACAAIAAgACAAAAlRf9x+MFdAVwEPTgBlAHQAdwBvAHIAawAACToAIAAgACAAAAl/Xq1kMFdAVwETQgByAG8AYQBkAGMAYQBzAHQAAAnvUyh1A4P0VgEVSABvAHMAdAAgAHIAYQBuAGcAZQAAByAALQAgAAEL71ModTtOOmdwZQELSABvAHMAdABzAAANOgAgACAAIAAgACAAAAkwV0BXe3yLVwEJVAB5AHAAZQAADzoAIAAgACAAIAAgACAAAAV7fCtSAQtDAGwAYQBzAHMAAAeMTtuPNlIBDUIAaQBuAGEAcgB5AAAbxmKXXypZjniGTiAAKAA7TjpncGUNTrONKQABQXQAbwBvACAAbQBhAG4AeQAgAHMAdQBiAG4AZQB0AHMAIAAoAG4AbwAgAGgAbwBzAHQAcwAgAGwAZQBmAHQAKQAABcZiBlIBC3MAcABsAGkAdAAAByAAOk4gAAENIABpAG4AdABvACAAAAkgACpOIAAvAAEJIAB4ACAALwAAAzoAAAcgACAAIAAACSAAIAAgACgAAEVNUgB/IAAgACAAIACpYwF4IAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAO9TKHU7TjpnIAAgACAAIAAgABqQTZEmewFbcAByAGUAZgBpAHgAIAAgAG0AYQBzAGsAIAAgACAAIAAgACAAIAAgACAAIAAgACAAaABvAHMAdABzACAAIAAgACAAIAAgACAAIAB3AGkAbABkAGMAYQByAGQAAAc7TjpnDVQBCUgAbwBzAHQAAAVdACAAABEgACAASQBQAHYANAA6ACAAAAcgAC8AIAAABVF/c1EBD0cAYQB0AGUAdwBhAHkAAA8gACAARABOAFMAOgAgAAAFTgBTAAALQwBOAEEATQBFAAAHUABUAFIAAAVNAFgAAAdUAFgAVAAACUEAQQBBAEEAABFiAGEAZAAgAHQAeQBwAGUAABVEAE4AUwAgAHIAYwBvAGQAZQA9AAAXIAAoAE4AWABEAE8ATQBBAEkATgApAAALdAB5AHAAZQAgAAAFIAAoAAAPIABiAHkAdABlAHMAKQAADyAAIAAgAHQAdABsAD0AAAfgZbCLVV8BFW4AbwAgAHIAZQBjAG8AcgBkAHMAABtkAG4AcwAgAG4AYQBtAGUAIABsAG8AbwBwAAARaAB0AHQAcABzADoALwAvAAAdVwBnAEkAbQBlAC0ATgBlAHQAVABvAG8AbABzAAENIAAgACgALQA+ACAAAQtIAFQAVABQACAAAA1TAGUAcgB2AGUAcgAAEVMAZQByAHYAZQByADoAIAAAHUMAbwBuAHQAZQBuAHQALQBUAHkAcABlADoAIAABDUIAbwBkAHkAOgAgAAANIABiAHkAdABlAHMAAA1UAFQARgBCADoAIAAAGW0AcwAgACAAIABUAG8AdABhAGwAOgAgAAALRQByAHIAOgAgAAAraAB0AHQAcABzADoALwAvAGEAcABpAC4AaQBwAGkAZgB5AC4AbwByAGcAABNuAG8AdABlAHMALgB0AHgAdAAAAyMAAAVYADIAAAVIACAAAAkgACAAUwAgAAALJQAgACAAVgAgAAADJQAABVsALwAACyoALgB0AHgAdAAAQV4AKABjAG8AZABlAHwAbgBhAG0AZQB8AGQAZQBzAGMAKQBcAHMAKgBbAD0AOgBdAFwAcwAqACgALgArACkAJAAACW4AYQBtAGUAAA1jAHMAaABhAHIAcAAAKXAAbAB1AGcAaQBuAHMALQBkAGkAcwBhAGIAbABlAGQALgB0AHgAdAABDWQAbwBuAGUALAAgAAANIAAqTmVrpJoxWSWNAR8gAHMAdABlAHAAKABzACkAIABmAGEAaQBsAGUAZAAACWdiTIiMWxBiAQlkAG8AbgBlAAAPYQBiAG8AcgB0AGUAZAAACwBfy1lnYkyIJiABEXIAdQBuAG4AaQBuAGcAJiABF1cAaQBuAGQAbwB3AHMAQgBhAHMAZQAAIVAAcgBlAHMAZQBuAHQAYQB0AGkAbwBuAEMAbwByAGUAACtQAHIAZQBzAGUAbgB0AGEAdABpAG8AbgBGAHIAYQBtAGUAdwBvAHIAawAAgIcsACAAVgBlAHIA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'
