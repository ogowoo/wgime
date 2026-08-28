# -*- coding: utf-8 -*-
"""tray.py — pystray 托盘: 启用/禁用, 模式, 繁简, 退出. 回调 marshal 回 tkinter 主线程."""
try:
    import pystray
    from PIL import Image, ImageDraw
    HAS_TRAY = True
except Exception:
    pystray = None
    HAS_TRAY = False

import queue

MODE_NAMES = ('混合', '拼音', '五笔', '词典')

# 托盘回调 (pystray 线程) 不能直接碰 tkinter —— 入队, 主线程 poll 里执行
TRAY_Q = queue.Queue()


def _icon_img(active):
    img = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([6, 6, 58, 58], 12, fill=(0, 122, 255, 255) if active else (120, 128, 140, 255))
    d.ellipse([24, 20, 40, 36], fill=(255, 255, 255, 255))
    return img


class Tray:
    def __init__(self, root, api):
        self.root = root
        self.api = api
        self.icon = None

    def _refresh(self):
        try:
            self.icon.icon = _icon_img(self.api['is_active']())
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
            pystray.MenuItem('启用/禁用 (Shift 轻拍)', self._on(self.api['toggle'])),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem('模式',
                             pystray.Menu(
                                 *(pystray.MenuItem(MODE_NAMES[m], self._on(lambda m=m: self.api['set_mode'](m)),
                                                    checked=lambda _it, m=m: self.api['get_mode']() == m)
                                   for m in range(4)))),
            pystray.MenuItem('繁体输出 (Ctrl+Shift+F)', self._on(self.api['trad'])),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem('当前程序: 剪贴板上屏切换', self._on(self.api['apppaste'])),
            pystray.MenuItem('当前程序: 标点吞字修复切换', self._on(self.api['appkeyfix'])),
            pystray.Menu.SEPARATOR,
            pystray.MenuItem('退出', self._on(self.api['quit'])),
        )
        self.icon = pystray.Icon('WgIme-Pure', _icon_img(True), 'WgIme-Pure', menu)
        self.icon.run_detached()
        self._refresh()
        return True
