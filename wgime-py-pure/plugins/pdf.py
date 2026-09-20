# -*- coding: utf-8 -*-
"""pdf.py — PDF 工具箱 (第七十七轮; 纯 Python 引擎 pypdf, 完全离线)。

为什么是"插件 + 内嵌 pypdf"这个组合 (动这块前先读这三条):
  1. **进程内 .py 插件**: `main.load_py_plugins()` 用 exec_module 把 plugins/*.py 收进 PLUGINS,
     上屏编码 `pdf` 命中后 `run_launcher()` 直接调 `run()` —— 那是 **Tk 主线程**, 所以这里能像
     二维码/计算器插件一样用宿主 `ui.make_window` 建真窗口。**不能**做成 `plugins/*.txt` 的
     `[python]` 块: 那是 `python.exe <临时脚本>` 子进程 (还有 60s 熔断), 拿不到宿主的 sys.path,
     import 不到内嵌的 pypdf, 也开不了宿主风格的窗口。
  2. **pypdf 内嵌在单文件的 thirdparty.zip 里** (构建期 `collect_thirdparty(['pystray','pypdf'])`,
     zipimport + %LOCALAPPDATA%/wgime-py/site)。它是纯 Python(60 个 .py / 0 个 .pyd), 所以能跨
     解释器版本内嵌 —— 这跟 Pillow/comtypes 那类 C 扩展不是一个故事。代价 ~+497KB。
  3. **能力边界**(实测, 别在文档里吹过头):
     - 拆分/合并/旋转/删页/分析/取文字: pypdf 直接做。
     - **压缩**: 只做"结构无损压缩"(`compress_content_streams`), 对已经是图片型的 PDF 基本
       省不动(实测 1900.6KB -> 1874.9KB), 对小文件甚至**变大**(1359 -> 1452 B)。真正能大幅
       缩小的"重排页"路线要栅格化 (P2 的 WinRT 渲染), 不在这层。
     - **取文字**: 只对"文字型"PDF 有效。扫描件/图片型 PDF 实测取到 **0 字符** —— 这时如实
       报"可能是扫描件", 不要假装成功。
     - AES 加密 PDF 打不开 (需要 cryptography, 见 build-wgime-pure.py 的 _THIRD_SKIP);
       老的 RC4 加密有纯 Python 回退, 能开。

安全约定: **绝不覆盖/修改原文件**。所有输出都写成新名字(`xxx_split.pdf`), 重名自动 `-2`/`-3`。
重活全部丢后台线程, 只经 `win.after(0, ...)` 回主线程改控件 (Tk 不是线程安全的)。
"""
import collections
import json
import os
import queue
import shutil
import subprocess
import tempfile
import threading
import time

CODE = 'pdf'
NAME = 'PDF 工具'
DESC = '合并/拆分/旋转/删页/提取文字/页面分析 · 纯 Python 引擎(pypdf) · 离线 · 不修改原文件'
VERSION = '1.0'
AUTHOR = 'WgIme'
PERM = 'low'


# ======================================================================
# 纯逻辑层: 不 import tkinter, 也不碰任何控件 —— tests/pdf-test.py 直接调这些
# ======================================================================
class PdfError(Exception):
    """可预期的失败(文件不存在/加密/损坏/参数错), 消息就是给用户看的人话。"""


def _pypdf():
    """懒 import pypdf。单文件分发里它在内嵌 zip; 源码目录跑时走 site-packages。"""
    try:
        import pypdf
    except Exception as ex:                                    # 内嵌缺失/宿主没装
        raise PdfError('找不到 PDF 引擎 pypdf (%r) —— 单文件分发里应内嵌, '
                       '见 wgime-py-pure/tests/embedded-isolation-test.py' % (ex,))
    return pypdf


def human(n):
    """字节数 -> 人话 (与 tools.py 的显示风格一致)。"""
    try:
        n = float(n)
    except (TypeError, ValueError):
        return str(n)
    if n < 1024:
        return '%d B' % int(n)
    if n < 1024 * 1024:
        return '%.1f KB' % (n / 1024.0)
    return '%.2f MB' % (n / 1048576.0)


def parse_ranges(spec, maxn):
    """'1-5,8,11-13' -> 升序去重的 1-based 页号列表。

    规则(和用户在 itools/打印对话框里的习惯一致):
      * 空串 / 'all' / '*' / '全部' -> 全部页
      * 单个数字 '5' -> [5]; 区间 '3-5' -> [3,4,5]; **倒着写 '5-3' 也当 [3,4,5]**(不报错)
      * 超出范围的值**丢弃**(不报错), 因为页数是改文件后才变的, 报错太吵
      * 一个有效页都解析不出来 -> 抛 PdfError(让调用方提示"页码范围无效")
    """
    s = (spec or '').strip().lower()
    if not s or s in ('all', '*', '全部', '所有'):
        return list(range(1, maxn + 1))
    out = []
    for tok in s.replace('，', ',').replace(' ', ',').split(','):
        tok = tok.strip()
        if not tok:
            continue
        if '-' in tok[1:]:                                     # 允许 '1-3'; 负号不参与
            a, _, b = tok.partition('-')
            try:
                a, b = int(a), int(b)
            except ValueError:
                continue
            out.extend(range(min(a, b), max(a, b) + 1))
        else:
            try:
                out.append(int(tok))
            except ValueError:
                continue
    if not out:
        raise PdfError('页码范围无效: %r (例子: 1-5,8,11-13)' % (spec,))
    return sorted(set(p for p in out if 1 <= p <= maxn))


def norm_pages(pages, maxn):
    """页号列表(1-based) 或 '1-5,8' 字符串 -> 升序去重 + 范围钳制。"""
    if isinstance(pages, (list, tuple, set)):
        try:
            v = sorted(set(int(x) for x in pages))
        except (TypeError, ValueError):
            raise PdfError('页号必须是整数列表: %r' % (pages,))
        return [p for p in v if 1 <= p <= maxn]
    return parse_ranges(pages, maxn)


def unique_path(path):
    """不覆盖任何已有文件: 重名就加 -2 / -3 ... (最多试到 -99)。"""
    if not os.path.exists(path):
        return path
    stem, ext = os.path.splitext(path)
    for i in range(2, 100):
        p = '%s-%d%s' % (stem, i, ext)
        if not os.path.exists(p):
            return p
    raise PdfError('同名文件太多, 请换一个输出目录')


def sibling(src, suffix, ext=None):
    """源文件同目录的新名字: a.pdf + '_split' -> a_split.pdf (再经 unique_path)。"""
    d, fn = os.path.split(src)
    stem, e = os.path.splitext(fn)
    return unique_path(os.path.join(d, stem + suffix + (ext or e or '.pdf')))


def open_reader(path, password=''):
    """PdfReader + 加密处理 + 人话报错。加密 PDF 只在真解不开时才抛。"""
    pypdf = _pypdf()
    if not os.path.isfile(path):
        raise PdfError('文件不存在: %s' % path)
    try:
        r = pypdf.PdfReader(path)
    except Exception as ex:
        raise PdfError('打不开(不是 PDF 或已损坏): %s' % ex)
    if getattr(r, 'is_encrypted', False):
        ok = 0
        try:
            ok = r.decrypt(password or '')
        except Exception as ex:
            raise PdfError('加密 PDF 解密失败: %s' % ex)
        if not ok:
            raise PdfError('PDF 已加密: 需要密码; 若用的是 AES 加密则单文件版打不开'
                           '(不带 cryptography C 扩展), 只支持 RC4 老加密')
        try:
            len(r.pages)                                       # 解密后真的能读才算数
        except Exception as ex:
            raise PdfError('加密 PDF 解密后仍读不了: %s' % ex)
    return r


