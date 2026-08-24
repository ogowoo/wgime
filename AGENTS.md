# AGENTS.md — 面向 AI Agent 的项目上下文

> 本文件是给 AI Agent（及多会话）的速查上下文。接手任务时先读这里，避免重复踩坑、避免上下文失忆。
> 人类视角的说明见 README.md；逐版本记录见 CHANGELOG.md。

## 1. 项目是什么

WgIme = 免安装单文件悬浮输入法（拼音/五笔/混合/英汉词典）+ WgTray（无输入法的托盘工具箱）。
两个程序 × 两种形态（bat 带载荷 / ps1 带载荷），全部单文件自包含。

## 2. 关键文件与职责

| 文件 | 角色 | 注意 |
|---|---|---|
| `wgime.bat` | **C# 源码真身** + bat 版（内嵌瘦 DLL + 码表 `###WGIME_DATA###` 数据块） | 改输入法/工具箱/插件核心逻辑一律改这里 |
| `WgIme.ps1` | WgIme ps1 版（内嵌完整 DLL + 码表 trailer） | **从 wgime.bat 生成**，不要手改 |
| `wgtray.bat` / `wgtray-nopayload.bat` | WgTray bat 两版 | 从 wgime.bat 的 C# 切分生成 |
| `WgTray.ps1` | WgTray ps1 版 | 同上 |
| `build-wgime-dll.ps1` | 编译 WgIme 完整 DLL（含码表 + WgImeLauncher + trailer） | 给 ps1 版用 |
| `build-wgime-ps1.ps1` | 组装 WgIme.ps1（调 build-wgime-dll 到临时目录再 base64 嵌入） | 同步 root + wg-all + release |
| `tests\rebuild-wgime-bat-payload.ps1` | **重编译 wgime.bat 的内嵌瘦 DLL**（纯 WordBoard，555KB） | 改 wgime.bat 的 `$cs` 后必须跑这个 |
| `build-wgtray.ps1` | 生成 wgtray 各版（`-Bat`/`-NoPayload`，默认 ps1） | 含**切片行号**，wgime.bat 增删行后要同步 |
| `config.txt` / `tools.txt` | 配置 / 工具箱模板 | root 与 wg-all、release 三方同步 |
| `plugins\*.txt` | 插件（calc 种子 / clock / chat / clean-bin / qping / wgtranslate） | 三处同步 |
| `sync-dist.ps1` | **一键刷分发目录**（config/tools/插件/码表/文档/wgime.bat → wg-all + release） | 改完这些文件后跑一次 |
| `release\` | 纯成品目录 | 成品 + 码表 txt + config/tools + docs + plugins，不放 build/test |

## 3. 改动后必做的连锁动作

**改了 `wgime.bat` 的 C#（`$cs`）**：
1. `powershell -File tests\rebuild-wgime-bat-payload.ps1`（重编译 bat 内嵌瘦 DLL）
2. `powershell -File build-wgime-ps1.ps1`（重生成 WgIme.ps1 + 同步 wg-all/release）
3. `powershell -File build-wgtray.ps1` + `-Bat` + `-Bat -NoPayload`（重生成 WgTray 各版）
4. `Copy-Item wgime.bat release\wgime.bat`（手动同步，build 脚本不复制它）
5. 跑测试（见 §4）
6. 更新 CHANGELOG.md + 相关 docs

**改了 `build-wgtray.ps1` 切片**：wgime.bat 的 C# 增删行会导致切片 anchor 失配。切片行号在 build-wgtray.ps1 的 `$sliceDefs`，anchor 失配时报错会指明是哪个切片。用 anchor 重新定位行号（`Slice` 函数有 anchor 校验）。

**改了 `config.txt`/`tools.txt`/插件 `plugins\*.txt`/码表 `py.txt`/`wb.txt`/`ec.txt`/`import_*`/文档 `docs\WGIME_*.md`/`wgime.bat`**：跑 `powershell -File sync-dist.ps1` 一键同步到 wg-all + release（替代手工 Copy-Item；码表只进 release，文档只进 release\docs，WGIME_*.md 不含 AGENTS/CHANGELOG）。

## 4. 测试

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgime-ps1.tests.ps1    # WgIme ps1 版（15 项）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray-ps1.tests.ps1   # WgTray ps1 版（10 项）
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\wgtray.tests.ps1       # WgTray 两版（61 项）
```

