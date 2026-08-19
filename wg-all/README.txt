============================================================
 Wg - 输入法 + 托盘工具箱 (单目录双 DLL)
============================================================

本目录把两个 DLL 版合并在一起, 只留一个入口 install.bat:

  WgIme.dll    完整输入法 (拼音/五笔/混合/英汉词典, 全部词库
               编入 DLL, 含图标资源; 无需任何 txt 码表文件)
  WgTray.dll   托盘工具箱 (无输入法: tools.txt 工具箱 / 插件 /
               内置工具 / config 应用 / 全局快捷键, 含图标资源)
  install.bat  单入口: 首次运行启动两者并生成两个启动快捷方式

用法:

  * 双击 install.bat  -> 启动 输入法 + 托盘工具箱 (默认)
  * install.bat ime   -> 只启动输入法
  * install.bat tray  -> 只启动托盘工具箱
  * 首次运行 (默认全部) 会自动在目录内生成
    WgIme.lnk / WgTray.lnk 两个启动快捷方式
    (直接以 PowerShell 加载对应 DLL, 不经 bat, 无控制台闪烁;
     图标取自 DLL 内嵌资源; 每台机器首次生成, 删除后下次启动重建)

文件说明:

  config.txt    共用配置 (WgIme 的输入法键 + WgTray 的 app=/hotkey_*;
                各自只读自己的键, 互相兼容)
  tools.txt     工具箱配置 (托盘版使用; 缺失时首次运行自动播种)
  plugins\      插件 (两版共用, 规范见仓库 docs\WGIME_插件规范.md)
  README.txt    本文档

与旧版的关系: 本目录 = 原 wgime-dll\ + wgtray-dll\ 的合并;
WgIme.bat / WgTray.bat 是各自的内置启动器 (install.bat 调用其同款
命令; 也便于单独使用/测试)。

注意: 固化码表 (输入法托盘菜单) 在本部署不可用 (词库已编入 DLL)。

重建 (需要 Windows PowerShell 5.1 与 wgime.bat 源码):
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-dll.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray-dll.ps1
测试:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-dll.tests.ps1
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-dll.tests.ps1
============================================================