def analyze(path, probe_pages=5):
    """页面分析: 页数/版本/大小/元数据/是否加密/文字量(判文字型还是扫描件)。"""
    r = open_reader(path)
    n = len(r.pages)
    size = os.path.getsize(path)
    meta = {}
    try:
        md = r.metadata or {}
        for key, label in (('/Title', '标题'), ('/Author', '作者'), ('/Producer', '生成程序'),
                           ('/Creator', '创建程序'), ('/CreationDate', '创建时间')):
            v = md.get(key)
            if v:
                meta[label] = str(v)
    except Exception:
        pass
    probe = max(1, min(n, probe_pages))
    chars = 0
    for i in range(probe):
        try:
            chars += len(r.pages[i].extract_text() or '')
        except Exception:
            pass
    kind = '文字型' if chars > 500 else ('图片/扫描型' if chars < 100 else '图文混合')
    box = ''
    try:
        mb = r.pages[0].mediabox
        box = '%.0f x %.0f pt' % (float(mb.width), float(mb.height))
    except Exception:
        pass
    return {'pages': n, 'size': size, 'version': getattr(r, 'pdf_header', '') or '',
            'encrypted': bool(getattr(r, 'is_encrypted', False)), 'meta': meta,
            'text_chars': chars, 'probe_pages': probe, 'kind': kind, 'page_size': box}


def _write(w, out):
    w.write(out)                                               # pypdf 6.x 直接收路径字符串
    if not os.path.exists(out) or os.path.getsize(out) == 0:
        raise PdfError('写出 0 字节, 已失败: %s' % out)
    return os.path.getsize(out)


def merge(paths, out):
    """多个 PDF 按列表顺序合成一个。"""
    if len(paths) < 2:
        raise PdfError('合并至少需要 2 个文件')
    pypdf = _pypdf()
    w = pypdf.PdfWriter()
    for p in paths:
        open_reader(p)                                         # 先逐个校验(含加密), 免得写到一半才炸
        w.append(p)
    return {'out': out, 'size': _write(w, out), 'pages': len(w.pages), 'files': len(paths)}


def split(path, out, pages):
    """把指定页抽成一个新 PDF(保顺序)。"""
    pypdf = _pypdf()
    r = open_reader(path)
    n = len(r.pages)
    pg = norm_pages(pages, n)
    if not pg:
        raise PdfError('没有选出任何页(共 %d 页)' % n)
    w = pypdf.PdfWriter()
    for i in pg:
        w.add_page(r.pages[i - 1])
    return {'out': out, 'size': _write(w, out), 'pages': len(w.pages), 'source_pages': n}


def split_each(path, outdir, cancel=None, on_page=None):
    """每页存成一个文件 (outdir 里 <stem>_pNNN.pdf)。"""
    pypdf = _pypdf()
    r = open_reader(path)
    n = len(r.pages)
    stem = os.path.splitext(os.path.basename(path))[0]
    if not os.path.isdir(outdir):
        os.makedirs(outdir, exist_ok=True)
    made = []
    for i in range(1, n + 1):
        if cancel is not None and cancel():
            break
        w = pypdf.PdfWriter()
        w.add_page(r.pages[i - 1])
        out = unique_path(os.path.join(outdir, '%s_p%03d.pdf' % (stem, i)))
        _write(w, out)
        made.append(out)
        if on_page:
            on_page(i, n, out)
    if not made:
        raise PdfError('一页都没拆出来')
    return {'outdir': outdir, 'files': made, 'count': len(made), 'source_pages': n}


def rotate(path, out, pages, angle=90, cancel=None, on_page=None):
    """顺时针旋转指定页 (角度累加到已有 /Rotate 上, 等同 itools 的 (cur+angle)%360)。"""
    pypdf = _pypdf()
    angle = int(angle) % 360
    if angle not in (90, 180, 270):
        raise PdfError('旋转角度只能是 90 / 180 / 270 (给的是 %r)' % (angle,))
    r = open_reader(path)
    n = len(r.pages)
    pg = norm_pages(pages, n)
    if not pg:
        raise PdfError('没有选出任何页(共 %d 页)' % n)
    w = pypdf.PdfWriter()
    w.clone_document_from_reader(r)
    done = 0
    for i in pg:
        if cancel is not None and cancel():
            break
        w.pages[i - 1].rotate(angle)
        done += 1
        if on_page:
            on_page(i, n, None)
    if not done:
        raise PdfError('已取消, 没有页被旋转')
    return {'out': out, 'size': _write(w, out), 'rotated': done, 'angle': angle, 'pages': n}


def delete(path, out, pages, cancel=None, on_page=None):
    """删掉指定页(页号按**原文件**算)。全删会被拒绝 —— 那等于产出空文件。"""
    pypdf = _pypdf()
    r = open_reader(path)
    n = len(r.pages)
    pg = norm_pages(pages, n)
    if not pg:
        raise PdfError('没有选出任何页(共 %d 页)')
    if len(pg) >= n:
        raise PdfError('不能删掉全部 %d 页 (会产出空 PDF)' % n)
    w = pypdf.PdfWriter()
    w.clone_document_from_reader(r)
    for i in sorted(pg, reverse=True):                          # 从后往前删, 页号才不会串位
        if cancel is not None and cancel():
            break
        del w.pages[i - 1]
        if on_page:
            on_page(i, n, None)
    return {'out': out, 'size': _write(w, out), 'deleted': len(pg), 'left': len(w.pages),
            'pages': n}


