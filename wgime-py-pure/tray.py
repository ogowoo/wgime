# -*- coding: utf-8 -*-
"""tray.py — pystray 托盘: 启用/禁用, 模式, 繁简, 退出. 回调 marshal 回 tkinter 主线程."""
import logging as _logging
import traceback as _traceback

# 第四十一轮: 把 pystray 自己的日志抓下来. pystray 的 _show() **不检查** Shell_NotifyIcon 的返回值,
# 出错只走 logging; 而双击 .py 启动时解释器是 pythonw.exe, `sys.stderr is None` -> 这个报错**连显示
# 的地方都没有**(控制台跑能看到). 现在接一个 handler 存进 LOGS, 失败时随弹框一起报给用户/写进 debug.log.
LOGS = []


class _CaptureLog(_logging.Handler):
    def emit(self, record):
        try:
            msg = record.getMessage()
            if record.exc_info:
                msg += ' | ' + ''.join(_traceback.format_exception(*record.exc_info))
            LOGS.append('%s: %s' % (record.levelname, msg))
            del LOGS[:-40]
            try:
                import win as _w
                _w._dlog('pystray %s: %s' % (record.levelname, msg[:400]))
            except Exception:
                pass
        except Exception:
            pass


try:
    import pystray                      # pystray 的 win32 后端本身**不** import PIL (只在设图标时才用)
    HAS_TRAY = True
    IMPORT_ERR = ''
    _plog = _logging.getLogger('pystray')
    _plog.addHandler(_CaptureLog())
    _plog.setLevel(_logging.DEBUG)
except Exception:
    pystray = None
    HAS_TRAY = False
    IMPORT_ERR = _traceback.format_exc()

# Pillow: 画托盘图标要用; 但**宿主机器不一定装了**(用户机器实测: 官方 Python 3.14, 没装 Pillow ->
# `from PIL import ...` 直接 ImportError -> 整个托盘没了, 这就是"个别机器看不到托盘图标")。
# 所以它是可选依赖: 单文件版由构建脚本预渲染好图标内嵌 (见 _embedded_icons), 运行时不需要 PIL。
try:
    from PIL import Image, ImageDraw, ImageFont
    HAS_PIL = True
    PIL_ERR = ''
except Exception:
    Image = ImageDraw = ImageFont = None
    HAS_PIL = False
    PIL_ERR = _traceback.format_exc()


def _embedded_icons():
    """单文件版里由 build-wgime-pure.py 预渲染的托盘图标 (base64 ICO 字典); 源码布局下为 None。"""
    try:
        import sys as _s
        return getattr(_s.modules.get('__main__'), 'TRAY_ICONS', None)
    except Exception:
        return None

# 第四十一轮: 记下 pystray 真正发给 shell 的 NIM_ADD 返回值 —— **这是"图标登记上了没有"的唯一可靠信号**:
# NIM_ADD 返回 True 就说明 shell 收下了 (NIM_ADD=False 才是真失败)。反过来 Shell_NotifyIconGetRect 并不可靠
# (实测: NIM_ADD=True, GetRect 仍回 E_FAIL —— 它只能反映"在不在可见区", 不能判断有没有登记)。
NIM = {'add_ok': None, 'add_count': 0, 'modify_ok': None}
try:
    import pystray._win32 as _pw
    _orig_notify = _pw.win32.Shell_NotifyIcon
    _NIM_ADD, _NIM_MODIFY, _NIF_ICON = 0, 1, 0x2

    def _spy_notify(code, nid):
        r = _orig_notify(code, nid)
        code = int(code)
        if code == _NIM_ADD:
            NIM['add_ok'] = bool(r)
            NIM['add_count'] += 1
        elif code == _NIM_MODIFY and (int(getattr(nid, 'uFlags', 0)) & _NIF_ICON):
            NIM['modify_ok'] = bool(r)          # 换图标 (切模式/开关) 有没有被 shell 接受
        return r

    _pw.win32.Shell_NotifyIcon = _spy_notify
