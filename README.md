# WgIme

**免安装的单文件悬浮输入法** —— 双击 `wgime.bat` 即可使用，支持拼音 / 五笔 / 混合 / 英汉词典四种模式，带词频学习、简拼、模糊音、造词、码表导入与固化。

A single-file, install-free overlay IME for Windows: pinyin / wubi / mixed / EN-CN dictionary modes, with frequency learning, acronym pinyin, fuzzy pinyin, word creation, code-table import and bake-in.

## 特性

- **单文件分发**：一个 `wgime.bat` 包含全部代码（cmd 引导 + PowerShell + 内嵌 C# + 预编译 DLL 载荷），免安装、免注册、不产生 exe
- **四种模式**：混合（默认，五笔优先补拼音）/ 拼音 / 五笔 / 英汉词典
- **智能输入**：词频学习、简拼（`zg` → 中国）、模糊音（zh/z、ang/an、n/l…）、双拼（小鹤/自然码/微软）、以词定字
- **造词**：手动（Ctrl+Alt+C）/ 批量（文件导入）/ 自动（90 秒内连续选字自动组词）
- **码表导入**：Rime `*.dict.yaml`、编码在前/词在前 txt、英汉词表，自动识别 UTF-8/GB18030，热重载
- **固化码表**：一键把合并词库烘焙进 bat 内置表（滚动 7 份备份），之后可删除 txt 源文件
- **更多**：中文标点、vf 符号/emoji 面板（彩色 Fluent emoji）、v 模式（大写金额/千分位）、简繁切换、rq/sj/xq 动态候选、五笔 z 通配符、反查编码、自定义短语、快捷键全配置化

## 快速开始

1. 双击 `wgime.bat`（任务栏托盘出现"中"字图标）
2. 在任意文本框输入拼音/五笔，候选条出现在屏幕左下方（可拖动，位置记忆）
3. `Shift` 轻点开关输入法，`` Ctrl+` `` 切换模式
4. 详细说明见 [docs/WGIME_使用说明.md](docs/WGIME_使用说明.md)

## 文件说明

| 文件 | 作用 |
|---|---|
| `wgime.bat` | 程序本体（自包含） |
| `config.txt` | 用户配置（模糊音/短语/上屏方式/快捷键） |
| `py.txt` / `wb.txt` / `ec.txt` | 扩展词典（`码 词1 词2…`，UTF-8，可选） |
| `import_py.txt` / `import_wb.txt` | 码表导入产物（Gboard 词库转换） |
| `rebuild.ps1` | 修改内嵌 C# 后重建 DLL 载荷（必须用 Windows PowerShell 5.1） |
| `tests/` | 回归测试（单元 + 真实词库 e2e + 载荷一致性） |
| `docs/` | 使用说明 + 技术文档 |

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
