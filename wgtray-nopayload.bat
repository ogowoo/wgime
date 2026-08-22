@echo off
rem ============================================================
rem  WgTray - tray-only toolbox (NO IME): taskbar tray menu +
rem  tools.txt toolbox + plugins\*.txt + config.txt apps
rem  bat bootstrap -> PowerShell -> in-memory C# (or prebuilt DLL)
rem  Errors are logged to %TEMP%\WgTray_error.log
rem ============================================================
set "WGTRAY_PATH=%~f0"
set "WGTRAY_DIR=%~dp0"
if /i "%~1"=="_h" goto :main
rem WGTRAY_DEBUG=1: keep console visible so startup errors can be seen on locked-down machines
if defined WGTRAY_DEBUG (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '_h'"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -ArgumentList '_h' -WindowStyle Hidden"
)
exit /b
:main
if defined WGTRAY_DEBUG (
  powershell.exe -STA -NoProfile -NoLogo -ExecutionPolicy Bypass -Command "try { $s=[IO.File]::ReadAllText($env:WGTRAY_PATH,[Text.Encoding]::UTF8); $i=$s.LastIndexOf('###PWSHTRAY###'); $p=$s.Substring($i+14); Invoke-Expression $p } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)); Write-Host ($_ | Out-String) -ForegroundColor Red; Read-Host 'press ENTER to exit' }"
) else (
  powershell.exe -STA -NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -Command "try { $s=[IO.File]::ReadAllText($env:WGTRAY_PATH,[Text.Encoding]::UTF8); $i=$s.LastIndexOf('###PWSHTRAY###'); $p=$s.Substring($i+14); Invoke-Expression $p } catch { [IO.File]::WriteAllText((Join-Path $env:TEMP 'WgTray_error.log'), ($_ | Out-String)); Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show(($_ | Out-String),'WgTray Error') | Out-Null }"
)
exit /b
###PWSHTRAY###
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
$wgLoaded = $false
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
    class AlarmItem {
        public string Time = "07:30";
        public string Name = "闹钟";
        public bool Enabled = true;
        public string Repeat = "每天";
        public string Mode = "popup";    // popup=居中弹窗  full=全屏强制休息  tray=托盘气泡
        public AlarmItem() {}
        public AlarmItem(string time, string name, bool enabled) { Time = time; Name = name; Enabled = enabled; Repeat = "每天"; }
        public AlarmItem(string time, string name, bool enabled, string repeat) { Time = time; Name = name; Enabled = enabled; Repeat = repeat; }
    }
    static List<AlarmItem> alarms = new List<AlarmItem>();
    static System.Threading.SynchronizationContext uiContext;
    static readonly object alarmLock = new object();
    static List<System.Threading.Timer> snoozeTimers = new List<System.Threading.Timer>();
    static List<Form> fullscreenAlarms = new List<Form>();   // 全屏提醒实例 (强制休息), 防止重复
    // 旧版单闹钟字段，仅用于读取旧 clock.cfg 后迁移。
    static string alarmTime = "";
    static bool alarmOn = false;

    static void LoadCfg()
    {
        try {
            alarms.Clear();
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
                else if (k.StartsWith("alarm.")) {
                    string[] a = v.Split(new char[] { '|' }, 5);
                    if (a.Length >= 2 && ValidAlarmTime(a[0])) {
                        string nm = a.Length >= 3 ? UnescapeCfg(a[2]) : "闹钟";
                        string rp = a.Length >= 4 ? UnescapeCfg(a[3]) : "每天";
                        string md = a.Length >= 5 ? UnescapeCfg(a[4]) : "popup";
                        if (md != "popup" && md != "full" && md != "tray") md = "popup";
                        AlarmItem item = new AlarmItem(a[0], nm, a[1] == "1", rp); item.Mode = md;
                        alarms.Add(item);
                    }
                }
            }
            // 与旧版配置兼容：首次发现 alarm/alarmon 时自动迁移。
            if (alarms.Count == 0 && ValidAlarmTime(alarmTime)) alarms.Add(new AlarmItem(alarmTime, "旧版闹钟", alarmOn));
        } catch {}
    }
    static bool ValidAlarmTime(string t)
    {
        return System.Text.RegularExpressions.Regex.IsMatch(t == null ? "" : t, @"^([01]\d|2[0-3]):[0-5]\d$");
    }
    static string EscapeCfg(string s) { return Uri.EscapeDataString((s == null ? "" : s).Replace("\r", " ").Replace("\n", " ")); }
    static string UnescapeCfg(string s) { try { return Uri.UnescapeDataString(s == null ? "" : s); } catch { return s == null ? "" : s; } }
    static void SaveCfg()
    {
        try {
            Directory.CreateDirectory(CfgDir());
            var b = new System.Text.StringBuilder();
            b.Append("hourly = ").Append(hourly ? "1" : "0").Append("\n");
            b.Append("reminder = ").Append(reminder).Append("\n");
            for (int i = 0; i < alarms.Count; i++) {
                AlarmItem a = alarms[i];
                b.Append("alarm.").Append(i + 1).Append(" = ").Append(a.Time).Append("|").Append(a.Enabled ? "1" : "0").Append("|").Append(EscapeCfg(a.Name)).Append("|").Append(EscapeCfg(a.Repeat)).Append("|").Append(EscapeCfg(a.Mode)).Append("\n");
            }
            File.WriteAllText(CfgPath(), b.ToString(), new System.Text.UTF8Encoding(false));
        } catch {}
    }
    static bool RepeatMatches(AlarmItem a, DateTime now)
    {
        if (a.Repeat == "仅一次" || a.Repeat == "每天") return true;
        if (a.Repeat == "工作日") return now.DayOfWeek >= DayOfWeek.Monday && now.DayOfWeek <= DayOfWeek.Friday;
        if (a.Repeat == "周末") return now.DayOfWeek == DayOfWeek.Saturday || now.DayOfWeek == DayOfWeek.Sunday;
        string token = "日一二三四五六"[(int)now.DayOfWeek].ToString();
        return a.Repeat != null && a.Repeat.StartsWith("自定义:") && a.Repeat.IndexOf(token) >= 0;
    }
    static void QueueAlarmPopup(AlarmItem a, DateTime now)
    {
        if (uiContext == null) return;
        string time = a.Time, name = a.Name, repeat = a.Repeat, mode = a.Mode;
        uiContext.Post(delegate(object state) { DispatchAlarm(time, name, repeat, mode); }, null);
    }
    static void DispatchAlarm(string time, string name, string repeat, string mode)
    {
        try {
            if (mode == "full") { ShowFullscreenAlarm(time, name, repeat); return; }
            if (mode == "tray") { ShowTrayAlarm(time, name, repeat); return; }
            ShowAlarmPopup(time, name, repeat);
        } catch {}
    }
    // 全屏强制休息: 全屏半透明遮罩 + 置顶, 必须点"我知道了"才能关闭 (有声音, 每 3 秒重响)
    static void ShowFullscreenAlarm(string time, string name, string repeat)
    {
        // 同一时刻只保留一个全屏提醒 (防多个闹钟叠一起)
        for (int i = fullscreenAlarms.Count - 1; i >= 0; i--) {
            Form f = fullscreenAlarms[i];
            if (f == null || f.IsDisposed) { fullscreenAlarms.RemoveAt(i); continue; }
            try { f.Close(); } catch {}
        }
        var a = new Form();
        a.Text = "WgIme 休息提醒"; a.FormBorderStyle = FormBorderStyle.None; a.AutoScaleMode = AutoScaleMode.None;
        a.StartPosition = FormStartPosition.Manual; a.Location = new Point(0, 0);
        a.WindowState = FormWindowState.Normal; a.FormBorderStyle = FormBorderStyle.None;
        Rectangle wa = Screen.PrimaryScreen.Bounds;
        a.Bounds = wa;
        a.BackColor = Color.FromArgb(255, 18, 22, 30);          // 深色底
        a.TopMost = true; a.ShowInTaskbar = true; a.Opacity = 0.96;
        a.KeyPreview = true;
        a.Paint += delegate(object ss, PaintEventArgs ee) {
            var g = ee.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            int cx = a.ClientSize.Width / 2, cy = a.ClientSize.Height / 2;
            using (var title = new Font("Microsoft YaHei UI", 30F, FontStyle.Bold))
            using (var sub = new Font("Microsoft YaHei UI", 16F, FontStyle.Regular))
            using (var big = new Font("Microsoft YaHei UI", 120F, FontStyle.Bold)) {
                string msg = string.IsNullOrEmpty(name) ? "休息一下" : name;
                using (var br = new SolidBrush(Color.FromArgb(255, 235, 235, 240)))
                    g.DrawString(msg, title, br, new RectangleF(0, cy - 150, a.ClientSize.Width, 60), new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
                using (var br2 = new SolidBrush(Color.FromArgb(255, 150, 160, 180)))
                    g.DrawString(time + "  " + (repeat ?? ""), sub, br2, new RectangleF(0, cy - 80, a.ClientSize.Width, 40), new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
                using (var br3 = new SolidBrush(Color.FromArgb(255, 0, 122, 255)))
                    g.DrawString("☕", big, br3, new RectangleF(0, cy - 40, a.ClientSize.Width, 130), new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
            }
        };
        var ok = new FlatBtn { Text = "我知道了，继续工作", Font = F(13F, FontStyle.Bold), Location = new Point(0, 0), Size = new Size(280, 52), Primary = true };
        ok.Location = new Point(a.ClientSize.Width / 2 - 140, a.ClientSize.Height / 2 + 120);
        ok.Click += delegate { a.Close(); };
        a.Controls.Add(ok);
        var st = new System.Windows.Forms.Timer { Interval = 3000 };
        a.FormClosed += delegate { st.Stop(); st.Dispose(); fullscreenAlarms.Remove(a); };
        fullscreenAlarms.Add(a);
        System.Media.SystemSounds.Exclamation.Play();
        st.Tick += delegate { System.Media.SystemSounds.Exclamation.Play(); };
        st.Start();
        a.Show(); a.Activate();
    }
    // 托盘气泡: 轻提醒, 不打断 (声音一次)
    static void ShowTrayAlarm(string time, string name, string repeat)
    {
        try {
            var ni = new NotifyIcon();
            ni.Icon = System.Drawing.SystemIcons.Information;
            ni.Visible = true;
            ni.BalloonTipTitle = "WgIme 提醒  " + time;
            ni.BalloonTipText = (string.IsNullOrEmpty(name) ? "闹钟" : name) + "  (" + repeat + ")";
            ni.BalloonTipIcon = ToolTipIcon.Info;
            ni.ShowBalloonTip(8000);
            System.Media.SystemSounds.Asterisk.Play();
            System.Windows.Forms.Timer t = null;
            t = new System.Windows.Forms.Timer { Interval = 10000 };
            t.Tick += delegate { t.Stop(); t.Dispose(); ni.Visible = false; ni.Dispose(); };
            t.Start();
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
            var firedAlarms = new HashSet<string>();
            string firedDay = "";
            while (true) {
                System.Threading.Thread.Sleep(5000);
                try {
                    LoadCfg();
                    var now = DateTime.Now;
                    if (hourly && now.Minute == 0 && now.Hour != lastHour) {
                        lastHour = now.Hour;
                        System.Media.SystemSounds.Asterisk.Play();
                    }
                    string day = now.ToString("yyyy-MM-dd");
                    if (day != firedDay) { firedDay = day; firedAlarms.Clear(); }
                    string hm = now.ToString("HH:mm");
                    for (int ai = 0; ai < alarms.Count; ai++) {
                        AlarmItem a = alarms[ai];
                        string alarmKey = day + " " + hm + "#" + ai;
                        if (a.Enabled && hm == a.Time && RepeatMatches(a, now) && !firedAlarms.Contains(alarmKey)) {
                            firedAlarms.Add(alarmKey);
                            QueueAlarmPopup(a, now);
                            if (a.Repeat == "仅一次") { a.Enabled = false; SaveCfg(); }
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

    static void ShowAlarmPopup(string time, string name, string repeat)
    {
        var a = new Form();
        a.Text = "WgIme 闹钟提醒"; a.FormBorderStyle = FormBorderStyle.None; a.AutoScaleMode = AutoScaleMode.None;
        a.ClientSize = new Size(340, 224); a.BackColor = C_BG; a.TopMost = true; a.ShowInTaskbar = true;
        a.StartPosition = FormStartPosition.CenterScreen;
        EventHandler ar = delegate { try { SetWindowRgn(a.Handle, CreateRoundRectRgn(0, 0, a.Width + 1, a.Height + 1, 22, 22), true); } catch {} };
        a.HandleCreated += delegate { ar(a, EventArgs.Empty); }; a.Resize += delegate { ar(a, EventArgs.Empty); };
        a.Paint += delegate(object ss, PaintEventArgs ee) { ee.Graphics.SmoothingMode = SmoothingMode.AntiAlias; using (var p = RoundRect(new Rectangle(1, 1, a.Width - 3, a.Height - 3), 10)) using (var pn = new Pen(C_BORDER)) ee.Graphics.DrawPath(pn, p); };
        var head = new Panel { Location = new Point(0, 0), Size = new Size(340, 38), BackColor = C_HEADER };
        head.Controls.Add(MkLabel("闹钟提醒", F(9.5F, FontStyle.Bold), C_TEXT, 16, 8, 180, 24, ContentAlignment.MiddleLeft));
        head.MouseDown += delegate(object ss, MouseEventArgs ee) { if (ee.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(a.Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } };
        a.Controls.Add(head);
        a.Controls.Add(MkLabel(time, F(32F, FontStyle.Regular), C_ORANGE, 0, 52, 340, 52, ContentAlignment.MiddleCenter));
        a.Controls.Add(MkLabel(name, F(12F, FontStyle.Bold), C_TEXT, 20, 108, 300, 28, ContentAlignment.MiddleCenter));
        a.Controls.Add(MkLabel("重复：" + repeat, F(8.5F, FontStyle.Regular), C_SUB, 20, 136, 300, 20, ContentAlignment.MiddleCenter));
        var stop = new FlatBtn { Text = "停止提醒", Font = F(9F, FontStyle.Regular), Location = new Point(20, 174), Size = new Size(142, 34), Primary = true };
        var snooze = new FlatBtn { Text = "5分钟后提醒", Font = F(9F, FontStyle.Regular), Location = new Point(178, 174), Size = new Size(142, 34), Fg = C_ORANGE };
        var sound = new Timer { Interval = 1400 };
        sound.Tick += delegate { System.Media.SystemSounds.Exclamation.Play(); };
        stop.Click += delegate { sound.Stop(); a.Close(); };
        snooze.Click += delegate {
            sound.Stop(); a.Close();
            System.Threading.Timer later = null;
            later = new System.Threading.Timer(delegate(object state) {
                if (uiContext != null) uiContext.Post(delegate(object x) { ShowAlarmPopup(DateTime.Now.ToString("HH:mm"), name + "（稍后提醒）", "单次延后"); }, null);
                try { later.Dispose(); snoozeTimers.Remove(later); } catch {}
            }, null, 5 * 60 * 1000, System.Threading.Timeout.Infinite);
            snoozeTimers.Add(later);
        };
        a.FormClosed += delegate { sound.Stop(); sound.Dispose(); };
        a.Controls.Add(stop); a.Controls.Add(snooze);
        System.Media.SystemSounds.Exclamation.Play(); sound.Start(); a.Show(); a.Activate();
    }

    static void ShowAlarmManager(Form owner, Action changed, Font fontBtn, Font fontSub)
    {
        var m = new Form();
        m.Text = "WgIme 闹钟管理"; m.FormBorderStyle = FormBorderStyle.None; m.AutoScaleMode = AutoScaleMode.None;
        m.ClientSize = new Size(360, 456); m.BackColor = C_BG; m.TopMost = true; m.ShowInTaskbar = false;
        m.StartPosition = FormStartPosition.Manual;
        m.Location = new Point(owner.Left + (owner.Width - m.Width) / 2, owner.Top + (owner.Height - m.Height) / 2);
        EventHandler ar = delegate { try { SetWindowRgn(m.Handle, CreateRoundRectRgn(0, 0, m.Width + 1, m.Height + 1, 20, 20), true); } catch {} };
        m.HandleCreated += delegate { ar(m, EventArgs.Empty); }; m.Resize += delegate { ar(m, EventArgs.Empty); };
        m.Paint += delegate(object ss, PaintEventArgs ee) { ee.Graphics.SmoothingMode = SmoothingMode.AntiAlias; using (var pp = RoundRect(new Rectangle(1, 1, m.Width - 3, m.Height - 3), 9)) using (var pn = new Pen(C_BORDER)) ee.Graphics.DrawPath(pn, pp); };
        var head = new Panel { Location = new Point(0, 0), Size = new Size(360, 38), BackColor = C_HEADER };
        var cap = MkLabel("闹钟管理", F(9.5F, FontStyle.Bold), C_TEXT, 16, 8, 160, 24, ContentAlignment.MiddleLeft);
        var close = new FlatBtn { Text = "✕", Font = fontBtn, Location = new Point(316, 6), Size = new Size(34, 26), Bg = C_HEADER, BgHover = Color.FromArgb(255, 200, 60, 70) };
        close.Click += delegate { m.Close(); }; head.Controls.Add(cap); head.Controls.Add(close);
        head.MouseDown += delegate(object ss, MouseEventArgs ee) { if (ee.Button == MouseButtons.Left) { ReleaseCapture(); SendMessage(m.Handle, 0xA1, (IntPtr)0x2, IntPtr.Zero); } };
        m.Controls.Add(head);

        var list = new ListBox { Location = new Point(16, 52), Size = new Size(328, 154), BackColor = C_SURFACE, ForeColor = C_TEXT, Font = fontBtn, BorderStyle = BorderStyle.None, IntegralHeight = false };
        m.Controls.Add(list);
        var edTime = new RoundedEdit(76, 30, fontBtn); edTime.Location = new Point(16, 220); edTime.Box.Text = "07:30"; m.Controls.Add(edTime);
        var edName = new RoundedEdit(148, 30, fontBtn); edName.Location = new Point(100, 220); edName.Box.TextAlign = HorizontalAlignment.Left; edName.Box.Text = "闹钟"; m.Controls.Add(edName);
        var toggle = new FlatBtn { Text = "已开启", Font = fontBtn, Location = new Point(256, 219), Size = new Size(88, 32), Fg = C_GREEN };
        var repeat = new ComboBox { Location = new Point(16, 260), Size = new Size(328, 28), DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, BackColor = C_SURFACE, ForeColor = C_TEXT, Font = fontBtn };
        repeat.Items.AddRange(new object[] { "仅一次", "每天", "工作日", "周末", "自定义:一二三四五", "自定义:一三五", "自定义:二四六", "自定义:日六" }); repeat.SelectedItem = "每天"; m.Controls.Add(repeat);
        var mode = new ComboBox { Location = new Point(16, 296), Size = new Size(328, 28), DropDownStyle = ComboBoxStyle.DropDownList, FlatStyle = FlatStyle.Flat, BackColor = C_SURFACE, ForeColor = C_TEXT, Font = fontBtn };
        mode.Items.AddRange(new object[] { "居中弹窗", "全屏强制休息", "托盘气泡" }); mode.SelectedIndex = 0; m.Controls.Add(mode);
        bool editEnabled = true;
        toggle.Click += delegate { editEnabled = !editEnabled; toggle.Text = editEnabled ? "已开启" : "已关闭"; toggle.Fg = editEnabled ? C_GREEN : C_SUB; toggle.Invalidate(); };
        m.Controls.Add(toggle);
        var note = MkLabel("选择项目可编辑；提醒方式可单独设置", fontSub, C_SUB, 16, 332, 328, 20, ContentAlignment.MiddleLeft); m.Controls.Add(note);

        Action refresh = delegate {
            list.Items.Clear();
            for (int i = 0; i < alarms.Count; i++) list.Items.Add((alarms[i].Enabled ? "● " : "○ ") + alarms[i].Time + "   " + alarms[i].Name + "   [" + alarms[i].Repeat + "]");
            if (changed != null) changed();
        };
        Action<int> loadItem = delegate(int idx) {
            if (idx < 0 || idx >= alarms.Count) return;
            AlarmItem a = alarms[idx]; edTime.Box.Text = a.Time; edName.Box.Text = a.Name; editEnabled = a.Enabled;
            toggle.Text = editEnabled ? "已开启" : "已关闭"; toggle.Fg = editEnabled ? C_GREEN : C_SUB; toggle.Invalidate();
            repeat.SelectedItem = a.Repeat; if (repeat.SelectedIndex < 0) repeat.SelectedItem = "每天";
            mode.SelectedItem = a.Mode == "full" ? "全屏强制休息" : (a.Mode == "tray" ? "托盘气泡" : "居中弹窗");
        };
        list.SelectedIndexChanged += delegate { loadItem(list.SelectedIndex); };
        Action normalize = delegate {
            string t = edTime.Box.Text.Trim().Replace("：", ":"); string d = t.Replace(":", ""); int hh = 0, mm = 0;
            if (d.Length == 3 || d.Length == 4) { string hs = d.Substring(0, d.Length - 2), ms = d.Substring(d.Length - 2); if (int.TryParse(hs, out hh) && int.TryParse(ms, out mm) && hh >= 0 && hh <= 23 && mm >= 0 && mm <= 59) t = hh.ToString("00") + ":" + mm.ToString("00"); }
            edTime.Box.Text = t;
        };
        Func<AlarmItem> readItem = delegate {
            normalize(); string t = edTime.Box.Text.Trim();
            if (!ValidAlarmTime(t)) { note.Text = "时间格式错误，请输入 00:00–23:59"; note.ForeColor = C_RED; return null; }
            string nm = edName.Box.Text.Trim(); if (nm.Length == 0) nm = "闹钟";
            note.Text = "已保存"; note.ForeColor = C_GREEN;
            AlarmItem it = new AlarmItem(t, nm, editEnabled, repeat.SelectedItem == null ? "每天" : repeat.SelectedItem.ToString());
            string sel = mode.SelectedItem == null ? "居中弹窗" : mode.SelectedItem.ToString();
            it.Mode = sel == "全屏强制休息" ? "full" : (sel == "托盘气泡" ? "tray" : "popup");
            return it;
        };
        var add = new FlatBtn { Text = "新增", Font = fontBtn, Location = new Point(16, 372), Size = new Size(76, 34), Primary = true };
        var save = new FlatBtn { Text = "保存修改", Font = fontBtn, Location = new Point(100, 372), Size = new Size(92, 34), Fg = C_ACCENT };
        var del = new FlatBtn { Text = "删除", Font = fontBtn, Location = new Point(200, 372), Size = new Size(68, 34), Fg = C_RED };
        var clear = new FlatBtn { Text = "清空", Font = fontBtn, Location = new Point(276, 372), Size = new Size(68, 34), Fg = C_SUB };
        add.Click += delegate { AlarmItem a = readItem(); if (a == null) return; alarms.Add(a); SaveCfg(); refresh(); list.SelectedIndex = alarms.Count - 1; };
        save.Click += delegate { int i = list.SelectedIndex; if (i < 0 || i >= alarms.Count) { note.Text = "请先选择一个闹钟"; note.ForeColor = C_RED; return; } AlarmItem a = readItem(); if (a == null) return; alarms[i] = a; SaveCfg(); refresh(); list.SelectedIndex = i; };
        del.Click += delegate { int i = list.SelectedIndex; if (i < 0 || i >= alarms.Count) return; alarms.RemoveAt(i); SaveCfg(); refresh(); if (alarms.Count > 0) list.SelectedIndex = Math.Min(i, alarms.Count - 1); };
        clear.Click += delegate { edTime.Box.Text = "07:30"; edName.Box.Text = "闹钟"; editEnabled = true; toggle.Text = "已开启"; toggle.Fg = C_GREEN; toggle.Invalidate(); repeat.SelectedItem = "每天"; mode.SelectedIndex = 0; list.ClearSelected(); note.Text = "填写后点击新增"; note.ForeColor = C_SUB; };
        m.Controls.Add(add); m.Controls.Add(save); m.Controls.Add(del); m.Controls.Add(clear);
        m.FormClosed += delegate { SaveCfg(); if (changed != null) changed(); };
        refresh(); m.Show(owner);
    }

    public static void Run()
    {
        uiContext = System.Threading.SynchronizationContext.Current;
        if (uiContext == null) uiContext = new WindowsFormsSynchronizationContext();
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
        var lblAlSummary = MkLabel("", fontSub, C_SUB, 184, 288, 104, 22, ContentAlignment.MiddleLeft);
        var btnAlarmManage = new FlatBtn { Text = "管理闹钟", Font = fontBtn, Location = new Point(292, 282), Size = new Size(92, 32), Fg = C_ACCENT };
        Action refreshAlarmSummary = delegate {
            int enabled = 0; string next = "";
            for (int i = 0; i < alarms.Count; i++) if (alarms[i].Enabled) { enabled++; if (next.Length == 0 || String.Compare(alarms[i].Time, next) < 0) next = alarms[i].Time; }
            lblAlSummary.Text = alarms.Count == 0 ? "未设置" : (enabled + "个开启" + (next.Length > 0 ? " · " + next : ""));
        };
        refreshAlarmSummary();
        btnAlarmManage.Click += delegate { ShowAlarmManager(f, refreshAlarmSummary, fontBtn, fontSub); };
        var p0 = pages[0];
        p0.Controls.Add(lblTime); p0.Controls.Add(lblDate); p0.Controls.Add(lblDayOf);
        p0.Controls.Add(ringClock);
        p0.Controls.Add(chkHourly); p0.Controls.Add(lblAl); p0.Controls.Add(lblAlSummary); p0.Controls.Add(btnAlarmManage);

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

