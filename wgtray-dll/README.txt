============================================================
 WgTray - DLL 版 (托盘工具箱, 无输入法)
============================================================

用法: 把本文件夹拷到任意位置, 双击 WgTray.bat 即运行
      (托盘出现"工"字图标; WgTray.dll 必须与 WgTray.bat 同目录)。
      首次启动会自动在 WgTray.bat 旁边生成 WgTray.lnk 快捷方式
      (直接以 PowerShell 加载 DLL 启动, 不经 bat, 无控制台闪烁;
      图标取自 WgTray.dll 内嵌资源, 无需 .ico 文件; 每台机器首次
      运行时生成, 不会入库, 删除后下次启动会重新生成)。

与其他版本的区别 (功能完全一致, 只是程序集怎么来):

  | 版本 | 文件 | 启动方式 |
  |---|---|---|
  | 本版 (DLL 版) | WgTray.bat + WgTray.dll | 加载预编译 DLL, 无任何运行时动作 |
  | wgtray.bat | 单文件 | 内嵌 base64 预编译 DLL, 解码落盘后加载 |
  | wgtray-nopayload.bat | 单文件 | 内嵌 C# 源码, 启动时内存编译 |

为什么本版最不容易被误报:

  * 启动器只有 3 行: Add-Type -Path 加载 DLL + 运行入口。
    没有 base64 PE 载荷 / 没有 FromBase64String / 没有 Invoke-Expression /
    没有运行时编译 / 没有 -ExecutionPolicy Bypass。
  * 杀软眼里这就是一个"管理脚本加载辅助程序集"的普通模式,
    WgTray.dll 是一份正常的 .NET WinForms 程序集。
  * 不受执行策略限制 (-Command 不被策略门控), 默认 Restricted 策略
    的电脑也能双击运行。
  * 受限语言模式 (ConstrainedLanguage, 公司/学校锁定机) 下也能跑:
    Add-Type -Path 加载 DLL 是允许的 (这正是原带载荷版的兜底原理)。

首次运行自动播种 tools.txt 与 plugins\ 示例 (标记
%LOCALAPPDATA%\wgime\provisioned-tray-dll.done, 不覆盖已有文件)。

进一步降低误报:

  * 代码签名 (推荐): 对 WgTray.dll 做 Authenticode 签名
    (Set-AuthenticodeSignature 或 signtool), 并把你的证书装进目标机
    的"受信任的发布者"。签名后 SmartScreen/多数杀软会显著降低关注。
  * 放到受信任路径 (如 Program Files) 运行。
  * 若仍被某杀软误报: 向该厂商提交误报申诉 (合法软件的标准流程),
    Defender 有公开的误报提交中心。

重建: powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgtray-dll.ps1
      (需要本地有 wgime.bat 作为源码, git checkout master -- wgime.bat 恢复)
测试: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-dll.tests.ps1
============================================================
