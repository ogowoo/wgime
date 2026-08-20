============================================================
 Wg - 输入法 + 托盘工具箱 (单目录)
============================================================

本目录把输入法与托盘工具箱合并在一起, 只留一个入口 install.bat:

  WgIme.dll    完整输入法 (拼音/五笔/混合/英汉词典, 全部词库
               编入 DLL, 含图标资源; 无需任何 txt 码表文件)
  WgIme.bat    输入法启动器 (install.bat 调用; 也可单独使用)
  WgTray.ps1   托盘工具箱单文件载荷版 (无输入法): PS 引导 + 内嵌
               base64 DLL 载荷, 自动解出到 %LOCALAPPDATA%\wgime\
               WgTray.<md5>.dll 并加载; 无独立 dll 文件
  install.bat  单入口: 首次运行启动两者

用法:

  * 双击 install.bat  -> 启动 输入法 + 托盘工具箱 (默认)
  * install.bat ime   -> 只启动输入法
  * install.bat tray  -> 只启动托盘工具箱
  * 开机自启 (托盘版, 计划任务): 运行一次
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgTray.ps1 -Install
    注册登录时启动的计划任务 (schtasks ONLOGON);
    取消自启:  WgTray.ps1 -RemoveTask
    也可在托盘菜单 配置 -> 开机自启 里开关 (同样走计划任务)

文件说明:

  config.txt    共用配置 (WgIme 的输入法键 + WgTray 的 app=/hotkey_*;
                各自只读自己的键, 互相兼容)
  tools.txt     工具箱配置 (托盘版使用; 缺失时首次运行自动播种)
  plugins\      插件 (两版共用, 规范见仓库 docs\WGIME_插件规范.md)
  README.txt    本文档

托盘版为什么是 ps1 载荷: 启动命令行只有
  powershell ... -File WgTray.ps1
没有任何 Add-Type/.dll/::Run 明文, 规避 EDR 对"隐藏 PowerShell 加载
DLL"行为模式的命令行告警; 开机自启用计划任务而非 Startup 快捷方式。

重建 (需要 Windows PowerShell 5.1 与 wgime.bat 源码):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-dll.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1
测试:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-dll.tests.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1
============================================================