except Exception:
    pass

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
        self.last_error = ''      # start() 失败原因 (第四十一轮) —— 由 main 弹框/写日志

    def _hicon(self, mode, active=True):
        """用内嵌 ICO 造 HICON (不需要 Pillow). 没有内嵌图标时返回 None (回退到 PIL 路径)。"""
        icons = _embedded_icons()
        if not icons:
            return None
        key = 'tool' if self._runmode() == 'tray' else '%d%s' % (int(mode) % 4, 'a' if active else 'i')
        b64 = icons.get(key) or icons.get('0a')
        if not b64:
            return None
        try:
            import base64 as _b64
            import win as _w
            return _w.icon_from_ico_bytes(_b64.b64decode(b64), key)
        except Exception:
            return None

    def _inject_hicon(self, h):
        """把 HICON 直接塞给 pystray, 绕过它的 PIL 序列化 (`_assert_icon_handle` 见到句柄就直接用)。"""
        try:
            self.icon._icon = h or 'embedded'      # 真值: pystray 的 visible setter 要求"有图标数据"
        except Exception:
            pass
        self.icon._icon_handle = h
        try:
            self.icon._icon_valid = True
        except Exception:
            pass

    def _refresh(self):
        try:
            if self.icon is None:
                return
            mode, active = self.api['get_mode'](), self.api['is_active']()
            if _embedded_icons():
                h = self._hicon(mode, active)
                was = False
                try:
                    was = bool(getattr(self.icon, 'visible', False))
                except Exception:
                    was = False
                try:
                    import win as _w
                    _w._dlog('tray _refresh embedded mode=%s active=%s hicon=%s visible=%s'
                             % (mode, active, bool(h), was))
                except Exception:
                    pass
                if h:
                    if was:
                        try:
                            self.icon._release_icon()
                        except Exception:
                            pass
                    self._inject_hicon(h)
                    if was:                         # 已经显示着 -> 通知 shell 换图 (NIM_MODIFY | NIF_ICON)
                        try:
                            self.icon._message(1, 0x2, hIcon=h)
                        except Exception:
                            pass
                        try:
                            import win as _w
                            _w._dlog('tray icon swap -> %s modified=%s'
                                     % ('%d%s' % (int(mode) % 4, 'a' if active else 'i'), NIM.get('modify_ok')))
                        except Exception:
                            pass
            elif HAS_PIL:
                self.icon.icon = (_tool_icon_img() if self._runmode() == 'tray'
                                  else _icon_img(mode, active))
            self.icon.update_menu()   # 刷新菜单勾选态(checked 重求值), 否则切换后勾选不变、看起来"没反应"
        except Exception:
            pass

    def _runmode(self):
        try:
            return self.api.get('get_runmode', lambda: 'ime')()
        except Exception:
            return 'ime'

    def notify(self, title, text):
        """托盘气泡 (对齐 C# ShowBalloonTip)。返回是否已发出."""
        try:
            if self.icon is None:
                return False
            self.icon.notify(str(text), str(title))
            return True
        except Exception:
            return False

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
            # 开关 (勾选态 = 输入法当前是否开启, 对齐 C# miOnOff.Checked = Hook.IsLocked)
            pystray.MenuItem(L('开关  (Shift 轻点)', 'On/Off  (Shift tap)'), self._on(self.api['toggle']),
                             checked=lambda _it: self.api['is_active']()),
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
                                                  self._on(self.api['trad']),
                                                  checked=lambda _it: self.api['get_trad']()),
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
                                 pystray.MenuItem(L('批量造词… (文件, 每行一个词)', 'Batch Make Words… (file, one word per line)'),
                                                  self._on(self.api['batchmakeword'])),
                                 pystray.MenuItem(L('用户词表…', 'User Words…'),
                                                  self._on(self.api['userwords'])),
                                 pystray.Menu.SEPARATOR,
                                 pystray.MenuItem(L('导入码表…', 'Import Table…'),
                                                  self._on(self.api['import_table'])))),
            pystray.Menu.SEPARATOR,
            # 这个程序
            pystray.MenuItem(L('这个程序', 'This app'),
                             pystray.Menu(
                                 pystray.MenuItem(L('改用剪贴板上屏', 'Paste via clipboard'),
                                                  self._on(self.api['apppaste']),
                                                  checked=lambda _it: self.api['get_apppaste']()),
                                 pystray.MenuItem(L('标点吞字修复', 'Punct stale-char fix'),
                                                  self._on(self.api['appkeyfix']),
                                                  checked=lambda _it: self.api['get_appkeyfix']()),
                                 pystray.MenuItem(L('编辑配置 (config.txt)…', 'Edit config (config.txt)…'),
                                                  self._on(self.api['open_config'])),
                                 pystray.MenuItem(L('重载配置 (config/tools/插件)', 'Reload config (config/tools/plugins)'),
                                                  self._on(self.api['reload'])),
                                 pystray.MenuItem(L('数据目录…', 'Data folder…'),
                                                  self._on(self.api['open_datadir'])))),
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
                                                  self._on(self.api['reload'])),
                                 pystray.MenuItem(L('数据目录…', 'Data folder…'),
                                                  self._on(self.api['open_datadir'])))),
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
        """建图标 + 起 pystray 线程. 返回 True/False (False 时 self.last_error 有原因).
        第四十一/四十二轮: 每个可能失败的步骤都留痕; 图标优先用内嵌 ICO (**不需要宿主装 Pillow**),
        没有内嵌图标(源码布局)时才回退到 PIL。"""
        self.last_error = ''
        if not HAS_TRAY:
            self.last_error = 'pystray 导入失败:\n' + (IMPORT_ERR or '(未知)')
            return False
        try:
            if self._runmode() == 'tray':
                items = self._tray_items()
                pil_icon = (_tool_icon_img() if HAS_PIL else None)
                mode_for_icon = 0
            else:
                items = self._ime_items()
                mode_for_icon = self.api['get_mode']()
                pil_icon = (_icon_img(mode_for_icon, True) if HAS_PIL else None)
            if pil_icon is None and not _embedded_icons():
                self.last_error = ('缺 Pillow (PIL) 且单文件里没有预渲染图标, 无法创建托盘图标。\n'
                                   'Pillow 报错:\n' + (PIL_ERR or '(未知)'))
                return False
            menu = pystray.Menu(*items)
            self.icon = pystray.Icon('WgIme-Pure', None, 'WgIme-Pure', menu)
            if _embedded_icons():
                # 内嵌图标可用 -> 完全不走 PIL; 先塞好句柄, run_detached 里的 NIM_ADD 就会带上它
                h = self._hicon(mode_for_icon, True)
                if h:
                    self._inject_hicon(h)
                else:
                    self.last_error = '内嵌托盘图标加载失败 (LoadImage 返回空)'
                    return False
            else:
                self.icon.icon = pil_icon
            self.icon.run_detached()
            self._refresh()
            return True
        except Exception:
            self.last_error = _traceback.format_exc()
            return False

    def selfcheck(self):
        """问 shell: 图标登记上没有、可见还是在隐藏溢出区.
        返回 (state, rect); state 见 win.notify_icon_rect ('visible'/'overflow'/'missing'/'unknown').
        **uID 必须是 pystray 用的那个**: pystray `_win32._message()` 里 `hID=id(self.icon)`,
        不是常量 1 —— 传错 id 时 shell 会回 E_FAIL, 看起来像"图标没登记"(假阴性)。"""
        try:
            import win as _w
        except Exception:
            return 'unknown', None
        if self.icon is None:
            return 'missing', None
        hwnd = getattr(self.icon, '_hwnd', 0)
        if not hwnd:
            return 'missing', None
        state, rect = _w.notify_icon_rect(hwnd, id(self.icon))
        if state == 'missing':                     # 兜底: 万一哪天 pystray 改成固定 id
            state2, rect2 = _w.notify_icon_rect(hwnd, 1)
            if state2 != 'missing':
                return state2, rect2
        return state, rect
