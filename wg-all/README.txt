============================================================
 Wg - 单文件双运行模式 (单目录, ps1 载荷版)
============================================================

本目录收敛为一个程序两种模式, 只留一个入口 install.bat:

  WgIme.ps1   单一程序 (单文件 ps1 载荷版 - PS 引导 + 内嵌 base64
              DLL, 含全部词库/图标/emoji 资源, 运行时解出到
              %LOCALAPPDATA%\wgime\WgIme.<md5>.dll 并加载):
                ime 模式  = 完整输入法 (拼音/五笔/混合/英汉词典)
                tray 模式 = 托盘工具箱 (tools.txt 工具箱 / 插件 /
                            内置工具 / config 应用) - 不装键盘 hook
  install.bat 单入口 (见用法)

运行模式由 config.txt 的 mode 键定义 (mode = ime|tray, 缺省 ime):
托盘菜单「运行模式」可随时切换 (写 config + 自动重启)。

用法:

  * 双击 install.bat     -> 按当前 config mode 启动
  * install.bat ime      -> 强制 mode=ime 并启动
  * install.bat tray     -> 强制 mode=tray 并启动
  * 开机自启: 程序不自带自启注册 (无 -Install / 无计划任务 / 托盘菜单
    无"开机自启"项); 需要自启时由你自己的工具挂任务, 启动命令:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1

文件说明:

  config.txt    共用配置 (mode/showcode/paste/...; app=/hotkey_* 工具用)
  tools.txt     工具箱配置 (缺失时首次运行自动播种)
  plugins\      插件 (规范见仓库 docs\WGIME_插件规范.md)
  README.txt    本文档

为什么是 ps1 载荷版: 启动命令行只有
  powershell ... -File WgIme.ps1
没有任何 Add-Type/.dll/::Run 明文, 规避 EDR 对"隐藏 PowerShell 加载
DLL"行为模式的命令行告警。不生成启动快捷方式, 不自带自启注册 -
启动一律走 ps1 (install.bat / 你自己的自启工具 / 手动 -File)。

重建 (需要 Windows PowerShell 5.1 与 wgime.bat 源码):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-ps1.ps1
测试:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1
============================================================
