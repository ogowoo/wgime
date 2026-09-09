# -*- coding: utf-8 -*-
"""wgime-qr.py — 二维码生成器 (纯 Python + tkinter 移植自 C# 插件 wgime-qr-clean-border-style-v2.5).

内嵌 QR 编码器移植自 Project Nayuki 的 QR Code generator 算法 (与 C# 版同源):
  Copyright (c) Project Nayuki. MIT License.
  https://www.nayuki.io/page/qr-code-generator-library

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions: The above copyright notice and this
permission notice shall be included in all copies or substantial portions of
the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

功能: 完全离线生成二维码; 简洁圆角细边框; 支持上下方说明文字;
UTF-8 + ECI 26; 默认 M 级纠错 (QR Model 2, version 1..10, byte mode).
保存 PNG 为纯 Python 手工 PNG (zlib+struct); 复制图片走 ctypes CF_DIB 剪贴板.
"""
import math
import struct
import time
import zlib
from collections import deque

CODE = 'qrcode'
NAME = '二维码生成器'
DESC = '完全离线生成二维码；简洁圆角细边框；支持上下方说明文字；UTF-8 + ECI 26；默认 M 级纠错'
VERSION = '2.5'
AUTHOR = 'WgIme / Project Nayuki derived encoder'
PERM = 'low'


