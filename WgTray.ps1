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
# Hide this script's console window if one is visible (e.g. right-click
# "Run with PowerShell" / bare -File launch). GetConsoleWindow() returns
# the console attached to THIS process (MainWindowHandle is useless here:
# on Win10+ the console belongs to conhost, so it is always 0). When the
# console is already hidden (scheduled task / install.bat) ShowWindow
# returns False and nothing changes.
try {
    Add-Type -Name WgHide -Namespace Wg -MemberDefinition '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' -ErrorAction Stop
    $hw = [Wg.WgHide]::GetConsoleWindow()
    if ($hw -ne [IntPtr]::Zero) { [Wg.WgHide]::ShowWindow($hw, 0) | Out-Null }
} catch {}
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
    class ToolAction { internal string Name; internal List<string[]> Steps = new List<string[]>(); internal List<string> Raw = new List<string>(); }
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
                if (act == null) continue;                                   // steps before any button: ignore
                var toks = ToolToks(t);
                if (toks.Count > 0) { act.Steps.Add(toks.ToArray()); act.Raw.Add(t); }
            }
        } catch {}
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
'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CRENEQsRClhaWCjcAQAKc4YBAApvhwEAChEWfjMAAARveQEAChEWEw4WEw84qQAAAAMRBW/ZAQAKey0AAAQRD2/dAQAKExBznQAABhMSERIREHspAAAEb4IBAAoREhEQb94BAAoREiIAABhBFih6AAAGb4MBAAoREhEMEQtzhgEACm+HAQAKERIRCREPEQhdEQwRClhaWBEJEQ8RCFsRCxEKWFpYc4QBAApvhQEAChESExEREQL+Bo4AAAZzWwAACm+IAQAKEQ5viQEAChERb4oBAAoRDxdYEw8RDwMRBW/ZAQAKey0AAARv2wEACj8+////c5oAAAYTFxEXGm+mAQAKERcfCm/fAQAKERd+MwAABG95AQAKERcRB31BAAAEERcRDn1CAAAEERcTExEHb4kBAAoRDm+KAQAKEQdviQEAChETb4oBAAoREwL+BoUAAAZzlQEACm+WAQAKERMC/gaGAAAGc58BAApvoAEAChETAv4GhwAABnOfAQAKb+ABAAoRE349AAAELREU/gaTAAAGc58BAAqAPQAABH49AAAEb+EBAAoCezAAAAQRB2/iAQAKAiiJAQAKEQdvigEAChEFF1gTBREFA2/GAAAKP5X8//8Cc5cBAAoTHhEeFiBmAQAAc4QBAApvhQEAChEeIDACAAAfcHOGAQAKb4cBAAoRHn47AAAEb3kBAAoRHh8MHhoec+MBAApvpAEAChEefTEAAAQCezEAAAQRJi0OAv4GlAAABnOVAQAKEyYRJm+WAQAKAnPkAQAKEx8RHxtvpgEAChEfF2/lAQAKER8Xb+YBAAoRHxZv5wEAChEfFm/oAQAKER9+OwAABG95AQAKER9+PAAABG97AQAKER9yeykAcCIAABBBc+kBAApvgwEAChEffS8AAAQCezEAAARviQEACgJ7LwAABG+KAQAKc5oAAAYTIBEgGm+mAQAKESAfCm/fAQAKESB+OwAABG95AQAKESATGQJ7MQAABG+JAQAKERlvigEAChEZAv4GigAABnOVAQAKb5YBAAoRGQL+BosAAAZznwEACm+gAQAKERkC/gaMAAAGc58BAApv4AEAChEZfj4AAAQtERT+BpUAAAZznwEACoA+AAAEfj4AAARv4QEACgIoiQEACgJ7MQAABG+KAQAKAgJzmwAABn0yAAAEAnsyAAAEKOoBAAoCESctDgL+BpYAAAZz6wEAChMnESco7AEACgIRKC0OAv4GlwAABnOvAQAKEygRKCiwAQAKA2/GAAAKLRUCco0pAHByjCoAcCgBAAAGKI0AAAYqABswBQAQAQAAQwAAEQIoNgAACijtAQAKCgJ7MAAABG/uAQAKEwU4hAAAABIFKO8BAAoLB2/wAQAKLHQHb/EBAAoTBhIGBijyAQAKLGIHb4kBAApv8wEAChMHKy4RB29RAQAKdAIAAAEMCHUJAAACDQksFwIJA2UfeFsfMFoohAAABhcTBN2QAAAAEQdv8wAACi3J3hURB3U2AAABEwgRCCwHEQhvEwAACtwWEwTeaxIFKPQBAAo6cP///94OEgX+FhgAABtvEwAACtwCezEAAAQsQAJ7MQAABG/xAQAKEwkSCQYo8gEACiwpAnsvAAAEbx8AAAogtgAAABYDZR94WxlaKH4AAAYmAiiJAAAGFxME3gfeAybeABYqEQQqQUwAAAIAAABNAAAAOwAAAIgAAAAVAAAAAAAAAAIAAAAZAAAAlwAAALAAAAAOAAAAAAAAAAAAAAAAAAAACAEAAAgBAAADAAAAAQAAARMwAgBJAAAAEAAAEQN7QgAABG9xAQAKA3tBAAAEb3EBAApZCgQWLwMWEAIEBjEDBhACA3tCAAAEb/UBAAoEZS4TA3tCAAAEBGVv9gEACgNv0QEACipaAgMDe0IAAARv9QEACmUEWCiDAAAGKhswBADtAAAARAAAEQN0CQAAAgoGe0IAAARvcQEACgZ7QQAABG9xAQAKWQsHFjABKgZvcQEACgwfGAgGe0EAAARvcQEACloGe0IAAARvcQEAClso3AEACg0ICVkGe0IAAARv9QEACmVaB1sTBARvdAEAChMFEQUabw0AAAoYEQQcCXN1AQAKGSh7AAAGEwYGez8AAAQtGyD/AAAAILQAAAAgvAAAACDLAAAAKHgBAAorGSD/AAAAII4AAAAglwAAACCqAAAAKHgBAApzEQAAChMHEQURBxEGbxIAAAreDBEHLAcRB28TAAAK3N4MEQYsBxEGbxMAAArcKgAAAAEcAAACAMUADdIADAAAAAACAIIAXuAADAAAAAATMAQAzQAAAEUAABEDdAkAAAIKBG9/AQAKIAAAEAAuASoGe0IAAARvcQEACgZ7QQAABG9xAQAKWQsHFjABKgZvcQEACgwfGAgGe0EAAARvcQEACloGe0IAAARvcQEAClso3AEACg0ICVkGe0IAAARv9QEACmVaB1sTBARv9wEAChEEMioEb/cBAAoRBAlYMB4GF30/AAAEBgRv9wEAChEEWX1AAAAEBhdv1QEACioCBgRv9wEAChEEMg0Ge0EAAARvcQEACisMBntBAAAEb3EBAAplKIQAAAYqAAAAEzAFAHQAAABGAAARA3QJAAACCgZ7PwAABC0BKgZ7QgAABG9xAQAKBntBAAAEb3EBAApZCwZvcQEACgwfGAgGe0EAAARvcQEACloGe0IAAARvcQEAClso3AEACg0HFjEECAkwASoCBgRv9wEACgZ7QAAABFkHWggJWVsogwAABioTMAUAhQAAAEcAABEEAnsvAAAEbx8AAAogugAAABYWKH4AAAYLEgEobAEAClQDAnsvAAAEbx8AAAogzgAAABYWKH4AAAYMEgIobAEAClRyyioAcAJ7LwAABG/4AQAKKPkBAAoNEgMo+gEACgoFFwJ7LwAABG/7AQAKEwQSBCj6AQAKFwYo3AEAClso3AEAClQqAAAAGzABAEsAAABIAAARAnsxAAAEb4kBAApv8wEACgwrHAhvUQEACnQCAAABCgZ1CQAAAgsHLAYHb9EBAAoIb/MAAAot3N4RCHU2AAABDQksBglvEwAACtwqAAEQAAACABEAKDkAEQAAAAAbMAQAygAAAEkAABEDdAkAAAIKAhIBEgISAyiIAAAGCAkwASoGb3EBAAoTBB8UEQQJWghbKNwBAAoTBQgJWRMGEQYWMAMWKwoRBBEFWQdaEQZbEwcEb3QBAAoTCBEIGm8NAAAKGBEHHBEFc3UBAAoZKHsAAAYTCQZ7PwAABC0SIP8AAAAfWh9fH3UoeAEACisWIP8AAAAfeiCAAAAAIJkAAAAoeAEACnMRAAAKEwoRCBEKEQlvEgAACt4MEQosBxEKbxMAAArc3gwRCSwHEQlvEwAACtwqAAABHAAAAgCiAA2vAAwAAAAAAgBrAFK9AAwAAAAAEzAFALgAAABKAAARA3QJAAACCgRvfwEACiAAABAALgEqAhIBEgISAyiIAAAGCAkwASoGb3EBAAoTBB8UEQQJWghbKNwBAAoTBQgJWRMGEQYWMAMWKwoRBBEFWQdaEQZbEwcEb/cBAAoRBzIrBG/3AQAKEQcRBVgwHgYXfT8AAAQGBG/3AQAKEQdZfUAAAAQGF2/VAQAKKgJ7LwAABG8fAAAKILYAAAAWBG/3AQAKEQcyAwkrAgllKH4AAAYmBm/RAQAKKhMwBACYAAAASwAAEQN0CQAAAgoGez8AAAQtASoCEgESAhIDKIgAAAYGb3EBAAoTBB8UEQQJWghbKNwBAAoTBQgJWRMGEQYWMQYRBBEFMAEqBG/3AQAKBntAAAAEWREGWhEEEQVZWxMHEQcWLwMWEwcRBxEGMQQRBhMHEQcHWRMIEQgsHwJ7LwAABG8fAAAKILYAAAAWEQgofgAABiYGb9EBAAoqHgIoaQAACipKAnu1AAAEAnu2AAAEKI0AAAYqABMwAwBhAAAATAAAERQKc0ABAAYLBwN9tgAABAcCfbUAAAQCKPwBAAosGQIGLQ0H/gZBAQAGczwBAAoKBig9AQAKJioCey8AAAQHe7YAAARy0CoAcCgyAAAKb/0BAAoCezEAAAQsBgIoiQAABioeAihpAAAKKjYCe7cAAAQXb/4BAAoqABswBQCwAgAATQAAERQTBxYKFgsWDDgKAgAAAnu4AAAEeyoAAAQIbzsBAAqOaRczfwJ7uAAABHsqAAAECG87AQAKFppyKhIAcCgkAAAKLV0Ce7gAAAR7KgAABAhvOwEAChaacmQSAHAoJAAACi0+Anu4AAAEeyoAAAQIbzsBAAoWmnK8EgBwKCQAAAotHwJ7uAAABHsqAAAECG87AQAKFppy/BIAcCgkAAAKKwQXKwEWDQktFgJ7uAAABHsrAAAECG8iAQAKOJAAAABydQIAcAJ7uAAABHsqAAAECG87AQAKFppyKhIAcCgkAAAKLVMCe7gAAAR7KgAABAhvOwEAChaacrwSAHAoJAAACi0tAnu4AAAEeyoAAAQIbzsBAAoWmnL8EgBwKCQAAAotB3LWKgBwKxNy7CoAcCsMckQWAHArBXIyFQBwcvQqAHByBCsAcCgBAAAGKEAAAAoTBHMsAAAKEwUCe7gAAAR7KgAABAhvOwEACgktGAJ7uAAABHsrAAAECG8iAQAKKBkAAAYrEQJ7uAAABHsrAAAECG8iAQAKEQUoBQAABiggAAAGEwYRBW+lAAAKFjEXAnu5AAAEEQVvMwAACm8jAAAKKI0AAAYRBnLuFABwKCQAAAosBBcLK1kRBiwkBhdYCgJ7uQAABHIsKwBwEQRyPCsAcBEGKHAAAAoojQAABisXAnu5AAAEckorAHARBCgyAAAKKI0AAAYIF1gMCAJ7uAAABHsqAAAEbzQBAAo/4P3//wJ7uQAABActPwYsK3JaKwBwcmorAHAoAQAABgaMYgAAAXJ+KwBwcpIrAHAoAQAABijFAAAKKyByuCsAcHLKKwBwKAEAAAYrD3LgKwBwcvQrAHAoAQAABiiNAAAGAnu5AAAEEQctDgL+BkQBAAZzPAEAChMHEQcoPQEACibeAybeACoBEAAAAACKAiKsAgMBAAABEzAEAHsAAABOAAARc0IBAAYLBwJ9uQAABAcDdAIAAAF9twAABAcHe7cAAARv/wEACnQFAAACfbgAAAQHe7cAAAQWb/4BAAoCchAsAHAHe7gAAAR7KQAABHIYLABwKEAAAAoojQAABgf+BkMBAAZzPwEACnNAAQAKCgYXb0EBAAoGb0IBAAoqAAMwBAAOAQAAAAAAACD/AAAAIOgAAAAg7QAAACD1AAAAKHgBAAqAMwAABCD/AAAAIP8AAAAg/wAAACD/AAAAKHgBAAqANAAABCD/AAAAINwAAAAg4wAAACDvAAAAKHgBAAqANQAABCD/AAAAINkAAAAg4AAAACDsAAAAKHgBAAqANgAABCD/AAAAIMMAAAAgzAAAACDdAAAAKHgBAAqANwAABCD/AAAAHx0fHR8fKHgBAAqAOAAABCD/AAAAH24fdCCFAAAAKHgBAAqAOQAABCD/AAAAFh96IP8AAAAoeAEACoA6AAAEIP8AAAAfLh8wH0AoeAEACoA7AAAEIP8AAAAg1gAAACDZAAAAIOIAAAAoeAEACoA8AAAEKjoCKJcBAAoCF28AAgAKKjoCKJcBAAoCF28AAgAKKjoCKGkAAAoCA31DAAAEKgATMAMANAAAADYAABEDKGoBAAogCgIAAC4CFioCe0MAAAQDKGsBAAoKEgAoAQIACh8QYyD//wAAal9ob4IAAAYqAzAFAHYAAAAAAAAAAiD/AAAAIP8AAAAg/wAAACD/AAAAKHgBAAp9RAAABAIg/wAAACDwAAAAIPMAAAAg+QAAACh4AQAKfUUAAAQCIP8AAAAg4gAAACDoAAAAIPIAAAAoeAEACn1GAAAEAiiXAQAKAhdvAAIACgIomwEACm+cAQAKKlYCF31JAAAEAijRAQAKAgMoAgIACipWAhZ9SQAABAIo0QEACgIDKAMCAAoqVgIXfUoAAAQCKNEBAAoCAygEAgAKKlYCFn1KAAAEAijRAQAKAgMoBQIACioAABswCACpAQAATwAAEQNvdAEACgoGGm8NAAAKAigGAgAKLCoCKAYCAApvBwIACnMRAAAKCwYHAigIAgAKbwkCAAreCgcsBgdvEwAACtwSAhYWAihwAQAKF1kCKHEBAAoXWSh1AQAKAigKAgAKLCgCe0oAAAQtGAJ7SQAABC0IAntEAAAEKykCe0UAAAQrIQJ7RgAABCsZIP8AAAAg8wAAACDzAAAAIPYAAAAoeAEACg0IHih7AAAGEwQJcxEAAAoTBQYRBREEbxIAAAreDBEFLAcRBW8TAAAK3N4MEQQsBxEEbxMAAArcAntHAAAELD4Ce0gAAAQsNn46AAAEcxEAAAoTBgYRBh8MAihxAQAKGlkCKHABAAofGFkZbwsCAAreDBEGLAcRBm8TAAAK3AIoCgIACiwHfjgAAAQrBX45AAAEcxEAAAoTB3MVAAAKEwkRCRdvFgAAChEJF28XAAAKEQkTCAYCbwwCAAoCb/gBAAoRByIAAMBAIgAAAAACKHABAAofDFlrAihxAQAKa3MQAAAKEQhvDQIACt4MEQgsBxEIbxMAAArc3gwRBywHEQdvEwAACtwqAAAAAUwAAAIAJwAPNgAKAAAAAAIAtAAMwAAMAAAAAAIArAAizgAMAAAAAAIA9gAeFAEMAAAAAAIAVgE4jgEMAAAAAAIAOwFhnAEMAAAAABswBABcAAAAPwAAERmNPAAAAQ0JFnL1KABwogkXcikpAHCiCRhyAQAAcKIJCgYTBBYTBSsbEQQRBZoLBwIDGXMUAAAKDN4fJt4AEQUXWBMFEQURBI5pMt0oyQEACgIDGXPKAQAKKggqARAAAAAALwAMOwADAQAAARMwBwCaAAAAQAAAEXMEAAAKCgMYWgsGDwAoywEACg8AKMwBAAoHByIAADRDIgAAtEJvzQEACgYPACjOAQAKB1kPACjMAQAKBwciAACHQyIAALRCb80BAAoGDwAozgEACgdZDwAozwEACgdZBwciAAAAACIAALRCb80BAAoGDwAoywEACg8AKM8BAAoHWQcHIgAAtEIiAAC0Qm/NAQAKBm8KAAAKBioeAihpAAAKKh4CKGkAAAoqAAALMAcALgAAAAAAAAACKB8AAAoWFgIocAEAChdYAihxAQAKF1gfFB8UKKgAAAYXKKkAAAYm3gMm3gAqAAABEAAAAAAAACoqAAMBAAABXgJ7ugAABAJ7vQAABH5yAQAKb3MBAAoqXgJ7ugAABAJ7vQAABH5yAQAKb3MBAAoqGzAFAF4AAAA3AAARBG90AQAKCgYabw0AAAoXFwIocAEAChlZAihxAQAKGVlzdQEACh8JKKQAAAYLfk8AAAQiAACAP3N2AQAKDAYIB293AQAK3goILAYIbxMAAArc3goHLAYHbxMAAArcKgAAARwAAAIAPQAKRwAKAAAAAAIALQAmUwAKAAAAAL4Ce7wAAAQg/wAAACDoAAAAHxEfIyh4AQAKb3kBAAoCe7wAAAQoegEACm97AQAKKoYCe7wAAAQoDgAACm95AQAKAnu8AAAEflAAAARvewEACioeAih8AQAKKgAAGzAHAEoAAAA4AAARfk8AAARzfQEACgoEb3QBAAoGFgJ7uwAABG9xAQAKF1kCe7sAAARvcAEACgJ7uwAABG9xAQAKF1lvfgEACt4KBiwGBm8TAAAK3CoAAAEQAAACAAsAND8ACgAAAAALMAQANgAAAAAAAAAEb38BAAogAAAQAC4BKiilAAAGJgIoHwAACiChAAAAGCiAAQAKfoEBAAoopgAABibeAybeACoAAAEQAAAAAA4AJDIAAwEAAAETMAMAhAAAABAAABEWCitnAnu+AAAEe70AAAR7VgAABAZvDgIACgYCe78AAAT+AX1cAAAEAnu+AAAEe70AAAR7VgAABAZvDgIACm/RAQAKAnu+AAAEe70AAAR7VQAABAZv0gEACgYCe78AAAT+AW/TAQAKBhdYCgYCe74AAAR7vQAABHtWAAAEbw8CAAoygSpGBG+LAQAKHxszBgIofAEACioAABMwBwCaBQAAUAAAERQTHRQTHhQTHxQTIBQTIQJz1wEACn1VAAAEAnMQAgAKfVYAAAQCKIwBAApzRQEABhMcERwCfb0AAAQCciAsAHByPiwAcCgBAAAGb4IBAAoCFiiNAQAKAhYojgEACgIXKI8BAAoCFyiQAQAKAhcokQEACgIggAIAACAIAgAAc4YBAAookgEACgJ+SwAABG95AQAKERwRHS0OAv4GtgAABnNbAAAKEx0RHX26AAAEAhEc/gZGAQAGc1sAAAookwEACgIRHP4GRwEABnNbAAAKKJQBAAoCER4tDgL+BrcAAAZzlQEAChMeER4olgEAChEcc5cBAAoTGBEYFhZzhAEACm+FAQAKERgggAIAAB8mc4YBAApvhwEAChEYfkwAAARveQEAChEYfbsAAARzmAEAChMZERlybwkAcHJuLABwKAEAAAZvggEAChEZF2+ZAQAKERkfDh8Jc4QBAApvhQEAChEZIgAAIEEXKKMAAAZvgwEAChEZflAAAARvewEAChEZKA4AAApveQEAChEZChEcc5gBAAoTGhEacsolAHBvggEAChEaHx4fGnOGAQAKb4cBAAoRGiBaAgAAHHOEAQAKb4UBAAoRGh8gb5oBAAoRGiIAACBBFiijAAAGb4MBAAoRGn5QAAAEb3sBAAoRGigOAAAKb3kBAAoRGiibAQAKb5wBAAoRGn28AAAEERx7vAAABBEc/gZIAQAGc1sAAApvnQEAChEce7wAAAQRHP4GSQEABnNbAAAKb54BAAoRHHu8AAAEER8tDgL+BrgAAAZzWwAAChMfER9viAEAChEce7sAAARviQEACgZvigEAChEce7sAAARviQEAChEce7wAAARvigEAChEce7sAAAQRHP4GSgEABnOVAQAKb5YBAAoRIC0OAv4GuQAABnOfAQAKEyARIAsRHHu7AAAEB2+gAQAKBgdvoAEACgIoiQEAChEce7sAAARvigEACnOXAQAKExsRGxYfJnOEAQAKb4UBAAoRGyCAAgAAHyhzhgEACm+HAQAKERt+SwAABG95AQAKERsMAiiJAQAKCG+KAQAKILoBAAANAntVAAAEAhYJHywSBBILKKsAAAZv4gEACgJ7VQAABAIXCR8sEgUSDCirAAAGb+IBAAoCe1UAAAQCGAkfTBIGEg0oqwAABm/iAQAKAntVAAAEAhkJHywSBxIOKKsAAAZv4gEACgJ7VQAABAIaCR8sEggSDyirAAAGb+IBAAoCe1UAAAQCGwkfTBIJEhAoqwAABm/iAQAKAntVAAAEAhwJHywSChIRKKsAAAZv4gEACh2NPAAAARMiESIWcoosAHCiESIXcpQsAHCiESIYcqQsAHCiESIZcqwsAHCiESIacrYsAHByvCwAcCgBAAAGohEiG3LILABwcs4sAHAoAQAABqIRIhxy3CwAcHLiLABwKAEAAAaiESITEiBkAgAAERKOaVsTExYTFDjfAAAAc0sBAAYTFxEX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AAABAKYPAgACAKsPAgADALAPAAABALQPAAACACQIAAABALQPAAACACQIAAABALgPAAACAL8PAAADAMMPAAAEAMcPAAAFANIPAAAGANYPAAAHANwPAAAIACQIEBAJAOQPEBAKAOwPAAABAPEPAAACAPYPAAADAPwPAAAEAP4PAAAFAAMQAAABAKMPAAACAJ4PAAADACQIAAAEAAsQAAABAJ0HAAACAA4QAAABAJ0HAAACABgQAAADAA4QAgAEAB0QAAABAJ0HAAACACEQAAADAA4QAgAEACUQAAABAJ0HAAACACoQAAADAA4QAAABAC8QAAABADEQAAABADMQAAABADUQAAACADwQAgADAEUQAgAEAEgQAgAFAE0QAAABADEQAAABADEQAAABADUQAAACADwQAAABADUQAAACADwQAAADAFIQAAABAFgQAAACAFoQAAABAFwQAAACAGEQAAADAGcQAAAEAA4QAAABAG4QAAACADEQAAABADMQAAACAHAQAAABADMQAAACAHAQAAABADMQAAACAHIQAAABADMQAAACAHIQAAABAHYQAAACAA4QAAABAA4QAAABAHoQAAACAHwQAAADAH4QAAABAC4PAAABAC4PAAABAIIQAAACAIgQAAADAI4QAAABAJMQAAACAJgQAAABAH4PAAABAJwQAAACAKEQAAABAJwQAAABAKoQAAABAJwQAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABALEQAAACAHgPAAADALYQAAAEAHUPAAABALEQAAACAHgPAAABAHgPAAACAEUPAAADAHUPAAABAHgPAAABADMQAAABAJ0HAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABABgQAAACAMIQAAABACUPAAACACcPAAABALEQAAACAMUQAAADAMkQAAAEANAQAAABAHoQAAACAMUQAAADAG4QAAAEANcQAAABANkQAAACANwQAAADAN8QAAAEAOIQAAAFAG4QAAAGAHoQAAABALEQAAACAOUQAAADAOoQAAABAPEQAAABAPYQAAABAIgLAAACAPwQAAABAIgLAAACAAARAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAC8QAAACAAMRAgABAAURAgACAAsRAgADAOQPAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAC8QAAABABERAAACAAMRAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAPktAAACAFgbAAABAC8QAAACAAMRAAABAPktAAACAFgbAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAHoQAAABADMQAAABAAMRAAABAAMRAAABAAMRAAABAAMRAAABAAMRAAABABgQAAACAMIQAAABACUPAAACACcPAAABALEQAAACAMUQAAADAMkQAAAEANAQAAABAHoQAAACAMUQAAADAG4QAAAEANcQAAABANkQAAACANwQAAADAN8QAAAEAOIQAAAFAG4QAAAGAHoQAAABALEQAAACAOUQAAADAOoQAAABABgRAAACABwRAAADACURAgAEACoRAgAFACQIAAABAC4RAAACAI8OAAADAJEOAAAEAG4QAAAFADYPAAAGADURAAABAD0RAAABAC8QAAABACoRAAACACQIAAABACoRAAACACQIAAABACoRAAACACQIAAABACoRAAACACQIAAABACoRAAACACQIAAABACoRAAACACQIAAABACoRAAACACQIAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAAMRAAABAAMRAAABAAMRAAABAAMRAAABAAMRAAABAI8OAAACAJEOAAADAG4QAAAEADYPAAABAAMRAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAI8OAAACAJEOAAADAG4QAAAEAHoQAgABAAURAgACAAsRAgADAOQPAAABAC8QAAACAAMRAAABAC8QAAABAC8QAAABAEARAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAHoQAAABAHoQAAABAAMRAAABAAMRAAABADMQAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABABgQAAACAMIQAAABACUPAAACACcPAAABALEQAAACAMUQAAADAMkQAAAEANAQAAABAHoQAAACAMUQAAADAG4QAAAEANcQAAABANkQAAACANwQAAADAN8QAAAEAOIQAAAFAG4QAAAGAHoQAAABALEQAAACAOUQAAADAOoQAAABAPEPAAACABgRAAABAEYRAAABAEYRAgABAAURAgACAAsRAgADAOQPAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAEYRAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAC8QAAACAAMRAAABAAMRAAABAHgPAAACAEgRAAADAEUPAAAEAEsRAAABAHoQAAABAHoQAAACAE8RAAADAMkQAAAEANAQAAABAFwQAgABAHAQAAABAE8RAAACAMkQAAADANAQAAABAI8OAAACAJEOAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABAMIWAAACAMkWAAABAFURAAACAFwRAAABAE8RAAACAMkQAAADANAQAAABAE8RAAACAMkQAAADANAQAAAEAGMRAAAFAFURAAABAGwRAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAFgbAAABAC8QAAACAFgbAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAMIWAAACAMkWAAABAC8QAAACAAMRAAABADgoAAACAG4QAAADAHoQ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AAABANkAAAAAAAQAAAAAAAAAAAAAAAEA8AAAAAAABAAAAAAAAAAAAAAAGgByAQAAAAAEAAAAAAAAAAAAAAABAOIAAAAAAAQAAAAAAAAAAAAAAAEATQYAAAAAAwACAAQAAgAFAAIABgACAAcAAgAIAAcACQAHAAoABwALAAcADAACAA0ADAAOAAwADwAMABAADwARAAIAEgACABMAEgAUABIAFQACABYAFQAXABUAGAAVABkAAgAbABoAHAACAB0AAgAeAAIAHwACACAAAgAhABoAIgACACMAIgAkAAIAJQAEACYABAAnAAcAKAAHACkABwAqAAcAKwAMACwADAAtAAwALgAtAC8ADAAwAAwAMQAwADIADAAzAAwANAAzADUADAA2ADUANwA1ADgAGgA5AAwAOgAMADsAOgA8AA8APQASAD4AEgA/ABIATwBkBE8AvgQAAAA8TW9kdWxlPgB3Z3RyYXlfbmV3LmRsbABUcmF5QXBwAEhvdEtleUhvc3QAUGx1Z2luTWdyRm9ybQBUb29sQWN0aW9uAFRvb2xUYWIAVG9vbHNGb3JtAFZQAFNCYXIAV2hlZWxGaWx0ZXIAVEJ0bgBOZXRUb29sc0Zvcm0ATkJ0bgBORWRpdABOTG9nAERCUABDbGlwRm9ybQBOb3RlRm9ybQBOVENoaXAAU0JQYW5lbABDb2xvckZvcm0AUFQATVNMTABNb3VzZVByb2MAUGx1Z2luQ29kZQBtc2NvcmxpYgBTeXN0ZW0AT2JqZWN0AFN5c3RlbS5XaW5kb3dzLkZvcm1zAENvbnRyb2wARm9ybQBQYW5lbABJTWVzc2FnZUZpbHRlcgBWYWx1ZVR5cGUATXVsdGljYXN0RGVsZWdhdGUAWmgATABEYXRhRGlyAEJhdERpcgBCYXRQYXRoAE5vdGlmeUljb24AdHJheVJlZgBTeXN0ZW0uRHJhd2luZwBTeXN0ZW0uRHJhd2luZy5EcmF3aW5nMkQAR3JhcGhpY3NQYXRoAFJlY3RhbmdsZUYAUm91bmRlZFJlY3QASWNvbgBDb2xvcgBNYWtlSWNvbgBDb250ZXh0TWVudVN0cmlwAG1lbnUAVG9vbFN0cmlwTWVudUl0ZW0AbWlBcHBzAG1pUGx1Z2lucwBtaUF1dG8AaG90SXRlbXMAdHJheQBoa0hvc3QASG90VG9vbGJveE1vZABIb3RUb29sYm94VmsASG90UGx1Z2luc01vZABIb3RQbHVnaW5zVmsASG90TWVudU1vZABIb3RNZW51VmsAVG9vbFRpcEljb24AVHJheVRpcAB1aUludm9rZXIAVWkAUGFyc2VIb3RrZXkASG90a2V5VGV4dABBcHBseUhvdGtleXMASGFuZGxlSG90S2V5AElzQXV0b1N0YXJ0AFNldEF1dG9TdGFydABTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYwBEaWN0aW9uYXJ5YDIAQXBwcwBEZWZhdWx0Q29uZmlnVGV4dABMb2FkQ29uZmlnAFJlbG9hZENvbmZpZwBPcGVuQ29uZmlnRmlsZQBPcGVuRGF0YURpcgBCdWlsZE1lbnUAUmVmcmVzaE1lbnVDaGVja3MAUmVidWlsZFRyYXlNZW51AFJ1bgBGaXhMZWdhY3lDb25maWdJZkJyb2tlbgBMYXVuY2hBcHAATGlzdGAxAFRvb2xUYWJzAHRvb2xzRm9ybQBUb29sVG9rcwBMb2FkVG9vbHMAVG9vbFJlc3QAVG9vbFBhdGgATWljcm9zb2Z0LldpbjMyAFJlZ2lzdHJ5S2V5AFRvb2xSZWdTcGxpdABTeXN0ZW0uRGlhZ25vc3RpY3MAUHJvY2Vzc1N0YXJ0SW5mbwBTeXN0ZW0uVGV4dABTdHJpbmdCdWlsZGVyAFJ1bkhpZGRlbgBSdW5WaXNpYmxlAEVuY29kaW5nAFJ1blNjcmlwdEJsb2NrAFRvb2xEZWwARXhlY1Rvb2xTdGVwAFNob3dUb29scwBuZXRGb3JtAFNob3dOZXRUb29scwBQaW5nT25jZQBQaW5nUnR0AEhvcE9uY2UAVGVzdFBvcnQAUGFyc2VJcFY0AElwU3RyAE1hc2tUb0JpdHMAUGFyc2VJcE1hc2sASXBUeXBlAElwQ2xhc3MAU3VibmV0Q2FsYwBTdWJuZXRTcGxpdABSYW5nZVRvQ2lkcgBNYXNrVGFibGUATG9jYWxOZXRJbmZvAERuc1F1ZXJ5AFN5c3RlbS5JTwBCaW5hcnlXcml0ZXIARG5zQkUxNgBEbnNVMTYARG5zVTMyAERuc1NraXBOYW1lAERuc1JlYWROYW1lAEh0dHBDaGVjawBQdWJsaWNJcABjbGlwRm9ybQBDbGlwUHVzaABTaG93Q2xpcABub3RlRm9ybQBOb3Rlc1BhdGgAU2hvd05vdGUAY29sb3JGb3JtAENvbG9ySGV4AENvbG9ySHN2AFNob3dDb2xvcgBQbHVnaW5BY3Rpb25zAElFbnVtZXJhYmxlYDEAUGFyc2VUb29sU3RlcHMARXh0cmFjdFBsdWdpbkJsb2NrAExvYWRQbHVnaW5zAFBsdWdpbkluZm8AU3lzdGVtLkNvcmUASGFzaFNldGAxAERpc2FibGVkUGx1Z2lucwBMb2FkRGlzYWJsZWRQbHVnaW5zAFNldFBsdWdpbkRpc2FibGVkAFJ1blBsdWdpbgBQbHVnaW5Db2RlQ2FjaGUAUGx1Z2luUmVmcwBQbHVnaW5SZWZzRnVsbABDb21waWxlUGx1Z2luAFJ1bkNvZGVQbHVnaW4AU3lzdGVtLlRocmVhZGluZwBUaHJlYWQAcGx1Z2luVGhyZWFkAHBsdWdpbkludm9rZXIARW5zdXJlUGx1Z2luVGhyZWFkAHBsdWdpbk1ncgBTaG93UGx1Z2luTWdyAC5jdG9yAEFjdGlvbmAxAE9uSG90S2V5AHJlZwBSZWdpc3RlckhvdEtleQBVbnJlZ2lzdGVySG90S2V5AFJlZwBVbnJlZwBNZXNzYWdlAFduZFByb2MAaG9zdABMaXN0VmlldwBsaXN0AFBsdWdpbkRpcgBSZWZyZXNoTGlzdABSdW5TZWwAVG9nZ2xlU2VsAFNlbEZpbGUAT3BlbkRpcgBFZGl0U2VsAERlbFNlbABOZXdQbHVnaW4ATmFtZQBTdGVwcwBSYXcAQWN0aW9ucwBDb2xzAFRleHRCb3gAbG9nAHBhZ2VzAGxvZ1dyYXAAd2hlZWxGaWx0ZXIAVENfQkcAVENfU1VSRkFDRQBUQ19IRUFERVIAVENfU1VSRjIAVENfQk9SREVSAFRDX1RFWFQAVENfU1VCAFRDX0FDQ0VOVABUQ19DT05CRwBUQ19DT05GRwBGb250AEZvbnRTdHlsZQBURgBSZWN0YW5nbGUAVFJvdW5kAFRSZWxlYXNlQ2FwdHVyZQBUU2VuZE1lc3NhZ2UAVFNlbmRNc2dJbnQAVENyZWF0ZVJvdW5kUmVjdFJnbgBUU2V0V2luZG93UmduAE9uV2hlZWwAU2V0VnBPZmZzZXQAU2Nyb2xsVnAAUGFpbnRFdmVudEFyZ3MAUGFnZVNiUGFpbnQATW91c2VFdmVudEFyZ3MAUGFnZVNiRG93bgBQYWdlU2JNb3ZlAExvZ1NiTWV0cmljcwBJbnZhbGlkYXRlTG9nQmFyAExvZ1NiUGFpbnQATG9nU2JEb3duAExvZ1NiTW92ZQBMb2cARXZlbnRBcmdzAFJ1bkFjdGlvbgBEcmFnAERyYWdPZmYASG9zdABWcABQcmVGaWx0ZXJNZXNzYWdlAEJnAEJnSG92ZXIAQmdEb3duAEFjY2VudExpbmUAU2VsZWN0ZWQAaG92ZXIAZG93bgBPbk1vdXNlRW50ZXIAT25Nb3VzZUxlYXZlAE9uTW91c2VEb3duAE9uTW91c2VVcABPblBhaW50AE5DX0JHAE5DX0hFQURFUgBOQ19DQVJEAE5DX1NVUkYyAE5DX0JPUkRFUgBOQ19URVhUAE5DX1NVQgBOQ19BQ0NFTlQATkNfQ09OQkcATkNfQ09ORkcATlJvdW5kAE5SZWxlYXNlQ2FwdHVyZQBOU2VuZE1lc3NhZ2UATlNlbmRNc2dJbnQATkNyZWF0ZVJvdW5kUmVjdFJnbgBOU2V0V2luZG93UmduAGNoaXBzAE1ha2VQYWdlAE1rQnRuAFRocmVhZFN0YXJ0AFN0YW1wAEJ1aWxkUGluZ1RhYgBCdWlsZFRyYWNlcnRUYWIAQnVpbGREbnNUYWIAQnVpbGRIdHRwVGFiAEJ1aWxkUG9ydFRhYgBCdWlsZFN1Ym5ldFRhYgBCdWlsZExvY2FsVGFiAEZnAFByaW1hcnkAQm94AGJhcgBUaW1lcgBzeW5jAGRyYWcAZHJhZ09mZgBsYXN0Rmlyc3QAbGFzdFRvdGFsAE1ldHJpY3MAUGFpbnRCYXIATGluZQBTZXQAU2F2ZQBXTV9DTElQQk9BUkRVUERBVEUAQWRkQ2xpcGJvYXJkRm9ybWF0TGlzdGVuZXIAUmVtb3ZlQ2xpcGJvYXJkRm9ybWF0TGlzdGVuZXIASGlzdG9yeQBMaXN0Qm94AHNlbGZTZXQAT25IYW5kbGVDcmVhdGVkAEZvcm1DbG9zZWRFdmVudEFyZ3MAT25Gb3JtQ2xvc2VkAENvcHlTZWwAYm94AExhYmVsAHN0YXR1cwBzYXZlcgBzYlN5bmMAaGVhZGVyAHdyYXAAc3RyaXAAc2IAZmlsZXMAY3VyAGFjdGl2ZUNpAHNiRHJhZwBzYkRyYWdPZmYAQ04AQ0JvZHkAQ0hlYWQAQ1RleHQAQ1N1YgBORgBOb3RlUm91bmQATm90ZUNvbG9yUGF0aABMb2FkTm90ZUNvbG9yAE5vdGVzRGlyAE5vdGVNZXRhUGF0aABSZWxlYXNlQ2FwdHVyZQBTZW5kTWVzc2FnZQBTZW5kTXNnSW50AENyZWF0ZVJvdW5kUmVjdFJnbgBTZXRXaW5kb3dSZ24ATG9hZE5vdGVzAFNhdmVNZXRhAExvYWRDdXIAVGl0bGVPZgBSZWJ1aWxkVGFicwBTd2l0Y2hUbwBBZGROb3RlAERlbGV0ZU5vdGUAU2JNZXRyaWNzAFBhaW50U2IAU2JEb3duAFNiTW92ZQBBcHBseVRoZW1lAFNhdmVOb3cAVGl0bGUAQWN0aXZlAENlbnRlcgBTZXRXaW5kb3dzSG9va0V4AFVuaG9va1dpbmRvd3NIb29rRXgAQ2FsbE5leHRIb29rRXgAR2V0TW9kdWxlSGFuZGxlAEdldEN1cnNvclBvcwBzd2F0Y2gAbGJsAG1vdXNlSG9vawBwcm9jAFN0YXJ0UGljawBTdG9wUGljawBNb3VzZUhvb2tQcm9jAFBpY2tBdAB4AHkAcHQAbW91c2VEYXRhAGZsYWdzAHRpbWUAZXh0cmEASW52b2tlAElBc3luY1Jlc3VsdABBc3luY0NhbGxiYWNrAEJlZ2luSW52b2tlAEVuZEludm9rZQBTeXN0ZW0uUmVmbGVjdGlvbgBBc3NlbWJseQBBc20ATWV0aG9kSW5mbwBFbnRyeQBFcnJvcgB6aABlbgByAHJhZABjaABjAHRpdGxlAHRleHQAaWNvbgBzcGVjAG1vZABTeXN0ZW0uUnVudGltZS5JbnRlcm9wU2VydmljZXMAT3V0QXR0cmlidXRlAHZrAGlkAG9uAGRpcgBiYXRQYXRoAGYAY29kZQBsaW5lAHJhd0xpbmUAcmVzdAB0awBmdWxsAGhpdmUAc3ViAHBzaQBzY3JpcHQAZXh0AGV4ZQBhcmdzUHJlZml4AGVuYwBpb0VuYwBwcmVsdWRlAHZpc2libGUAdGFpbABwYXRoAGlzRGlyAG4AZmFpbABza2lwcGVkAHVpAHRpbWVvdXRNcwBzaXplAHJ0dAB0dGwAZG9uZQBwb3J0AHMAdgBtAGlwVGV4dABtYXNrVGV4dABpcABiaXRzAG1hc2sAY291bnQAYQBiAG5hbWUAcXR5cGUAc2VydmVyAHcAcABwb3MAdXJsAGgAdABjYXAAbGluZXMAc3RlcHMAcmF3cwBib2R5AHRhZwBmaWxlAGRpc2FibGVkAHNvdXJjZQBoV25kAGZzTW9kaWZpZXJzAHN0AG1zZwB3UGFyYW0AbFBhcmFtAGwAeDEAeTEAeDIAeTIAaFJnbgByZWRyYXcAdGFicwBkZWx0YQBvZmYAZHkAZQBmaXJzdAB0b3RhbABzZW5kZXIAaWR4AGNvbnRlbnRIAHRvcEgAdG9wAHBhcmVudABwcmltYXJ5AGZuAG93bmVyAGkAY2IAdGlkAG5Db2RlAG9iamVjdABtZXRob2QAY2FsbGJhY2sAcmVzdWx0AFN5c3RlbS5SdW50aW1lLkNvbXBpbGVyU2VydmljZXMAQ29tcGlsYXRpb25SZWxheGF0aW9uc0F0dHJpYnV0ZQBSdW50aW1lQ29tcGF0aWJpbGl0eUF0dHJpYnV0ZQB3Z3RyYXlfbmV3AGdldF9YAGdldF9ZAEFkZEFyYwBnZXRfUmlnaHQAZ2V0X0JvdHRvbQBDbG9zZUZpZ3VyZQBCaXRtYXAAR3JhcGhpY3MASW1hZ2UARnJvbUltYWdlAFNtb290aGluZ01vZGUAc2V0X1Ntb290aGluZ01vZGUAZ2V0X1RyYW5zcGFyZW50AENsZWFyAFNvbGlkQnJ1c2gAQnJ1c2gARmlsbFBhdGgASURpc3Bvc2FibGUARGlzcG9zZQBHcmFwaGljc1VuaXQAU3RyaW5nRm9ybWF0AFN0cmluZ0FsaWdubWVudABzZXRfQWxpZ25tZW50AHNldF9MaW5lQWxpZ25tZW50AEZvbnRGYW1pbHkAZ2V0X0ZvbnRGYW1pbHkAQWRkU3RyaW5nAENvbXBvc2l0aW5nTW9kZQBzZXRfQ29tcG9zaXRpbmdNb2RlAEdldEhpY29uAEZyb21IYW5kbGUAU2hvd0JhbGxvb25UaXAAZ2V0X0lzRGlzcG9zZWQAZ2V0X0hhbmRsZQBTdHJpbmcASXNOdWxsT3JXaGl0ZVNwYWNlAFRvTG93ZXIAQ2hhcgBTcGxpdABUcmltAG9wX0VxdWFsaXR5AGdldF9MZW5ndGgAZ2V0X0NoYXJzAEFycmF5AEluZGV4T2YAPFByaXZhdGVJbXBsZW1lbnRhdGlvbkRldGFpbHM+e0ZEMkEzQUYzLUVCMjQtNDZCNS1CNURGLUJFNDlCMkJGMzJFMH0AQ29tcGlsZXJHZW5lcmF0ZWRBdHRyaWJ1dGUAJCRtZXRob2QweDYwMDAwMDYtMQBBZGQAVHJ5R2V0VmFsdWUAQXBwZW5kAFVJbnQzMgBfX1N0YXRpY0FycmF5SW5pdFR5cGVTaXplPTk2ACQkbWV0aG9kMHg2MDAwMDA3LTEAUnVudGltZUhlbHBlcnMAUnVudGltZUZpZWxkSGFuZGxlAEluaXRpYWxpemVBcnJheQBUb1N0cmluZwBDb25jYXQAZ2V0X0lzSGFuZGxlQ3JlYXRlZABDdXJzb3IAUG9pbnQAZ2V0X1Bvc2l0aW9uAFRvb2xTdHJpcERyb3BEb3duAFNob3cAc2V0X1VzZVNoZWxsRXhlY3V0ZQBzZXRfQ3JlYXRlTm9XaW5kb3cAc2V0X1JlZGlyZWN0U3RhbmRhcmRPdXRwdXQAc2V0X1JlZGlyZWN0U3RhbmRhcmRFcnJvcgBQcm9jZXNzAFN0YXJ0AFdhaXRGb3JFeGl0AGdldF9FeGl0Q29kZQBSZXBsYWNlAEV4Y2VwdGlvbgBnZXRfTWVzc2FnZQBzZXRfSXRlbQBQYXRoAENvbWJpbmUARmlsZQBFeGlzdHMAZ2V0X1VURjgAUmVhZEFsbExpbmVzAFN1YnN0cmluZwBTeXN0ZW0uVGV4dC5SZWd1bGFyRXhwcmVzc2lvbnMAUmVnZXgATWF0Y2gAR3JvdXAAZ2V0X1N1Y2Nlc3MAR3JvdXBDb2xsZWN0aW9uAGdldF9Hcm91cHMAZ2V0X0l0ZW0AQ2FwdHVyZQBnZXRfVmFsdWUARW52aXJvbm1lbnQARXhwYW5kRW52aXJvbm1lbnRWYXJpYWJsZXMAVVRGOEVuY29kaW5nAFdyaXRlQWxsVGV4dABzZXRfRmlsZU5hbWUAPEJ1aWxkTWVudT5iX182AHBhcmFtMABwYXJhbTEAPEJ1aWxkTWVudT5iX183ADxCdWlsZE1lbnU+Yl9fOAA8QnVpbGRNZW51PmJfXzkAPEJ1aWxkTWVudT5iX19hADxCdWlsZE1lbnU+Yl9fYgA8QnVpbGRNZW51PmJfX2MAPEJ1aWxkTWVudT5iX19kADxCdWlsZE1lbnU+Yl9fZQA8QnVpbGRNZW51PmJfX2YAPEJ1aWxkTWVudT5iX18xMABFdmVudEhhbmRsZXIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTEyAFN5c3RlbS5Db21wb25lbnRNb2RlbABDYW5jZWxFdmVudEFyZ3MAPEJ1aWxkTWVudT5iX18xMQBBcHBsaWNhdGlvbgBFeGl0AFRvb2xTdHJpcABUb29sU3RyaXBJdGVtQ29sbGVjdGlvbgBnZXRfSXRlbXMAVG9vbFN0cmlwSXRlbQBUb29sU3RyaXBTZXBhcmF0b3IAVG9vbFN0cmlwRHJvcERvd25JdGVtAGdldF9Ecm9wRG93bkl0ZW1zAGFkZF9DbGljawBzZXRfRW5hYmxlZABDYW5jZWxFdmVudEhhbmRsZXIAYWRkX09wZW5pbmcAc2V0X0NvbnRleHRNZW51U3RyaXAAc2V0X0NoZWNrZWQAc2V0X1RleHQAPD5jX19EaXNwbGF5Q2xhc3MxOAA8PjRfX3RoaXMAPFJlYnVpbGRUcmF5TWVudT5iX18xNQA8PmNfX0Rpc3BsYXlDbGFzczFhADxSZWJ1aWxkVHJheU1lbnU+Yl9fMTcAPFJlYnVpbGRUcmF5TWVudT5iX18xNgBFbnVtZXJhdG9yAEdldEVudW1lcmF0b3IAS2V5VmFsdWVQYWlyYDIAZ2V0X0N1cnJlbnQAU3RhcnRzV2l0aABnZXRfS2V5AE1vdmVOZXh0ADw+Y19fRGlzcGxheUNsYXNzMWQAYXBwADxSdW4+Yl9fMWMAc2V0X1Zpc2libGUAU3BlY2lhbEZvbGRlcgBHZXRGb2xkZXJQYXRoAERpcmVjdG9yeQBEaXJlY3RvcnlJbmZvAENyZWF0ZURpcmVjdG9yeQBNdXRleABNZXNzYWdlQm94AERpYWxvZ1Jlc3VsdABGcm9tQXJnYgBzZXRfSWNvbgBhZGRfQXBwbGljYXRpb25FeGl0AFJlYWRBbGxUZXh0AENvbnRhaW5zAFRyaW1TdGFydABJc1BhdGhSb290ZWQAc2V0X0FyZ3VtZW50cwBJc1doaXRlU3BhY2UASm9pbgBJbnNlcnQARW5kc1dpdGgASW50MzIAVHJ5UGFyc2UAZ2V0X0NvdW50AFRvQXJyYXkAVG9VcHBlcgBSZWdpc3RyeQBDdXJyZW50VXNlcgBMb2NhbE1hY2hpbmUAQ2xhc3Nlc1Jvb3QAVXNlcnMAQ3VycmVudENvbmZpZwA8PmNfX0Rpc3BsYXlDbGFzczI2AG91dHAARGF0YVJlY2VpdmVkRXZlbnRBcmdzADxSdW5IaWRkZW4+Yl9fMjQAPFJ1bkhpZGRlbj5iX18yNQBlMgBnZXRfRGF0YQBBcHBlbmRMaW5lAGdldF9TdGFuZGFyZE91dHB1dEVuY29kaW5nAGdldF9EZWZhdWx0AHNldF9TdGFuZGFyZE91dHB1dEVuY29kaW5nAHNldF9TdGFuZGFyZEVycm9yRW5jb2RpbmcARGF0YVJlY2VpdmVkRXZlbnRIYW5kbGVyAGFkZF9PdXRwdXREYXRhUmVjZWl2ZWQAYWRkX0Vycm9yRGF0YVJlY2VpdmVkAEJlZ2luT3V0cHV0UmVhZExpbmUAQmVnaW5FcnJvclJlYWRMaW5lAEdldFRlbXBQYXRoAEd1aWQATmV3R3VpZABEZWxldGUAPD5jX19EaXNwbGF5Q2xhc3MyZQBNZXNzYWdlQm94QnV0dG9ucwBidG5zAE1lc3NhZ2VCb3hEZWZhdWx0QnV0dG9uAGRlZgA8RXhlY1Rvb2xTdGVwPmJfXzJkAE1lc3NhZ2VCb3hJY29uAEZ1bmNgMQBEZWxlZ2F0ZQBQYXJzZQBTbGVlcABHZXRQcm9jZXNzZXNCeU5hbWUAS2lsbABJbnQ2NABCeXRlAENvbnZlcnQAVG9CeXRlAENyZWF0ZVN1YktleQBSZWdpc3RyeVZhbHVlS2luZABTZXRWYWx1ZQBPcGVuU3ViS2V5AERlbGV0ZVZhbHVlAERlbGV0ZVN1YktleVRyZWUAVHJpbUVuZABHZXREaXJlY3RvcnlOYW1lAEdldEZpbGVOYW1lAEdldEZpbGVzAEdldERpcmVjdG9yaWVzAEFjdGl2YXRlAFN5c3RlbS5OZXQuTmV0d29ya0luZm9ybWF0aW9uAFBpbmcAUGluZ1JlcGx5AFNlbmQASVBTdGF0dXMAZ2V0X1N0YXR1cwBTeXN0ZW0uTmV0AElQQWRkcmVzcwBnZXRfQWRkcmVzcwBnZXRfUm91bmR0cmlwVGltZQBQaW5nT3B0aW9ucwBnZXRfT3B0aW9ucwBnZXRfVHRsAGdldF9CdWZmZXIARm9ybWF0AFN0b3B3YXRjaABTdGFydE5ldwBTeXN0ZW0uTmV0LlNvY2tldHMAVGNwQ2xpZW50AEJlZ2luQ29ubmVjdABXYWl0SGFuZGxlAGdldF9Bc3luY1dhaXRIYW5kbGUAV2FpdE9uZQBFbmRDb25uZWN0AGdldF9FbGFwc2VkTWlsbGlzZWNvbmRzAFR5cGUAR2V0VHlwZQBNZW1iZXJJbmZvAGdldF9OYW1lAEdldEFkZHJlc3NCeXRlcwBQYWRMZWZ0AE1hdGgATWluAF9fU3RhdGljQXJyYXlJbml0VHlwZVNpemU9NTYAJCRtZXRob2QweDYwMDAwMzAtMQBQYWRSaWdodABEbnMAR2V0SG9zdE5hbWUATmV0d29ya0ludGVyZmFjZQBHZXRBbGxOZXR3b3JrSW50ZXJmYWNlcwBPcGVyYXRpb25hbFN0YXR1cwBnZXRfT3BlcmF0aW9uYWxTdGF0dXMATmV0d29ya0ludGVyZmFjZVR5cGUAZ2V0X05ldHdvcmtJbnRlcmZhY2VUeXBlAElQSW50ZXJmYWNlUHJvcGVydGllcwBHZXRJUFByb3BlcnRpZXMAVW5pY2FzdElQQWRkcmVzc0luZm9ybWF0aW9uQ29sbGVjdGlvbgBnZXRfVW5pY2FzdEFkZHJlc3NlcwBJRW51bWVyYXRvcmAxAFVuaWNhc3RJUEFkZHJlc3NJbmZvcm1hdGlvbgBJUEFkZHJlc3NJbmZvcm1hdGlvbgBBZGRyZXNzRmFtaWx5AGdldF9BZGRyZXNzRmFtaWx5AGdldF9JUHY0TWFzawBTeXN0ZW0uQ29sbGVjdGlvbnMASUVudW1lcmF0b3IAR2F0ZXdheUlQQWRkcmVzc0luZm9ybWF0aW9uQ29sbGVjdGlvbgBnZXRfR2F0ZXdheUFkZHJlc3NlcwBHYXRld2F5SVBBZGRyZXNzSW5mb3JtYXRpb24ASVBBZGRyZXNzQ29sbGVjdGlvbgBnZXRfRG5zQWRkcmVzc2VzACQkbWV0aG9kMHg2MDAwMDMyLTEAUmFuZG9tAE5leHQATWVtb3J5U3RyZWFtAFN0cmVhbQBnZXRfQVNDSUkAR2V0Qnl0ZXMAV3JpdGUAVWRwQ2xpZW50AFNvY2tldABnZXRfQ2xpZW50AHNldF9SZWNlaXZlVGltZW91dABBbnkASVBFbmRQb2ludABSZWNlaXZlAENvcHkAR2V0U3RyaW5nAFdlYlJlcXVlc3QAQ3JlYXRlAEh0dHBXZWJSZXF1ZXN0AHNldF9UaW1lb3V0AHNldF9SZWFkV3JpdGVUaW1lb3V0AHNldF9Vc2VyQWdlbnQAV2ViUmVzcG9uc2UAR2V0UmVzcG9uc2UASHR0cFdlYlJlc3BvbnNlAFVyaQBnZXRfUmVzcG9uc2VVcmkAb3BfSW5lcXVhbGl0eQBnZXRfSG9zdABIdHRwU3RhdHVzQ29kZQBnZXRfU3RhdHVzQ29kZQBnZXRfU3RhdHVzRGVzY3JpcHRpb24AV2ViSGVhZGVyQ29sbGVjdGlvbgBnZXRfSGVhZGVycwBTeXN0ZW0uQ29sbGVjdGlvbnMuU3BlY2lhbGl6ZWQATmFtZVZhbHVlQ29sbGVjdGlvbgBnZXRfQ29udGVudFR5cGUAR2V0UmVzcG9uc2VTdHJlYW0AUmVhZABXZWJFeGNlcHRpb24AZ2V0X1Jlc3BvbnNlAFN0cmVhbVJlYWRlcgBUZXh0UmVhZGVyAFJlYWRUb0VuZABJc051bGxPckVtcHR5AFJlbW92ZQBSZW1vdmVBdABnZXRfUgBnZXRfRwBnZXRfQgBNYXgAUm91bmQAUmVnZXhPcHRpb25zAFdyaXRlQWxsTGluZXMAPD5jX19EaXNwbGF5Q2xhc3MzMwA8PmNfX0Rpc3BsYXlDbGFzczM2ADxSdW5QbHVnaW4+Yl9fMzEAQ1MkPD44X19sb2NhbHMzNABlcnJzAGFib3J0ZWQAPFJ1blBsdWdpbj5iX18zMgBBY3Rpb24Ac2V0X0lzQmFja2dyb3VuZABBc3NlbWJseU5hbWUATG9hZABnZXRfTG9jYXRpb24ATWljcm9zb2Z0LkNTaGFycABDU2hhcnBDb2RlUHJvdmlkZXIAU3lzdGVtLkNvZGVEb20uQ29tcGlsZXIAQ29tcGlsZXJQYXJhbWV0ZXJzAHNldF9HZW5lcmF0ZUluTWVtb3J5AHNldF9HZW5lcmF0ZUV4ZWN1dGFibGUAU3RyaW5nQ29sbGVjdGlvbgBnZXRfUmVmZXJlbmNlZEFzc2VtYmxpZXMAQWRkUmFuZ2UAQ29kZURvbVByb3ZpZGVyAENvbXBpbGVyUmVzdWx0cwBDb21waWxlQXNzZW1ibHlGcm9tU291cmNlAENvbXBpbGVyRXJyb3JDb2xsZWN0aW9uAGdldF9FcnJvcnMAZ2V0X0hhc0Vycm9ycwBDb2xsZWN0aW9uQmFzZQBDb21waWxlckVycm9yAGdldF9MaW5lAGdldF9FcnJvclRleHQAZ2V0X0NvbXBpbGVkQXNzZW1ibHkAR2V0VHlwZXMARW1wdHlUeXBlcwBCaW5kaW5nRmxhZ3MAQmluZGVyAFBhcmFtZXRlck1vZGlmaWVyAEdldE1ldGhvZABnZXRfUmV0dXJuVHlwZQBWb2lkAFJ1bnRpbWVUeXBlSGFuZGxlAEdldFR5cGVGcm9tSGFuZGxlADw+Y19fRGlzcGxheUNsYXNzM2IAcGMAPFJ1bkNvZGVQbHVnaW4+Yl9fMzkATWV0aG9kQmFzZQBHZXRCYXNlRXhjZXB0aW9uADxFbnN1cmVQbHVnaW5UaHJlYWQ+Yl9fM2QAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTNlAEFwYXJ0bWVudFN0YXRlAFNldEFwYXJ0bWVudFN0YXRlAHNldF9OYW1lAC5jY3RvcgBTeXN0ZW0uR2xvYmFsaXphdGlvbgBDdWx0dXJlSW5mbwBnZXRfQ3VycmVudFVJQ3VsdHVyZQBEbGxJbXBvcnRBdHRyaWJ1dGUAdXNlcjMyLmRsbABDb250YWluc0tleQBnZXRfTXNnAGdldF9XUGFyYW0ASW50UHRyAFRvSW50MzIAPD5jX19EaXNwbGF5Q2xhc3M2NwA8LmN0b3I+Yl9fNTEAPD5jX19EaXNwbGF5Q2xhc3M2OQBDUyQ8PjhfX2xvY2FsczY4AHJnAGNsb3NlAGNhcmQAPC5jdG9yPmJfXzQ3ADwuY3Rvcj5iX180OAA8LmN0b3I+Yl9fNGEAPC5jdG9yPmJfXzRiADwuY3Rvcj5iX180ZAA8LmN0b3I+Yl9fNGYAPC5jdG9yPmJfXzU3AGNhcDIAPC5jdG9yPmJfXzQ2ADwuY3Rvcj5iX180OQA8LmN0b3I+Yl9fNGMAPC5jdG9yPmJfXzRlADwuY3Rvcj5iX181MAA8LmN0b3I+Yl9fNTIAPC5jdG9yPmJfXzUzADwuY3Rvcj5iX181NAA8LmN0b3I+Yl9fNTUAPC5jdG9yPmJfXzU2ADwuY3Rvcj5iX181OABLZXlFdmVudEFyZ3MAPC5jdG9yPmJfXzU5AGdldF9XaWR0aABnZXRfSGVpZ2h0AEVtcHR5AGdldF9HcmFwaGljcwBQZW4ARHJhd1BhdGgAc2V0X0JhY2tDb2xvcgBnZXRfV2hpdGUAc2V0X0ZvcmVDb2xvcgBDbG9zZQBEcmF3TGluZQBNb3VzZUJ1dHRvbnMAZ2V0X0J1dHRvbgBvcF9FeHBsaWNpdABaZXJvAHNldF9Gb250AHNldF9Mb2NhdGlvbgBTaXplAHNldF9TaXplAENvbnRyb2xDb2xsZWN0aW9uAGdldF9Db250cm9scwBLZXlzAGdldF9LZXlDb2RlAEZvcm1Cb3JkZXJTdHlsZQBzZXRfRm9ybUJvcmRlclN0eWxlAENvbnRhaW5lckNvbnRyb2wAQXV0b1NjYWxlTW9kZQBzZXRfQXV0b1NjYWxlTW9kZQBGb3JtU3RhcnRQb3NpdGlvbgBzZXRfU3RhcnRQb3NpdGlvbgBzZXRfVG9wTW9zdABzZXRfS2V5UHJldmlldwBzZXRfQ2xpZW50U2l6ZQBhZGRfSGFuZGxlQ3JlYXRlZABhZGRfUmVzaXplAFBhaW50RXZlbnRIYW5kbGVyAGFkZF9QYWludABzZXRfQXV0b1NpemUAQ29udGVudEFsaWdubWVudABzZXRfVGV4dEFsaWduAEN1cnNvcnMAZ2V0X0hhbmQAc2V0X0N1cnNvcgBhZGRfTW91c2VFbnRlcgBhZGRfTW91c2VMZWF2ZQBNb3VzZUV2ZW50SGFuZGxlcgBhZGRfTW91c2VEb3duAEFjdGlvbmAzAFBhZGRpbmcAc2V0X1BhZGRpbmcARG9ja1N0eWxlAHNldF9Eb2NrAFZpZXcAc2V0X1ZpZXcAc2V0X0Z1bGxSb3dTZWxlY3QAc2V0X011bHRpU2VsZWN0AHNldF9IaWRlU2VsZWN0aW9uAEJvcmRlclN0eWxlAHNldF9Cb3JkZXJTdHlsZQBDb2x1bW5IZWFkZXJDb2xsZWN0aW9uAGdldF9Db2x1bW5zAENvbHVtbkhlYWRlcgBhZGRfRG91YmxlQ2xpY2sAS2V5RXZlbnRIYW5kbGVyAGFkZF9LZXlEb3duAEJlZ2luVXBkYXRlAExpc3RWaWV3SXRlbUNvbGxlY3Rpb24AU3RyaW5nQ29tcGFyaXNvbgBFcXVhbHMATGlzdFZpZXdJdGVtAExpc3RWaWV3U3ViSXRlbUNvbGxlY3Rpb24AZ2V0X1N1Ykl0ZW1zAExpc3RWaWV3U3ViSXRlbQBzZXRfVGFnAGdldF9HcmF5AEVuZFVwZGF0ZQBJV2luMzJXaW5kb3cAU2VsZWN0ZWRMaXN0Vmlld0l0ZW1Db2xsZWN0aW9uAGdldF9TZWxlY3RlZEl0ZW1zAGdldF9UYWcARGF0ZVRpbWUAZ2V0X05vdwBnZXRfR2VuZXJpY1NhbnNTZXJpZgBnZGkzMi5kbGwAPD5jX19EaXNwbGF5Q2xhc3M5MgB0YWJCdG5zADwuY3Rvcj5iX183YgA8LmN0b3I+Yl9fN2MAPC5jdG9yPmJfXzdlADwuY3Rvcj5iX183ZgA8LmN0b3I+Yl9fODEAPD5jX19EaXNwbGF5Q2xhc3M5NABDUyQ8PjhfX2xvY2FsczkzADwuY3Rvcj5iX184MwA8LmN0b3I+Yl9fN2EAPC5jdG9yPmJfXzdkADwuY3Rvcj5iX184MAA8LmN0b3I+Yl9fODIAPC5jdG9yPmJfXzg0AHMyAENTJDw+OV9fQ2FjaGVkQW5vbnltb3VzTWV0aG9kRGVsZWdhdGU4ZAA8LmN0b3I+Yl9fODUAPC5jdG9yPmJfXzg2AENTJDw+OV9fQ2FjaGVkQW5vbnltb3VzTWV0aG9kRGVsZWdhdGU4ZgA8LmN0b3I+Yl9fODcAPC5jdG9yPmJfXzg4AEludmFsaWRhdGUAc2V0X0NhcHR1cmUAUmVtb3ZlTWVzc2FnZUZpbHRlcgBzZXRfV2lkdGgAYWRkX01vdXNlTW92ZQBhZGRfTW91c2VVcABUZXh0Qm94QmFzZQBzZXRfTXVsdGlsaW5lAHNldF9SZWFkT25seQBTY3JvbGxCYXJzAHNldF9TY3JvbGxCYXJzAEFkZE1lc3NhZ2VGaWx0ZXIARm9ybUNsb3NlZEV2ZW50SGFuZGxlcgBhZGRfRm9ybUNsb3NlZABQb2ludFRvQ2xpZW50AGdldF9WaXNpYmxlAGdldF9Cb3VuZHMAU3lzdGVtLldpbmRvd3MuRm9ybXMuTGF5b3V0AEFycmFuZ2VkRWxlbWVudENvbGxlY3Rpb24AZ2V0X1RvcABzZXRfVG9wAGdldF9Gb250AFRleHRSZW5kZXJlcgBNZWFzdXJlVGV4dABnZXRfQ2xpZW50U2l6ZQA8PmNfX0Rpc3BsYXlDbGFzczk4ADxMb2c+Yl9fOTYAZ2V0X0ludm9rZVJlcXVpcmVkAEFwcGVuZFRleHQAPD5jX19EaXNwbGF5Q2xhc3M5YwBidG4APFJ1bkFjdGlvbj5iX185YQA8UnVuQWN0aW9uPmJfXzliAHNldF9Eb3VibGVCdWZmZXJlZABUb0ludDY0AGdldF9QYXJlbnQAZ2V0X0JhY2tDb2xvcgBnZXRfQ2xpZW50UmVjdGFuZ2xlAEZpbGxSZWN0YW5nbGUAZ2V0X0VuYWJsZWQAZ2V0X1RleHQARHJhd1N0cmluZwA8PmNfX0Rpc3BsYXlDbGFzc2I1ADwuY3Rvcj5iX19hNgA8LmN0b3I+Yl9fYTcAPC5jdG9yPmJfX2E5ADwuY3Rvcj5iX19hYQA8LmN0b3I+Yl9fYWMAPD5jX19EaXNwbGF5Q2xhc3NiNwBDUyQ8PjhfX2xvY2Fsc2I2ADwuY3Rvcj5iX19hZQA8LmN0b3I+Yl9fYTUAPC5jdG9yPmJfX2E4ADwuY3Rvcj5iX19hYgA8LmN0b3I+Yl9fYWQAPC5jdG9yPmJfX2FmADw+Y19fRGlzcGxheUNsYXNzYzMAPD5jX19EaXNwbGF5Q2xhc3NjNQBjbnQAY2FuY2VsADxCdWlsZFBpbmdUYWI+Yl9fYmQAPEJ1aWxkUGluZ1RhYj5iX19jMAA8QnVpbGRQaW5nVGFiPmJfX2MxADxCdWlsZFBpbmdUYWI+Yl9fYzIAQ1MkPD44X19sb2NhbHNjNABzegA8QnVpbGRQaW5nVGFiPmJfX2JlADxCdWlsZFBpbmdUYWI+Yl9fYmYARG91YmxlAEJvb2xlYW4APD5jX19EaXNwbGF5Q2xhc3NjZAA8QnVpbGRUcmFjZXJ0VGFiPmJfX2M4ADxCdWlsZFRyYWNlcnRUYWI+Yl9fY2IAPEJ1aWxkVHJhY2VydFRhYj5iX19jYwA8QnVpbGRUcmFjZXJ0VGFiPmJfX2M5ADxCdWlsZFRyYWNlcnRUYWI+Yl9fY2EAPD5jX19EaXNwbGF5Q2xhc3NkNwA8PmNfX0Rpc3BsYXlDbGFzc2RiAHR5cGVzAHRvZ2dsZXMAPEJ1aWxkRG5zVGFiPmJfX2QyADxCdWlsZERuc1RhYj5iX19kNQA8QnVpbGREbnNUYWI+Yl9fZDYAQ1MkPD44X19sb2NhbHNkOABubQBzdgB0cAA8QnVpbGREbnNUYWI+Yl9fZDMAPEJ1aWxkRG5zVGFiPmJfX2Q0ADw+Y19fRGlzcGxheUNsYXNzZDkAdGkAPEJ1aWxkRG5zVGFiPmJfX2QxADw+Y19fRGlzcGxheUNsYXNzZTUAPD5jX19EaXNwbGF5Q2xhc3NlNwBnbwA8QnVpbGRIdHRwVGFiPmJfX2RlADxCdWlsZEh0dHBUYWI+Yl9fZTEAPEJ1aWxkSHR0cFRhYj5iX19lMgA8QnVpbGRIdHRwVGFiPmJfX2UzADxCdWlsZEh0dHBUYWI+Yl9fZTQAQ1MkPD44X19sb2NhbHNlNgB1ADxCdWlsZEh0dHBUYWI+Yl9fZGYAPEJ1aWxkSHR0cFRhYj5iX19lMABzZXRfU3VwcHJlc3NLZXlQcmVzcwA8PmNfX0Rpc3BsYXlDbGFzc2YyADw+Y19fRGlzcGxheUNsYXNzZjQAPD5jX19EaXNwbGF5Q2xhc3NmNwBzY2FuADxCdWlsZFBvcnRUYWI+Yl9fZWEAPEJ1aWxkUG9ydFRhYj5iX19lZAA8QnVpbGRQb3J0VGFiPmJfX2YwADxCdWlsZFBvcnRUYWI+Yl9fZjEAQ1MkPD44X19sb2NhbHNmMwA8QnVpbGRQb3J0VGFiPmJfX2ViADxCdWlsZFBvcnRUYWI+Yl9fZWMAcG9ydHMAPEJ1aWxkUG9ydFRhYj5iX19lZQA8QnVpbGRQb3J0VGFiPmJfX2VmAF9fU3RhdGljQXJyYXlJbml0VHlwZVNpemU9NTIAJCRtZXRob2QweDYwMDAxNTAtMQA8PmNfX0Rpc3BsYXlDbGFzczEwMwBtawBpcDEAaXAyADxCdWlsZFN1Ym5ldFRhYj5iX19mZgA8QnVpbGRTdWJuZXRUYWI+Yl9fMTAwADxCdWlsZFN1Ym5ldFRhYj5iX18xMDEAPEJ1aWxkU3VibmV0VGFiPmJfXzEwMgBhZGRfVGV4dENoYW5nZWQAPD5jX19EaXNwbGF5Q2xhc3MxMGEAPD5jX19EaXNwbGF5Q2xhc3MxMGQAcmVmcmVzaAA8QnVpbGRMb2NhbFRhYj5iX18xMDUAPEJ1aWxkTG9jYWxUYWI+Yl9fMTA4ADxCdWlsZExvY2FsVGFiPmJfXzEwOQA8QnVpbGRMb2NhbFRhYj5iX18xMDYAQ1MkPD44X19sb2NhbHMxMGIAaW5mbwA8QnVpbGRMb2NhbFRhYj5iX18xMDcAQ2xpcGJvYXJkAFNldFRleHQAPC5jdG9yPmJfXzExMQA8LmN0b3I+Yl9fMTEyADwuY3Rvcj5iX18xMTMARm9jdXMAZ2V0X0lCZWFtAGFkZF9FbnRlcgBhZGRfTGVhdmUAZ2V0X0ZvY3VzZWQAPC5jdG9yPmJfXzExYQA8LmN0b3I+Yl9fMTFiADwuY3Rvcj5iX18xMWMAPC5jdG9yPmJfXzExZAA8LmN0b3I+Yl9fMTFlADwuY3Rvcj5iX18xMWYAU3RvcABDb21wb25lbnQAc2V0X0ludGVydmFsAGFkZF9UaWNrAGFkZF9EaXNwb3NlZAA8PmNfX0Rpc3BsYXlDbGFzczEyOAA8TGluZT5iX18xMjYAU2F2ZUZpbGVEaWFsb2cARmlsZURpYWxvZwBzZXRfRmlsdGVyAENvbW1vbkRpYWxvZwBTaG93RGlhbG9nAGdldF9GaWxlTmFtZQA8LmN0b3I+Yl9fMTMwADwuY3Rvcj5iX18xMzEAPC5jdG9yPmJfXzEzMgA8LmN0b3I+Yl9fMTMzADwuY3Rvcj5iX18xMzQAc2V0X0ludGVncmFsSGVpZ2h0AHNldF9IZWlnaHQAQnV0dG9uAExpc3RDb250cm9sAGdldF9TZWxlY3RlZEluZGV4AE9iamVjdENvbGxlY3Rpb24AR2V0VGV4dAA8PmNfX0Rpc3BsYXlDbGFzczE1ZAA8LmN0b3I+Yl9fMTQ2ADwuY3Rvcj5iX18xNDcAPC5jdG9yPmJfXzE0OAA8LmN0b3I+Yl9fMTQ5ADw+Y19fRGlzcGxheUNsYXNzMTVmAENTJDw+OF9fbG9jYWxzMTVlAGNpADwuY3Rvcj5iX18xNGIAPC5jdG9yPmJfXzE0YwA8LmN0b3I+Yl9fMTQ1ADwuY3Rvcj5iX18xNGEAPC5jdG9yPmJfXzE0ZAA8LmN0b3I+Yl9fMTRlADwuY3Rvcj5iX18xNGYAPC5jdG9yPmJfXzE1MAA8LmN0b3I+Yl9fMTUxAEZvcm1DbG9zaW5nRXZlbnRBcmdzADwuY3Rvcj5iX18xNTIAPC5jdG9yPmJfXzE1MwBEcmF3RWxsaXBzZQBBZGRFbGxpcHNlAFJlZ2lvbgBzZXRfUmVnaW9uAEZvcm1DbG9zaW5nRXZlbnRI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VV8pAA0ACgA7ACAAYQBwAHAAOgAgAFhi2Hbcg1VTIAAtAD4AIACUXih1IADMkYR2YWfudiwAIAAWfwF4PABUAEEAQgA+AA1U8Hk8AFQAQQBCAD4AfVTkTlsAPABUAEEAQgA+AMJTcGVdACAAKAAGUpSWJntfTqVj11N6ejxoLAAgACtUeno8aIR2fVTkTih1FV/3UwVTT087AA0ACgA7ACAAIAAgACAAIAAgAPh2+VvvjYRfCWMgAHcAZwB0AHIAYQB5AC4AYgBhAHQAIABAYihX7nZVX+OJkGcsACAAL2UBYyAAJQCvc4NY2FPPkSUAKQANAAoAOwAgAGEAcABwACAAPQAgAG4AcAAJALCLi04sZwkAbgBvAHQAZQBwAGEAZAAuAGUAeABlAA0ACgA7ACAAYQBwAHAAIAA9ACAAZwB5AAkA006TXu52VV8JAEMAOgBcAFQAbwBvAGwAcwBcAFcAZwBJAG0AZQANAAoAOwAgAGEAcABwACAAPQAgAGIAZAAJAH52pl4JAGgAdAB0AHAAcwA6AC8ALwB3AHcAdwAuAGIAYQBpAGQAdQAuAGMAbwBtAA0ACgA7ACAAaFFAXOtfd2MulSAAKAA8aA9fOgAgAGMAdAByAGwALwBhAGwAdAAvAHMAaABpAGYAdAAvAHcAaQBuACAAxH4IVCwAIACCWSAAYwB0AHIAbAArAGEAbAB0ACsAdAA7ACAAbgBvAG4AZQAvAG8AZgBmACAAgXkodSkAOgANAAoAOwAgAGgAbwB0AGsAZQB5AF8AdABvAG8AbABiAG8AeAAgAD0AIABjAHQAcgBsACsAYQBsAHQAKwB0ACAAIAAgAFNiAF/lXXdRsXsNAAoAOwAgAGgAbwB0AGsAZQB5AF8AcABsAHUAZwBpAG4AcwAgAD0AIABjAHQAcgBsACsAYQBsAHQAKwBwACAAIAAgAFNiAF/SY/ZOoXsGdA0ACgA7ACAAaABvAHQAawBlAHkAXwBtAGUAbgB1ACAAIAAgACAAPQAgAGMAdAByAGwAKwBhAGwAdAArAHcAIAAgACAAKFdJUQdoBFk+Zjp5WGLYdtyDVVMNAAoAOwAgACgAVwBnAEkAbQBlACAAhHYgAGYAdQB6AHoAeQAvAHAAYQBzAHQAZQAvAGsAZQB5AGYAaQB4ACAASXuTj2VR1WxNkW5/LGflXXdRDU5/Tyh1LAAgAFl1QHcNTnFfzVQpAA0ACgABB+Vdd1GxewEPVABvAG8AbABiAG8AeAAAG2IAdQBpAGwAdABpAG4AOgB0AG8AbwBsAHMAAAEAC3QAbwBvAGwAcwAAB24AZQB0AAAJUX/cfuVdd1EBG04AZQB0AHcAbwByAGsAIAB0AG8AbwBsAHMAACFiAHUAaQBsAHQAaQBuADoAbgBlAHQAdABvAG8AbABzAAAJdwBsAGcAagAACWMAbABpAHAAAAtqUjSNf2eGU/JTASNDAGwAaQBwAGIAbwBhAHIAZAAgAGgAaQBzAHQAbwByAHkAABliAHUAaQBsAHQAaQBuADoAYwBsAGkAcAAAB2oAbABiAAAFYgBqAAAFv09+ewEZUwB0AGkAYwBrAHkAIABuAG8AdABlAHMAABliAHUAaQBsAHQAaQBuADoAbgBvAHQAZQAAC24AbwB0AGUAcwAABXkAcwAACZyYcoL+YtZTARlDAG8AbABvAHIAIABwAGkAYwBrAGUAcgAAG2IAdQBpAGwAdABpAG4AOgBjAG8AbABvAHIAAAtjAG8AbABvAHIAAAnSY/ZOoXsGdAEdUABsAHUAZwBpAG4AIABtAGEAbgBhAGcAZQByAAAjYgB1AGkAbAB0AGkAbgA6AHAAbAB1AGcAaQBuAG0AZwByAAAJYwBqAGcAbAAAFWMAdAByAGwAKwBhAGwAdAArAHQAABVjAHQAcgBsACsAYQBsAHQAKwBwAAAVYwB0AHIAbAArAGEAbAB0ACsAdwAAFWMAbwBuAGYAaQBnAC4AdAB4AHQAAAdhAHAAcAAAX14AKABcAFMAKwApAFwAcwArACgAXABTACsAKQBcAHMAKwAoACIAKAA/ADoAWwBeACIAXQAqACkAIgB8AFwAUwArACkAKAA/ADoAXABzACsAKAAuACoAKQApAD8AJAAAHWgAbwB0AGsAZQB5AF8AdABvAG8AbABiAG8AeAAAHWgAbwB0AGsAZQB5AF8AcABsAHUAZwBpAG4AcwAAF2gAbwB0AGsAZQB5AF8AbQBlAG4AdQAAB2oAcwBxAAAJYwBhAGwAYwAACeVdd1GxeyYgARFUAG8AbwBsAGIAbwB4ACYgAQXSY/ZOAQ9QAGwAdQBnAGkAbgBzAAAJhVFuf+Vdd1EBHUIAdQBpAGwAdAAtAGkAbgAgAHQAbwBvAGwAcwABB6GLl3toVgEVQwBhAGwAYwB1AGwAYQB0AG8AcgAAH5ReKHUgACgAYwBvAG4AZgBpAGcALgB0AHgAdAApAAEjQQBwAHAAcwAgACgAYwBvAG4AZgBpAGcALgB0AHgAdAApAAAFTZFufwENQwBvAG4AZgBpAGcAACUWf5GPTZFufyAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAJiABM0UAZABpAHQAIABjAG8AbgBmAGkAZwAgACgAYwBvAG4AZgBpAGcALgB0AHgAdAApACYgAQnNkX2PTZFufwEbUgBlAGwAbwBhAGQAIABjAG8AbgBmAGkAZwAAJVMAdABhAHIAdAAgAHcAaQB0AGgAIABXAGkAbgBkAG8AdwBzAAALcGVuY+52VV8mIAEZRABhAHQAYQAgAGYAbwBsAGQAZQByACYgAQtoUUBc6193Yy6VAR1HAGwAbwBiAGEAbAAgAGgAbwB0AGsAZQB5AHMAAEsoVyAAYwBvAG4AZgBpAGcALgB0AHgAdAAgAIR2IABoAG8AdABrAGUAeQBfACoAIAAule5POWUgACgAbgBvAG4AZQAgAIF5KHUpAAFlZQBkAGkAdAAgAGgAbwB0AGsAZQB5AF8AKgAgAGsAZQB5AHMAIABpAG4AIABjAG8AbgBmAGkAZwAuAHQAeAB0ACAAKABuAG8AbgBlACAAdABvACAAZABpAHMAYQBiAGwAZQApAAAFAJD6UQEJRQB4AGkAdAAAC1NiAF/lXXdRsXsBGU8AcABlAG4AIAB0AG8AbwBsAGIAbwB4AAAHOgAgACAAAA0+Zjp5WGLYdtyDVVMBHVMAaABvAHcAIAB0AHIAYQB5ACAAbQBlAG4AdQAAD3AAbAB1AGcAaQBuADoAABdjAG8AZABlAHAAbAB1AGcAaQBuADoAAAcgACAAKAAAAykAAC8oAOBl0mP2TiAAFCAgAD5lIABwAGwAdQBnAGkAbgBzAFwAKgAuAHQAeAB0ACkAAUEoAG4AbwAgAHAAbAB1AGcAaQBuAHMAIAAUICAAcAB1AHQAIABwAGwAdQBnAGkAbgBzAFwAKgAuAHQAeAB0ACkAAQvSY/ZOoXsGdCYgAR9QAGwAdQBnAGkAbgAgAG0AYQBuAGEAZwBlAHIAJiABEWIAdQBpAGwAdABpAG4AOgAARSgA4GUgABQgIABjAG8AbgBmAGkAZwAuAHQAeAB0ACAAzJGgUiAAYQBwAHAAIAA9ACAAFn8BeCAADVTweSAAfVTkTikAAWkoAG4AbwBuAGUAIAAUICAAYQBkAGQAIAAnAGEAcABwACAAPQAgAGMAbwBkAGUAIABuAGEAbQBlACAAYwBvAG0AbQBhAG4AZAAnACAAaQBuACAAYwBvAG4AZgBpAGcALgB0AHgAdAApAAELdwBnAGkAbQBlAAApVwBnAFQAcgBhAHkAUwBpAG4AZwBsAGUASQBuAHMAdABhAG4AYwBlAAAzVwBnAFQAcgBhAHkAIADyXShX0I9MiCAAFCAgAPeLSFHOTlhi2HYAkPpR52WeW4tPAjABgI1XAGcAVAByAGEAeQAgAGkAcwAgAGEAbAByAGUAYQBkAHkAIAByAHUAbgBuAGkAbgBnACAAFCAgAGUAeABpAHQAIAB0AGgAZQAgAG8AbABkACAAaQBuAHMAdABhAG4AYwBlACAAZgByAG8AbQAgAHQAaABlACAAdAByAGEAeQAgAGYAaQByAHMAdAAuAAENVwBnAFQAcgBhAHkAAAPlXQEDVAAABWAAbgAABzoALwAvAAAJL1SoUjFZJY0BG0wAYQB1AG4AYwBoACAAZgBhAGkAbABlAGQAAAU6ACAAABN0AG8AbwBsAHMALgB0AHgAdAAAAwoAAA9bAHMAaABlAGwAbABdAAALWwBjAG0AZABdAAAVcwBoAGUAbABsAGIAbABvAGMAawAAGVsAcABvAHcAZQByAHMAaABlAGwAbABdAAAJWwBwAHMAXQAAD3AAcwBiAGwAbwBjAGsAABtbAC8AcABvAHcAZQByAHMAaABlAGwAbABdAAALWwAvAHAAcwBdAAARWwBzAGgAZQBsAGwAeABdAAANWwBjAG0AZAB4AF0AABdzAGgAZQBsAGwAYgBsAG8AYwBrAHgAABtbAHAAbwB3AGUAcgBzAGgAZQBsAGwAeABdAAALWwBwAHMAeABdAAARcABzAGIAbABvAGMAawB4AAAJdABhAGIAIAAAAz8AAAtjAG8AbABzACAAAAXlXXdRAQtUAG8AbwBsAHMAAA9iAHUAdAB0AG8AbgAgAAAJSABLAEMAVQAAI0gASwBFAFkAXwBDAFUAUgBSAEUATgBUAF8AVQBTAEUAUgAACUgASwBMAE0AACVIAEsARQBZAF8ATABPAEMAQQBMAF8ATQBBAEMASABJAE4ARQAACUgASwBDAFIAACNIAEsARQBZAF8AQwBMAEEAUwBTAEUAUwBfAFIATwBPAFQAAAdIAEsAVQAAFUgASwBFAFkAXwBVAFMARQBSAFMAAAlIAEsAQwBDAAAnSABLAEUAWQBfAEMAVQBSAFIARQBOAFQAXwBDAE8ATgBGAEkARwAAFWIAYQBkACAAaABpAHYAZQA6ACAAAA8gACAAbwB1AHQAOgAgAAAPIAAgAGUAeABpAHQAIAAAFWUAeABpAHQAIABjAG8AZABlACAAABd3AGcAaQBtAGUALQB0AG8AbwBsAC0AAQNOAAAHbQBzAGcAAA9jAG8AbgBmAGkAcgBtAAALdABpAHQAbABlAAAPYgB1AHQAdABvAG4AcwAABW8AawAAEW8AawBjAGEAbgBjAGUAbAAAD2QAZQBmAGEAdQBsAHQAAAMxAAALYQBiAG8AcgB0AAAJdwBhAGkAdAAACWsAaQBsAGwAABMgACAAawBpAGwAbABlAGQAIAAAByAAeAAgAAAHcgB1AG4AAAtzAGgAZQBsAGwAAA9jAG0AZAAuAGUAeABlAAAHLwBjACAAAAkuAGMAbQBkAAAJLgBwAHMAMQAAHXAAbwB3AGUAcgBzAGgAZQBsAGwALgBlAHgAZQAAUy0ATgBvAFAAcgBvAGYAaQBsAGUAIAAtAEUAeABlAGMAdQB0AGkAbwBuAFAAbwBsAGkAYwB5ACAAQgB5AHAAYQBzAHMAIAAtAEYAaQBsAGUAIAABZ1sAQwBvAG4AcwBvAGwAZQBdADoAOgBPAHUAdABwAHUAdABFAG4AYwBvAGQAaQBuAGcAIAA9ACAAWwBUAGUAeAB0AC4ARQBuAGMAbwBkAGkAbgBnAF0AOgA6AFUAVABGADgADQAKAAANcwBoAGUAbABsAHgAACENAAoAZQBjAGgAbwAuAA0ACgBwAGEAdQBzAGUADQAKAABnDQAKAFcAcgBpAHQAZQAtAEgAbwBzAHQAIAAnACcADQAKAFIAZQBhAGQALQBIAG8AcwB0ACAAJwBwAHIAZQBzAHMAIABFAE4AVABFAFIAIAB0AG8AIABjAGwAbwBzAGUAJwANAAoAAQlvAHAAZQBuAAAPcgBlAGcALQBzAGUAdAABAyAAAAtkAHcAbwByAGQAAAtxAHcAbwByAGQAAA1lAHgAcABhAG4AZAAAC20AdQBsAHQAaQAADWIAaQBuAGEAcgB5AAAPcgBlAGcALQBkAGUAbAABEWYAaQBsAGUALQBkAGUAbAABP3IAZQBmAHUAcwBlACAAdABvACAAZABlAGwAZQB0AGUAIABhACAAZAByAGkAdgBlACAAcgBvAG8AdAA6ACAAABEgACAAcwBrAGkAcAA6ACAAABUgACAAZABlAGwAZQB0AGUAZAAgAAAVLAAgAHMAawBpAHAAcABlAGQAIAAAJSAAKABpAG4AIAB1AHMAZQAgAC8AIABsAG8AYwBrAGUAZAApAAALbQBrAGQAaQByAAAddQBuAGsAbgBvAHcAbgAgAHYAZQByAGIAOgAgAABVdABvAG8AbABzAC4AdAB4AHQAIAA6Tnp6FmINTlhbKFcUIBQgKFcgAHcAZwBpAG0AZQAuAGIAYQB0ACAADFTudlVf+l4ATipOc1PvU/ttoFKfUv2AAWt0AG8AbwBsAHMALgB0AHgAdAAgAG0AaQBzAHMAaQBuAGcALwBlAG0AcAB0AHkAIAAtACAAYwByAGUAYQB0AGUAIABpAHQAIABuAGUAeAB0ACAAdABvACAAdwBnAGkAbQBlAC4AYgBhAHQAAVlyAGUAcABsAHkAIABmAHIAbwBtACAAewAwAH0AOgAgAHQAaQBtAGUAPQB7ADEAfQBtAHMAIAB0AHQAbAA9AHsAMgB9ACAAYgB5AHQAZQBzAD0AewAzAH0AABFzAHQAYQB0AHUAcwA6ACAAAA9lAHIAcgBvAHIAOgAgAAAFIAAgAAAVbQBzACAAIAAoAGQAbwBuAGUAKQAABW0AcwAAEyAAIABlAHIAcgBvAHIAOgAgAAAhYwBsAG8AcwBlAGQAIAAoAHQAaQBtAGUAbwB1AHQAIAAAB20AcwApAAANbwBwAGUAbgAgACAAABFjAGwAbwBzAGUAZAAgACgAABNJAFAAdgA0ACAAbwBuAGwAeQAAC6ljAXgNTt6P7X4BJ24AbwBuAC0AYwBvAG4AdABpAGcAdQBvAHUAcwAgAG0AYQBzAGsAARViAGEAZAAgAHAAcgBlAGYAaQB4AAALKmcHY5pbMFdAVwEXdQBuAHMAcABlAGMAaQBmAGkAZQBkAAAf3lavczBXQFcgACgAbABvAG8AcABiAGEAYwBrACkAARFsAG8AbwBwAGIAYQBjAGsAAB3BeQlnMFdAVyAAKABSAEYAQwAxADkAMQA4ACkAASNwAHIAaQB2AGEAdABlACAAKABSAEYAQwAxADkAMQA4ACkAABn+lO+NLGcwVyAAKABBAFAASQBQAEEAKQABJWwAaQBuAGsALQBsAG8AYwBhAGwAIAAoAEEAUABJAFAAQQApAAEh0I8lhEZVp34gAE4AQQBUACAAKABDAEcATgBBAFQAKQABI2MAYQByAHIAaQBlAHIALQBnAHIAYQBkAGUAIABOAEEAVAABHcR+rWQgACgAbQB1AGwAdABpAGMAYQBzAHQAKQABE20AdQBsAHQAaQBjAGEAcwB0AAAb3U9ZdSAAKAByAGUAcwBlAHIAdgBlAGQAKQABEXIAZQBzAGUAcgB2AGUAZAAACWxRUX8wV0BXAQ1wAHUAYgBsAGkAYwAAA0EAAANCAAADQwAAA0QAAANFAAAFqWMBeAEJTQBhAHMAawAAEzoAIAAgACAAIAAgACAAIAAgAAAJIAAgACgALwAABxqQTZEmewERVwBpAGwAZABjAGEAcgBkAAALOgAgACAAIAAgAAAJUX/cfjBXQFcBD04AZQB0AHcAbwByAGsAAAk6ACAAIAAgAAAJf16tZDBXQFcBE0IAcgBvAGEAZABjAGEAcwB0AAAJ71ModQOD9FYBFUgAbwBzAHQAIAByAGEAbgBnAGUAAAcgAC0AIAABC+9TKHU7TjpncGUBC0gAbwBzAHQAcwAADToAIAAgACAAIAAgAAAJMFdAV3t8i1cBCVQAeQBwAGUAAA86ACAAIAAgACAAIAAgAAAFe3wrUgELQwBsAGEAcwBzAAAHjE7bjzZSAQ1CAGkAbgBhAHIAeQAAG8Zil18qWY54hk4gACgAO046Z3BlDU6zjSkAAUF0AG8AbwAgAG0AYQBuAHkAIABzAHUAYgBuAGUAdABzACAAKABuAG8AIABoAG8AcwB0AHMAIABsAGUAZgB0ACkAAAXGYgZSAQtzAHAAbABpAHQAAAcgADpOIAABDSAAaQBuAHQAbwAgAAAJIAAqTiAALwABCSAAeAAgAC8AAAM6AAAHIAAgACAAAAkgACAAIAAoAABFTVIAfyAAIAAgACAAqWMBeCAAIAAgACAAIAAgACAAIAAgACAAIAAgACAAIADvUyh1O046ZyAAIAAgACAAIAAakE2RJnsBW3AAcgBlAGYAaQB4ACAAIABtAGEAcwBrACAAIAAgACAAIAAgACAAIAAgACAAIAAgAGgAbwBzAHQAcwAgACAAIAAgACAAIAAgACAAdwBpAGwAZABjAGEAcgBkAAAHO046Zw1UAQlIAG8AcwB0AAAFXQAgAAARIAAgAEkAUAB2ADQAOgAgAAAHIAAvACAAAAVRf3NRAQ9HAGEAdABlAHcAYQB5AAAPIAAgAEQATgBTADoAIAAABU4AUwAAC0MATgBBAE0ARQAAB1AAVABSAAAFTQBYAAAHVABYAFQAAAlBAEEAQQBBAAARYgBhAGQAIAB0AHkAcABlAAAVRABOAFMAIAByAGMAbwBkAGUAPQAAFyAAKABOAFgARABPAE0AQQBJAE4AKQAAByAAfAAgAAALdAB5AHAAZQAgAAAFIAAoAAAPIABiAHkAdABlAHMAKQAADyAAIAAgAHQAdABsAD0AAAfgZbCLVV8BFW4AbwAgAHIAZQBjAG8AcgBkAHMAABtkAG4AcwAgAG4AYQBtAGUAIABsAG8AbwBwAAARaAB0AHQAcABzADoALwAvAAAdVwBnAEkAbQBlAC0ATgBlAHQAVABvAG8AbABzAAENIAAgACgALQA+ACAAAQtIAFQAVABQACAAAA1TAGUAcgB2AGUAcgAAEVMAZQByAHYAZQByADoAIAAAHUMAbwBuAHQAZQBuAHQALQBUAHkAcABlADoAIAABDUIAbwBkAHkAOgAgAAANIABiAHkAdABlAHMAAA1UAFQARgBCADoAIAAAGW0AcwAgACAAIABUAG8AdABhAGwAOgAgAAALRQByAHIAOgAgAAAraAB0AHQAcABzADoALwAvAGEAcABpAC4AaQBwAGkAZgB5AC4AbwByAGcAABNuAG8AdABlAHMALgB0AHgAdAAAAyMAAAVYADIAAAVIACAAAAkgACAAUwAgAAALJQAgACAAVgAgAAADJQAABVsALwAACyoALgB0AHgAdAAAQV4AKABjAG8AZABlAHwAbgBhAG0AZQB8AGQAZQBzAGMAKQBcAHMAKgBbAD0AOgBdAFwAcwAqACgALgArACkAJAAACWMAbwBkAGUAAAluAGEAbQBlAAANYwBzAGgAYQByAHAAAClwAGwAdQBnAGkAbgBzAC0AZABpAHMAYQBiAGwAZQBkAC4AdAB4AHQAAQmMWxBiLAAgAAENZABvAG4AZQAsACAAAA0g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ANABAAwAAADwOgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
