============================================================
 Wg 成品包 (release) - 输入法 + 托盘工具箱
============================================================

本目录只放成品, 直接拿去用; 不含构建脚本 / 测试 / 源码中间物。
两个程序, 各两种形态 (功能一致, 按环境取舍):

  输入法 WgIme:
    wgime.bat     bat 版带载荷 - 双击即用 (内嵌 C# + 基础码表, 自包含)
    WgIme.ps1     ps1 版 - powershell -File WgIme.ps1 (内嵌 base64 DLL,
                  命令行干净, 规避 EDR 告警; 含全部词库)

  托盘工具箱 WgTray (无输入法):
    wgtray.bat           bat 版带预编译 DLL 载荷 (保底所有机器)
    wgtray-nopayload.bat bat 纯源码版 (启动内存编译, 杀软检测面小)
    WgTray.ps1           ps1 版

用法:

  * 输入法: 双击 wgime.bat; 或 powershell -File WgIme.ps1
  * 托盘:   双击 wgtray.bat / wgtray-nopayload.bat; 或 powershell -File WgTray.ps1
  * 开机自启 (计划任务 schtasks ONLOGON), 各运行一次:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1 -Install
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgTray.ps1 -Install
    取消自启: 相应 ps1 加 -RemoveTask
    托盘菜单 "选项 -> 开机自启" 开关也走同一计划任务

文件说明:

  config.txt    共用配置 (WgIme 输入法键 + WgTray 的 app=/hotkey_*)
  tools.txt     工具箱配置 ([tab 标签页] / [按钮名] / code = xxx 启动编码 / 步骤行)
  plugins\      插件目录 (步骤 DSL / C# 插件)
  README.txt    本文档

首次运行自动播种 tools.txt / plugins\ / config.txt 示例 (不覆盖已有文件)。
数据目录 %LOCALAPPDATA%\wgime (删除即恢复初始状态)。

详细说明见仓库 docs\ (使用说明 / 技术文档 / 插件规范 / 插件 UI 规范)。
============================================================
