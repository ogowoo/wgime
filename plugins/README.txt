============================================================
 WgIme 插件速览 (plugins\*.txt)
============================================================

插件 = 纯文本文件, 把一个启动编码绑定到一组动作:

  code = qls            ; 启动编码 (小写 a-z, 必填, 唯一)
  name = 清空回收站      ; 显示名 (必填)
  desc = 说明            ; 可选

  <步骤>                 ; 头部之后直到文件末尾都是步骤

用法: 输入编码 -> 候选条出现 ▶<name> -> 空格选中 -> 后台执行, 气泡报结果。
改完/新增后: 托盘"配置 -> 重载配置"即时生效。
管理: 输入 plugins (或 cjgl) 打开插件管理窗体 (列表/编辑/删除/新建/重载)。

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
 %LOCALAPPDATA%\wgime\provisioned.done 后重启 wgime.bat。)