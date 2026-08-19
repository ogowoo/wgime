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

    // ---------- 开机自启 (Startup 文件夹快捷方式) ----------
    static string StartupLinkPath() { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "WgTray.lnk"); }
    static bool IsAutoStart() { try { return File.Exists(StartupLinkPath()); } catch { return false; } }
    static void SetAutoStart(bool on)
    {
        string p = StartupLinkPath();
        try {
            if (!on) {
                if (File.Exists(p)) File.Delete(p);
                TrayTip(L("开机自启", "Startup"), L("已关闭", "off"), ToolTipIcon.Info);
                return;
            }
            var type = Type.GetTypeFromProgID("WScript.Shell");
            var sh = Activator.CreateInstance(type);
            var lnk = type.InvokeMember("CreateShortcut", System.Reflection.BindingFlags.InvokeMethod, null, sh, new object[] { p });
            var lt = lnk.GetType();
            lt.InvokeMember("TargetPath", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { BatPath });
            lt.InvokeMember("WorkingDirectory", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { BatDir });
            lt.InvokeMember("Description", System.Reflection.BindingFlags.SetProperty, null, lnk, new object[] { "WgTray" });
            lt.InvokeMember("Save", System.Reflection.BindingFlags.InvokeMethod, null, lnk, null);
            TrayTip(L("开机自启", "Startup"), L("已开启 (Startup\\WgTray.lnk)", "on (Startup\\WgTray.lnk)"), ToolTipIcon.Info);
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
'TVqQAAMAAAAEAAAA//8AALgAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAA4fug4AtAnNIbgBTM0hVGhpcyBwcm9ncmFtIGNhbm5vdCBiZSBydW4gaW4gRE9TIG1vZGUuDQ0KJAAAAAAAAABQRQAATAEDAES7hWoAAAAAAAAAAOAAAiELAQsAALwBAAAGAAAAAAAAztoBAAAgAAAA4AEAAAAAEAAgAAAAAgAABAAAAAAAAAAEAAAAAAAAAAAgAgAAAgAAAAAAAAMAQIUAABAAABAAAAAAEAAAEAAAAAAAABAAAAAAAAAAAAAAAHjaAQBTAAAAAOABALACAAAAAAAAAAAAAAAAAAAAAAAAAAACAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAACAAAAAAAAAAAAAAACCAAAEgAAAAAAAAAAAAAAC50ZXh0AAAA1LoBAAAgAAAAvAEAAAIAAAAAAAAAAAAAAAAAACAAAGAucnNyYwAAALACAAAA4AEAAAQAAAC+AQAAAAAAAAAAAAAAAABAAABALnJlbG9jAAAMAAAAAAACAAACAAAAwgEAAAAAAAAAAAAAAAAAQAAAQgAAAAAAAAAAAAAAAAAAAACw2gEAAAAAAEgAAAACAAUAPAoBADzQAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAC5+AQAABC0CAyoCKhMwBwCeAAAAAQAAEXMEAAAKCgMiAAAAQFoLBg8AKAUAAAoPACgGAAAKBwciAAA0QyIAALRCbwcAAAoGDwAoCAAACgdZDwAoBgAACgcHIgAAh0MiAAC0Qm8HAAAKBg8AKAgAAAoHWQ8AKAkAAAoHWQcHIgAAAAAiAAC0Qm8HAAAKBg8AKAUAAAoPACgJAAAKB1kHByIAALRCIgAAtEJvBwAACgZvCgAACgYqAAAbMAkAQgEAAAIAABEfQB9AcwsAAAoKBigMAAAKCwcabw0AAAoHKA4AAApvDwAACiIAAAAAIgAAAAAiAACAQiIAAIBCcxAAAAoiAABgQSgCAAAGDANzEQAACg0HCQhvEgAACt4KCSwGCW8TAAAK3N4KCCwGCG8TAAAK3HMEAAAKEwRyAQAAcCIAAFBCFhhzFAAAChMFcxUAAAoTCBEIF28WAAAKEQgXbxcAAAoRCBMGEQQCEQVvGAAAChYiAABQQiIAAAAAIgAAAAAiAACAQiIAAIBCcxAAAAoRBm8ZAAAKBxdvGgAACigOAAAKcxEAAAoTBwcRBxEEbxIAAAreDBEHLAcRB28TAAAK3N4MEQUsBxEFbxMAAArc3gwRBCwHEQRvEwAACtzeCgcsBgdvEwAACtwGbxsAAAooHAAAChMJ3goGLAYGbxMAAArcEQkqAABBrAAAAgAAAE4AAAAKAAAAWAAAAAoAAAAAAAAAAgAAAEcAAAAdAAAAZAAAAAoAAAAAAAAAAgAAAOYAAAAMAAAA8gAAAAwAAAAAAAAAAgAAAIgAAAB4AAAAAAEAAAwAAAAAAAAAAgAAAHUAAACZAAAADgEAAAwAAAAAAAAAAgAAABEAAAALAQAAHAEAAAoAAAAAAAAAAgAAAAoAAAArAQAANQEAAAoAAAAAAAAACzAFABgAAAAAAAAAfgUAAAQgKAoAAAIDBG8dAAAK3gMm3gAqARAAAAAAAAAUFAADAQAAAQswAQAzAAAAAAAAAH4TAAAELAx+EwAABG8eAAAKLBVzYgAABoATAAAEfhMAAARvHwAACibeAybeAH4TAAAEKgABEAAAAAAAACoqAAMBAAABEzAEAHUEAAADAAARAxZUBBZUAiggAAAKLAIWKgJvIQAACheNPQAAARMGEQYWHyudEQZvIgAACgoGBo5pF1mabyMAAAoLFgw4igAAAAYImm8jAAAKDQlyJwAAcCgkAAAKLQ0JcjEAAHAoJAAACiwIAyVLGGBUK1sJckEAAHAoJAAACiwIAyVLF2BUK0YJckkAAHAoJAAACiwIAyVLGmBUKzEJclUAAHAoJAAACi0aCXJdAABwKCQAAAotDQlyZQAAcCgkAAAKLAgDJUseYFQrAhYqCBdYDAgGjmkXWT9r////B28lAAAKFzMqBxZvJgAACh9hMh8HFm8mAAAKH3owFAQHFm8mAAAKH2FZH0FYVDhkAwAAB28lAAAKFzMqBxZvJgAACh8wMh8HFm8mAAAKHzkwFAQHFm8mAAAKHzBZHzBYVDgxAwAAHwyNPAAAARMHEQcWcm8AAHCiEQcXcnUAAHCiEQcYcnsAAHCiEQcZcoEAAHCiEQcacocAAHCiEQcbco0AAHCiEQcccpMAAHCiEQcdcpkAAHCiEQcecp8AAHCiEQcfCXKlAABwohEHHwpyrQAAcKIRBx8LcrUAAHCiEQcTBBEEBygBAAArEwURBRYyDAQfcBEFWFQ4mgIAAAclEwg5jwIAAP4TfpAAAAQ6PQEAAB8YcykAAAolcr0AAHAWKCoAAAolcskAAHAXKCoAAAolctUAAHAYKCoAAAolct0AAHAZKCoAAAolcvEAAHAaKCoAAAolcvkAAHAbKCoAAAolcgUBAHAcKCoAAAolchEBAHAdKCoAAAolchsBAHAeKCoAAAolci0BAHAfCSgqAAAKJXI/AQBwHwooKgAACiVyUwEAcB8LKCoAAAolcl8BAHAfDCgqAAAKJXJrAQBwHw0oKgAACiVyeQEAcB8OKCoAAAolcoUBAHAfDygqAAAKJXKZAQBwHxAoKgAACiVyowEAcB8RKCoAAAolcq0BAHAfEigqAAAKJXK3AQBwHxMoKgAACiVyvwEAcB8UKCoAAAolcskBAHAfFSgqAAAKJXLVAQBwHxYoKgAACiVy2wEAcB8XKCoAAAr+E4CQAAAE/hN+kAAABBEIEgkoKwAACjkxAQAAEQlFGAAAAAUAAAAOAAAAFwAAACAAAAAoAAAAMQAAAD0AAABJAAAAUgAAAFsAAABkAAAAbQAAAHYAAAB/AAAAiAAAAJEAAACaAAAAoAAAAKYAAACsAAAAsgAAALgAAAC+AAAAxAAAADjFAAAABB8gVDi+AAAABB8NVDi1AAAABB8bVDisAAAABB5UOKQAAAAEHwlUOJsAAAAEIMAAAABUOI8AAAAEIL0AAABUOIMAAAAEILsAAABUK3oEINsAAABUK3EEIN0AAABUK2gEILoAAABUK18EIN4AAABUK1YEILwAAABUK00EIL4AAABUK0QEIL8AAABUKzsEINwAAABUKzIEHyFUKywEHyJUKyYEHyRUKyAEHyNUKxoEHyVUKxQEHydUKw4EHyZUKwgEHyhUKwIWKgNLFv4BFv4BKgAAAAAAAAAgAAAADQAAABsAAAAIAAAACQAAAMAAAAC9AAAAuwAAANsAAADdAAAAugAAAN4AAAC8AAAAvgAAAL8AAADcAAAAIQAAACIAAAAkAAAAIwAAACUAAAAnAAAAJgAAACgAAAATMAQA+gEAAAQAABECLRMDLRBy5QEAcHLxAQBwKAEAAAYqcywAAAoKAhhfLAwGcv8BAHBvLQAACiYCF18sDAZyCwIAcG8tAAAKJgIaXywMBnIVAgBwby0AAAomAh5fLAwGciMCAHBvLQAACiYDH0E3GQMfWjUUBh9hA1gfQVnRby4AAAomOHUBAAADHzA3GQMfOTUUBh8wA1gfMFnRby4AAAomOFcBAAADH3A3HgMfezUZBh9Gby4AAAoDH3BZF1hvLwAACiY4NAEAAB8YjTwAAAETBBEEFnItAgBwohEEF3I5AgBwohEEGHJFAgBwohEEGXJNAgBwohEEGnJhAgBwohEEG3JpAgBwohEEHHJtAgBwohEEHXJxAgBwohEEHnJ1AgBwohEEHwlyeQIAcKIRBB8Kcn0CAHCiEQQfC3KBAgBwohEEHwxyhQIAcKIRBB8NcokCAHCiEQQfDnKNAgBwohEEHw9ykQIAcKIRBB8QcpUCAHCiEQQfEXKfAgBwohEEHxJyqQIAcKIRBB8TcrMCAHCiEQQfFHK7AgBwohEEHxVyxQIAcKIRBB8WctECAHCiEQQfF3LXAgBwohEECx8YjUAAAAEl0JEAAAQoMAAACgwIAygCAAArDQYJFi8YcuECAHAPAXLnAgBwKDEAAAooMgAACisDBwmaby0AAAomBm8zAAAKKgAAAzAEAN4AAAAAAAAAAnsMAAAELS8CKAUAAAZ0AwAAAn0MAAAEAnsMAAAELBcCewwAAAQC/gYJAAAGczQAAAp9JQAABAJ7DAAABCwNAnsMAAAEbzUAAAotASoCewwAAAQXb2AAAAYCewwAAAQYb2AAAAYCewwAAAQZb2AAAAZ+DQAABC0Hfg4AAAQsFgJ7DAAABBd+DQAABH4OAAAEb18AAAZ+DwAABC0HfhAAAAQsFgJ7DAAABBh+DwAABH4QAAAEb18AAAZ+EQAABC0HfhIAAAQsFgJ7DAAABBl+EQAABH4SAAAEb18AAAYqAAALMAIARAAAAAAAAAADFzMNAnLrAgBwKBcAAAYrLQMYMw0CcvkCAHAoFwAABiscAxkzGAJ7BgAABCwQAnsGAAAEKDYAAApvNwAACt4DJt4AKgEQAAAAAAAAQEAAAwEAAAFGHSg4AAAKcgkDAHAoOQAACioAABswAQAUAAAABQAAESgKAAAGKDoAAAoK3gUmFgreAAYqARAAAAAAAAANDQAFAQAAARswCABNAQAABgAAESgKAAAGCgItNwYoOgAACiwGBig7AAAKch8DAHByKQMAcCgBAAAGcjkDAHByQQMAcCgBAAAGFygEAAAG3QwBAABySQMAcCg8AAAKCwcoPQAACgwHcmUDAHAgAAEAABQIF40BAAABEwYRBhYGohEGbz4AAAoNCW8/AAAKEwQRBHKDAwBwIAAgAAAUCReNAQAAARMHEQcWfgQAAASiEQdvPgAACiYRBHKZAwBwIAAgAAAUCReNAQAAARMIEQgWfgMAAASiEQhvPgAACiYRBHK7AwBwIAAgAAAUCReNAQAAARMJEQkWctMDAHCiEQlvPgAACiYRBHLhAwBwIAABAAAUCRRvPgAACiZyHwMAcHIpAwBwKAEAAAZy6wMAcHIdBABwKAEAAAYXKAQAAAbeIBMFck0EAHByWwQAcCgBAAAGEQVvQAAAChkoBAAABt4AKgAAAEEcAAAAAAAABgAAACYBAAAsAQAAIAAAAE4AAAEacnkEAHAqABswBgDpBQAABwAAEXNBAAAKgBQAAAR+FAAABHLrAgBwGY08AAABEw0RDRZyXggAcHJmCABwKAEAAAaiEQ0XcnYIAHCiEQ0YcpIIAHCiEQ1vQgAACn4UAAAEcpQIAHAZjTwAAAETDhEOFnJeCABwcmYIAHAoAQAABqIRDhdydggAcKIRDhhykggAcKIRDm9CAAAKfhQAAARyoAgAcBmNPAAAARMPEQ8WcqgIAHBysggAcCgBAAAGohEPF3LOCABwohEPGHKSCABwohEPb0IAAAp+FAAABHLwCABwGY08AAABExAREBZyqAgAcHKyCABwKAEAAAaiERAXcs4IAHCiERAYcpIIAHCiERBvQgAACn4UAAAEcvoIAHAZjTwAAAETERERFnIECQBwchAJAHAoAQAABqIRERdyNAkAcKIRERhykggAcKIREW9CAAAKfhQAAARyTgkAcBmNPAAAARMSERIWcgQJAHByEAkAcCgBAAAGohESF3I0CQBwohESGHKSCABwohESb0IAAAp+FAAABHJWCQBwGY08AAABExMRExZyXAkAcHJiCQBwKAEAAAaiERMXcnwJAHCiERMYcpIIAHCiERNvQgAACn4UAAAEcpYJAHAZjTwAAAETFBEUFnJcCQBwcmIJAHAoAQAABqIRFBdyfAkAcKIRFBhykggAcKIRFG9CAAAKfhQAAARyogkAcBmNPAAAARMVERUWcqgJAHBysgkAcCgBAAAGohEVF3LMCQBwohEVGHKSCABwohEVb0IAAAp+FAAABHLoCQBwGY08AAABExYRFhZyqAkAcHKyCQBwKAEAAAaiERYXcswJAHCiERYYcpIIAHCiERZvQgAACn4UAAAEcvkCAHAZjTwAAAETFxEXFnL0CQBwcv4JAHAoAQAABqIRFxdyHAoAcKIRFxhykggAcKIRF29CAAAKfhQAAARyQAoAcBmNPAAAARMYERgWcvQJAHBy/gkAcCgBAAAGohEYF3IcCgBwohEYGHKSCABwohEYb0IAAApySgoAcH8NAAAEfw4AAAQoBgAABiZyYAoAcH8PAAAEfxAAAAQoBgAABiZydgoAcH8RAAAEfxIAAAQoBgAABiYCcowKAHAoOQAACgoGKBYAAAYGKDoAAAo5ZgIAAAYoQwAACihEAAAKExkWExo4RgIAABEZERqaCwdvIwAACgwIbyUAAAo5KAIAAAgWbyYAAAofIzsaAgAACBZvJgAACh87OwwCAAAIHz1vRQAACg0JFz/8AQAACBYJb0YAAApvIwAACm8hAAAKEwQICRdYb0cAAApvIwAAChMFEQRyogoAcCgkAAAKOTwBAAARBReNPQAAARMbERsWHwmdERtvIgAAChMGFBMHFBMIFBMJcpIIAHATChEGjmkZMigRBhaaEwcRBheaEwgRBhiaEwkRBo5pGTAHcpIIAHArBBEGGZoTCit8EQVyqgoAcChIAAAKEwsRC29JAAAKLGURC29KAAAKF29LAAAKb0wAAAoTBxELb0oAAAoYb0sAAApvTAAAChMIEQtvSgAAChlvSwAACm9MAAAKF409AAABExwRHBYfIp0RHG9NAAAKEwkRC29KAAAKGm9LAAAKb0wAAAoTChEHOewAAAARB28jAAAKbyEAAAoTBxEHbyUAAAoWPtEAAAB+FAAABBEHGY08AAABEx0RHRYRCG8jAAAKohEdFxEJbyMAAAooTgAACqIRHRgRCm8jAAAKKE4AAAqiER1vQgAACjiLAAAAEQRyCgsAcCgkAAAKLCERBX8NAAAEfw4AAAQoBgAABi1qFoANAAAEFoAOAAAEK1wRBHIoCwBwKCQAAAosIREFfw8AAAR/EAAABCgGAAAGLTsWgA8AAAQWgBAAAAQrLREEckYLAHAoJAAACiwfEQV/EQAABH8SAAAEKAYAAAYtDBaAEQAABBaAEgAABBEaF1gTGhEaERmOaT+v/f//3gMm3gAoRQAABgIoRAAABn4UAAAEcl4LAHASDG9PAAAKLBF+FAAABHJmCwBwEQxvQgAACioAAABBHAAAAAAAADEDAACFAgAAtgUAAAMAAAABAAABGzADAFUAAAAIAAARfgMAAAQoDgAABn4DAAAEKBkAAAZ+AwAABHKMCgBwKDkAAAoKBig6AAAKLRYGKA0AAAYWc1AAAAooUQAACt4DJt4AAigIAAAGAigUAAAGAigTAAAGKgAAAAEQAAAAACwAEz8AAwEAAAEbMAMALwAAAAkAABFzUgAACgoGfgMAAARyjAoAcCg5AAAKb1MAAAoGF29UAAAKBihVAAAKJt4DJt4AKgABEAAAAAAAACsrAAMBAAABGzACACUAAAAJAAARc1IAAAoKBn4CAAAEb1MAAAoGF29UAAAKBihVAAAKJt4DJt4AKgAAAAEQAAAAAAAAISEAAwEAAAEyAnLrAgBwKBcAAAYqMgJyXgsAcCgXAAAGKjICcqAIAHAoFwAABioyAnL6CABwKBcAAAYqMgJyVgkAcCgXAAAGKjICcqIJAHAoFwAABioeAigQAAAGKh4CKA8AAAYqUigLAAAGFv4BKAwAAAYCKBMAAAYqHgIoEQAABioaKFYAAAoqHgIoEwAABioAABMwBQC6AwAACgAAEQJzVwAACn0GAAAEAnsGAAAEb1gAAApycAsAcHJ6CwBwKAEAAAYUAv4GTgAABnNZAAAKb1oAAAomAnsGAAAEb1gAAApzWwAACm9cAAAKJgJyjAsAcHKSCwBwKAEAAAZzXQAACn0IAAAEAnsGAAAEb1gAAAoCewgAAARvXAAACiZyogsAcHKsCwBwKAEAAAZzXQAACgoGb14AAApyygsAcHLSCwBwKAEAAAYUAv4GTwAABnNZAAAKb1oAAAomBm9eAAAKcqgIAHBysggAcCgBAAAGFAL+BlAAAAZzWQAACm9aAAAKJgZvXgAACnIECQBwchAJAHAoAQAABhQC/gZRAAAGc1kAAApvWgAACiYGb14AAApyXAkAcHJiCQBwKAEAAAYUAv4GUgAABnNZAAAKb1oAAAomBm9eAAAKcqgJAHBysgkAcCgBAAAGFAL+BlMAAAZzWQAACm9aAAAKJgJ7BgAABG9YAAAKBm9cAAAKJgJy6AsAcHIIDABwKAEAAAZzXQAACn0HAAAEAnsGAAAEb1gAAAoCewcAAARvXAAACiZyLAwAcHIyDABwKAEAAAZzXQAACgsHb14AAApyQAwAcHJmDABwKAEAAAYUAv4GVAAABnNZAAAKb1oAAAomB29eAAAKcpoMAHBypAwAcCgBAAAGFAL+BlUAAAZzWQAACm9aAAAKJgdvXgAACnNbAAAKb1wAAAomAnIfAwBwcsAMAHAoAQAABnNdAAAKfQkAAAQCewkAAAQC/gZWAAAGc1kAAApvXwAACgdvXgAACgJ7CQAABG9cAAAKJgdvXgAACnLmDABwcvIMAHAoAQAABhQC/gZXAAAGc1kAAApvWgAACiYCewYAAARvWAAACgdvXAAACiZyDA0AcHIYDQBwKAEAAAZzXQAACgwWDSszAnsKAAAECXNgAAAKogJ7CgAABAmaFm9hAAAKCG9eAAAKAnsKAAAECZpvXAAACiYJF1gNCRkyyQhvXgAACnNbAAAKb1wAAAomcjYNAHBygg0AcCgBAAAGc10AAAoTBBEEFm9hAAAKCG9eAAAKEQRvXAAACiYCewYAAARvWAAACghvXAAACiYCewYAAARvWAAACnNbAAAKb1wAAAomAnsGAAAEb1gAAApy6A0AcHLuDQBwKAEAAAYUfiMAAAQtERT+BlgAAAZzWQAACoAjAAAEfiMAAARvWgAACiYCewYAAAQC/gZZAAAGc2IAAApvYwAACgJ7CwAABAJ7BgAABG9kAAAKAigUAAAGAigTAAAGKgAAAzAFAN4AAAAAAAAAAnsJAAAELBACewkAAAQoCwAABm9lAAAKAnsKAAAEOboAAAACewoAAASOaRlArAAAAAJ7CgAABBaaOZ8AAAACewoAAAQWmnL4DQBwcgQOAHAoAQAABnIeDgBwfg0AAAR+DgAABCgHAAAGKGYAAApvZwAACgJ7CgAABBeacvQJAHBy/gkAcCgBAAAGch4OAHB+DwAABH4QAAAEKAcAAAYoZgAACm9nAAAKAnsKAAAEGJpyJg4AcHI0DgBwKAEAAAZyHg4AcH4RAAAEfhIAAAQoBwAABihmAAAKb2cAAAoqHgIoaAAACioeAihoAAAKKkoCe5YAAAQCe5UAAAQoFwAABioyAnL5AgBwKBcAAAYqSgJ7mAAABAJ7lwAABCgXAAAGKgAAABswBQBtAgAACwAAEQJ7CAAABCwIAnsHAAAELQEqAnsIAAAEb14AAApvaQAAChYKfhQAAARvagAAChMMOI0AAAASDChrAAAKC3MeAQAGEwQRBAJ9lgAABBIBKGwAAAoXmgwIclIOAHBvbQAACi0NCHJiDgBwb20AAAosUhEEEgEobgAACn2VAAAEEgEobAAAChaaDQJ7CAAABG9eAAAKCXJ6DgBwEQR7lQAABHKCDgBwKG8AAAoUEQT+Bh8BAAZzWQAACm9aAAAKJgYXWAoSDChwAAAKOmf////eDhIM/hYEAAAbbxMAAArcBi0xAnsIAAAEb14AAApyhg4AcHK2DgBwKAEAAAZzXQAAChMKEQoWb2EAAAoRCm9cAAAKJgJ7CAAABG9eAAAKc1sAAApvXAAACiYCewgAAARvXgAACnL4DgBwcgQPAHAoAQAABhQC/gZaAAAGc1kAAApvWgAACiYCewcAAARvXgAACm9pAAAKFhMFfhQAAARvagAAChMNOKMAAAASDShrAAAKEwZzIAEABhMJEQkCfZgAAAQSBihsAAAKF5oTBxEHciQPAHBvbQAACi1yEQdyUg4AcG9tAAAKLWQRB3JiDgBwb20AAAotVhEJEgYobgAACn2XAAAEEgYobAAAChaaEwgCewcAAARvXgAAChEIcnoOAHARCXuXAAAEcoIOAHAobwAAChQRCf4GIQEABnNZAAAKb1oAAAomEQUXWBMFEg0ocAAACjpR////3g4SDf4WBAAAG28TAAAK3BEFLTECewcAAARvXgAACnI2DwBwcnwPAHAoAQAABnNdAAAKEwsRCxZvYQAAChELb1wAAAomKgAAAAEcAAACAC8AoM8ADgAAAAACAHMBtikCDgAAAAAeAihoAAAKKgMwAgBSAAAAAAAAAAJ7mQAABHsLAAAEFm9xAAAKAnuZAAAEewwAAAQsMwJ7mQAABHsMAAAEF29gAAAGAnuZAAAEewwAAAQYb2AAAAYCe5kAAAR7DAAABBlvYAAABioAABswBQApAQAADAAAER8cKDgAAApy5g8AcCg5AAAKgAIAAAR+AgAABChyAAAKJt4DJt4AAoADAAAEA4AEAAAEKAUAAAYmF3LyDwBwEgBzcwAACgtzIgEABgwGLR9yHBAAcHJQEABwKAEAAAZy0wMAcCh0AAAKJt26AAAACHNNAAAGfZkAAAQIe5kAAARzdQAACn0LAAAECHuZAAAEewsAAARy3xAAcHLjEABwKAEAAAYWH3gg1AAAACh2AAAKKAMAAAZvdwAACgh7mQAABHsLAAAEctMDAHBveAAACgh7mQAABHsLAAAEF29xAAAKCHuZAAAEewsAAASABQAABAh7mQAABG8PAAAGCHuZAAAEbxIAAAYI/gYjAQAGc1kAAAooeQAACih6AAAK3goHLAYHbxMAAArcKgAAAAEcAAAAABYADSMAAwEAAAECAEYA2B4BCgAAAAAbMAMAUgAAAAgAABECKDoAAAotAt5HAihDAAAKKHsAAAoKBnLnEABwb3wAAAosKQYWjT0AAAFvfQAACnJ9AgBwb20AAAosEQIoDQAABhZzUAAACihRAAAK3gMm3gAqAAABEAAAAAAAAE5OAAMBAAABGzAEAJ0BAAANAAARfhQAAAQsD34UAAAEAxIAb08AAAotASoGF5pydggAcCgkAAAKLAsCKCIAAAbdawEAAAYXmnLOCABwKCQAAAosCwIoIwAABt1RAQAABheacjQJAHAoJAAACiwLAig8AAAG3TcBAAAGF5pyfAkAcCgkAAAKLAsCKD4AAAbdHQEAAAYXmnLMCQBwKCQAAAosCwIoQQAABt0DAQAABheaclIOAHBvbQAACiwUAgYXmh1vRwAACihHAAAG3eAAAAAGF5pyYg4AcG9tAAAKLBUCBheaHwtvRwAACihKAAAG3bwAAAAGF5pyHAoAcCgkAAAKLAsCKEwAAAbdogAAAAYXmgsHcu0QAHBvfgAAChYvKgcfXG9FAAAKFi8LBx8vb0UAAAoWMhQHKH8AAAotDH4DAAAEByg5AAAKC3NSAAAKDQkHb1MAAAoJF29UAAAKCQwGjmkYMRQGGJpvJQAAChYxCQgGGJpvgAAACggoVQAACibeLRMEcvUQAHBy/xAAcCgBAAAGBhaachsRAHARBG9AAAAKKGYAAAoZKAQAAAbeACoAAABBHAAAAAAAABcAAABYAQAAbwEAAC0AAABOAAABEzAFAKwAAAAOAAARc4EAAAoKFgs4kQAAAAcXWAsHAm8lAAAKLw4CB28mAAAKKIIAAAot5QcCbyUAAAoveQIHbyYAAAofIjMxAh8iBxdYb4MAAAoMCBYvBwJvJQAACgwGAgcXWAgHWRdZb0YAAApvhAAACggXWAsrMQcNKwQJF1gNCQJvJQAACi8OAglvJgAACiiCAAAKLOUGAgcJB1lvRgAACm+EAAAKCQsHAm8lAAAKP2f///8GKhswBAC9AwAADwAAEXOFAAAKCgaAFQAABAJyIREAcCg5AAAKCwcoOgAACi0F3ZcDAAAUDBQNFBMEFBMFc4EAAAoTBgcoQwAACihEAAAKExAWExE4YQMAABEQERGaEwcRBCxbEQdvIwAAChEEKCQAAAosPQksMgl7KgAABBeNPAAAARMSERIWEQWiERJvhgAACgl7KwAABHI1EQBwEQYohwAACm+EAAAKFBMEOAMDAAARBhEHb4QAAAo49QIAABEHbyMAAAoTCBEIbyUAAAo54AIAABEIFm8mAAAKHzs70QIAABEIFm8mAAAKHyM7wgIAABEIcjkRAHAoJAAACi0OEQhySREAcCgkAAAKLCgJOaACAAByVREAcBMFEQgXco0CAHBviAAAChMEEQZviQAACjh+AgAAEQhyaxEAcCgkAAAKLQ4RCHKFEQBwKCQAAAosNQk5XAIAAHKPEQBwEwURCHKFEQBwKCQAAAotB3KfEQBwKwVyuxEAcBMEEQZviQAACjgtAgAAEQhyxxEAcCgkAAAKLQ4RCHLZEQBwKCQAAAosKAk5CwIAAHLnEQBwEwURCBdyjQIAcG+IAAAKEwQRBm+JAAAKOOkBAAARCHL/EQBwKCQAAAotDhEIchsSAHAoJAAACiwoCTnHAQAAcicSAHATBREIF3KNAgBwb4gAAAoTBBEGb4kAAAo4pQEAABEIcnUCAHBvbQAACjlfAQAAEQhyeQIAcG+KAAAKOU4BAAARCBcRCG8lAAAKGFlvRgAACm8jAAAKEwkRCXI5EgBwb20AAAosQREJGm9HAAAKbyMAAAoTCXN6AAAGEwoRChEJbyUAAAoWMAdyQxIAcCsCEQl9LAAABBEKDAYIb4sAAAoUDTgcAQAAEQlyRxIAcG9tAAAKLGARCRtvRwAACm8jAAAKEgsojAAACjn1AAAAEQsXLwMXEwsRCxwxAxwTCwgtJ3N6AAAGEwwRDHJTEgBwclkSAHAoAQAABn0sAAAEEQwMBghviwAACggRC30uAAAEOK4AAAARCXJlEgBwb20AAAosDxEJHW9HAAAKbyMAAAoTCQgtJ3N6AAAGEw0RDXJTEgBwclkSAHAoAQAABn0sAAAEEQ0MBghviwAACnN5AAAGEw4RDhEJbyUAAAoWMAdyQxIAcCsCEQl9KQAABBEODQh7LQAABAlvjQAACis1CSwyEQgoGAAABhMPEQ9vjgAAChYxHwl7KgAABBEPb48AAApvhgAACgl7KwAABBEIb4QAAAoRERdYExEREREQjmk/lPz//94DJt4AKgAAAEEcAAAAAAAADAAAAK0DAAC5AwAAAwAAAAEAAAETMAMAIgAAABAAABECHyBvRQAACgoGFjIPAgYXWG9HAAAKbyMAAAoqcpIIAHAqAAATMAQAYQAAAAgAABECbyUAAAoWMBIDjmkXMAdykggAcCsGAxeaKwECCgZvIwAACgoGbyUAAAoYMi0GFm8mAAAKHyIzIgYGbyUAAAoXWW8mAAAKHyIzEAYXBm8lAAAKGFlvRgAACgoGKE4AAAoqAAAAEzAEAPoAAAARAAARAh8vH1xvkAAACgoGH1xvRQAACgsHFjIKBhYHb0YAAAorAQZvkQAACgwEBxYyCwYHF1hvRwAACisFcpIIAHBRCHJ1EgBwKCQAAAotDQhyfxIAcCgkAAAKLAgDfpIAAApRKghyoxIAcCgkAAAKLQ0Icq0SAHAoJAAACiwIA36TAAAKUSoIctMSAHAoJAAACi0NCHLdEgBwKCQAAAosCAN+lAAAClEqCHIBEwBwKCQAAAotDQhyCRMAcCgkAAAKLAgDfpUAAApRKghyHxMAcCgkAAAKLQ0IcikTAHAoJAAACiwIA36WAAAKUSpyURMAcAIoMgAACnOXAAAKeh4CKGgAAAoqbgRvmAAACiwSAnuaAAAEBG+YAAAKb5kAAAomKm4Eb5gAAAosEgJ7mgAABARvmAAACm+ZAAAKJioAABMwAwDzAAAAEgAAEXMkAQAGCwIWb1QAAAoCF2+aAAAKAhdvmwAACgIXb5wAAAoCb50AAAotFgIongAACm+fAAAKAiieAAAKb6AAAAoHcywAAAp9mgAABAIoVQAACgoGB/4GJQEABnOhAAAKb6IAAAoGB/4GJgEABnOhAAAKb6MAAAoGb6QAAAoGb6UAAAoGb6YAAAoHe5oAAARvpwAAChYxIQNyZxMAcAd7mgAABG8zAAAKbyMAAAooMgAACm+ZAAAKJgNydxMAcAZvqAAACoxmAAABKKkAAApvmQAACiYGb6gAAAosFnKHEwBwBm+oAAAKjGYAAAEoqQAACioUKgATMAMAUAAAABMAABECF29UAAAKAihVAAAKCgZvpgAACgNydxMAcAZvqAAACoxmAAABKKkAAApvmQAACiYGb6gAAAosFnKHEwBwBm+oAAAKjGYAAAEoqQAACioUKhswBQChAAAAFAAAERQKKKoAAApynRMAcCirAAAKEwQSBHK1EwBwKKwAAAoDKGYAAAooOQAACgoGDgYCDgkoZgAACg4EKFEAAApzUgAACgwIBG9TAAAKCAVyuRMAcAZyuRMAcChvAAAKb4AAAAoICw4FLBAHDgVvnwAACgcOBW+gAAAKDggtCgcOBygdAAAGKwgHDgcoHgAABg3eDwYsCwYoOwAACt4DJt4A3AkqAAAAARwAAAAAkwAImwADAQAAAQIAAgCOkAAPAAAAAAswAwA2AAAAAAAAAAMsCQIXKK0AAAorBgIoOwAACgQlShdYVN4bJgUlShdYVA4Eb44AAAoeLwgOBAJvhAAACt4AKgAAARAAAAAAAAAaGgAbAQAAAR4CKGgAAAoqggJ7mwAABAJ7nAAABAJ7nQAABB8gAnueAAAEKK4AAAoqAAAAGzAKANsIAAAVAAARAhaabyEAAAoKBnK9EwBwKCQAAAosKn4FAAAELBZ+BQAABCBgCQAActMDAHADF28dAAAK3gMm3gAUEyndmAgAAAZyxRMAcCgkAAAKOY4BAABzJwEABhMHEQcDfZsAAAQRB3LTAwBwfZwAAAQRBxp9nQAABBEHIAABAAB9ngAABAMffG9FAAAKCwcWPwUBAAARBwMWB29GAAAKbyMAAAp9mwAABAMHF1hvRwAACheNPQAAARMqESoWH3ydESpvIgAAChMrFhMsOL4AAAARKxEsmgwIHz1vRQAACg0JFz+iAAAACBYJb0YAAApvIwAACm8hAAAKEwQICRdYb0cAAApvIwAAChMFEQRy1RMAcCgkAAAKLAsRBxEFfZwAAAQrZREEcuETAHAoJAAACiwsEQcRBXLxEwBwKCQAAAotFBEFcvcTAHAoJAAACi0DGisEFysBFn2dAAAEKysRBHIJFABwKCQAAAosHREHEQVyGRQAcCgkAAAKLQcgAAEAACsBFn2eAAAEESwXWBMsESwRK45pPzf///8cEwYFLBoFEQf+BigBAAZzrwAACm+wAAAKpWUAAAETBhEHe50AAAQtCBQTKd0TBwAAEQYcLgwRBhcuB3IdFABwKwEUEynd+gYAAAZyKRQAcCgkAAAKLBUCF5oosQAACiiyAAAKFBMp3dgGAAAGcjMUAHAoJAAACix7FhMIAheaKLMAAAoTLRYTLisfES0RLpoTCREJb7QAAAoRCBdYEwjeAybeABEuF1gTLhEuES2OaTLZBBqNAQAAARMvES8Wcj0UAHCiES8XEQiMZgAAAaIRLxhyURQAcKIRLxkCF5qiES8otQAACm+ZAAAKJhQTKd1QBgAABnJZFABwKCQAAAotEAZyYRQAcCgkAAAKOdwAAAAGclkUAHAoJAAACi0pc1IAAAoTDhEOcm0UAHBvUwAAChEOcn0UAHADKDIAAApvgAAAChEOKxhzUgAAChMNEQ0CF5ooTgAACm9TAAAKEQ0TCgZyWRQAcCgkAAAKLHACjmkYMWpzLAAAChMLGBMMK0kRC2+nAAAKFjEKEQsfIG8uAAAKJhELAhEMmh8gb0UAAAoWLwYCEQyaKxNyuRMAcAIRDJpyuRMAcChmAAAKby0AAAomEQwXWBMMEQwCjmkysBEKEQtvMwAACm+AAAAKEQoEKB0AAAYTKd1XBQAABnJVEQBwKCQAAAosLgNyhRQAcHJtFABwcn0UAHAongAAChRykggAcAQWcpIIAHAoHwAABhMp3RwFAAAGco8RAHAoJAAACiw0A3KPFABwcpkUAHBytxQAcBdzUAAAChZzUAAACnILFQBwBBZykggAcCgfAAAGEynd2wQAAAZycxUAcCgkAAAKLDRzUgAAChMnESdybRQAcG9TAAAKESdyfRQAcAMoMgAACm+AAAAKEScEKB4AAAYTKd2aBAAABnLnEQBwKCQAAAosLgNyhRQAcHJtFABwcn0UAHAongAAChRykggAcAQXcoEVAHAoHwAABhMp3V8EAAAGcicSAHAoJAAACiwvA3KPFABwcpkUAHBytxQAcBdzUAAAChRykggAcAQXcqMVAHAoHwAABhMp3SMEAAAGcgsWAHAoJAAACiwtc1IAAAoTDxEPAwIoGwAABm9TAAAKEQ8Xb1QAAAoRDyhVAAAKJhQTKd3pAwAABnIVFgBwKCQAAAo5gQEAAAIXmihOAAAKEhASESgcAAAGAhiacm0CAHAoJAAACi0FAhiaKwVykggAcBMSAhmabyEAAAoTE3IlFgBwAhoCjmkaWSi2AAAKExQRE3IpFgBwKCQAAAosFhoTFhEUKLEAAAqMZgAAARMVOOYAAAARE3I1FgBwKCQAAAosFx8LExYRFCi3AAAKjHAAAAETFTjBAAAAERNyQRYAcCgkAAAKLAwYExYRFBMVOKcAAAARE3JPFgBwKCQAAAosHh0TFhEUF409AAABEzARMBYffJ0RMG8iAAAKExUrexETclsWAHAoJAAACixmGRMWERRyJRYAcHKSCABwb7gAAApybQIAcHKSCABwb7gAAAoTFxEXbyUAAAoYW41xAAABExgWExkrHhEYERkRFxEZGFoYb0YAAAofECi5AAAKnBEZF1gTGREZERiOaTLaERgTFSsHFxMWERQTFREQERFvugAAChMaERoREhEVERZvuwAACt4MERosBxEabxMAAArcFBMp3VgCAAAGcmkWAHAoJAAACixoAheaKE4AAAoSGxIcKBwAAAYCjmkYMT8RGxEcF2+8AAAKEx0RHSwhER0CGJpybQIAcCgkAAAKLQUCGJorBXKSCABwFm+9AAAK3hYRHSwHER1vEwAACtwRGxEcFm++AAAKFBMp3eMBAAAGcnkWAHAoJAAACjmYAQAAAwIoGwAABhMeER4XjT0AAAETMRExFh9cnRExb78AAApvJQAAChkwE3KLFgBwER4oMgAAChMp3ZgBAAAWEx8WEyBzgQAAChMhER4fKm9FAAAKFi8PER4fP29FAAAKFj+GAAAAER4owAAAChMiER4owQAAChMjESIowgAACjmYAAAAESIRIyjDAAAKEzIWEzMrGxEyETOaEyQRJBYSHxIgESEoIAAABhEzF1gTMxEzETKOaTLdESIRIyjEAAAKEzQWEzUrGxE0ETWaEyURJRcSHxIgESEoIAAABhE1F1gTNRE1ETSOaTLdKzARHijCAAAKLBARHhcSHxIgESEoIAAABisXER4oOgAACiwOER4WEh8SIBEhKCAAAAYRIW/FAAAKEzYrHBI2KMYAAAoTJgRyyxYAcBEmKDIAAApvmQAACiYSNijHAAAKLdveDhI2/hYLAAAbbxMAAArcBHLdFgBwER+MZgAAAREgFjAHcpIIAHArFnLzFgBwESCMZgAAAXIJFwBwKMgAAAooyAAACm+ZAAAKJhQTKd47BnIvFwBwKCQAAAosEgMCKBsAAAYocgAACiYUEyneHHI7FwBwBigyAAAKEyneDRMoEShv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CRYoNAAABgkWKDQAAAYCbyMAAAoXjT0AAAETIBEgFh8unREgb78AAAoXjT0AAAETIREhFh8unREhbyIAAAoTIhYTIysuESIRI5oTBCgCAQAKEQRvAwEAChMFCREFjmnSbwQBAAoJEQVvBQEAChEjF1gTIxEjESKOaTLKCRZvBAEACgkG0Sg0AAAGCRcoNAAABnMGAQAKEwcRB28HAQAKBW8IAQAKEQcIbwkBAAoIbwoBAAppBB81bwsBAAomfgwBAAoWcw0BAAoTCBEHEghvDgEAChMG3gwRBywHEQdvEwAACtwRBhmRHw9fEwkRCSwxF408AAABEyQRJBZyPR4AcBEJjGYAAAERCRkuB3KSCABwKwVyUx4AcCjIAAAKohEkKhEGGig1AAAGEwoRBhwoNQAABhMLHwwTDBYTDSsXEQYRDCg3AAAGEwwRDBpYEwwRDRdYEw0RDREKMuNzgQAAChMOFhMPOJoCAAARBhIMKDgAAAYTEBEGEQwoNQAABhMREQYRDBpYKDYAAAYTEhEGEQweWCg1AAAGExMRDB8KWBMUEREXM28djQEAAAETJRElFhEGERSRjHEAAAGiESUXcokCAHCiESUYEQYRFBdYkYxxAAABohElGXKJAgBwohElGhEGERQYWJGMcQAAAaIRJRtyiQIAcKIRJRwRBhEUGViRjHEAAAGiESUotQAAChMVODMBAAARER8cMyofEI1xAAABExYRBhEUERYWHxAoDwEAChEWcxABAApvMwAAChMVOAMBAAARERguCxERGy4GEREfDDMUERQTFxEGEhcoOAAABhMVON8AAAARER8PMy4RFBhYExgRBhEUKDUAAAaMZgAAAXIlFgBwEQYSGCg4AAAGKMgAAAoTFTirAAAAEREfEDNjcywAAAoTGREUExoRFBETWBMbKz4RBhEaJRdYExqRExwRGShDAAAKEQYRGhEcbxEBAApvLQAACiYRGhEcWBMaERoRGy8NERlyax4AcG8tAAAKJhEaERsyvBEZbzMAAAoTFStCG40BAAABEyYRJhZycx4AcKIRJhcREYxmAAABohEmGHJ/HgBwohEmGRETjGYAAAGiESYacoUeAHCiESYotQAAChMVERQRE1gTDBERFy5VEREfHC5IEREYLjwRERsuMBERHwwuIxERHw8uFhERHxAuCRIRKOcAAAorL3IZHgBw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AQAAAXICe6gAAAQCe6cAAAR7pQAABH51AQAKb3YBAAoqcgJ7qAAABAJ7pwAABHulAAAEfnUBAApvdgEACioAABswBQBeAAAANgAAEQRvdwEACgoGGm8NAAAKFxcCKHMBAAoZWQIodAEAChlZc3gBAAofCSh8AAAGC343AAAEIgAAgD9zeQEACgwGCAdvegEACt4KCCwGCG8TAAAK3N4KBywGB28TAAAK3CoAAAEcAAACAD0ACkcACgAAAAACAC0AJlMACgAAAAC+AnuqAAAEIP8AAAAg6AAAAB8RHyMoewEACm98AQAKAnuqAAAEKH0BAApvfgEACiqGAnuqAAAEKA4AAApvfAEACgJ7qgAABH44AAAEb34BAAoqHgIofwEACioAABswBwBKAAAANwAAEX43AAAEc4ABAAoKBG93AQAKBhYCe6kAAARvdAEAChdZAnupAAAEb3MBAAoCe6kAAARvdAEAChdZb4EBAAreCgYsBgZvEwAACtwqAAABEAAAAgALADQ/AAoAAAAACzAEADYAAAAAAAAABG+CAQAKIAAAEAAuASoofQAABiYCKB8AAAogoQAAABgogwEACn6EAQAKKH4AAAYm3gMm3gAqAAABEAAAAAAOACQyAAMBAAABEzAEAGkAAAA4AAARc54AAAYLBwNvhQEACgciAAAQQRYoewAABm+GAQAKBwJ7rAAABB5zhwEACm+IAQAKBwQfHHOJAQAKb4oBAAoHCgYFb4sBAAoCe6sAAARvjAEACgZvjQEACgIle6wAAAQEHlhYfawAAAQqHgIoZgAABipeAnumAAAEbw8AAAYCe6UAAAQoZQAABioeAihnAAAGKh4CKGkAAAYqHgIoagAABioeAihrAAAGKh4CKGwAAAYqAAAAGzAFAGcAAAA2AAARBG93AQAKCgYabw0AAAoWFgJ7rQAABG9zAQAKF1kCe60AAARvdAEAChdZc3gBAAoeKHwAAAYLfjcAAAQiAACAP3N5AQAKDAYIB296AQAK3goILAYIbxMAAArc3goHLAYHbxMAAArcKgABHAAAAgBGAApQAAoAAAAAAgA2ACZcAAoAAAAAHgIoagAABipGBG+OAQAKHxszBgIofwEACioAABMwBQCcBgAAOQAAERQTChQTCxQTDBQTDRQTDhQTDxQTEBQTERQTEhQTExQTFBQTFRQTFnMvAQAG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AQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQAoEAAAAgDSEAAAAQA1DwAAAgA3DwAAAQDBEAAAAgDVEAAAAwDZEAAABADgEAAAAQCKEAAAAgDVEAAAAwB+EAAABADnEAAAAQDpEAAAAgDsEAAAAwDvEAAABADyEAAABQB+EAAABgCKEAAAAQDBEAAAAgD1EAAAAwD6EAAAAQABEQAAAQAGEQAAAQCYCwAAAgAMEQAAAQCYCwAAAgAQEQAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQIAAQAVEQIAAgAbEQIAAwD0DwAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQA/EAAAAQAhEQAAAgATEQAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQA+LgAAAgBkGwAAAQA/EAAAAgATEQAAAQA+LgAAAgBkGwAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQCKEAAAAQBDEAAAAQATEQAAAQATEQAAAQATEQAAAQATEQAAAQATEQAAAQAoEAAAAgDSEAAAAQA1DwAAAgA3DwAAAQDBEAAAAgDVEAAAAwDZEAAABADgEAAAAQCKEAAAAgDVEAAAAwB+EAAABADnEAAAAQDpEAAAAgDsEAAAAwDvEAAABADyEAAABQB+EAAABgCKEAAAAQDBEAAAAgD1EAAAAwD6EAAAAQAoEQAAAgAsEQAAAwA1EQIABAA6EQIABQA0CAAAAQA+EQAAAgCfDgAAAwChDgAABAB+EAAABQBGDwAABgBFEQAAAQBNEQAAAQA/EAAAAQA6EQAAAgA0CAAAAQA6EQAAAgA0CAAAAQA6EQAAAgA0CAAAAQA6EQAAAgA0CAAAAQA6EQAAAgA0CAAAAQA6EQAAAgA0CAAAAQA6EQAAAgA0CAAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQATEQAAAQATEQAAAQATEQAAAQATEQAAAQATEQAAAQCfDgAAAgChDgAAAwB+EAAABABGDwAAAQATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQCfDgAAAgChDgAAAwB+EAAABACKEAIAAQAVEQIAAgAbEQIAAwD0DwAAAQA/EAAAAgATEQAAAQA/EAAAAQA/EAAAAQBQEQAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQCKEAAAAQCKEAAAAQATEQAAAQATEQAAAQBDEAAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQAoEAAAAgDSEAAAAQA1DwAAAgA3DwAAAQDBEAAAAgDVEAAAAwDZEAAABADgEAAAAQCKEAAAAgDVEAAAAwB+EAAABADnEAAAAQDpEAAAAgDsEAAAAwDvEAAABADyEAAABQB+EAAABgCKEAAAAQDBEAAAAgD1EAAAAwD6EAAAAQABEAAAAgAoEQAAAQBWEQAAAQBWEQIAAQAVEQIAAgAbEQIAAwD0DwAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQBWEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQAAAQATEQAAAQCIDwAAAgBYEQAAAwBVDwAABABbEQAAAQCKEAAAAQCKEAAAAgBfEQAAAwDZEAAABADgEAAAAQBsEAIAAQCAEAAAAQBfEQAAAgDZEAAAAwDgEAAAAQCfDgAAAgChDgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQBlEQAAAgBsEQAAAQBfEQAAAgDZEAAAAwDgEAAAAQBfEQAAAgDZEAAAAwDgEAAABABzEQAABQBlEQAAAQB8EQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgBkGwAAAQA/EAAAAgBkGwAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQB9KAAAAgB+EAAAAwCKEAAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQDlFgAAAgDsFgAAAQA/EAAAAgATEQAAAQA/EAAAAgATEQoAFQBpAVcHYwBxAVcHZwB5AVcHYwBJAFcHYwBRAOwRnQNRAPIRnQNJAPgRoQNRAP8RnQNRAAkSnQNJABQSYwCBAVcHagOJATYSsQOJAU4SugNhAGASwQOJAXASxgNRAFcHzAOhAVcHxgOJAYcS1AOxAZwSYwDxAFcH3QPBAVcHYwDBAc4S6APBAdwS6APxAPkS7wNJAAgT9QOJASITBASBATYTCwRZAD8TDwRBAEoTMgQRAFkTOwQRAGgTCwThAXoTPwThAY0TDQLhAZoTRAThAaATDQLhAaUTSwThAbETUQThAbwTVQTxAcwTWgT5AVcHYwAMAFcHZwAMAEgUfAQMAEwUhAShAFcHYwChAFgUngShAFgUpAShAFgUqgQJArkUtAQBAskUwgThAdIUDQAJAMkUDQIUAFcHdwMRANkUOwQZAvoU2QQpAhkV3wQxAjgV5gRBAksVDQBJAlgVPwRJAl8VggBRAmsV8QRZAocV+ARRAqoV/wQJALcVDQVxAskVDQIcAFcHYwAcANUVfASpAN4VMgVJAucVNwXhAcwTPwXhAfQVRAXhAfQVSgV5AiMWTwWJAi8WOwSBAksWVwWRAlYWXQWZAmcWDQLhAaATZAUxAnEWpwAcAEwUhAShAlcHnwVJApkWpAWZAFcHYwCZAKYWjQCZALMWnwWpAs8WsAXBAgkYrwFpAFcHYwDJAjAY0gWxAlcHdwPRAkgU2AXhAlcHYwDRAkgU5QVxAFcHjQDpAnEY0gXZAoMY7AVxAFcHYwDZAo0YnwXxAlcHdwMpAqwY8wVBALgY+gVxAM0YnwXhAdIUDAbZAtkYjQAJAFcHYwDRAnASYwAcAGQZEwYkAIEZKAYsAGcWPQbhAY0ZQgYsAJgZRwbhAdIUTAYkAKAZOwRBAMwZnwUJA/AZhQYZA1cHjAYhAxkVlAZBAFcHYwBhAB4anAZBACcapAZBANkYjQDBAjAaqgbBAosDrwFJAkQaugbhAVAaQgbhAVkaZAXhAcwTwQZBAmMaPwSZAHAajQA0AFcHYwDpAX4a2QbhAcwT3gY0AEgU5AY8AFcHYwBEAEgU5AbhAYsaAwfhAZAaDQc0AHASYwDhAZcaQgY8AEgU5AYxA6YaEwdMAEgU5AY0AK8aUQQ0ALkaIQfhAcEaVgfhAckaDQI5A9oaXAc5A+YaXAc5A/MaXAc5A/8aXAc5AwUbXAdxAlcHjQBBA2cbDQKhAHAbngSZAHsbnwWZAI4bnwWZAKkbnwWZAMMbcgepAN4bMgWZAOobdweZAAUcdwdJA1cHdwOpAjgcfQepAk8cfQepAmUcYwCpAnkcYwCpAowcYwChALETUQSpApgcUQThAdIUhAdBAqUcbABRA7YcmAdRA8kUwgQJA18VswEhAxkVugdUAFcHdwMRAMEO1AcxAzgd2wfJAD4d4AepAkQd5QepAlcdYwDhAdIU7QfhAYsa8weBAzgd/AfhAcEaAQiRA28dBwiRAHYdDQiRAJUdEwiRAJ4dHAiRAKkdIwiRALUdIwjhAcYdZAVBAs4dpwBBAt8dpwAJA1gVPwQJA+sdKgEJA/QdKgE0AGQZKQhcAIEZRwZcAKAZOwThAdIUOgg8AK8aUQQRABkVYwAZAAMeYwCpA1cHYwCpAzkeowixA0ceqwixA2cesQixA3MetwixA5EeuwjJA50eUQSxA6UewQjhAbAexgipAzke3AjJA1cH8AipAzke9gjRA8EeFAnZA1cHYwDZA+ceGglJAf8eJgnhAxMffwLZAxsfLAnRAyYftwhxArcVDQXpA0kfDQLBAzgdQwnBA1IfwQiRA8kUZAnhAWIfagnhAdIUcAnxA28fowkxA8kUDQLhAaQfSgWBA8kUDQL5A7EfbAABBM4f0AkBBPgf1wkBBEkfDQIBBCMg3QkBBFIg4wkZBIgg6QkhBGQZ7wlkAIEZRwY5BGcesQjBA+ogAwoxBPwgsQhJBKAZOwQZBE4hCQpRBGQZDwpsAIEZRwZZBGcesQgZBJMhIwphBGQZKQp0AIEZRwZpBFcHYwBpBL8hdApxBFcHYwCxAFcHeQqpANghMgWpAOIhgAqxAOshhgqxAOshiwqBBFcHYwCBBAIikQqJBA0iZwBxBLkawQh5BLETtwiBBDkelwrBAyAioAqRBFcHpQqBBC8irQrxATcitgrBA1cHiwqpADwiwwqZBFEiFguZBGciZwChBHMiZwChBIgijQCZBKIiHQupBMIiIwvhAdIiSwS5BOAiDQKxBPgiKQuxBAcjDQKpBDEjLwvRBFYWwgSpBHAjDQKpBIAjNQt5BJIjOwvZBKQjHQvhBFcHeQrpBMkjDQLhAdMjPwQ0AFYWeQs0AOEjfws0AJAahQs0AOgjZwBhAPEjjAuJA8kUwgRhAPcjjAthAP0jjAvxAwMklgvxA28flgvxAwcknAt8AGQZtAuEAIEZRwaMAFcHYwB5AiMW9wuUAFAafwucAFcHYwCcANUVfAREAK8aUQSMANUVfASUAFcHYwCUAEgUfwuUAOEjfws0AFcHPwxJAhokSQxEAFYWeQv5BFcHdwMRAOMOWwyMAEwUhAQhAVcHdwPJAFcH9QLJAJcknwXJAM8WYwABBVcHjQBZAbUkegxZAdIigwxZAbokDQIJBVcHYwARBVcHYwARBRYlnwURBSslnwURBVMloQwZBWwlpwwhBZUlrQwpBccluAwxBdIlOwQ5BWQZvgxJBIEZxAxBBf0lUQShAFgUyAxBBQYmDQIpBRQmzgxZASkm1AxRAjIm2wxRAk8m4QxhAdIi9gxhAVkmDQVRAn8mAA1RAqUTCQ1hAaUT9gxhBcEORQ1xAsgmTA2cAEwUhAQRAFcHYwDJAConZg3JADwnjQBxBW0nbQ1xBUkfDQJ5BVcHjQCkANUVfASkAKAnfwukAFYWfw3ZAKwnUQTZALQnCwSBBcYnUQQUAMEO5AYRAKUH+AGkAFcHYwARACspUQQRADUpUQQZAUAppA2xAsEOpQIJAUYpqQ0BAVcHEQORBVcHrw2JAVcptg1hAB4ayg0RAGApxgNhAG4pwQMRAHgpxgMZAIYpYwCRBVcHxgOJAYwp0w0RAaIp5A2BBa0p6g2BBbkpXAMRANkYjQARAL4p7w0hAlcHagMRAMcp3wShBVcHagMRANkp9Q0RAIMY7AURAPQp/A2pBUgUGQOJBQYqCQ4ZAFcHYwAZACIqDw7BBVUqFg4ZAHkqHQ4ZAIsqnwUZAJcqnwUZAKYq9Q0RALUq7AURAMcq7AXZBVcHdwMRAOQqJA4hAFcHYwBBAVcHYwARAO4qnwVBAQwrKw7pBSIrMg4RACsrOA4RADYr7AURAEUr7AXxBVcHdwMRAGYrPw6sAFcHdwOsAMEOUQ4BBlcHZwARAIUrWw7hAFcHYwARAJsrYg7hAKkraQ7hALIrnwXhAMQrnwXhANQrnwXhAPIrcA7hABksdw4hBkgUfQ4RADIs7AUxBlcHdwMRAFIshQ7hAF4sYwDhADAY2g45BnASYwDhAZIs4A6cAKAnfwucAFYWfw1JBlcHjQBJBsAs6A5RBkgU7g5JBt0s9Q5hAOUswQNJBngpxgM5BkgU+g7hAO4sYwAhAxkVGg/hACQtKg9pBq8aUQRpBlYWMA9JBjYtxAwhAxkVPQ9xBkctUQ9xBskUwgREAFcHYwBMAFcHYwDRAU8tYA/xAFcHZg8BAewRUQQBAfIRUQRJAPgRgA8BAf8RUQQBAQkSUQS0AFYWeQsRAMUuYwC8AFYWeQsRAMwZnwW0AK8aUQQRANAunwXBAtwuxQ+8AFcHYwC0AFcHYwA8AFYWeQu0AEgU5AZMAK8aUQTxAwMkowlMAFYWeQsRAN0s9Q4RAPAuZwARAPouPw4RAAgvPw68AEgU5AYBBlcHEQPpAFcHYwB5BiAvnwV5Bi4vnwV5BvIrcA7pAEYvyw/xAFcH0g/BAlUvxQ+JBlcHdwMZAH0v2A8RAIwvNxC8AGQZKQjEAIEZRwYRAJovOwQRAKYvSBABAVAaThCRBmQZvgzEAKAZOwQRAOcvUQQRAO8vZwARAfIRUQQRAPcvlxCZBg0wnBChBTUpUQQRABkwpRARAEcwOwR5BlowjQARAI0YnwURADYtxAwRAJ8wnwWBBbIwtwgRACIKvgIRAC8KvgIRADwKxQIRAEgKxQIRALowEBERAMUwFRERANMwSBCJAecwGhERAPUwOwSJAecwJBERAAExDQKJAQoxLxHMAFYWeQvMAK8aUQTMAFcHYwDMAEgU5AahBskUwgT5BMEOYwCJBdU0nwXhAYsarAARAIs27AWxBlw3ggARAI43OwTpBZQ3Mg4RAJ437AURAKg37AURALI3OwQpAc8WYwApARI4YwC5BpwSYwApAVcHYwApASE4ZwApAS447AW5Bjc47AXBBlcHYwDJBoA4jQDJBqYWjQDRBpg4vxPJBqM4DQIxAVcHYwAxAfY4nwURAAk5ZwDZBlcHYwAxAYMY7AUZAEsMvgIZAG8MLgPhBic5UQQxAV4sYwAxATAY/xPpBnASYwDpBkgUBRQxAe4sYwCxBko5bAAZAKUH+AGJAXg60w3UAFcHYwBJAIQ6EQP5BlcHMRQRAJY6NxQBB1cHdwMZALk6PhTcAFcHYwBBAtw6pwDcAKAnfwvcANUVfATcAGQZmRTkAIEZKAbsAGcWPQbkAKAZOwR5Bvg6ZwDhBFcH1RTpBAs7DQIRAewRUQSpBXASYwDUAHASYwAZABkwpRChBSspUQQRAFE7Pw7UAEgU5AYRAMUunwXUAFYWeQvUAK8aUQR5BnASYwBJAmA7hwA0ANUVhQvBAXQ7HBXBAZM7IxUhAPIrcA6BBdIibBUpB+M7chWJAfI7gBWBAQE8ixUxB1cHnxUCAKkAmwMOAK0AAAAIAKABHwMuABsArxUuABMAphVDA0MBaASDA0MBaASjA0MBaATDA0MBaATjA0MBaAQDBEMBaARDBEMBaARhBEMBaASBBEMBaASDBEMBaASjBEMBaATDBEMBaATjBEMBaAQDBUMBaAQjBUMBaARDBUMBaARjBUMBaASDBUMBaASjBUMBaATjBUMBaAQDBkMBaARDBkMBaARjBkMBaASjBkMBaAQjB0MBaARDB0MBaASDB0MBaAShB0MBaASjB0MBaATBB0MBaATDB0MBaATjB0MBaATACUMBaATgCUMBaAQACkMBaAQgCkMBaARACkMBaARgCkMBaASACkMBaASgCkMBaATACkMBaATgCkMBaAQAC0MBaAQgC0MBaARAC0MBaARgC0MBaASgDUMBaATADUMBaATgDUMBaAQADkMBaAQgDkMBaARADkMBaARgDkMBaASADkMBaASgDkMBaATADkMBaATgDkMBaAQAD0MBaAQAEkMBaAQgEkMBaARAEkMBaARgEkMBaASAEkMBaASgEkMBaATAEkMBaATgEkMBaAQAE0MBaATgFkMBaAQAF0MBaAQgF0MBaARAF0MBaARgF0MBaASgGEMBaATAGEMBaATgGEMBaATAGUMBaATgGUMBaAQAGkMBaAQgGkMBaARAGkMBaARgGkMBaASgG0MBaATAG0MBaATgG0MBaAQAHEMBaAQgHEMBaASgH0MBaATAH0MBaATgH0MBaAQAIEMBaAQgIEMBaARAIEMBaARgIEMBaASAIEMBaASgIEMBaATAIEMBaASgIkMBaATAIkMBaATgIkMBaAQAI0MBaAQBAGAAAAAbAAEAOAAAACEAAQA0AAAAOACrAxUEjQTHBO0EEwVqBawFuAUABlQGsQbGBuoGJwdSB2AHigeSB54HQQjNCOYIAwkzCUoJTwlUCVsJYAl2CYwJqQm+CT0KywoMC0MLbAuQC6ELxQveCxAMNgxkDHIMjQwTDVINWA1zDYYNvw3eDQIOjA4DDyUPNw9XD3MPig/AD98PVRB1EIYQjxCrELcQxBDYEOQQ8RD6EAgRPhFtEb4RxxHOEdMR7hEDEgsSHRIlEjkSRhJOEm4SeBJ+EpESmRKfErASuBLCEs0S1BLeEhATIBMoE0kTVxNtE3cTghOIE6QTthPIE9QTChQUFEUUtRTcFOQU6RQAFQgVERUqFUwVehWSFZUnZC11BNMEKgUfBjQG0wb1BvwGGgfLBzMI+gkaCjQKrgu+C+8LAgwIDHgNRg6yD7kPQBBmESoUkRSlFK0UAAG7AHMHAQAAAb0AggcBAAAB+wA0DQEAAAH9AEMNAQAAAf8AQw0BAAABAQFaDQIAAAEDAW0NAQAAAU0BNA0BAAABTwFDDQEAAAFRAUMNAQAAAVMBWg0CAAABVQFtDQEAAAGrAfoLAQAAAa0BFQwBAAAB0wE0DQEAAAHVAUMNAQAAAdcBQw0BAAAB2QFaDQIAAAHbAW0NAQAAARcCDA4BAAABGQIdDgEAAAEbAjEOAQAAAR0CQA4BAAABHwJQDgEAECgAAJEA8F8AAJIAMMoAAJQABIAAAAAAAAAAAAAAAAAAAAAA4REAAAQAAAAAAAAAAAAAAAEA2QAAAAAABAAAAAAAAAAAAAAAAQDwAAAAAAAEAAAAAAAAAAAAAAAaAHIBAAAAAAQAAAAAAAAAAAAAAAEA4gAAAAAABAAAAAAAAAAAAAAAAQBdBgAAAAADAAIABAACAAUAAgAGAAIABwACAAgABwAJAAcACgAHAAsABwAMAAIADQAMAA4ADAAPAAwAEAAPABEAAgASAAIAEwASABQAEgAVAAIAFgAVABcAFQAYABUAGQACABsAGgAcAAIAHQACAB4AAgAfAAIAIAACACEAGgAiAAIAIwAiACQAAgAlAAQAJgAEACcABwAoAAcAKQAHACoABwArAAwALAAMAC0ADAAuAC0ALwAMADAADAAxADAAMgAMADMADAA0ADMANQAMADYANQA3ADUAOAAaADkADAA6AAwAOwA6ADwADwA9ABIAPgASAD8AEgBPAGQETwC+BAAAADxNb2R1bGU+AHdndHJheV9uZXcuZGxsAFRyYXlBcHAASG90S2V5SG9zdABQbHVnaW5NZ3JGb3JtAFRvb2xBY3Rpb24AVG9vbFRhYgBUb29sc0Zvcm0AVlAAU0JhcgBXaGVlbEZpbHRlcgBUQnRuAE5ldFRvb2xzRm9ybQBOQnRuAE5FZGl0AE5Mb2cAREJQAENsaXBGb3JtAE5vdGVGb3JtAE5UQ2hpcABTQlBhbmVsAENvbG9yRm9ybQBQVABNU0xMAE1vdXNlUHJvYwBQbHVnaW5Db2RlAG1zY29ybGliAFN5c3RlbQBPYmplY3QAU3lzdGVtLldpbmRvd3MuRm9ybXMAQ29udHJvbABGb3JtAFBhbmVsAElNZXNzYWdlRmlsdGVyAFZhbHVlVHlwZQBNdWx0aWNhc3REZWxlZ2F0ZQBaaABMAERhdGFEaXIAQmF0RGlyAEJhdFBhdGgATm90aWZ5SWNvbgB0cmF5UmVmAFN5c3RlbS5EcmF3aW5nAFN5c3RlbS5EcmF3aW5nLkRyYXdpbmcyRABHcmFwaGljc1BhdGgAUmVjdGFuZ2xlRgBSb3VuZGVkUmVjdABJY29uAENvbG9yAE1ha2VJY29uAENvbnRleHRNZW51U3RyaXAAbWVudQBUb29sU3RyaXBNZW51SXRlbQBtaUFwcHMAbWlQbHVnaW5zAG1pQXV0bwBob3RJdGVtcwB0cmF5AGhrSG9zdABIb3RUb29sYm94TW9kAEhvdFRvb2xib3hWawBIb3RQbHVnaW5zTW9kAEhvdFBsdWdpbnNWawBIb3RNZW51TW9kAEhvdE1lbnVWawBUb29sVGlwSWNvbgBUcmF5VGlwAHVpSW52b2tlcgBVaQBQYXJzZUhvdGtleQBIb3RrZXlUZXh0AEFwcGx5SG90a2V5cwBIYW5kbGVIb3RLZXkAU3RhcnR1cExpbmtQYXRoAElzQXV0b1N0YXJ0AFNldEF1dG9TdGFydABTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYwBEaWN0aW9uYXJ5YDIAQXBwcwBEZWZhdWx0Q29uZmlnVGV4dABMb2FkQ29uZmlnAFJlbG9hZENvbmZpZwBPcGVuQ29uZmlnRmlsZQBPcGVuRGF0YURpcgBCdWlsZE1lbnUAUmVmcmVzaE1lbnVDaGVja3MAUmVidWlsZFRyYXlNZW51AFJ1bgBGaXhMZWdhY3lDb25maWdJZkJyb2tlbgBMYXVuY2hBcHAATGlzdGAxAFRvb2xUYWJzAHRvb2xzRm9ybQBUb29sVG9rcwBMb2FkVG9vbHMAVG9vbFJlc3QAVG9vbFBhdGgATWljcm9zb2Z0LldpbjMyAFJlZ2lzdHJ5S2V5AFRvb2xSZWdTcGxpdABTeXN0ZW0uRGlhZ25vc3RpY3MAUHJvY2Vzc1N0YXJ0SW5mbwBTeXN0ZW0uVGV4dABTdHJpbmdCdWlsZGVyAFJ1bkhpZGRlbgBSdW5WaXNpYmxlAEVuY29kaW5nAFJ1blNjcmlwdEJsb2NrAFRvb2xEZWwARXhlY1Rvb2xTdGVwAFNob3dUb29scwBuZXRGb3JtAFNob3dOZXRUb29scwBQaW5nT25jZQBQaW5nUnR0AEhvcE9uY2UAVGVzdFBvcnQAUGFyc2VJcFY0AElwU3RyAE1hc2tUb0JpdHMAUGFyc2VJcE1hc2sASXBUeXBlAElwQ2xhc3MAU3VibmV0Q2FsYwBTdWJuZXRTcGxpdABSYW5nZVRvQ2lkcgBNYXNrVGFibGUATG9jYWxOZXRJbmZvAERuc1F1ZXJ5AFN5c3RlbS5JTwBCaW5hcnlXcml0ZXIARG5zQkUxNgBEbnNVMTYARG5zVTMyAERuc1NraXBOYW1lAERuc1JlYWROYW1lAEh0dHBDaGVjawBQdWJsaWNJcABjbGlwRm9ybQBDbGlwUHVzaABTaG93Q2xpcABub3RlRm9ybQBOb3Rlc1BhdGgAU2hvd05vdGUAY29sb3JGb3JtAENvbG9ySGV4AENvbG9ySHN2AFNob3dDb2xvcgBQbHVnaW5BY3Rpb25zAElFbnVtZXJhYmxlYDEAUGFyc2VUb29sU3RlcHMARXh0cmFjdFBsdWdpbkJsb2NrAExvYWRQbHVnaW5zAFBsdWdpbkluZm8AU3lzdGVtLkNvcmUASGFzaFNldGAxAERpc2FibGVkUGx1Z2lucwBMb2FkRGlzYWJsZWRQbHVnaW5zAFNldFBsdWdpbkRpc2FibGVkAFJ1blBsdWdpbgBQbHVnaW5Db2RlQ2FjaGUAUGx1Z2luUmVmcwBQbHVnaW5SZWZzRnVsbABDb21waWxlUGx1Z2luAFJ1bkNvZGVQbHVnaW4AU3lzdGVtLlRocmVhZGluZwBUaHJlYWQAcGx1Z2luVGhyZWFkAHBsdWdpbkludm9rZXIARW5zdXJlUGx1Z2luVGhyZWFkAHBsdWdpbk1ncgBTaG93UGx1Z2luTWdyAC5jdG9yAEFjdGlvbmAxAE9uSG90S2V5AHJlZwBSZWdpc3RlckhvdEtleQBVbnJlZ2lzdGVySG90S2V5AFJlZwBVbnJlZwBNZXNzYWdlAFduZFByb2MAaG9zdABMaXN0VmlldwBsaXN0AFBsdWdpbkRpcgBSZWZyZXNoTGlzdABSdW5TZWwAVG9nZ2xlU2VsAFNlbEZpbGUAT3BlbkRpcgBFZGl0U2VsAERlbFNlbABOZXdQbHVnaW4ATmFtZQBTdGVwcwBSYXcAQWN0aW9ucwBDb2xzAFRleHRCb3gAbG9nAHBhZ2VzAGxvZ1dyYXAAd2hlZWxGaWx0ZXIAVENfQkcAVENfU1VSRkFDRQBUQ19IRUFERVIAVENfU1VSRjIAVENfQk9SREVSAFRDX1RFWFQAVENfU1VCAFRDX0FDQ0VOVABUQ19DT05CRwBUQ19DT05GRwBGb250AEZvbnRTdHlsZQBURgBSZWN0YW5nbGUAVFJvdW5kAFRSZWxlYXNlQ2FwdHVyZQBUU2VuZE1lc3NhZ2UAVFNlbmRNc2dJbnQAVENyZWF0ZVJvdW5kUmVjdFJnbgBUU2V0V2luZG93UmduAE9uV2hlZWwAU2V0VnBPZmZzZXQAU2Nyb2xsVnAAUGFpbnRFdmVudEFyZ3MAUGFnZVNiUGFpbnQATW91c2VFdmVudEFyZ3MAUGFnZVNiRG93bgBQYWdlU2JNb3ZlAExvZ1NiTWV0cmljcwBJbnZhbGlkYXRlTG9nQmFyAExvZ1NiUGFpbnQATG9nU2JEb3duAExvZ1NiTW92ZQBMb2cARXZlbnRBcmdzAFJ1bkFjdGlvbgBEcmFnAERyYWdPZmYASG9zdABWcABQcmVGaWx0ZXJNZXNzYWdlAEJnAEJnSG92ZXIAQmdEb3duAEFjY2VudExpbmUAU2VsZWN0ZWQAaG92ZXIAZG93bgBPbk1vdXNlRW50ZXIAT25Nb3VzZUxlYXZlAE9uTW91c2VEb3duAE9uTW91c2VVcABPblBhaW50AE5DX0JHAE5DX0hFQURFUgBOQ19DQVJEAE5DX1NVUkYyAE5DX0JPUkRFUgBOQ19URVhUAE5DX1NVQgBOQ19BQ0NFTlQATkNfQ09OQkcATkNfQ09ORkcATlJvdW5kAE5SZWxlYXNlQ2FwdHVyZQBOU2VuZE1lc3NhZ2UATlNlbmRNc2dJbnQATkNyZWF0ZVJvdW5kUmVjdFJnbgBOU2V0V2luZG93UmduAGNoaXBzAE1ha2VQYWdlAE1rQnRuAFRocmVhZFN0YXJ0AFN0YW1wAEJ1aWxkUGluZ1RhYgBCdWlsZFRyYWNlcnRUYWIAQnVpbGREbnNUYWIAQnVpbGRIdHRwVGFiAEJ1aWxkUG9ydFRhYgBCdWlsZFN1Ym5ldFRhYgBCdWlsZExvY2FsVGFiAEZnAFByaW1hcnkAQm94AGJhcgBUaW1lcgBzeW5jAGRyYWcAZHJhZ09mZgBsYXN0Rmlyc3QAbGFzdFRvdGFsAE1ldHJpY3MAUGFpbnRCYXIATGluZQBTZXQAU2F2ZQBXTV9DTElQQk9BUkRVUERBVEUAQWRkQ2xpcGJvYXJkRm9ybWF0TGlzdGVuZXIAUmVtb3ZlQ2xpcGJvYXJkRm9ybWF0TGlzdGVuZXIASGlzdG9yeQBMaXN0Qm94AHNlbGZTZXQAT25IYW5kbGVDcmVhdGVkAEZvcm1DbG9zZWRFdmVudEFyZ3MAT25Gb3JtQ2xvc2VkAENvcHlTZWwAYm94AExhYmVsAHN0YXR1cwBzYXZlcgBzYlN5bmMAaGVhZGVyAHdyYXAAc3RyaXAAc2IAZmlsZXMAY3VyAGFjdGl2ZUNpAHNiRHJhZwBzYkRyYWdPZmYAQ04AQ0JvZHkAQ0hlYWQAQ1RleHQAQ1N1YgBORgBOb3RlUm91bmQATm90ZUNvbG9yUGF0aABMb2FkTm90ZUNvbG9yAE5vdGVzRGlyAE5vdGVNZXRhUGF0aABSZWxlYXNlQ2FwdHVyZQBTZW5kTWVzc2FnZQBTZW5kTXNnSW50AENyZWF0ZVJvdW5kUmVjdFJnbgBTZXRXaW5kb3dSZ24ATG9hZE5vdGVzAFNhdmVNZXRhAExvYWRDdXIAVGl0bGVPZgBSZWJ1aWxkVGFicwBTd2l0Y2hUbwBBZGROb3RlAERlbGV0ZU5vdGUAU2JNZXRyaWNzAFBhaW50U2IAU2JEb3duAFNiTW92ZQBBcHBseVRoZW1lAFNhdmVOb3cAVGl0bGUAQWN0aXZlAENlbnRlcgBTZXRXaW5kb3dzSG9va0V4AFVuaG9va1dpbmRvd3NIb29rRXgAQ2FsbE5leHRIb29rRXgAR2V0TW9kdWxlSGFuZGxlAEdldEN1cnNvclBvcwBzd2F0Y2gAbGJsAG1vdXNlSG9vawBwcm9jAFN0YXJ0UGljawBTdG9wUGljawBNb3VzZUhvb2tQcm9jAFBpY2tBdAB4AHkAcHQAbW91c2VEYXRhAGZsYWdzAHRpbWUAZXh0cmEASW52b2tlAElBc3luY1Jlc3VsdABBc3luY0NhbGxiYWNrAEJlZ2luSW52b2tlAEVuZEludm9rZQBTeXN0ZW0uUmVmbGVjdGlvbgBBc3NlbWJseQBBc20ATWV0aG9kSW5mbwBFbnRyeQBFcnJvcgB6aABlbgByAHJhZABjaABjAHRpdGxlAHRleHQAaWNvbgBzcGVjAG1vZABTeXN0ZW0uUnVudGltZS5JbnRlcm9wU2VydmljZXMAT3V0QXR0cmlidXRlAHZrAGlkAG9uAGRpcgBiYXRQYXRoAGYAY29kZQBsaW5lAHJhd0xpbmUAcmVzdAB0awBmdWxsAGhpdmUAc3ViAHBzaQBzY3JpcHQAZXh0AGV4ZQBhcmdzUHJlZml4AGVuYwBpb0VuYwBwcmVsdWRlAHZpc2libGUAdGFpbABwYXRoAGlzRGlyAG4AZmFpbABza2lwcGVkAHVpAHRpbWVvdXRNcwBzaXplAHJ0dAB0dGwAZG9uZQBwb3J0AHMAdgBtAGlwVGV4dABtYXNrVGV4dABpcABiaXRzAG1hc2sAY291bnQAYQBiAG5hbWUAcXR5cGUAc2VydmVyAHcAcABwb3MAdXJsAGgAdABjYXAAbGluZXMAc3RlcHMAcmF3cwBib2R5AHRhZwBmaWxlAGRpc2FibGVkAHNvdXJjZQBoV25kAGZzTW9kaWZpZXJzAHN0AG1zZwB3UGFyYW0AbFBhcmFtAGwAeDEAeTEAeDIAeTIAaFJnbgByZWRyYXcAdGFicwBkZWx0YQBvZmYAZHkAZQBmaXJzdAB0b3RhbABzZW5kZXIAaWR4AGNvbnRlbnRIAHRvcEgAdG9wAHBhcmVudABwcmltYXJ5AGZuAG93bmVyAGkAY2IAdGlkAG5Db2RlAG9iamVjdABtZXRob2QAY2FsbGJhY2sAcmVzdWx0AFN5c3RlbS5SdW50aW1lLkNvbXBpbGVyU2VydmljZXMAQ29tcGlsYXRpb25SZWxheGF0aW9uc0F0dHJpYnV0ZQBSdW50aW1lQ29tcGF0aWJpbGl0eUF0dHJpYnV0ZQB3Z3RyYXlfbmV3AGdldF9YAGdldF9ZAEFkZEFyYwBnZXRfUmlnaHQAZ2V0X0JvdHRvbQBDbG9zZUZpZ3VyZQBCaXRtYXAAR3JhcGhpY3MASW1hZ2UARnJvbUltYWdlAFNtb290aGluZ01vZGUAc2V0X1Ntb290aGluZ01vZGUAZ2V0X1RyYW5zcGFyZW50AENsZWFyAFNvbGlkQnJ1c2gAQnJ1c2gARmlsbFBhdGgASURpc3Bvc2FibGUARGlzcG9zZQBHcmFwaGljc1VuaXQAU3RyaW5nRm9ybWF0AFN0cmluZ0FsaWdubWVudABzZXRfQWxpZ25tZW50AHNldF9MaW5lQWxpZ25tZW50AEZvbnRGYW1pbHkAZ2V0X0ZvbnRGYW1pbHkAQWRkU3RyaW5nAENvbXBvc2l0aW5nTW9kZQBzZXRfQ29tcG9zaXRpbmdNb2RlAEdldEhpY29uAEZyb21IYW5kbGUAU2hvd0JhbGxvb25UaXAAZ2V0X0lzRGlzcG9zZWQAZ2V0X0hhbmRsZQBTdHJpbmcASXNOdWxsT3JXaGl0ZVNwYWNlAFRvTG93ZXIAQ2hhcgBTcGxpdABUcmltAG9wX0VxdWFsaXR5AGdldF9MZW5ndGgAZ2V0X0NoYXJzAEFycmF5AEluZGV4T2YAPFByaXZhdGVJbXBsZW1lbnRhdGlvbkRldGFpbHM+ezA0OEQ4NTc2LUMyRDQtNDM2OC1BMTJBLTg4OEQxRTcwMzAxNH0AQ29tcGlsZXJHZW5lcmF0ZWRBdHRyaWJ1dGUAJCRtZXRob2QweDYwMDAwMDYtMQBBZGQAVHJ5R2V0VmFsdWUAQXBwZW5kAFVJbnQzMgBfX1N0YXRpY0FycmF5SW5pdFR5cGVTaXplPTk2ACQkbWV0aG9kMHg2MDAwMDA3LTEAUnVudGltZUhlbHBlcnMAUnVudGltZUZpZWxkSGFuZGxlAEluaXRpYWxpemVBcnJheQBUb1N0cmluZwBDb25jYXQAZ2V0X0lzSGFuZGxlQ3JlYXRlZABDdXJzb3IAUG9pbnQAZ2V0X1Bvc2l0aW9uAFRvb2xTdHJpcERyb3BEb3duAFNob3cARW52aXJvbm1lbnQAU3BlY2lhbEZvbGRlcgBHZXRGb2xkZXJQYXRoAFBhdGgAQ29tYmluZQBGaWxlAEV4aXN0cwBEZWxldGUAVHlwZQBHZXRUeXBlRnJvbVByb2dJRABBY3RpdmF0b3IAQ3JlYXRlSW5zdGFuY2UAQmluZGluZ0ZsYWdzAEJpbmRlcgBJbnZva2VNZW1iZXIAR2V0VHlwZQBFeGNlcHRpb24AZ2V0X01lc3NhZ2UAc2V0X0l0ZW0AZ2V0X1VURjgAUmVhZEFsbExpbmVzAFN1YnN0cmluZwBTeXN0ZW0uVGV4dC5SZWd1bGFyRXhwcmVzc2lvbnMAUmVnZXgATWF0Y2gAR3JvdXAAZ2V0X1N1Y2Nlc3MAR3JvdXBDb2xsZWN0aW9uAGdldF9Hcm91cHMAZ2V0X0l0ZW0AQ2FwdHVyZQBnZXRfVmFsdWUARXhwYW5kRW52aXJvbm1lbnRWYXJpYWJsZXMAVVRGOEVuY29kaW5nAFdyaXRlQWxsVGV4dABzZXRfRmlsZU5hbWUAc2V0X1VzZVNoZWxsRXhlY3V0ZQBQcm9jZXNzAFN0YXJ0ADxCdWlsZE1lbnU+Yl9fMwBwYXJhbTAAcGFyYW0xADxCdWlsZE1lbnU+Yl9fNAA8QnVpbGRNZW51PmJfXzUAPEJ1aWxkTWVudT5iX182ADxCdWlsZE1lbnU+Yl9fNwA8QnVpbGRNZW51PmJfXzgAPEJ1aWxkTWVudT5iX185ADxCdWlsZE1lbnU+Yl9fYQA8QnVpbGRNZW51PmJfX2IAPEJ1aWxkTWVudT5iX19jADxCdWlsZE1lbnU+Yl9fZABFdmVudEhhbmRsZXIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZWYAU3lzdGVtLkNvbXBvbmVudE1vZGVsAENhbmNlbEV2ZW50QXJncwA8QnVpbGRNZW51PmJfX2UAQXBwbGljYXRpb24ARXhpdABUb29sU3RyaXAAVG9vbFN0cmlwSXRlbUNvbGxlY3Rpb24AZ2V0X0l0ZW1zAFRvb2xTdHJpcEl0ZW0AVG9vbFN0cmlwU2VwYXJhdG9yAFRvb2xTdHJpcERyb3BEb3duSXRlbQBnZXRfRHJvcERvd25JdGVtcwBhZGRfQ2xpY2sAc2V0X0VuYWJsZWQAQ2FuY2VsRXZlbnRIYW5kbGVyAGFkZF9PcGVuaW5nAHNldF9Db250ZXh0TWVudVN0cmlwAHNldF9DaGVja2VkAHNldF9UZXh0ADw+Y19fRGlzcGxheUNsYXNzMTUAPD40X190aGlzADxSZWJ1aWxkVHJheU1lbnU+Yl9fMTIAPD5jX19EaXNwbGF5Q2xhc3MxNwA8UmVidWlsZFRyYXlNZW51PmJfXzE0ADxSZWJ1aWxkVHJheU1lbnU+Yl9fMTMARW51bWVyYXRvcgBHZXRFbnVtZXJhdG9yAEtleVZhbHVlUGFpcmAyAGdldF9DdXJyZW50AFN0YXJ0c1dpdGgAZ2V0X0tleQBNb3ZlTmV4dAA8PmNfX0Rpc3BsYXlDbGFzczFhAGFwcAA8UnVuPmJfXzE5AHNldF9WaXNpYmxlAERpcmVjdG9yeQBEaXJlY3RvcnlJbmZvAENyZWF0ZURpcmVjdG9yeQBNdXRleABNZXNzYWdlQm94AERpYWxvZ1Jlc3VsdABGcm9tQXJnYgBzZXRfSWNvbgBhZGRfQXBwbGljYXRpb25FeGl0AFJlYWRBbGxUZXh0AENvbnRhaW5zAFRyaW1TdGFydABJc1BhdGhSb290ZWQAc2V0X0FyZ3VtZW50cwBJc1doaXRlU3BhY2UASm9pbgBJbnNlcnQARW5kc1dpdGgASW50MzIAVHJ5UGFyc2UAZ2V0X0NvdW50AFRvQXJyYXkAUmVwbGFjZQBUb1VwcGVyAFJlZ2lzdHJ5AEN1cnJlbnRVc2VyAExvY2FsTWFjaGluZQBDbGFzc2VzUm9vdABVc2VycwBDdXJyZW50Q29uZmlnADw+Y19fRGlzcGxheUNsYXNzMjMAb3V0cABEYXRhUmVjZWl2ZWRFdmVudEFyZ3MAPFJ1bkhpZGRlbj5iX18yMQA8UnVuSGlkZGVuPmJfXzIyAGUyAGdldF9EYXRhAEFwcGVuZExpbmUAc2V0X0NyZWF0ZU5vV2luZG93AHNldF9SZWRpcmVjdFN0YW5kYXJkT3V0cHV0AHNldF9SZWRpcmVjdFN0YW5kYXJkRXJyb3IAZ2V0X1N0YW5kYXJkT3V0cHV0RW5jb2RpbmcAZ2V0X0RlZmF1bHQAc2V0X1N0YW5kYXJkT3V0cHV0RW5jb2RpbmcAc2V0X1N0YW5kYXJkRXJyb3JFbmNvZGluZwBEYXRhUmVjZWl2ZWRFdmVudEhhbmRsZXIAYWRkX091dHB1dERhdGFSZWNlaXZlZABhZGRfRXJyb3JEYXRhUmVjZWl2ZWQAQmVnaW5PdXRwdXRSZWFkTGluZQBCZWdpbkVycm9yUmVhZExpbmUAV2FpdEZvckV4aXQAZ2V0X0V4aXRDb2RlAEdldFRlbXBQYXRoAEd1aWQATmV3R3VpZAA8PmNfX0Rpc3BsYXlDbGFzczJiAE1lc3NhZ2VCb3hCdXR0b25zAGJ0bnMATWVzc2FnZUJveERlZmF1bHRCdXR0b24AZGVmADxFeGVjVG9vbFN0ZXA+Yl9fMmEATWVzc2FnZUJveEljb24ARnVuY2AxAERlbGVnYXRlAFBhcnNlAFNsZWVwAEdldFByb2Nlc3Nlc0J5TmFtZQBLaWxsAEludDY0AEJ5dGUAQ29udmVydABUb0J5dGUAQ3JlYXRlU3ViS2V5AFJlZ2lzdHJ5VmFsdWVLaW5kAFNldFZhbHVlAE9wZW5TdWJLZXkARGVsZXRlVmFsdWUARGVsZXRlU3ViS2V5VHJlZQBUcmltRW5kAEdldERpcmVjdG9yeU5hbWUAR2V0RmlsZU5hbWUAR2V0RmlsZXMAR2V0RGlyZWN0b3JpZXMAQWN0aXZhdGUAU3lzdGVtLk5ldC5OZXR3b3JrSW5mb3JtYXRpb24AUGluZwBQaW5nUmVwbHkAU2VuZABJUFN0YXR1cwBnZXRfU3RhdHVzAFN5c3RlbS5OZXQASVBBZGRyZXNzAGdldF9BZGRyZXNzAGdldF9Sb3VuZHRyaXBUaW1lAFBpbmdPcHRpb25zAGdldF9PcHRpb25zAGdldF9UdGwAZ2V0X0J1ZmZlcgBGb3JtYXQAU3RvcHdhdGNoAFN0YXJ0TmV3AFN5c3RlbS5OZXQuU29ja2V0cwBUY3BDbGllbnQAQmVnaW5Db25uZWN0AFdhaXRIYW5kbGUAZ2V0X0FzeW5jV2FpdEhhbmRsZQBXYWl0T25lAEVuZENvbm5lY3QAZ2V0X0VsYXBzZWRNaWxsaXNlY29uZHMATWVtYmVySW5mbwBnZXRfTmFtZQBHZXRBZGRyZXNzQnl0ZXMAUGFkTGVmdABNYXRoAE1pbgBfX1N0YXRpY0FycmF5SW5pdFR5cGVTaXplPTU2ACQkbWV0aG9kMHg2MDAwMDMxLTEAUGFkUmlnaHQARG5zAEdldEhvc3ROYW1lAE5ldHdvcmtJbnRlcmZhY2UAR2V0QWxsTmV0d29ya0ludGVyZmFjZXMAT3BlcmF0aW9uYWxTdGF0dXMAZ2V0X09wZXJhdGlvbmFsU3RhdHVzAE5ldHdvcmtJbnRlcmZhY2VUeXBlAGdldF9OZXR3b3JrSW50ZXJmYWNlVHlwZQBJUEludGVyZmFjZVByb3BlcnRpZXMAR2V0SVBQcm9wZXJ0aWVzAFVuaWNhc3RJUEFkZHJlc3NJbmZvcm1hdGlvbkNvbGxlY3Rpb24AZ2V0X1VuaWNhc3RBZGRyZXNzZXMASUVudW1lcmF0b3JgMQBVbmljYXN0SVBBZGRyZXNzSW5mb3JtYXRpb24ASVBBZGRyZXNzSW5mb3JtYXRpb24AQWRkcmVzc0ZhbWlseQBnZXRfQWRkcmVzc0ZhbWlseQBnZXRfSVB2NE1hc2sAU3lzdGVtLkNvbGxlY3Rpb25zAElFbnVtZXJhdG9yAEdhdGV3YXlJUEFkZHJlc3NJbmZvcm1hdGlvbkNvbGxlY3Rpb24AZ2V0X0dhdGV3YXlBZGRyZXNzZXMAR2F0ZXdheUlQQWRkcmVzc0luZm9ybWF0aW9uAElQQWRkcmVzc0NvbGxlY3Rpb24AZ2V0X0Ruc0FkZHJlc3NlcwAkJG1ldGhvZDB4NjAwMDAzMy0xAFJhbmRvbQBOZXh0AE1lbW9yeVN0cmVhbQBTdHJlYW0AZ2V0X0FTQ0lJAEdldEJ5dGVzAFdyaXRlAFVkcENsaWVudABTb2NrZXQAZ2V0X0NsaWVudABzZXRfUmVjZWl2ZVRpbWVvdXQAQW55AElQRW5kUG9pbnQAUmVjZWl2ZQBDb3B5AEdldFN0cmluZwBXZWJSZXF1ZXN0AENyZWF0ZQBIdHRwV2ViUmVxdWVzdABzZXRfVGltZW91dABzZXRfUmVhZFdyaXRlVGltZW91dABzZXRfVXNlckFnZW50AFdlYlJlc3BvbnNlAEdldFJlc3BvbnNlAEh0dHBXZWJSZXNwb25zZQBVcmkAZ2V0X1Jlc3BvbnNlVXJpAG9wX0luZXF1YWxpdHkAZ2V0X0hvc3QASHR0cFN0YXR1c0NvZGUAZ2V0X1N0YXR1c0NvZGUAZ2V0X1N0YXR1c0Rlc2NyaXB0aW9uAFdlYkhlYWRlckNvbGxlY3Rpb24AZ2V0X0hlYWRlcnMAU3lzdGVtLkNvbGxlY3Rpb25zLlNwZWNpYWxpemVkAE5hbWVWYWx1ZUNvbGxlY3Rpb24AZ2V0X0NvbnRlbnRUeXBlAEdldFJlc3BvbnNlU3RyZWFtAFJlYWQAV2ViRXhjZXB0aW9uAGdldF9SZXNwb25zZQBTdHJlYW1SZWFkZXIAVGV4dFJlYWRlcgBSZWFkVG9FbmQASXNOdWxsT3JFbXB0eQBSZW1vdmUAUmVtb3ZlQXQAZ2V0X1IAZ2V0X0cAZ2V0X0IATWF4AFJvdW5kAFJlZ2V4T3B0aW9ucwBXcml0ZUFsbExpbmVzADw+Y19fRGlzcGxheUNsYXNzMzAAPD5jX19EaXNwbGF5Q2xhc3MzMwA8UnVuUGx1Z2luPmJfXzJlAENTJDw+OF9fbG9jYWxzMzEAZXJycwBhYm9ydGVkADxSdW5QbHVnaW4+Yl9fMmYAQWN0aW9uAHNldF9Jc0JhY2tncm91bmQAQXNzZW1ibHlOYW1lAExvYWQAZ2V0X0xvY2F0aW9uAE1pY3Jvc29mdC5DU2hhcnAAQ1NoYXJwQ29kZVByb3ZpZGVyAFN5c3RlbS5Db2RlRG9tLkNvbXBpbGVyAENvbXBpbGVyUGFyYW1ldGVycwBzZXRfR2VuZXJhdGVJbk1lbW9yeQBzZXRfR2VuZXJhdGVFeGVjdXRhYmxlAFN0cmluZ0NvbGxlY3Rpb24AZ2V0X1JlZmVyZW5jZWRBc3NlbWJsaWVzAEFkZFJhbmdlAENvZGVEb21Qcm92aWRlcgBDb21waWxlclJlc3VsdHMAQ29tcGlsZUFzc2VtYmx5RnJvbVNvdXJjZQBDb21waWxlckVycm9yQ29sbGVjdGlvbgBnZXRfRXJyb3JzAGdldF9IYXNFcnJvcnMAQ29sbGVjdGlvbkJhc2UAQ29tcGlsZXJFcnJvcgBnZXRfTGluZQBnZXRfRXJyb3JUZXh0AGdldF9Db21waWxlZEFzc2VtYmx5AEdldFR5cGVzAEVtcHR5VHlwZXMAUGFyYW1ldGVyTW9kaWZpZXIAR2V0TWV0aG9kAGdldF9SZXR1cm5UeXBlAFZvaWQAUnVudGltZVR5cGVIYW5kbGUAR2V0VHlwZUZyb21IYW5kbGUAPD5jX19EaXNwbGF5Q2xhc3MzOABwYwA8UnVuQ29kZVBsdWdpbj5iX18zNgBNZXRob2RCYXNlAEdldEJhc2VFeGNlcHRpb24APEVuc3VyZVBsdWdpblRocmVhZD5iX18zYQBDUyQ8PjlfX0NhY2hlZEFub255bW91c01ldGhvZERlbGVnYXRlM2IAQXBhcnRtZW50U3RhdGUAU2V0QXBhcnRtZW50U3RhdGUAc2V0X05hbWUALmNjdG9yAFN5c3RlbS5HbG9iYWxpemF0aW9uAEN1bHR1cmVJbmZvAGdldF9DdXJyZW50VUlDdWx0dXJlAERsbEltcG9ydEF0dHJpYnV0ZQB1c2VyMzIuZGxsAENvbnRhaW5zS2V5AGdldF9Nc2cAZ2V0X1dQYXJhbQBJbnRQdHIAVG9JbnQzMgA8PmNfX0Rpc3BsYXlDbGFzczY0ADwuY3Rvcj5iX180ZQA8PmNfX0Rpc3BsYXlDbGFzczY2AENTJDw+OF9fbG9jYWxzNjUAcmcAY2xvc2UAY2FyZAA8LmN0b3I+Yl9fNDQAPC5jdG9yPmJfXzQ1ADwuY3Rvcj5iX180NwA8LmN0b3I+Yl9fNDgAPC5jdG9yPmJfXzRhADwuY3Rvcj5iX180YwA8LmN0b3I+Yl9fNTQAY2FwMgA8LmN0b3I+Yl9fNDMAPC5jdG9yPmJfXzQ2ADwuY3Rvcj5iX180OQA8LmN0b3I+Yl9fNGIAPC5jdG9yPmJfXzRkADwuY3Rvcj5iX180ZgA8LmN0b3I+Yl9fNTAAPC5jdG9yPmJfXzUxADwuY3Rvcj5iX181MgA8LmN0b3I+Yl9fNTMAPC5jdG9yPmJfXzU1AEtleUV2ZW50QXJncwA8LmN0b3I+Yl9fNTYAZ2V0X1dpZHRoAGdldF9IZWlnaHQARW1wdHkAZ2V0X0dyYXBoaWNzAFBlbgBEcmF3UGF0aABzZXRfQmFja0NvbG9yAGdldF9XaGl0ZQBzZXRfRm9yZUNvbG9yAENsb3NlAERyYXdMaW5lAE1vdXNlQnV0dG9ucwBnZXRfQnV0dG9uAG9wX0V4cGxpY2l0AFplcm8Ac2V0X0ZvbnQAc2V0X0xvY2F0aW9uAFNpemUAc2V0X1NpemUAQ29udHJvbENvbGxlY3Rpb24AZ2V0X0NvbnRyb2xzAEtleXMAZ2V0X0tleUNvZGUARm9ybUJvcmRlclN0eWxlAHNldF9Gb3JtQm9yZGVyU3R5bGUAQ29udGFpbmVyQ29udHJvbABBdXRvU2NhbGVNb2RlAHNldF9BdXRvU2NhbGVNb2RlAEZvcm1TdGFydFBvc2l0aW9uAHNldF9TdGFydFBvc2l0aW9uAHNldF9Ub3BNb3N0AHNldF9LZXlQcmV2aWV3AHNldF9DbGllbnRTaXplAGFkZF9IYW5kbGVDcmVhdGVkAGFkZF9SZXNpemUAUGFpbnRFdmVudEhhbmRsZXIAYWRkX1BhaW50AHNldF9BdXRvU2l6ZQBDb250ZW50QWxpZ25tZW50AHNldF9UZXh0QWxpZ24AQ3Vyc29ycwBnZXRfSGFuZABzZXRfQ3Vyc29yAGFkZF9Nb3VzZUVudGVyAGFkZF9Nb3VzZUxlYXZlAE1vdXNlRXZlbnRIYW5kbGVyAGFkZF9Nb3VzZURvd24AQWN0aW9uYDMAUGFkZGluZwBzZXRfUGFkZGluZwBEb2NrU3R5bGUAc2V0X0RvY2sAVmlldwBzZXRfVmlldwBzZXRfRnVsbFJvd1NlbGVjdABzZXRfTXVsdGlTZWxlY3QAc2V0X0hpZGVTZWxlY3Rpb24AQm9yZGVyU3R5bGUAc2V0X0JvcmRlclN0eWxlAENvbHVtbkhlYWRlckNvbGxlY3Rpb24AZ2V0X0NvbHVtbnMAQ29sdW1uSGVhZGVyAGFkZF9Eb3VibGVDbGljawBLZXlFdmVudEhhbmRsZXIAYWRkX0tleURvd24AQmVnaW5VcGRhdGUATGlzdFZpZXdJdGVtQ29sbGVjdGlvbgBTdHJpbmdDb21wYXJpc29uAEVxdWFscwBMaXN0Vmlld0l0ZW0ATGlzdFZpZXdTdWJJdGVtQ29sbGVjdGlvbgBnZXRfU3ViSXRlbXMATGlzdFZpZXdTdWJJdGVtAHNldF9UYWcAZ2V0X0dyYXkARW5kVXBkYXRlAElXaW4zMldpbmRvdwBTZWxlY3RlZExpc3RWaWV3SXRlbUNvbGxlY3Rpb24AZ2V0X1NlbGVjdGVkSXRlbXMAZ2V0X1RhZwBEYXRlVGltZQBnZXRfTm93AGdldF9HZW5lcmljU2Fuc1NlcmlmAGdkaTMyLmRsbAA8PmNfX0Rpc3BsYXlDbGFzczhmAHRhYkJ0bnMAPC5jdG9yPmJfXzc4ADwuY3Rvcj5iX183OQA8LmN0b3I+Yl9fN2IAPC5jdG9yPmJfXzdjADwuY3Rvcj5iX183ZQA8PmNfX0Rpc3BsYXlDbGFzczkxAENTJDw+OF9fbG9jYWxzOTAAPC5jdG9yPmJfXzgwADwuY3Rvcj5iX183NwA8LmN0b3I+Yl9fN2EAPC5jdG9yPmJfXzdkADwuY3Rvcj5iX183ZgA8LmN0b3I+Yl9fODEAczIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZThhADwuY3Rvcj5iX184MgA8LmN0b3I+Yl9fODMAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZThjADwuY3Rvcj5iX184NAA8LmN0b3I+Yl9fODUASW52YWxpZGF0ZQBzZXRfQ2FwdHVyZQBSZW1vdmVNZXNzYWdlRmlsdGVyAHNldF9XaWR0aABhZGRfTW91c2VNb3ZlAGFkZF9Nb3VzZVVwAFRleHRCb3hCYXNlAHNldF9NdWx0aWxpbmUAc2V0X1JlYWRPbmx5AFNjcm9sbEJhcnMAc2V0X1Njcm9sbEJhcnMAQWRkTWVzc2FnZUZpbHRlcgBGb3JtQ2xvc2VkRXZlbnRIYW5kbGVyAGFkZF9Gb3JtQ2xvc2VkAFBvaW50VG9DbGllbnQAZ2V0X1Zpc2libGUAZ2V0X0JvdW5kcwBTeXN0ZW0uV2luZG93cy5Gb3Jtcy5MYXlvdXQAQXJyYW5nZWRFbGVtZW50Q29sbGVjdGlvbgBnZXRfVG9wAHNldF9Ub3AAZ2V0X0ZvbnQAVGV4dFJlbmRlcmVyAE1lYXN1cmVUZXh0AGdldF9DbGllbnRTaXplADw+Y19fRGlzcGxheUNsYXNzOTUAPExvZz5iX185MwBnZXRfSW52b2tlUmVxdWlyZWQAQXBwZW5kVGV4dAA8PmNfX0Rpc3BsYXlDbGFzczk5AGJ0bgA8UnVuQWN0aW9uPmJfXzk3ADxSdW5BY3Rpb24+Yl9fOTgAc2V0X0RvdWJsZUJ1ZmZlcmVkAFRvSW50NjQAZ2V0X1BhcmVudABnZXRfQmFja0NvbG9yAGdldF9DbGllbnRSZWN0YW5nbGUARmlsbFJlY3RhbmdsZQBnZXRfRW5hYmxlZABnZXRfVGV4dABEcmF3U3RyaW5nADw+Y19fRGlzcGxheUNsYXNzYjIAPC5jdG9yPmJfX2EzADwuY3Rvcj5iX19hNAA8LmN0b3I+Yl9fYTYAPC5jdG9yPmJfX2E3ADwuY3Rvcj5iX19hOQA8PmNfX0Rpc3BsYXlDbGFzc2I0AENTJDw+OF9fbG9jYWxzYjMAPC5jdG9yPmJfX2FiADwuY3Rvcj5iX19hMgA8LmN0b3I+Yl9fYTUAPC5jdG9yPmJfX2E4ADwuY3Rvcj5iX19hYQA8LmN0b3I+Yl9fYWMAPD5jX19EaXNwbGF5Q2xhc3NjMAA8PmNfX0Rpc3BsYXlDbGFzc2MyAGNudABjYW5jZWwAPEJ1aWxkUGluZ1RhYj5iX19iYQA8QnVpbGRQaW5nVGFiPmJfX2JkADxCdWlsZFBpbmdUYWI+Yl9fYmUAPEJ1aWxkUGluZ1RhYj5iX19iZgBDUyQ8PjhfX2xvY2Fsc2MxAHN6ADxCdWlsZFBpbmdUYWI+Yl9fYmIAPEJ1aWxkUGluZ1RhYj5iX19iYwBEb3VibGUAQm9vbGVhbgA8PmNfX0Rpc3BsYXlDbGFzc2NhADxCdWlsZFRyYWNlcnRUYWI+Yl9fYzUAPEJ1aWxkVHJhY2VydFRhYj5iX19jOAA8QnVpbGRUcmFjZXJ0VGFiPmJfX2M5ADxCdWlsZFRyYWNlcnRUYWI+Yl9fYzYAPEJ1aWxkVHJhY2VydFRhYj5iX19jNwA8PmNfX0Rpc3BsYXlDbGFzc2Q0ADw+Y19fRGlzcGxheUNsYXNzZDgAdHlwZXMAdG9nZ2xlcwA8QnVpbGREbnNUYWI+Yl9fY2YAPEJ1aWxkRG5zVGFiPmJfX2QyADxCdWlsZERuc1RhYj5iX19kMwBDUyQ8PjhfX2xvY2Fsc2Q1AG5tAHN2AHRwADxCdWlsZERuc1RhYj5iX19kMAA8QnVpbGREbnNUYWI+Yl9fZDEAPD5jX19EaXNwbGF5Q2xhc3NkNgB0aQA8QnVpbGREbnNUYWI+Yl9fY2UAPD5jX19EaXNwbGF5Q2xhc3NlMgA8PmNfX0Rpc3BsYXlDbGFzc2U0AGdvADxCdWlsZEh0dHBUYWI+Yl9fZGIAPEJ1aWxkSHR0cFRhYj5iX19kZQA8QnVpbGRIdHRwVGFiPmJfX2RmADxCdWlsZEh0dHBUYWI+Yl9fZTAAPEJ1aWxkSHR0cFRhYj5iX19lMQBDUyQ8PjhfX2xvY2Fsc2UzAHUAPEJ1aWxkSHR0cFRhYj5iX19kYwA8QnVpbGRIdHRwVGFiPmJfX2RkAHNldF9TdXBwcmVzc0tleVByZXNzADw+Y19fRGlzcGxheUNsYXNzZWYAPD5jX19EaXNwbGF5Q2xhc3NmMQA8PmNfX0Rpc3BsYXlDbGFzc2Y0AHNjYW4APEJ1aWxkUG9ydFRhYj5iX19lNwA8QnVpbGRQb3J0VGFiPmJfX2VhADxCdWlsZFBvcnRUYWI+Yl9fZWQAPEJ1aWxkUG9ydFRhYj5iX19lZQBDUyQ8PjhfX2xvY2Fsc2YwADxCdWlsZFBvcnRUYWI+Yl9fZTgAPEJ1aWxkUG9ydFRhYj5iX19lOQBwb3J0cwA8QnVpbGRQb3J0VGFiPmJfX2ViADxCdWlsZFBvcnRUYWI+Yl9fZWMAX19TdGF0aWNBcnJheUluaXRUeXBlU2l6ZT01MgAkJG1ldGhvZDB4NjAwMDE1MS0xADw+Y19fRGlzcGxheUNsYXNzMTAwAG1rAGlwMQBpcDIAPEJ1aWxkU3VibmV0VGFiPmJfX2ZjADxCdWlsZFN1Ym5ldFRhYj5iX19mZAA8QnVpbGRTdWJuZXRUYWI+Yl9fZmUAPEJ1aWxkU3VibmV0VGFiPmJfX2ZmAGFkZF9UZXh0Q2hhbmdlZAA8PmNfX0Rpc3BsYXlDbGFzczEwNwA8PmNfX0Rpc3BsYXlDbGFzczEwYQByZWZyZXNoADxCdWlsZExvY2FsVGFiPmJfXzEwMgA8QnVpbGRMb2NhbFRhYj5iX18xMDUAPEJ1aWxkTG9jYWxUYWI+Yl9fMTA2ADxCdWlsZExvY2FsVGFiPmJfXzEwMwBDUyQ8PjhfX2xvY2FsczEwOABpbmZvADxCdWlsZExvY2FsVGFiPmJfXzEwNABDbGlwYm9hcmQAU2V0VGV4dAA8LmN0b3I+Yl9fMTBlADwuY3Rvcj5iX18xMGYAPC5jdG9yPmJfXzExMABGb2N1cwBnZXRfSUJlYW0AYWRkX0VudGVyAGFkZF9MZWF2ZQBnZXRfRm9jdXNlZAA8LmN0b3I+Yl9fMTE3ADwuY3Rvcj5iX18xMTgAPC5jdG9yPmJfXzExOQA8LmN0b3I+Yl9fMTFhADwuY3Rvcj5iX18xMWIAPC5jdG9yPmJfXzExYwBTdG9wAENvbXBvbmVudABzZXRfSW50ZXJ2YWwAYWRkX1RpY2sAYWRkX0Rpc3Bvc2VkADw+Y19fRGlzcGxheUNsYXNzMTI1ADxMaW5lPmJfXzEyMwBTYXZlRmlsZURpYWxvZwBGaWxlRGlhbG9nAHNldF9GaWx0ZXIAQ29tbW9uRGlhbG9nAFNob3dEaWFsb2cAZ2V0X0ZpbGVOYW1lADwuY3Rvcj5iX18xMmQAPC5jdG9yPmJfXzEyZQA8LmN0b3I+Yl9fMTJmADwuY3Rvcj5iX18xMzAAPC5jdG9yPmJfXzEzMQBzZXRfSW50ZWdyYWxIZWlnaHQAc2V0X0hlaWdodABCdXR0b24ATGlzdENvbnRyb2wAZ2V0X1NlbGVjdGVkSW5kZXgAT2JqZWN0Q29sbGVjdGlvbgBHZXRUZXh0ADw+Y19fRGlzcGxheUNsYXNzMTVhADwuY3Rvcj5iX18xNDMAPC5jdG9yPmJfXzE0NAA8LmN0b3I+Yl9fMTQ1ADwuY3Rvcj5iX18xNDYAPD5jX19EaXNwbGF5Q2xhc3MxNWMAQ1MkPD44X19sb2NhbHMxNWIAY2kAPC5jdG9yPmJfXzE0OAA8LmN0b3I+Yl9fMTQ5ADwuY3Rvcj5iX18xNDIAPC5jdG9yPmJfXzE0NwA8LmN0b3I+Yl9fMTRhADwuY3Rvcj5iX18xNGIAPC5jdG9yPmJfXzE0YwA8LmN0b3I+Yl9fMTRkADwuY3Rvcj5iX18xNGUARm9ybUNsb3NpbmdFdmVudEFyZ3MAPC5jdG9yPmJfXzE0ZgA8LmN0b3I+Yl9fMTUwAERyYXdFbGxpcHNlAEFkZEVsbGlwc2UAUmVnaW9uAHNldF9SZWdpb24ARm9ybUNsb3NpbmdFdmVudEhhbmRsZXIAYWRkX0Zvcm1DbG9zaW5nAFNvcnRlZERpY3Rpb25hcnlgMgBHZXRGaWxlTmFtZVdpdGhvdXRFeHRlbnNpb24Ac2V0X1NlbGVjdGlvblN0YXJ0AFJlYWRMaW5lADw+Y19fRGlzcGxheUNsYXNzMTYzADxSZWJ1aWxkVGFicz5iX18xNjAAPFJlYnVpbGRUYWJzPmJfXzE2MQBhZGRfTW91c2VDbGljawBNb3ZlAFN0cmluZ1RyaW1taW5nAHNldF9UcmltbWluZwBTdHJpbmdGb3JtYXRGbGFncwBzZXRfRm9ybWF0RmxhZ3MAPC5jdG9yPmJfXzE2YgA8LmN0b3I+Yl9fMTZjADwuY3Rvcj5iX18xNmQAPC5jdG9yPmJfXzE2ZQBNYXJzaGFsAFB0clRvU3RydWN0dXJlAENvcHlGcm9tU2NyZWVuAEdldFBpeGVsAFN0cnVjdExheW91dEF0dHJpYnV0ZQBMYXlvdXRLaW5kAAAAJU0AaQBjAHIAbwBzAG8AZgB0ACAAWQBhAEgAZQBpACAAVQBJAAAJYwB0AHIAbAAAD2MAbwBuAHQAcgBvAGwAAAdhAGwAdAAAC3MAaABpAGYAdAAAB3cAaQBuAAAHYwBtAGQAAAltAGUAdABhAAAFZgAxAAAFZgAyAAAFZgAzAAAFZgA0AAAFZgA1AAAFZgA2AAAFZgA3AAAFZgA4AAAFZgA5AAAHZgAxADAAAAdmADEAMQAAB2YAMQAyAAALcwBwAGEAYwBlAAALZQBuAHQAZQByAAAHZQBzAGMAABNiAGEAYwBrAHMAcABhAGMAZQAAB3QAYQBiAAALZwByAGEAdgBlAAALbQBpAG4AdQBzAAAJcABsAHUAcwAAEWwAYgByAGEAYwBrAGUAdAAAEXIAYgByAGEAYwBrAGUAdAAAE3MAZQBtAGkAYwBvAGwAbwBuAAALcQB1AG8AdABlAAALYwBvAG0AbQBhAAANcABlAHIAaQBvAGQAAAtzAGwAYQBzAGgAABNiAGEAYwBrAHMAbABhAHMAaAAACXAAZwB1AHAAAAlwAGcAZABuAAAJaABvAG0AZQAAB2UAbgBkAAAJbABlAGYAdAAAC3IAaQBnAGgAdAAABXUAcAAACWQAbwB3AG4AAAsoACpnvotufykAAQ0oAG4AbwBuAGUAKQAAC0MAdAByAGwAKwAACUEAbAB0ACsAAA1TAGgAaQBmAHQAKwAACVcAaQBuACsAAAtTAHAAYQBjAGUAAAtFAG4AdABlAHIAAAdFAHMAYwAAE0IAYQBjAGsAcwBwAGEAYwBlAAAHVABhAGIAAANgAAADLQABAz0AAANbAAADXQAAAzsAAAMnAAEDLAAAAy4AAAMvAAADXAAACVAAZwBVAHAAAAlQAGcARABuAAAJSABvAG0AZQAAB0UAbgBkAAAJTABlAGYAdAAAC1IAaQBnAGgAdAAABVUAcAAACUQAbwB3AG4AAAUwAHgAAANYAAANaQB0AG8AbwBsAHMAAA9wAGwAdQBnAGkAbgBzAAAVVwBnAFQAcgBhAHkALgBsAG4AawAACQBfOmfqgS9UAQ9TAHQAYQByAHQAdQBwAAAH8l1zUe2VAQdvAGYAZgAAG1cAUwBjAHIAaQBwAHQALgBTAGgAZQBsAGwAAB1DAHIAZQBhAHQAZQBTAGgAbwByAHQAYwB1AHQAABVUAGEAcgBnAGUAdABQAGEAdABoAAAhVwBvAHIAawBpAG4AZwBEAGkAcgBlAGMAdABvAHIAeQAAF0QAZQBzAGMAcgBpAHAAdABpAG8AbgAADVcAZwBUAHIAYQB5AAAJUwBhAHYAZQAAMfJdAF8vVCAAKABTAHQAYQByAHQAdQBwAFwAVwBnAFQAcgBhAHkALgBsAG4AawApAAEvbwBuACAAKABTAHQAYQByAHQAdQBwAFwAVwBnAFQAcgBhAHkALgBsAG4AawApAAANAF86Z+qBL1QxWSWNAR1TAHQAYQByAHQAdQBwACAAZgBhAGkAbABlAGQAAIPjOwAgAFcAZwBUAHIAYQB5ACAATZFuf4dl9k4gACgAVQBUAEYALQA4ACwAIAAOTiAAdwBnAHQAcgBhAHkALgBiAGEAdAAgAAxU7nZVXykADQAKADsAIABhAHAAcAA6ACAAWGLYdtyDVVMgAC0APgAgAJReKHUgAMyRhHZhZ+52LAAgABZ/AXg8AFQAQQBCAD4ADVTweTwAVABBAEIAPgB9VOROWwA8AFQAQQBCAD4AwlNwZV0AIAAoAAZSlJYme19OpWPXU3p6PGgsACAAK1R6ejxohHZ9VOROKHUVX/dTBVNPTzsADQAKADsAIAAgACAAIAAgACAA+Hb5W++NhF8JYyAAdwBnAHQAcgBhAHkALgBiAGEAdAAgAEBiKFfudlVf44mQZywAIAAvZQFjIAAlAK9zg1jYU8+RJQApAA0ACgA7ACAAYQBwAHAAIAA9ACAAbgBwAAkAsIuLTixnCQBuAG8AdABlAHAAYQBkAC4AZQB4AGUADQAKADsAIABhAHAAcAAgAD0AIABnAHkACQDTTpNe7nZVXwkAQwA6AFwAVABvAG8AbABzAFwAVwBnAEkAbQBlAA0ACgA7ACAAYQBwAHAAIAA9ACAAYgBkAAkAfnamXgkAaAB0AHQAcABzADoALwAvAHcAdwB3AC4AYgBhAGkAZAB1AC4AYwBvAG0ADQAKADsAIABoUUBc6193Yy6VIAAoADxoD186ACAAYwB0AHIAbAAvAGEAbAB0AC8AcwBoAGkAZgB0AC8AdwBpAG4AIADEfghULAAgAIJZIABjAHQAcgBsACsAYQBsAHQAKwB0ADsAIABuAG8AbgBlAC8AbwBmAGYAIACBeSh1KQA6AA0ACgA7ACAAaABvAHQAawBlAHkAXwB0AG8AbwBsAGIAbwB4ACAAPQAgAGMAdAByAGwAKwBhAGwAdAArAHQAIAAgACAAU2IAX+Vdd1Gxew0ACgA7ACAAaABvAHQAawBlAHkAXwBwAGwAdQBnAGkAbgBzACAAPQAgAGMAdAByAGwAKwBhAGwAdAArAHAAIAAgACAAU2IAX9Jj9k6hewZ0DQAKADsAIABoAG8AdABrAGUAeQBfAG0AZQBuAHUAIAAgACAAIAA9ACAAYwB0AHIAbAArAGEAbAB0ACsAdwAgACAAIAAoV0lRB2gEWT5mOnlYYth23INVUw0ACgA7ACAAKABXAGcASQBtAGUAIACEdiAAZgB1AHoAegB5AC8AcABhAHMAdABlAC8AawBlAHkAZgBpAHgAIABJe5OPZVHVbE2Rbn8sZ+Vdd1ENTn9PKHUsACAAWXVAdw1OcV/NVCkADQAKAAEH5V13UbF7AQ9UAG8AbwBsAGIAbwB4AAAbYgB1AGkAbAB0AGkAbgA6AHQAbwBvAGwAcwAAAQALdABvAG8AbABzAAAHbgBlAHQAAAlRf9x+5V13UQEbTgBlAHQAdwBvAHIAawAgAHQAbwBvAGwAcwAAIWIAdQBpAGwAdABpAG4AOgBuAGUAdAB0AG8AbwBsAHMAAAl3AGwAZwBqAAAJYwBsAGkAcAAAC2pSNI1/Z4ZT8lMBI0MAbABpAHAAYgBvAGEAcgBkACAAaABpAHMAdABvAHIAeQAAGWIAdQBpAGwAdABpAG4AOgBjAGwAaQBwAAAHagBsAGIAAAViAGoAAAW/T357ARlTAHQAaQBjAGsAeQAgAG4AbwB0AGUAcwAAGWIAdQBpAGwAdABpAG4AOgBuAG8AdABlAAALbgBvAHQAZQBzAAAFeQBzAAAJnJhygv5i1lMBGUMAbwBsAG8AcgAgAHAAaQBjAGsAZQByAAAbYgB1AGkAbAB0AGkAbgA6AGMAbwBsAG8AcgAAC2MAbwBsAG8AcgAACdJj9k6hewZ0AR1QAGwAdQBnAGkAbgAgAG0AYQBuAGEAZwBlAHIAACNiAHUAaQBsAHQAaQBuADoAcABsAHUAZwBpAG4AbQBnAHIAAAljAGoAZwBsAAAVYwB0AHIAbAArAGEAbAB0ACsAdAAAFWMAdAByAGwAKwBhAGwAdAArAHAAABVjAHQAcgBsACsAYQBsAHQAKwB3AAAVYwBvAG4AZgBpAGcALgB0AHgAdAAAB2EAcABwAABfXgAoAFwAUwArACkAXABzACsAKABcAFMAKwApAFwAcwArACgAIgAoAD8AOgBbAF4AIgBdACoAKQAiAHwAXABTACsAKQAoAD8AOgBcAHMAKwAoAC4AKgApACkAPwAkAAAdaABvAHQAawBlAHkAXwB0AG8AbwBsAGIAbwB4AAAdaABvAHQAawBlAHkAXwBwAGwAdQBnAGkAbgBzAAAXaABvAHQAawBlAHkAXwBtAGUAbgB1AAAHagBzAHEAAAljAGEAbABjAAAJ5V13UbF7JiABEVQAbwBvAGwAYgBvAHgAJiABBdJj9k4BD1AAbAB1AGcAaQBuAHMAAAmFUW5/5V13UQEdQgB1AGkAbAB0AC0AaQBuACAAdABvAG8AbABzAAEHoYuXe2hWARVDAGEAbABjAHUAbABhAHQAbwByAAAflF4odSAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAASNBAHAAcABzACAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAAAVNkW5/AQ1DAG8AbgBmAGkAZwAAJRZ/kY9NkW5/IAAoAGMAbwBuAGYAaQBnAC4AdAB4AHQAKQAmIAEzRQBkAGkAdAAgAGMAbwBuAGYAaQBnACAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAJiABCc2RfY9NkW5/ARtSAGUAbABvAGEAZAAgAGMAbwBuAGYAaQBnAAAlUwB0AGEAcgB0ACAAdwBpAHQAaAAgAFcAaQBuAGQAbwB3AHMAAAtwZW5j7nZVXyYgARlEAGEAdABhACAAZgBvAGwAZABlAHIAJiABC2hRQFzrX3djLpUBHUcAbABvAGIAYQBsACAAaABvAHQAawBlAHkAcwAASyhXIABjAG8AbgBmAGkAZwAuAHQAeAB0ACAAhHYgAGgAbwB0AGsAZQB5AF8AKgAgAC6V7k85ZSAAKABuAG8AbgBlACAAgXkodSkAAWVlAGQAaQB0ACAAaABvAHQAawBlAHkAXwAqACAAawBlAHkAcwAgAGkAbgAgAGMAbwBuAGYAaQBnAC4AdAB4AHQAIAAoAG4AbwBuAGUAIAB0AG8AIABkAGkAcwBhAGIAbABlACkAAAUAkPpRAQlFAHgAaQB0AAALU2IAX+Vdd1GxewEZTwBwAGUAbgAgAHQAbwBvAGwAYgBvAHgAAAc6ACAAIAAADT5mOnlYYth23INVUwEdUwBoAG8AdwAgAHQAcgBhAHkAIABtAGUAbgB1AAAPcABsAHUAZwBpAG4AOgAAF2MAbwBkAGUAcABsAHUAZwBpAG4AOgAAByAAIAAoAAADKQAALygA4GXSY/ZOIAAUICAAPmUgAHAAbAB1AGcAaQBuAHMAXAAqAC4AdAB4AHQAKQABQSgAbgBvACAAcABsAHUAZwBpAG4AcwAgABQgIABwAHUAdAAgAHAAbAB1AGcAaQBuAHMAXAAqAC4AdAB4AHQAKQABC9Jj9k6hewZ0JiABH1AAbAB1AGcAaQBuACAAbQBhAG4AYQBnAGUAcgAmIAERYgB1AGkAbAB0AGkAbgA6AABFKADgZSAAFCAgAGMAbwBuAGYAaQBnAC4AdAB4AHQAIADMkaBSIABhAHAAcAAgAD0AIAAWfwF4IAANVPB5IAB9VOROKQABaSgAbgBvAG4AZQAgABQgIABhAGQAZAAgACcAYQBwAHAAIAA9ACAAYwBvAGQAZQAgAG4AYQBtAGUAIABjAG8AbQBtAGEAbgBkACcAIABpAG4AIABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAAQt3AGcAaQBtAGUAAClXAGcAVAByAGEAeQBTAGkAbgBnAGwAZQBJAG4AcwB0AGEAbgBjAGUAADNXAGcAVAByAGEAeQAgAPJdKFfQj0yIIAAUICAA94tIUc5OWGLYdgCQ+lHnZZ5bi08CMAGAjVcAZwBUAHIAYQB5ACAAaQBzACAAYQBsAHIAZQBhAGQAeQAgAHIAdQBuAG4AaQBuAGcAIAAUICAAZQB4AGkAdAAgAHQAaABlACAAbwBsAGQAIABpAG4AcwB0AGEAbgBjAGUAIABmAHIAbwBtACAAdABoAGUAIAB0AHIAYQB5ACAAZgBpAHIAcwB0AC4AAQPlXQEDVAAABWAAbgAABzoALwAvAAAJL1SoUjFZJY0BG0wAYQB1AG4AYwBoACAAZgBhAGkAbABlAGQAAAU6ACAAABN0AG8AbwBsAHMALgB0AHgAdAAAAwoAAA9bAHMAaABlAGwAbABdAAALWwBjAG0AZABdAAAVcwBoAGUAbABsAGIAbABvAGMAawAAGVsAcABvAHcAZQByAHMAaABlAGwAbABdAAAJWwBwAHMAXQAAD3AAcwBiAGwAbwBjAGsAABtbAC8AcABvAHcAZQByAHMAaABlAGwAbABdAAALWwAvAHAAcwBdAAARWwBzAGgAZQBsAGwAeABdAAANWwBjAG0AZAB4AF0AABdzAGgAZQBsAGwAYgBsAG8AYwBrAHgAABtbAHAAbwB3AGUAcgBzAGgAZQBsAGwAeABdAAALWwBwAHMAeABdAAARcABzAGIAbABvAGMAawB4AAAJdABhAGIAIAAAAz8AAAtjAG8AbABzACAAAAXlXXdRAQtUAG8AbwBsAHMAAA9iAHUAdAB0AG8AbgAgAAAJSABLAEMAVQAAI0gASwBFAFkAXwBDAFUAUgBSAEUATgBUAF8AVQBTAEUAUgAACUgASwBMAE0AACVIAEsARQBZAF8ATABPAEMAQQBMAF8ATQBBAEMASABJAE4ARQAACUgASwBDAFIAACNIAEsARQBZAF8AQwBMAEEAUwBTAEUAUwBfAFIATwBPAFQAAAdIAEsAVQAAFUgASwBFAFkAXwBVAFMARQBSAFMAAAlIAEsAQwBDAAAnSABLAEUAWQBfAEMAVQBSAFIARQBOAFQAXwBDAE8ATgBGAEkARwAAFWIAYQBkACAAaABpAHYAZQA6ACAAAA8gACAAbwB1AHQAOgAgAAAPIAAgAGUAeABpAHQAIAAAFWUAeABpAHQAIABjAG8AZABlACAAABd3AGcAaQBtAGUALQB0AG8AbwBsAC0AAQNOAAADIgAAB20AcwBnAAAPYwBvAG4AZgBpAHIAbQAAC3QAaQB0AGwAZQAAD2IAdQB0AHQAbwBuAHMAAAVvAGsAABFvAGsAYwBhAG4AYwBlAGwAAA9kAGUAZgBhAHUAbAB0AAADMQAAC2EAYgBvAHIAdAAACXcAYQBpAHQAAAlrAGkAbABsAAATIAAgAGsAaQBsAGwAZQBkACAAAAcgAHgAIAAAB3IAdQBuAAALcwBoAGUAbABsAAAPYwBtAGQALgBlAHgAZQAABy8AYwAgAAAJLgBjAG0AZAAACS4AcABzADEAAB1wAG8AdwBlAHIAcwBoAGUAbABsAC4AZQB4AGUAAFMtAE4AbwBQAHIAbwBmAGkAbABlACAALQBFAHgAZQBjAHUAdABpAG8AbgBQAG8AbABpAGMAeQAgAEIAeQBwAGEAcwBzACAALQBGAGkAbABlACAAAWdbAEMAbwBuAHMAbwBsAGUAXQA6ADoATwB1AHQAcAB1AHQARQBuAGMAbwBkAGkAbgBnACAAPQAgAFsAVABlAHgAdAAuAEUAbgBjAG8AZABpAG4AZwBdADoAOgBVAFQARgA4AA0ACgAADXMAaABlAGwAbAB4AAAhDQAKAGUAYwBoAG8ALgANAAoAcABhAHUAcwBlAA0ACgAAZw0ACgBXAHIAaQB0AGUALQBIAG8AcwB0ACAAJwAnAA0ACgBSAGUAYQBkAC0ASABvAHMAdAAgACcAcAByAGUAcwBzACAARQBOAFQARQBSACAAdABvACAAYwBsAG8AcwBlACcADQAKAAEJbwBwAGUAbgAAD3IAZQBnAC0AcwBlAHQAAQMgAAALZAB3AG8AcgBkAAALcQB3AG8AcgBkAAANZQB4AHAAYQBuAGQAAAttAHUAbAB0AGkAAA1iAGkAbgBhAHIAeQAAD3IAZQBnAC0AZABlAGwAARFmAGkAbABlAC0AZABlAGwAAT9yAGUAZgB1AHMAZQAgAHQAbwAgAGQAZQBsAGUAdABlACAAYQAgAGQAcgBpAHYAZQAgAHIAbwBvAHQAOgAgAAARIAAgAHMAawBpAHAAOgAgAAAVIAAgAGQAZQBsAGUAdABlAGQAIAAAFSwAIABzAGsAaQBwAHAAZQBkACAAACUgACgAaQBuACAAdQBzAGUAIAAvACAAbABvAGMAawBlAGQAKQAAC20AawBkAGkAcgAAHXUAbgBrAG4AbwB3AG4AIAB2AGUAcgBiADoAIAAAVXQAbwBvAGwAcwAuAHQAeAB0ACAAOk56ehZiDU5YWyhXFCAUIChXIAB3AGcAaQBtAGUALgBiAGEAdAAgAAxU7nZVX/peAE4qTnNT71P7baBSn1L9gAFrdABvAG8AbABzAC4AdAB4AHQAIABtAGkAcwBzAGkAbgBnAC8AZQBtAHAAdAB5ACAALQAgAGMAcgBlAGEAdABlACAAaQB0ACAAbgBlAHgAdAAgAHQAbwAgAHcAZwBpAG0AZQAuAGIAYQB0AAFZcgBlAHAAbAB5ACAAZgByAG8AbQAgAHsAMAB9ADoAIAB0AGkAbQBlAD0AewAxAH0AbQBzACAAdAB0AGwAPQB7ADIAfQAgAGIAeQB0AGUAcwA9AHsAMwB9AAARcwB0AGEAdAB1AHMAOgAgAAAPZQByAHIAbwByADoAIAAABSAAIAAAFW0AcwAgACAAKABkAG8AbgBlACkAAAVtAHMAABMgACAAZQByAHIAbwByADoAIAAAIWMAbABvAHMAZQBkACAAKAB0AGkAbQBlAG8AdQB0ACAAAAdtAHMAKQAADW8AcABlAG4AIAAgAAARYwBsAG8AcwBlAGQAIAAoAAATSQBQAHYANAAgAG8AbgBsAHkAAAupYwF4DU7ej+1+ASduAG8AbgAtAGMAbwBuAHQAaQBnAHUAbwB1AHMAIABtAGEAcwBrAAEVYgBhAGQAIABwAHIAZQBmAGkAeAAACypnB2OaWzBXQFcBF3UAbgBzAHAAZQBjAGkAZgBpAGUAZAAAH95Wr3MwV0BXIAAoAGwAbwBvAHAAYgBhAGMAawApAAERbABvAG8AcABiAGEAYwBrAAAdwXkJZzBXQFcgACgAUgBGAEMAMQA5ADEAOAApAAEjcAByAGkAdgBhAHQAZQAgACgAUgBGAEMAMQA5ADEAOAApAAAZ/pTvjSxnMFcgACgAQQBQAEkAUABBACkAASVsAGkAbgBrAC0AbABvAGMAYQBsACAAKABBAFAASQBQAEEAKQABIdCPJYRGVad+IABOAEEAVAAgACgAQwBHAE4AQQBUACkAASNjAGEAcgByAGkAZQByAC0AZwByAGEAZABlACAATgBBAFQAAR3Efq1kIAAoAG0AdQBsAHQAaQBjAGEAcwB0ACkAARNtAHUAbAB0AGkAYwBhAHMAdAAAG91PWXUgACgAcgBlAHMAZQByAHYAZQBkACkAARFyAGUAcwBlAHIAdgBlAGQAAAlsUVF/MFdAVwENcAB1AGIAbABpAGMAAANBAAADQgAAA0MAAANEAAADRQAABaljAXgBCU0AYQBzAGsAABM6ACAAIAAgACAAIAAgACAAIAAACSAAIAAoAC8AAAcakE2RJnsBEVcAaQBsAGQAYwBhAHIAZAAACzoAIAAgACAAIAAACVF/3H4wV0BXAQ9OAGUAdAB3AG8AcgBrAAAJOgAgACAAIAAACX9erWQwV0BXARNCAHIAbwBhAGQAYwBhAHMAdAAACe9TKHUDg/RWARVIAG8AcwB0ACAAcgBhAG4AZwBlAAAHIAAtACAAAQvvUyh1O046Z3BlAQtIAG8AcwB0AHMAAA06ACAAIAAgACAAIAAACTBXQFd7fItXAQlUAHkAcABlAAAPOgAgACAAIAAgACAAIAAABXt8K1IBC0MAbABhAHMAcwAAB4xO2482UgENQgBpAG4AYQByAHkAABvGYpdfKlmOeIZOIAAoADtOOmdwZQ1Os40pAAFBdABvAG8AIABtAGEAbgB5ACAAcwB1AGIAbgBlAHQAcwAgACgAbgBvACAAaABvAHMAdABzACAAbABlAGYAdAApAAAFxmIGUgELcwBwAGwAaQB0AAAHIAA6TiAAAQ0gAGkAbgB0AG8AIAAACSAAKk4gAC8AAQkgAHgAIAAvAAADOgAAByAAIAAgAAAJIAAgACAAKAAARU1SAH8gACAAIAAgAKljAXggACAAIAAgACAAIAAgACAAIAAgACAAIAAgACAA71ModTtOOmcgACAAIAAgACAAGpBNkSZ7AVtwAHIAZQBmAGkAeAAgACAAbQBhAHMAawAgACAAIAAgACAAIAAgACAAIAAgACAAIABoAG8AcwB0AHMAIAAgACAAIAAgACAAIAAgAHcAaQBsAGQAYwBhAHIAZAAABztOOmcNVAEJSABvAHMAdAAABV0AIAAAESAAIABJAFAAdgA0ADoAIAAAByAALwAgAAAFUX9zUQEPRwBhAHQAZQB3AGEAeQAADyAAIABEAE4AUwA6ACAAAAVOAFMAAAtDAE4AQQBNAEUAAAdQAFQAUgAABU0AWAAAB1QAWABUAAAJQQBBAEEAQQAAEWIAYQBkACAAdAB5AHAAZQAAFUQATgBTACAAcgBjAG8AZABlAD0AABcgACgATgBYAEQATwBNAEEASQBOACkAAAcgAHwAIAAAC3QAeQBwAGUAIAAABSAAKAAADyAAYgB5AHQAZQBzACkAAA8gACAAIAB0AHQAbAA9AAAH4GWwi1VfARVuAG8AIAByAGUAYwBvAHIAZABzAAAbZABuAHMAIABuAGEAbQBlACAAbABvAG8AcAAAEWgAdAB0AHAAcwA6AC8ALwAAHVcAZwBJAG0AZQAtAE4AZQB0AFQAbwBvAGwAcwABDSAAIAAoAC0APgAgAAELSABUAFQAUAAgAAANUwBlAHIAdgBlAHIAABFTAGUAcgB2AGUAcgA6ACAAAB1DAG8AbgB0AGUAbgB0AC0AVAB5AHAAZQA6ACAAAQ1CAG8AZAB5ADoAIAAADSAAYgB5AHQAZQBzAAANVABUAEYAQgA6ACAAABltAHMAIAAgACAAVABvAHQAYQBsADoAIAAAC0UAcgByADoAIAAAK2gAdAB0AHAAcwA6AC8ALwBhAHAAaQAuAGkAcABpAGYAeQAuAG8AcgBnAAATbgBvAHQAZQBzAC4AdAB4AHQAAAMjAAAFWAAyAAAFSAAgAAAJIAAgAFMAIAAACyUAIAAgAFYAIAAAAyUAAAVbAC8AAAsqAC4AdAB4AHQAAEFeACgAYwBvAGQAZQB8AG4AYQBtAGUAfABkAGUAcwBjACkAXABzACoAWwA9ADoAXQBcAHMAKgAoAC4AKwApACQAAAljAG8AZABlAAAJbgBhAG0AZQAADWMAcwBoAGEAcgBwAAApcABsAHUAZwBpAG4AcwAtAGQAaQBzAGEAYgBsAGUAZAAuAHQAeAB0AAEJjFsQYiwAIAABDWQAbwBuAGUALAAgAAANIAAqTmVrpJoxWSWNAR8gAHMAdABlAHAAKABzACkAIABmAGEAaQBsAGUAZAAACWdiTIiMWxBiAQlkAG8AbgBlAAAH8l3WU4htAQ9hAGIAbwByAHQAZQBkAAALAF/LWWdiTIgmIAERcgB1AG4AbgBpAG4AZwAmIAEXVwBpAG4AZABvAHcAcwBCAGEAcwBlAAAhUAByAGUAcwBlAG4AdABhAHQAaQBvAG4AQwBvAHIAZQAAK1AAcgBlAHMAZQBuAHQAYQB0AGkAbwBuAEYAcgBhAG0AZQB3AG8AcgBrAACAhywAIABWAGUAcgBzAGkAbwBuAD0ANAAuADAALgAwAC4AMAAsACAAQwB1AGwAdAB1AHIAZQA9AG4AZQB1AHQAcgBhAGwALAAgAFAAdQBiAGwAaQBjAEsAZQB5AFQAbwBrAGUAbgA9ADMAMQBiAGYAMwA4ADUANgBhAGQAMwA2ADQAZQAzADUAAICdUwB5AHMAdABlAG0ALgBYAGEAbQBsACwAIABWAGUAcgBzAGkAbwBuAD0ANAAuADAALgAwAC4AMAAsACAAQwB1AGwAdAB1AHIAZQA9AG4AZQB1AHQAcgBhAGwALAAgAFAAdQBiAGwAaQBjAEsAZQB5AFQAbwBrAGUAbgA9AGIANwA3AGEANQBjADUANgAxADkAMwA0AGUAMAA4ADkAAAtsAGkAbgBlACAAAAU7ACAAAAdSAHUAbgAAX24AbwAgACcAcAB1AGIAbABpAGMAIABzAHQAYQB0AGkAYwAgAHYAbwBpAGQAIABSAHUAbgAoACkAJwAgAGUAbgB0AHIAeQAgAHAAbwBpAG4AdAAgAGYAbwB1AG4AZAABDdJj9k7Qj0yI+lEZlQEZUABsAHUAZwBpAG4AIABlAHIAcgBvAHIAAA3SY/ZOFn/RizFZJY0BK1AAbAB1AGcAaQBuACAAYwBvAG0AcABpAGwAZQAgAGYAYQBpAGwAZQBkAAAbVwBnAFQAcgBhAHkAUABsAHUAZwBpAG4AcwAABXoAaAAAFVMAeQBzAHQAZQBtAC4AZABsAGwAADFTAHkAcwB0AGUAbQAuAFcAaQBuAGQAbwB3AHMALgBGAG8AcgBtAHMALgBkAGwAbAAAJVMAeQBzAHQAZQBtAC4ARAByAGEAdwBpAG4AZwAuAGQAbABsAAAfUwB5AHMAdABlAG0ALgBDAG8AcgBlAC4AZABsAGwAAB9TAHkAcwB0AGUAbQAuAEQAYQB0AGEALgBkAGwAbAAAHdJj9k6hewZ0IAAgACgAVwBnAFQAcgBhAHkAKQABMVAAbAB1AGcAaQBuACAATQBhAG4AYQBnAGUAcgAgACAAKABXAGcAVAByAGEAeQApAAAdUABsAHUAZwBpAG4AIABNAGEAbgBhAGcAZQByAAADFScBBdCPTIgBBc2RfY8BDVIAZQBsAG8AYQBkAAALL1QodS8AgXkodQENTwBuAC8ATwBmAGYAAAlTYgBf7nZVXwEXTwBwAGUAbgAgAGYAbwBsAGQAZQByAAAFFn+RjwEJRQBkAGkAdAAAByBSZJYmIAEPRABlAGwAZQB0AGUAJiABC7Bl+l4han9nJiABCU4AZQB3ACYgAQUNVPB5AQlOAGEAbQBlAAAFFn8BeAEJQwBvAGQAZQAABXt8i1cBBS9UXFABC1MAdABhAHQAZQAABbZyAWABDVMAdABhAHQAdQBzAAAFh2X2TgEJRgBpAGwAZQAAFVIARQBBAEQATQBFAC4AdAB4AHQAAAVjazheAQVPAEsAAAkWf9GLMVkljQEbYwBvAG0AcABpAGwAZQAgAGUAcgByAG8AcgAACeOJkGcxWSWNARdwAGEAcgBzAGUAIABlAHIAcgBvAHIAAAUgAGVrAQ0gAHMAdABlAHAAcwAABWVrpJoBB0QAUwBMAAAFQwAjAAAFL1QodQEPZQBuAGEAYgBsAGUAZAAAB/JdgXkodQERZABpAHMAYQBiAGwAZQBkAAAR94tIUQmQLU4ATipO0mP2TgErUwBlAGwAZQBjAHQAIABhACAAcABsAHUAZwBpAG4AIABmAGkAcgBzAHQAAA8gUmSW0mP2Todl9k4gAAEnRABlAGwAZQB0AGUAIABwAGwAdQBnAGkAbgAgAGYAaQBsAGUAIAAACW4AZQB3AC0AAQ1IAEgAbQBtAHMAcwAACS4AdAB4AHQAAIDbOwAgAFcAZwBUAHIAYQB5ACAAcABsAHUAZwBpAG4AIAAoAHMAcABlAGMAOgAgAGQAbwBjAHMALwBXAEcASQBNAEUAXwDSY/ZOxIkDgy4AbQBkACkADQAKAGMAbwBkAGUAIAA9ACAAbQB5AGMAbwBkAGUADQAKAG4AYQBtAGUAIAA9ACAAEWKEdtJj9k4NAAoAZABlAHMAYwAgAD0AIAANAAoADQAKAG0AcwBnACAAaABlAGwAbABvACAAZgByAG8AbQAgAG0AeQAgAHAAbAB1AGcAaQBuAA0ACgABM1MAZQBnAG8AZQAgAFUASQAgAFYAYQByAGkAYQBiAGwAZQAgAEQAaQBzAHAAbABhAHkAABFTAGUAZwBvAGUAIABVAEkAABvlXXdRsXsgACAAKABXAGcAVAByAGEAeQApAAEjVABvAG8AbABiAG8AeAAgACAAKABXAGcAVAByAGEAeQApAAARQwBvAG4AcwBvAGwAYQBzAACA/XQAbwBvAGwAcwAuAHQAeAB0ACAAOk56ehZiDU5YWyhXAjA8aA9fOgAgAFsAdABhAGIAIAAHaH57dZhdACAALwAgAFsAYwBvAGwAcwAgABdScGVdACAALwAgAFsACWOulA1UXQAgAC8AIABla6SaTIggACgAbQBzAGcAIABjAG8AbgBmAGkAcgBtACAAcgB1AG4AIABzAGgAZQBsAGwAIABvAHAAZQBuACAAawBpAGwAbAAgAHcAYQBpAHQAIAByAGUAZwAtAHMAZQB0ACAAcgBlAGcALQBkAGUAbAAgAGYAaQBsAGUALQBkAGUAbAAgAG0AawBkAGkAcgApAAE9dABvAG8AbABzAC4AdAB4AHQAIABpAHMAIABlAG0AcAB0AHkAIABvAHIAIABtAGkAcwBzAGkAbgBnAC4AAAVBAGcAAAUNAAoAABVwAG8AdwBlAHIAcwBoAGUAbABsAAAHcABzAHgAAA9dACAAGllMiBqBLGdXVwEnXQAgAG0AdQBsAHQAaQAtAGwAaQBuAGUAIABzAGMAcgBpAHAAdAABDyAAIABbADFZJY1dACAAAQ0gACAALQA+ACAAIAABDyAAIABbAG8AawBdACAAAA8tAC0AIACMWxBiLAAgAAETLQAtACAAZABvAG4AZQAsACAAARMgACpOZWukmjFZJY0gAC0ALQABJSAAcwB0AGUAcAAoAHMAKQAgAGYAYQBpAGwAZQBkACAALQAtAAERLQAtACAAjFsQYiAALQAtAAEVLQAtACAAZABvAG4AZQAgAC0ALQABEy0ALQAgAPJd1lOIbSAALQAtAAEbLQAtACAAYQBiAG8AcgB0AGUAZAAgAC0ALQABBz0APQAgAAAHIAA9AD0AAB1Rf9x+5V13USAAIAAoAFcAZwBUAHIAYQB5ACkAAS9OAGUAdAB3AG8AcgBrACAAVABvAG8AbABzACAAIAAoAFcAZwBUAHIAYQB5ACkAABtOAGUAdAB3AG8AcgBrACAAVABvAG8AbABzAAAJUABpAG4AZwAAD1QAcgBhAGMAZQByAHQAAAdEAE4AUwAACUgAVABUAFAAAAXveuNTAQtQAG8AcgB0AHMAAAVQW1F/AQ1TAHUAYgBuAGUAdAAABSxnOmcBC0wAbwBjAGEAbAAAEUgASAA6AG0AbQA6AHMAcwAAF3IAZQBwAGwAeQA6ACAAcwBlAHEAPQAADSAAdABpAG0AZQA9AAAbdABpAG0AZQBvAHUAdAA6ACAAcwBlAHEAPQAAD99+oYs6ACAA8l3RUyAAARlzAHQAYQB0AHMAOgAgAHMAZQBuAHQAIAAACSAA8l02ZSAAAQ0gAHIAZQBjAHYAIAAACSAAIk4FUyAAAQ0gAGwAbwBzAHMAIAAABzAALgAjAAAlIAD2ZfZeIABtAGkAbgAvAGEAdgBnAC8AbQBhAHgAIAA9ACAAAScgAHIAdAB0ACAAbQBpAG4ALwBhAHYAZwAvAG0AYQB4ACAAPQAgAAAHLQAtACAAAQcgAC0ALQABES0ALQAgAHAAaQBuAGcAIAABBSAAeAAAAx4iAQ8gACAAcwBpAHoAZQA9AAAJQgAgAC0ALQABEzIAMgAzAC4ANQAuADUALgA1AAADNAAABTMAMgAABVxQYmsBCVMAdABvAHAAAAUFbmSWAQtDAGwAZQBhAHIAAAXdT1hbAVc7TjpnIAArACAAIWtwZSAAKAAwAD0AAWPtfikAIAArACAABVMnWQ9cKABXW4KCKQA7ACAACWdQliFrcGXRjYxbk4/6USAAIk4FU4dzLwD2ZfZe336hiwGAk2gAbwBzAHQAIAArACAAYwBvAHUAbgB0ACAAKAAwAD0AbABvAG8AcAApACAAKwAgAHAAYQBjAGsAZQB0ACAAYgB5AHQAZQBzADsAIABmAGkAbgBpAHQAZQAgAHIAdQBuAHMAIABlAG4AZAAgAHcAaQB0AGgAIABsAG8AcwBzAC8AcgB0AHQAIABzAHQAYQB0AHMAABctAC0AIAB0AHIAYQBjAGUAcgB0ACAAAQ0AX8tZ740xdd+NKo4BF1QAcgBhAGMAZQAgAHIAbwB1AHQAZQAADy0ALQAgAGQAbgBzACAAAQcgACAAQAAAG3cAdwB3AC4AYgBhAGkAZAB1AC4AYwBvAG0AAAXlZ+KLAQtRAHUAZQByAHkAAF+fU8tZIABEAE4AUwAgAE9TrovlZ+KLIAAoAFUARABQACAANQAzACkALAAgALCLVV97fItXuXAJkDsAIAANZ6FSaFbYnqSLP5bMkSAAMgAyADMALgA1AC4ANQAuADUAAVFyAGEAdwAgAEQATgBTACAAbwB2AGUAcgAgAFUARABQAC8ANQAzADsAIABjAGwAaQBjAGsAIABhACAAcgBlAGMAbwByAGQAIAB0AHkAcABlAAARLQAtACAAaAB0AHQAcAAgAAEraAB0AHQAcABzADoALwAvAHcAdwB3AC4AYgBhAGkAZAB1AC4AYwBvAG0AAAX3i0JsAQtGAGUAdABjAGgAAICNtnIBYAF4LwBTAGUAcgB2AGUAcgAvAEMAbwBuAHQAZQBuAHQALQBUAHkAcABlAC8AQgBvAGQAeQAgACdZD1wvAFQAVABGAEIALwA7YBeA9mU7ACAA6oGoUt+Nj5bzjWyPLAAgAOBlIABzAGMAaABlAG0AZQAgANiepIsgAGgAdAB0AHAAcwA6AC8ALwABV3MAdABhAHQAdQBzAC8AaABlAGEAZABlAHIAcwAvAHMAaQB6AGUALwBUAFQARgBCADsAIABmAG8AbABsAG8AdwBzACAAcgBlAGQAaQByAGUAYwB0AHMAABUtAC0AIABrYs9jjFsQYiAALQAtAAEfLQAtACAAcwBjAGEAbgAgAGQAbwBuAGUAIAAtAC0AAREtAC0AIABzAGMAYQBuACAAAQ0gACpOOF4ode9641MBFSAAcABvAHIAdABzACkAIAAtAC0AAQc0ADQAMwAABcBoS20BC0MAaABlAGMAawAADTheKHXveuNTa2LPYwEXUwBjAGEAbgAgAGMAbwBtAG0AbwBuAAAdLQAtACAAA4P0VmyPIABDAEkARABSACAALQAtAAEnLQAtACAAcgBhAG4AZwBlACAAdABvACAAQwBJAEQAUgAgAC0ALQABBUkAUAAAGTEAOQAyAC4AMQA2ADgALgAxAC4AMQAwAAALTVIAfy8AqWMBeAEXUAByAGUAZgBpAHgALwBNAGEAcwBrAAAFMgA0AAAHxmIGUjpOARVTAHAAbABpAHQAIABpAG4AdABvAAAHKk5QW1F/AQ9zAHUAYgBuAGUAdABzAAALUwBwAGwAaQB0AAAHH5DlZ2iIAQtUAGEAYgBsAGUAAAUDg/RWAQtSAGEAbgBnAGUAABkxADkAMgAuADEANgA4AC4AMQAuADkAOQAAA7YlAQtsUVF/IABJAFAAARNQAHUAYgBsAGkAYwAgAEkAUAAAFeVn4osxWSWNIAAoAACXVIBRfykAAS1xAHUAZQByAHkAIABmAGEAaQBsAGUAZAAgACgAbwBmAGYAbABpAG4AZQApAAAFN1KwZQEPUgBlAGYAcgBlAHMAaAAACQ1ZNlJoUeiQARFDAG8AcAB5ACAAYQBsAGwAABNsAG8AZwB8ACoALgB0AHgAdAAAD24AZQB0AGwAbwBnAC0AAR95AHkAeQB5AE0ATQBkAGQALQBIAEgAbQBtAHMAcwABH2pSNI1/Z4ZT8lMgACAAKABXAGcAVAByAGEAeQApAAE3QwBsAGkAcABiAG8AYQByAGQAIABIAGkAcwB0AG8AcgB5ACAAIAAoAFcAZwBUAHIAYQB5ACkAAAkNWTZSCZAtTgEJQwBvAHAAeQAACQVuenqGU/JTASe5cGFn7nY9AA1ZNlLeVmpSNI1/ZzsAIAAsZ5d6AF9Ad01i0XYsVAFLYwBsAGkAYwBrACAAPQAgAGMAbwBwAHkAIABiAGEAYwBrADsAIABsAGkAcwB0AGUAbgBzACAAdwBoAGkAbABlACAAbwBwAGUAbgAAAyYgAR1uAG8AdABlAC0AYwBvAGwAbwByAC4AdAB4AHQAAQ15AGUAbABsAG8AdwAAHW4AbwB0AGUAcwAtAG0AZQB0AGEALgB0AHgAdAABGb9PfnsgACAAKABXAGcAVAByAGEAeQApAAEfTgBvAHQAZQBzACAAIAAoAFcAZwBUAHIAYQB5ACkAAAtOAG8AdABlAHMAAAsxAC4AdAB4AHQAAAe/T357IAABC04AbwB0AGUAIAAAAysAAAl0AG0AcABfAAAJ8l3dT1hbIAABDXMAYQB2AGUAZAAgAAAJcABpAG4AawAADXAAdQByAHAAbABlAAAJYgBsAHUAZQAAC2cAcgBlAGUAbgAAC3cAaABpAHQAZQAAHZyYcoL+YtZTIAAgACgAVwBnAFQAcgBhAHkAKQABLUMAbwBsAG8AcgAgAFAAaQBjAGsAZQByACAAIAAoAFcAZwBUAHIAYQB5ACkAAAMUIAER/mLWUyAAKAC5cE9cVV4pAAEnUABpAGMAawAgACgAYwBsAGkAYwBrACAAcwBjAHIAZQBlAG4A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ANABAAwAAADQOgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