def extract_text(path, out, cancel=None, on_page=None):
    """逐页取文字, 写成 UTF-8(BOM) txt —— 中文 Windows 记事本打开不乱码。"""
    r = open_reader(path)
    n = len(r.pages)
    parts = []
    cjk = 0
    for i in range(1, n + 1):
        if cancel is not None and cancel():
            break
        try:
            t = r.pages[i - 1].extract_text() or ''
        except Exception as ex:
            t = ''
            parts.append('<<第 %d 页取字失败: %s>>' % (i, ex))
        parts.append(t)
        cjk += sum(1 for ch in t if '\u4e00' <= ch <= '\u9fff')
        if on_page:
            on_page(i, n, None)
    text = '\n'.join(parts)
    with open(out, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(text)
    return {'out': out, 'chars': len(text), 'cjk': cjk, 'pages': n, 'size': os.path.getsize(out)}


def compress_lossless(path, out):
    """结构无损压缩: 重压内容流 + 合并重复对象。

    **不要**把它宣传成"能把 PDF 压小" —— 实测: 图片型 PDF 1900.6KB->1874.9KB(99%),
    小文字型 PDF 1359->1452B(反而变大)。它只对"未压缩内容流的大文件"有效。
    """
    pypdf = _pypdf()
    r = open_reader(path)
    w = pypdf.PdfWriter()
    w.clone_document_from_reader(r)
    for pg in w.pages:
        try:
            pg.compress_content_streams()
        except Exception:
            pass
    try:
        w.compress_identical_objects()
    except Exception:
        pass
    size = _write(w, out)
    before = os.path.getsize(path)
    return {'out': out, 'size': size, 'before': before,
            'ratio': (100.0 * size / before) if before else 0.0}


# ======================================================================
# P2 纯逻辑层: WinRT 栅格化 / OCR (Windows.Data.Pdf + Windows.Media.Ocr)
# ======================================================================
_W32_SRC = r"""# wg-pdfw32.ps1 -- resident JSON-line helper (Windows.Data.Pdf rasterize + Windows.Media.Ocr). ASCII ONLY: PS 5.1 reads .ps1 as ANSI.
# protocol: one JSON per line on stdin; one JSON per line on stdout (JSON ONLY). stderr = diagnostics.
# reqs: {"cmd":"ping"} | {"cmd":"render",...,"format":"png|jpg"}
#       {"cmd":"ocr",...,"lang":"zh-Hans-CN","width":2000} | {"cmd":"exit"}
$ErrorActionPreference = 'Continue'
$WarningPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
$sw0 = [Diagnostics.Stopwatch]::StartNew()

Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null

$SF = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$PPD = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$BE = [Windows.Graphics.Imaging.BitmapEncoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$BD = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
$OcrEngine = [Windows.Media.Ocr.OcrEngine, Windows.Media.Ocr, ContentType = WindowsRuntime]
$WLanguage = [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime]
$XStream = [System.IO.WindowsRuntimeStreamExtensions]

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$asTaskAction = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]

function Await($op, $type) {
    $t = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    return $t.Result
}
function AwaitAction($op) {
    $t = $asTaskAction.Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
}
function Emit($o) {
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress -Depth 6))
    [Console]::Out.Flush()
}
function Bytes($stream) {
    $stream.Seek(0)
    $net = $XStream::AsStreamForRead($stream)
    $ms = New-Object IO.MemoryStream
    $net.CopyTo($ms)
    $net.Dispose()
    return $ms.ToArray()
}

try {
    $langs = @()
    foreach ($l in $OcrEngine::AvailableRecognizerLanguages) { $langs += $l.LanguageTag }
    Emit @{ ready = $true; boot_ms = $sw0.ElapsedMilliseconds; pdf_api = $true; ocr = $langs }
} catch {
    Emit @{ ready = $false; error = ("WinRT init failed: " + $_.Exception.Message) }
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }
    $line = $line.Trim()
    if (-not $line) { continue }
    $id = 0
    try {
        $req = $line | ConvertFrom-Json
        $id = [int]($req.id)
        $cmd = [string]$req.cmd
        if ($cmd -eq 'exit') { break }
        elseif ($cmd -eq 'ping') {
            Emit @{ id = $id; ok = $true; ocr = (@($OcrEngine::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag })) }
        }
        elseif ($cmd -eq 'render') {
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            $file = Await ($SF::GetFileFromPathAsync([string]$req.pdf)) $SF
            $doc = Await ($PPD::LoadFromFileAsync($file)) $PPD
            $total = $doc.PageCount
            $pages = @()
            if ($null -ne $req.pages) { foreach ($p in $req.pages) { $pages += [int]$p } }
            else { for ($i = 1; $i -le $total; $i++) { $pages += $i } }
            $fmt = [string]$req.format
            $width = [int]$req.width
            $stem = [string]$req.stem
            $outdir = [string]$req.outdir
            [void][IO.Directory]::CreateDirectory($outdir)
            $files = @()
            $wrote = 0
            foreach ($pn in $pages) {
                if ($pn -lt 1 -or $pn -gt $total) { continue }
                $pg = $doc.GetPage($pn - 1)
                $st = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
                $op = New-Object Windows.Data.Pdf.PdfPageRenderOptions
                $op.DestinationWidth = [uint32]$width
                if ($fmt -eq 'jpg') { $op.BitmapEncoderId = $BE::JpegEncoderId }
                AwaitAction ($pg.RenderToStreamAsync($st, $op))
                $bytes = Bytes $st
                $path = [IO.Path]::Combine($outdir, ('{0}_p{1:d3}.{2}' -f $stem, $pn, $fmt))
                [IO.File]::WriteAllBytes($path, $bytes)
                $files += @{ path = $path; page = $pn; bytes = $bytes.Length }
                $wrote++
                Emit @{ id = $id; progress = @{ i = $wrote; total = $pages.Count; page = $pn } }
            }
            Emit @{ id = $id; ok = $true; files = $files; ms = $t0.ElapsedMilliseconds; total_pages = $total }
        }
        elseif ($cmd -eq 'ocr') {
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            $lang = [string]$req.lang
            $eng = $null
            if ($lang) {
                try { $eng = $OcrEngine::TryCreateFromLanguage([Windows.Globalization.Language]::new($lang)) } catch { $eng = $null }
            }
            if ($null -eq $eng) { $eng = $OcrEngine::TryCreateFromUserProfileLanguages() }
            if ($null -eq $eng) { throw 'no OCR language pack (Settings > Time & Language > Language > add a language + Optional features: Optical character recognition)' }
            $file = Await ($SF::GetFileFromPathAsync([string]$req.pdf)) $SF
            $doc = Await ($PPD::LoadFromFileAsync($file)) $PPD
            $total = $doc.PageCount
            $pages = @()
            if ($null -ne $req.pages) { foreach ($p in $req.pages) { $pages += [int]$p } }
            else { for ($i = 1; $i -le $total; $i++) { $pages += $i } }
            $width = [int]$req.width
            if ($width -le 0) { $width = 2000 }
            $out = @()
            $done = 0
            foreach ($pn in $pages) {
                if ($pn -lt 1 -or $pn -gt $total) { continue }
                $pg = $doc.GetPage($pn - 1)
                $st = New-Object Windows.Storage.Streams.InMemoryRandomAccessStream
                $op = New-Object Windows.Data.Pdf.PdfPageRenderOptions
                $op.DestinationWidth = [uint32]$width
                $op.BitmapEncoderId = $BE::PngEncoderId
                AwaitAction ($pg.RenderToStreamAsync($st, $op))
                $st.Seek(0)
                $dec = Await ($BD::CreateAsync($st)) $BD
                $bmp = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime])
                $res = Await ($eng.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult, Windows.Media.Ocr, ContentType = WindowsRuntime])
                $out += @{ page = $pn; text = [string]$res.Text }
                $done++
                Emit @{ id = $id; progress = @{ i = $done; total = $pages.Count; page = $pn } }
            }
            Emit @{ id = $id; ok = $true; texts = $out; ms = $t0.ElapsedMilliseconds; lang = $eng.RecognizerLanguage.LanguageTag }
        }
        else {
            Emit @{ id = $id; ok = $false; error = ('unknown cmd: ' + $cmd) }
        }
    } catch {
        Emit @{ id = $id; ok = $false; error = $_.Exception.Message }
    }
}
"""


class _W32(object):
    """常驻 PowerShell 助手 (JSON 行协议) 的父进程侧。

    机制照抄 voice.py 的 `_WarmSrv`(第六十三/六十四轮那套), 只是协议不同 —— 那几条坑是共通的:
      * `lock` 只管起/杀, `rlock` 只管一问一答; **两个锁别合并**(合并了就会在识别时把起进程堵住)
      * 源码走**环境变量** `WGIME_PDFW32_SRC` + `iex` 引导: 不落盘、不把 7.3KB 塞进命令行
        (实测命令行只有 89 字符, 起进程 28ms)
      * 回包 `ensure_ascii=True`(裸 UTF-8 在中文机会变 `?`), 父进程退出 = stdin EOF = 子进程自退(实测 rc=0)
      * 连续起不来 `MAX_FAIL` 次后不再重试(否则用户每点一次都白起一个 powershell)
    取消的语义: 助手是**单线程一问一答**的, 渲染途中它读不到 stdin, 所以 __取消 = 杀掉助手__,
    下次调用会自动重启(冷启实测 ~1.8s)。
    """
    MAX_FAIL = 3
    T_COLD = 180.0                 # 首次(含 WinRT 初始化)
    T_TIMEOUT = 1800.0             # 之后(大文件多页)

    def __init__(self):
        self.lock = threading.Lock()
        self.rlock = threading.Lock()
        self.proc = None
        self.q = None
        self.errbuf = None
        self.ready = False
        self.boot_ms = 0
        self.info = {}
        self.fail = 0
        self.rid = 0
        self.last_err = ''
        self.started = 0.0

    def _tail_err(self):
        if not self.errbuf:
            return ''
        tail = [t for t in list(self.errbuf)[-2:] if t]
        return (' | stderr: ' + ' / '.join(tail)) if tail else ''

    def _kill_locked(self):
        p, self.proc = self.proc, None
        self.ready = False
        if p is None:
            return
        try:
            if p.poll() is None:
                try:
                    p.stdin.write('{"cmd":"exit"}\n')
                    p.stdin.flush()
                except Exception:
                    pass
                p.kill()
        except Exception:
            pass

    def shutdown(self):
        with self.lock:
            self._kill_locked()

    def _spawn(self):
        env = dict(os.environ)
        env['WGIME_PDFW32_SRC'] = _W32_SRC
        argv = ['powershell.exe', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass',
                '-Command', 'iex $env:WGIME_PDFW32_SRC']
        return subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, encoding='utf-8',
                                errors='replace', bufsize=1,
                                creationflags=0x08000000,      # CREATE_NO_WINDOW
                                env=env)

    def ensure(self):
        """起进程(或复用)。**不等 READY** —— 预热路径要能在别的线程上调它。"""
        with self.lock:
            if self.proc is not None and self.proc.poll() is None:
                return True
            if self.fail >= self.MAX_FAIL:
                return False
            now = time.monotonic()
            if now - self.started < 1.0:                      # 起得太密: 挡一下重试风暴
                return False
            self._kill_locked()
            self.started = now
            self.ready = False
            self.boot_ms = 0
            self.last_err = ''
            q = queue.Queue()
            errbuf = collections.deque(maxlen=20)
            self.q, self.errbuf = q, errbuf
            try:
                p = self._spawn()
            except Exception as e:
                self.last_err = '启动 WinRT 助手失败: %r' % (e,)
                self.fail += 1
                return False
            self.proc = p
            threading.Thread(target=self._reader, args=(p, q), daemon=True).start()
            threading.Thread(target=self._err_reader, args=(p, errbuf), daemon=True).start()
            return True

    def _reader(self, p, q):
        """**q 必须是参数**: 重启时 self.q 会换成新队列, 用 self.q 会让旧线程的 EOF 落到新队列里。"""
        try:
            for line in p.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    q.put(json.loads(line))
                except ValueError:
                    continue
        except Exception:
            pass
        finally:
            try:
                q.put({'eof': True})
            except Exception:
                pass

    def _err_reader(self, p, buf):
        try:
            for line in p.stderr:
                buf.append(line.rstrip()[:300])
        except Exception:
            pass

    def _died(self, why, rc=None):
        self.fail += 1
        with self.lock:
            self._kill_locked()
        return None, '%s%s%s' % (why, (' (rc=%s)' % rc) if rc is not None else '', self._tail_err())

    def call(self, req, cancel=None, on_page=None):
        """发一条请求 -> (回包 dict, 错误串)。`on_page(i, total, page)` 收进度行。"""
        if not self.ensure():
            if self.fail >= self.MAX_FAIL:
                return None, ('WinRT 助手连续 %d 次起不来, 已停止重试(重启 WgIme 可再试)'
                              '%s' % (self.fail, ('; 上次错误: ' + self.last_err) if self.last_err else ''))
            return None, (self.last_err or 'WinRT 助手还没就绪, 请再试一次')
        with self.rlock:
            p, q = self.proc, self.q
            if p is None or p.poll() is not None:
                return self._died('WinRT 助手已退出', p.poll() if p else None)
            self.rid += 1
            rid = self.rid
            req = dict(req)
            req['id'] = rid
            cold = not self.ready
            try:
                p.stdin.write(json.dumps(req, ensure_ascii=True) + '\n')
                p.stdin.flush()
            except Exception as e:
                return self._died('给 WinRT 助手发请求失败: %r' % (e,))
            limit = self.T_COLD if cold else self.T_TIMEOUT
            deadline = time.monotonic() + limit
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    with self.lock:
                        self._kill_locked()
                    return None, 'WinRT 操作超时 (%.0fs)' % limit
                if cancel is not None and cancel():
                    with self.lock:
                        self._kill_locked()
                    return None, '已取消(助手已重启, 下次会稍慢)'
                try:
                    o = q.get(timeout=min(left, 0.25))
                except queue.Empty:
                    if p.poll() is not None:
                        return self._died('WinRT 助手退出', p.poll())
                    continue
                if o.get('eof'):
                    return self._died('WinRT 助手退出', p.poll())
                if o.get('ready') is False:
                    self.fail += 1
                    with self.lock:
                        self._kill_locked()
                    return None, str(o.get('error') or 'WinRT 不可用(需要 Windows 10/11)')
                if o.get('ready') and 'id' not in o:
                    self.ready = True
                    # 用户真正等的是**从 spawn 到能用**: 子进程自己报的 boot_ms 只算了"PS 起来之后
                    # 脚本初始化"那一段(实测 ~0.1s), 而 powershell.exe 冷启本身要 ~1.7s —— 别少报。
                    self.boot_ms = int((time.monotonic() - self.started) * 1000)
                    self.info = o
                    self.fail = 0
                    continue
                if int(o.get('id') or 0) != rid:              # 串包/过期回包: 丢掉继续等自己那条
                    continue
                if o.get('progress'):
                    if on_page:
                        pr = o['progress']
                        on_page(int(pr.get('i') or 0), int(pr.get('total') or 0),
                                int(pr.get('page') or 0))
                    continue
                if not o.get('ok'):
                    return None, 'WinRT 失败: %s' % (o.get('error') or '?')
                self.fail = 0
                return o, None