# ======================================================================
# QR Model 2 byte-mode 编码器: versions 1..10, ECC M, ECI 26 (UTF-8)
# ======================================================================
class _Bits(object):
    def __init__(self):
        self.a = []

    def put(self, v, n):
        for i in range(n - 1, -1, -1):
            self.a.append(((v >> i) & 1) != 0)

    def to_bytes(self):
        r = bytearray((len(self.a) + 7) // 8)
        for i, b in enumerate(self.a):
            if b:
                r[i >> 3] |= 1 << (7 - (i & 7))
        return bytes(r)


_TOTAL = (0, 26, 44, 70, 100, 134, 172, 196, 242, 292, 346)   # 每版本原始码字数
_ECC = (0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26)            # 每块 ECC 码字数 (M 级)
_BLOCKS = (0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5)                   # 块数 (M 级)


def qr_encode(text):
    """文本 -> Qr 对象 (version/size/modules/mask). 超长抛 ValueError."""
    data = text.encode('utf-8')
    for v in range(1, 11):
        cap = _TOTAL[v] - _ECC[v] * _BLOCKS[v]
        cc = 8 if v <= 9 else 16
        if 12 + 4 + cc + len(data) * 8 <= cap * 8:
            return _Qr(v, data, cc, cap)
    raise ValueError('内容过长，本地紧凑编码器最多支持约 213 个 UTF-8 字节')


class _Qr(object):
    def __init__(self, v, src, cc, data_cw):
        self.version = v
        self.size = v * 4 + 17
        self.mask = -1
        b = _Bits()
        b.put(7, 4)                     # ECI mode
        b.put(26, 8)                    # ECI 26 = UTF-8
        b.put(4, 4)                     # byte mode
        b.put(len(src), cc)
        for x in src:
            b.put(x, 8)
        maxbits = data_cw * 8
        b.put(0, min(4, maxbits - len(b.a)))        # terminator
        while len(b.a) & 7:
            b.a.append(False)
        pad = 0xEC
        while len(b.a) < maxbits:
            b.put(pad, 8)
            pad = 0x11 if pad == 0xEC else 0xEC
        code = self._add_ecc(b.to_bytes(), v)
        self._build(code)

    # ---------- GF(2^8/0x11D) Reed-Solomon ----------
    @staticmethod
    def _mul(x, y):
        z = 0
        for i in range(7, -1, -1):
            z = (z << 1) ^ (((z >> 7) & 1) * 0x11D)
            if (y >> i) & 1:
                z ^= x
        return z & 0xFF

    @classmethod
    def _divisor(cls, d):
        r = bytearray(d)
        r[d - 1] = 1
        root = 1
        for _ in range(d):
            for j in range(d):
                r[j] = cls._mul(r[j], root)
                if j + 1 < d:
                    r[j] ^= r[j + 1]
            root = cls._mul(root, 2)
        return bytes(r)

    @classmethod
    def _remainder(cls, data, div):
        r = bytearray(len(div))
        for x in data:
            f = x ^ r[0]
            r = r[1:] + b'\x00'
            for i in range(len(r)):
                r[i] ^= cls._mul(div[i], f)
        return bytes(r)

    @classmethod
    def _add_ecc(cls, data, v):
        nb, ep, raw = _BLOCKS[v], _ECC[v], _TOTAL[v]
        short_len = raw // nb
        short_blocks = nb - raw % nb
        div = cls._divisor(ep)
        ds, es = [], []
        k = 0
        for i in range(nb):
            ln = short_len - ep + (0 if i < short_blocks else 1)
            d = data[k:k + ln]
            k += ln
            ds.append(d)
            es.append(cls._remainder(d, div))
        out = bytearray()
        mx = max(len(d) for d in ds)
        for j in range(mx):
            for i in range(nb):
                if j < len(ds[i]):
                    out.append(ds[i][j])
        for j in range(ep):
            for i in range(nb):
                out.append(es[i][j])
        return bytes(out)

    # ---------- 矩阵构建 ----------
    def _set(self, x, y, dark, fn):
        if 0 <= x < self.size and 0 <= y < self.size:
            self.modules[y][x] = dark
            if fn:
                self.fn[y][x] = True

    def _finder(self, cx, cy):
        for dy in range(-4, 5):
            for dx in range(-4, 5):
                d = max(abs(dx), abs(dy))
                self._set(cx + dx, cy + dy, d != 2 and d != 4, True)

    def _align_pos(self):
        v = self.version
        if v == 1:
            return []
        n = v // 7 + 2
        step = 26 if v == 32 else (v * 4 + n * 2 + 1) // (n * 2 - 2) * 2
        a = [0] * n
        a[0] = 6
        p = self.size - 7
        for i in range(n - 1, 0, -1):
            a[i] = p
            p -= step
        return a

    def _build(self, code):
        n = self.size
        self.modules = [[False] * n for _ in range(n)]
        self.fn = [[False] * n for _ in range(n)]
        for i in range(n):                                  # timing patterns
            self._set(6, i, i % 2 == 0, True)
            self._set(i, 6, i % 2 == 0, True)
        self._finder(3, 3)
        self._finder(n - 4, 3)
        self._finder(3, n - 4)
        ap = self._align_pos()
        na = len(ap)
        for i, x in enumerate(ap):              # 只跳过三个定位角 (对齐 Nayuki 参考实现;
            for j, y in enumerate(ap):          # 时序线上的 (6,k)/(k,6) 对齐图形必须画)
                if (i, j) in ((0, 0), (0, na - 1), (na - 1, 0)):
                    continue
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        self._set(x + dx, y + dy, max(abs(dx), abs(dy)) != 1, True)
        self._draw_format(0)                                # dummy; 之后按选定掩码重写
        if self.version >= 7:
            self._draw_version()
        self._place(code)
        # 8 种掩码逐个评分, 取罚分最低 (Nayuki 参考实现的完整罚分规则)
        base = [row[:] for row in self.modules]
        best, best_score = 0, None
        for m in range(8):
            self.modules = [row[:] for row in base]
            self._apply_mask(m)
            self._draw_format(m)
            s = self._penalty()
            if best_score is None or s < best_score:
                best, best_score = m, s
        self.modules = [row[:] for row in base]
        self._apply_mask(best)
        self._draw_format(best)
        self.mask = best

    def _place(self, data):
        n = self.size
        bit = 0
        right = n - 1
        while right >= 1:
            if right == 6:
                right -= 1
            for vert in range(n):
                y = n - 1 - vert if (right + 1) & 2 == 0 else vert
                for j in range(2):
                    x = right - j
                    if not self.fn[y][x]:
                        if bit < len(data) * 8:
                            self.modules[y][x] = ((data[bit >> 3] >> (7 - (bit & 7))) & 1) != 0
                        bit += 1
            right -= 2

    # ---------- 掩码 / 格式信息 / 版本信息 ----------
    @staticmethod
    def _mask_bit(m, x, y):
        if m == 0:
            return (x + y) % 2 == 0
        if m == 1:
            return y % 2 == 0
        if m == 2:
            return x % 3 == 0
        if m == 3:
            return (x + y) % 3 == 0
        if m == 4:
            return (x // 3 + y // 2) % 2 == 0
        if m == 5:
            return x * y % 2 + x * y % 3 == 0
        if m == 6:
            return (x * y % 2 + x * y % 3) % 2 == 0
        return ((x + y) % 2 + x * y % 3) % 2 == 0

    def _apply_mask(self, m):
        for y in range(self.size):
            for x in range(self.size):
                if not self.fn[y][x] and self._mask_bit(m, x, y):
                    self.modules[y][x] = not self.modules[y][x]

    def _draw_format(self, mask):
        data = mask                       # ECC M 的 format bits = 0
        rem = data
        for _ in range(10):
            rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537)
        bits = ((data << 10) | rem) ^ 0x5412
        n = self.size
        for i in range(6):
            self._set(8, i, (bits >> i) & 1 != 0, True)
        self._set(8, 7, (bits >> 6) & 1 != 0, True)
        self._set(8, 8, (bits >> 7) & 1 != 0, True)
        self._set(7, 8, (bits >> 8) & 1 != 0, True)
        for i in range(9, 15):
            self._set(14 - i, 8, (bits >> i) & 1 != 0, True)
        for i in range(8):
            self._set(n - 1 - i, 8, (bits >> i) & 1 != 0, True)
        for i in range(8, 15):
            self._set(8, n - 15 + i, (bits >> i) & 1 != 0, True)
        self._set(8, n - 8, True, True)

    def _draw_version(self):
        v = self.version
        rem = v
        for _ in range(12):
            rem = (rem << 1) ^ (((rem >> 11) & 1) * 0x1F25)
        bits = v << 12 | rem
        n = self.size
        for i in range(18):
            b = (bits >> i) & 1 != 0
            a = n - 11 + i % 3
            c = i // 3
            self._set(a, c, b, True)
            self._set(c, a, b, True)

    # ---------- 罚分 (Nayuki 参考实现完整规则 N1..N4, 含 finder-like pattern) ----------
    def _fp_add(self, runlen, hist):
        if hist[0] == 0:
            runlen += self.size
        hist.appendleft(runlen)

    @staticmethod
    def _fp_count(hist):
        n = hist[1]
        core = n > 0 and hist[2] == hist[4] == hist[5] == n and hist[3] == n * 3
        return ((1 if (core and hist[0] >= n * 4 and hist[6] >= n) else 0)
                + (1 if (core and hist[6] >= n * 4 and hist[0] >= n) else 0))

    def _fp_terminate(self, runcolor, runlen, hist):
        if runcolor:
            self._fp_add(runlen, hist)
            runlen = 0
        runlen += self.size
        self._fp_add(runlen, hist)
        return self._fp_count(hist)

    def _penalty(self):
        n = self.size
        mod = self.modules
        result = 0
        # N1 行/列同色连续 + N3 finder-like pattern
        for horizontal in (True, False):
            outer = range(n)
            for i in outer:
                runcolor = False
                runlen = 0
                hist = deque([0] * 7, 7)
                for j in range(n):
                    color = mod[i][j] if horizontal else mod[j][i]
                    if color == runcolor:
                        runlen += 1
                        if runlen == 5:
                            result += 3
                        elif runlen > 5:
                            result += 1
                    else:
                        self._fp_add(runlen, hist)
                        if not runcolor:
                            result += self._fp_count(hist) * 40
                        runcolor = color
                        runlen = 1
                result += self._fp_terminate(runcolor, runlen, hist) * 40
        # N2 2x2 同色块
        for y in range(n - 1):
            for x in range(n - 1):
                c = mod[y][x]
                if c == mod[y][x + 1] == mod[y + 1][x] == mod[y + 1][x + 1]:
                    result += 3
        # N4 明暗比例
        dark = sum(1 for row in mod for c in row if c)
        total = n * n
        k = (abs(dark * 20 - total * 10) + total - 1) // total - 1
        result += k * 10
        return result


# ======================================================================
# 图像渲染: 白卡 + 圆角细边框 + 上方标题 + 下方说明 + QR 矩阵
# (GDI ctypes 离屏 DIB 渲染文字; 失败时退化为无文字纯矩阵位图)
# ======================================================================
def _layout(qr, pixels, caption, footer):
    quiet = 4
    scale = max(1, pixels // (qr.size + quiet * 2))
    qr_size = (qr.size + quiet * 2) * scale
    border, radius = 12, 14
    title_h = 52 if caption and caption.strip() else 0
    footer_h = 44 if footer and footer.strip() else 0
    card_w = qr_size + border * 2
    card_h = qr_size + border * 2 + title_h
    gap = 8 if footer_h else 0
    return {'quiet': quiet, 'scale': scale, 'qr_size': qr_size, 'border': border,
            'radius': radius, 'title_h': title_h, 'footer_h': footer_h,
            'card_w': card_w, 'card_h': card_h, 'gap': gap,
            'w': card_w, 'h': card_h + gap + footer_h}


def _render_fallback(qr, pixels):
    """无 GDI 兜底: 纯白底 + 黑色模块 (无卡片/文字). 返回 (w, h, bgrx top-down)."""
    quiet = 4
    scale = max(1, pixels // (qr.size + quiet * 2))
    w = (qr.size + quiet * 2) * scale
    buf = bytearray(b'\xff' * (w * w * 4))
    for y in range(qr.size):
        for x in range(qr.size):
            if qr.modules[y][x]:
                for dy in range(scale):
                    row = (y + quiet) * scale + dy
                    off = (row * w + (x + quiet) * scale) * 4
                    for dx in range(scale):
                        buf[off + dx * 4:off + dx * 4 + 3] = b'\x12\x12\x12'
    return w, w, bytes(buf)


def _render_gdi(qr, pixels, caption, footer):
    """GDI 离屏渲染 (对齐 C# Draw()). 返回 (w, h, bgrx top-down); 失败抛异常."""
    import ctypes
    import ctypes.wintypes as wt
    gdi32 = ctypes.windll.gdi32
    user32 = ctypes.windll.user32
    gdi32.CreateCompatibleDC.restype = ctypes.c_void_p
    gdi32.CreateDIBSection.restype = ctypes.c_void_p
    gdi32.CreateDIBSection.argtypes = [ctypes.c_void_p, ctypes.c_void_p, wt.UINT,
                                       ctypes.c_void_p, ctypes.c_void_p, wt.DWORD]
    gdi32.SelectObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    gdi32.SelectObject.restype = ctypes.c_void_p
    gdi32.CreateSolidBrush.argtypes = [wt.DWORD]
    gdi32.CreateSolidBrush.restype = ctypes.c_void_p
    gdi32.CreatePen.argtypes = [ctypes.c_int, ctypes.c_int, wt.DWORD]
    gdi32.CreatePen.restype = ctypes.c_void_p
    gdi32.DeleteObject.argtypes = [ctypes.c_void_p]
    gdi32.DeleteDC.argtypes = [ctypes.c_void_p]
    gdi32.CreateFontW.restype = ctypes.c_void_p
    gdi32.SetBkMode.argtypes = [ctypes.c_void_p, ctypes.c_int]
    gdi32.SetTextColor.argtypes = [ctypes.c_void_p, wt.DWORD]
    user32.FillRect.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    user32.DrawTextW.argtypes = [ctypes.c_void_p, wt.LPCWSTR, ctypes.c_int,
                                 ctypes.c_void_p, wt.UINT]

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [('biSize', wt.DWORD), ('biWidth', wt.LONG), ('biHeight', wt.LONG),
                    ('biPlanes', wt.WORD), ('biBitCount', wt.WORD),
                    ('biCompression', wt.DWORD), ('biSizeImage', wt.DWORD),
                    ('biXPelsPerMeter', wt.LONG), ('biYPelsPerMeter', wt.LONG),
                    ('biClrUsed', wt.DWORD), ('biClrImportant', wt.DWORD)]

    class BITMAPINFO(ctypes.Structure):
        _fields_ = [('bmiHeader', BITMAPINFOHEADER), ('bmiColors', wt.DWORD * 3)]

    L = _layout(qr, pixels, caption, footer)
    W, H = L['w'], L['h']

    def colorref(r, g, b):
        return r | (g << 8) | (b << 16)

    def pt(v):                       # 96 DPI: point -> logical pixels
        return -int(round(v * 96.0 / 72.0))

    hdc = gdi32.CreateCompatibleDC(None)
    if not hdc:
        raise OSError('CreateCompatibleDC failed')
    hbmp = old = None
    objs = []
    try:
        bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        bmi.bmiHeader.biWidth = W
        bmi.bmiHeader.biHeight = -H                    # top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = 0                # BI_RGB
        ppv = ctypes.c_void_p()
        hbmp = gdi32.CreateDIBSection(hdc, ctypes.byref(bmi), 0,
                                      ctypes.byref(ppv), None, 0)
        if not hbmp or not ppv:
            raise OSError('CreateDIBSection failed')
        old = gdi32.SelectObject(hdc, hbmp)

        def brush(rgb):
            h = gdi32.CreateSolidBrush(rgb)
            objs.append(h)
            return h

        def fill_rect(x0, y0, x1, y1, rgb):
            rc = wt.RECT(x0, y0, x1, y1)
            user32.FillRect(hdc, ctypes.byref(rc), brush(rgb))

        fill_rect(0, 0, W, H, colorref(255, 255, 255))
        # 圆角细边框白卡 (C#: 填充白 + 1.5px Color(218,221,226))
        pen = gdi32.CreatePen(0, 1, colorref(218, 221, 226))
        objs.append(pen)
        white = brush(colorref(255, 255, 255))
        oldp = gdi32.SelectObject(hdc, pen)
        oldb = gdi32.SelectObject(hdc, white)
        gdi32.RoundRect(hdc, 0, 0, L['card_w'], L['card_h'],
                        L['radius'] * 2, L['radius'] * 2)
        gdi32.SelectObject(hdc, oldp)
        gdi32.SelectObject(hdc, oldb)

        def draw_text(text, size_pt, bold, rgb, x0, y0, x1, y1):
            f = gdi32.CreateFontW(pt(size_pt), 0, 0, 0, 700 if bold else 400,
                                  0, 0, 0, 1, 0, 0, 0, 0, 'Microsoft YaHei UI')
            objs.append(f)
            oldf = gdi32.SelectObject(hdc, f)
            gdi32.SetBkMode(hdc, 1)                    # TRANSPARENT
            gdi32.SetTextColor(hdc, rgb)
            rc = wt.RECT(x0, y0, x1, y1)
            user32.DrawTextW(hdc, text, -1, ctypes.byref(rc),
                             0x01 | 0x04 | 0x20 | 0x8000)   # CENTER|VCENTER|SINGLELINE|END_ELLIPSIS
            gdi32.SelectObject(hdc, oldf)

        if L['title_h']:
            txt = caption.strip()
            if len(txt) > 32:
                txt = txt[:31] + '…'
            fs = 15 if len(txt) > 22 else (17 if len(txt) > 14 else 19)
            draw_text(txt, fs, True, colorref(25, 25, 25),
                      L['border'], 4, L['card_w'] - L['border'], L['title_h'] - 6)
        # QR 模块 (C#: SmoothingMode.None, Color(18,18,18))
        ox, oy = L['border'], L['border'] + L['title_h']
        s, q = L['scale'], L['quiet']
        dark = brush(colorref(18, 18, 18))
        for y in range(qr.size):
            for x in range(qr.size):
                if qr.modules[y][x]:
                    rc = wt.RECT(ox + (x + q) * s, oy + (y + q) * s,
                                 ox + (x + q + 1) * s, oy + (y + q + 1) * s)
                    user32.FillRect(hdc, ctypes.byref(rc), dark)
        if L['footer_h']:
            txt = footer.strip()
            if len(txt) > 56:
                txt = txt[:55] + '…'
            fs = 12 if len(txt) > 38 else (13.5 if len(txt) > 26 else 15)
            draw_text(txt, fs, False, colorref(105, 105, 105),
                      14, L['card_h'] + L['gap'], W - 14, L['card_h'] + L['gap'] + L['footer_h'])
        return W, H, ctypes.string_at(ppv, W * H * 4)
    finally:
        if old and hbmp:
            gdi32.SelectObject(hdc, old)
        for h in objs:
            gdi32.DeleteObject(h)
        if hbmp:
            gdi32.DeleteObject(hbmp)
        gdi32.DeleteDC(hdc)


def render_image(qr, pixels=640, caption='', footer=''):
    """渲染完整卡片图. 返回 (w, h, bgrx top-down bytes)."""
    try:
        return _render_gdi(qr, pixels, caption, footer)
    except Exception:
        return _render_fallback(qr, pixels)


# ---------- 纯 Python PNG (zlib + struct 手工打包) ----------
def png_bytes(w, h, bgrx):
    """bgrx top-down 32bpp -> PNG (RGB8). """
    rows = []
    stride = w * 4
    for y in range(h):
        row = bgrx[y * stride:(y + 1) * stride]
        rgb = bytearray(w * 3)
        rgb[0::3] = row[2::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        rows.append(b'\x00' + bytes(rgb))              # filter type 0
    raw = b''.join(rows)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
            + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


# ---------- 复制图片到剪贴板 (CF_DIB, ctypes 原生) ----------
def copy_image_to_clipboard(w, h, bgrx):
    import ctypes
    import ctypes.wintypes as wt
    user32 = ctypes.windll.user32
    kernel32 = ctypes.windll.kernel32
    user32.OpenClipboard.argtypes = [ctypes.c_void_p]
    user32.OpenClipboard.restype = wt.BOOL
    user32.SetClipboardData.argtypes = [wt.UINT, ctypes.c_void_p]
    user32.SetClipboardData.restype = ctypes.c_void_p
    kernel32.GlobalAlloc.argtypes = [wt.UINT, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = ctypes.c_void_p
    kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
    kernel32.GlobalLock.restype = ctypes.c_void_p
    kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
    # CF_DIB: BITMAPINFOHEADER (bottom-up) + 像素
    hdr = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 32, 0, w * h * 4, 2835, 2835, 0, 0)
    stride = w * 4
    rows = b''.join(bgrx[y * stride:(y + 1) * stride] for y in range(h - 1, -1, -1))
    data = hdr + rows
    if not user32.OpenClipboard(None):
        raise OSError('无法打开剪贴板')
    try:
        user32.EmptyClipboard()
        hglob = kernel32.GlobalAlloc(0x0042, len(data))     # GMEM_MOVEABLE|GMEM_ZEROINIT
        if not hglob:
            raise OSError('GlobalAlloc failed')
        ptr = kernel32.GlobalLock(hglob)
        if not ptr:
            kernel32.GlobalFree(hglob)
            raise OSError('GlobalLock failed')
        ctypes.memmove(ptr, data, len(data))
        kernel32.GlobalUnlock(hglob)
        if not user32.SetClipboardData(8, hglob):           # CF_DIB
            kernel32.GlobalFree(hglob)
            raise OSError('SetClipboardData failed')
    finally:
        user32.CloseClipboard()


# ======================================================================
# GUI (宿主设计系统 ui: 无边框圆角窗 + 扁平按钮 + 圆角输入框)
# ======================================================================
def _rr_points(x0, y0, x1, y1, r):
    """圆角矩形折线点 (canvas smooth polygon 用), 顺时针."""
    pts = []
    for cx, cy, a0 in ((x0 + r, y0 + r, 180), (x1 - r, y0 + r, 270),
                       (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90)):
        for i in range(7):
            a = math.radians(a0 + i * 15)
            pts += [cx + r * math.cos(a), cy + r * math.sin(a)]
    return pts


def _draw_preview(canvas, qr, caption, footer):
    """在 320x360 Canvas 上绘制卡片预览 (clean border 风格, 对齐 C# Draw 布局)."""
    import ui
    canvas.delete('all')
    quiet = 4
    scale = max(1, 296 // (qr.size + quiet * 2))
    qsz = (qr.size + quiet * 2) * scale
    has_cap = bool(caption and caption.strip())
    has_foot = bool(footer and footer.strip())
    title_h = 26 if has_cap else 0
    foot_h = 22 if has_foot else 0
    border = 6
    card_w = qsz + border * 2
    card_h = qsz + border * 2 + title_h
    gap = 4 if has_foot else 0
    total_h = card_h + gap + foot_h
    x0 = (320 - card_w) // 2
    y0 = max(0, (360 - total_h) // 2)
    # 白卡 + 圆角细边框
    canvas.create_polygon(_rr_points(x0, y0, x0 + card_w, y0 + card_h, 8),
                          smooth=True, fill='#FFFFFF', outline='#DADDE2', width=1)
    if has_cap:
        canvas.create_text(160, y0 + border + title_h // 2, text=caption.strip(),
                           fill='#191919', font=ui.font(9, bold=True), width=card_w - 16)
    qx, qy = x0 + border, y0 + border + title_h
    for y in range(qr.size):
        for x in range(qr.size):
            if qr.modules[y][x]:
                canvas.create_rectangle(qx + (x + quiet) * scale, qy + (y + quiet) * scale,
                                        qx + (x + quiet + 1) * scale, qy + (y + quiet + 1) * scale,
                                        fill='#121212', outline='')
    if has_foot:
        canvas.create_text(160, y0 + card_h + gap + foot_h // 2, text=footer.strip(),
                           fill='#696969', font=ui.font(8), width=320 - 28)


def run():
    import tkinter as tk
    from tkinter import filedialog
    import ui

    win, content = ui.make_window('WgIme 二维码生成器', 560, 884)

    tk.Label(content, text='二维码生成器', bg=ui.BG, fg=ui.TEXT,
             font=ui.font(17, bold=True)).place(x=18, y=14, width=300, height=32)
    tk.Label(content, text='完全离线 · UTF-8 + ECI 26 · M 级纠错', bg=ui.BG, fg=ui.SUB,
             font=ui.font(9)).place(x=18, y=46, width=520, height=22)

    # 主输入 (C# 是多行 TextBox; rounded_entry 是单行 Entry, 这里用同款圆角风格包一个多行 Text)
    input_frame = tk.Frame(content, bg=ui.CARD, highlightthickness=1,
                           highlightbackground=ui.BORDER, highlightcolor=ui.ACCENT)
    input_frame.place(x=18, y=74, width=524, height=106)
    input_box = tk.Text(input_frame, font=ui.font(10.5), bg=ui.CARD, fg=ui.TEXT,
                        bd=0, highlightthickness=0, wrap='word')
    input_box.place(x=12, y=10, width=500, height=86)
    input_box.insert('1.0', 'https://')

    tk.Label(content, text='二维码上方缩略文字（可选）', bg=ui.BG, fg=ui.SUB,
             font=ui.font(8.5), anchor='w').place(x=18, y=186, width=524, height=20)
    caption_box = ui.rounded_entry(content, x=18, y=206, w=524, h=44)

    tk.Label(content, text='二维码下方说明文字（可选）', bg=ui.BG, fg=ui.SUB,
             font=ui.font(8.5), anchor='w').place(x=18, y=258, width=524, height=20)
    footer_box = ui.rounded_entry(content, x=18, y=278, w=524, h=44,
                                  initial='请使用浏览器扫描打开，微信内无法打开')

    card = tk.Frame(content, bg=ui.CARD, highlightthickness=1,
                    highlightbackground=ui.BORDER)
    card.place(x=105, y=336, width=350, height=390)
    canvas = tk.Canvas(card, bg=ui.CARD, bd=0, highlightthickness=0)
    canvas.place(x=15, y=15, width=320, height=360)
    empty = tk.Label(card, text='输入内容及上下方文字后点击“生成”', bg=ui.CARD, fg=ui.SUB,
                     font=ui.font(10))
    empty.place(x=15, y=15, width=320, height=360)

    status = tk.Label(content, text='准备就绪', bg=ui.BG, fg=ui.SUB,
                      font=ui.font(8.5), anchor='w')
    status.place(x=18, y=736, width=524, height=24)

    state = {'qr': None, 'img': None}          # img = (w, h, bgrx)

    def set_status(text, color):
        status.configure(text=text, fg=color)

    def get_input():
        return input_box.get('1.0', 'end-1c')

    def make():
        t = get_input()
        caption, footer = caption_box.get(), footer_box.get()
        if not t.strip():
            set_status('请输入需要编码的内容', ui.RED)
            return
        try:
            q = qr_encode(t)
            img = render_image(q, 640, caption, footer)
            state['qr'], state['img'] = q, img
            _draw_preview(canvas, q, caption, footer)
            empty.place_forget()
            set_status('本地生成成功 · Version %d · %d × %d' % (q.version, img[0], img[1]),
                       ui.GREEN)
        except Exception as ex:
            set_status('生成失败: %s' % ex, ui.RED)

    def do_copy():
        if state['img'] is None:
            set_status('请先生成二维码', ui.RED)
            return
        try:
            copy_image_to_clipboard(*state['img'])
            set_status('二维码图片已复制到剪贴板', ui.GREEN)
        except Exception as ex:
            set_status('复制失败: %s' % ex, ui.RED)

    def do_save():
        if state['img'] is None:
            set_status('请先生成二维码', ui.RED)
            return
        path = filedialog.asksaveasfilename(
            parent=win, title='保存二维码', defaultextension='.png',
            filetypes=[('PNG 图片', '*.png')],
            initialfile='qrcode-' + time.strftime('%Y%m%d-%H%M%S') + '.png')
        if not path:
            return
        try:
            with open(path, 'wb') as f:
                f.write(png_bytes(*state['img']))
            set_status('已保存: %s' % path, ui.GREEN)
        except Exception as ex:
            set_status('保存失败: %s' % ex, ui.RED)

    def do_clear():
        input_box.delete('1.0', 'end')
        caption_box.delete(0, 'end')
        footer_box.delete(0, 'end')
        input_box.focus_set()
        set_status('已清空', ui.SUB)

    ui.flat_button(content, '生成', make, primary=True, x=18, y=778, w=116, h=36)
    ui.flat_button(content, '复制图片', do_copy, x=148, y=778, w=116, h=36)
    ui.flat_button(content, '保存 PNG', do_save, x=278, y=778, w=116, h=36)
    ui.flat_button(content, '清空', do_clear, x=408, y=778, w=116, h=36)

    input_box.bind('<Control-Return>', lambda e: (make(), 'break')[1])
    caption_box.bind('<Return>', lambda e: (make(), 'break')[1])
    footer_box.bind('<Return>', lambda e: (make(), 'break')[1])
    win.after(0, input_box.focus_set)
    return win
