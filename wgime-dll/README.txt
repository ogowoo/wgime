============================================================
 WgIme - DLL 版 (完整输入法, 薄 bat 启动器)
============================================================

用法: 把本文件夹拷到任意位置, 双击 WgIme.bat 即运行
      (WgIme.dll 必须与 WgIme.bat 同目录; 完整输入法:
       拼音/五笔/混合/英汉词典、词频学习、简拼、模糊音、造词、
       码表导入等全部功能与原 wgime.bat 一致)。
      首次启动会自动在 WgIme.bat 旁边生成 WgIme.lnk 快捷方式
      (指向本 bat, 最小化启动、减少控制台闪烁; 每台机器首次
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
  * 基础词库 (拼音单字 2.7 万 / 五笔单字 1.7 万 / 拼音词语表 /
    词频权重 / 英汉表, 共约 1.3MB) 编进 WgIme.dll —— 删掉 txt 文件
    照样能打字 (与原版内嵌表内容逐字节相同, 词典缓存 wgime.mb 通用)。
  * 扩展码表已随附: py.txt / wb.txt / ec.txt / import_py.txt /
    import_wb.txt (与原版同目录文件逐字节相同, 启动自动叠加;
    ec.txt 提供完整英汉词典模式)。删除它们不影响基础打字, 只是
    词语/英汉候选减少。
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