- 测试需要 Windows PowerShell 5.1（`powershell.exe`，不是 pwsh）。
- 测试会启动真实 IME/托盘进程，可能被**单实例锁**影响；失败时先杀掉残留的 powershell 进程（`Get-CimInstance Win32_Process | ? CommandLine -match 'WgIme|WgTray' | % { Stop-Process $_.ProcessId -Force }`），清理 `%LOCALAPPDATA%\wgime\WgIme.*.dll` 和 `wgime.mb` 缓存后重跑。
- schtasks 相关断言在无交互会话会 SKIP（已处理）。

## 5. 关键约束（踩过的坑）

1. **行尾**：`wgime.bat`/`wgtray.bat` 必须 CRLF 无 BOM（.gitattributes `eol=crlf`，仓库存储 LF、checkout 转 CRLF）。build 脚本用 LF 内部处理、写出时转 CRLF。**不要用 -text**（那会导致 blob 存成 LF，别人 clone 后 cmd 解析失败）。
2. **编码**：`wgime.bat` 是 UTF-8 无 BOM（C# 里中文直接用）。`.ps1` 构建脚本必须 ASCII（PS 5.1 按 ANSI 读），非 ASCII 内容放 UTF-8 模板文件（如 `wgtray_glue.cs.txt`）。测试脚本也是 ASCII。
3. **提交消息**：含 `>`/`▶`/中文的 commit message 用 `git commit -F 文件`（不要用 `-m`，会破坏 PowerShell 解析）。
4. **大文件推送**：39MB ps1 推送可能 HTTP 408，先 `git config core.compression 0`。
5. **码表 txt**：`py.txt`/`wb.txt`/`ec.txt`/`import_*` 已**入库跟踪**（根目录，构建源）。它们也用于 build-wgime-dll 生成 trailer。
6. **wgime.bat 瘦 DLL 陷阱**：`build-wgime-dll.ps1` 产出的是**含码表 + launcher 的完整 DLL（5.3MB）**，只该给 WgIme.ps1。wgime.bat 的内嵌 DLL 是**纯 WordBoard（555KB）**，必须用 `tests\rebuild-wgime-bat-payload.ps1` 生成——否则 wgime.bat 会涨到 9.6MB。
7. **WordBoard 与 WgImeLauncher 解耦**：WordBoard 不硬引用 WgImeLauncher，用 `TrailerExtractor` 委托字段。bat 版不设置它（码表走 RunApp 参数），ps1 版 launcher 设置它。改动时保持这个解耦。
8. **种子**：首次播种只留 `tools.txt` + `plugins\README.txt` + `plugins\calc.txt`（三段 here-string：`$seedTools`/`$seedPluginReadme`/`$seedCalc`）。config.txt 是运行时 C# `DefaultConfigText()` 生成的，**不是种子**。
9. **自启**：程序**不自带**自启（无 -Install / 无计划任务 / 无菜单自启项）。用户自己挂任务/启动文件夹。
10. **码表数据块 `###WGIME_DATA###`**：wgime.bat 的内置码表（原 5 段 here-string）已移到文件尾部的 `###WGIME_DATA###` 数据块（在 `###WGIME_DLL###` 之前），分段标记 `###PYDATA###`/`###WBDATA###`/`###ECDATA###`/`###PYWORDS###`/`###PYWFREQ###`。PS 引导层用 `Get-DictSeg` 按 `###NAME###` + 下一个 `\n###` 分段提取，码表**不参与 PS 脚本解析**（消除 Invoke-Expression 扫描大 here-string 的启动开销）。cmd bootstrap 用 `$j=$s.LastIndexOf('###WGIME_DATA###')` 截断 `$p`——**必须 LastIndexOf**（marker 也出现在 bootstrap 行本身和提取逻辑注释里，IndexOf 会定位错）。固化码表（`BakeTables`）用 `ReplaceDictSeg(bat,"PYDATA"/"WBDATA"/"ECDATA",…)` 写回数据块对应 segment；`build-wgime-dll.ps1` 用同名 `Get-DictSeg` 从数据块取码表。
11. **遍历字典构建索引必须排序**：.NET `Dictionary` 的遍历顺序取决于键 hash + **插入顺序**；bake 的 `SerializeDict` 按 code 排序重写码表、改变插入顺序。凡是用 `foreach (var kv in <字典>)` 构建顺序敏感的索引/列表（`BuildCharPy`/`BuildAcro`/`BuildCharWb`/`BuildReverse`/`AddWubiWildcard`/`BuildRevWb`）必须改成 `.OrderBy(k => k.Key, StringComparer.Ordinal)`，否则 bake 前后多音字简拼 key、同频候选 tie-break 会不一致。

