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
    ToolStripMenuItem miApps, miPlugins;                            // 动态子菜单 (config 应用 / 插件), 重载配置时重建
    NotifyIcon tray;

    static void TrayTip(string title, string text, ToolTipIcon icon) { try { trayRef.ShowBalloonTip(2600, title, text, icon); } catch {} }

    // 隐藏的 UI 线程控件: 工具步骤/插件的 confirm 弹窗通过它 Invoke 回 UI 线程
    // (TrayApp 不是 Form, 不像原 WordBoard 能直接传 this)
    static Control uiInvoker;
    static Control Ui()
    {
        try { if (uiInvoker == null || uiInvoker.IsDisposed) { uiInvoker = new Control(); IntPtr h = uiInvoker.Handle; } } catch {}
        return uiInvoker;
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
        RebuildTrayMenu();
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

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L("退出", "Exit"), null, delegate { Application.Exit(); });
        tray.ContextMenuStrip = menu;
        RebuildTrayMenu();
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
            Application.ApplicationExit += delegate { app.tray.Visible = false; };
            Application.Run();
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
                    "; WgIme plugin (spec: docs/WGIME_插件规范.md)\r\n" +
                    "code = mycode\r\n" +
                    "name = 我的插件\r\n" +
                    "desc = \r\n\r\n" +
                    "msg hello from my plugin\r\n", new UTF8Encoding(false));
                Process.Start(new ProcessStartInfo { FileName = f, UseShellExecute = true });
            } catch {}
        }
    }
}
'@

