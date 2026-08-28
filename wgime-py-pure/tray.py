# -*- coding: utf-8 -*-
"""tray.py — pystray 托盘: 启用/禁用, 模式, 繁简, 退出. 回调 marshal 回 tkinter 主线程."""
try:
    import pystray
    from PIL import Image, ImageDraw, ImageFont
    HAS_TRAY = True
except Exception:
    pystray = None
    HAS_TRAY = False

import queue
import ctypes as _ct


def _is_zh():
    try:
        return (_ct.windll.kernel32.GetUserDefaultUILanguage() & 0x3FF) == 0x04   # 主语言 0x04 = 中文
    except Exception:
        return True


_ZH = _is_zh()


def L(zh, en):
    """C# 同款: 按系统 UI 语言返回中文或英文."""
    return zh if _ZH else en


MODE_NAMES = ('混合', '拼音', '五笔', '词典')
MODE_EN = ('Mixed', 'Pinyin', 'Wubi', 'Dict')
# 与 C# 版一致: 模式汉字镂空 + Win11 强调色 (中/拼/五/译), 未激活灰
MODE_CHARS = ('中', '拼', '五', '译')
MODE_COLORS = ((0, 120, 212), (0, 183, 195), (202, 80, 16), (136, 23, 152))
OFF_COLOR = (190, 185, 179)

# 托盘回调 (pystray 线程) 不能直接碰 tkinter —— 入队, 主线程 poll 里执行
TRAY_Q = queue.Queue()


def _icon_img(mode, active):
    """C# 同款: 圆角方形 + 模式汉字镂空 + 模式色."""
    color = MODE_COLORS[mode % 4] if active else OFF_COLOR
    img = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, 63, 63], 14, fill=color + (255,))
    ch = MODE_CHARS[mode % 4]
    try:
        font = ImageFont.truetype('msyh.ttc', 52)
    except Exception:
        try:
            font = ImageFont.truetype('Microsoft YaHei UI', 52)
        except Exception:
            font = ImageFont.load_default()
    mask = Image.new('L', (64, 64), 0)
    md = ImageDraw.Draw(mask)
    md.text((32, 32), ch, font=font, fill=255, anchor='mm')
    px = img.load()
    pm = mask.load()
    for y in range(64):
        for x in range(64):
            if pm[x, y] > 128:
                px[x, y] = (0, 0, 0, 0)
    return img


class Tray:
    def __init__(self, root, api):
        self.root = root
        self.api = api
        self.icon = None

    def _refresh(self):
        try:
            self.icon.icon = _icon_img(self.api['get_mode'](), self.api['is_active']())
        except Exception:
            pass

    def _on(self, fn):
        def wrap(_icon, _item):
            # 入队给主线程执行 (tkinter 不能跨线程调用), 随后刷新图标
            TRAY_Q.put(lambda: (fn(), self._refresh()))
        return wrap

    def start(self):
        if not HAS_TRAY:
            return False
        menu = pystray.Menu(
            # 开关
            pystray.MenuItem(L('开关  (Shift 轻点)', 'On/Off  (Shift tap)'), self._on(self.api['toggle'])),
            pystray.Menu.SEPARATOR,
            # 模式
            pystray.MenuItem(L('模式  (Ctrl+` 循环)', 'Mode  (Ctrl+` cycles)'),
                             pystray.Menu(
                                 *(pystray.MenuItem(L(MODE_NAMES[m], MODE_EN[m]),
                                                    self._on(lambda m=m: self.api['set_mode'](m)),
                                                    checked=lambda _it, m=m: self.api['get_mode']() == m)
                                   for m in range(4)))),
            # 选项
            pystray.MenuItem(L('选项', 'Options'),
                             pystray.Menu(
                                 pystray.MenuItem(L('繁体输出  (Ctrl+Shift+F)', 'Trad output  (Ctrl+Shift+F)'),
                                                  self._on(self.api['trad'])),
                                 pystray.MenuItem(L('反查编码', 'Reverse code'),
                                                  self._on(self.api['toggleshowcode']),
                                                  checked=lambda _it: self.api['get_showcode']()),
                                 pystray.MenuItem(L('整句输入', 'Sentence mode'),
                                                  self._on(self.api['togglesentence']),
                                                  checked=lambda _it: self.api['get_sentence']()),
                                 pystray.MenuItem(L('联想', 'Association'),
                                                  self._on(self.api['toggleassoc']),
                                                  checked=lambda _it: self.api['get_assoc']()),
                                 pystray.MenuItem(L('空闲隐藏', 'Hide when idle'),
                                                  self._on(self.api['togglehideidle']),
                                                  checked=lambda _it: self.api['get_hideidle']()),
                                 pystray.MenuItem(L('候选窗跟随光标', 'Candidate board follows caret'),
                                                  self._on(self.api['followcaret']),
                                                  checked=lambda _it: self.api['get_followcaret']()),
                                 pystray.MenuItem(L('主题', 'Theme'),
                                                  pystray.Menu(
                                                      pystray.MenuItem(L('深色', 'Dark'),
                                                                       self._on(lambda: self.api['set_theme']('dark')),
                                                                       checked=lambda _it: self.api['get_theme']() == 'dark'),
                                                      pystray.MenuItem(L('浅色', 'Light'),
                                                                       self._on(lambda: self.api['set_theme']('light')),
                                                                       checked=lambda _it: self.api['get_theme']() == 'light'))))),
            # 词库
            pystray.MenuItem(L('词库', 'Dictionary'),
                             pystray.Menu(
                                 pystray.MenuItem(L('造词  (Ctrl+Alt+C)', 'Make Word  (Ctrl+Alt+C)'),
                                                  self._on(self.api['makeword'])),
                                 pystray.MenuItem(L('导入码表…', 'Import Table…'),
                                                  self._on(self.api['import_table'])))),
            pystray.Menu.SEPARATOR,
            # 这个程序
            pystray.MenuItem(L('这个程序', 'This app'),
                             pystray.Menu(
                                 pystray.MenuItem(L('改用剪贴板上屏', 'Paste via clipboard'),
                                                  self._on(self.api['apppaste'])),
                                 pystray.MenuItem(L('标点吞字修复', 'Punct stale-char fix'),
                                                  self._on(self.api['appkeyfix'])))),
            pystray.Menu.SEPARATOR,
            # 退出
            pystray.MenuItem(L('退出', 'Exit'), self._on(self.api['quit'])),
        )
        self.icon = pystray.Icon('WgIme-Pure', _icon_img(self.api['get_mode'](), True), 'WgIme-Pure', menu)
        self.icon.run_detached()
        self._refresh()
        return True
