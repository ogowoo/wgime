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


def _tool_icon_img():
    """tray(托盘工具箱) 模式图标: 圆角方块 + 镂空"工"字 (对齐 wgtray)."""
    color = (0, 120, 212)
    img = Image.new('RGBA', (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, 63, 63], 14, fill=color + (255,))
    ch = '工'
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
            if self._runmode() == 'tray':
                self.icon.icon = _tool_icon_img()
            else:
                self.icon.icon = _icon_img(self.api['get_mode'](), self.api['is_active']())
            self.icon.update_menu()   # 刷新菜单勾选态(checked 重求值), 否则切换后勾选不变、看起来"没反应"
        except Exception:
            pass

    def _runmode(self):
        try:
            return self.api.get('get_runmode', lambda: 'ime')()
        except Exception:
            return 'ime'

    def _on(self, fn):
        def wrap(_icon, _item):
            # 入队给主线程执行 (tkinter 不能跨线程调用), 随后刷新图标
            TRAY_Q.put(lambda: (fn(), self._refresh()))
        return wrap

    # ---------- 运行模式子菜单 (ime/tray 切换 -> 写 config + 重启) ----------
    def _runmode_item(self):
        return pystray.MenuItem(L('运行模式', 'Run mode'),
                                pystray.Menu(
                                    pystray.MenuItem(L('输入法 (IME)', 'IME mode'),
                                                     self._on(lambda: self.api['switch_runmode']('ime')),
                                                     checked=lambda _it: self._runmode() == 'ime'),
                                    pystray.MenuItem(L('托盘工具箱 (Tray)', 'Tray toolbox'),
                                                     self._on(lambda: self.api['switch_runmode']('tray')),
                                                     checked=lambda _it: self._runmode() == 'tray')))

    def _plugins_menu(self):
        """托盘「插件」子菜单: 列出 plugins 目录插件, 点击即运行; 尾部加插件管理入口."""
        try:
            plugins = self.api['list_plugins']()
        except Exception:
            plugins = []
        items = []
        for p in plugins:
            if not p.get('enabled', True):
                continue
            label = '%s  (%s)' % (p.get('name'), p.get('code'))
            items.append(pystray.MenuItem(label, self._on(lambda f=p['file']: self.api['run_plugin_file'](f))))
        if not items:
            items.append(pystray.MenuItem(L('(无插件 — 放 plugins\\*.py/txt)', '(no plugins — put plugins\\*.py/txt)'), None, enabled=False))
        items.append(pystray.Menu.SEPARATOR)
        items.append(pystray.MenuItem(L('插件管理…', 'Plugin manager…'), self._on(self.api['pluginmgr'])))
        return pystray.MenuItem(L('插件', 'Plugins'), pystray.Menu(*items))

    def _tools_menu(self):
        return pystray.MenuItem(L('内置工具', 'Built-in tools'),
                                pystray.Menu(
                                    pystray.MenuItem(L('网络工具', 'Network tools'),
                                                     self._on(self.api['nettools'])),
                                    pystray.MenuItem(L('剪贴板历史', 'Clipboard history'),
                                                     self._on(self.api['clipboard'])),
                                    pystray.MenuItem(L('便签', 'Sticky notes'),
                                                     self._on(self.api['notes'])),
                                    pystray.MenuItem(L('颜色拾取', 'Color picker'),
                                                     self._on(self.api['color']))))

    def _apps_menu(self):
        try:
            apps = self.api['apps']()
        except Exception:
            apps = []
        if not apps:
            return pystray.MenuItem(L('应用 (config.txt)', 'Apps (config.txt)'),
                                    pystray.MenuItem(L('(无)', '(none)'), None, enabled=False))
        items = tuple(pystray.MenuItem(name, self._on(lambda c=code: self.api['run_app'](c)))
                      for code, (name, _cmd, _args) in apps)
        return pystray.MenuItem(L('应用 (config.txt)', 'Apps (config.txt)'), pystray.Menu(*items))

    # ---------- 菜单组 ----------
    def _ime_items(self):
        return (
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
                                 pystray.MenuItem(L('全角标点  (Ctrl+.)', 'CN punctuation  (Ctrl+.)'),
                                                  self._on(self.api['togglecnpunct']),
                                                  checked=lambda _it: self.api['get_cnpunct']()),
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
                                                  self._on(self.api['appkeyfix'])),
                                 pystray.MenuItem(L('编辑配置 (config.txt)…', 'Edit config (config.txt)…'),
                                                  self._on(self.api['open_config'])),
                                 pystray.MenuItem(L('重载配置 (config/tools/插件)', 'Reload config (config/tools/plugins)'),
                                                  self._on(self.api['reload'])))),
            pystray.Menu.SEPARATOR,
            self._runmode_item(),
            pystray.Menu.SEPARATOR,
            # 退出
            pystray.MenuItem(L('退出', 'Exit'), self._on(self.api['quit'])),
        )

    def _tray_items(self):
        """tray 模式菜单: 对齐 wgtray (工具箱/内置工具/插件/应用/配置/运行模式/退出)."""
        return (
            # 工具箱
            pystray.MenuItem(L('工具箱…', 'Toolbox…'), self._on(self.api['toolbox'])),
            self._tools_menu(),
            self._plugins_menu(),
            self._apps_menu(),
            pystray.Menu.SEPARATOR,
            # 配置
            pystray.MenuItem(L('配置', 'Config'),
                             pystray.Menu(
                                 pystray.MenuItem(L('编辑配置 (config.txt)…', 'Edit config (config.txt)…'),
                                                  self._on(self.api['open_config'])),
                                 pystray.MenuItem(L('重载配置 (config/tools/插件)', 'Reload config (config/tools/plugins)'),
                                                  self._on(self.api['reload'])))),
            pystray.Menu.SEPARATOR,
            self._runmode_item(),
            pystray.Menu.SEPARATOR,
            # 退出
            pystray.MenuItem(L('退出', 'Exit'), self._on(self.api['quit'])),
        )

    def rebuild(self):
        """重建菜单 (插件/应用列表随配置变化, reload 后调用). pystray 菜单结构需整体替换."""
        if not HAS_TRAY or self.icon is None:
            return
        try:
            if self._runmode() == 'tray':
                items = self._tray_items()
            else:
                items = self._ime_items()
            self.icon.menu = pystray.Menu(*items)
            self.icon.update_menu()
        except Exception:
            pass

    def start(self):
        if not HAS_TRAY:
            return False
        if self._runmode() == 'tray':
            items = self._tray_items()
            icon = _tool_icon_img()
        else:
            items = self._ime_items()
            icon = _icon_img(self.api['get_mode'](), True)
        menu = pystray.Menu(*items)
        self.icon = pystray.Icon('WgIme-Pure', icon, 'WgIme-Pure', menu)
        self.icon.run_detached()
        self._refresh()
        return True
