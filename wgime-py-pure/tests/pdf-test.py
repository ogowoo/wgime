# -*- coding: utf-8 -*-
r"""PDF 插件回归 (第七十七轮).

测三件事, 顺序就是它们的因果链:
  1. **单文件成品里真的内嵌了能用的 pypdf** —— 从 dist 的 `THIRD_ZIP_B64` 解出 zip, 挂到
     sys.path 最前面再 import, 并断言 `pypdf.__file__` 就在那个 zip 里(否则"构建机装了 pypdf"
     会把"内嵌漏了"糊过去; 同第六十九轮的 six 教训)。
  2. **插件的纯逻辑层** (合并/拆分/旋转/删页/取字/分析/压缩/页号解析/不覆盖写) 全部真跑一遍。
  3. **插件契约** (CODE/callable run/PERM) —— `main.load_py_plugins()` 要求的就是这三样,
     少一样整个插件会被静默丢弃(error='plugin must define CODE and callable run()')。

fixture 一律**现造** (第七十六轮规矩): 脚本里手写一个带正确 xref 的 PDF(可切 FlateDecode),
不用机器上任何现成文件、也不写绝对路径 —— 换台机器照样跑。

跑法: python wgime-py-pure\tests\pdf-test.py
"""
import base64
import io
import os
import re
import shutil
import sys
import tempfile
import zipfile
import importlib.util
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
DIST = os.path.join(PURE, 'dist', 'wgime-py.py')
PLUGIN = os.path.join(PURE, 'plugins', 'pdf.py')

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-58s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


# ----------------------------------------------------------------------
# fixture: 最小但**合法**的 PDF (正确 xref + trailer + 可选 /Info)
# ----------------------------------------------------------------------
def mk_pdf(path, pages=3, flate=False, info=True, lines=8):
    """lines=0 -> 内容流是空的(模拟"图片/扫描型": 一点文字都取不到)。"""
    objs = {}
    font_num = 3
    page_nums = []
    content_nums = []
    num = 3
    for _ in range(pages):
        num += 1
        page_nums.append(num)
    for _ in range(pages):
        num += 1
        content_nums.append(num)
    info_num = num + 1
    objs[1] = b'<</Type/Catalog/Pages 2 0 R>>'
    if info:
        objs[info_num] = b'<</Title(WgIme PDF Test)/Author(probe)/Producer(handmade fixture)>>'
    objs[2] = ('<</Type/Pages/Kids[%s]/Count %d>>' %
               (' '.join('%d 0 R' % p for p in page_nums), pages)).encode()
    for i, pn in enumerate(page_nums):
        objs[pn] = ('<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]'
                    '/Resources<</Font<</F1 %d 0 R>>>>/Contents %d 0 R>>'
                    % (font_num, content_nums[i])).encode()
    objs[font_num] = b'<</Type/Font/Subtype/Type1/BaseFont/Helvetica/Encoding/WinAnsiEncoding>>'
    for i, cn in enumerate(content_nums):
        body = ''
        for k in range(lines):
            body += ('BT /F1 %d Tf 72 %d Td (Page %d line %d: Hello PDF World, this is a text-heavy '
                     'fixture used by the WgIme pdf-test regression) Tj ET\n'
                     % (12, 700 - k * 20, i + 1, k + 1))
        body = body.encode()
        if not body:
            body = b''                                # 空内容流 = 取不到任何文字
        if flate and body:
            body = zlib.compress(body)
            filt = b'/Filter/FlateDecode'
        else:
            filt = b''
        objs[cn] = (b'<</Length ' + str(len(body)).encode() + filt + b'>>\nstream\n'
                    + body + b'\nendstream')

    buf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offs = {}
    for k in sorted(objs):
        offs[k] = len(buf)
        buf += ('%d 0 obj\n' % k).encode() + objs[k] + b'\nendobj\n'
    xref = len(buf)
    mx = max(objs)
    buf += ('xref\n0 %d\n' % (mx + 1)).encode() + b'0000000000 65535 f \n'
    for k in range(1, mx + 1):
        if k in offs:
            buf += ('%010d 00000 n \n' % offs[k]).encode()
        else:
            buf += b'0000000000 65535 f \n'
    tr = b'<</Size %d/Root 1 0 R' % (mx + 1)
    if info:
        tr += b'/Info %d 0 R' % info_num
    tr += b'>>'
    buf += b'trailer\n' + tr + ('\nstartxref\n%d\n%%%%EOF\n' % xref).encode()
    with open(path, 'wb') as f:
        f.write(bytes(buf))
    return len(buf)