_W32C = {'cli': None}


def _w32():
    if _W32C['cli'] is None:
        _W32C['cli'] = _W32()
    return _W32C['cli']


def winrt_info(timeout_note=None):
    """探测 WinRT 可用性 + 可用的 OCR 语言。返回 {ok, ocr:[...], boot_ms, error?}。"""
    o, err = _w32().call({'cmd': 'ping'})
    if err:
        return {'ok': False, 'error': err, 'ocr': []}
    return {'ok': True, 'ocr': list(o.get('ocr') or []), 'boot_ms': _w32().boot_ms}


def jpeg_size(data):
    """从 JPEG 字节读 (宽, 高); 不是 JPEG 或找不到 SOF 就 None。"""
    if not data or len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return None
    i, n = 2, len(data)
    while i + 3 < n:
        if data[i] != 0xFF:
            i += 1
            continue
        m = data[i + 1]
        if m == 0xD8 or m == 0x01 or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        if m == 0xD9:
            break
        seglen = (data[i + 2] << 8) | data[i + 3]
        if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):     # SOF0..SOF15 去掉 DHT/JPG/DAC
            if i + 9 > n:
                return None
            h = (data[i + 5] << 8) | data[i + 6]
            w = (data[i + 7] << 8) | data[i + 8]
            return (w, h)
        i += 2 + max(2, seglen)
    return None


