============================================================
 Wg - 输入法 + 托盘工具箱 (单目录, 双 ps1 载荷版)
============================================================

本目录把输入法与托盘工具箱合并在一起, 只留一个入口 install.bat:

  WgIme.ps1   完整输入法 (拼音/五笔/混合/英汉词典): 单文件 ps1
              载荷版 - PS 引导 + 内嵌 base64 DLL (含全部词库/图标/
              emoji 资源), 运行时解出到
              %LOCALAPPDATA%\wgime\WgIme.<md5>.dll 并加载
  WgTray.ps1  托盘工具箱 (无输入法: tools.txt 工具箱 / 插件 /
              内置工具 / config 应用 / 全局快捷键): 同样单文件 ps1
              载荷版, 解出 WgTray.<md5>.dll
  install.bat 单入口: 启动 IME + 托盘 (all/ime/tray 三种模式)

用法:

  * 双击 install.bat  -> 启动 输入法 + 托盘工具箱 (默认)
  * install.bat ime   -> 只启动输入法
  * install.bat tray  -> 只启动托盘工具箱
  * 开机自启 (计划任务, 非 Startup 快捷方式), 各运行一次:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1 -Install
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgTray.ps1 -Install
    注册登录时启动的计划任务 (schtasks ONLOGON);
    取消自启:  相应 ps1 加 -RemoveTask
    托盘菜单"配置 -> 开机自启"开关也走同一计划任务

文件说明:

  config.txt    共用配置 (WgIme 的输入法键 + WgTray 的 app=/hotkey_*;
                各自只读自己的键, 互相兼容)
  tools.txt     工具箱配置 (托盘版使用; 缺失时首次运行自动播种)
  plugins\      插件 (两版共用, 规范见仓库 docs\WGIME_插件规范.md)
  README.txt    本文档

为什么是 ps1 载荷版: 启动命令行只有
  powershell ... -File WgIme.ps1 / WgTray.ps1
没有任何 Add-Type/.dll/::Run 明文, 规避 EDR 对"隐藏 PowerShell 加载
DLL"行为模式的命令行告警。不生成启动快捷方式 - 启动一律走 ps1
(install.bat / 计划任务 / 手动 -File)。

重建 (需要 Windows PowerShell 5.1 与 wgime.bat 源码):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-ps1.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray.ps1
测试:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1
============================================================