def ui_check(mod):
    """UI 层真建窗口(需要桌面; 没有就 SKIP)。测三件在纯逻辑层测不到的事:

    ① run() 能建出窗口, 且**没有控件被窗口裁掉**(AGENTS §42 的审计法: 遍历 content 子控件算绝对 x+w/y+h);
    ② **子线程 -> win.after(0, ..) -> 主线程改控件** 这条路真的通 —— 操作日志/进度全走它, 不通的话
       用户看到的是"窗口像死的", 重活却在后台跑;
       **注意测法**: 必须真跑 `mainloop()`。用 `root.update()` 循环时 `_tkinter` 会以
       "main thread is not in main loop" 拒绝子线程的 `after`(假红), 我第一版探针就是这么被骗的。
    ③ 重复调 run() 是单例(抬起旧窗, 不叠第二个)。
    """
    import tkinter as tk
    import threading
    import time
    sys.path.insert(0, PURE)                     # run() 里要 import ui
    root = tk.Tk()
    root.withdraw()
    win = mod.run()
    root.update_idletasks()
    W, H = win.winfo_width(), win.winfo_height()
    content = None
    for ch in win.winfo_children():
        if ch.winfo_y() == 38:                   # ui.make_window 的 content 在标题栏(38px)之下
            content = ch
            break
    check('[UI] run() 建出窗口且 content 在位', content is not None, 'H=%s' % H)

    clipped = []
    n_widgets = 0
    if content is not None:
        CH = H - 38
        for ch in content.winfo_children():
            n_widgets += 1
            x, y = ch.winfo_x(), ch.winfo_y()
            w, h = ch.winfo_width(), ch.winfo_height()
            if x + w > W or y + h > CH:
                clipped.append((str(ch), x, y, w, h))
    check('[UI] %d 个控件没有一个越出窗口 (§42 裁切审计)' % n_widgets, not clipped, repr(clipped[:3]))

    # **重叠审计**: 只查"越出窗口"是不够的 —— 第七十七轮 P2 就漏过一次真重叠(第 3 行操作磁贴
    # y=270 正压在"页码范围/角度"那行 y=272 上, 而越界审计全绿: 两边都在窗口内)。
    # 判据: 两个兄弟控件的矩形**真相交**(贴边不算), 全部用 place() 显式坐标摆的窗口必须两两不重叠。
    rects = []
    if content is not None:
        for ch in content.winfo_children():
            rects.append((str(ch), ch.winfo_x(), ch.winfo_y(), ch.winfo_width(), ch.winfo_height()))
    over = []
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            a, b = rects[i], rects[j]
            if (a[1] + a[3] > b[1] and b[1] + b[3] > a[1]
                    and a[2] + a[4] > b[2] and b[2] + b[4] > a[2]):
                over.append((a[0], b[0], (a[1], a[2], a[3], a[4]), (b[1], b[2], b[3], b[4])))
    check('[UI] %d 个控件两两不重叠' % len(rects), not over, repr(over[:3]))

    state = {'seen': [], 'txt': '', 'win2': None, 'tops': (0, 0)}

    def from_thread():
        time.sleep(0.3)
        win.after(0, lambda: state['seen'].append('t2m'))

    threading.Thread(target=from_thread, daemon=True).start()

    def finish():
        state['txt'] = mod._W['tb'].get('1.0', 'end')
        n0 = len([w for w in root.winfo_children() if isinstance(w, tk.Toplevel)])
        state['win2'] = mod.run()
        state['tops'] = (n0, len([w for w in root.winfo_children() if isinstance(w, tk.Toplevel)]))
        root.quit()

    root.after(5000, finish)                     # 主线程里排的 after(合法), 到点收网退出 mainloop
    root.mainloop()

    check('[UI] 子线程 after 回调到达主线程', bool(state['seen']))
    check('[UI] 后台预热的引擎日志到达主线程', '引擎就绪' in state['txt'], repr(state['txt'][-80:]))
    check('[UI] 重复 run() 是单例(抬起, 不叠窗)',
          state['win2'] is win and state['tops'] == (1, 1), repr(state['tops']))
    try:
        win.destroy()
    except Exception:
        pass


