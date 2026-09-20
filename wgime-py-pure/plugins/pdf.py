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
import os
import threading

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
# UI 层 (只在这里 import tkinter / ui)
# ======================================================================
_W = {'win': None, 'tb': None}          # 单例窗口 + 日志控件
_BUSY = [False]
_CANCEL = [False]
_ANGLE = [90]


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

    # 内容区需要 540px, 标题栏 38px (ui.make_window 的 content 只占 h-38, 见 AGENTS §42)
    W, H = 640, 584
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

    def del_sel():
        for i in reversed(list(lb.curselection())):
            lb.delete(i)
        log('移除选中, 剩 %d 个' % lb.size())

    def clear_all():
        lb.delete(0, 'end')
        log('已清空文件列表')

    ui.flat_button(content, '添加 PDF…', add_files, x=12, y=62, w=118, h=32)
    ui.flat_button(content, '移除选中', del_sel, x=136, y=62, w=92, h=32)
    ui.flat_button(content, '清空', clear_all, x=234, y=62, w=72, h=32)
    tk.Label(content, text='输出写到源文件同目录(带 _后缀) · 绝不覆盖原文件',
             bg=ui.BG, fg=ui.SUB, font=ui.font(8.5), anchor='w').place(x=316, y=62, width=312, height=32)

    lb = tk.Listbox(content, font=ui.font(9), bg=ui.CARD, fg=ui.TEXT, bd=0,
                    highlightthickness=1, highlightbackground=ui.BORDER,
                    selectmode=tk.EXTENDED, activestyle='none')
    lb.place(x=12, y=100, width=616, height=86)

    # ---- 参数行 ----
    tk.Label(content, text='页码范围', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=12, y=272, width=62, height=32)
    range_e = ui.rounded_entry(content, x=76, y=272, w=150, h=32)
    tk.Label(content, text='角度', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5),
             anchor='w').place(x=238, y=272, width=34, height=32)
    angle_btns = {}
    for i, (txt, deg) in enumerate((('90°', 90), ('180°', 180), ('270°', 270))):
        b = ui.flat_button(content, txt, (lambda d: (lambda: _set_angle(d)))(deg),
                           x=274 + i * 54, y=272, w=50, h=32)
        angle_btns[deg] = b
    each_var = tk.IntVar(value=0)
    chk = tk.Checkbutton(content, text='拆分: 每页一个文件', variable=each_var, bg=ui.BG, fg=ui.SUB,
                         font=ui.font(8.5), activebackground=ui.BG, selectcolor=ui.CARD,
                         bd=0, highlightthickness=0, anchor='w', cursor='hand2')
    chk.place(x=440, y=272, width=188, height=32)

    def _set_angle(d):
        _ANGLE[0] = d
        for deg, btn in angle_btns.items():
            try:
                btn.configure(bg=ui.ACCENT if deg == d else ui.CARD,
                              fg='white' if deg == d else ui.TEXT)
            except Exception:
                pass
        log('旋转角度 = %d°' % d)

    _set_angle(_ANGLE[0])

    # ---- 日志 ----
    tb = ui.console_text(content, x=12, y=312, w=616, h=170)
    _W['tb'] = tb
    log('就绪。先「添加 PDF…」, 再点下面任意一个操作。引擎: pypdf(内嵌, 后台预热中…)')

    # ---- 后台预热 pypdf (zipimport 冷启实测 ~865ms; 不预热的话第一次点按钮会像卡住) ----
    def warm():
        try:
            pypdf = _pypdf()
            log('引擎就绪: pypdf %s' % getattr(pypdf, '__version__', '?'))
        except Exception as ex:
            log('引擎不可用: %s' % ex)
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

    ui.flat_button(content, '拆分', do_split, x=12, y=194, w=196, h=32)
    ui.flat_button(content, '合并', do_merge, x=222, y=194, w=196, h=32)
    ui.flat_button(content, '旋转', do_rotate, x=432, y=194, w=196, h=32)
    ui.flat_button(content, '删页', do_delete, x=12, y=232, w=196, h=32)
    ui.flat_button(content, '提取文字', do_extract, x=222, y=232, w=196, h=32)
    ui.flat_button(content, '分析', do_analyze, x=432, y=232, w=196, h=32)

    def do_cancel():
        _CANCEL[0] = True
        log('已请求取消 (正在跑的循环会在下一页停下来)')

    ui.flat_button(content, '取消当前操作', do_cancel, x=12, y=492, w=140, h=36)
    ui.flat_button(content, '打开输出目录', lambda: _open_dir(log, pick_one), x=160, y=492, w=140, h=36)
    ui.flat_button(content, '关闭', win.destroy, x=308, y=492, w=96, h=36)
    tk.Label(content, text='pypdf 引擎 · 不联网 · 不修改原文件', bg=ui.BG, fg=ui.SUB,
             font=ui.font(8)).place(x=412, y=492, width=216, height=36)
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
