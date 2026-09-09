============================================================
 wgime-py 纯 Python 分发包 (package) - 可整体拷贝的生产目录
============================================================

本目录是构建产物，由 `wgime-py-pure\build-package.ps1` 生成，
**不要手改本目录文件**（下次构建会被整体清空重建）。
改源位置：

  * 主程序/模块      wgime-py-pure\main.py / win.py / bar.py / ...（构建时内嵌进 wgime-py.py）
  * 插件 .py         wgime-py-pure\plugins\*.py（本目录 plugins\ 里同名 .py 的源）
  * 插件 .txt        wgime-py-pure\..\plugins\*.txt（仓库根 plugins\，步骤 DSL / [python] / [csharp]）
  * config.txt       wgime-py-pure\..\config.txt（仓库根）
  * tools.txt        wgime-py-pure\..\tools.txt（仓库根）
  * 码表 dicts\      wgime-py-pure\..\py.txt / wb.txt / ec.txt / ...（仓库根）

重建：powershell -NoProfile -File wgime-py-pure\build-package.ps1

用法：python wgime-py.py        （被 python.exe 启动会自动用 pythonw.exe 无控制台重启）
      WGIME_DEBUG=1 python wgime-py.py   （保留控制台看错误）

目录说明:

  wgime-py.py            单文件主程序（内嵌全部模块 + pystray/uiautomation/comtypes zip）
  dicts\                 码表（构建时从仓库根复制）
  plugins\               插件目录（步骤 DSL *.txt + 纯 Python *.py）
  config.txt / tools.txt 配置 / 工具箱模板（构建时从仓库根复制）
  run-csharp-plugin.ps1  [csharp] 插件 PowerShell sidecar（回退路径）

数据目录 %LOCALAPPDATA%\wgime-py（删除即恢复初始状态；Store 版 Python 自动切 ~\wgime-py）。
首次运行自动播种 tools.txt / plugins\ 示例（不覆盖已有文件）。
============================================================
