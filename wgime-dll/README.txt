============================================================
 WgIme - DLL 版 (完整输入法, 薄 bat 启动器)
============================================================

用法: 把本文件夹拷到任意位置, 双击 WgIme.bat 即运行
      (WgIme.dll 必须与 WgIme.bat 同目录; 完整输入法:
       拼音/五笔/混合/英汉词典、词频学习、简拼、模糊音、造词、
       码表导入等全部功能与原 wgime.bat 一致)。
      首次启动会自动在 WgIme.bat 旁边生成 WgIme.lnk 快捷方式
      (直接以 PowerShell 加载 DLL 启动, 不经 bat, 无控制台闪烁;
      图标取自 WgIme.dll 内嵌资源, 无需 .ico 文件; 每台机器首次
      运行时生成, 不会入库, 删除后下次启动会重新生成)。

与其他版本的区别 (功能完全一致, 只是程序集和词库怎么来):

  | 版本 | 启动方式 |
  |---|---|
  | 本版 (DLL 版) | 薄 bat 加载预编译 WgIme.dll; 基础词库(单字+词语表)编在 DLL 内 |
  | wgime.bat | bat 自解压 + Invoke-Expression + 内嵌 base64 预编译 DLL |
  | wgtray-dll\ | 薄 bat + 托盘版 DLL (无输入法) |

本版特点:

  * 启动器只有 3 行: Add-Type -Path 加载 DLL + 运行入口。
    无 base64 PE 载荷 / 无 FromBase64String / 无 Invoke-Expression /
    无运行时编译 / 无 -ExecutionPolicy Bypass (-Command 不受策略门控,
    默认 Restricted 策略的电脑也能双击运行)。
  * 基础词库 + 全部扩展码表 (py.txt / wb.txt / ec.txt / import_*.txt,
    共约 3000 万字符) 已**合并编入 WgIme.dll** (压缩 trailer, 启动时
    解压合并, 与"带 txt 文件"的词典逐字等价, 词典缓存 wgime.mb 通用)。
    **文件夹不需要任何 txt 码表文件**; 以后想加新码表, 仍可把同名
    txt 放到本文件夹, 会按原逻辑叠加。
  * 重建含扩展码表的 DLL 需要码表源: 构建脚本优先读 wgime-dll\ 内的
    py.txt 等, 其次读仓库根目录的本地副本 (均不存在时仅编入内置基础表)。
  * 用户数据目录 %LOCALAPPDATA%\wgime 照旧 (词频/用户词/便签/颜色等,
    启动时自动创建; 与 wgtray 各版共用, 与原 wgime.bat 也共用)。

已知差异:

  * "固化码表" (托盘 词库 -> 固化码表) 在本版不可用: 词库已编进 DLL,
    没有可写入的 here-string, 点击会报"固化失败"提示 —— 需要固化请用
    wgime.bat 原版。导入码表/造词/用户词表等功能不受影响 (写 txt/数据目录)。
  * 首次运行不自动播种 tools.txt / plugins (本文件夹已随附);
    全新部署时从仓库拷贝 tools.txt 与 plugins\ 即可。

重建: powershell.exe -NoProfile -ExecutionPolicy Bypass -File build-wgime-dll.ps1
      (需要本地有 wgime.bat 作为源码, git checkout master -- wgime.bat 恢复)
测试: powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-dll.tests.ps1
============================================================
