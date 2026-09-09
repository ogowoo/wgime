============================================================
 Wg 成品包 (release) - 输入法 (含托盘工具箱运行模式)
============================================================

本目录只放成品, 直接拿去用; 不含构建脚本 / 测试 / 源码中间物。
每个分发文件都是"一个程序两种运行模式", 按环境取形态:

  wgime.bat     bat 版带载荷 - 双击即用 (内嵌 C# + 基础码表, 自包含)
  WgIme.ps1     ps1 版 - powershell -File WgIme.ps1 (内嵌 base64 DLL,
                命令行干净, 规避 EDR 告警; 含全部词库)

运行模式由 config.txt 的 mode 键定义 (缺省 ime):

  mode = ime    输入法: 键盘钩子 + 候选窗 + 组字 (默认)
  mode = tray   托盘工具箱 (原独立 WgTray): 不装键盘钩子, 托盘"工"字
                图标 + 工具菜单 (工具箱 / 内置工具 / 插件管理 / config 应用)

托盘菜单「运行模式」可随时切换 (写 config + 自动重启生效)。

用法:

  * 输入法: 双击 wgime.bat; 或 powershell -File WgIme.ps1 (config mode=ime)
  * 托盘工具箱: config.txt 设 mode = tray 后启动 (同文件, 托盘"工"字图标)
  * 开机自启: 程序不自带自启注册 (无 -Install / 无计划任务 / 菜单无
    "开机自启"项); 需要自启时由你自己的工具 (任务计划/启动文件夹)
    挂上启动命令即可:
      powershell.exe -NoProfile -ExecutionPolicy Bypass -File WgIme.ps1

文件说明:

  config.txt    共用配置 (mode=ime|tray / 输入法键 / app= 应用 / hotkey_*)
  tools.txt     工具箱配置 ([tab 标签页] / [按钮名] / code = xxx 启动编码 / 步骤行)
  plugins\      插件目录 (步骤 DSL / 插件)
  docs\         文档: 使用说明 / 技术文档 / 插件规范 / 窗体设计语言
  README.txt    本文档

首次运行自动播种 tools.txt / plugins\ / config.txt 示例 (不覆盖已有文件)。
数据目录 %LOCALAPPDATA%\wgime (删除即恢复初始状态)。
============================================================