def main():
    print('dist   = %s' % DIST)
    print('plugin = %s' % PLUGIN)
    if not os.path.exists(DIST):
        print('  dist 不存在, 先跑 build-package.ps1')
        return 1

    # ---- 1) 从**成品**里解出内嵌 zip, 并让 pypdf 只能来自它 ----
    txt = io.open(DIST, encoding='utf-8', errors='replace').read()
    m = re.search(r"THIRD_ZIP_B64 = '(.*?)'\n", txt, re.S)
    check('dist 里有 THIRD_ZIP_B64', m is not None)
    if not m:
        return 1
    blob = base64.b64decode(m.group(1))
    tmp = tempfile.mkdtemp(prefix='wg-pdf-test-')
    try:
        zp = os.path.join(tmp, 'thirdparty.zip')
        with open(zp, 'wb') as f:
            f.write(blob)
        names = zipfile.ZipFile(io.BytesIO(blob)).namelist()
        check("内嵌 zip 里有 pypdf 包", any(x.startswith('pypdf/') for x in names))
        sys.path.insert(0, zp)
        import pypdf
        check('import pypdf 命中的是**内嵌**那份 (不是 site-packages)',
              os.path.abspath(pypdf.__file__).startswith(os.path.abspath(tmp)),
              pypdf.__file__)

        # ---- 2) 加载插件模块 (不调 run(), 那需要 Tk/宿主 ui) ----
        spec = importlib.util.spec_from_file_location('wg_pdf_plugin_under_test', PLUGIN)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        print('  pypdf %s / plugin %s v%s' % (pypdf.__version__, mod.CODE, mod.VERSION))

        # ---- 3) 插件契约 ----
        check("CODE == 'pdf' (上屏编码)", mod.CODE == 'pdf', repr(getattr(mod, 'CODE', None)))
        check('run 可调用 (load_py_plugins 硬要求)', callable(getattr(mod, 'run', None)))
        check('PERM=low -> 运行前不弹权限确认', mod.PERM == 'low', repr(mod.PERM))
        check('DESC/NAME/VERSION 都有', bool(mod.DESC and mod.NAME and mod.VERSION))

        d = os.path.join(tmp, 'work')
        os.makedirs(d)
        a = os.path.join(d, 'a.pdf')
        b = os.path.join(d, 'b.pdf')
        bad = os.path.join(d, 'bad.pdf')
        tiny = os.path.join(d, 'tiny.pdf')
        na = mk_pdf(a, 3)
        nb = mk_pdf(b, 2, flate=True)
        mk_pdf(tiny, 1, lines=0)
        with open(bad, 'wb') as f:
            f.write(b'this is not a pdf at all')
        print('  fixture: a.pdf %dB(3页, 未压缩) b.pdf %dB(2页, FlateDecode) tiny.pdf(1页, 空内容流)'
              % (na, nb))

        # ---- 页号解析 ----
        pr = mod.parse_ranges
        check("parse_ranges '1-3' -> [1,2,3]", pr('1-3', 10) == [1, 2, 3], repr(pr('1-3', 10)))
        check("parse_ranges '1-2,4' -> [1,2,4]", pr('1-2,4', 10) == [1, 2, 4], repr(pr('1-2,4', 10)))
        check("parse_ranges '5-3' 倒着写 -> [3,4,5]", pr('5-3', 10) == [3, 4, 5], repr(pr('5-3', 10)))
        check("parse_ranges '' / all -> 全部", pr('', 3) == [1, 2, 3] and pr('all', 3) == [1, 2, 3])
        check('parse_ranges 去重 + 升序', pr('6,2,2,1', 10) == [1, 2, 6], repr(pr('6,2,2,1', 10)))
        check('parse_ranges 超范围的值丢弃(不报错)', pr('1,99', 3) == [1], repr(pr('1,99', 3)))
        check('parse_ranges 全角逗号也认', pr('1，3', 5) == [1, 3], repr(pr('1，3', 5)))
        try:
            pr('abc', 5)
            check('parse_ranges 无效输入抛 PdfError', False, '没有抛异常')
        except mod.PdfError:
            check('parse_ranges 无效输入抛 PdfError', True)
        check('norm_pages 收整数列表也钳范围', mod.norm_pages([1, 9, 2, 2], 3) == [1, 2])

        # ---- 不覆盖写 ----
        p1 = os.path.join(d, 'out.pdf')
        check('unique_path: 不存在时原样返回', mod.unique_path(p1) == p1)
        open(p1, 'wb').write(b'x')
        check('unique_path: 已存在则 -2', mod.unique_path(p1).endswith('out-2.pdf'),
              mod.unique_path(p1))
        check('sibling: 后缀写在扩展名之前', mod.sibling(a, '_split').endswith('a_split.pdf'),
              mod.sibling(a, '_split'))

        # ---- 分析 ----
        info = mod.analyze(a)
        check('analyze: 页数 = 3', info['pages'] == 3, repr(info['pages']))
        check('analyze: 版本 = %PDF-1.4', info['version'] == '%PDF-1.4', repr(info['version']))
        check("analyze: 判为'文字型'", info['kind'] == '文字型', repr(info['kind']))
        check('analyze: 空内容流(扫描件形状)判为 图片/扫描型',
              mod.analyze(tiny)['kind'] == '图片/扫描型', repr(mod.analyze(tiny)['kind']))
        check('analyze: 取到 /Info 元数据', info['meta'].get('标题') == 'WgIme PDF Test', repr(info['meta']))
        check('analyze: 文字量 > 0', info['text_chars'] > 50, repr(info['text_chars']))
        check('analyze: 未加密', info['encrypted'] is False)
        check('analyze: 页面尺寸 612x792', '612 x 792' in info['page_size'], repr(info['page_size']))

        # ---- 提取文字 ----
        out_txt = os.path.join(d, 'a.txt')
        et = mod.extract_text(a, out_txt)
        raw = io.open(out_txt, encoding='utf-8-sig').read()
        check('extract_text: 写出 txt 且带 BOM(记事本友好)',
              open(out_txt, 'rb').read(3) == b'\xef\xbb\xbf')
        check("extract_text: 含 'Hello PDF World'", 'Hello PDF World' in raw, repr(raw[:60]))
        check('extract_text: 3 页都在 (每页首行都能找到)',
              all(('Page %d line 1' % i) in raw for i in (1, 2, 3)), repr(raw[:60]))
        check('extract_text: 字符数对得上', et['chars'] == len(raw), '%r vs %r' % (et['chars'], len(raw)))

        # ---- 合并 ----
        out_m = os.path.join(d, 'merged.pdf')
        r = mod.merge([a, b], out_m)
        check('merge: 3+2 = 5 页', r['pages'] == 5, repr(r['pages']))
        check('merge: 输出文件存在且 > 0', os.path.getsize(out_m) > 0)
        try:
            mod.merge([a], os.path.join(d, 'm1.pdf'))
            check('merge: 只给 1 个文件 -> PdfError', False, '没有抛异常')
        except mod.PdfError:
            check('merge: 只给 1 个文件 -> PdfError', True)

        # ---- 拆分 ----
        out_s = os.path.join(d, 'split.pdf')
        r = mod.split(a, out_s, '1,3')
        check('split: 抽 1,3 两页 -> 2 页', r['pages'] == 2, repr(r))
        r = mod.split(a, os.path.join(d, 'split_all.pdf'), '')
        check('split: 空范围 = 全部 3 页', r['pages'] == 3, repr(r))
        outdir = os.path.join(d, 'each')
        r = mod.split_each(a, outdir)
        check('split_each: 3 页 -> 3 个文件', r['count'] == 3, repr(r['count']))
        check('split_each: 文件名带页号 p001', os.path.basename(r['files'][0]) == 'a_p001.pdf',
              os.path.basename(r['files'][0]))
        # 取消: 第一页之后就停 (证明 cancel 回调真的接进了循环)
        cnt = [0]
        outdir2 = os.path.join(d, 'each_cancel')
        r = mod.split_each(a, outdir2, cancel=lambda: cnt[0] >= 1,
                           on_page=lambda *_: cnt.__setitem__(0, cnt[0] + 1))
        check('split_each: cancel 之后停下(不再产出全部)', r['count'] < 3, repr(r['count']))

        # ---- 旋转 ----
        out_r = os.path.join(d, 'rot.pdf')
        r = mod.rotate(a, out_r, '1', angle=90)
        back = pypdf.PdfReader(out_r)
        check('rotate: 第 1 页 /Rotate = 90', int(back.pages[0].rotation) == 90,
              repr(back.pages[0].rotation))
        check('rotate: 其它页没被转', int(back.pages[1].rotation) == 0, repr(back.pages[1].rotation))
        r = mod.rotate(a, os.path.join(d, 'rot180.pdf'), 'all', angle=180)
        back = pypdf.PdfReader(os.path.join(d, 'rot180.pdf'))
        check('rotate: 全部页 180', all(int(p.rotation) == 180 for p in back.pages))
        try:
            mod.rotate(a, os.path.join(d, 'rot45.pdf'), '1', angle=45)
            check('rotate: 非 90/180/270 -> PdfError', False, '没有抛异常')
        except mod.PdfError:
            check('rotate: 非 90/180/270 -> PdfError', True)

        # ---- 删页 ----
        out_d = os.path.join(d, 'del.pdf')
        r = mod.delete(a, out_d, [2])
        check('delete: 删 1 页 -> 剩 2 页', r['left'] == 2 and r['deleted'] == 1, repr(r))
        check('delete: 删掉的确实是第 2 页',
              'Page 1' in (pypdf.PdfReader(out_d).pages[0].extract_text() or ''))
        try:
            mod.delete(a, os.path.join(d, 'delall.pdf'), 'all')
            check('delete: 全删 -> PdfError', False, '没有抛异常')
        except mod.PdfError:
            check('delete: 全删 -> PdfError', True)

        # ---- 结构压缩 (不承诺能压小, 只承诺不炸且输出合法) ----
        out_c = os.path.join(d, 'comp.pdf')
        r = mod.compress_lossless(a, out_c)
        check('compress_lossless: 输出合法 PDF', len(pypdf.PdfReader(out_c).pages) == 3, repr(r))
        check('compress_lossless: 如实给出压缩比字段', 'ratio' in r and r['ratio'] > 0, repr(r))

        # ---- 错误路径全是人话 (PdfError), 不能冒 traceback ----
        for label, fn in (
                ('文件不存在', lambda: mod.analyze(os.path.join(d, 'nope.pdf'))),
                ('垃圾文件', lambda: mod.analyze(bad)),
                ('旋转不存在的页', lambda: mod.rotate(a, os.path.join(d, 'x.pdf'), '99'))):
            try:
                fn()
                check('%s -> PdfError' % label, False, '没有抛异常')
            except mod.PdfError:
                check('%s -> PdfError' % label, True)
            except Exception as ex:
                check('%s -> PdfError' % label, False, '抛了 %r' % (ex,))

        # ---- P2 纯 Python 部分: 尺寸解析 + "图片拼 PDF" ----
        print('  --- P2: 尺寸解析 + 图片拼 PDF (纯 Python, 不依赖 pypdf 的图片 API) ---')
        # 手搓一个"看起来像 JPEG"的字节流: 尺寸解析只读 SOF 标记, 不解码像素 ——
        # 所以 fixture 可以完全自足(不需要任何真图片文件)。
        jpg_small = (b'\xff\xd8'
                     + b'\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00'
                     + b'\xff\xc0\x00\x11\x08' + bytes([0x01, 0xF4]) + bytes([0x02, 0x58])
                     + b'\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01'
                     + b'\xff\xd9')
        check('jpeg_size: 从 SOF0 读出 (宽600, 高500)', mod.jpeg_size(jpg_small) == (600, 500),
              repr(mod.jpeg_size(jpg_small)))
        check('jpeg_size: 非 JPEG -> None', mod.jpeg_size(b'definitely not a jpeg') is None)
        check('jpeg_size: 截断字节流 -> None (不抛)', mod.jpeg_size(jpg_small[:12]) is None)
        png_small = (b'\x89PNG\r\n\x1a\n' + b'\x00\x00\x00\rIHDR'
                     + (1240).to_bytes(4, 'big') + (1754).to_bytes(4, 'big'))
        check('png_size: 从 IHDR 读出 (1240x1754)', mod.png_size(png_small) == (1240, 1754),
              repr(mod.png_size(png_small)))
        check('png_size: 非 PNG -> None', mod.png_size(b'nope') is None)

        out_j = os.path.join(d, 'fromjpg.pdf')
        mod.build_pdf_from_jpegs([(jpg_small, 600, 500, 612.0, 792.0),
                                  (jpg_small, 600, 500, 300.0, 200.0)], out_j)
        rj = pypdf.PdfReader(out_j)
        check('build_pdf_from_jpegs: 2 页, 页尺寸用原 mediabox',
              len(rj.pages) == 2
              and abs(float(rj.pages[0].mediabox.width) - 612.0) < 0.1
              and abs(float(rj.pages[1].mediabox.height) - 200.0) < 0.1,
              repr([(float(p.mediabox.width), float(p.mediabox.height)) for p in rj.pages]))
        check('build_pdf_from_jpegs: 图片以 /DCTDecode 原样内嵌(不重编码)',
              b'/DCTDecode' in open(out_j, 'rb').read())
        try:
            mod.build_pdf_from_jpegs([], os.path.join(d, 'empty.pdf'))
            check('build_pdf_from_jpegs: 空列表 -> PdfError', False, '没有抛异常')
        except mod.PdfError:
            check('build_pdf_from_jpegs: 空列表 -> PdfError', True)

        # ---- P2 WinRT 部分 (没装/没有 WinRT 就 SKIP 整段) ----
        print('  --- P2: WinRT 栅格化 + OCR + 有损压缩 (无 WinRT 则 SKIP) ---')
        info = mod.winrt_info()
        if not info.get('ok'):
            print('  %-58s SKIP %s' % ('WinRT 段', (info.get('error') or '')[:100]))
        else:
            check('WinRT: 助手就绪并报出 OCR 语言包', bool(info.get('ocr')), repr(info))
            print('  WinRT 就绪 %.1fs, OCR 语言 = %s'
                  % (info.get('boot_ms', 0) / 1000.0, ','.join(info.get('ocr') or [])))
            dirimg = os.path.join(d, 'imgs')
            r = mod.render_images(a, dirimg, [1, 2, 3], width=1240, fmt='png')
            check('render_images: 3 页 -> 3 个 png', r['count'] == 3 and
                  all(os.path.exists(f['path']) for f in r['files']), repr(r['count']))
            check('render_images: 文件名带页号 + 尺寸已解析',
                  os.path.basename(r['files'][0]['path']) == 'a_p001.png'
                  and r['files'][0]['w'] > 100 and r['files'][0]['h'] > 100,
                  repr((os.path.basename(r['files'][0]['path']), r['files'][0]['w'], r['files'][0]['h'])))
            r1 = mod.render_images(a, dirimg, [2], width=800, fmt='jpg')
            check('render_images: 只渲染指定页 + jpg 尺寸解析',
                  r1['count'] == 1 and r1['files'][0]['page'] == 2 and r1['files'][0]['w'] == 800,
                  repr((r1['count'], r1['files'][0]['w'])))
            # OCR: 我们的 fixture 是 1240px 渲染的 Helvetica 文字, OCR 会把它读回来
            _, _, _, _, _ = (0, 0, 0, 0, 0)
            out_o = os.path.join(d, 'ocr.txt')
            ro = mod.ocr_text(a, out_o, [1, 2], lang=None, width=2000)
            body = io.open(out_o, encoding='utf-8-sig').read().lower()
            check('ocr_text: 认出 fixture 的文字 (含 page/pdf)', ro['chars'] > 20
                  and 'pdf' in body and 'page 1' in body, repr(body[:70]))
            check('ocr_text: 写成 UTF-8(BOM) 的 txt + 报出引擎语言',
                  open(out_o, 'rb').read(3) == b'\xef\xbb\xbf' and bool(ro['lang']), repr(ro['lang']))
            # 有损压缩: fixture 太小(1.4KB), 栅格化后**必然变大** —— 这里只断言"产出合法 PDF",
            # 真实收益(图片型 PDF ~10x)见 AGENTS-DETAIL §D16, 别用这个 fixture 去证明压缩率。
            out_c2 = os.path.join(d, 'raster.pdf')
            rc = mod.compress_raster(a, out_c2, width=1240)
            rc2 = pypdf.PdfReader(out_c2)
            check('compress_raster: 产出合法 PDF, 页数一致',
                  len(rc2.pages) == 3 and rc['pages'] == 3, repr((len(rc2.pages), rc['ratio'])))
            check('compress_raster: 如实报出 before/size/ratio',
                  rc['before'] > 0 and rc['size'] > 0 and rc['ratio'] > 0, repr(rc['ratio']))
            print('  (fixture 只有 %d B, 所以 ratio=%.0f%% —— 小文字 PDF 栅格化必然变大, 这是预期)'
                  % (rc['before'], rc['ratio']))
            # 取消的机制是"杀掉助手", 下次调用要能自动重启 —— 这条必须验(否则取消一次就永久废掉)
            mod._w32().shutdown()
            info2 = mod.winrt_info()
            check('取消/杀掉助手后能自动重启 (冷启)', bool(info2.get('ok')), repr(info2)[:120])
            mod._w32().shutdown()

        # ---- UI 层 (要真桌面; 没有就 SKIP) ----
        try:
            import tkinter as _tk
            ui_check(mod)
        except ImportError:
            print('  %-58s SKIP %s' % ('UI 层真建窗口', 'no tkinter'))
        except Exception as _ex:
            if type(_ex).__name__ in ('TclError', 'TclError_'):
                print('  %-58s SKIP %s' % ('UI 层真建窗口', 'no desktop: %s' % _ex))
            else:
                check('UI 层真建窗口', False, '%r' % (_ex,))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