def png_size(data):
    """从 PNG 字节读 (宽, 高) (IHDR 固定在偏移 16..24); 不是 PNG 就 None。"""
    if not data or len(data) < 24 or data[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    return ((data[16] << 24) | (data[17] << 16) | (data[18] << 8) | data[19],
            (data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23])


def build_pdf_from_jpegs(items, out):
    """把一组 JPEG 拼成一个 PDF —— **纯 Python, 连 pypdf 都不用**。

    items: [(jpeg_bytes, img_w, img_h, page_w, page_h)]; 页尺寸用原 PDF 的 mediabox(pt),
    图铺满整页(JPEG 直接以 /DCTDecode 内嵌, 不再重编码)。
    栅格化"压缩"的最后一棒就是它(itools 那边靠 pdf-lib, 我们不需要)。
    """
    n = len(items)
    if not n:
        raise PdfError('没有可写入的页面')
    objs = {1: b'<</Type/Catalog/Pages 2 0 R>>'}
    kids = []
    num = 2
    for jpg, iw, ih, pw, ph in items:
        page_no, cont_no, img_no = num + 1, num + 2, num + 3
        num += 3
        kids.append(page_no)
        objs[page_no] = ('<</Type/Page/Parent 2 0 R/MediaBox[0 0 %.2f %.2f]'
                         '/Resources<</XObject<</Im0 %d 0 R>>>>/Contents %d 0 R>>'
                         % (pw, ph, img_no, cont_no)).encode()
        cs = ('q %.2f 0 0 %.2f 0 0 cm /Im0 Do Q' % (pw, ph)).encode()
        objs[cont_no] = (b'<</Length ' + str(len(cs)).encode() + b'>>\nstream\n' + cs + b'\nendstream')
        objs[img_no] = (('<</Type/XObject/Subtype/Image/Width %d/Height %d/ColorSpace/DeviceRGB'
                         '/BitsPerComponent 8/Filter/DCTDecode/Length %d>>\nstream\n'
                         % (iw, ih, len(jpg))).encode() + jpg + b'\nendstream')
    objs[2] = ('<</Type/Pages/Kids[%s]/Count %d>>'
               % (' '.join('%d 0 R' % k for k in kids), n)).encode()

    buf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offs = {}
    for k in sorted(objs):
        offs[k] = len(buf)
        buf += ('%d 0 obj\n' % k).encode() + objs[k] + b'\nendobj\n'
    xref = len(buf)
    mx = max(objs)
    buf += ('xref\n0 %d\n' % (mx + 1)).encode() + b'0000000000 65535 f \n'
    for k in range(1, mx + 1):
        buf += (('%010d 00000 n \n' % offs[k]) if k in offs else '0000000000 65535 f \n').encode()
    buf += (b'trailer\n<</Size %d/Root 1 0 R>>\nstartxref\n%d\n%%%%EOF\n' % (mx + 1, xref))
    with open(out, 'wb') as f:
        f.write(bytes(buf))
    size = os.path.getsize(out)
    if not size:
        raise PdfError('写出 0 字节: %s' % out)
    return size


def _render_to(path, outdir, pages, width, fmt, cancel=None, on_page=None):
    """共用的栅格化入口: 开始前先 `open_reader` 校验(加密/损坏在这里就报人话)。"""
    open_reader(path)
    stem = os.path.splitext(os.path.basename(path))[0]
    o, err = _w32().call({'cmd': 'render', 'pdf': path, 'outdir': outdir,
                          'pages': list(pages) if pages else None,
                          'width': int(width), 'format': fmt, 'stem': stem},
                         cancel=cancel, on_page=on_page)
    if err:
        raise PdfError(err)
    files = sorted(o.get('files') or [], key=lambda f: int(f.get('page') or 0))
    out = []
    for f in files:
        try:
            data = open(f['path'], 'rb').read()
        except OSError as ex:
            raise PdfError('渲染结果读不到: %s' % ex)
        wh = png_size(data) if fmt == 'png' else jpeg_size(data)
        out.append({'path': f['path'], 'page': int(f.get('page') or 0), 'bytes': len(data),
                    'w': wh[0] if wh else 0, 'h': wh[1] if wh else 0})
    if not out:
        raise PdfError('一页都没渲染出来')
    return {'files': out, 'count': len(out), 'ms': o.get('ms'), 'format': fmt, 'width': int(width)}


def render_images(path, outdir, pages=None, width=1240, fmt='png', cancel=None, on_page=None):
    """PDF -> 图片 (由 WinRT 助手渲染, 不依赖任何第三方图像库)。"""
    if fmt not in ('png', 'jpg'):
        raise PdfError('图片格式只能是 png / jpg')
    if not os.path.isdir(outdir):
        os.makedirs(outdir, exist_ok=True)
    return _render_to(path, outdir, pages, width, fmt, cancel=cancel, on_page=on_page)


def preview_first_page(path, box_w, box_h, outdir=None):
    """把 PDF 第 1 页渲成"恰好放进 (box_w, box_h)"的一张 PNG -> {'png','w','h','outdir'}。

    纯逻辑(不碰 Tk, 可被测试直接调): 先用 pypdf 读第 1 页 mediabox 算出恰好贴框的渲染宽度,
    再走 WinRT 渲染 —— 栅格化器只有 WinRT 这一条腿, 所以"预览"在没装 WinRT 的机器上会如实报失败
    (而不是假装有图)。调用方负责 `shutil.rmtree(result['outdir'])`。
    """
    r = open_reader(path)
    mb = r.pages[0].mediabox
    pw, ph = float(mb.width), float(mb.height)
    if pw <= 0 or ph <= 0:
        raise PdfError('第 1 页尺寸异常: %sx%s' % (pw, ph))
    scale = min(float(box_w) / pw, float(box_h) / ph)
    w = max(40, min(2000, int(pw * scale)))
    outdir = outdir or tempfile.mkdtemp(prefix='wg-pdf-prev-')
    res = render_images(path, outdir, [1], width=w, fmt='png')
    f0 = res['files'][0]
    data = open(f0['path'], 'rb').read()
    wh = png_size(data) or (w, max(1, int(ph * scale)))
    return {'png': f0['path'], 'w': wh[0], 'h': wh[1], 'outdir': outdir}


def ocr_text(path, out, pages=None, lang=None, width=2000, cancel=None, on_page=None):
    """扫描件取字: WinRT 渲染 -> Windows.Media.Ocr 识别 -> 写成 UTF-8(BOM) txt。

    `lang` 为空时用系统"用户配置语言"的 OCR 引擎; 指定(如 zh-Hans-CN)则要求装了对应语言包。
    """
    open_reader(path)
    o, err = _w32().call({'cmd': 'ocr', 'pdf': path,
                          'pages': list(pages) if pages else None,
                          'lang': lang or '', 'width': int(width)},
                         cancel=cancel, on_page=on_page)
    if err:
        raise PdfError(err)
    texts = sorted(o.get('texts') or [], key=lambda t: int(t.get('page') or 0))
    if not texts:
        raise PdfError('一页都没识别出来')
    text = '\n'.join((t.get('text') or '') for t in texts)
    with open(out, 'w', encoding='utf-8-sig', newline='') as f:
        f.write(text)
    cjk = sum(1 for ch in text if '\u4e00' <= ch <= '\u9fff')
    return {'out': out, 'chars': len(text), 'cjk': cjk, 'pages': len(texts),
            'lang': o.get('lang') or '', 'size': os.path.getsize(out), 'ms': o.get('ms')}


def compress_raster(path, out, width=1240, cancel=None, on_page=None):
    """**有损**压缩: 每页栅格化成 JPEG, 再用 build_pdf_from_jpegs 重拼一个 PDF。

    代价必须说清楚: 文字/矢量/链接**全部消失**(变成图片), 换来的是体积(实测图片型 PDF ~10x)。
    结构无损那条路是 `compress_lossless`, 两条路别混。
    """
    pypdf = _pypdf()
    r = open_reader(path)
    sizes = []
    for pg in r.pages:
        mb = pg.mediabox
        sizes.append((float(mb.width), float(mb.height)))
    n = len(sizes)
    tmpdir = tempfile.mkdtemp(prefix='wg-pdf-raster-')
    try:
        res = _render_to(path, tmpdir, list(range(1, n + 1)), width, 'jpg',
                         cancel=cancel, on_page=on_page)
        items = []
        for f in res['files']:
            data = open(f['path'], 'rb').read()
            wh = jpeg_size(data) or (f['w'], f['h'])
            pw, ph = sizes[f['page'] - 1] if 1 <= f['page'] <= n else (float(wh[0]), float(wh[1]))
            items.append((data, int(wh[0]), int(wh[1]), pw, ph))
        size = build_pdf_from_jpegs(items, out)
        before = os.path.getsize(path)
        return {'out': out, 'size': size, 'before': before, 'pages': len(items),
                'ratio': (100.0 * size / before) if before else 0.0, 'ms': res.get('ms')}
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

# ======================================================================
# UI 层 (只在这里 import tkinter / ui)
# ======================================================================
_W = {'win': None, 'tb': None}          # 单例窗口 + 日志控件
_BUSY = [False]
_CANCEL = [False]
_ANGLE = [90]
_FMT = ['png']                          # 转图片的格式
_LANG = ['']                            # OCR 语言 ('' = 系统用户配置语言)


def _entry_int(e, default, lo=64, hi=6000):
    """读一个"数字输入框", 任何非法输入回落到 default 并钳进 [lo, hi]。"""
    try:
        v = int(float((e.get() or '').strip()))
    except (ValueError, AttributeError, Exception):
        v = default
    return max(lo, min(hi, v))


def _alive(w):
    try:
        return bool(w) and w.winfo_exists()
    except Exception:
        return False


def run():
    import tkinter as tk
    from tkinter import filedialog
    import ui

    if _alive(_W['win']):                                       # 已经开着 -> 抬起来, 不再开第二个
        try:
            _W['win'].deiconify()
            _W['win'].lift()
            _W['win'].focus_force()
        except Exception:
            pass
        return _W['win']

    # 内容区需要 588px (最后一行结束于 576), 标题栏 38px (ui.make_window 的 content 只占 h-38, 见 §42)
    W, H = 640, 626
    win, content = ui.make_window('WgIme PDF 工具', W, H)
    _W['win'] = win
    _BUSY[0] = False
    _CANCEL[0] = False

    def log(s):
        """**线程安全**的日志: 后台线程只许调它, 真正写控件在 after 里回主线程。"""
        def _do():
            tb = _W['tb']
            if not _alive(win) or tb is None:
                return
            try:
                tb.insert('end', s + '\n')
                tb.see('end')
            except Exception:
                pass
        try:
            win.after(0, _do)
        except Exception:
            pass

    # ---- 标题 ----
    tk.Label(content, text='PDF 工具', bg=ui.BG, fg=ui.TEXT,
             font=ui.font(15, bold=True)).place(x=12, y=10, width=300, height=26)
    tk.Label(content, text='纯 Python 引擎 pypdf · 完全离线 · 绝不修改原文件', bg=ui.BG, fg=ui.SUB,
             font=ui.font(8.5)).place(x=12, y=36, width=616, height=18)

    # ---- 文件列表 ----
    def files():
        try:
            return [lb.get(i) for i in range(lb.size())]
        except Exception:
            return []

    def add_files():
        ps = filedialog.askopenfilenames(title='选择 PDF (可多选; 合并用全部, 其它操作只用选中的那个)',
                                        filetypes=[('PDF 文件', '*.pdf'), ('所有文件', '*.*')])
        for p in ps or ():
            if p and p not in files():
                lb.insert('end', p)
        log('已添加 %d 个文件, 列表共 %d 个' % (len(ps or ()), lb.size()))
        if ps:
            preview_show(lb.get(0))

    def del_sel():
        for i in reversed(list(lb.curselection())):
            lb.delete(i)
        log('移除选中, 剩 %d 个' % lb.size())
        on_select()

    def clear_all():
        lb.delete(0, 'end')
        log('已清空文件列表')
        preview_clear()

    ui.flat_button(content, '添加 PDF…', add_files, x=12, y=62, w=118, h=32)
    ui.flat_button(content, '移除选中', del_sel, x=136, y=62, w=92, h=32)
    ui.flat_button(content, '清空', clear_all, x=234, y=62, w=72, h=32)
    tk.Label(content, text='输出写到源文件同目录(带 _后缀) · 绝不覆盖原文件',
             bg=ui.BG, fg=ui.SUB, font=ui.font(8.5), anchor='w').place(x=316, y=62, width=312, height=32)

    lb = tk.Listbox(content, font=ui.font(9), bg=ui.CARD, fg=ui.TEXT, bd=0,
                    highlightthickness=1, highlightbackground=ui.BORDER,
                    selectmode=tk.EXTENDED, activestyle='none')
    lb.place(x=12, y=100, width=420, height=86)

    # ---- 预览框 (选中文件后后台渲染第 1 页贴进来; 栅格化走 WinRT, 不可用就如实写"预览不可用") ----
    pv = {'img': None, 'token': 0}
    pv_box = tk.Frame(content, bg=ui.CARD, highlightthickness=1, highlightbackground=ui.BORDER)
    pv_box.place(x=440, y=100, width=188, height=86)
    pv_lbl = tk.Label(pv_box, text='预览\n(加文件后自动渲染)', bg=ui.CARD, fg=ui.SUB,
                      font=ui.font(8), justify='center')
    pv_lbl.place(x=2, y=2, width=184, height=82)
    _W['preview'] = {'label': pv_lbl, 'state': pv}

    def preview_clear(msg='预览\n(加文件后自动渲染)'):
        pv['token'] += 1
        pv['img'] = None
        try:
            pv_lbl.configure(image='', text=msg)
        except Exception:
            pass

    def preview_fail(ex):
        preview_clear('预览不可用\n%s' % str(ex)[:26])

    def preview_show(path):
        """后台渲第 1 页 -> after 回主线程显示 (token 防"快速换选后旧图盖新图")。"""
        pv['token'] += 1
        tok = pv['token']
        try:
            pv_lbl.configure(image='', text='渲染预览…')
        except Exception:
            pass

        def work():
            try:
                d = preview_first_page(path, 184, 82)
            except Exception as ex:
                win.after(0, lambda: preview_fail(ex))
                return

            def show():
                if tok != pv['token']:                      # 期间又选了别的文件: 丢弃过期结果
                    shutil.rmtree(d['outdir'], ignore_errors=True)
                    return
                try:
                    img = tk.PhotoImage(file=d['png'])
                except Exception as ex:
                    preview_fail(ex)
                    shutil.rmtree(d['outdir'], ignore_errors=True)
                    return
                pv['img'] = img                             # 必须保引用, 否则被 GC 后 Label 变白
                pv_lbl.configure(image=img, text='')
                shutil.rmtree(d['outdir'], ignore_errors=True)
            win.after(0, show)

        threading.Thread(target=work, daemon=True).start()

    _W['preview']['show'] = preview_show
    _W['preview']['clear'] = preview_clear

    def on_select(_=None):
        sel = list(lb.curselection())
        fs = files()
        if sel:
            preview_show(lb.get(sel[0]))
        elif fs:
            preview_show(fs[0])
        else:
            preview_clear()

    lb.bind('<<ListboxSelect>>', on_select)

    def _toggle_btn(text, x, y, w, h, is_sel, on_pick):
        """扁平"单选"按钮: 颜色**每次重画都从 is_sel() 现算**。

        **不能**用 ui.flat_button + 事后 .configure(bg=ACCENT) 来做选中态 —— flat_button 的
        Enter/Leave/Press/Release 处理器把 bg 恢复到**创建时**那一份(闭包绑死), 于是默认选中的
        按钮被 hover 一次就变成「白底 + 白字」, 文字直接消失(第七十七轮用户实测:
        '90°'/'PNG'/'自动' 三个默认项划过之后全看不见)。
        """
        btn = tk.Label(content, text=text, bg=ui.CARD, fg=ui.TEXT,
                       font=ui.font(9.5), cursor='hand2')
        btn.place(x=x, y=y, width=w, height=h)

        def paint(hover=False, pressed=False):
            if is_sel():
                btn.configure(bg=('#0A6CDC' if pressed else ('#2C92FF' if hover else ui.ACCENT)),
                              fg='white')
            else:
                btn.configure(bg=(ui.SURF2 if (hover or pressed) else ui.CARD), fg=ui.TEXT)

        def release(_):
            on_pick()                  # 先改状态
            paint()                    # 再按新状态重画自己(整组的重画由 on_pick 里的 setter 做)
        btn.bind('<Enter>', lambda e: paint(hover=True))
        btn.bind('<Leave>', lambda e: paint())
        btn.bind('<ButtonPress-1>', lambda e: paint(pressed=True))
        btn.bind('<ButtonRelease-1>', release)
        paint()
        btn.refresh = paint
        return btn

    # ---- 参数行 (第 3 行操作磁贴到 302 为止, 所以这里从 310 起 —— 原来放 272 会**正压在磁贴上**,
    #      而"越出窗口"的审计查不出这种重叠, 现在 tests/pdf-test.py 里有专门的两两不重叠断言) ----
    tk.Label(content, text='页码范围', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=12, y=310, width=62, height=32)
    range_e = ui.rounded_entry(content, x=76, y=310, w=150, h=32)
    tk.Label(content, text='角度', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=238, y=310, width=34, height=32)
    angle_btns = {}

    def _set_angle(d):
        _ANGLE[0] = d
        for b in angle_btns.values():
            b.refresh()
        log('旋转角度 = %d°' % d)

    for i, (txt, deg) in enumerate((('90°', 90), ('180°', 180), ('270°', 270))):
        angle_btns[deg] = _toggle_btn(txt, 274 + i * 54, 310, 50, 32,
                                      lambda d=deg: _ANGLE[0] == d,
                                      lambda d=deg: _set_angle(d))
    each_var = tk.IntVar(value=0)
    chk = tk.Checkbutton(content, text='拆分: 每页一个文件', variable=each_var, bg=ui.BG, fg=ui.SUB,
                         font=ui.font(8.5), activebackground=ui.BG, selectcolor=ui.CARD,
                         bd=0, highlightthickness=0, anchor='w', cursor='hand2')
    chk.place(x=440, y=310, width=188, height=32)

    _set_angle(_ANGLE[0])

    # ---- 第二参数行: 图片宽度 / 图片格式 / OCR 语言 (P2 那三个操作用) ----
    tk.Label(content, text='宽度', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=12, y=348, width=40, height=32)
    width_e = ui.rounded_entry(content, x=56, y=348, w=80, h=32, initial='1240')
    tk.Label(content, text='格式', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=146, y=348, width=38, height=32)
    fmt_btns = {}

    def _set_fmt(k):
        _FMT[0] = k
        for b in fmt_btns.values():
            b.refresh()

    for i, (txt, key) in enumerate((('PNG', 'png'), ('JPG', 'jpg'))):
        fmt_btns[key] = _toggle_btn(txt, 186 + i * 60, 348, 56, 32,
                                    lambda k=key: _FMT[0] == k,
                                    lambda k=key: _set_fmt(k))
    tk.Label(content, text='OCR', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=310, y=348, width=34, height=32)
    lang_btns = {}

    def _set_lang(k):
        _LANG[0] = k
        for b in lang_btns.values():
            b.refresh()
        log('OCR 语言 = %s' % (k or '自动(系统用户配置语言)'))

    for i, (txt, key) in enumerate((('中', 'zh-Hans-CN'), ('EN', 'en-US'), ('自动', ''))):
        lang_btns[key] = _toggle_btn(txt, 348 + i * 48, 348, 44, 32,
                                     lambda k=key: _LANG[0] == k,
                                     lambda k=key: _set_lang(k))
    tk.Label(content, text='宽 px · 渲染/识别用', bg=ui.BG, fg=ui.SUB, font=ui.font(8),
             anchor='w').place(x=502, y=348, width=126, height=32)

    # ---- 日志 ----
    tb = ui.console_text(content, x=12, y=390, w=616, h=140)
    _W['tb'] = tb
    log('就绪。先「添加 PDF…」, 再点下面任意一个操作。引擎: pypdf(内嵌, 后台预热中…)')

    # ---- 后台预热 (pypdf zipimport 冷启实测 ~865ms; WinRT 助手冷启 ~1.8s) ----
    def warm():
        try:
            pypdf = _pypdf()
            log('引擎就绪: pypdf %s' % getattr(pypdf, '__version__', '?'))
        except Exception as ex:
            log('引擎不可用: %s' % ex)
        try:
            info = winrt_info()
            if info['ok']:
                log('WinRT 就绪 (%.1fs): 转图片/OCR 可用, OCR 语言 = %s'
                    % (info['boot_ms'] / 1000.0, ', '.join(info['ocr']) or '无'))
            else:
                log('WinRT 不可用(转图片/OCR/压缩将失败): %s' % info['error'])
        except Exception as ex:
            log('WinRT 探测异常: %r' % (ex,))
    threading.Thread(target=warm, daemon=True).start()

    # ---- 操作 ----
    def pick_one():
        """单文件操作: 有选中用选中第一个, 没有就用列表第一个。"""
        fs = files()
        if not fs:
            raise PdfError('请先「添加 PDF…」')
        sel = list(lb.curselection())
        if len(sel) > 1:
            raise PdfError('这个操作只处理 1 个文件, 但你选了 %d 个(合并才用多选)' % len(sel))
        i = sel[0] if sel else 0
        if not sel:
            log('(没选中行, 用列表第 1 个: %s)' % os.path.basename(fs[i]))
        return fs[i]

    def spawn(title, fn):
        """把活丢后台线程; 同一时刻只跑一个操作。"""
        if _BUSY[0]:
            log('已有操作在进行中, 等它跑完或点「取消当前操作」')
            return
        _BUSY[0] = True
        _CANCEL[0] = False
        log('--- %s 开始 ---' % title)

        def worker():
            try:
                fn()
            except PdfError as ex:
                log('失败: %s' % ex)
            except Exception as ex:
                log('异常: %r' % (ex,))
            finally:
                _BUSY[0] = False
                log('--- %s 结束 ---' % title)

        threading.Thread(target=worker, daemon=True).start()

    def do_analyze():
        def work():
            p = pick_one()
            d = analyze(p)
            log('%s' % os.path.basename(p))
            log('  页数 %d · 大小 %s · 版本 %s · 页面 %s' % (d['pages'], human(d['size']),
                                                        d['version'], d['page_size']))
            log('  文字量(前 %d 页) %d 字符 -> %s' % (d['probe_pages'], d['text_chars'], d['kind']))
            if d['encrypted']:
                log('  注意: 该 PDF 带加密标记')
            for k, v in d['meta'].items():
                log('  %s: %s' % (k, v[:80]))
            if d['kind'] != '文字型':
                log('  提示: 非文字型 PDF 「提取文字」基本取不到东西(需要 OCR, 见 P2)')
        spawn('分析', work)

    def do_extract():
        def work():
            p = pick_one()
            out = sibling(p, '_text', '.txt')
            cancel = lambda: _CANCEL[0]
            d = extract_text(p, out, cancel=cancel,
                             on_page=lambda i, n, _o: log('  取字 %d/%d' % (i, n)) if (i % 20 == 0 or i == n) else None)
            log('已写出 %s (%s, %d 字符, 其中汉字 %d)' % (out, human(d['size']), d['chars'], d['cjk']))
            if d['chars'] < 50:
                log('  文字很少 —— 大概率是扫描件/图片型 PDF, 纯取字取不到')
        spawn('提取文字', work)

    def do_merge():
        def work():
            fs = files()
            if len(fs) < 2:
                raise PdfError('合并需要列表里至少 2 个文件')
            d = os.path.dirname(fs[0])
            stem = os.path.splitext(os.path.basename(fs[0]))[0]
            out = unique_path(os.path.join(d, stem + '_merged.pdf'))
            r = merge(fs, out)
            log('已合并 %d 个文件 -> %s (%d 页, %s)' % (r['files'], out, r['pages'], human(r['size'])))
        spawn('合并', work)

    def do_split():
        def work():
            p = pick_one()
            n = len(open_reader(p).pages)
            if each_var.get():
                outdir = os.path.splitext(p)[0] + '_pages'
                r = split_each(p, outdir, cancel=lambda: _CANCEL[0],
                               on_page=lambda i, t, _o: log('  %d/%d' % (i, t)) if (i % 10 == 0 or i == t) else None)
                log('已拆成 %d 个文件 -> %s' % (r['count'], r['outdir']))
            else:
                pg = parse_ranges(range_e.get(), n)
                out = sibling(p, '_split')
                r = split(p, out, pg)
                log('已抽出 %d 页 (原 %d 页) -> %s (%s)' % (r['pages'], r['source_pages'], out, human(r['size'])))
        spawn('拆分', work)

    def do_rotate():
        def work():
            p = pick_one()
            n = len(open_reader(p).pages)
            pg = parse_ranges(range_e.get() or 'all', n)
            out = sibling(p, '_rotated')
            r = rotate(p, out, pg, angle=_ANGLE[0], cancel=lambda: _CANCEL[0])
            log('已旋转 %d 页 %d° -> %s (%s)' % (r['rotated'], r['angle'], out, human(r['size'])))
        spawn('旋转', work)

    def do_delete():
        def work():
            p = pick_one()
            n = len(open_reader(p).pages)
            pg = parse_ranges(range_e.get(), n)                    # 必须显式给页, 空 = 全部 -> 会被下面拒
            out = sibling(p, '_deleted')
            r = delete(p, out, pg, cancel=lambda: _CANCEL[0])
            log('已删除 %d 页, 剩 %d 页 -> %s (%s)' % (r['deleted'], r['left'], out, human(r['size'])))
        spawn('删页', work)

    def do_images():
        def work():
            p = pick_one()
            n = len(open_reader(p).pages)
            pg = parse_ranges(range_e.get() or 'all', n)
            outdir = os.path.splitext(p)[0] + '_images'
            w = _entry_int(width_e, 1240)
            r = render_images(p, outdir, pg, width=w, fmt=_FMT[0], cancel=lambda: _CANCEL[0],
                              on_page=lambda i, t, _pg: log('  渲染 %d/%d' % (i, t))
                              if (i % 5 == 0 or i == t) else None)
            f0 = r['files'][0]
            log('已导出 %d 张 %s 图 (%dpx 宽) -> %s' % (r['count'], r['format'].upper(), r['width'], outdir))
            log('  例: %s (%s, %dx%d)' % (os.path.basename(f0['path']), human(f0['bytes']), f0['w'], f0['h']))
        spawn('转图片', work)

    def do_ocr():
        def work():
            p = pick_one()
            n = len(open_reader(p).pages)
            pg = parse_ranges(range_e.get() or 'all', n)
            out = sibling(p, '_ocr', '.txt')
            w = max(_entry_int(width_e, 2000), 1200)      # OCR 太糊会认不出, 至少 1200px
            r = ocr_text(p, out, pg, lang=(_LANG[0] or None), width=w, cancel=lambda: _CANCEL[0],
                         on_page=lambda i, t, _pg: log('  识别 %d/%d' % (i, t))
                         if (i % 3 == 0 or i == t) else None)
            log('OCR 完成: %s (%s, %d 字符, 汉字 %d, 引擎 %s)'
                % (out, human(r['size']), r['chars'], r['cjk'], r['lang'] or '?'))
            if r['chars'] < 10:
                log('  几乎没认出来 —— 页面可能是纯图/太小, 试着把「宽度」调大')
        spawn('OCR 取字', work)

    def do_raster():
        def work():
            p = pick_one()
            w = _entry_int(width_e, 1240)
            out = sibling(p, '_small')
            log('  这条是**有损**的: 文字/矢量/链接会变成图片')
            r = compress_raster(p, out, width=w, cancel=lambda: _CANCEL[0],
                                on_page=lambda i, t, _pg: log('  渲染 %d/%d' % (i, t))
                                if (i % 5 == 0 or i == t) else None)
            log('已重排为图片 PDF: %s (%.1f%%: %s -> %s, %d 页)'
                % (out, r['ratio'], human(r['before']), human(r['size']), r['pages']))
        spawn('压缩(转图片)', work)

    ui.flat_button(content, '拆分', do_split, x=12, y=194, w=196, h=32)
    ui.flat_button(content, '合并', do_merge, x=222, y=194, w=196, h=32)
    ui.flat_button(content, '旋转', do_rotate, x=432, y=194, w=196, h=32)
    ui.flat_button(content, '删页', do_delete, x=12, y=232, w=196, h=32)
    ui.flat_button(content, '提取文字', do_extract, x=222, y=232, w=196, h=32)
    ui.flat_button(content, '分析', do_analyze, x=432, y=232, w=196, h=32)
    ui.flat_button(content, '转图片', do_images, x=12, y=270, w=196, h=32)
    ui.flat_button(content, 'OCR 取字', do_ocr, x=222, y=270, w=196, h=32)
    ui.flat_button(content, '压缩(转图片)', do_raster, x=432, y=270, w=196, h=32)

    def do_cancel():
        _CANCEL[0] = True
        log('已请求取消 (纯 Python 的循环会在下一页停下; WinRT 操作会杀掉助手, 下次稍慢)')

    ui.flat_button(content, '取消当前操作', do_cancel, x=12, y=540, w=140, h=36)
    ui.flat_button(content, '打开输出目录', lambda: _open_dir(log, pick_one), x=160, y=540, w=140, h=36)
    ui.flat_button(content, '关闭', win.destroy, x=308, y=540, w=96, h=36)
    tk.Label(content, text='pypdf + Windows WinRT · 不联网 · 不修改原文件', bg=ui.BG, fg=ui.SUB,
             font=ui.font(8)).place(x=412, y=540, width=216, height=36)
    win.after(0, lambda: lb.focus_set())
    return win


def _open_dir(log, pick_one):
    """在资源管理器里打开"当前文件所在目录" (输出都在它旁边)。"""
    try:
        p = pick_one()
        d = os.path.dirname(os.path.abspath(p))
        os.startfile(d)                                         # noqa: S606 (Windows 专用)
        log('已打开 %s' % d)
    except Exception as ex:
        log('打开目录失败: %r' % (ex,))