## 6. 加载与性能（已做的优化，改动时别回退）

- **缓存命中跳过 trailer 解压**：`WgImeLauncher.ComputeTrailerHash`（压缩字节 md5，不解压）→ `BuildDicts` 用它查 `.mb` 缓存；miss 才 `ExtractDictsFull` 解压（经 `TrailerExtractor` 委托）。
- **WGB4 缓存格式**：批量块读取 + 并行 ToMap + `CompressionLevel.Fastest`。
- **词频保存后台化**：`SaveFreq` 走线程池（`freqSaving` 防堆积），退出时 `SaveFreqSync` 同步落盘。内存上限：FreqM/LastPickM 各 3 万、Freq 9 万、Assoc key 2 万。
- **启动计时日志**：`startup: LoadFreq+BuildDicts=XXXms ApplySwap=YYYms`。
- **固化码表预生成缓存**：`BakeTables` 固化后（无论是否勾选"删除源文件"）`PrebuildCacheAfterBake` 用 bake 后的输入重算 md5 并复用内存字典直接写 `wgime.mb`，下次启动命中缓存，跳过 ~10-24s 冷重建。md5 的 overlay 文件字节用 `SafeRead` 读实际状态；它对新码表 `TrimEnd` 末尾换行，与 `Get-DictSeg` 读数据块时的 `TrimEnd` 字节级一致，否则 md5 对不上。保留源文件时下次启动的 overlay 是幂等的（`AddDictLine` 覆盖 + `MergeUserWords` 只追加），冷启动结果等于内存字典。

## 7. Git / 分支

- 主分支 `master`（唯一活跃分支）。`wgtray` 已归档（`wgtray-archive` tag），不再更新。
- 提交后推 `origin/master`。release 发版本用 GitHub API + zip（见历史操作）。
- **发 release 的中文坑**：用 GitHub API 创建/更新 release 的 body 时，必须用 `HttpWebRequest` + `[Text.Encoding]::UTF8.GetBytes(json)` 显式 UTF-8 字节发送。**不要用 `Invoke-RestMethod` + `ConvertTo-Json`**——PowerShell 5.1 会把中文 body 编码成 `?`（曾导致 v1.2.0~v1.2.4 的 release 描述全变问号）。
- 版本 tag：`v1.0.0` ~ `v1.2.4`（后续版本递增）。插件更新不单独发 release。

## 8. 当前状态速览

- 最近工作：码表数据块化（`###WGIME_DATA###`，消除启动时 PS 解析大 here-string）、固化码表写数据块 + 预生成 `.mb` 缓存（下次启动跳过 ~10s 冷重建）、词库加载优化（缓存命中跳解压）、wgime.bat 恢复瘦 DLL、种子精简、chat 插件（MQTT）、clock 多提醒、文档同步。
- 待用户验证：词库加载速度（缓存命中路径）、chat 插件与手机互通、固化码表后启动速度（应已降到缓存命中级别）。
