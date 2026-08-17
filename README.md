# WgIme

**免安装的单文件悬浮输入法** —— 双击 `wgime.bat` 即可使用，支持拼音 / 五笔 / 混合 / 英汉词典四种模式，带词频学习、简拼、模糊音、造词、码表导入与固化。

A single-file, install-free overlay IME for Windows: pinyin / wubi / mixed / EN-CN dictionary modes, with frequency learning, acronym pinyin, fuzzy pinyin, word creation, code-table import and bake-in.

## 特性

- **单文件分发**：一个 `wgime.bat` 包含全部代码（cmd 引导 + PowerShell + 内嵌 C# + 预编译 DLL 载荷），免安装、免注册、不产生 exe
- **全单字内嵌**：内置拼音 26,719 字 / 五笔 17,366 字（BMP CJK + 〇 + 扩展A区基本打尽）——删掉所有 txt 词库文件照样能打出几乎所有汉字；txt 提供词语与排序
- **四种模式**：混合（默认，五笔优先补拼音）/ 拼音 / 五笔 / 英汉词典
- **智能输入**：整句连打（`nihaoshijie` → 你好世界，6 万词表 + 词频最佳路径）、联想（学习个人习惯、可连续联想）、词频学习、简拼（`zg` → 中国）、模糊音（zh/z、ang/an、n/l…）、双拼（小鹤/自然码/微软）、以词定字
- **造词**：手动（Ctrl+Alt+C）/ 批量（文件导入）/ 自动（90 秒内连续选字自动组词）
- **码表导入**：Rime `*.dict.yaml`、编码在前/词在前 txt、英汉词表，自动识别 UTF-8/GB18030，热重载
- **固化码表**：一键把合并词库烘焙进 bat 内置表（滚动 7 份备份），之后可删除 txt 源文件
- **应用启动器**：编码唤出应用——内置 `jsq` 计算器 / `itools` 工具箱 / `net` 网络工具 / `clip` 剪贴板历史 / `bj` 便签 / `ys` 颜色拾取 / `plugins` 插件管理；config.txt 可挂任意程序/目录/网址
- **插件系统**：`plugins\*.txt` 纯文本插件（自动化步骤 DSL 或内嵌 C#/WinForms，内存编译），首次运行自动播种示例与规范说明
- **更多**：中文标点、vf 符号/emoji 面板（彩色 Fluent emoji）、v 模式（大写金额/千分位）、简繁切换、rq/sj/xq 动态候选、五笔 z 通配符、反查编码、自定义短语、快捷键全配置化、候选窗光标跟随（UIA 三级回退）、空闲自动隐藏、微信 4.x 等 Qt 应用标点吞字修复（keyfix）

## 快速开始

1. 双击 `wgime.bat`（任务栏托盘出现"中"字图标）
2. 在任意文本框输入拼音/五笔，候选条跟随光标出现（可拖动；`followcaret = 0` 恢复固定位置，空闲自动隐藏）
3. `Shift` 轻点开关输入法，`` Ctrl+` `` 切换模式
4. 详细说明见 [docs/WGIME_使用说明.md](docs/WGIME_使用说明.md)

## 文件说明

| 文件 | 作用 |
|---|---|
| `wgime.bat` | 程序本体（自包含） |
| `config.txt` | 用户配置（模糊音/短语/上屏方式/快捷键） |
| `py.txt` / `wb.txt` / `ec.txt` | 扩展词典（`码 词1 词2…`，UTF-8，可选） |
| `import_py.txt` / `import_wb.txt` | 码表导入产物（Gboard 词库转换） |
| `tools.txt` | 工具箱配置（首次运行自动播种示例） |
| `plugins/` | 插件目录（步骤 DSL / C# 插件；播种含 README 规范与示例） |
| `build-full-singles.ps1` | 重建全单字内嵌码表（数据源见下表） |
| `rebuild.ps1` | 修改内嵌 C# 后重建 DLL 载荷（必须用 Windows PowerShell 5.1） |
| `tests/` | 回归测试（核心夹具 + 真实词库 e2e + 载荷一致性 + 真实微信注入 + 光标/插件/工具箱/网络工具等） |
| `docs/` | 使用说明 + 技术文档 + 插件规范 + TSF 评估 |

## 开发

- 修改内嵌 C# 后必须运行 `rebuild.ps1`（Windows PowerShell 5.1），否则运行时仍是旧代码
- 运行测试：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime.tests.ps1`
- 文件约束：纯 LF / 无 BOM / UTF-8（详见技术文档 §11.2）

## 系统要求

Windows 10/11，Windows PowerShell 5.1（系统自带），无需安装。

## 技术架构

```
wgime.bat
├─ cmd 引导 (隐藏窗口自举)
├─ PowerShell 引导 + 内嵌三表 (拼音/五笔/英汉)
├─ C# 源码: KeyBordHook (WH_KEYBOARD_LL 全局钩子) + WordBoard (候选条/托盘) + 词典管线
└─ base64 预编译 DLL 载荷 (ConstrainedLanguage 机器兜底, MD5 版本戳缓存)
```

详见 [docs/WGIME_技术文档.md](docs/WGIME_技术文档.md)。

## 数据来源与许可

本仓库随附的词库与资源数据来源如下，使用前请确认符合各自许可：

| 文件 | 来源 | 说明 |
|---|---|---|
| `py.txt` | 内置基础拼音表 + **Gboard 词库**（按词频取前 40 万词） | 拼音扩展词库，`码 词1 词2…` |
| `import_py.txt` | **Gboard 词库** 150 万词转拼音（与内置一致率 96.7%，异读差异） | 码表导入产物，启动自动叠加 |
| `import_wb.txt` | **Gboard 词库** 150 万词按 86 组词规则 + 内置双字词投票取码（准确率 100%） | 五笔扩展，启动自动叠加 |
| `ec.txt` | **ECDICT**（[skywind3000/ECDICT](https://github.com/skywind3000/ECDICT)，340 万词条，MIT 协议），过滤 `^[a-z]{1,32}$` 纯单词 33.4 万条 | 英汉词典模式 |
| `wgime.bat` 内嵌 emoji | **Microsoft Fluent Emoji 3D**（微软官方开源，MIT 协议，Windows 11 同款风格） | vf 面板彩色 emoji 图片 |
| `wgime.bat` 内置简繁映射 | **OpenCC** TSCharacters 单字映射（3602 对） | 简繁输出 |
| `wgime.bat` 内嵌全单字拼音 | **pinyin-data**（[mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data)，Unihan 派生，MIT 协议），声调符号剥离、ü→v | 由 `build-full-singles.ps1` 合并进内嵌表 |

**注意**：
- Gboard 词库由 Google 提供，转换后的词表仅用于个人输入法使用；如涉及商业分发请自行确认 Gboard 词库的许可条款。
- ECDICT 与 pinyin-data 均为 MIT 协议。
- 删除以上任一 txt 词库文件，`wgime.bat` 仍可独立运行（**内嵌全单字表**，只是词语候选减少）；需要完整词库时再放回同名文件即可。

## License

代码部分（`wgime.bat`、`rebuild.ps1`、`tests/`、`docs/`）遵循 MIT 协议，详情见各文件头注释。随附词库数据的许可见上表。

