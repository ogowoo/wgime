============================================================
 WgTray - PS1 版 (单文件, 托盘工具箱, 无输入法)
============================================================

用法: 右键本文件 -> "使用 PowerShell 运行" (Run with PowerShell)
      (托盘出现"工"字图标)。这是系统自带入口, 自带 Process 级
      执行策略放行, 默认 Restricted 策略的电脑也能直接运行;
      脚本会自行隐藏控制台窗口。

与其他版本的区别 (功能完全一致, 只是程序集怎么来):

  | 版本 | 文件 | 启动方式 |
  |---|---|---|
  | 本版 (PS1 版) | WgTray.ps1 单文件 | 内嵌 C# 源码, 启动时内存编译 |
  | wgtray.bat | 单文件 bat | bat 自解压 + Invoke-Expression + 内嵌 base64 载荷 |
  | wgtray-nopayload.bat | 单文件 bat | bat 自解压 + Invoke-Expression + 内存编译 |
  | wgtray-dll\ | bat + dll | 加载预编译 DLL (最干净) |

本版特点:

  * 单文件、纯文本、无 base64、无自解压链 (没有 Invoke-Expression,
    没有 -ExecutionPolicy Bypass, 没有 -WindowStyle Hidden 参数),
    源码可直接审查。
  * 双击不会跑——ps1 双击默认打开编辑器, 用右键"使用 PowerShell 运行"
    启动; 或对脚本签名后建快捷方式。
  * 受限语言模式 (ConstrainedLanguage) 下无法启动 (Add-Type 被禁止)
    ——锁定机请用 wgtray.bat 或 wgtray-dll\ 版。

签名 (强烈推荐, 进一步降低误报):

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File sign-wgtray.ps1
  # 自动创建自签代码签名证书 (CurrentUser, 无需管理员), 装进本机
  # "受信任的发布者", 并给 WgTray.ps1 签名。
  # 其他机器: 导出证书导入其"受信任的发布者"即可 (脚本会打印命令)。

  签名后: AllSigned/RemoteSigned 策略直接运行、SmartScreen 不再拦、
  多数杀软对受信任发布者的脚本显著降低关注。
  若仍被某杀软误报: 向该厂商提交误报申诉 (合法软件的标准流程)。

重建: powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray-ps1.ps1
      (需要本地有 wgime.bat 作为源码, git checkout master -- wgime.bat 恢复)
测试: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1
============================================================