# ---- load prebuilt DLL from embedded payload, in-memory compile only as fallback ----
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
'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AAoTCxELFm9SAAAKEQtvRQAACiYqAAAAARwAAAIALwCgzwAOAAAAAAIAcwG2KQIOAAAAAB4CKEkAAAoqSgJ7iQAABHsJAAAEFm9TAAAKKgAbMAUAKQEAAAgAABEfHChUAAAKckgIAHAoIwAACoACAAAEfgIAAAQoVQAACibeAybeAAKAAwAABAOABAAABCgFAAAGJhdyVAgAcBIAc1YAAAoLcxABAAYMBi0fcn4IAHBysggAcCgBAAAGckEJAHAoVwAACibdugAAAAhzRQAABn2JAAAECHuJAAAEc1gAAAp9CQAABAh7iQAABHsJAAAEck8JAHByUwkAcCgBAAAGFh94INQAAAAoWQAACigDAAAGb1oAAAoIe4kAAAR7CQAABHJBCQBwb1sAAAoIe4kAAAR7CQAABBdvUwAACgh7iQAABHsJAAAEgAUAAAQIe4kAAARvCAAABgh7iQAABG8LAAAGCP4GEQEABnNCAAAKKFwAAAooXQAACt4KBywGB28TAAAK3CoAAAABHAAAAAAWAA0jAAMBAAABAgBGANgeAQoAAAAAGzADAFIAAAAEAAARAigkAAAKLQLeRwIoJQAACiheAAAKCgZyVwkAcG9fAAAKLCkGFo0+AAABb2AAAApyXQkAcG9OAAAKLBECKAYAAAYWczgAAAooOQAACt4DJt4AKgAAARAAAAAAAABOTgADAQAAARswBACdAQAACQAAEX4LAAAELA9+CwAABAMSAG83AAAKLQEqBheacroCAHAoLgAACiwLAigaAAAG3WsBAAAGF5pyEgMAcCguAAAKLAsCKBsAAAbdUQEAAAYXmnJ4AwBwKC4AAAosCwIoNAAABt03AQAABheacsADAHAoLgAACiwLAig2AAAG3R0BAAAGF5pyEAQAcCguAAAKLAsCKDkAAAbdAwEAAAYXmnK0BgBwb04AAAosFAIGF5odby0AAAooPwAABt3gAAAABheacsQGAHBvTgAACiwVAgYXmh8Lby0AAAooQgAABt28AAAABheacnAEAHAoLgAACiwLAihEAAAG3aIAAAAGF5oLB3JhCQBwb2EAAAoWLyoHH1xvKgAAChYvCwcfL28qAAAKFjIUByhiAAAKLQx+AwAABAcoIwAACgtzOgAACg0JB287AAAKCRdvPAAACgkMBo5pGDEUBhiabygAAAoWMQkIBhiab2MA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WG8tAAAKbycAAAoTBREEclUMAHAoLgAACiwLEQcRBX2MAAAEK2URBHJhDABwKC4AAAosLBEHEQVycQwAcCguAAAKLRQRBXJ3DABwKC4AAAotAxorBBcrARZ9jQAABCsrEQRyiQwAcCguAAAKLB0RBxEFcpkMAHAoLgAACi0HIAABAAArARZ9jgAABBEsF1gTLBEsESuOaT83////HBMGBSwaBREH/gYWAQAGc5gAAApvmQAACqVWAAABEwYRB3uNAAAELQgUEyndEwcAABEGHC4MEQYXLgdynQwAcCsBFBMp3foGAAAGcqkMAHAoLgAACiwVAheaKJoAAAoomwAAChQTKd3YBgAABnKzDABwKC4AAAosexYTCAIXmiicAAAKEy0WEy4rHxEtES6aEwkRCW+dAAAKEQgXWBMI3gMm3gARLhdYEy4RLhEtjmky2QQajQEAAAETLxEvFnK9DABwohEvFxEIjFgAAAGiES8YctEMAHCiES8ZAheaohEvKJ4AAApvfwAACiYUEyndUAYAAAZy2QwAcCguAAAKLRAGcuEMAHAoLgAACjncAAAABnLZDABwKC4AAAotKXM6AAAKEw4RDnLtDABwbzsAAAoRDnL9DABwAyh8AAAKb2MAAAoRDisYczoAAAoTDRENAheaKDYAAApvOwAAChENEwoGctkMAHAoLgAACixwAo5pGDFqc4cAAAoTCxgTDCtJEQtvjgAAChYxChELHyBvnwAACiYRCwIRDJofIG8qAAAKFi8GAhEMmisTcjkMAHACEQyacjkMAHAoZQAACm+gAAAKJhEMF1gTDBEMAo5pMrARChELb48AAApvYwAAChEKBCgVAAAGEyndVwUAAAZyyQkAcCguAAAKLC4DcgUNAHBy7QwAcHL9DABwKIQAAAoUctYCAHAEFnLWAgBwKBcAAAYTKd0cBQAABnIHCgBwKC4AAAosNANyDw0AcHIZDQBwcjcNAHAXczgAAAoWczgAAApyiw0AcAQWctYCAHAoFwAABhMp3dsEAAAGcvMNAHAoLgAACiw0czoAAAoTJxEncu0MAHBvOwAAChEncv0MAHADKHwAAApvYwAAChEnBCgWAAAGEyndmgQAAAZyXwoAcCguAAAKLC4DcgUNAHBy7QwAcHL9DABwKIQAAAoUctYCAHAEF3IBDgBwKBcAAAYTKd1fBAAABnKf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AAAAAAAAAAAAAAAAAACqEAAABAAAAAAAAAAAAAAAAQDOAAAAAAAEAAAAAAAAAAAAAAABAOUAAAAAAAQAAAAAAAAAAAAAABoAXwEAAAAABAAAAAAAAAAAAAAAAQDXAAAAAAAEAAAAAAAAAAAAAAABAIQFAAAAAAMAAgAEAAIABQACAAYABQAHAAUACAAFAAkABQAKAAIACwAKAAwACgANAAoADgANAA8AAgAQAAIAEQAQABIAEAATAAIAFAATABUAEwAWABMAFwACABgAAgAZAAIAGgACABsAAgAcAAIAHQACAB8AHgAgAAIAIQAgACIAAgAjAAUAJAAFACUABQAmAAUAJwAKACgACgApAAoAKgApACsACgAsAAoALQAsAC4ACgAvAAoAMAAvADEACgAyADEAMwAxADQAHgA1AAoANgAKADcANgA4AA0AOQAQADoAEAA7ABAAPAAYAD0AGAAAAAA8TW9kdWxlPgB3Z3RyYXlfbmV3LmRsbABUcmF5QXBwAFRvb2xBY3Rpb24AVG9vbFRhYgBUb29sc0Zvcm0AVlAAU0JhcgBXaGVlbEZpbHRlcgBUQnRuAE5ldFRvb2xzRm9ybQBOQnRuAE5FZGl0AE5Mb2cAREJQAENsaXBGb3JtAE5vdGVGb3JtAE5UQ2hpcABTQlBhbmVsAENvbG9yRm9ybQBQVABNU0xMAE1vdXNlUHJvYwBQbHVnaW5Db2RlAFBsdWdpbk1nckZvcm0AbXNjb3JsaWIAU3lzdGVtAE9iamVjdABTeXN0ZW0uV2luZG93cy5Gb3JtcwBGb3JtAFBhbmVsAElNZXNzYWdlRmlsdGVyAFZhbHVlVHlwZQBNdWx0aWNhc3REZWxlZ2F0ZQBaaABMAERhdGFEaXIAQmF0RGlyAEJhdFBhdGgATm90aWZ5SWNvbgB0cmF5UmVmAFN5c3RlbS5EcmF3aW5nAFN5c3RlbS5EcmF3aW5nLkRyYXdpbmcyRABHcmFwaGljc1BhdGgAUmVjdGFuZ2xlRgBSb3VuZGVkUmVjdABJY29uAENvbG9yAE1ha2VJY29uAENvbnRleHRNZW51U3RyaXAAbWVudQBUb29sU3RyaXBNZW51SXRlbQBtaUFwcHMAbWlQbHVnaW5zAHRyYXkAVG9vbFRpcEljb24AVHJheVRpcABDb250cm9sAHVpSW52b2tlcgBVaQBTeXN0ZW0uQ29sbGVjdGlvbnMuR2VuZXJpYwBEaWN0aW9uYXJ5YDIAQXBwcwBEZWZhdWx0Q29uZmlnVGV4dABMb2FkQ29uZmlnAFJlbG9hZENvbmZpZwBPcGVuQ29uZmlnRmlsZQBPcGVuRGF0YURpcgBCdWlsZE1lbnUAUmVidWlsZFRyYXlNZW51AFJ1bgBGaXhMZWdhY3lDb25maWdJZkJyb2tlbgBMYXVuY2hBcHAATGlzdGAxAFRvb2xUYWJzAHRvb2xzRm9ybQBUb29sVG9rcwBMb2FkVG9vbHMAVG9vbFJlc3QAVG9vbFBhdGgATWljcm9zb2Z0LldpbjMyAFJlZ2lzdHJ5S2V5AFRvb2xSZWdTcGxpdABTeXN0ZW0uRGlhZ25vc3RpY3MAUHJvY2Vzc1N0YXJ0SW5mbwBTeXN0ZW0uVGV4dABTdHJpbmdCdWlsZGVyAFJ1bkhpZGRlbgBSdW5WaXNpYmxlAEVuY29kaW5nAFJ1blNjcmlwdEJsb2NrAFRvb2xEZWwARXhlY1Rvb2xTdGVwAFNob3dUb29scwBuZXRGb3JtAFNob3dOZXRUb29scwBQaW5nT25jZQBQaW5nUnR0AEhvcE9uY2UAVGVzdFBvcnQAUGFyc2VJcFY0AElwU3RyAE1hc2tUb0JpdHMAUGFyc2VJcE1hc2sASXBUeXBlAElwQ2xhc3MAU3VibmV0Q2FsYwBTdWJuZXRTcGxpdABSYW5nZVRvQ2lkcgBNYXNrVGFibGUATG9jYWxOZXRJbmZvAERuc1F1ZXJ5AFN5c3RlbS5JTwBCaW5hcnlXcml0ZXIARG5zQkUxNgBEbnNVMTYARG5zVTMyAERuc1NraXBOYW1lAERuc1JlYWROYW1lAEh0dHBDaGVjawBQdWJsaWNJcABjbGlwRm9ybQBDbGlwUHVzaABTaG93Q2xpcABub3RlRm9ybQBOb3Rlc1BhdGgAU2hvd05vdGUAY29sb3JGb3JtAENvbG9ySGV4AENvbG9ySHN2AFNob3dDb2xvcgBQbHVnaW5BY3Rpb25zAElFbnVtZXJhYmxlYDEAUGFyc2VUb29sU3RlcHMARXh0cmFjdFBsdWdpbkJsb2NrAExvYWRQbHVnaW5zAFBsdWdpbkluZm8AU3lzdGVtLkNvcmUASGFzaFNldGAxAERpc2FibGVkUGx1Z2lucwBMb2FkRGlzYWJsZWRQbHVnaW5zAFNldFBsdWdpbkRpc2FibGVkAFJ1blBsdWdpbgBQbHVnaW5Db2RlQ2FjaGUAUGx1Z2luUmVmcwBQbHVnaW5SZWZzRnVsbABDb21waWxlUGx1Z2luAFJ1bkNvZGVQbHVnaW4AU3lzdGVtLlRocmVhZGluZwBUaHJlYWQAcGx1Z2luVGhyZWFkAHBsdWdpbkludm9rZXIARW5zdXJlUGx1Z2luVGhyZWFkAHBsdWdpbk1ncgBTaG93UGx1Z2luTWdyAC5jdG9yAE5hbWUAU3RlcHMAUmF3AEFjdGlvbnMAQ29scwBUZXh0Qm94AGxvZwBwYWdlcwBsb2dXcmFwAHdoZWVsRmlsdGVyAFRDX0JHAFRDX1NVUkZBQ0UAVENfSEVBREVSAFRDX1NVUkYyAFRDX0JPUkRFUgBUQ19URVhUAFRDX1NVQgBUQ19BQ0NFTlQAVENfQ09OQkcAVENfQ09ORkcARm9udABGb250U3R5bGUAVEYAUmVjdGFuZ2xlAFRSb3VuZABUUmVsZWFzZUNhcHR1cmUAVFNlbmRNZXNzYWdlAFRTZW5kTXNnSW50AFRDcmVhdGVSb3VuZFJlY3RSZ24AVFNldFdpbmRvd1JnbgBPbldoZWVsAFNldFZwT2Zmc2V0AFNjcm9sbFZwAFBhaW50RXZlbnRBcmdzAFBhZ2VTYlBhaW50AE1vdXNlRXZlbnRBcmdzAFBhZ2VTYkRvd24AUGFnZVNiTW92ZQBMb2dTYk1ldHJpY3MASW52YWxpZGF0ZUxvZ0JhcgBMb2dTYlBhaW50AExvZ1NiRG93bgBMb2dTYk1vdmUATG9nAEV2ZW50QXJncwBSdW5BY3Rpb24ARHJhZwBEcmFnT2ZmAEhvc3QAVnAAaG9zdABNZXNzYWdlAFByZUZpbHRlck1lc3NhZ2UAQmcAQmdIb3ZlcgBCZ0Rvd24AQWNjZW50TGluZQBTZWxlY3RlZABob3ZlcgBkb3duAE9uTW91c2VFbnRlcgBPbk1vdXNlTGVhdmUAT25Nb3VzZURvd24AT25Nb3VzZVVwAE9uUGFpbnQATkNfQkcATkNfSEVBREVSAE5DX0NBUkQATkNfU1VSRjIATkNfQk9SREVSAE5DX1RFWFQATkNfU1VCAE5DX0FDQ0VOVABOQ19DT05CRwBOQ19DT05GRwBOUm91bmQATlJlbGVhc2VDYXB0dXJlAE5TZW5kTWVzc2FnZQBOU2VuZE1zZ0ludABOQ3JlYXRlUm91bmRSZWN0UmduAE5TZXRXaW5kb3dSZ24AY2hpcHMATWFrZVBhZ2UATWtCdG4AVGhyZWFkU3RhcnQAU3RhbXAAQnVpbGRQaW5nVGFiAEJ1aWxkVHJhY2VydFRhYgBCdWlsZERuc1RhYgBCdWlsZEh0dHBUYWIAQnVpbGRQb3J0VGFiAEJ1aWxkU3VibmV0VGFiAEJ1aWxkTG9jYWxUYWIARmcAUHJpbWFyeQBCb3gAYmFyAFRpbWVyAHN5bmMAZHJhZwBkcmFnT2ZmAGxhc3RGaXJzdABsYXN0VG90YWwATWV0cmljcwBQYWludEJhcgBMaW5lAFNldABTYXZlAFdNX0NMSVBCT0FSRFVQREFURQBBZGRDbGlwYm9hcmRGb3JtYXRMaXN0ZW5lcgBSZW1vdmVDbGlwYm9hcmRGb3JtYXRMaXN0ZW5lcgBIaXN0b3J5AExpc3RCb3gAbGlzdABzZWxmU2V0AE9uSGFuZGxlQ3JlYXRlZABGb3JtQ2xvc2VkRXZlbnRBcmdzAE9uRm9ybUNsb3NlZABDb3B5U2VsAFJlZnJlc2hMaXN0AFduZFByb2MAYm94AExhYmVsAHN0YXR1cwBzYXZlcgBzYlN5bmMAaGVhZGVyAHdyYXAAc3RyaXAAc2IAZmlsZXMAY3VyAGFjdGl2ZUNpAHNiRHJhZwBzYkRyYWdPZmYAQ04AQ0JvZHkAQ0hlYWQAQ1RleHQAQ1N1YgBORgBOb3RlUm91bmQATm90ZUNvbG9yUGF0aABMb2FkTm90ZUNvbG9yAE5vdGVzRGlyAE5vdGVNZXRhUGF0aABSZWxlYXNlQ2FwdHVyZQBTZW5kTWVzc2FnZQBTZW5kTXNnSW50AENyZWF0ZVJvdW5kUmVjdFJnbgBTZXRXaW5kb3dSZ24ATG9hZE5vdGVzAFNhdmVNZXRhAExvYWRDdXIAVGl0bGVPZgBSZWJ1aWxkVGFicwBTd2l0Y2hUbwBBZGROb3RlAERlbGV0ZU5vdGUAU2JNZXRyaWNzAFBhaW50U2IAU2JEb3duAFNiTW92ZQBBcHBseVRoZW1lAFNhdmVOb3cAVGl0bGUAQWN0aXZlAENlbnRlcgBTZXRXaW5kb3dzSG9va0V4AFVuaG9va1dpbmRvd3NIb29rRXgAQ2FsbE5leHRIb29rRXgAR2V0TW9kdWxlSGFuZGxlAEdldEN1cnNvclBvcwBzd2F0Y2gAbGJsAG1vdXNlSG9vawBwcm9jAFN0YXJ0UGljawBTdG9wUGljawBNb3VzZUhvb2tQcm9jAFBpY2tBdAB4AHkAcHQAbW91c2VEYXRhAGZsYWdzAHRpbWUAZXh0cmEASW52b2tlAElBc3luY1Jlc3VsdABBc3luY0NhbGxiYWNrAEJlZ2luSW52b2tlAEVuZEludm9rZQBTeXN0ZW0uUmVmbGVjdGlvbgBBc3NlbWJseQBBc20ATWV0aG9kSW5mbwBFbnRyeQBFcnJvcgBMaXN0VmlldwBQbHVnaW5EaXIAVG9nZ2xlU2VsAFNlbEZpbGUAT3BlbkRpcgBFZGl0U2VsAERlbFNlbABOZXdQbHVnaW4AemgAZW4AcgByYWQAY2gAYwB0aXRsZQB0ZXh0AGljb24AZGlyAGJhdFBhdGgAZgBjb2RlAGxpbmUAcmF3TGluZQByZXN0AHRrAGZ1bGwAaGl2ZQBTeXN0ZW0uUnVudGltZS5JbnRlcm9wU2VydmljZXMAT3V0QXR0cmlidXRlAHN1YgBwc2kAc2NyaXB0AGV4dABleGUAYXJnc1ByZWZpeABlbmMAaW9FbmMAcHJlbHVkZQB2aXNpYmxlAHRhaWwAcGF0aABpc0RpcgBuAGZhaWwAc2tpcHBlZAB1aQB0aW1lb3V0TXMAc2l6ZQBydHQAdHRsAGRvbmUAcG9ydABzAHYAbQBpcFRleHQAbWFza1RleHQAaXAAYml0cwBtYXNrAGNvdW50AGEAYgBuYW1lAHF0eXBlAHNlcnZlcgB3AHAAcG9zAHVybABoAHQAY2FwAGxpbmVzAHN0ZXBzAHJhd3MAYm9keQB0YWcAZmlsZQBkaXNhYmxlZABzb3VyY2UAc3QAaFduZABtc2cAd1BhcmFtAGxQYXJhbQBsAHgxAHkxAHgyAHkyAGhSZ24AcmVkcmF3AHRhYnMAZGVsdGEAb2ZmAGR5AGUAZmlyc3QAdG90YWwAc2VuZGVyAGlkeABjb250ZW50SAB0b3BIAHRvcABwYXJlbnQAcHJpbWFyeQBmbgBvd25lcgBpAGlkAGNiAG1vZAB0aWQAbkNvZGUAb2JqZWN0AG1ldGhvZABjYWxsYmFjawByZXN1bHQAU3lzdGVtLlJ1bnRpbWUuQ29tcGlsZXJTZXJ2aWNlcwBDb21waWxhdGlvblJlbGF4YXRpb25zQXR0cmlidXRlAFJ1bnRpbWVDb21wYXRpYmlsaXR5QXR0cmlidXRlAHdndHJheV9uZXcAZ2V0X1gAZ2V0X1kAQWRkQXJjAGdldF9SaWdodABnZXRfQm90dG9tAENsb3NlRmlndXJlAEJpdG1hcABHcmFwaGljcwBJbWFnZQBGcm9tSW1hZ2UAU21vb3RoaW5nTW9kZQBzZXRfU21vb3RoaW5nTW9kZQBnZXRfVHJhbnNwYXJlbnQAQ2xlYXIAU29saWRCcnVzaABCcnVzaABGaWxsUGF0aABJRGlzcG9zYWJsZQBEaXNwb3NlAEdyYXBoaWNzVW5pdABTdHJpbmdGb3JtYXQAU3RyaW5nQWxpZ25tZW50AHNldF9BbGlnbm1lbnQAc2V0X0xpbmVBbGlnbm1lbnQARm9udEZhbWlseQBnZXRfRm9udEZhbWlseQBBZGRTdHJpbmcAQ29tcG9zaXRpbmdNb2RlAHNldF9Db21wb3NpdGluZ01vZGUAR2V0SGljb24ARnJvbUhhbmRsZQBTaG93QmFsbG9vblRpcABnZXRfSXNEaXNwb3NlZABnZXRfSGFuZGxlAFN0cmluZwBzZXRfSXRlbQBQYXRoAENvbWJpbmUARmlsZQBFeGlzdHMAZ2V0X1VURjgAUmVhZEFsbExpbmVzAFRyaW0AZ2V0X0xlbmd0aABnZXRfQ2hhcnMASW5kZXhPZgBTdWJzdHJpbmcAVG9Mb3dlcgBvcF9FcXVhbGl0eQBDaGFyAFNwbGl0AFN5c3RlbS5UZXh0LlJlZ3VsYXJFeHByZXNzaW9ucwBSZWdleABNYXRjaABHcm91cABnZXRfU3VjY2VzcwBHcm91cENvbGxlY3Rpb24AZ2V0X0dyb3VwcwBnZXRfSXRlbQBDYXB0dXJlAGdldF9WYWx1ZQBFbnZpcm9ubWVudABFeHBhbmRFbnZpcm9ubWVudFZhcmlhYmxlcwBUcnlHZXRWYWx1ZQBVVEY4RW5jb2RpbmcAV3JpdGVBbGxUZXh0AHNldF9GaWxlTmFtZQBzZXRfVXNlU2hlbGxFeGVjdXRlAFByb2Nlc3MAU3RhcnQAPEJ1aWxkTWVudT5iX18zAHBhcmFtMABwYXJhbTEAPEJ1aWxkTWVudT5iX180ADxCdWlsZE1lbnU+Yl9fNQA8QnVpbGRNZW51PmJfXzYAPEJ1aWxkTWVudT5iX183ADxCdWlsZE1lbnU+Yl9fOAA8QnVpbGRNZW51PmJfXzkAPEJ1aWxkTWVudT5iX19hADxCdWlsZE1lbnU+Yl9fYgA8QnVpbGRNZW51PmJfX2MARXZlbnRIYW5kbGVyAENTJDw+OV9fQ2FjaGVkQW5vbnltb3VzTWV0aG9kRGVsZWdhdGVkAENvbXBpbGVyR2VuZXJhdGVkQXR0cmlidXRlAEFwcGxpY2F0aW9uAEV4aXQAVG9vbFN0cmlwAFRvb2xTdHJpcEl0ZW1Db2xsZWN0aW9uAGdldF9JdGVtcwBUb29sU3RyaXBJdGVtAEFkZABUb29sU3RyaXBTZXBhcmF0b3IAVG9vbFN0cmlwRHJvcERvd25JdGVtAGdldF9Ecm9wRG93bkl0ZW1zAHNldF9Db250ZXh0TWVudVN0cmlwADw+Y19fRGlzcGxheUNsYXNzMTMAPD40X190aGlzADxSZWJ1aWxkVHJheU1lbnU+Yl9fMTAAPD5jX19EaXNwbGF5Q2xhc3MxNQA8UmVidWlsZFRyYXlNZW51PmJfXzEyADxSZWJ1aWxkVHJheU1lbnU+Yl9fMTEARW51bWVyYXRvcgBHZXRFbnVtZXJhdG9yAEtleVZhbHVlUGFpcmAyAGdldF9DdXJyZW50AFN0YXJ0c1dpdGgAZ2V0X0tleQBDb25jYXQATW92ZU5leHQAc2V0X0VuYWJsZWQAPD5jX19EaXNwbGF5Q2xhc3MxOABhcHAAPFJ1bj5iX18xNwBzZXRfVmlzaWJsZQBTcGVjaWFsRm9sZGVyAEdldEZvbGRlclBhdGgARGlyZWN0b3J5AERpcmVjdG9yeUluZm8AQ3JlYXRlRGlyZWN0b3J5AE11dGV4AE1lc3NhZ2VCb3gARGlhbG9nUmVzdWx0AFNob3cARnJvbUFyZ2IAc2V0X0ljb24Ac2V0X1RleHQAYWRkX0FwcGxpY2F0aW9uRXhpdABSZWFkQWxsVGV4dABDb250YWlucwBUcmltU3RhcnQASXNQYXRoUm9vdGVkAHNldF9Bcmd1bWVudHMARXhjZXB0aW9uAGdldF9NZXNzYWdlAElzV2hpdGVTcGFjZQBKb2luAEluc2VydABFbmRzV2l0aABJbnQzMgBUcnlQYXJzZQBnZXRfQ291bnQAVG9BcnJheQBSZXBsYWNlAFRvVXBwZXIAUmVnaXN0cnkAQ3VycmVudFVzZXIATG9jYWxNYWNoaW5lAENsYXNzZXNSb290AFVzZXJzAEN1cnJlbnRDb25maWcAPD5jX19EaXNwbGF5Q2xhc3MyMQBvdXRwAERhdGFSZWNlaXZlZEV2ZW50QXJncwA8UnVuSGlkZGVuPmJfXzFmADxSdW5IaWRkZW4+Yl9fMjAAZTIAZ2V0X0RhdGEAQXBwZW5kTGluZQBzZXRfQ3JlYXRlTm9XaW5kb3cAc2V0X1JlZGlyZWN0U3RhbmRhcmRPdXRwdXQAc2V0X1JlZGlyZWN0U3RhbmRhcmRFcnJvcgBnZXRfU3RhbmRhcmRPdXRwdXRFbmNvZGluZwBnZXRfRGVmYXVsdABzZXRfU3RhbmRhcmRPdXRwdXRFbmNvZGluZwBzZXRfU3RhbmRhcmRFcnJvckVuY29kaW5nAERhdGFSZWNlaXZlZEV2ZW50SGFuZGxlcgBhZGRfT3V0cHV0RGF0YVJlY2VpdmVkAGFkZF9FcnJvckRhdGFSZWNlaXZlZABCZWdpbk91dHB1dFJlYWRMaW5lAEJlZ2luRXJyb3JSZWFkTGluZQBXYWl0Rm9yRXhpdABUb1N0cmluZwBnZXRfRXhpdENvZGUAR2V0VGVtcFBhdGgAR3VpZABOZXdHdWlkAERlbGV0ZQA8PmNfX0Rpc3BsYXlDbGFzczI5AE1lc3NhZ2VCb3hCdXR0b25zAGJ0bnMATWVzc2FnZUJveERlZmF1bHRCdXR0b24AZGVmADxFeGVjVG9vbFN0ZXA+Yl9fMjgATWVzc2FnZUJveEljb24ARnVuY2AxAERlbGVnYXRlAFBhcnNlAFNsZWVwAEdldFByb2Nlc3Nlc0J5TmFtZQBLaWxsAEFwcGVuZABJbnQ2NABCeXRlAENvbnZlcnQAVG9CeXRlAENyZWF0ZVN1YktleQBSZWdpc3RyeVZhbHVlS2luZABTZXRWYWx1ZQBPcGVuU3ViS2V5AERlbGV0ZVZhbHVlAERlbGV0ZVN1YktleVRyZWUAVHJpbUVuZABHZXREaXJlY3RvcnlOYW1lAEdldEZpbGVOYW1lAEdldEZpbGVzAEdldERpcmVjdG9yaWVzAEFjdGl2YXRlAFN5c3RlbS5OZXQuTmV0d29ya0luZm9ybWF0aW9uAFBpbmcAUGluZ1JlcGx5AFNlbmQASVBTdGF0dXMAZ2V0X1N0YXR1cwBTeXN0ZW0uTmV0AElQQWRkcmVzcwBnZXRfQWRkcmVzcwBnZXRfUm91bmR0cmlwVGltZQBQaW5nT3B0aW9ucwBnZXRfT3B0aW9ucwBnZXRfVHRsAGdldF9CdWZmZXIARm9ybWF0AFN0b3B3YXRjaABTdGFydE5ldwBTeXN0ZW0uTmV0LlNvY2tldHMAVGNwQ2xpZW50AEJlZ2luQ29ubmVjdABXYWl0SGFuZGxlAGdldF9Bc3luY1dhaXRIYW5kbGUAV2FpdE9uZQBFbmRDb25uZWN0AGdldF9FbGFwc2VkTWlsbGlzZWNvbmRzAFR5cGUAR2V0VHlwZQBNZW1iZXJJbmZvAGdldF9OYW1lAEdldEFkZHJlc3NCeXRlcwBVSW50MzIAUGFkTGVmdABNYXRoAE1pbgA8UHJpdmF0ZUltcGxlbWVudGF0aW9uRGV0YWlscz57MkE4RjJDQzQtNkM2OS00QjZCLUFDMUMtMDg5MjFBQUJFNTZFfQBfX1N0YXRpY0FycmF5SW5pdFR5cGVTaXplPTU2ACQkbWV0aG9kMHg2MDAwMDI5LTEAUnVudGltZUhlbHBlcnMAQXJyYXkAUnVudGltZUZpZWxkSGFuZGxlAEluaXRpYWxpemVBcnJheQBQYWRSaWdodABEbnMAR2V0SG9zdE5hbWUATmV0d29ya0ludGVyZmFjZQBHZXRBbGxOZXR3b3JrSW50ZXJmYWNlcwBPcGVyYXRpb25hbFN0YXR1cwBnZXRfT3BlcmF0aW9uYWxTdGF0dXMATmV0d29ya0ludGVyZmFjZVR5cGUAZ2V0X05ldHdvcmtJbnRlcmZhY2VUeXBlAElQSW50ZXJmYWNlUHJvcGVydGllcwBHZXRJUFByb3BlcnRpZXMAVW5pY2FzdElQQWRkcmVzc0luZm9ybWF0aW9uQ29sbGVjdGlvbgBnZXRfVW5pY2FzdEFkZHJlc3NlcwBJRW51bWVyYXRvcmAxAFVuaWNhc3RJUEFkZHJlc3NJbmZvcm1hdGlvbgBJUEFkZHJlc3NJbmZvcm1hdGlvbgBBZGRyZXNzRmFtaWx5AGdldF9BZGRyZXNzRmFtaWx5AGdldF9JUHY0TWFzawBTeXN0ZW0uQ29sbGVjdGlvbnMASUVudW1lcmF0b3IAR2F0ZXdheUlQQWRkcmVzc0luZm9ybWF0aW9uQ29sbGVjdGlvbgBnZXRfR2F0ZXdheUFkZHJlc3NlcwBHYXRld2F5SVBBZGRyZXNzSW5mb3JtYXRpb24ASVBBZGRyZXNzQ29sbGVjdGlvbgBnZXRfRG5zQWRkcmVzc2VzACQkbWV0aG9kMHg2MDAwMDJiLTEAUmFuZG9tAE5leHQATWVtb3J5U3RyZWFtAFN0cmVhbQBnZXRfQVNDSUkAR2V0Qnl0ZXMAV3JpdGUAVWRwQ2xpZW50AFNvY2tldABnZXRfQ2xpZW50AHNldF9SZWNlaXZlVGltZW91dABBbnkASVBFbmRQb2ludABSZWNlaXZlAENvcHkAR2V0U3RyaW5nAFdlYlJlcXVlc3QAQ3JlYXRlAEh0dHBXZWJSZXF1ZXN0AHNldF9UaW1lb3V0AHNldF9SZWFkV3JpdGVUaW1lb3V0AHNldF9Vc2VyQWdlbnQAV2ViUmVzcG9uc2UAR2V0UmVzcG9uc2UASHR0cFdlYlJlc3BvbnNlAFVyaQBnZXRfUmVzcG9uc2VVcmkAb3BfSW5lcXVhbGl0eQBnZXRfSG9zdABIdHRwU3RhdHVzQ29kZQBnZXRfU3RhdHVzQ29kZQBnZXRfU3RhdHVzRGVzY3JpcHRpb24AV2ViSGVhZGVyQ29sbGVjdGlvbgBnZXRfSGVhZGVycwBTeXN0ZW0uQ29sbGVjdGlvbnMuU3BlY2lhbGl6ZWQATmFtZVZhbHVlQ29sbGVjdGlvbgBnZXRfQ29udGVudFR5cGUAR2V0UmVzcG9uc2VTdHJlYW0AUmVhZABXZWJFeGNlcHRpb24AZ2V0X1Jlc3BvbnNlAFN0cmVhbVJlYWRlcgBUZXh0UmVhZGVyAFJlYWRUb0VuZABJc051bGxPckVtcHR5AFJlbW92ZQBSZW1vdmVBdABnZXRfUgBnZXRfRwBnZXRfQgBNYXgAUm91bmQAUmVnZXhPcHRpb25zAFdyaXRlQWxsTGluZXMAPD5jX19EaXNwbGF5Q2xhc3MyZQA8PmNfX0Rpc3BsYXlDbGFzczMxADxSdW5QbHVnaW4+Yl9fMmMAQ1MkPD44X19sb2NhbHMyZgBlcnJzAGFib3J0ZWQAPFJ1blBsdWdpbj5iX18yZABBY3Rpb24Ac2V0X0lzQmFja2dyb3VuZABBc3NlbWJseU5hbWUATG9hZABnZXRfTG9jYXRpb24ATWljcm9zb2Z0LkNTaGFycABDU2hhcnBDb2RlUHJvdmlkZXIAU3lzdGVtLkNvZGVEb20uQ29tcGlsZXIAQ29tcGlsZXJQYXJhbWV0ZXJzAHNldF9HZW5lcmF0ZUluTWVtb3J5AHNldF9HZW5lcmF0ZUV4ZWN1dGFibGUAU3RyaW5nQ29sbGVjdGlvbgBnZXRfUmVmZXJlbmNlZEFzc2VtYmxpZXMAQWRkUmFuZ2UAQ29kZURvbVByb3ZpZGVyAENvbXBpbGVyUmVzdWx0cwBDb21waWxlQXNzZW1ibHlGcm9tU291cmNlAENvbXBpbGVyRXJyb3JDb2xsZWN0aW9uAGdldF9FcnJvcnMAZ2V0X0hhc0Vycm9ycwBDb2xsZWN0aW9uQmFzZQBDb21waWxlckVycm9yAGdldF9MaW5lAGdldF9FcnJvclRleHQAZ2V0X0NvbXBpbGVkQXNzZW1ibHkAR2V0VHlwZXMARW1wdHlUeXBlcwBCaW5kaW5nRmxhZ3MAQmluZGVyAFBhcmFtZXRlck1vZGlmaWVyAEdldE1ldGhvZABnZXRfUmV0dXJuVHlwZQBWb2lkAFJ1bnRpbWVUeXBlSGFuZGxlAEdldFR5cGVGcm9tSGFuZGxlADw+Y19fRGlzcGxheUNsYXNzMzYAcGMAPFJ1bkNvZGVQbHVnaW4+Yl9fMzQATWV0aG9kQmFzZQBHZXRCYXNlRXhjZXB0aW9uADxFbnN1cmVQbHVnaW5UaHJlYWQ+Yl9fMzgAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTM5AEFwYXJ0bWVudFN0YXRlAFNldEFwYXJ0bWVudFN0YXRlAHNldF9OYW1lAGdldF9Jc0hhbmRsZUNyZWF0ZWQALmNjdG9yAFN5c3RlbS5HbG9iYWxpemF0aW9uAEN1bHR1cmVJbmZvAGdldF9DdXJyZW50VUlDdWx0dXJlAGdldF9HZW5lcmljU2Fuc1NlcmlmAERsbEltcG9ydEF0dHJpYnV0ZQB1c2VyMzIuZGxsAGdkaTMyLmRsbAA8PmNfX0Rpc3BsYXlDbGFzczVlAHJnAGNsb3NlAHRhYkJ0bnMAPC5jdG9yPmJfXzQ3ADwuY3Rvcj5iX180OAA8LmN0b3I+Yl9fNGEAPC5jdG9yPmJfXzRiADwuY3Rvcj5iX180ZAA8PmNfX0Rpc3BsYXlDbGFzczYwAENTJDw+OF9fbG9jYWxzNWYAPC5jdG9yPmJfXzRmADwuY3Rvcj5iX180NgA8LmN0b3I+Yl9fNDkAPC5jdG9yPmJfXzRjADwuY3Rvcj5iX180ZQA8LmN0b3I+Yl9fNTAAczIATW91c2VFdmVudEhhbmRsZXIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTU5ADwuY3Rvcj5iX181MQA8LmN0b3I+Yl9fNTIAQ1MkPD45X19DYWNoZWRBbm9ueW1vdXNNZXRob2REZWxlZ2F0ZTViADwuY3Rvcj5iX181MwBLZXlFdmVudEFyZ3MAPC5jdG9yPmJfXzU0AGdldF9XaWR0aABnZXRfSGVpZ2h0AEVtcHR5AGdldF9HcmFwaGljcwBQZW4ARHJhd1BhdGgAc2V0X0JhY2tDb2xvcgBnZXRfV2hpdGUAc2V0X0ZvcmVDb2xvcgBDbG9zZQBEcmF3TGluZQBNb3VzZUJ1dHRvbnMAZ2V0X0J1dHRvbgBJbnRQdHIAb3BfRXhwbGljaXQAWmVybwBJbnZhbGlkYXRlAHNldF9DYXB0dXJlAFJlbW92ZU1lc3NhZ2VGaWx0ZXIAS2V5cwBnZXRfS2V5Q29kZQBGb3JtQm9yZGVyU3R5bGUAc2V0X0Zvcm1Cb3JkZXJTdHlsZQBDb250YWluZXJDb250cm9sAEF1dG9TY2FsZU1vZGUAc2V0X0F1dG9TY2FsZU1vZGUARm9ybVN0YXJ0UG9zaXRpb24Ac2V0X1N0YXJ0UG9zaXRpb24Ac2V0X1RvcE1vc3QAc2V0X0tleVByZXZpZXcAU2l6ZQBzZXRfQ2xpZW50U2l6ZQBhZGRfSGFuZGxlQ3JlYXRlZABhZGRfUmVzaXplAFBhaW50RXZlbnRIYW5kbGVyAGFkZF9QYWludABQb2ludABzZXRfTG9jYXRpb24Ac2V0X1NpemUAc2V0X0F1dG9TaXplAHNldF9Gb250AENvbnRlbnRBbGlnbm1lbnQAc2V0X1RleHRBbGlnbgBDdXJzb3JzAEN1cnNvcgBnZXRfSGFuZABzZXRfQ3Vyc29yAGFkZF9Nb3VzZUVudGVyAGFkZF9Nb3VzZUxlYXZlAGFkZF9DbGljawBDb250cm9sQ29sbGVjdGlvbgBnZXRfQ29udHJvbHMAYWRkX01vdXNlRG93bgBzZXRfVGFnAERvY2tTdHlsZQBzZXRfRG9jawBzZXRfV2lkdGgAYWRkX01vdXNlTW92ZQBhZGRfTW91c2VVcABQYWRkaW5nAHNldF9QYWRkaW5nAFRleHRCb3hCYXNlAHNldF9NdWx0aWxpbmUAc2V0X1JlYWRPbmx5AEJvcmRlclN0eWxlAHNldF9Cb3JkZXJTdHlsZQBTY3JvbGxCYXJzAHNldF9TY3JvbGxCYXJzAEFkZE1lc3NhZ2VGaWx0ZXIARm9ybUNsb3NlZEV2ZW50SGFuZGxlcgBhZGRfRm9ybUNsb3NlZABLZXlFdmVudEhhbmRsZXIAYWRkX0tleURvd24AZ2V0X1Bvc2l0aW9uAFBvaW50VG9DbGllbnQAZ2V0X1Zpc2libGUAZ2V0X0JvdW5kcwBTeXN0ZW0uV2luZG93cy5Gb3Jtcy5MYXlvdXQAQXJyYW5nZWRFbGVtZW50Q29sbGVjdGlvbgBnZXRfVG9wAHNldF9Ub3AAVG9JbnQzMgBnZXRfRm9udABUZXh0UmVuZGVyZXIATWVhc3VyZVRleHQAZ2V0X0NsaWVudFNpemUAPD5jX19EaXNwbGF5Q2xhc3M2NAA8TG9nPmJfXzYyAGdldF9JbnZva2VSZXF1aXJlZABBcHBlbmRUZXh0ADw+Y19fRGlzcGxheUNsYXNzNjgAYnRuADxSdW5BY3Rpb24+Yl9fNjYAPFJ1bkFjdGlvbj5iX182NwBnZXRfVGFnAHNldF9Eb3VibGVCdWZmZXJlZABnZXRfTXNnAGdldF9XUGFyYW0AVG9JbnQ2NABnZXRfUGFyZW50AGdldF9CYWNrQ29sb3IAZ2V0X0NsaWVudFJlY3RhbmdsZQBGaWxsUmVjdGFuZ2xlAGdldF9FbmFibGVkAGdldF9UZXh0AERyYXdTdHJpbmcAPD5jX19EaXNwbGF5Q2xhc3M4MQA8LmN0b3I+Yl9fNzIAPC5jdG9yPmJfXzczADwuY3Rvcj5iX183NQA8LmN0b3I+Yl9fNzYAPC5jdG9yPmJfXzc4ADw+Y19fRGlzcGxheUNsYXNzODMAQ1MkPD44X19sb2NhbHM4MgA8LmN0b3I+Yl9fN2EAPC5jdG9yPmJfXzcxADwuY3Rvcj5iX183NAA8LmN0b3I+Yl9fNzcAPC5jdG9yPmJfXzc5ADwuY3Rvcj5iX183YgBEYXRlVGltZQBnZXRfTm93ADw+Y19fRGlzcGxheUNsYXNzOGYAPD5jX19EaXNwbGF5Q2xhc3M5MQBjbnQAY2FuY2VsADxCdWlsZFBpbmdUYWI+Yl9fODkAPEJ1aWxkUGluZ1RhYj5iX184YwA8QnVpbGRQaW5nVGFiPmJfXzhkADxCdWlsZFBpbmdUYWI+Yl9fOGUAQ1MkPD44X19sb2NhbHM5MABzegA8QnVpbGRQaW5nVGFiPmJfXzhhADxCdWlsZFBpbmdUYWI+Yl9fOGIARG91YmxlAEJvb2xlYW4APD5jX19EaXNwbGF5Q2xhc3M5OQA8QnVpbGRUcmFjZXJ0VGFiPmJfXzk0ADxCdWlsZFRyYWNlcnRUYWI+Yl9fOTcAPEJ1aWxkVHJhY2VydFRhYj5iX185OAA8QnVpbGRUcmFjZXJ0VGFiPmJfXzk1ADxCdWlsZFRyYWNlcnRUYWI+Yl9fOTYAPD5jX19EaXNwbGF5Q2xhc3NhMwA8PmNfX0Rpc3BsYXlDbGFzc2E3AHR5cGVzAHRvZ2dsZXMAPEJ1aWxkRG5zVGFiPmJfXzllADxCdWlsZERuc1RhYj5iX19hMQA8QnVpbGREbnNUYWI+Yl9fYTIAQ1MkPD44X19sb2NhbHNhNABubQBzdgB0cAA8QnVpbGREbnNUYWI+Yl9fOWYAPEJ1aWxkRG5zVGFiPmJfX2EwADw+Y19fRGlzcGxheUNsYXNzYTUAdGkAPEJ1aWxkRG5zVGFiPmJfXzlkADw+Y19fRGlzcGxheUNsYXNzYjEAPD5jX19EaXNwbGF5Q2xhc3NiMwBnbwA8QnVpbGRIdHRwVGFiPmJfX2FhADxCdWlsZEh0dHBUYWI+Yl9fYWQAPEJ1aWxkSHR0cFRhYj5iX19hZQA8QnVpbGRIdHRwVGFiPmJfX2FmADxCdWlsZEh0dHBUYWI+Yl9fYjAAQ1MkPD44X19sb2NhbHNiMgB1ADxCdWlsZEh0dHBUYWI+Yl9fYWIAPEJ1aWxkSHR0cFRhYj5iX19hYwBzZXRfU3VwcHJlc3NLZXlQcmVzcwA8PmNfX0Rpc3BsYXlDbGFzc2JlADw+Y19fRGlzcGxheUNsYXNzYzAAPD5jX19EaXNwbGF5Q2xhc3NjMwBzY2FuADxCdWlsZFBvcnRUYWI+Yl9fYjYAPEJ1aWxkUG9ydFRhYj5iX19iOQA8QnVpbGRQb3J0VGFiPmJfX2JjADxCdWlsZFBvcnRUYWI+Yl9fYmQAQ1MkPD44X19sb2NhbHNiZgA8QnVpbGRQb3J0VGFiPmJfX2I3ADxCdWlsZFBvcnRUYWI+Yl9fYjgAcG9ydHMAPEJ1aWxkUG9ydFRhYj5iX19iYQA8QnVpbGRQb3J0VGFiPmJfX2JiAF9fU3RhdGljQXJyYXlJbml0VHlwZVNpemU9NTIAJCRtZXRob2QweDYwMDAxMmEtMQA8PmNfX0Rpc3BsYXlDbGFzc2NmAG1rAGlwMQBpcDIAPEJ1aWxkU3VibmV0VGFiPmJfX2NiADxCdWlsZFN1Ym5ldFRhYj5iX19jYwA8QnVpbGRTdWJuZXRUYWI+Yl9fY2QAPEJ1aWxkU3VibmV0VGFiPmJfX2NlAGFkZF9UZXh0Q2hhbmdlZAA8PmNfX0Rpc3BsYXlDbGFzc2Q2ADw+Y19fRGlzcGxheUNsYXNzZDkAcmVmcmVzaAA8QnVpbGRMb2NhbFRhYj5iX19kMQA8QnVpbGRMb2NhbFRhYj5iX19kNAA8QnVpbGRMb2NhbFRhYj5iX19kNQA8QnVpbGRMb2NhbFRhYj5iX19kMgBDUyQ8PjhfX2xvY2Fsc2Q3AGluZm8APEJ1aWxkTG9jYWxUYWI+Yl9fZDMAQ2xpcGJvYXJkAFNldFRleHQAPC5jdG9yPmJfX2RkADwuY3Rvcj5iX19kZQA8LmN0b3I+Yl9fZGYARm9jdXMAZ2V0X0lCZWFtAGFkZF9FbnRlcgBhZGRfTGVhdmUAZ2V0X0ZvY3VzZWQAPC5jdG9yPmJfX2U2ADwuY3Rvcj5iX19lNwA8LmN0b3I+Yl9fZTgAPC5jdG9yPmJfX2U5ADwuY3Rvcj5iX19lYQA8LmN0b3I+Yl9fZWIAU3RvcABTeXN0ZW0uQ29tcG9uZW50TW9kZWwAQ29tcG9uZW50AHNldF9JbnRlcnZhbABhZGRfVGljawBhZGRfRGlzcG9zZWQAPD5jX19EaXNwbGF5Q2xhc3NmNAA8TGluZT5iX19mMgBTYXZlRmlsZURpYWxvZwBGaWxlRGlhbG9nAHNldF9GaWx0ZXIAQ29tbW9uRGlhbG9nAElXaW4zMldpbmRvdwBTaG93RGlhbG9nAGdldF9GaWxlTmFtZQA8LmN0b3I+Yl9fZmMAPC5jdG9yPmJfX2ZkADwuY3Rvcj5iX19mZQA8LmN0b3I+Yl9fZmYAPC5jdG9yPmJfXzEwMABzZXRfSW50ZWdyYWxIZWlnaHQAc2V0X0hlaWdodABCdXR0b24AZ2V0X0dyYXkAYWRkX0RvdWJsZUNsaWNrAExpc3RDb250cm9sAGdldF9TZWxlY3RlZEluZGV4AEJlZ2luVXBkYXRlAE9iamVjdENvbGxlY3Rpb24ARW5kVXBkYXRlAEdldFRleHQAPD5jX19EaXNwbGF5Q2xhc3MxMjkAPC5jdG9yPmJfXzExMgA8LmN0b3I+Yl9fMTEzADwuY3Rvcj5iX18xMTQAPC5jdG9yPmJfXzExNQA8PmNfX0Rpc3BsYXlDbGFzczEyYgBDUyQ8PjhfX2xvY2FsczEyYQBjaQA8LmN0b3I+Yl9fMTE3ADwuY3Rvcj5iX18xMTgAPC5jdG9yPmJfXzExMQA8LmN0b3I+Yl9fMTE2ADwuY3Rvcj5iX18xMTkAPC5jdG9yPmJfXzExYQA8LmN0b3I+Yl9fMTFiADwuY3Rvcj5iX18xMWMAPC5jdG9yPmJfXzExZABGb3JtQ2xvc2luZ0V2ZW50QXJncwA8LmN0b3I+Yl9fMTFlADwuY3Rvcj5iX18xMWYARHJhd0VsbGlwc2UAQWRkRWxsaXBzZQBSZWdpb24Ac2V0X1JlZ2lvbgBGb3JtQ2xvc2luZ0V2ZW50SGFuZGxlcgBhZGRfRm9ybUNsb3NpbmcAU29ydGVkRGljdGlvbmFyeWAyAEdldEZpbGVOYW1lV2l0aG91dEV4dGVuc2lvbgBDb250YWluc0tleQBzZXRfU2VsZWN0aW9uU3RhcnQAUmVhZExpbmUAPD5jX19EaXNwbGF5Q2xhc3MxMzIAPFJlYnVpbGRUYWJzPmJfXzEyZgA8UmVidWlsZFRhYnM+Yl9fMTMwAGFkZF9Nb3VzZUNsaWNrAE1vdmUAU3RyaW5nVHJpbW1pbmcAc2V0X1RyaW1taW5nAFN0cmluZ0Zvcm1hdEZsYWdzAHNldF9Gb3JtYXRGbGFncwA8LmN0b3I+Yl9fMTNhADwuY3Rvcj5iX18xM2IAPC5jdG9yPmJfXzEzYwA8LmN0b3I+Yl9fMTNkAE1hcnNoYWwAUHRyVG9TdHJ1Y3R1cmUAQ29weUZyb21TY3JlZW4AR2V0UGl4ZWwAU3RydWN0TGF5b3V0QXR0cmlidXRlAExheW91dEtpbmQAPD5jX19EaXNwbGF5Q2xhc3MxNjgAPC5jdG9yPmJfXzE1MwA8PmNfX0Rpc3BsYXlDbGFzczE2YQBDUyQ8PjhfX2xvY2FsczE2OQBjYXJkADwuY3Rvcj5iX18xNGEAPC5jdG9yPmJfXzE0YgA8LmN0b3I+Yl9fMTRkADwuY3Rvcj5iX18xNGUAPC5jdG9yPmJfXzE1MAA8LmN0b3I+Yl9fMTUyADwuY3Rvcj5iX18xNTkAY2FwMgA8LmN0b3I+Yl9fMTQ5ADwuY3Rvcj5iX18xNGMAPC5jdG9yPmJfXzE0ZgA8LmN0b3I+Yl9fMTUxADwuY3Rvcj5iX18xNTQAPC5jdG9yPmJfXzE1NQA8LmN0b3I+Yl9fMTU2ADwuY3Rvcj5iX18xNTcAPC5jdG9yPmJfXzE1OAA8LmN0b3I+Yl9fMTVhADwuY3Rvcj5iX18xNWIAQWN0aW9uYDMAVmlldwBzZXRfVmlldwBzZXRfRnVsbFJvd1NlbGVjdABzZXRfTXVsdGlTZWxlY3QAc2V0X0hpZGVTZWxlY3Rpb24AQ29sdW1uSGVhZGVyQ29sbGVjdGlvbgBnZXRfQ29sdW1ucwBDb2x1bW5IZWFkZXIATGlzdFZpZXdJdGVtQ29sbGVjdGlvbgBTdHJpbmdDb21wYXJpc29uAEVxdWFscwBMaXN0Vmlld0l0ZW0ATGlzdFZpZXdTdWJJdGVtQ29sbGVjdGlvbgBnZXRfU3ViSXRlbXMATGlzdFZpZXdTdWJJdGVtAFNlbGVjdGVkTGlzdFZpZXdJdGVtQ29sbGVjdGlvbgBnZXRfU2VsZWN0ZWRJdGVtcwAAJU0AaQBjAHIAbwBzAG8AZgB0ACAAWQBhAEgAZQBpACAAVQBJAACCazsAIABXAGcAVAByAGEAeQAgAE2Rbn+HZfZOIAAoAFUAVABGAC0AOAAsACAADk4gAHcAZwB0AHIAYQB5AC4AYgBhAHQAIAAMVO52VV8pAA0ACgA7ACAAYQBwAHAAOgAgAFhi2Hbcg1VTIAAtAD4AIACUXih1IADMkYR2YWfudiwAIAAWfwF4PABUAEEAQgA+AA1U8Hk8AFQAQQBCAD4AfVTkTlsAPABUAEEAQgA+AMJTcGVdACAAKAAGUpSWJntfTqVj11N6ejxoLAAgACtUeno8aIR2fVTkTih1FV/3UwVTT087AA0ACgA7ACAAIAAgACAAIAAgAPh2+VvvjYRfCWMgAHcAZwB0AHIAYQB5AC4AYgBhAHQAIABAYihX7nZVX+OJkGcsACAAL2UBYyAAJQCvc4NY2FPPkSUAKQANAAoAOwAgAGEAcABwACAAPQAgAG4AcAAJALCLi04sZwkAbgBvAHQAZQBwAGEAZAAuAGUAeABlAA0ACgA7ACAAYQBwAHAAIAA9ACAAZwB5AAkA006TXu52VV8JAEMAOgBcAFQAbwBvAGwAcwBcAFcAZwBJAG0AZQANAAoAOwAgAGEAcABwACAAPQAgAGIAZAAJAH52pl4JAGgAdAB0AHAAcwA6AC8ALwB3AHcAdwAuAGIAYQBpAGQAdQAuAGMAbwBtAA0ACgA7ACAAKABXAGcASQBtAGUAIACEdiAAZgB1AHoAegB5AC8AcABhAHMAdABlAC8AawBlAHkAZgBpAHgAIABJe5OPZVHVbE2Rbn8sZ+Vdd1ENTn9PKHUsACAAWXVAdw1OcV/NVCkADQAKAAENaQB0AG8AbwBsAHMAAAflXXdRsXsBD1QAbwBvAGwAYgBvAHgAABtiAHUAaQBsAHQAaQBuADoAdABvAG8AbABzAAABAAt0AG8AbwBsAHMAAAduAGUAdAAACVF/3H7lXXdRARtOAGUAdAB3AG8AcgBrACAAdABvAG8AbABzAAAhYgB1AGkAbAB0AGkAbgA6AG4AZQB0AHQAbwBvAGwAcwAACXcAbABnAGoAAAljAGwAaQBwAAALalI0jX9nhlPyUwEjQwBsAGkAcABiAG8AYQByAGQAIABoAGkAcwB0AG8AcgB5AAAZYgB1AGkAbAB0AGkAbgA6AGMAbABpAHAAAAdqAGwAYgAABWIAagAABb9PfnsBGVMAdABpAGMAawB5ACAAbgBvAHQAZQBzAAAZYgB1AGkAbAB0AGkAbgA6AG4AbwB0AGUAAAtuAG8AdABlAHMAAAV5AHMAAAmcmHKC/mLWUwEZQwBvAGwAbwByACAAcABpAGMAawBlAHIAABtiAHUAaQBsAHQAaQBuADoAYwBvAGwAbwByAAALYwBvAGwAbwByAAAPcABsAHUAZwBpAG4AcwAACdJj9k6hewZ0AR1QAGwAdQBnAGkAbgAgAG0AYQBuAGEAZwBlAHIAACNiAHUAaQBsAHQAaQBuADoAcABsAHUAZwBpAG4AbQBnAHIAAAljAGoAZwBsAAAVYwBvAG4AZgBpAGcALgB0AHgAdAAAB2EAcABwAABfXgAoAFwAUwArACkAXABzACsAKABcAFMAKwApAFwAcwArACgAIgAoAD8AOgBbAF4AIgBdACoAKQAiAHwAXABTACsAKQAoAD8AOgBcAHMAKwAoAC4AKgApACkAPwAkAAAHagBzAHEAAAljAGEAbABjAAAJ5V13UbF7JiABEVQAbwBvAGwAYgBvAHgAJiABBdJj9k4BD1AAbAB1AGcAaQBuAHMAAAmFUW5/5V13UQEdQgB1AGkAbAB0AC0AaQBuACAAdABvAG8AbABzAAEHoYuXe2hWARVDAGEAbABjAHUAbABhAHQAbwByAAAflF4odSAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAASNBAHAAcABzACAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAAAVNkW5/AQ1DAG8AbgBmAGkAZwAAJRZ/kY9NkW5/IAAoAGMAbwBuAGYAaQBnAC4AdAB4AHQAKQAmIAEzRQBkAGkAdAAgAGMAbwBuAGYAaQBnACAAKABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAJiABCc2RfY9NkW5/ARtSAGUAbABvAGEAZAAgAGMAbwBuAGYAaQBnAAALcGVuY+52VV8mIAEZRABhAHQAYQAgAGYAbwBsAGQAZQByACYgAQUAkPpRAQlFAHgAaQB0AAAPcABsAHUAZwBpAG4AOgAAF2MAbwBkAGUAcABsAHUAZwBpAG4AOgAAByAAIAAoAAADKQAALygA4GXSY/ZOIAAUICAAPmUgAHAAbAB1AGcAaQBuAHMAXAAqAC4AdAB4AHQAKQABQSgAbgBvACAAcABsAHUAZwBpAG4AcwAgABQgIABwAHUAdAAgAHAAbAB1AGcAaQBuAHMAXAAqAC4AdAB4AHQAKQABC9Jj9k6hewZ0JiABH1AAbAB1AGcAaQBuACAAbQBhAG4AYQBnAGUAcgAmIAERYgB1AGkAbAB0AGkAbgA6AABFKADgZSAAFCAgAGMAbwBuAGYAaQBnAC4AdAB4AHQAIADMkaBSIABhAHAAcAAgAD0AIAAWfwF4IAANVPB5IAB9VOROKQABaSgAbgBvAG4AZQAgABQgIABhAGQAZAAgACcAYQBwAHAAIAA9ACAAYwBvAGQAZQAgAG4AYQBtAGUAIABjAG8AbQBtAGEAbgBkACcAIABpAG4AIABjAG8AbgBmAGkAZwAuAHQAeAB0ACkAAQt3AGcAaQBtAGUAAClXAGcAVAByAGEAeQBTAGkAbgBnAGwAZQBJAG4AcwB0AGEAbgBjAGUAADNXAGcAVAByAGEAeQAgAPJdKFfQj0yIIAAUICAA94tIUc5OWGLYdgCQ+lHnZZ5bi08CMAGAjVcAZwBUAHIAYQB5ACAAaQBzACAAYQBsAHIAZQBhAGQAeQAgAHIAdQBuAG4AaQBuAGcAIAAUICAAZQB4AGkAdAAgAHQAaABlACAAbwBsAGQAIABpAG4AcwB0AGEAbgBjAGUAIABmAHIAbwBtACAAdABoAGUAIAB0AHIAYQB5ACAAZgBpAHIAcwB0AC4AAQ1XAGcAVAByAGEAeQAAA+VdAQNUAAAFYABuAAADOwAABzoALwAvAAAJL1SoUjFZJY0BG0wAYQB1AG4AYwBoACAAZgBhAGkAbABlAGQAAAU6ACAAABN0AG8AbwBsAHMALgB0AHgAdAAAAwoAAA9bAHMAaABlAGwAbABdAAALWwBjAG0AZABdAAAVcwBoAGUAbABsAGIAbABvAGMAawAAAy8AABlbAHAAbwB3AGUAcgBzAGgAZQBsAGwAXQAACVsAcABzAF0AAA9wAHMAYgBsAG8AYwBrAAAbWwAvAHAAbwB3AGUAcgBzAGgAZQBsAGwAXQAAC1sALwBwAHMAXQAAEVsAcwBoAGUAbABsAHgAXQAADVsAYwBtAGQAeABdAAAXcwBoAGUAbABsAGIAbABvAGMAawB4AAAbWwBwAG8AdwBlAHIAcwBoAGUAbABsAHgAXQAAC1sAcABzAHgAXQAAEXAAcwBiAGwAbwBjAGsAeAAAA1sAAANdAAAJdABhAGIAIAAAAz8AAAtjAG8AbABzACAAAAXlXXdRAQtUAG8AbwBsAHMAAA9iAHUAdAB0AG8AbgAgAAAJSABLAEMAVQAAI0gASwBFAFkAXwBDAFUAUgBSAEUATgBUAF8AVQBTAEUAUgAACUgASwBMAE0AACVIAEsARQBZAF8ATABPAEMAQQBMAF8ATQBBAEMASABJAE4ARQAACUgASwBDAFIAACNIAEsARQBZAF8AQwBMAEEAUwBTAEUAUwBfAFIATwBPAFQAAAdIAEsAVQAAFUgASwBFAFkAXwBVAFMARQBSAFMAAAlIAEsAQwBDAAAnSABLAEUAWQBfAEMAVQBSAFIARQBOAFQAXwBDAE8ATgBGAEkARwAAFWIAYQBkACAAaABpAHYAZQA6ACAAAA8gACAAbwB1AHQAOgAgAAAPIAAgAGUAeABpAHQAIAAAFWUAeABpAHQAIABjAG8AZABlACAAABd3AGcAaQBtAGUALQB0AG8AbwBsAC0AAQNOAAADIgAAB20AcwBnAAAPYwBvAG4AZgBpAHIAbQAAC3QAaQB0AGwAZQAAD2IAdQB0AHQAbwBuAHMAAAVvAGsAABFvAGsAYwBhAG4AYwBlAGwAAA9kAGUAZgBhAHUAbAB0AAADMQAAC2EAYgBvAHIAdAAACXcAYQBpAHQAAAlrAGkAbABsAAATIAAgAGsAaQBsAGwAZQBkACAAAAcgAHgAIAAAB3IAdQBuAAALcwBoAGUAbABsAAAPYwBtAGQALgBlAHgAZQAABy8AYwAgAAAJLgBjAG0AZAAACS4AcABzADEAAB1wAG8AdwBlAHIAcwBoAGUAbABsAC4AZQB4AGUAAFMtAE4AbwBQAHIAbwBmAGkAbABlACAALQBFAHgAZQBjAHUAdABpAG8AbgBQAG8AbABpAGMAeQAgAEIAeQBwAGEAcwBzACAALQBGAGkAbABlACAAAWdbAEMAbwBuAHMAbwBsAGUAXQA6ADoATwB1AHQAcAB1AHQARQBuAGMAbwBkAGkAbgBnACAAPQAgAFsAVABlAHgAdAAuAEUAbgBjAG8AZABpAG4AZwBdADoAOgBVAFQARgA4AA0ACgAADXMAaABlAGwAbAB4AAAhDQAKAGUAYwBoAG8ALgANAAoAcABhAHUAcwBlAA0ACgAAZw0ACgBXAHIAaQB0AGUALQBIAG8AcwB0ACAAJwAnAA0ACgBSAGUAYQBkAC0ASABvAHMAdAAgACcAcAByAGUAcwBzACAARQBOAFQARQBSACAAdABvACAAYwBsAG8AcwBlACcADQAKAAEJbwBwAGUAbgAAD3IAZQBnAC0AcwBlAHQAAQMtAAEDIAAAC2QAdwBvAHIAZAAAC3EAdwBvAHIAZAAADWUAeABwAGEAbgBkAAALbQB1AGwAdABpAAANYgBpAG4AYQByAHkAAA9yAGUAZwAtAGQAZQBsAAERZgBpAGwAZQAtAGQAZQBsAAE/cgBlAGYAdQBzAGUAIAB0AG8AIABkAGUAbABlAHQAZQAgAGEAIABkAHIAaQB2AGUAIAByAG8AbwB0ADoAIAAAESAAIABzAGsAaQBwADoAIAAAFSAAIABkAGUAbABlAHQAZQBkACAAABUsACAAcwBrAGkAcABwAGUAZAAgAAAlIAAoAGkAbgAgAHUAcwBlACAALwAgAGwAbwBjAGsAZQBkACkAAAttAGsAZABpAHIAAB11AG4AawBuAG8AdwBuACAAdgBlAHIAYgA6ACAAAFV0AG8AbwBsAHMALgB0AHgAdAAgADpOenoWYg1OWFsoVxQgFCAoVyAAdwBnAGkAbQBlAC4AYgBhAHQAIAAMVO52VV/6XgBOKk5zU+9T+22gUp9S/YABa3QAbwBvAGwAcwAuAHQAeAB0ACAAbQBpAHMAcwBpAG4AZwAvAGUAbQBwAHQAeQAgAC0AIABjAHIAZQBhAHQAZQAgAGkAdAAgAG4AZQB4AHQAIAB0AG8AIAB3AGcAaQBtAGUALgBiAGEAdAABWXIAZQBwAGwAeQAgAGYAcgBvAG0AIAB7ADAAfQA6ACAAdABpAG0AZQA9AHsAMQB9AG0AcwAgAHQAdABsAD0AewAyAH0AIABiAHkAdABlAHMAPQB7ADMAfQAAEXMAdABhAHQAdQBzADoAIAAAD2UAcgByAG8AcgA6ACAAAAUgACAAABVtAHMAIAAgACgAZABvAG4AZQApAAAFbQBzAAATIAAgAGUAcgByAG8AcgA6ACAAACFjAGwAbwBzAGUAZAAgACgAdABpAG0AZQBvAHUAdAAgAAAHbQBzACkAAA1vAHAAZQBuACAAIAAAEWMAbABvAHMAZQBkACAAKAAAE0kAUAB2ADQAIABvAG4AbAB5AAADLgAAC6ljAXgNTt6P7X4BJ24AbwBuAC0AYwBvAG4AdABpAGcAdQBvAHUAcwAgAG0AYQBzAGsAARViAGEAZAAgAHAAcgBlAGYAaQB4AAALKmcHY5pbMFdAVwEXdQBuAHMAcABlAGMAaQBmAGkAZQBkAAAf3lavczBXQFcgACgAbABvAG8AcABiAGEAYwBrACkAARFsAG8AbwBwAGIAYQBjAGsAAB3BeQlnMFdAVyAAKABSAEYAQwAxADkAMQA4ACkAASNwAHIAaQB2AGEAdABlACAAKABSAEYAQwAxADkAMQA4ACkAABn+lO+NLGcwVyAAKABBAFAASQBQAEEAKQABJWwAaQBuAGsALQBsAG8AYwBhAGwAIAAoAEEAUABJAFAAQQApAAEh0I8lhEZVp34gAE4AQQBUACAAKABDAEcATgBBAFQAKQABI2MAYQByAHIAaQBlAHIALQBnAHIAYQBkAGUAIABOAEEAVAABHcR+rWQgACgAbQB1AGwAdABpAGMAYQBzAHQAKQABE20AdQBsAHQAaQBjAGEAcwB0AAAb3U9ZdSAAKAByAGUAcwBlAHIAdgBlAGQAKQABEXIAZQBzAGUAcgB2AGUAZAAACWxRUX8wV0BXAQ1wAHUAYgBsAGkAYwAAA0EAAANCAAADQwAAA0QAAANFAAAFqWMBeAEJTQBhAHMAawAAEzoAIAAgACAAIAAgACAAIAAgAAAJIAAgACgALwAABxqQTZEmewERVwBpAGwAZABjAGEAcgBkAAALOgAgACAAIAAgAAAJUX/cfjBXQFcBD04AZQB0AHcAbwByAGsAAAk6ACAAIAAgAAAJf16tZDBXQFcBE0IAcgBvAGEAZABjAGEAcwB0AAAJ71ModQOD9FYBFUgAbwBzAHQAIAByAGEAbgBnAGUAAAc6ACAAIAAAByAALQAgAAEL71ModTtOOmdwZQELSABvAHMAdABzAAANOgAgACAAIAAgACAAAAkwV0BXe3yLVwEJVAB5AHAAZQAADzoAIAAgACAAIAAgACAAAAV7fCtSAQtDAGwAYQBzAHMAAAeMTtuPNlIBDUIAaQBuAGEAcgB5AAAbxmKXXypZjniGTiAAKAA7TjpncGUNTrONKQABQXQAbwBvACAAbQBhAG4AeQAgAHMAdQBiAG4AZQB0AHMAIAAoAG4AbwAgAGgAbwBzAHQAcwAgAGwAZQBmAHQAKQAABcZiBlIBC3MAcABsAGkAdAAAByAAOk4gAAENIABpAG4AdABvACAAAAkgACpOIAAvAAEJIAB4ACAALwAAAzoAAAcgACAAIAAACSAAIAAgACgAAEVNUgB/IAAgACAAIACpYwF4IAAgACAAIAAgACAAIAAgACAAIAAgACAAIAAgAO9TKHU7TjpnIAAgACAAIAAgABqQTZEmewFbcAByAGUAZgBpAHgAIAAgAG0AYQBzAGsAIAAgACAAIAAgACAAIAAgACAAIAAgACAAaABvAHMAdABzACAAIAAgACAAIAAgACAAIAB3AGkAbABkAGMAYQByAGQAAAc7TjpnDVQBCUgAbwBzAHQAAAVdACAAABEgACAASQBQAHYANAA6ACAAAAcgAC8AIAAABVF/c1EBD0cAYQB0AGUAdwBhAHkAAA8gACAARABOAFMAOgAgAAAFTgBTAAALQwBOAEEATQBFAAAHUABUAFIAAAVNAFgAAAdUAFgAVAAACUEAQQBBAEEAABFiAGEAZAAgAHQAeQBwAGUAABVEAE4AUwAgAHIAYwBvAGQAZQA9AAAXIAAoAE4AWABEAE8ATQBBAEkATgApAAAHIAB8ACAAAAt0AHkAcABlACAAAAUgACgAAA8gAGIAeQB0AGUAcwApAAAPIAAgACAAdAB0AGwAPQAAB+BlsItVXwEVbgBvACAAcgBlAGMAbwByAGQAcwAAG2QAbgBzACAAbgBhAG0AZQAgAGwAbwBvAHAAABFoAHQAdABwAHMAOgAvAC8AAB1XAGcASQBtAGUALQBOAGUAdABUAG8AbwBsAHMAAQ0gACAAKAAtAD4AIAABC0gAVABUAFAAIAAADVMAZQByAHYAZQByAAARUwBlAHIAdgBlAHIAOgAgAAAdQwBvAG4AdABlAG4AdAAtAFQAeQBwAGUAOgAgAAENQgBvAGQAeQA6ACAAAA0gAGIAeQB0AGUAcwAADVQAVABGAEIAOgAgAAAZbQBzACAAIAAgAFQAbwB0AGEAbAA6ACAAAAtFAHIAcgA6ACAAACtoAHQAdABwAHMAOgAvAC8AYQBwAGkALgBpAHAAaQBmAHkALgBvAHIAZwAAE24AbwB0AGUAcwAuAHQAeAB0AAADIwAABVgAMgAABUgAIAAACSAAIABTACAAAAslACAAIABWACAAAAMlAAAFWwAvAAALKgAuAHQAeAB0AABBXgAoAGMAbwBkAGUAfABuAGEAbQBlAHwAZABlAHMAYwApAFwAcwAqAFsAPQA6AF0AXABzACoAKAAuACsAKQAkAAAJYwBvAGQAZQAACW4AYQBtAGUAAA1jAHMAaABhAHIAcAAAKXAAbAB1AGcAaQBuAHMALQBkAGkAcwBhAGIAbABlAGQALgB0AHgAdAABCYxbEGIsACAAAQ1kAG8AbgBlACwAIAAADSAAKk5la6SaMVkljQEfIABzAHQAZQBwACgAcwApACAAZgBhAGkAbABlAGQAAAlnYkyIjFsQYgEJZABvAG4AZQAAB/Jd1lOIbQEPYQBiAG8AcgB0AGUAZAAACwBfy1lnYkyIJiABEXIAdQBuAG4AaQBuAGcAJiABF1cAaQBuAGQAbwB3AHMAQgBhAHMAZQAAIVAAcgBlAHMAZQBuAHQAYQB0AGkAbwBuAEMAbwByAGUAACtQAHIAZQBzAGUAbgB0AGEAdABpAG8AbgBGAHIAYQBtAGUAdwBvAHIAawAAgIcsACAAVgBlAHIAcwBpAG8AbgA9ADQALgAwAC4AMAAuADAALAAgAEMAdQBsAHQAdQByAGUAPQBuAGUAdQB0AHIAYQBsACwAIABQAHUAYgBsAGkAYwBLAGUAeQBUAG8AawBlAG4APQAzADEAYgBmADMAOAA1ADYAYQBkADMANgA0AGUAMwA1AACAnVMAeQBzAHQAZQBtAC4AWABhAG0AbAAsACAAVgBlAHIAcwBpAG8AbgA9ADQALgAwAC4AMAAuADAALAAgAEMAdQBsAHQAdQByAGUAPQBuAGUAdQB0AHIAYQBsACwAIABQAHUAYgBsAGkAYwBLAGUAeQBUAG8AawBlAG4APQBiADcANwBhADUAYwA1ADYAMQA5ADMANABlADAAOAA5AAALbABpAG4AZQAgAAAFOwAgAAAHUgB1AG4AAF9uAG8AIAAnAHAAdQBiAGwAaQBjACAAcwB0AGEAdABpAGMAIAB2AG8AaQBkACAAUgB1AG4AKAApACcAIABlAG4AdAByAHkAIABwAG8AaQBuAHQAIABmAG8AdQBuAGQAAQ3SY/ZO0I9MiPpRGZUBGVAAbAB1AGcAaQBuACAAZQByAHIAbwByAAAN0mP2ThZ/0YsxWSWNAStQAGwAdQBnAGkAbgAgAGMAbwBtAHAAaQBsAGUAIABmAGEAaQBsAGUAZAAAG1cAZwBUAHIAYQB5AFAAbAB1AGcAaQBuAHMAAAV6AGgAABVTAHkAcwB0AGUAbQAuAGQAbABsAAAxUwB5AHMAdABlAG0ALgBXAGkAbgBkAG8A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AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAsAEADAAAABA+AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=='
