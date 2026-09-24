# -*- coding: utf-8 -*-
r"""截图标注 —— wgime 双模插件（由 `build-wrap-qt-plugin.py` 从原始单文件**整体包进** `_app_main()` 而来）。

本文件 = 原程序 + 薄包装。**为什么不能直接当普通插件**（三个硬约束）:
  ① PySide6 是巨型 C 扩展, 内嵌不进 wgime 的单文件发行版（规范 §12）;
  ② 原程序在**模块级**就 `import PySide6.*`, 还有模块级依赖自举（缺包自己 pip 装、装不上 `SystemExit`）
     —— 被装载器在**输入法启动时** exec 的话: 拖慢启动、可能当场联网装包、缺依赖时插件静默消失;
  ③ Qt 与宿主的 Tk **不能共用主线程事件循环** ⇒ 界面必须在**独立进程**里跑。
所以模块级只留「清单 / 查询 / 拉起自己」三件事, `_app_main()` 只在被调用时才构建 Qt 界面。

**双模**: `STANDALONE = True`。`python 本文件.py` = 原程序本身(它的
`if __name__ == '__main__':` 块被整体缩进进了 `_app_main()`, 独立运行时 `__name__` 照样是
`'__main__'`, 所以入口**仍然只有一个**); 尾块只负责测试钩子与 `STANDALONE-OK` 标记。
`--check-deps` 只报依赖不出界面。

**重新生成**（原程序改了之后）:
    python wgime-py-pure\build-wrap-qt-plugin.py <原始单文件.py> wgime-py-pure\plugins\PyShot.py pyshot 截图标注
⚠ 别把本文件再复制成只差大小写的另一个名字(Windows 大小写不敏感, 会互相覆盖, 见 AGENTS §5 规则 53)。
"""
# ---- 双模式 (1/3): 独立运行时先把宿主目录(上级)插进 sys.path —— 必须在第一个宿主 import 之前 ----
if __name__ == '__main__':
    import os as _os, sys as _sys
    _sys.path.insert(0, _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))))

import os
import subprocess
import sys

CODE = 'pyshot'
NAME = '截图标注'
DESC = '截图标注 2.16.1 —— 截图/滚动截图/标注编辑/贴图(独立进程, 需 PySide6)'
VERSION = '1.0'
AUTHOR = 'ogowoo'
PERM = 'low'                       # 只把「跟插件一起分发的自家程序」拉起来; 程序自身权限另算(规范 §16)
STANDALONE = True                  # 双模式 (2/3) 标记: 插件管理器据此显示"双模"

SELF = os.path.abspath(__file__)
CREATE_NO_WINDOW = 0x08000000
PAYLOAD_VERSION = '2.16.1'          # 打包时从原程序里抠的版本(便于 `app_version()` 兜底)


def app_version():
    """原程序版本: 先扫文件里的 `APP_VERSION = `, 扫不到用打包时抠的那个。**不 import 原程序**。"""
    try:
        with open(SELF, encoding='utf-8', errors='replace') as f:
            for _ in range(2000):
                ln = f.readline()
                if not ln:
                    break
                s = ln.strip()
                if s.startswith('APP_VERSION'):
                    return s.split('=', 1)[1].strip().strip('"\'')
    except OSError:
        pass
    return PAYLOAD_VERSION


def private_site_dirs():
    """wgime 的私有依赖目录(依赖自检把包装在这儿) —— 子进程要能看见它们。"""
    la = os.environ.get('LOCALAPPDATA') or ''
    bases = ([os.path.join(la, 'wgime-py')] if la else []) + [os.path.join(os.path.expanduser('~'), 'wgime-py')]
    out = []
    for b in bases:
        for sub in ('site', os.path.join('site', 'pip')):
            d = os.path.join(b, sub)
            if os.path.isdir(d) and d not in out:
                out.append(d)
    return out


def pyside_available():
    """给**子进程**看的判据: 本解释器里没有、但 wgime 私有目录里有, 也算有。"""
    import importlib.util
    try:
        if importlib.util.find_spec('PySide6') is not None:
            return True
    except Exception:
        pass
    for d in private_site_dirs():
        if os.path.isdir(os.path.join(d, 'PySide6')):
            return True
    return False


def child_env(skip_deps=False):
    env = dict(os.environ)
    extra = private_site_dirs()
    if extra:
        old = env.get('PYTHONPATH') or ''
        env['PYTHONPATH'] = os.pathsep.join(extra + ([old] if old else []))
    if skip_deps:                   # 自动化: 别让原程序自己联网装包/弹模态框
        env['PYSHOT_SKIP_DEPS'] = '1'
        env['PYSHOT_NO_ALERT'] = '1'
    return env


def spawn_argv(extra_args=None):
    """子进程命令行 = **本文件自己**(优先 pythonw, 不弹黑框)。"""
    exe = sys.executable or 'python'
    cand = os.path.join(os.path.dirname(exe), 'pythonw.exe')
    if os.path.exists(cand):
        exe = cand
    return [exe, '-X', 'utf8', SELF] + list(extra_args or [])


def spawn(extra_args=None, popen=None, skip_deps=False):
    """把本文件作为独立进程拉起(不等待)。返回 pid; 失败抛 RuntimeError。"""
    if not os.path.isfile(SELF):
        raise RuntimeError('自己不见了: %s' % SELF)
    runner = popen or subprocess.Popen
    flags = CREATE_NO_WINDOW if sys.platform == 'win32' else 0
    p = runner(spawn_argv(extra_args), env=child_env(skip_deps=skip_deps), cwd=os.path.dirname(SELF),
               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
               close_fds=True, creationflags=flags)
    return getattr(p, 'pid', 0)


def missing_hint():
    """缺 PySide6 时给人话(**不自动装** —— 200MB 的东西不该悄悄装)。"""
    return ('%s 需要 PySide6(约 200MB)。\n'
            '装法: 打启动编码 `deps` 打开依赖自检 → 勾选 PySide6 → 安装所选;'
            '或命令行 `pip install PySide6`。' % NAME)


def _tip(text):
    """走宿主的托盘气泡; 不在宿主里(独立跑/无 tools)就退回 stdout。"""
    try:
        import tools as _tools
        _tools._tip(NAME + ' (' + CODE + ')', text)
        return
    except Exception:
        pass
    try:
        print('[%s] %s' % (CODE, text), flush=True)
    except Exception:
        pass


def run():
    """宿主入口(Tk 主线程里同步调, **必须立刻返回**): 把本文件作为独立进程拉起。

    被装载器 load 进来时 `__name__` 是 `wgime_ext_...`, 独立运行时是 `'__main__'` —— 两条路都只是
    「拉起自己」, 所以不需要区分(也不能复用 `_standalone.py` 那套 Tk 看守: 本程序不是 Tk 程序)。
    """
    if not pyside_available():
        _tip(missing_hint())
        return False
    try:
        spawn()
    except Exception as ex:
        _tip('启动失败: %r' % (ex,))
        return False
    v = app_version()
    _tip('已启动(托盘常驻) %s\n截图/滚动截图走它的托盘菜单或默认热键。' % (('PyShot ' + v) if v else NAME))
    return True


def _app_main():
    """原程序体(由 build-wrap-qt-plugin.py 整体缩进进来)。**只在被调用时才有副作用**。"""
    global _cache, _current, _settings_cache
    # -*- coding: utf-8 -*-
    """PyShot 2.16.1 单文件版 —— 仿 FSCapture 的截图 + 标注编辑工具（自动安装依赖）

    本版主题：工具条可滚动可收起

    这是一个自动生成的单文件版本：把多文件源码合并在一起，并在启动时自动安装
    缺失的第三方库（PySide6），因此可以直接发给别人运行::

        python PyShot.py              # 启动后驻留托盘，按 PrintScreen 开始截图
        python PyShot.py 图片.png     # 直接编辑已有图片
        python PyShot.py --check-deps # 只检查依赖

    注意：依赖自举那段代码排在最前面执行（见 PRELUDE），必须在**任何 PySide6
    导入之前** —— 否则没装 PySide6 的机器会在半路 ImportError，自动安装形同虚设。

    版本号只在 version.py 里定义；生成方式：python build_single.py
    （请勿手工修改本文件，改动请改多文件源码）
    """


    # ========================================================================
    # 来自 i18n_data.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """i18n 词表（由 _gen_i18n.py 生成，请勿手改本文件）。

    键 = 简体原文；值 = (繁體, English)。tr() 查不到时回落原文。
    """

    # key: 简体原文 -> (繁體, English)
    TABLE = {
        "区域截图": ("區域截圖", "Capture Region"),
        "框选一块区域截图": ("框選一塊區域截圖", "Drag to capture a region"),
        "全屏截图": ("全螢幕截圖", "Capture Full Screen"),
        "截取鼠标所在的那块显示器": ("截取滑鼠所在的那塊顯示器", "Capture the monitor the mouse is on"),
        "选择显示器截图": ("選擇顯示器截圖", "Capture a Specific Monitor"),
        "滚动长截图（实验性）": ("捲動長截圖（實驗性）", "Scrolling Capture (experimental)"),
        "说明：实验性功能，长图可能重复、错位或拼不上": ("說明：實驗性功能，長圖可能重複、错位或拼不上", "Note: experimental — the long image may repeat, misalign, or fail to stitch"),
        "启用滚动长截图（不稳定）": ("啟用捲動長截圖（不穩定）", "Enable Scrolling Capture (unstable)"),
        "默认关闭：这个功能还在实验阶段，长图可能重复、错位或拼不上": ("預設關閉：這個功能還在實驗阶段，長圖可能重複、错位或拼不上", "Off by default: this feature is still experimental — the long image may repeat, misalign, or fail to stitch"),
        "自动滚轮": ("自動滾輪", "Auto Wheel"),
        "框选可滚动区域，程序自己发滚轮逐屏拼接（普通网页/文档）": ("框選可捲動區域，程序自己发滾輪逐屏拼接（普通網頁/文档）", "Select a scrollable area; PyShot sends wheel events and stitches (web pages, documents)"),
        "拖拽滚动条": ("拖曳捲動條", "Drag Scrollbar"),
        "框选区域后点一下滚动条滑块，程序按住滑块匀速拖拽。\n远程桌面 / Citrix 里最稳：步长会实测标定": ("框選區域後點一下捲動條滑桿，程序按住滑桿勻速拖曳。\n遠端桌面 / Citrix 裡最穩：步長會實測標定", "Select an area, then click the scrollbar thumb; PyShot drags it steadily.\nMost reliable in Remote Desktop / Citrix (the step size is calibrated automatically)"),
        "按键翻页": ("按鍵翻頁", "Page Down"),
        "框选区域后程序发送 PageDown 翻页（适合没有滚动条的应用）": ("框選區域後程序发送 PageDown 翻頁（適合沒有捲動條的套用）", "Select an area; PyShot sends Page Down (for apps without a scrollbar)"),
        "手动滚动": ("手動捲動", "Manual Scroll"),
        "自己用滚轮滚动，程序只负责逐帧拼接": ("自己用滾輪捲動，程序只負責逐幀拼接", "You scroll; PyShot only stitches the frames"),
        "屏幕取色": ("螢幕取色", "Screen Color Picker"),
        "单击屏幕任意位置，把色值复制到剪贴板": ("單擊螢幕任意位置，把色值複製到剪貼簿", "Click anywhere to copy its color to the clipboard"),
        "贴出剪贴板图片": ("貼出剪貼簿圖片", "Pin Clipboard Image"),
        "把剪贴板里的图片钉在屏幕最上层": ("把剪貼簿裡的圖片钉在螢幕最上層", "Pin the clipboard image on top of the screen"),
        "打开图片编辑…": ("開啟圖片編輯…", "Open Image for Editing…"),
        "打开一张已有图片进行标注": ("開啟一張已有圖片進行標注", "Open an existing image to annotate"),
        "显示编辑器": ("顯示編輯器", "Show Editor"),
        "直接打开编辑器窗口（空白也能用，从它的「文件」菜单打开图片）": ("直接開啟編輯器窗口（空白也能用，从它的「檔案」菜單開啟圖片）", "Open the editor window directly (works even when empty; use its File menu to open an image)"),
        "语言": ("語言", "Language"),
        "取消截图": ("取消截圖", "Cancel Capture"),
        "收起正在显示的截图遮罩（Esc / 再按一次热键也可以）": ("收起正在顯示的截圖遮罩（Esc / 再按一次快速鍵也可以）", "Dismiss the capture overlay (Esc or pressing the hotkey again also works)"),
        "退出 PyShot": ("結束 PyShot", "Exit PyShot"),
        "按系统语言自动选择": ("按系統語言自動選擇", "Choose automatically from the system language"),
        "界面语言已切换": ("介面語言已切換", "Interface language changed"),
        "所有显示器拼成一张": ("所有顯示器拼成一張", "All Monitors as One Image"),
        "把每块显示器按逻辑位置拼成一张长图": ("把每塊顯示器按邏輯位置拼成一張長圖", "Stitch every monitor into a single image"),
        "总耗时 ": ("總耗時 ", ""),
        "工具：选择": ("工具：選擇", "Tool: Select"),
        "耗时 ": ("耗時 ", ""),
        " ms（一次性）": (" ms（一次性）", ""),
        " 张，耗时 ": (" 張，耗時 ", ""),
        "从进程开始到就绪 ": ("从進程開始到就绪 ", ""),
        "滚动长截图开关 = ": ("捲動長截圖開關 = ", ""),
        "滚动长截图（实验性功能）": ("捲動長截圖（實驗性功能）", "Scrolling Capture (experimental)"),
        "滚动长截图还是实验性功能，默认关闭。": ("捲動長截圖還是實驗性功能，預設關閉。", "Scrolling capture is still experimental and is off by default."),
        "它靠「逐帧拼接」实现：程序自己滚动画面，再把每一帧接起来。遇到下面这些情况很容易出问题：\n· 只对普通网页/文档比较可靠；Citrix、远程桌面、Java、虚拟机里的画面经常拼不上\n· 可能拼出重复内容或错位，也可能滚到一半就停住\n· 滚动期间不要动鼠标键盘，窗口也不要移动或缩放\n\n只要一张普通截图的话，用「区域截图 / 全屏截图」就够了。确实需要长图再启用。": ("它靠「逐幀拼接」實現：程序自己捲動畫面，再把每一幀接起來。遇到下面這些情况很容易出问題：\n· 只對普通網頁/文档比較可靠；Citrix、遠端桌面、Java、虛擬機裡的畫面經常拼不上\n· 可能拼出重複內容或错位，也可能滾到一半就停住\n· 捲動期間不要動滑鼠鍵盤，窗口也不要移動或縮放\n\n只要一張普通截圖的话，用「區域截圖 / 全螢幕截圖」就够了。確實需要長圖再啟用。", "It works by stitching frame after frame: PyShot scrolls the view and joins the frames back together. It goes wrong easily when:\n· Only plain web pages/documents are fairly reliable; Citrix, Remote Desktop, Java apps and virtual machines often fail to stitch\n· The result may repeat content or misalign, or stop halfway\n· Do not touch the mouse or keyboard while it scrolls, and do not move or resize the window\n\nIf you only need a normal screenshot, Capture Region / Capture Full Screen is enough. Enable this only when you really need a long image."),
        "不再提示": ("不再提示", "Don't show again"),
        "仍然启用": ("仍然啟用", "Enable anyway"),
        "取消": ("取消", "Cancel"),
        "拖拽滚动条自动滚动": ("拖曳捲動條自動捲動", "Drag the scrollbar to scroll automatically"),
        "已记录滚动条位置": ("已記錄捲動條位置", "Scrollbar position recorded"),
        "滚到底会自动结束；想中途停止点控制条上的按钮。": ("滾到底會自動結束；想中途停止點控製條上的按鈕。", "It stops automatically at the bottom; click the button on the bar to stop early."),
        "滚动截图完成": ("捲動截圖完成", "Scrolling capture done"),
        "已拼接 ": ("已拼接 ", "Stitched "),
        " px 长图": (" px 長圖", " px"),
        "滚动截图失败": ("捲動截圖失敗", "Scrolling capture failed"),
        "PyShot 已启动": ("PyShot 已啟動", "PyShot started"),
        "打开图片": ("開啟圖片", "Open Image"),
        "图片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp)": ("圖片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp)", "Images (*.png *.jpg *.jpeg *.bmp *.gif *.webp)"),
        "[PyShot] 全局热键已注册：": ("[PyShot] 全局快速鍵已註冊：", ""),
        "[PyShot] 热键注册失败，已尝试：": ("[PyShot] 快速鍵註冊失敗，已嘗試：", ""),
        "{} 区域截图": ("{} 區域截圖", "{} Capture Region"),
        "{} 全屏截图": ("{} 全螢幕截圖", "{} Capture Full Screen"),
        "PyShot 截图工具\n{}\n双击图标截图": ("PyShot 截圖工具\n{}\n雙擊圖示截圖", "PyShot Screen Capture\n{}\nDouble-click the icon to capture"),
        "PyShot 截图工具\n双击图标截图 · 右键菜单": ("PyShot 截圖工具\n雙擊圖示截圖 · 右鍵菜單", "PyShot Screen Capture\nDouble-click to capture · right-click for the menu"),
        "跟随系统": ("跟隨系統", "Follow system"),
        "主屏": ("主屏", "Primary"),
        "（未检测到显示器）": ("（未偵測到顯示器）", "(no monitor detected)"),
        "PyShot 截图工具": ("PyShot 截圖工具", "PyShot Screen Capture"),
        "单击不截图：双击托盘图标开始截图（也可以按 {}）": ("單擊不截圖：雙擊托盤圖示開始截圖（也可以按 {}）", "A single click does not capture — double-click the tray icon to start (or press {})"),
        "单击不截图：双击托盘图标开始截图": ("單擊不截圖：雙擊托盤圖示開始截圖", "A single click does not capture — double-click the tray icon to start"),
        " 块屏，耗时 ": (" 塊屏，耗時 ", ""),
        "全屏截图完成": ("全螢幕截圖完成", "Full-screen capture done"),
        "滚动长截图未启用": ("捲動長截圖未啟用", "Scrolling capture is not enabled"),
        "这是实验性功能，默认关闭。请在托盘菜单「滚动长截图（实验性）」里勾选「启用滚动长截图（不稳定）」后再用。": ("這是實驗性功能，預設關閉。請在托盤菜單「捲動長截圖（實驗性）」裡勾選「啟用捲動長截圖（不穩定）」後再用。", "This is an experimental feature and is off by default. In the tray menu, open “Scrolling Capture (experimental)” and tick “Enable Scrolling Capture (unstable)” first."),
        "滚动截图": ("捲動截圖", "Scrolling capture"),
        "区域太小，请框选更高的可滚动区域": ("區域太小，請框選更高的可捲動區域", "Area too small — select a taller scrollable region"),
        "滑块锚点 ({}, {})，开始自动拖拽滚动。\n": ("滑桿錨點 ({}, {})，開始自動拖曳捲動。\n", "Thumb anchor ({}, {}) — starting to drag.\n"),
        "已复制": ("已複製", "Copied"),
        "贴图": ("釘圖", "Pin"),
        "剪贴板里没有图片": ("剪貼簿裡沒有圖片", "No image in the clipboard"),
        "PyShot 热键不可用": ("PyShot 快速鍵不可用", "PyShot hotkeys unavailable"),
        "按 {} 框选截图，或双击托盘图标。\n": ("按 {} 框選截圖，或雙擊托盤圖示。\n", "Press {} to capture a region, or double-click the tray icon.\n"),
        "右键托盘图标：滚动长截图 / 屏幕取色 / 贴图 / 退出。\n找不到图标时点任务栏右侧的 ∧ 展开。": ("右鍵托盤圖示：捲動長截圖 / 螢幕取色 / 釘圖 / 結束。\n找不到圖示時點任務欄右側的 ∧ 展開。", "Right-click the tray icon: scrolling capture / color picker / pin / exit.\nIf the icon is hidden, click the ∧ arrow near the clock."),
        "跳过保存：当前 ": ("跳過儲存：當前 ", ""),
        " 个标签少于缓存的 ": (" 個標籤少於緩存的 ", ""),
        "启动·托盘就绪": ("啟動·托盤就绪", ""),
        "区域 ": ("區域 ", ""),
        "全屏 ": ("全螢幕 ", ""),
        " 排队 ": (" 排队 ", ""),
        "ms，实际等了 ": ("ms，實際等了 ", ""),
        " 耗时 ": (" 耗時 ", ""),
        "热键（{}）都被占用，请双击托盘图标截图。\n": ("快速鍵（{}）都被佔用，請雙擊托盤圖示截圖。\n", "Hotkeys ({}) are all taken — double-click the tray icon to capture.\n"),
        "可用环境变量 PYSHOT_HOTKEY 指定其他组合，例如 PYSHOT_HOTKEY=ctrl+alt+j": ("可用環境變數 PYSHOT_HOTKEY 指定其他組合，例如 PYSHOT_HOTKEY=ctrl+alt+j", "Set PYSHOT_HOTKEY to pick another combination, e.g. PYSHOT_HOTKEY=ctrl+alt+j"),
        "PyShot 已启动（恢复了 {} 张上次的截图）": ("PyShot 已啟動（恢複了 {} 張上次的截圖）", "PyShot started (restored {} capture(s))"),
        " · 从进程开始 ": (" · 从進程開始 ", ""),
        " ms（热键=": (" ms（快速鍵=", ""),
        "显示器 {}": ("顯示器 {}", "Monitor {}"),
        "打开编辑器失败": ("開啟編輯器失敗", "Could not open the editor"),
        "全屏截图失败": ("全螢幕截圖失敗", "Full-screen capture failed"),
        "兜底：确保覆盖层真的铺满并且是画出来的。\n\n        注意：**不能**因为 _bg 还没抓回来就跳过 —— 抓屏是延后做的（先显示遮罩、\n        后抓底图），这里要是等 _bg，头几帧的兜底就全空转了，多屏/缩放下遮罩\n        可能压根没铺好（曾因此表现成\"遮罩卡住不动\"）。\n        ": ("兜底：確保覆蓋層真的鋪滿并且是畫出來的。\n\n        注意：**不能**因為 _bg 還沒抓回來就跳過 —— 抓屏是延後做的（先顯示遮罩、\n        後抓底圖），這裡要是等 _bg，頭几幀的兜底就全空轉了，多屏/縮放下遮罩\n        可能壓根沒鋪好（曾因此表現成\"遮罩卡住不動\"）。\n        ", ""),
        "底图=空": ("底圖=空", ""),
        "底图=自检失败": ("底圖=自檢失敗", ""),
        "屏=": ("屏=", ""),
        "屏幕取色：单击复制色值    ·    Esc / 右键 取消": ("螢幕取色：單擊複製色值    ·    Esc / 右鍵 取消", "Color picker: click to copy the value    ·    Esc / right-click to cancel"),
        "底图=": ("底圖=", ""),
        " 平均亮度=": (" 平均亮度=", ""),
        " 采样色数=": (" 采樣色數=", ""),
        "（疑似纯色/拍到自己！）": ("（疑似純色/拍到自己！）", ""),
        "拖拽选择要滚动截图的区域    ·    Esc / 右键 取消": ("拖曳選擇要捲動截圖的區域    ·    Esc / 右鍵 取消", "Drag to select the area to scroll-capture    ·    Esc / right-click to cancel"),
        "蓝框内可直接点击滚动条【滑块】→ 自动开始滚动    ·    Esc 取消": ("藍框內可直接點擊捲動條【滑桿】→ 自動開始捲動    ·    Esc 取消", "Click the scrollbar thumb inside the frame to start    ·    Esc to cancel"),
        "拖拽选择截图区域    ·    Esc / 右键 取消": ("拖曳選擇截圖區域    ·    Esc / 右鍵 取消", "Drag to select a region    ·    Esc / right-click to cancel"),
        "选择": ("選擇", "Select"),
        "选择并移动已有标注（Delete 删除）": ("選擇并移動已有標注（Delete 刪除）", "Select and move annotations (Delete to remove)"),
        "矩形": ("矩形", "Rectangle"),
        "拖拽画矩形，Shift 画正方形": ("拖曳畫矩形，Shift 畫正方形", "Drag for a rectangle, Shift for a square"),
        "椭圆": ("橢圓", "Ellipse"),
        "拖拽画椭圆，Shift 画正圆": ("拖曳畫橢圓，Shift 畫正圓", "Drag for an ellipse, Shift for a circle"),
        "直线": ("直線", "Line"),
        "拖拽画直线，Shift 锁定水平/垂直/45°": ("拖曳畫直線，Shift 鎖定水平/垂直/45°", "Drag for a line, Shift locks to 0/45/90°"),
        "箭头": ("箭頭", "Arrow"),
        "拖拽画箭头，指引方向": ("拖曳畫箭頭，指引方向", "Drag for an arrow"),
        "画笔": ("畫筆", "Pen"),
        "自由手绘": ("自由手繪", "Freehand drawing"),
        "序号": ("序號", "Step Number"),
        "单击放置递增序号，做步骤指引": ("單擊放置遞增序號，做步驟指引", "Click to place an incrementing step number"),
        "文字": ("文字", "Text"),
        "单击后输入文字，Enter 确认": ("單擊後輸入文字，Enter 確認", "Click and type, Enter to confirm"),
        "高亮": ("標示", "Highlight"),
        "拖拽涂抹半透明高亮": ("拖曳塗抹半透明標示", "Drag to paint a translucent highlight"),
        "马赛克": ("馬賽克", "Mosaic"),
        "拖拽对区域打码": ("拖曳對區域打碼", "Drag to pixelate an area"),
        "取色": ("取色", "Pick Color"),
        "单击吸取图上颜色作为当前标注颜色": ("單擊吸取圖上顏色作為當前標注顏色", "Click to pick a color from the image"),
        "裁剪": ("裁剪", "Crop"),
        "拖拽选择保留区域，Enter 应用": ("拖曳選擇保留區域，Enter 套用", "Drag to select what to keep, Enter to apply"),
        "抓手": ("抓手", "Hand"),
        "拖拽移动画面（图放大后看不同位置）；任何工具下按住中键或空格也能拖": ("拖曳移動畫面（圖放大後看不同位置）；任何工具下按住中鍵或空格也能拖", "Drag to move the view (look around once zoomed in); middle-drag or hold Space works with any tool"),
        "选择颜色": ("選擇顏色", "Choose a color"),
        "颜色": ("顏色", "Color"),
        "自定义…": ("自定義…", "Custom…"),
        "打开系统拾色器": ("開啟系統拾色器", "Open the system color picker"),
        "自定义颜色": ("自定義顏色", "Custom colors"),
        "输入文字，Enter 确认 / Esc 取消": ("輸入文字，Enter 確認 / Esc 取消", "Type text, Enter to confirm / Esc to cancel"),
        "PyShot 编辑器": ("PyShot 編輯器", "PyShot Editor"),
        "还没有图片": ("還沒有圖片", "No image yet"),
        "从「文件」菜单打开图片，或直接截图 / 从剪贴板粘贴": ("从「檔案」菜單開啟圖片，或直接截圖 / 从剪貼簿貼上", "Open an image from the File menu, capture the screen, or paste from the clipboard"),
        "文件": ("檔案", "File"),
        "打开图片…": ("開啟圖片…", "Open Image…"),
        "打开剪贴板图片": ("開啟剪貼簿圖片", "Open Clipboard Image"),
        "把剪贴板里的图片作为**新标签**打开": ("把剪貼簿裡的圖片作為**新標籤**開啟", "Open the clipboard image as a **new tab**"),
        "保存": ("儲存", "Save"),
        "关闭当前标签": ("關閉當前標籤", "Close Tab"),
        "退出": ("結束", "Exit"),
        "编辑": ("編輯", "Edit"),
        "撤销": ("復原", "Undo"),
        "重做": ("重做", "Redo"),
        "粘贴到当前图（浮动）": ("貼上到當前圖（浮動）", "Paste onto This Image (floating)"),
        "把剪贴板里的截图贴到当前图上：拖动摆位置、Ctrl+滚轮缩放，Enter 固定、Esc 取消": ("把剪貼簿裡的截圖貼到當前圖上：拖動擺位置、Ctrl+滾輪縮放，Enter 固定、Esc 取消", "Paste the clipboard screenshot onto this image: drag to place it, Ctrl+wheel to scale, Enter to apply, Esc to discard"),
        "固定粘贴的图": ("固定貼上的圖", "Apply Pasted Image"),
        "把正在摆放的粘贴图合成进当前图（Enter）": ("把正在擺放的貼上圖合成進當前圖（Enter）", "Merge the pasted image into this one (Enter)"),
        "取消粘贴": ("取消貼上", "Discard Paste"),
        "丢掉正在摆放的粘贴图（Esc）": ("丢掉正在擺放的貼上圖（Esc）", "Throw away the pasted image (Esc)"),
        "粘贴图外观": ("貼上圖外观", "Pasted Image Style"),
        "加阴影": ("加陰影", "Add shadow"),
        "加白色描边": ("加白色描邊", "Add white outline"),
        "置于顶层": ("置於顶層", "Bring to Front"),
        "置于底层": ("置於底層", "Send to Back"),
        "上移一层": ("上移一層", "Bring Forward"),
        "下移一层": ("下移一層", "Send Backward"),
        "再制一个": ("再製一個", "Duplicate"),
        "复制选中的图形/文字，向右下错开一点": ("複製選中的圖形/文字，向右下错開一點", "Copy the selected shape/text, offset slightly down-right"),
        "旋转 15°": ("旋轉 15°", "Rotate 15°"),
        "把选中图形转 15°（拖它上面的圆形手柄可以任意角度）": ("把選中圖形轉 15°（拖它上面的圓形手柄可以任意角度）", "Rotate the selection by 15° (drag the round handle above it for any angle)"),
        "摆正（0°）": ("擺正（0°）", "Straighten (0°)"),
        "修改文字…": ("修改文字…", "Edit Text…"),
        "改选中文字的内容（也可以直接双击文字）": ("改選中文字的內容（也可以直接雙擊文字）", "Change the selected text (or just double-click the text)"),
        "字体…": ("字體…", "Font…"),
        "选字体/字号/粗体：选中文字就改它，否则改之后新写的文字": ("選字體/字號/粗體：選中文字就改它，否則改之後新寫的文字", "Pick family/size/bold: applies to the selected text, otherwise to text you write next"),
        "复制到剪贴板": ("複製到剪貼簿", "Copy to Clipboard"),
        "贴图到屏幕": ("釘圖到螢幕", "Pin to Screen"),
        "视图": ("視圖", "View"),
        "放大": ("放大", "Zoom In"),
        "缩小": ("縮小", "Zoom Out"),
        "实际像素 (1:1)": ("實際像素 (1:1)", "Actual pixels (1:1)"),
        "适应窗口": ("符合窗口", "Fit to Window"),
        "显示左侧工具条": ("顯示左側工具條", "Show Tool Rail"),
        "工具条可以滚动；嫌占地方就整条收起（工具快捷键依然可用）": ("工具條可以捲動；嫌占地方就整條收起（工具快捷鍵依然可用）", "The tool rail scrolls; turn it off entirely if you need the space (tool shortcuts still work)"),
        "特效": ("特效", "Effects"),
        "水印…": ("水印…", "Watermark…"),
        "边框…": ("邊框…", "Border…"),
        "水平翻转": ("水平翻轉", "Flip Horizontally"),
        "左右镜像（标注也跟着翻，可 Ctrl+Z 撤销）": ("左右镜像（標注也跟着翻，可 Ctrl+Z 復原）", "Mirror left-right (annotations flip too; Ctrl+Z to undo)"),
        "垂直翻转": ("垂直翻轉", "Flip Vertically"),
        "上下镜像（标注也跟着翻，可 Ctrl+Z 撤销）": ("上下镜像（標注也跟着翻，可 Ctrl+Z 復原）", "Mirror top-bottom (annotations flip too; Ctrl+Z to undo)"),
        "顺时针 90°": ("順時针 90°", "Rotate 90° CW"),
        "逆时针 90°": ("逆時针 90°", "Rotate 90° CCW"),
        "调整尺寸…": ("調整尺寸…", "Resize…"),
        "按像素重设整张图（含标注），可 Ctrl+Z 撤销": ("按像素重設整張圖（含標注），可 Ctrl+Z 復原", "Resize the whole image in pixels (annotations scale with it); Ctrl+Z to undo"),
        "选项": ("選項", "Options"),
        "启动时恢复上次的截图": ("啟動時恢複上次的截圖", "Restore last captures on startup"),
        "重启后自动把上次编辑的截图放回来（存在缓存里，不需要你保存）": ("重啟後自動把上次編輯的截圖放回來（存在緩存裡，不需要你儲存）", "Bring back your last captures automatically after a restart (kept in a cache — no need to save)"),
        "截图时不最小化编辑器": ("截圖時不最小化編輯器", "Keep the editor visible while capturing"),
        "打开后截图时编辑器留在原地，方便截编辑器自己；平时关着（截图时自动让位，免得被拍进图里）": ("開啟後截圖時編輯器留在原地，方便截編輯器自己；平時關着（截圖時自動讓位，免得被拍進圖裡）", "When on, the editor stays where it is while you capture — handy for capturing the editor itself. Keep it off normally, so the editor gets out of the way instead of appearing in your screenshot"),
        "清除上次的截图缓存": ("清除上次的截圖緩存", "Clear last-capture cache"),
        "编辑默认水印…": ("編輯預設水印…", "Edit Default Watermark…"),
        "编辑默认边框…": ("編輯預設邊框…", "Edit Default Border…"),
        "帮助": ("幫助", "Help"),
        "关于 PyShot": ("關於 PyShot", "About PyShot"),
        "已粘贴到当前图：拖动摆位置 · 拖手柄缩放、拖上方圆点旋转 · Enter 固定 · Esc 取消": ("已貼上到當前圖：拖動擺位置 · 拖手柄縮放、拖上方圓點旋轉 · Enter 固定 · Esc 取消", "Pasted onto this image: drag to place · drag the handles to scale, the dot above to rotate · Enter to apply · Esc to discard"),
        "已再制一个（Ctrl+Z 可撤销）": ("已再製一個（Ctrl+Z 可復原）", "Duplicated (Ctrl+Z to undo)"),
        "选择字体": ("選擇字體", "Choose Font"),
        "之后的文字用这个字体": ("之後的文字用這個字體", "New text will use this font"),
        "旋转 {:.0f}°（Ctrl+Z 可撤销）": ("旋轉 {:.0f}°（Ctrl+Z 可復原）", "Rotated {:.0f}° (Ctrl+Z to undo)"),
        "调整尺寸": ("調整尺寸", "Resize"),
        "宽度（像素，当前 {}）": ("寬度（像素，當前 {}）", "Width in pixels (currently {})"),
        "高度（像素，当前 {}）": ("高度（像素，當前 {}）", "Height in pixels (currently {})"),
        "已调整为 {} × {}（Ctrl+Z 可撤销）": ("已調整為 {} × {}（Ctrl+Z 可復原）", "Resized to {} × {} (Ctrl+Z to undo)"),
        "PyShot {} — {}\n仿 FastStone Capture 的截图与标注工具\n\n托盘右键：区域截图 / 全屏截图 / 滚动长截图 / 屏幕取色 / 贴图\n编辑器：多标签标注 · 粘贴拼图 · 水印 · 加边框（含手撕纸）· 三语界面": ("PyShot {} — {}\n仿 FastStone Capture 的截圖與標注工具\n\n托盤右鍵：區域截圖 / 全螢幕截圖 / 捲動長截圖 / 螢幕取色 / 釘圖\n編輯器：多標籤標注 · 貼上拼圖 · 水印 · 加邊框（含手撕紙）· 三語介面", "PyShot {} — {}\nA FastStone Capture style screenshot and annotation tool\n\nTray menu: region / full-screen capture, scrolling capture, color picker, pin\nEditor: multi-tab annotation · paste & compose · watermark · borders (incl. torn paper) · 3 languages"),
        "关闭此标签 (Ctrl+W)": ("關閉此標籤 (Ctrl+W)", "Close this tab (Ctrl+W)"),
        "截图": ("截圖", "Capture"),
        "截取新区域\n会自动最小化编辑器，截完回到这里新增标签": ("截取新區域\n會自動最小化編輯器，截完回到這裡新增標籤", "Capture a new region\nThe editor is minimized and the capture is added as a tab"),
        "更多颜色…（基本颜色 + 自定义颜色）": ("更多顏色…（基本顏色 + 自定義顏色）", "More colors… (basic + custom)"),
        "序号圆的大小\n选中已有序号时可直接调整它的大小": ("序號圓的大小\n選中已有序號時可直接調整它的大小", "Step-circle size\nAdjusts the selected step number directly"),
        "撤销 (Ctrl+Z)": ("復原 (Ctrl+Z)", "Undo (Ctrl+Z)"),
        "重做 (Ctrl+Y)": ("重做 (Ctrl+Y)", "Redo (Ctrl+Y)"),
        "应用裁剪": ("套用裁剪", "Apply Crop"),
        "应用裁剪框 (Enter)": ("套用裁剪框 (Enter)", "Apply the crop (Enter)"),
        "复制": ("複製", "Copy"),
        "复制到剪贴板 (Ctrl+C)": ("複製到剪貼簿 (Ctrl+C)", "Copy to clipboard (Ctrl+C)"),
        "把当前结果钉在屏幕最上层（Snipaste 风格）": ("把當前結果钉在螢幕最上層（Snipaste 風格）", "Pin the result on top of the screen (Snipaste style)"),
        "水印": ("水印", "Watermark"),
        "水印：文字与图片可各自开关（也可同时用）\n九宫格位置或平铺、各自调不透明度、可旋转与设边距\n还能「应用并设为默认」，之后新截图自动加": ("水印：文字與圖片可各自開關（也可同時用）\n九宮格位置或平鋪、各自調不透明度、可旋轉與設邊距\n還能「套用并設為預設」，之後新截圖自動加", "Watermark: text and image can be used together\n9-grid position or tiling, separate opacity, rotation and margin\nApply and set as default to add it to new captures"),
        "边框": ("邊框", "Border"),
        "加边框（对应 FSCapture 的「特效 → 边缘」）\n单线/双线/虚线/圆角/投影阴影/立体浮雕/边缘渐隐/拍立得白边\n边框加在图片外面，图会变大；可 Ctrl+Z 撤销": ("加邊框（對應 FSCapture 的「特效 → 邊缘」）\n單線/雙線/虛線/圓角/投影陰影/立體浮雕/邊缘漸隱/拍立得白邊\n邊框加在圖片外面，圖會變大；可 Ctrl+Z 復原", "Border (FSCapture's Effects -> Edge)\nSolid / double / dashed / rounded / drop shadow / bevel / fade / polaroid / torn paper\nThe border goes outside the image, so the result gets bigger; Ctrl+Z to undo"),
        "保存为文件 (Ctrl+S)": ("儲存為檔案 (Ctrl+S)", "Save to a file (Ctrl+S)"),
        "关闭": ("關閉", "Close"),
        "关闭编辑器 (Esc)": ("關閉編輯器 (Esc)", "Close the editor (Esc)"),
        "缩小 (Ctrl+滚轮)": ("縮小 (Ctrl+滾輪)", "Zoom out (Ctrl+wheel)"),
        "放大 (Ctrl+滚轮)": ("放大 (Ctrl+滾輪)", "Zoom in (Ctrl+wheel)"),
        "截取新区域{}\n会自动最小化编辑器，截完回到这里新增标签": ("截取新區域{}\n會自動最小化編輯器，截完回到這裡新增標籤", "Capture a new region{}\nThe editor is minimized; new captures are added as tabs"),
        "已复制到剪贴板": ("已複製到剪貼簿", "Copied to the clipboard"),
        "已设为默认水印，之后每次新截图会自动添加": ("已設為預設水印，之後每次新截圖會自動添加", "Saved as the default watermark; it will be added automatically"),
        "已设为默认水印（本次运行有效，配置写入失败）": ("已設為預設水印（本次運行有效，配置寫入失敗）", "Saved as the default watermark for this session (config write failed)"),
        "保存截图": ("儲存截圖", "Save Capture"),
        "PNG 图片 (*.png);;JPEG 图片 (*.jpg);;BMP 图片 (*.bmp)": ("PNG 圖片 (*.png);;JPEG 圖片 (*.jpg);;BMP 圖片 (*.bmp)", "PNG image (*.png);;JPEG image (*.jpg);;BMP image (*.bmp)"),
        "基本颜色": ("基本顏色", "Basic colors"),
        "删除": ("刪除", "Delete"),
        "直角": ("直角", "Square corners"),
        "小圆角": ("小圓角", "Slightly rounded"),
        "大圆角": ("大圓角", "Very rounded"),
        "已固定粘贴的图（Ctrl+Z 可撤销）": ("已固定貼上的圖（Ctrl+Z 可復原）", "Pasted image applied (Ctrl+Z to undo)"),
        "先选一个图形（用「选择」工具点一下）": ("先選一個圖形（用「選擇」工具點一下）", "Select a shape first (click it with the Select tool)"),
        "先选一段文字（用「选择」工具点一下，或直接双击文字）": ("先選一段文字（用「選擇」工具點一下，或直接雙擊文字）", "Select a text object first (click it with Select, or double-click the text)"),
        "已改字体（Ctrl+Z 可撤销）": ("已改字體（Ctrl+Z 可復原）", "Font changed (Ctrl+Z to undo)"),
        "已取消粘贴": ("已取消貼上", "Paste discarded"),
        "已水平翻转（Ctrl+Z 可撤销）": ("已水平翻轉（Ctrl+Z 可復原）", "Flipped horizontally (Ctrl+Z to undo)"),
        "已垂直翻转（Ctrl+Z 可撤销）": ("已垂直翻轉（Ctrl+Z 可復原）", "Flipped vertically (Ctrl+Z to undo)"),
        "已开启：截图时编辑器留在原地（方便截编辑器自己）": ("已開啟：截圖時編輯器留在原地（方便截編輯器自己）", "On: the editor stays visible while capturing (good for capturing the editor)"),
        "已关闭：截图时编辑器自动最小化让位": ("已關閉：截圖時編輯器自動最小化讓位", "Off: the editor minimizes itself while capturing"),
        "已收起左侧工具条（工具快捷键仍可用；想恢复：视图菜单）": ("已收起左側工具條（工具快捷鍵仍可用；想恢複：視圖菜單）", "Tool rail hidden (shortcuts still work; bring it back from the View menu)"),
        "已显示左侧工具条": ("已顯示左側工具條", "Tool rail shown"),
        "已清除上次的截图缓存": ("已清除上次的截圖緩存", "Last-capture cache cleared"),
        "已设为默认边框，之后每次新截图会自动加": ("已設為預設邊框，之後每次新截圖會自動加", "Saved as the default border; it will be added automatically"),
        "滚轮/Ctrl+滚轮 缩放 · 中键或空格拖动查看": ("滾輪/Ctrl+滾輪 縮放 · 中鍵或空格拖動查看", "Wheel / Ctrl+wheel to zoom · middle-drag or Space to pan"),
        "线宽": ("線寬", "Width"),
        "字号": ("字號", "Size"),
        "适应": ("符合", "Fit"),
        "缩放以适应窗口": ("縮放以符合窗口", "Scale to fit the window"),
        "工具：": ("工具：", "Tool: "),
        " 工具": (" 工具", " Tool"),
        "已设为默认边框（本次运行有效，配置写入失败）": ("已設為預設邊框（本次運行有效，配置寫入失敗）", "Saved as the default border for this session (config write failed)"),
        "边框宽度为 0，未做改动": ("邊框寬度為 0，未做改動", "Border width is 0 — nothing changed"),
        "已保存：": ("已儲存：", "Saved: "),
        "点这里定义一个自定义颜色…": ("點這裡定義一個自定義顏色…", "Click to define a custom color…"),
        "已旋转 90°（Ctrl+Z 可撤销）": ("已旋轉 90°（Ctrl+Z 可復原）", "Rotated 90° (Ctrl+Z to undo)"),
        "已逆时针旋转 90°（Ctrl+Z 可撤销）": ("已逆時针旋轉 90°（Ctrl+Z 可復原）", "Rotated 90° counter-clockwise (Ctrl+Z to undo)"),
        "当前颜色": ("當前顏色", "Current color"),
        "已加边框：": ("已加邊框：", "Border added: "),
        "截图 {}": ("截圖 {}", "Capture {}"),
        "，切回": ("，切回", ", back to "),
        "已取色": ("已取色", "Picked"),
        "单线边框": ("單線邊框", "Solid Line"),
        "纯色边框，最简洁": ("純色邊框，最簡潔", "A simple solid border"),
        "双线边框": ("雙線邊框", "Double Line"),
        "外粗内细的双线": ("外粗內細的雙線", "A thick outer and thin inner line"),
        "虚线边框": ("虛線邊框", "Dashed"),
        "虚线描边": ("虛線描邊", "Dashed outline"),
        "圆角边框": ("圓角邊框", "Rounded"),
        "图片切圆角 + 描边": ("圖片切圓角 + 描邊", "Rounded corners with an outline"),
        "投影阴影": ("投影陰影", "Drop Shadow"),
        "四周柔和阴影（背景透明，适合贴到文档里）": ("四周柔和陰影（背景透明，適合貼到文档裡）", "Soft shadow, transparent background (great for documents)"),
        "立体浮雕": ("立體浮雕", "Bevel"),
        "左上亮、右下暗，做出凹凸感": ("左上亮、右下暗，做出凹凸感", "Light from the top-left, dark bottom-right"),
        "边缘渐隐": ("邊缘漸隱", "Fade Edges"),
        "图片四边渐隐到边框色": ("圖片四邊漸隱到邊框色", "The image fades into the border color"),
        "拍立得白边": ("拍立得白邊", "Polaroid"),
        "下方留宽白边，像拍立得": ("下方留寬白邊，像拍立得", "Wide white margin at the bottom"),
        "手撕纸": ("手撕紙", "Torn Paper"),
        "图片贴在一张撕下来的纸上，边缘不规则 + 投影": ("圖片貼在一張撕下來的紙上，邊缘不規則 + 投影", "The image sits on a torn piece of paper with an irregular edge and a shadow"),
        "边框颜色": ("邊框顏色", "Border color"),
        "边框 / 边缘效果": ("邊框 / 邊缘效果", "Border / Edge Effect"),
        "样式": ("樣式", "Style"),
        "宽度": ("寬度", "Width"),
        "圆角": ("圓角", "Corner radius"),
        "撕边": ("撕邊", "Tear"),
        "撕口的起伏幅度；不能超过纸边宽度": ("撕口的起伏幅度；不能超過紙邊寬度", "Depth of the torn edge; cannot exceed the paper margin"),
        "换一个撕法": ("換一個撕法", "Re-roll"),
        "重新随机撕口（同一个种子预览和成品一致）": ("重新隨機撕口（同一個種子預覽和成品一致）", "Pick a new random tear (the preview always matches the result)"),
        "阴影浓度": ("陰影濃度", "Shadow"),
        "细节": ("細節", "Details"),
        "预览": ("預覽", "Preview"),
        "应用": ("套用", "Apply"),
        "应用并设为默认": ("套用并設為預設", "Apply and Set as Default"),
        "投影浓度": ("投影濃度", "Shadow"),
        "仅供参考": ("僅供參考", "For reference only"),
        "左上": ("左上", "Top-left"),
        "上中": ("上中", "Top-center"),
        "右上": ("右上", "Top-right"),
        "左中": ("左中", "Middle-left"),
        "居中": ("居中", "Center"),
        "右中": ("右中", "Middle-right"),
        "左下": ("左下", "Bottom-left"),
        "下中": ("下中", "Bottom-center"),
        "右下": ("右下", "Bottom-right"),
        "未启用": ("未啟用", "Disabled"),
        "平铺": ("平鋪", "Tiled"),
        "选择水印字体": ("選擇水印字體", "Choose the watermark font"),
        "水印颜色": ("水印顏色", "Watermark color"),
        "文字「": ("文字「", "Text “"),
        "图片 ": ("圖片 ", "Image "),
        "文字水印": ("文字水印", "Text watermark"),
        "要加在水印上的文字（可多行）": ("要加在水印上的文字（可多行）", "Watermark text (multiple lines allowed)"),
        "文字颜色": ("文字顏色", "Text color"),
        "描边（深浅背景都清晰）": ("描邊（深淺背景都清晰）", "Outline (readable on any background)"),
        "粗体": ("粗體", "Bold"),
        "斜体": ("斜體", "Italic"),
        "图片水印": ("圖片水印", "Image watermark"),
        "选择一张图片（建议用透明底的 PNG）": ("選擇一張圖片（建議用透明底的 PNG）", "Choose an image (a transparent PNG works best)"),
        "浏览…": ("瀏覽…", "Browse…"),
        "清除": ("清除", "Clear"),
        " % 图宽": (" % 圖寬", "% of width"),
        "选择水印图片": ("選擇水印圖片", "Choose a watermark image"),
        "图片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp);;所有文件 (*.*)": ("圖片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp);;所有檔案 (*.*)", "Images (*.png *.jpg *.jpeg *.bmp *.gif *.webp);;All files (*.*)"),
        "位置与排布": ("位置與排布", "Position & Layout"),
        "平铺整张图": ("平鋪整張圖", "Tile across the image"),
        "字体": ("字體", "Font"),
        "不透明度": ("不透明度", "Opacity"),
        "大小": ("大小", "Size"),
        "（无图片）": ("（無圖片）", "(no image)"),
        "间距": ("間距", "Spacing"),
        "旋转": ("旋轉", "Rotate"),
        "边距": ("邊距", "Margin"),
        "（未选择）": ("（未選擇）", "(none)"),
        "需要 Frame 或数组，收到 ": ("需要 Frame 或數組，收到 ", ""),
        "选区里似乎包含多块独立滚动的区域（例如上方列表 + 下方明细面板），它们滚动量不同，拼不到一起。\n请只框选其中一个面板（不含固定的明细面板/工具栏）后重试。\n（排查用：设环境变量 PYSHOT_SCROLL_DEBUG=1 会把每帧存到 ~/.pyshot/scroll_debug）": ("選區裡似乎包含多塊獨立捲動的區域（例如上方列表 + 下方明細面板），它們捲動量不同，拼不到一起。\n請只框選其中一個面板（不含固定的明細面板/工具列）後重試。\n（排查用：設環境變數 PYSHOT_SCROLL_DEBUG=1 會把每幀存到 ~/.pyshot/scroll_debug）", "The selection seems to contain several independently scrolling areas, which cannot be stitched.\nPlease select only one panel (without fixed toolbars) and retry.\n(Diagnostics: set PYSHOT_SCROLL_DEBUG=1 to dump frames to ~/.pyshot/scroll_debug)"),
        " 占比 ": (" 占比 ", ""),
        " 明显高于 d=0 的 ": (" 明顯高於 d=0 的 ", ""),
        "（逐像素差 ": ("（逐像素差 ", ""),
        " 偏大，按占优判为命中）": (" 偏大，按占優判為命中）", ""),
        "滚动截图准备中…": ("捲動截圖準備中…", "Preparing scrolling capture…"),
        "完成 (Enter)": ("完成 (Enter)", "Done (Enter)"),
        "停止 (Esc)": ("停止 (Esc)", "Stop (Esc)"),
        "{}截图中… {} 帧 / {} px": ("{}截圖中… {} 幀 / {} px", "{}capturing… {} frames / {} px"),
        "（本帧 +{}）": ("（本幀 +{}）", "(+{} this frame)"),
        "未达阈值，取差异最小的帧（": ("未達阈值，取差異最小的幀（", ""),
        " 抓帧 ": (" 抓幀 ", ""),
        "首帧": ("首幀", "first frame"),
        "静止条带 ": ("靜止條帶 ", ""),
        "/6，算得 s=": ("/6，算得 s=", ""),
        "（占比 ": ("（占比 ", ""),
        "全局对不上，条带算出 s=": ("全局對不上，條帶算出 s=", ""),
        "全局 s=0，条带算出 s=": ("全局 s=0，條帶算出 s=", ""),
        "滚轮": ("滾輪", "Wheel"),
        "按键": ("按鍵", "Key"),
        "请用鼠标滚轮或 Page Down 自己滚动页面，滚到底后点「完成」": ("請用滑鼠滾輪或 Page Down 自己捲動頁面，滾到底後點「完成」", "Scroll with the wheel or Page Down, then click Done"),
        "差异 ": ("差異 ", ""),
        "（阈值 3.0）": ("（阈值 3.0）", ""),
        "模式=": ("模式=", ""),
        "帧#": ("幀#", ""),
        "抓帧失败：区域过小或被遮挡": ("抓幀失敗：區域過小或被遮擋", "Capture failed: the region is too small or hidden"),
        " 累计=": (" 累计=", ""),
        "拖拽没生效，改用滚轮重试": ("拖曳沒生效，改用滾輪重試", "Dragging had no effect — retrying with the wheel"),
        "没有抓到任何内容": ("沒有抓到任何內容", "Nothing was captured"),
        "手动": ("手動", "Manual"),
        "滚动": ("捲動", "Scroll"),
        "抓到的画面是空白/纯色，无法拼接。\n目标窗口（Citrix / 远程桌面 / Java 应用）多半在用硬件加速或内容保护，GDI 抓屏拿不到内容。按顺序试：\n① Citrix Workspace：关掉「使用硬件加速进行图形处理」；服务端策略把「视频编解码压缩」设为不使用\n② Java 应用：启动参数加 -Dsun.java2d.d3d=false -Dsun.java2d.opengl=false -Dsun.java2d.noddraw=true（强制走 GDI 绘制）\n③ 托盘菜单用「滚动长截图（手动滚动）」：你自己滚，程序只拼帧\n④ 把窗口最大化或调整大小后重试": ("抓到的畫面是空白/純色，無法拼接。\n目標窗口（Citrix / 遠端桌面 / Java 套用）多半在用硬體加速或內容保護，GDI 抓屏拿不到內容。按順序試：\n① Citrix Workspace：關掉「使用硬體加速進行圖形處理」；服務端策略把「影片編解碼壓縮」設為不使用\n② Java 套用：啟動參數加 -Dsun.java2d.d3d=false -Dsun.java2d.opengl=false -Dsun.java2d.noddraw=true（強製走 GDI 繪製）\n③ 托盤菜單用「捲動長截圖（手動捲動）」：你自己滾，程序只拼幀\n④ 把窗口最大化或調整大小後重試", "The captured frames are blank/solid and cannot be stitched.\nThe target window (Citrix / Remote Desktop / a Java app) is probably using hardware acceleration or content protection, which blocks GDI screen capture. Try, in order:\n(1) Citrix Workspace: turn off 'Use hardware acceleration for graphics'; on the server set video-codec compression to 'Do not use video codec'\n(2) Java apps: add -Dsun.java2d.d3d=false -Dsun.java2d.opengl=false -Dsun.java2d.noddraw=true to force GDI rendering\n(3) Tray menu -> Manual scrolling capture: you scroll, PyShot just stitches\n(4) Maximize or resize the window and retry"),
        "抓帧尺寸发生变化，已停止（请确保窗口未移动/缩放）": ("抓幀尺寸发生變化，已停止（請確保窗口未移動/縮放）", "The captured area changed size; stopped (keep the window fixed)"),
        " 累计高度 ": (" 累计高度 ", ""),
        "画面内容变化过快，无法对齐拼接。\n": ("畫面內容變化過快，無法對齊拼接。\n", "The content changed too fast to align and stitch.\n"),
        "拼接 +": ("拼接 +", ""),
        "px（静止边缘 top=": ("px（靜止邊缘 top=", ""),
        "拖拽和滚轮都没能让页面滚动。\n可能原因：点击位置不在滚动区域，或该窗口不响应注入的输入。\n建议改用「滚动长截图（PageDown 自动滚动）」或「手动滚动」。": ("拖曳和滾輪都沒能讓頁面捲動。\n可能原因：點擊位置不在捲動區域，或該窗口不響應注入的輸入。\n建議改用「捲動長截圖（PageDown 自動捲動）」或「手動捲動」。", "Neither dragging nor the wheel scrolled the page.\nThe click may be outside the scrollable area, or the window ignores injected input.\nTry Page Down mode or Manual scroll instead."),
        "整幅 ": ("整幅 ", ""),
        " 列 → 保留 [": (" 列 → 保留 [", ""),
        ")（左右共裁掉 ": (")（左右共裁掉 ", ""),
        " 列）": (" 列）", ""),
        "抓帧失败：": ("抓幀失敗：", "Capture failed: "),
        " 对不上，减小步长后重试": (" 對不上，减小步長後重試", ""),
        "拖拽滚动条模式下最常见的原因：点在了滚动条的**轨道**上而不是**滑块**上——那样会一次翻整页，无法拼接。请重新框选并点中滑块本身。\n": ("拖曳捲動條模式下最常見的原因：點在了捲動條的**軌道**上而不是**滑桿**上——那樣會一次翻整頁，無法拼接。請重新框選并點中滑桿本身。\n", "Most common cause: you clicked the scrollbar *track* instead of the *thumb*, which jumps a whole page. Select again and click the thumb itself.\n"),
        "（请关闭动画/视频后重试）\n": ("（請關閉動畫/影片後重試）\n", "(close animations/videos and retry)\n"),
        "复制图片": ("複製圖片", "Copy image"),
        "重置大小 / 透明度": ("重置大小 / 透明度", "Reset size / opacity"),
        "关闭 (Esc)": ("關閉 (Esc)", "Close (Esc)"),
        "PyShot 依赖安装失败": ("PyShot 依賴安裝失敗", "PyShot dependency installation failed"),
        "PyShot 依赖仍不可用": ("PyShot 依賴仍不可用", "PyShot dependencies are still unavailable"),
        " 依赖检查：": (" 依賴檢查：", ""),
        "  内嵌依赖目录: 无（将使用系统环境或自动安装）": ("  內嵌依賴目錄: 無（將使用系統環境或自動安裝）", ""),
        "  解释器: ": ("  解釋器: ", ""),
        "[PyShot] 缺少依赖：": ("[PyShot] 缺少依賴：", ""),
        "，正在自动安装（首次约需 1-3 分钟）…": ("，正在自動安裝（首次約需 1-3 分鐘）…", ", installing automatically (1–3 minutes the first time)…"),
        "请手动执行以下命令后重新运行：\n\n": ("請手動執行以下命令後重新運行：\n\n", ""),
        "以下库导入失败：": ("以下庫導入失敗：", "These libraries failed to import:"),
        "  内嵌依赖目录: ": ("  內嵌依賴目錄: ", ""),
        "[PyShot] 依赖检查：": ("[PyShot] 依賴檢查：", ""),
        " 已就绪。": (" 已就绪。", ""),
        "[PyShot] pip 执行失败：": ("[PyShot] pip 執行失敗：", ""),
        "  [缺失] ": ("  [缺失] ", ""),
        "工具条可滚动可收起": ("工具條可捲動可收起", "scrollable / collapsible tool rail"),
    }


    # ========================================================================
    # 来自 i18n.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """i18n.py —— 三语支持（简体 / 繁體 / English），默认跟随系统。

    设计
    ====
    - **键就是简体原文**（gettext 风格）：源码里写 `tr("区域截图")`，好读也好维护
    - 词表在 `i18n_data.py`（由 `_gen_i18n.py` 生成）
    - 查不到的词条**回落到原文**，所以漏译只是显示原文，不会崩
    - 语言选择存在 `~/.pyshot/settings.json`，首次运行按系统语言猜

    用法::


        tr("区域截图")
        tr("已保存：{}", path)          # 占位符用 {}，内部走 str.format
    """
    import json
    import locale
    import os
    from pathlib import Path



    # 语言代码 → 菜单里显示的名字（这三项本身不翻译）
    LANGUAGES = [("zh_CN", "简体中文"), ("zh_TW", "繁體中文"), ("en", "English")]
    DEFAULT_LANGUAGE = "zh_CN"
    AUTO = "auto"

    SETTINGS_PATH = Path.home() / ".pyshot" / "settings.json"
    _current = None
    _settings_cache = {}


    # ---------------------------------------------------------------- 系统语言探测

    def system_language() -> str:
        """按系统语言决定用哪套文案：中文分简繁，其它一律英文。"""
        code = ""
        # 先问 Qt（它更懂 Windows 的区域设置）
        try:
            from PySide6.QtCore import QLocale
            code = QLocale.system().name() or ""      # 例：zh_CN / zh_TW / en_US
        except Exception:                              # noqa: BLE001
            code = ""
        if not code:
            try:
                code = locale.getdefaultlocale()[0] or ""
            except Exception:                          # noqa: BLE001
                code = ""
        return language_from_locale(code)


    def language_from_locale(code: str) -> str:
        """把 'zh_TW' / 'zh-Hant-HK' / 'en_US' 这类标识归到三语之一。"""
        c = (code or "").replace("-", "_").lower()
        if not c:
            return DEFAULT_LANGUAGE
        if c.startswith("zh"):
            # 繁体区：台湾 / 香港 / 澳门 / 以及带 Hant 的写法
            if any(k in c for k in ("tw", "hk", "mo", "hant", "traditional")):
                return "zh_TW"
            return "zh_CN"
        return "en"


    # ---------------------------------------------------------------- 设置读写

    def _load_settings() -> dict:
        global _settings_cache
        if _settings_cache:
            return dict(_settings_cache)
        try:
            with open(SETTINGS_PATH, encoding="utf-8") as f:
                data = json.load(f)
            _settings_cache = data if isinstance(data, dict) else {}
        except Exception:                              # noqa: BLE001
            _settings_cache = {}
        return dict(_settings_cache)


    def _save_settings(data: dict) -> bool:
        global _settings_cache
        _settings_cache = dict(data)
        try:
            SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
                json.dump(_settings_cache, f, ensure_ascii=False, indent=2)
            return True
        except Exception:                              # noqa: BLE001
            return False


    def saved_language() -> str:
        """读设置里保存的语言；没保存过返回 AUTO（表示跟随系统）。"""
        code = str(_load_settings().get("language", AUTO) or AUTO)
        if code in (AUTO, "", None):
            return AUTO
        return code if code in dict(LANGUAGES) else AUTO


    def current_language() -> str:
        """当前语言：环境变量 PYSHOT_LANG > 保存的设置 > 系统语言。"""
        global _current
        if _current is None:
            env = os.environ.get("PYSHOT_LANG")
            if env and env in dict(LANGUAGES):
                _current = env
            else:
                code = saved_language()
                _current = system_language() if code == AUTO else code
        return _current


    def set_language(code: str, persist: bool = True) -> str:
        """切换语言。code 可以是三语之一，也可以是 AUTO（跟随系统）。

        返回真正生效的语言代码。设置 PYSHOT_LANG 时它优先（测试/强制指定用）。
        """
        global _current
        env = os.environ.get("PYSHOT_LANG")
        if env and env in dict(LANGUAGES):
            _current = env
            return _current
        if code == AUTO:
            _current = system_language()
        elif code in dict(LANGUAGES):
            _current = code
        else:
            _current = system_language()
        if persist:
            data = _load_settings()
            data["language"] = code
            _save_settings(data)
        return _current


    def reset_cache():
        """测试用：清掉内存里的语言与设置缓存。"""
        global _current, _settings_cache
        _current = None
        _settings_cache = {}


    def language_name(code: str) -> str:
        return dict(LANGUAGES).get(code, code)


    # ---------------------------------------------------------------- 翻译

    def tr(text: str, *args, **kwargs) -> str:
        """翻译一段文案；支持 {} 占位符。

        三种情况都能处理：
        - 传入的是**简体原文**（源码里的写法）→ 直接查表
        - 传入的是**已经翻译过的文本**（切换语言时对现有控件再翻一次）→ 反向查回原文
        - 查不到 → 原样返回（漏译不会崩，只是显示原文）
        """
        return _translate(current_language(), text, *args, **kwargs)


    def tr_in(lang: str, text: str, *args, **kwargs) -> str:
        """指定语言翻译（生成对照/测试用）。"""
        return _translate(lang, text, *args, **kwargs)


    def _translate(lang: str, text: str, *args, **kwargs) -> str:
        key = text
        if key not in TABLE:
            key = _REVERSE.get(text, text)          # 已翻译过的文本 → 找回原文
        entry = TABLE.get(key)
        out = key
        if entry is not None:
            if lang == "zh_TW":
                out = entry[0] or key
            elif lang == "en":
                out = entry[1] or key
        if args or kwargs:
            try:
                out = out.format(*args, **kwargs)
            except Exception:                          # noqa: BLE001
                pass
        return out


    def _build_reverse() -> dict:
        """译文 → 原文 的索引，便于"再翻译一次"（对现有控件做通用刷新）。"""
        rev = {}
        for key, (zh_tw, en) in TABLE.items():
            for value in (zh_tw, en):
                if value and value != key:
                    rev.setdefault(value, key)
        return rev


    _REVERSE = _build_reverse()


    def coverage() -> tuple:
        """返回 (总条数, 繁体条数, 英文条数)——用于自检与测试。"""
        total = len(TABLE)
        zh_tw = sum(1 for v in TABLE.values() if v[0])
        en = sum(1 for v in TABLE.values() if v[1])
        return total, zh_tw, en

    # ---------------------------------------------------------------- 通用设置项
    def get_setting(key: str, default=None):
        """读一个设置项（存在 ~/.pyshot/settings.json，与语言共用）。"""
        return _load_settings().get(key, default)


    def set_setting(key: str, value) -> bool:
        data = _load_settings()
        data[key] = value
        return _save_settings(data)


    # ========================================================================
    # 来自 bootstrap.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """依赖自举：启动时检查并自动安装缺失的第三方库（PySide6 / numpy）。

    设计要点
    ========
    - 只用标准库，保证在"什么都还没装"的环境里也能跑起来
    - 安装按顺序降级尝试：直接装 → --user → 国内镜像 → 镜像 + --user
    - Windows 上先尝试打开长路径支持（PySide6 的深层路径会因此安装失败）
    - 全部失败时给出可复制的手动命令，并弹系统对话框提示
    - 环境变量 PYSHOT_SKIP_DEPS=1 可跳过检查（测试用）
    - PYSHOT_PIP_MIRROR 可自定义镜像源
    """
    import os
    import subprocess
    import sys
    from pathlib import Path


    # 版本号：必须**模块顶层**导入。写成函数内的 `from version import ...` 会被
    # 单文件合并删掉，只剩一个空 try 块 → 构建出语法错误（这个坑踩过一次）。


    # (导入名, pip 安装名)
    # 只依赖 PySide6：拼接/图像统计都用纯 Python 实现了，不再需要 numpy。
    REQUIRED_PACKAGES = [
        ("PySide6", "PySide6"),
    ]

    # 国内镜像（默认仅在直连失败时使用）
    DEFAULT_MIRROR = "https://pypi.tuna.tsinghua.edu.cn/simple"


    def bundled_libs() -> Path | None:
        """程序旁边的内嵌依赖目录（便携版/内嵌版用，存在就不需要 pip）。"""
        here = Path(getattr(sys, "frozen", None) and sys.executable or __file__).resolve()
        libs = here.parent / "libs"
        return libs if libs.is_dir() else None


    def _use_bundled_libs() -> bool:
        """有内嵌依赖就优先用它（不联网、不装包）。"""
        libs = bundled_libs()
        if libs is None:
            return False
        p = str(libs)
        if p not in sys.path:
            sys.path.insert(0, p)
        return True


    def missing_packages(requirements=None) -> list:
        """返回缺失的 pip 包名列表。"""
        import importlib
        reqs = REQUIRED_PACKAGES if requirements is None else requirements
        missing = []
        for module_name, pip_name in reqs:
            try:
                importlib.import_module(module_name)
            except Exception:
                missing.append(pip_name)
        return missing


    def enable_windows_long_paths() -> bool:
        """Windows 未开启长路径支持时，pip 安装 PySide6 会因路径过长失败。"""
        if os.name != "nt":
            return False
        try:
            import winreg
            path = r"SYSTEM\CurrentControlSet\Control\FileSystem"
            key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path, 0,
                                 winreg.KEY_READ | winreg.KEY_SET_VALUE)
            try:
                value, _ = winreg.QueryValueEx(key, "LongPathsEnabled")
            except FileNotFoundError:
                value = 0
            if value == 1:
                return True
            winreg.SetValueEx(key, "LongPathsEnabled", 0, winreg.REG_DWORD, 1)
            print("[PyShot] 已开启 Windows 长路径支持（解决 PySide6 安装失败）")
            return True
        except Exception:
            # 没有管理员权限就算了，安装时若失败会给出提示
            return False


    def pip_install(packages, mirror: str | None = None, runner=None,
                    extra_args=()) -> bool:
        """按 直装 → --user → 镜像 → 镜像 + --user 的顺序尝试安装。

        runner(cmd) -> int 可注入，便于测试；默认真正执行 pip。
        """
        mirror = mirror if mirror is not None else os.environ.get(
            "PYSHOT_PIP_MIRROR", DEFAULT_MIRROR)
        base = [sys.executable, "-m", "pip", "install", *extra_args]
        attempts = [base + list(packages)]
        if "--user" not in extra_args:
            attempts.append(base + ["--user"] + list(packages))
        if mirror:
            attempts.append(base + ["-i", mirror] + list(packages))
            if "--user" not in extra_args:
                attempts.append(base + ["--user", "-i", mirror] + list(packages))
        run = runner or (lambda cmd: subprocess.call(cmd))
        for cmd in attempts:
            try:
                if run(cmd) == 0:
                    return True
            except Exception as ex:  # noqa: BLE001
                print(f"[PyShot] pip 执行失败：{ex}")
        return False


    def alert(title: str, message: str):
        """无 GUI 可用时的提示：Windows 弹系统对话框，其他平台打印。

        自动化测试/无人值守场景设 PYSHOT_NO_ALERT=1 就只打印 —— 否则这个模态框
        会把测试挂在那里等人点确定。
        """
        print(f"[PyShot] {title}：{message}")
        if os.name == "nt" and os.environ.get("PYSHOT_NO_ALERT") != "1":
            try:
                import ctypes
                ctypes.windll.user32.MessageBoxW(None, message, title, 0x40)
            except Exception:
                pass


    def ensure_deps(requirements=None, runner=None, quiet: bool = False) -> bool:
        """确保依赖就绪：优先用内嵌依赖；缺什么装什么。返回是否可用。"""
        if os.environ.get("PYSHOT_SKIP_DEPS") == "1":
            return True
        reqs = REQUIRED_PACKAGES if requirements is None else requirements
        # 1) 程序旁边有内嵌依赖目录 → 直接用，不联网不装包
        if _use_bundled_libs():
            if not missing_packages(reqs):
                if not quiet:
                    print("[PyShot] 依赖检查：使用程序旁边的内嵌依赖目录，无需安装。")
                return True
        missing = missing_packages(reqs)
        if not missing:
            # 一切正常时也报一句：以前这里完全静默，用户会以为"依赖检查没了"
            if not quiet:
                print(f"[PyShot] 依赖检查：{', '.join(p for _, p in reqs)} 已就绪。")
            return True
        if not quiet:
            print(f"[PyShot] 缺少依赖：{', '.join(missing)}，正在自动安装（首次约需 1-3 分钟）…")
        if os.name == "nt":
            enable_windows_long_paths()
        if not pip_install(missing, runner=runner):
            manual = f"{sys.executable} -m pip install " + " ".join(missing)
            alert("PyShot 依赖安装失败",
                  f"请手动执行以下命令后重新运行：\n\n{manual}")
            return False
        # 安装完再验证一次，确保真的能导入
        import importlib
        importlib.invalidate_caches()
        still = missing_packages(reqs)
        if still:
            alert("PyShot 依赖仍不可用", f"以下库导入失败：{', '.join(still)}")
            return False
        if not quiet:
            print("[PyShot] 依赖安装完成。")
        return True


    def deps_report() -> str:
        """依赖状态文本，供 --check-deps 使用。"""
        import importlib
        lines = [f"PyShot {APP_VERSION} 依赖检查："]
        bundled = bundled_libs()
        if bundled is not None:
            lines.append(f"  内嵌依赖目录: {bundled}")
        else:
            lines.append("  内嵌依赖目录: 无（将使用系统环境或自动安装）")
        for module_name, pip_name in REQUIRED_PACKAGES:
            try:
                mod = importlib.import_module(module_name)
                version = getattr(mod, "__version__", None)
                if version is None and module_name == "PySide6":
                    from PySide6 import __version__ as version  # type: ignore
                where = getattr(mod, "__file__", "")
                lines.append(f"  [OK]   {pip_name} {version or ''}  ({where})".rstrip())
            except Exception as ex:  # noqa: BLE001
                lines.append(f"  [缺失] {pip_name}（{type(ex).__name__}）")
        lines.append(f"  Python: {sys.version.split()[0]}  解释器: {sys.executable}")
        return "\n".join(lines)


    # 依赖自举：在任何 PySide6 导入之前完成检查与安装
    if not ensure_deps():
        raise SystemExit(1)


    # ========================================================================
    # 来自 version.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """版本号**只在这里定义**（其他地方一律 import，别再各写一份）。

    以前 `editor.py` 里写死 `APP_VERSION = "2.6"`，而 git 里程碑标签已经到
    `v2.15-qt` —— 两处各写一份，就必然会飘。现在统一从这里取，
    `build_single.py` 生成单文件时也读它写进文件头。

    命名：`MAJOR.MINOR[.PATCH]`，git 标签为 `v<版本>-qt`（`-qt` 表示根目录这套
    PySide6 实现，`tk_version/` 是独立的 Tkinter 版）。
    """
    APP_VERSION = "2.16.1"

    # 这版的一句话主题（写进单文件头与「关于」对话框，便于用户确认自己拿的是哪版）
    VERSION_TITLE = "工具条可滚动可收起"

    # 版本日期（本地日期，供日志/文档使用）
    VERSION_DATE = "2026-09-24"

    __version__ = APP_VERSION      # 兼容 `mod.__version__` 这种取法


    # ========================================================================
    # 来自 session.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """session.py —— 记住上次的截图（重启后还在，但**不需要你手动保存**）。

    设计
    ====
    - 关软件/崩溃前，把编辑器里的标签页（底图 + 标注 + 缩放 + 标题）悄悄写到
      `~/.pyshot/session/`；下次启动自动恢复，不弹"要不要保存"。
    - 它**不是**用户文件：不占用户目录、不生成"另存为"对话框；被恢复的标签仍然是
      未保存状态，用户想留就自己 Ctrl+S。
    - 只保留**最后一次**会话（每次写入先清空，避免越积越多）；限制标签数与总大小。

    存储结构::

        ~/.pyshot/session/session.json     # 会话描述（含每个标签的图形）
        ~/.pyshot/session/tab0.png         # 每个标签的底图（无损）

    为什么连图形一起存：只存拼好的图会把标注"焊死"，恢复后就没法再改了。
    """
    import json
    import os
    import shutil
    from pathlib import Path

    from PySide6.QtCore import QPointF, QRectF, QSize
    from PySide6.QtGui import QColor, QPixmap

    # 缓存目录；跑测试时用 PYSHOT_SESSION_DIR 指到临时目录，绝不碰用户真实数据
    SESSION_DIR = Path(os.environ.get("PYSHOT_SESSION_DIR") or
                       (Path.home() / ".pyshot" / "session"))
    SESSION_SETTINGS_PATH = Path.home() / ".pyshot" / "settings.json"
    MAX_TABS = 12                       # 最多恢复这么多标签
    MAX_BYTES = 120 * 1024 * 1024       # 底图总量上限（约 120MB）


    # ---------------------------------------------------------------- 设置开关

    def _load_session_settings() -> dict:
        try:
            with open(SESSION_SETTINGS_PATH, encoding="utf-8") as f:
                data = json.load(f)
            return data if isinstance(data, dict) else {}
        except Exception:                              # noqa: BLE001
            return {}


    def _save_session_settings(data: dict) -> bool:
        try:
            SESSION_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(SESSION_SETTINGS_PATH, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            return True
        except Exception:                              # noqa: BLE001
            return False


    def session_enabled() -> bool:
        """是否在启动时恢复上次的截图（默认开）。"""
        return bool(_load_session_settings().get("restore_session", True))


    def set_session_enabled(on: bool) -> bool:
        data = _load_session_settings()
        data["restore_session"] = bool(on)
        return _save_session_settings(data)


    # ---------------------------------------------------------------- 图形序列化

    def shape_to_dict(shape) -> dict:
        """把标注图形转成 JSON 可存的结构（按类名分派）。"""


        def pt(p):
            return [round(float(p.x()), 2), round(float(p.y()), 2)]

        base = {"t": type(shape).__name__, "color": shape.color.name(),
                "w": int(shape.width)}
        # 旋转角（新字段；旧缓存里没有就当作 0，不影响读旧数据）
        if getattr(shape, "rotation", 0.0):
            base["rot"] = round(float(shape.rotation), 2)
        if isinstance(shape, WatermarkShape):
            base.pop("color", None)
            base.pop("w", None)
            base["settings"] = dict(shape.settings)
            base["size"] = [shape.image_size.width(), shape.image_size.height()]
            if shape.offset is not None:
                base["offset"] = pt(shape.offset)
            return base
        if isinstance(shape, (EllipseShape, RectShape)):
            base["rect"] = [shape.rect.x(), shape.rect.y(),
                            shape.rect.width(), shape.rect.height()]
            base["ellipse"] = isinstance(shape, EllipseShape)
            base["fill"] = bool(getattr(shape, "fill", False))
            return base
        if isinstance(shape, HighlightShape):
            base["rect"] = [shape.rect.x(), shape.rect.y(),
                            shape.rect.width(), shape.rect.height()]
            return base
        if isinstance(shape, MosaicShape):
            base["rect"] = [shape.rect.x(), shape.rect.y(),
                            shape.rect.width(), shape.rect.height()]
            return base
        if isinstance(shape, ArrowShape):
            base["p1"], base["p2"] = pt(shape.p1), pt(shape.p2)
            return base
        if isinstance(shape, LineShape):
            base["p1"], base["p2"] = pt(shape.p1), pt(shape.p2)
            return base
        if isinstance(shape, PenShape):
            base["points"] = [pt(p) for p in shape.points]
            return base
        if isinstance(shape, TextShape):
            base["pos"] = pt(shape.pos)
            base["text"] = shape.text
            base["font_size"] = int(shape.font_size)
            if getattr(shape, "family", ""):
                base["font"] = shape.family
            base["bold"] = bool(getattr(shape, "bold", True))
            return base
        if isinstance(shape, StepShape):
            base["center"] = pt(shape.center)
            base["number"] = int(shape.number)
            base["diameter"] = float(shape.diameter)
            return base
        return {}                                      # 认不出来就不存（跳过）


    def shape_from_dict(d: dict):
        """反序列化：认不出来返回 None。"""

        t = d.get("t")
        color = QColor(d.get("color", "#e53935"))
        w = int(d.get("w", 3))

        def pt(seq):
            return QPointF(float(seq[0]), float(seq[1]))

        try:
            if t == "WatermarkShape":
                size = d.get("size") or [640, 400]
                off = pt(d["offset"]) if d.get("offset") else None
                return WatermarkShape(d.get("settings", {}), QSize(int(size[0]),
                                                                  int(size[1])),
                                      off)
            if t == "EllipseShape":
                r = d["rect"]
                return _with_rotation(EllipseShape(color, w,
                                                   QRectF(*[float(v) for v in r]),
                                                   bool(d.get("fill", False))), d)
            if t == "RectShape":
                r = d["rect"]
                return _with_rotation(RectShape(color, w,
                                                QRectF(*[float(v) for v in r]),
                                                bool(d.get("fill", False))), d)
            if t == "HighlightShape":
                return _with_rotation(HighlightShape(color, w,
                                                     QRectF(*[float(v) for v in d["rect"]])), d)
            if t == "MosaicShape":
                return _with_rotation(MosaicShape(color, w,
                                                  QRectF(*[float(v) for v in d["rect"]])), d)
            if t == "ArrowShape":
                return _with_rotation(ArrowShape(color, w, pt(d["p1"]), pt(d["p2"])), d)
            if t == "LineShape":
                return _with_rotation(LineShape(color, w, pt(d["p1"]), pt(d["p2"])), d)
            if t == "PenShape":
                return _with_rotation(PenShape(color, w,
                                               [pt(p) for p in d.get("points", [])]), d)
            if t == "TextShape":
                sh = TextShape(color, w, pt(d["pos"]), d.get("text", ""),
                               int(d.get("font_size", 20)), d.get("font", ""))
                sh.bold = bool(d.get("bold", True))
                return _with_rotation(sh, d)
            if t == "StepShape":
                return _with_rotation(StepShape(color, w, pt(d["center"]),
                                                int(d.get("number", 1)), 0,
                                                float(d.get("diameter", 36))), d)
        except Exception:                              # noqa: BLE001
            return None
        return None


    def _with_rotation(shape, d: dict):
        """把存下来的旋转角装回去（旧缓存没有 rot 字段 = 0）。"""
        if shape is not None and d.get("rot"):
            shape.rotation = float(d["rot"]) % 360.0
        return shape


    # ---------------------------------------------------------------- 保存 / 读取

    def _clear_dir():
        try:
            if SESSION_DIR.exists():
                shutil.rmtree(SESSION_DIR, ignore_errors=True)
        except Exception:                              # noqa: BLE001
            pass


    def clear_session():
        """清掉上次的会话（用户关掉所有标签或主动清除时调用）。"""
        _clear_dir()


    def has_session() -> bool:
        return (SESSION_DIR / "session.json").exists()


    def save_session(tabs: list) -> bool:
        """保存会话。tabs: [{title, zoom, pixmap, shapes:[Shape]}, ...]"""
        tabs = [t for t in tabs if t.get("pixmap") is not None][:MAX_TABS]
        if not tabs:
            clear_session()
            return True
        try:
            SESSION_DIR.mkdir(parents=True, exist_ok=True)
        except Exception:                              # noqa: BLE001
            return False

        # 先写到临时目录再整体替换，避免写到一半崩掉留下坏会话
        tmp = SESSION_DIR.with_name("session.tmp")
        shutil.rmtree(tmp, ignore_errors=True)
        try:
            tmp.mkdir(parents=True, exist_ok=True)
            total = 0
            items = []
            for i, tab in enumerate(tabs):
                pix = tab["pixmap"]
                name = f"tab{i}.png"
                path = tmp / name
                if not pix.save(str(path), "PNG"):
                    continue
                total += path.stat().st_size
                if total > MAX_BYTES:
                    path.unlink(missing_ok=True)
                    break
                shapes = []
                for sh in tab.get("shapes", []):
                    d = shape_to_dict(sh)
                    if d:
                        shapes.append(d)
                items.append({"title": tab.get("title") or f"截图 {i + 1}",
                              "zoom": float(tab.get("zoom", 1.0)),
                              "dpr": float(pix.devicePixelRatio() or 1.0),
                              "file": name,
                              "shapes": shapes})
            meta = {"version": 1, "tabs": items}
            with open(tmp / "session.json", "w", encoding="utf-8") as f:
                json.dump(meta, f, ensure_ascii=False)
            # 原子替换
            _clear_dir()
            tmp.rename(SESSION_DIR)
            return True
        except Exception:                              # noqa: BLE001
            shutil.rmtree(tmp, ignore_errors=True)
            return False


    def load_session() -> list:
        """读回上次的会话；返回 [{title, zoom, pixmap, shapes}, ...]。"""
        meta_path = SESSION_DIR / "session.json"
        if not meta_path.exists():
            return []
        try:
            with open(meta_path, encoding="utf-8") as f:
                meta = json.load(f)
        except Exception:                              # noqa: BLE001
            return []
        out = []
        for item in meta.get("tabs", [])[:MAX_TABS]:
            path = SESSION_DIR / str(item.get("file", ""))
            if not path.exists():
                continue
            pix = QPixmap(str(path))
            if pix.isNull():
                continue
            dpr = float(item.get("dpr") or 1.0)
            pix.setDevicePixelRatio(dpr)
            shapes = []
            for d in item.get("shapes", []):
                sh = shape_from_dict(d)
                if sh is not None:
                    shapes.append(sh)
            out.append({"title": item.get("title") or "截图",
                        "zoom": float(item.get("zoom", 1.0)),
                        "pixmap": pix, "shapes": shapes})
        return out


    # ========================================================================
    # 来自 diag.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """diag.py —— 全链路诊断日志（默认关闭，排查问题时才开）。

    开启方式（任选其一，等价）::

        set PYSHOT_DEBUG=1
        set PYSHOT_CAPTURE_DEBUG=1     # 旧名字，兼容

    输出到**控制台**和 ``~/.pyshot/debug.log``（超过 512KB 自动截断保留后半段）。
    每行都带**墙钟时间 + 毫秒 + 相对启动的毫秒**，还有每段操作的**耗时**，
    所以"双击之后到底慢在哪一步"能直接从日志看出来。

    用法::


        log("截图", "触发")
        with timed("抓屏"):            # 退出时自动记一行"耗时 xx ms"
            frame = grab()
        exc("打开编辑器失败")
    """
    import os
    import time
    import traceback
    from pathlib import Path

    LOG_PATH = Path(os.environ.get("PYSHOT_DEBUG_LOG")
                    or (Path.home() / ".pyshot" / "debug.log"))
    DIAG_MAX_BYTES = 512 * 1024
    _T0 = time.perf_counter()


    def enabled() -> bool:
        """是否开启诊断日志。"""
        return bool(os.environ.get("PYSHOT_DEBUG")
                    or os.environ.get("PYSHOT_CAPTURE_DEBUG"))


    def _stamp() -> str:
        now = time.time()
        return (f"{time.strftime('%H:%M:%S', time.localtime(now))}"
                f".{int(now * 1000) % 1000:03d}"
                f" (+{(time.perf_counter() - _T0) * 1000:8.1f}ms)")


    def log(tag: str, *parts):
        """记一行诊断日志（未开启时零开销返回）。"""
        if not enabled():
            return
        line = f"{_stamp()} {tag}: " + " ".join(str(p) for p in parts)
        try:
            print(line, flush=True)
        except Exception:                              # noqa: BLE001
            pass
        try:
            LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\n")
            # 轮转：只留最后一半，避免日志无限长大
            if LOG_PATH.stat().st_size > DIAG_MAX_BYTES:
                data = LOG_PATH.read_text(encoding="utf-8", errors="replace")
                LOG_PATH.write_text("……（日志过长，已截断前段）……\n"
                                    + data[-(DIAG_MAX_BYTES // 2):], encoding="utf-8")
        except Exception:                              # noqa: BLE001
            pass


    class timed:
        """上下文管理器：记下这段操作的耗时。

        用法::

            with timed("抓屏", "屏0"):   # 进入/退出各记一行，退出带耗时
                ...
        """

        def __init__(self, tag: str, *extra):
            self.tag = tag
            self.extra = extra
            self.t0 = 0.0

        def __enter__(self):
            self.t0 = time.perf_counter()
            if enabled():
                log(f"{self.tag}·开始", *self.extra)
            return self

        def __exit__(self, *exc_info):
            if enabled():
                cost = (time.perf_counter() - self.t0) * 1000
                tail = ("异常=" + repr(exc_info[1])) if exc_info and exc_info[0] \
                    else "OK"
                log(f"{self.tag}·结束", f"耗时 {cost:.1f} ms", tail, *self.extra)
            return False


    def exc(tag: str, err=None):
        """记一条异常（带完整堆栈）。"""
        if not enabled():
            return
        if err is None:
            log(tag, "异常:\n" + traceback.format_exc())
        else:
            log(tag, f"异常 {type(err).__name__}: {err}")


    def dump_env(extra: str = ""):
        """开一次环境快照：录屏/多屏/缩放问题经常就差这些信息。"""
        if not enabled():
            return
        try:
            import PySide6
            qt = PySide6.__version__
        except Exception:                              # noqa: BLE001
            qt = "?"
        log("环境", f"pid={os.getpid()} python={os.sys.version.split()[0]} "
                    f"Qt={qt} platform={os.environ.get('QT_QPA_PLATFORM') or '默认'} "
                    f"cwd={os.getcwd()} {extra}")
        try:
            from PySide6.QtGui import QGuiApplication
            for i, scr in enumerate(QGuiApplication.screens()):
                g = scr.geometry()
                log("环境·屏幕", f"#{i} {scr.name()} geo=({g.x()},{g.y()},"
                                 f"{g.width()}x{g.height()}) dpr={scr.devicePixelRatio()}"
                                 f" primary={scr is QGuiApplication.primaryScreen()}")
        except Exception as e:                         # noqa: BLE001
            log("环境·屏幕", f"枚举失败: {e}")


    def install_excepthook():
        """把未捕获异常也写进日志（托盘常驻进程崩了只有它留得下证据）。"""
        if not enabled():
            return
        import sys

        def _hook(etype, value, tb):
            try:
                log("未捕获异常", "".join(traceback.format_exception(etype, value, tb)))
            except Exception:                          # noqa: BLE001
                pass
            sys.__excepthook__(etype, value, tb)

        sys.excepthook = _hook


    # ========================================================================
    # 来自 watermark.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """watermark.py —— 水印（对照 FastStone Capture 的「特效 → 水印」重做）。

    FSCapture 的水印对话框是：**文字水印**和**图片水印**各自独立开关（可以同时
    启用，于是得到「公司 logo + 文字」的组合）、分别设字体/图片与透明度，再用
    九宫格选位置（或勾选平铺），可旋转、可设边距，右侧实时预览，最后「应用」；
    还有一个「设为默认」让之后每次截图自动加。

    本模块按这个结构组织：
    - 设置项：use_text / use_image 两个开关 + 各自的透明度
    - 位置：0..8 九宫格 + tile 平铺
    - 绘制：draw_watermark() 统一负责，编辑器里的 WatermarkShape 和对话框预览共用
    """
    import json
    import os
    from pathlib import Path

    from PySide6.QtCore import QPointF, QRectF, QSize, QSizeF, Qt
    from PySide6.QtGui import (QColor, QFont, QFontMetricsF, QIcon, QPainter,
                               QPen, QPixmap)
    from PySide6.QtWidgets import (QCheckBox, QColorDialog, QComboBox, QDialog,
                                   QDialogButtonBox, QFileDialog, QFontDialog,
                                   QGridLayout, QGroupBox, QHBoxLayout, QLabel,
                                   QLineEdit, QPlainTextEdit, QPushButton,
                                   QSlider, QSpinBox, QToolButton, QVBoxLayout,
                                   QWidget)


    DEFAULT_SETTINGS = {
        # ---- 文字水印 ----
        "use_text": True,
        "text": "仅供参考",
        "font_family": "Microsoft YaHei",
        "font_size": 28,             # 图像像素
        "bold": True,
        "italic": False,
        "color": "#ffffff",
        "text_alpha": 90,            # 0-255
        "outline": True,             # 描边，深浅背景都看得清
        # ---- 图片水印 ----
        "use_image": False,
        "image_path": "",
        "image_scale": 0.20,         # 占图像宽度的比例
        "image_alpha": 140,          # 0-255
        # ---- 位置与排布 ----
        "position": 8,               # 0..8 九宫格（0=左上 4=居中 8=右下）
        "tile": False,               # 平铺整张图
        "spacing": 60,               # 平铺间距（像素）
        "rotation": 0,               # 旋转角度
        "margin": 24,                # 距图像边缘（像素）
        # ---- 其它 ----
        "auto": False,               # 设为默认后，新截图自动套用
    }

    POSITION_NAMES = ["左上", "上中", "右上", "左中", "居中", "右中",
                      "左下", "下中", "右下"]

    CONFIG_PATH = Path.home() / ".pyshot" / "watermark.json"
    _cache = {}

    # 文字与图片同时启用时的上下间距（图像像素）
    GAP = 8.0


    # ---------------------------------------------------------------- 设置读写

    def normalize(settings: dict | None) -> dict:
        """补全/校验字段，并把旧版本配置迁移过来。

        旧版（v1）用 kind="text|image" + alpha + position=9 表示平铺，
        这里统一迁移到 use_text/use_image + 各自 alpha + tile。
        """
        out = dict(DEFAULT_SETTINGS)
        if not settings:
            return out
        s = dict(settings)

        if "kind" in s:                     # v1 → v2
            kind = s.pop("kind")
            out["use_text"] = (kind == "text")
            out["use_image"] = (kind == "image")
        if "alpha" in s:
            a = s.pop("alpha")
            out["text_alpha"] = a
            out["image_alpha"] = a
        if "shadow" in s:                   # 旧的 shadow ≈ 新的 outline
            out["outline"] = bool(s.pop("shadow"))
        if s.get("position") == 9:          # 旧的平铺写法
            out["tile"] = True
            s["position"] = 8

        for k, v in s.items():
            if k in DEFAULT_SETTINGS:
                out[k] = v

        # 类型与范围夹取（配置文件可能被手改坏）
        for key in ("use_text", "use_image", "bold", "italic", "outline", "tile",
                    "auto"):
            out[key] = bool(out[key])
        out["position"] = max(0, min(8, int(out["position"])))
        out["font_size"] = max(6, min(400, int(out["font_size"])))
        for key in ("text_alpha", "image_alpha"):
            out[key] = max(0, min(255, int(out[key])))
        out["image_scale"] = max(0.01, min(3.0, float(out["image_scale"])))
        out["rotation"] = max(-180, min(180, int(out["rotation"])))
        out["margin"] = max(0, min(2000, int(out["margin"])))
        out["spacing"] = max(0, min(2000, int(out["spacing"])))
        if not isinstance(out["text"], str):
            out["text"] = str(out["text"])
        return out


    def load_default() -> dict:
        """读取默认水印设置（缺字段自动补齐）。"""
        global _cache
        if _cache:
            return dict(_cache)
        try:
            with open(CONFIG_PATH, encoding="utf-8") as f:
                _cache = normalize(json.load(f))
        except Exception:                        # noqa: BLE001
            _cache = dict(DEFAULT_SETTINGS)
        return dict(_cache)


    def save_default(settings: dict) -> bool:
        """保存为默认（之后新截图自动套用）。返回是否写盘成功。"""
        global _cache
        _cache = normalize(settings)
        try:
            CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(_cache, f, ensure_ascii=False, indent=2)
            return True
        except Exception:                        # noqa: BLE001
            return False


    def clear_cache():
        """测试用：清掉内存缓存与图片缓存。"""
        global _cache
        _cache = {}
        if hasattr(_image_cache, "_pix"):
            _image_cache._pix.clear()


    def describe(settings: dict) -> str:
        """一句话描述当前水印（托盘/状态栏提示用）。"""
        s = normalize(settings)
        parts = []
        if s["use_text"]:
            parts.append(f"文字「{s['text'].splitlines()[0][:12] if s['text'] else ''}」")
        if s["use_image"]:
            parts.append(f"图片 {os.path.basename(s['image_path']) or '（未选择）'}")
        if not parts:
            return "未启用"
        where = "平铺" if s["tile"] else POSITION_NAMES[s["position"]]
        return " + ".join(parts) + f" · {where}"


    # ---------------------------------------------------------------- 字体/图片

    def make_font(settings: dict) -> QFont:
        font = QFont(settings.get("font_family") or "Microsoft YaHei")
        font.setPixelSize(max(6, int(settings.get("font_size", 28))))
        font.setBold(bool(settings.get("bold")))
        font.setItalic(bool(settings.get("italic")))
        return font


    def _image_cache(settings: dict):
        if not hasattr(_image_cache, "_pix"):
            _image_cache._pix = {}
        key = settings.get("image_path", "")
        if key not in _image_cache._pix:
            pix = QPixmap(key) if key and os.path.exists(key) else QPixmap()
            _image_cache._pix[key] = pix
        return _image_cache._pix[key]


    def load_image(settings: dict) -> QPixmap | None:
        pix = _image_cache(settings)
        return pix if pix is not None and not pix.isNull() else None


    # ---------------------------------------------------------------- 尺寸与位置

    def text_size(settings: dict) -> QSizeF:
        metrics = QFontMetricsF(make_font(settings))
        lines = (settings.get("text") or "").split("\n") or [""]
        width = max((metrics.horizontalAdvance(line) for line in lines), default=0.0)
        height = metrics.lineSpacing() * len(lines)
        return QSizeF(max(0.0, width), max(0.0, height))


    def image_size(settings: dict, image_size: QSize) -> QSizeF:
        pix = load_image(settings)
        if pix is None:
            return QSizeF(0, 0)
        scale = max(0.01, float(settings.get("image_scale", 0.2)))
        w = image_size.width() * scale
        h = w * pix.height() / max(1, pix.width())
        return QSizeF(w, h)


    def watermark_size(settings: dict, canvas_size: QSize) -> QSizeF:
        """整组水印的包围尺寸（文字与图片同时启用时上下排列）。

        注意：一个都不启用时返回 (0,0)，调用方应据此跳过绘制。
        参数名刻意不叫 image_size —— 那会遮蔽同名函数。
        """
        s = normalize(settings)
        tw = text_size(s) if s["use_text"] else QSizeF(0, 0)
        iw = image_size(s, canvas_size) if s["use_image"] else QSizeF(0, 0)
        if tw.height() <= 0 and iw.height() <= 0:
            return QSizeF(0, 0)
        width = max(tw.width(), iw.width())
        height = tw.height() + iw.height()
        if tw.height() > 0 and iw.height() > 0:
            height += GAP
        return QSizeF(width, height)


    def placements(settings: dict, canvas_size: QSize, size: QSizeF) -> list:
        """返回每个水印组的左上角坐标（平铺时多组）。"""
        s = normalize(settings)
        iw, ih = float(canvas_size.width()), float(canvas_size.height())
        margin = float(s["margin"])
        if s["tile"]:
            spacing = float(s["spacing"])
            step_x = size.width() + spacing
            step_y = size.height() + spacing
            if step_x <= 1 or step_y <= 1:
                return []
            out = []
            y = margin
            while y < ih:
                x = margin
                while x < iw:
                    out.append(QPointF(x, y))
                    x += step_x
                y += step_y
            return out
        col, row = s["position"] % 3, s["position"] // 3
        fx, fy = col / 2.0, row / 2.0
        avail_w = max(0.0, iw - margin * 2 - size.width())
        avail_h = max(0.0, ih - margin * 2 - size.height())
        return [QPointF(margin + fx * avail_w, margin + fy * avail_h)]


    # ---------------------------------------------------------------- 绘制

    def _wm_draw_text(painter: QPainter, settings: dict, box: QRectF):
        color = QColor(settings.get("color", "#ffffff"))
        color.setAlpha(int(settings.get("text_alpha", 90)))
        if color.alpha() <= 0:
            return
        font = make_font(settings)
        painter.setFont(font)
        metrics = QFontMetricsF(font)
        line_h = metrics.lineSpacing()
        lines = (settings.get("text") or "").split("\n")
        for i, line in enumerate(lines):
            y = box.top() + metrics.ascent() + i * line_h
            if settings.get("outline"):
                shadow = QColor(0, 0, 0, min(210, color.alpha() + 50))
                painter.setPen(shadow)
                for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    painter.drawText(QPointF(box.left() + dx, y + dy), line)
            painter.setPen(color)
            painter.drawText(QPointF(box.left(), y), line)


    def _wm_draw_image(painter: QPainter, settings: dict, box: QRectF):
        pix = load_image(settings)
        if pix is None:
            return
        alpha = int(settings.get("image_alpha", 140))
        if alpha <= 0:
            return
        painter.save()
        painter.setOpacity(alpha / 255.0)
        painter.drawPixmap(box, pix, QRectF(pix.rect()))
        painter.restore()


    def draw_watermark(painter: QPainter, settings: dict, canvas_size: QSize,
                       offset: QPointF | None = None):
        """把水印画到 painter 上（坐标系 = 图像像素）。

        图片水印在下、文字水印在上（同时启用时上下排列成一组）。
        """
        s = normalize(settings)
        size = watermark_size(s, canvas_size)
        if size.width() <= 0 or size.height() <= 0:
            return
        tw = text_size(s) if s["use_text"] else QSizeF(0, 0)
        iw = image_size(s, canvas_size) if s["use_image"] else QSizeF(0, 0)
        rotation = float(s["rotation"])
        off = offset or QPointF(0, 0)

        painter.save()
        for pt in placements(s, canvas_size, size):
            painter.save()
            cx = pt.x() + off.x() + size.width() / 2
            cy = pt.y() + off.y() + size.height() / 2
            painter.translate(cx, cy)
            if rotation:
                painter.rotate(rotation)
            top = -size.height() / 2
            if iw.height() > 0:
                _wm_draw_image(painter, s, QRectF(-iw.width() / 2, top,
                                                iw.width(), iw.height()))
                top += iw.height() + (GAP if tw.height() > 0 else 0)
            if tw.height() > 0:
                _wm_draw_text(painter, s,
                              QRectF(-tw.width() / 2, top, tw.width(), tw.height()))
            painter.restore()
        painter.restore()


    # ---------------------------------------------------------------- 对话框

    def _pct(alpha: int) -> int:
        return int(round(alpha * 100 / 255))


    def _alpha(pct: int) -> int:
        return int(round(pct * 255 / 100))


    class WatermarkDialog(QDialog):
        """水印对话框（对照 FSCapture：文字/图片各自开关 + 九宫格位置 + 实时预览）。

        确定后由调用方取 settings()；保存为默认则之后新截图自动套用。
        """

        PREVIEW_W, PREVIEW_H = 460, 170

        def __init__(self, parent=None, settings: dict | None = None,
                     image_size: QSize | None = None):
            super().__init__(parent)
            self.setWindowTitle(tr("水印"))
            self.setMinimumWidth(560)
            self._s = normalize(settings or load_default())
            self._image_size = image_size if (image_size and image_size.isValid()) \
                else QSize(640, 400)
            self._color = QColor(self._s["color"])
            self._pos_buttons = []

            root = QVBoxLayout(self)
            root.setSpacing(8)

            root.addWidget(self._build_text_group())
            root.addWidget(self._build_image_group())
            root.addWidget(self._build_layout_group())
            root.addWidget(self._build_preview_group())

            # 注意 QDialogButtonBox 一定要给 parent（self）：
            # Qt 只在 box 的父对象是 QDialog 时，才把它的 accepted()/rejected()
            # 自动接到对话框的 accept()/reject()。没有 parent 时"取消"点了没反应
            # （应用能用只是因为下面显式连了）—— 踩过这个坑，所以这里 parent 和
            # 显式连接都给上，不依赖隐式行为。
            buttons = QDialogButtonBox(self)
            self.btn_apply = buttons.addButton(tr("应用"), QDialogButtonBox.AcceptRole)
            self.btn_default = buttons.addButton(tr("应用并设为默认"),
                                                 QDialogButtonBox.AcceptRole)
            self.btn_cancel = buttons.addButton(tr("取消"),
                                                QDialogButtonBox.RejectRole)
            self.btn_cancel.clicked.connect(self.reject)
            buttons.rejected.connect(self.reject)
            self.btn_apply.clicked.connect(self._accept_apply)
            self.btn_default.clicked.connect(self._accept_default)
            root.addWidget(buttons)

            self._sync_enabled()
            self._refresh_preview()

        # ---------- 文字水印 ----------
        def _build_text_group(self) -> QGroupBox:
            box = QGroupBox(tr("文字水印"))
            box.setCheckable(True)
            box.setChecked(self._s["use_text"])
            self.grp_text = box
            box.toggled.connect(self._on_use_text)
            lay = QVBoxLayout(box)

            self.text = QPlainTextEdit(self._s["text"])
            self.text.setFixedHeight(54)
            self.text.setPlaceholderText(tr("要加在水印上的文字（可多行）"))
            self.text.textChanged.connect(self._refresh_preview)
            lay.addWidget(self.text)

            row = QHBoxLayout()
            self.font_btn = QPushButton()
            self.font_btn.setMinimumWidth(220)
            self.font_btn.clicked.connect(self._pick_font)
            row.addWidget(QLabel(tr("字体")))
            row.addWidget(self.font_btn, 1)

            self.color_btn = QPushButton()
            self.color_btn.setFixedSize(52, 26)
            self.color_btn.setToolTip(tr("文字颜色"))
            self.color_btn.clicked.connect(self._pick_color)
            row.addWidget(QLabel(tr("颜色")))
            row.addWidget(self.color_btn)
            row.addStretch(1)
            lay.addLayout(row)

            row2 = QHBoxLayout()
            row2.addWidget(QLabel(tr("不透明度")))
            self.text_alpha = QSlider(Qt.Horizontal)
            self.text_alpha.setRange(0, 100)
            self.text_alpha.setValue(_pct(self._s["text_alpha"]))
            self.text_alpha.valueChanged.connect(self._refresh_preview)
            self.text_alpha.valueChanged.connect(
                lambda v: self.text_alpha_label.setText(f"{v}%"))
            row2.addWidget(self.text_alpha, 1)
            self.text_alpha_label = QLabel(f"{_pct(self._s['text_alpha'])}%")
            self.text_alpha_label.setMinimumWidth(42)
            row2.addWidget(self.text_alpha_label)

            self.outline = QCheckBox(tr("描边（深浅背景都清晰）"))
            self.outline.setChecked(self._s["outline"])
            self.outline.toggled.connect(self._refresh_preview)
            row2.addWidget(self.outline)
            lay.addLayout(row2)
            self._update_font_button()
            self._update_color_button()
            return box

        def _on_use_text(self, on):
            self._s["use_text"] = on
            self._sync_enabled()
            self._refresh_preview()

        def _pick_font(self):
            font, ok = QFontDialog.getFont(make_font(self._s), self, "选择水印字体")
            if not ok:
                return
            self._s["font_family"] = font.family()
            self._s["font_size"] = max(6, font.pixelSize()
                                       if font.pixelSize() > 0 else 28)
            self._s["bold"] = font.bold()
            self._s["italic"] = font.italic()
            self._update_font_button()
            self._refresh_preview()

        def _update_font_button(self):
            styles = []
            if self._s["bold"]:
                styles.append("粗体")
            if self._s["italic"]:
                styles.append("斜体")
            tail = (" " + " ".join(styles)) if styles else ""
            self.font_btn.setText(f"{self._s['font_family']}  "
                                  f"{self._s['font_size']}px{tail}")

        def _pick_color(self):
            c = QColorDialog.getColor(self._color, self, "水印颜色")
            if c.isValid():
                self._color = c
                self._s["color"] = c.name()
                self._update_color_button()
                self._refresh_preview()

        def _update_color_button(self):
            self.color_btn.setStyleSheet(
                f"background:{self._color.name()};"
                "border:1px solid #3a3e47;border-radius:4px;")

        # ---------- 图片水印 ----------
        def _build_image_group(self) -> QGroupBox:
            box = QGroupBox(tr("图片水印"))
            box.setCheckable(True)
            box.setChecked(self._s["use_image"])
            self.grp_image = box
            box.toggled.connect(self._on_use_image)
            lay = QVBoxLayout(box)

            row = QHBoxLayout()
            self.image_path = QLineEdit(self._s["image_path"])
            self.image_path.setReadOnly(True)
            self.image_path.setPlaceholderText(tr("选择一张图片（建议用透明底的 PNG）"))
            row.addWidget(self.image_path, 1)
            browse = QPushButton(tr("浏览…"))
            browse.clicked.connect(self._pick_image)
            row.addWidget(browse)
            clear = QPushButton(tr("清除"))
            clear.clicked.connect(self._clear_image)
            row.addWidget(clear)
            lay.addLayout(row)

            row2 = QHBoxLayout()
            row2.addWidget(QLabel(tr("大小")))
            self.image_scale = QSpinBox()
            self.image_scale.setRange(1, 300)
            self.image_scale.setSuffix(tr(" % 图宽"))
            self.image_scale.setValue(int(round(self._s["image_scale"] * 100)))
            self.image_scale.valueChanged.connect(self._on_scale)
            row2.addWidget(self.image_scale)

            row2.addWidget(QLabel(tr("不透明度")))
            self.image_alpha = QSlider(Qt.Horizontal)
            self.image_alpha.setRange(0, 100)
            self.image_alpha.setValue(_pct(self._s["image_alpha"]))
            self.image_alpha.valueChanged.connect(self._refresh_preview)
            self.image_alpha.valueChanged.connect(
                lambda v: self.image_alpha_label.setText(f"{v}%"))
            row2.addWidget(self.image_alpha, 1)
            self.image_alpha_label = QLabel(f"{_pct(self._s['image_alpha'])}%")
            self.image_alpha_label.setMinimumWidth(42)
            row2.addWidget(self.image_alpha_label)

            self.image_thumb = QLabel()
            self.image_thumb.setFixedSize(72, 40)
            self.image_thumb.setAlignment(Qt.AlignCenter)
            self.image_thumb.setStyleSheet(
                "border:1px solid #3a3e47;border-radius:4px;color:#9aa0ab;")
            row2.addWidget(self.image_thumb)
            lay.addLayout(row2)
            self._update_image_thumb()
            return box

        def _on_use_image(self, on):
            self._s["use_image"] = on
            self._sync_enabled()
            self._refresh_preview()

        def _on_scale(self, v):
            self._s["image_scale"] = max(0.01, v / 100.0)
            self._refresh_preview()

        def _pick_image(self):
            path, _ = QFileDialog.getOpenFileName(
                self, tr("选择水印图片"), "",
                tr("图片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp);;所有文件 (*.*)"))
            if not path:
                return
            self._s["image_path"] = path
            self.image_path.setText(path)
            if not self.grp_image.isChecked():
                self.grp_image.setChecked(True)      # 选了图就顺手打开开关
            _image_cache._pix.pop(path, None) if hasattr(_image_cache, "_pix") else None
            self._update_image_thumb()
            self._sync_enabled()
            self._refresh_preview()

        def _clear_image(self):
            self._s["image_path"] = ""
            self.image_path.setText("")
            self._update_image_thumb()
            self._refresh_preview()

        def _update_image_thumb(self):
            pix = load_image(self._s)
            if pix is None:
                self.image_thumb.setPixmap(QPixmap())
                self.image_thumb.setText(tr("（无图片）"))
                return
            self.image_thumb.setText("")
            self.image_thumb.setPixmap(
                pix.scaled(self.image_thumb.size(), Qt.KeepAspectRatio,
                           Qt.SmoothTransformation))

        # ---------- 位置与排布 ----------
        def _build_layout_group(self) -> QGroupBox:
            box = QGroupBox(tr("位置与排布"))
            lay = QHBoxLayout(box)

            grid = QGridLayout()
            grid.setSpacing(3)
            for i in range(9):
                b = QToolButton()
                b.setCheckable(True)
                b.setAutoExclusive(True)
                b.setFixedSize(30, 26)
                b.setToolTip(tr(POSITION_NAMES[i]))
                b.clicked.connect(lambda checked=False, k=i: self._set_position(k))
                grid.addWidget(b, i // 3, i % 3)
                self._pos_buttons.append(b)
            self._pos_buttons[self._s["position"]].setChecked(True)
            lay.addLayout(grid)

            right = QVBoxLayout()
            self.tile = QCheckBox(tr("平铺整张图"))
            self.tile.setChecked(self._s["tile"])
            self.tile.toggled.connect(self._on_tile)
            right.addWidget(self.tile)

            row = QHBoxLayout()
            row.addWidget(QLabel(tr("间距")))
            self.spacing = QSpinBox()
            self.spacing.setRange(0, 2000)
            self.spacing.setSuffix(" px")
            self.spacing.setValue(self._s["spacing"])
            self.spacing.valueChanged.connect(self._on_spacing)
            row.addWidget(self.spacing)
            row.addStretch(1)
            right.addLayout(row)

            row2 = QHBoxLayout()
            row2.addWidget(QLabel(tr("旋转")))
            self.rotation = QSpinBox()
            self.rotation.setRange(-180, 180)
            self.rotation.setSuffix(" °")
            self.rotation.setValue(self._s["rotation"])
            self.rotation.valueChanged.connect(self._on_rotation)
            row2.addWidget(self.rotation)

            row2.addWidget(QLabel(tr("边距")))
            self.margin = QSpinBox()
            self.margin.setRange(0, 2000)
            self.margin.setSuffix(" px")
            self.margin.setValue(self._s["margin"])
            self.margin.valueChanged.connect(self._on_margin)
            row2.addWidget(self.margin)
            row2.addStretch(1)
            right.addLayout(row2)
            lay.addLayout(right, 1)
            return box

        def _set_position(self, idx):
            self._s["position"] = idx
            self._refresh_preview()

        def _on_tile(self, on):
            self._s["tile"] = on
            for b in self._pos_buttons:
                b.setEnabled(not on)                 # 平铺时位置无意义
            self.spacing.setEnabled(on)
            self._refresh_preview()

        def _on_spacing(self, v):
            self._s["spacing"] = v
            self._refresh_preview()

        def _on_rotation(self, v):
            self._s["rotation"] = v
            self._refresh_preview()

        def _on_margin(self, v):
            self._s["margin"] = v
            self._refresh_preview()

        # ---------- 预览 ----------
        def _build_preview_group(self) -> QGroupBox:
            box = QGroupBox(tr("预览"))
            lay = QVBoxLayout(box)
            self.preview = QLabel()
            self.preview.setFixedSize(self.PREVIEW_W, self.PREVIEW_H)
            self.preview.setAlignment(Qt.AlignCenter)
            lay.addWidget(self.preview)
            return box

        def _preview_pixmap(self) -> QPixmap:
            pix = QPixmap(self.PREVIEW_W, self.PREVIEW_H)
            painter = QPainter(pix)
            # 模拟一张截图：渐变 + 几行"文字"，方便看清水印效果
            for y in range(self.PREVIEW_H):
                k = y / max(1, self.PREVIEW_H - 1)
                painter.fillRect(
                    0, y, self.PREVIEW_W, 1,
                    QColor(int(246 - 40 * k), int(247 - 40 * k), int(250 - 40 * k)))
            painter.setPen(QColor("#b9bec7"))
            for i in range(4):
                painter.fillRect(24, 26 + i * 30, 150 + i * 60, 6,
                                 QColor("#c8ccd3"))
            painter.end()
            p2 = QPainter(pix)
            draw_watermark(p2, self._s, QSize(self.PREVIEW_W, self.PREVIEW_H))
            p2.end()
            return pix

        def _refresh_preview(self, *args):
            if not hasattr(self, "preview"):
                return
            self.preview.setPixmap(self._preview_pixmap())

        def _sync_enabled(self):
            on_text = self.grp_text.isChecked()
            for w in (self.text, self.font_btn, self.color_btn, self.text_alpha,
                      self.outline):
                w.setEnabled(on_text)
            if hasattr(self, "text_alpha_label"):
                self.text_alpha_label.setEnabled(on_text)
            on_img = self.grp_image.isChecked()
            for w in (self.image_scale, self.image_alpha, self.image_thumb):
                w.setEnabled(on_img)
            if hasattr(self, "image_alpha_label"):
                self.image_alpha_label.setEnabled(on_img)
            self.spacing.setEnabled(self.tile.isChecked())
            for b in self._pos_buttons:
                b.setEnabled(not self.tile.isChecked())

        # ---------- 结果 ----------
        def settings(self) -> dict:
            self._s["use_text"] = self.grp_text.isChecked()
            self._s["use_image"] = self.grp_image.isChecked()
            self._s["text"] = self.text.toPlainText()
            self._s["text_alpha"] = _alpha(self.text_alpha.value())
            self._s["image_alpha"] = _alpha(self.image_alpha.value())
            self._s["outline"] = self.outline.isChecked()
            self._s["tile"] = self.tile.isChecked()
            self._s["spacing"] = self.spacing.value()
            self._s["rotation"] = self.rotation.value()
            self._s["margin"] = self.margin.value()
            self._s["image_scale"] = max(0.01, self.image_scale.value() / 100.0)
            return normalize(self._s)

        def _accept_apply(self):
            self._save_as_default = False
            self.accept()

        def _accept_default(self):
            self._save_as_default = True
            self.accept()

        def save_as_default(self) -> bool:
            """调用方在 accepted 之后询问：是否要把本次设置存为默认。"""
            return bool(getattr(self, "_save_as_default", False))


    # ========================================================================
    # 来自 border.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """border.py —— 加边框 / 边缘效果（对照 FastStone Capture 的「特效 → 边缘」）。

    FSCapture 的边缘效果和「水印」在同一个菜单下，做法是**在图片四周加一圈**，
    于是输出图会变大（不是画在图上）。这里照这个思路实现：

    - `render_border(pixmap, settings)` 返回**加了边框后的新图**（尺寸更大）
    - 编辑器里由 `Canvas.apply_border()` 调用，并把已有标注整体平移
    - 提供对话框（样式 + 宽度 + 颜色 + 实时预览 + 用设为默认）

    样式列表（FSCapture 的样式名各版本略有出入，这里给了一套常用的）：
        单线 / 双线 / 虚线 / 圆角 / 投影阴影 / 立体浮雕 / 边缘渐隐 / 拍立得白边 / 手撕纸
    """
    import json
    import math
    import random
    from pathlib import Path

    from PySide6.QtCore import QPointF, QRectF, QSize, Qt
    from PySide6.QtGui import (QBrush, QColor, QLinearGradient, QPainter,
                               QPainterPath, QPen, QPixmap)
    from PySide6.QtWidgets import (QCheckBox, QColorDialog, QComboBox, QDialog,
                                   QDialogButtonBox, QFormLayout, QGroupBox,
                                   QHBoxLayout, QLabel, QPushButton, QSlider,
                                   QSpinBox, QVBoxLayout)


    # (值, 显示名, 说明)
    STYLES = [
        ("solid", "单线边框", "纯色边框，最简洁"),
        ("double", "双线边框", "外粗内细的双线"),
        ("dashed", "虚线边框", "虚线描边"),
        ("round", "圆角边框", "图片切圆角 + 描边"),
        ("shadow", "投影阴影", "四周柔和阴影（背景透明，适合贴到文档里）"),
        ("bevel", "立体浮雕", "左上亮、右下暗，做出凹凸感"),
        ("fade", "边缘渐隐", "图片四边渐隐到边框色"),
        ("polaroid", "拍立得白边", "下方留宽白边，像拍立得"),
        ("torn", "手撕纸", "图片贴在一张撕下来的纸上，边缘不规则 + 投影"),
    ]
    STYLE_NAMES = {k: name for k, name, _ in STYLES}

    BORDER_DEFAULTS = {
        "style": "shadow",
        "width": 16,             # 边框 / 阴影宽度（像素）
        "color": "#ffffff",      # 边框色 / 渐隐目标色 / 纸张色
        "shadow_alpha": 110,     # 阴影浓度 0-255
        "shadow_spread": 0,      # 阴影额外扩散
        "radius": 16,            # 圆角半径
        "tear": 9,               # 手撕纸：撕边起伏幅度（像素）
        "seed": 7,               # 手撕纸：随机种子（同一种子撕法一致，预览=成品）
        "auto": False,           # 设为默认后新截图自动加边框
    }

    BORDER_CONFIG_PATH = Path.home() / ".pyshot" / "border.json"
    _cache = {}


    # ---------------------------------------------------------------- 设置

    def normalize_border(settings: dict | None) -> dict:
        out = dict(BORDER_DEFAULTS)
        if settings:
            for k, v in settings.items():
                if k in BORDER_DEFAULTS:
                    out[k] = v
        if out["style"] not in STYLE_NAMES:
            out["style"] = BORDER_DEFAULTS["style"]
        out["width"] = max(0, min(400, int(out["width"])))
        out["shadow_alpha"] = max(0, min(255, int(out["shadow_alpha"])))
        out["shadow_spread"] = max(0, min(200, int(out["shadow_spread"])))
        out["radius"] = max(0, min(400, int(out["radius"])))
        # 撕边幅度不能超过纸边宽度，否则锯齿会超出画布
        out["tear"] = max(0, min(int(out["tear"]), out["width"] or 1, 200))
        out["seed"] = int(out["seed"]) % 100000
        out["auto"] = bool(out["auto"])
        if not isinstance(out["color"], str):
            out["color"] = BORDER_DEFAULTS["color"]
        return out


    def load_border_default() -> dict:
        global _cache
        if _cache:
            return dict(_cache)
        try:
            with open(BORDER_CONFIG_PATH, encoding="utf-8") as f:
                _cache = normalize_border(json.load(f))
        except Exception:                        # noqa: BLE001
            _cache = dict(BORDER_DEFAULTS)
        return dict(_cache)


    def save_border_default(settings: dict) -> bool:
        global _cache
        _cache = normalize_border(settings)
        try:
            BORDER_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
            with open(BORDER_CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(_cache, f, ensure_ascii=False, indent=2)
            return True
        except Exception:                        # noqa: BLE001
            return False


    def clear_border_cache():
        global _cache
        _cache = {}


    def describe_border(settings: dict) -> str:
        s = normalize_border(settings)
        return f"{STYLE_NAMES[s['style']]} {s['width']}px"


    # ---------------------------------------------------------------- 边距与绘制

    def border_padding(settings: dict) -> tuple:
        """返回 (左, 上, 右, 下) 需要扩出去的像素。"""
        s = normalize_border(settings)
        w = s["width"]
        style = s["style"]
        if style == "shadow":
            extra = w + s["shadow_spread"]
            return extra, extra, extra, extra
        if style == "polaroid":
            return w, w, w, max(w * 3, 24)
        if style == "torn":
            # 纸边 = width，撕边在此基础上上下起伏 tear，所以要再多留 tear
            extra = w + s["tear"]
            return extra, extra, extra, extra
        if w <= 0:
            return 0, 0, 0, 0
        return w, w, w, w


    # ---------------------------------------------------------------- 手撕纸

    def _torn_outline(rect: QRectF, tear: float, seed: int, step: float = 0.0):
        """围绕 rect 生成一圈**不规则撕边**的采样点（确定性随机）。

        整圈一次性做带惯性的随机游走（不是按边分段），所以撕痕会自然地绕过四角，
        不会在角上被"掐尖"；偶尔来一道更深的撕裂，像真的撕过头。
        """
        rnd = random.Random(seed)
        if step <= 0:
            step = max(3.0, tear * 0.75)

        # 1) 沿周长按顺序采样整圈：位置 + 指向纸外的法线
        ring = []

        def seg(x0, y0, x1, y1, nx, ny):
            length = math.hypot(x1 - x0, y1 - y0)
            n = max(1, int(length / step))
            for i in range(n):
                t = i / n
                ring.append((x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, nx, ny))

        seg(rect.left(), rect.top(), rect.right(), rect.top(), 0, -1)
        seg(rect.right(), rect.top(), rect.right(), rect.bottom(), 1, 0)
        seg(rect.right(), rect.bottom(), rect.left(), rect.bottom(), 0, 1)
        seg(rect.left(), rect.bottom(), rect.left(), rect.top(), -1, 0)
        if not ring:
            return []

        # 2) 沿整圈做连续随机游走（惯性能让相邻点相关，形成连续撕痕）
        offs = []
        off = 0.0
        for _ in ring:
            off = off * 0.72 + rnd.uniform(-1.0, 1.0) * tear * 0.55
            if rnd.random() < 0.10:                 # 偶尔一道深撕
                off -= tear * rnd.uniform(0.4, 1.1)
            offs.append(max(-tear, min(tear, off)))
        # 首尾相接处取平均，消除闭合时的台阶
        offs[0] = offs[-1] = (offs[0] + offs[-1]) / 2.0

        return [(x + nx * o, y + ny * o)
                for (x, y, nx, ny), o in zip(ring, offs)]


    def _torn_path(rect: QRectF, tear: float, seed: int) -> QPainterPath:
        pts = _torn_outline(rect, tear, seed)
        if not pts:
            path = QPainterPath()
            path.addRect(rect)
            return path
        # 用折线而不是曲线：撕纸的断口本来就该是硬边
        path = QPainterPath(QPointF(*pts[0]))
        for x, y in pts[1:]:
            path.lineTo(x, y)
        path.closeSubpath()
        return path


    def _draw_torn(painter: QPainter, pix: QPixmap, out_h: int, img_rect: QRectF,
                   s: dict):
        """画"贴在一张撕下来的纸上"的效果：投影 → 纸面 → 撕边描边 → 纤维 → 图片。"""
        tear = float(s["tear"])
        paper = QColor(s["color"])
        seed = int(s["seed"])

        # 纸的"标称外沿"：距图片 width，撕边在 ±tear 起伏
        nominal = img_rect.adjusted(-s["width"], -s["width"],
                                    s["width"], s["width"])
        pts = _torn_outline(nominal, tear, seed)
        path = _torn_path(nominal, tear, seed)

        # 1) 投影：同一路径多次小偏移叠加，得到柔和阴影
        shade = max(10, s["shadow_alpha"] // 4)
        for i in (4, 3, 2, 1):
            painter.save()
            painter.translate(i * 0.9, i * 1.1)
            painter.fillPath(path, QColor(0, 0, 0, shade))
            painter.restore()

        # 2) 纸面（带极淡的纵向渐变，像纸张受光）
        grad = QLinearGradient(0, 0, 0, out_h)
        grad.setColorAt(0.0, paper.lighter(103))
        grad.setColorAt(1.0, paper.darker(104))
        painter.fillPath(path, QBrush(grad))

        # 3) 撕边描一条极淡的灰线，纸才有厚度感
        painter.setPen(QPen(QColor(0, 0, 0, 34), 1))
        painter.setBrush(Qt.NoBrush)
        painter.drawPath(path)

        # 4) 断口纤维：沿撕边取点，画 1px 短须
        rnd = random.Random(seed + 991)
        painter.setPen(QPen(QColor(0, 0, 0, 26), 1))
        for _ in range(max(12, int(len(pts) * 0.5))):
            px, py = pts[rnd.randrange(len(pts))]
            painter.drawLine(QPointF(px, py),
                             QPointF(px + rnd.uniform(-1.4, 1.4),
                                     py + rnd.uniform(-1.4, 1.4)))

        # 5) 图片本体
        painter.drawPixmap(img_rect, pix, QRectF(pix.rect()))


    def _fill(painter, rect: QRectF, color: QColor):
        painter.fillRect(rect, color)


    def _draw_shadow(painter, image_rect: QRectF, s: dict):
        """柔和阴影：从外向内叠一圈圈低透明度圆角矩形，靠重叠累积成渐变。

        每圈透明度都取一个小值（约 base 的 12%），越靠近图片被叠加的圈数越多，
        于是自然形成"贴边最暗、向外渐隐"的效果；比按圈递增透明度更均匀，
        也不会在中间出现明显色阶。
        """
        base = QColor(s["color"])
        steps = max(10, min(30, max(6, s["width"])))
        per = max(6, int(s["shadow_alpha"] * 0.12))
        painter.setPen(Qt.NoPen)
        for i in range(steps, 0, -1):
            k = i / steps
            c = QColor(base)
            c.setAlpha(per)
            grow_x = s["width"] * k + s["shadow_spread"] * k
            grow_y = s["width"] * k * 0.72 + s["shadow_spread"] * k
            r = image_rect.adjusted(-grow_x, -grow_y, grow_x, grow_y)
            radius = max(0.0, s["radius"] * k)
            painter.setBrush(c)
            painter.drawRoundedRect(r, radius, radius)


    def render_border(pix: QPixmap, settings: dict) -> QPixmap:
        """在图片四周加边框，返回**更大的新图**。"""
        s = normalize_border(settings)
        left, top, right, bottom = border_padding(s)
        w = pix.width() + left + right
        h = pix.height() + top + bottom
        if w <= 0 or h <= 0 or (left + top + right + bottom) == 0:
            return QPixmap(pix)

        dpr = float(pix.devicePixelRatio() or 1.0)
        style = s["style"]
        color = QColor(s["color"])
        # 阴影 / 渐隐 / 手撕纸需要透明背景（贴到文档里才自然）
        transparent_bg = style in ("shadow", "fade", "torn")

        out = QPixmap(w, h)
        out.fill(Qt.transparent if transparent_bg else color)
        out.setDevicePixelRatio(dpr)

        p = QPainter(out)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.SmoothPixmapTransform)
        img_rect = QRectF(left, top, pix.width(), pix.height())

        if style == "shadow":
            _draw_shadow(p, img_rect, s)
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
        elif style == "torn":
            _draw_torn(p, pix, h, img_rect, s)
        elif style == "bevel":
            # 先画底色，再在图片外圈画亮/暗两条边
            p.fillRect(QRectF(0, 0, w, h), color)
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
            light = QColor(s["color"]).lighter(165)
            dark = QColor(s["color"]).darker(155)
            for i in range(max(1, s["width"] // 3)):
                inset = i
                p.setPen(QPen(light, 1))
                p.drawLine(QPointF(inset, h - inset),
                           QPointF(inset, inset))
                p.drawLine(QPointF(inset, inset), QPointF(w - inset, inset))
                p.setPen(QPen(dark, 1))
                p.drawLine(QPointF(w - 1 - inset, inset),
                           QPointF(w - 1 - inset, h - 1 - inset))
                p.drawLine(QPointF(w - 1 - inset, h - 1 - inset),
                           QPointF(inset, h - 1 - inset))
        elif style == "round":
            path = QPainterPath()
            path.addRoundedRect(img_rect, s["radius"], s["radius"])
            p.fillRect(QRectF(0, 0, w, h), color)
            p.save()
            p.setClipPath(path)
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
            p.restore()
            p.setPen(QPen(color.darker(140), 1))
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(img_rect, s["radius"], s["radius"])
        elif style == "double":
            p.fillRect(QRectF(0, 0, w, h), color)
            inner = QColor(s["color"]).darker(150)
            p.setPen(QPen(inner, max(1, s["width"] // 5)))
            inset = max(1.0, s["width"] * 0.32)
            p.setBrush(Qt.NoBrush)
            p.drawRect(img_rect.adjusted(-inset, -inset, inset, inset))
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
        elif style == "dashed":
            p.fillRect(QRectF(0, 0, w, h), color)
            p.setPen(QPen(QColor(s["color"]).darker(160), max(1, s["width"] // 4),
                          Qt.DashLine))
            p.setBrush(Qt.NoBrush)
            inset = s["width"] / 2.0
            p.drawRect(QRectF(inset, inset, w - inset * 2, h - inset * 2))
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
        elif style == "fade":
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
            # 图片四边用边框色渐隐（内阴影式晕开）
            band = max(2.0, s["width"] * 0.8)
            c0 = QColor(color)
            c0.setAlpha(230)
            c1 = QColor(color)
            c1.setAlpha(0)
            edges = [
                (QRectF(left, top, pix.width(), band), (0, 1)),
                (QRectF(left, top + pix.height() - band, pix.width(), band),
                 (0, -1)),
                (QRectF(left, top, band, pix.height()), (1, 0)),
                (QRectF(left + pix.width() - band, top, band, pix.height()),
                 (-1, 0)),
            ]
            for rect, (dx, dy) in edges:
                if dy:
                    g = QLinearGradient(rect.topLeft(), rect.bottomLeft())
                    if dy > 0:
                        g.setColorAt(0.0, c0)
                        g.setColorAt(1.0, c1)
                    else:
                        g.setColorAt(0.0, c1)
                        g.setColorAt(1.0, c0)
                else:
                    g = QLinearGradient(rect.topLeft(), rect.topRight())
                    if dx > 0:
                        g.setColorAt(0.0, c0)
                        g.setColorAt(1.0, c1)
                    else:
                        g.setColorAt(0.0, c1)
                        g.setColorAt(1.0, c0)
                p.fillRect(rect, g)
        elif style == "polaroid":
            p.fillRect(QRectF(0, 0, w, h), color)
            # 图片下方留白处画一条淡淡的分隔阴影，像相纸压痕
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))
            p.setPen(QPen(QColor(0, 0, 0, 28), 1))
            p.drawLine(QPointF(left, top + pix.height() + 0.5),
                       QPointF(left + pix.width(), top + pix.height() + 0.5))
        else:                                    # solid 及其它
            p.fillRect(QRectF(0, 0, w, h), color)
            p.drawPixmap(img_rect, pix, QRectF(pix.rect()))

        p.end()
        return out


    # ---------------------------------------------------------------- 对话框

    class BorderDialog(QDialog):
        """边框对话框（样式 + 宽度 + 颜色 + 实时预览）。"""

        PREVIEW_MAX = QSize(430, 170)

        def __init__(self, parent=None, settings: dict | None = None,
                     image_size: QSize | None = None):
            super().__init__(parent)
            self.setWindowTitle(tr("边框 / 边缘效果"))
            self.setMinimumWidth(520)
            self._s = normalize_border(settings or load_border_default())
            self._image_size = image_size if (image_size and image_size.isValid()) \
                else QSize(640, 400)

            root = QVBoxLayout(self)
            form = QFormLayout()

            self.style = QComboBox()
            for key, name, tip in STYLES:
                self.style.addItem(tr(name), key)
                self.style.setItemData(self.style.count() - 1, tr(tip), Qt.ToolTipRole)
            idx = [k for k, _, _ in STYLES].index(self._s["style"])
            self.style.setCurrentIndex(idx)
            self.style.currentIndexChanged.connect(self._on_style)
            form.addRow(tr("样式"), self.style)

            row = QHBoxLayout()
            self.width = QSpinBox()
            self.width.setRange(0, 400)
            self.width.setSuffix(" px")
            self.width.setValue(self._s["width"])
            self.width.valueChanged.connect(self._on_width)
            row.addWidget(self.width)
            self.color_btn = QPushButton()
            self.color_btn.setFixedSize(52, 26)
            self.color_btn.clicked.connect(self._pick_color)
            row.addWidget(QLabel(tr("颜色")))
            row.addWidget(self.color_btn)
            row.addStretch(1)
            form.addRow(tr("宽度"), row)

            row2 = QHBoxLayout()
            self.radius = QSpinBox()
            self.radius.setRange(0, 400)
            self.radius.setSuffix(" px")
            self.radius.setValue(self._s["radius"])
            self.radius.valueChanged.connect(self._on_radius)
            self.radius_label = QLabel(tr("圆角"))
            row2.addWidget(self.radius_label)
            row2.addWidget(self.radius)

            # 手撕纸专用：撕边幅度 + 换一个撕法
            self.tear_label = QLabel(tr("撕边"))
            self.tear = QSpinBox()
            self.tear.setRange(0, 200)
            self.tear.setSuffix(" px")
            self.tear.setToolTip(tr("撕口的起伏幅度；不能超过纸边宽度"))
            self.tear.setValue(self._s["tear"])
            self.tear.valueChanged.connect(self._on_tear)
            self.reseed = QPushButton(tr("换一个撕法"))
            self.reseed.setToolTip(tr("重新随机撕口（同一个种子预览和成品一致）"))
            self.reseed.clicked.connect(self._on_reseed)
            row2.addWidget(self.tear_label)
            row2.addWidget(self.tear)
            row2.addWidget(self.reseed)

            self.alpha = QSlider(Qt.Horizontal)
            self.alpha.setRange(0, 100)
            self.alpha.setValue(int(round(self._s["shadow_alpha"] * 100 / 255)))
            self.alpha.valueChanged.connect(self._on_alpha)
            self.alpha.valueChanged.connect(
                lambda v: self.alpha_label.setText(f"{v}%"))
            self.alpha_label = QLabel(f"{int(round(self._s['shadow_alpha'] * 100 / 255))}%")
            self.alpha_label.setMinimumWidth(40)
            self.alpha_text = QLabel(tr("阴影浓度"))
            row2.addWidget(self.alpha_text)
            row2.addWidget(self.alpha, 1)
            row2.addWidget(self.alpha_label)
            row2.addStretch(1)
            form.addRow(tr("细节"), row2)
            root.addLayout(form)

            prev = QGroupBox(tr("预览"))
            pl = QVBoxLayout(prev)
            self.preview = QLabel()
            self.preview.setFixedSize(self.PREVIEW_MAX)
            self.preview.setAlignment(Qt.AlignCenter)
            pl.addWidget(self.preview)
            root.addWidget(prev)

            self.note = QLabel()
            self.note.setStyleSheet("color:#9aa0ab;")
            root.addWidget(self.note)

            # 注意 QDialogButtonBox 一定要给 parent（self）：
            # Qt 只在 box 的父对象是 QDialog 时，才把它的 accepted()/rejected()
            # 自动接到对话框的 accept()/reject()。没有 parent 时"取消"点了没反应
            # （应用能用只是因为下面显式连了）—— 踩过这个坑，所以这里 parent 和
            # 显式连接都给上，不依赖隐式行为。
            buttons = QDialogButtonBox(self)
            self.btn_apply = buttons.addButton(tr("应用"), QDialogButtonBox.AcceptRole)
            self.btn_default = buttons.addButton(tr("应用并设为默认"),
                                                 QDialogButtonBox.AcceptRole)
            self.btn_cancel = buttons.addButton(tr("取消"),
                                                QDialogButtonBox.RejectRole)
            self.btn_cancel.clicked.connect(self.reject)
            buttons.rejected.connect(self.reject)
            self.btn_apply.clicked.connect(self._accept_apply)
            self.btn_default.clicked.connect(self._accept_default)
            root.addWidget(buttons)

            self._update_color_button()
            self._on_style()
            self._refresh_preview()

        # ---------- 交互 ----------
        def _on_style(self, *args):
            key = self.style.currentData()
            self._s["style"] = key
            # 每种样式只显示相关参数
            is_torn = key == "torn"
            show_radius = key in ("shadow", "round") or is_torn
            show_alpha = key in ("shadow", "torn")
            self.radius.setVisible(show_radius and not is_torn)
            self.radius_label.setVisible(show_radius and not is_torn)
            self.tear.setVisible(is_torn)
            self.tear_label.setVisible(is_torn)
            self.reseed.setVisible(is_torn)
            self.alpha.setVisible(show_alpha)
            self.alpha_label.setVisible(show_alpha)
            self.alpha_text.setVisible(show_alpha)
            if is_torn:
                self.alpha_text.setText(tr("投影浓度"))
                self.tear.setMaximum(max(1, self.width.value()))
            else:
                self.alpha_text.setText(tr("阴影浓度"))
            tips = {k: t for k, _, t in STYLES}
            self.note.setText(tr(tips.get(key, "")))
            self._refresh_preview()

        def _on_width(self, v):
            self._s["width"] = v
            # 撕边幅度不能超过纸边宽度
            if self._s.get("style") == "torn":
                self.tear.setMaximum(max(1, v))
            self._refresh_preview()

        def _on_tear(self, v):
            self._s["tear"] = v
            self._refresh_preview()

        def _on_reseed(self):
            self._s["seed"] = int(self._s.get("seed", 0)) + 1
            self._refresh_preview()

        def _on_radius(self, v):
            self._s["radius"] = v
            self._refresh_preview()

        def _on_alpha(self, v):
            self._s["shadow_alpha"] = int(round(v * 255 / 100))
            self._refresh_preview()

        def _pick_color(self):
            c = QColorDialog.getColor(QColor(self._s["color"]), self, "边框颜色")
            if c.isValid():
                self._s["color"] = c.name()
                self._update_color_button()
                self._refresh_preview()

        def _update_color_button(self):
            self.color_btn.setStyleSheet(
                f"background:{self._s['color']};"
                "border:1px solid #3a3e47;border-radius:4px;")

        # ---------- 预览 ----------
        def _sample(self) -> QPixmap:
            """造一张"截图"样张（用真实比例，但缩小到预览框内）。"""
            w = min(self._image_size.width(), 300)
            h = int(w * self._image_size.height()
                    / max(1, self._image_size.width()))
            pix = QPixmap(w, h)
            p = QPainter(pix)
            p.fillRect(0, 0, w, h, QColor("#f4f6f9"))
            p.setPen(QColor("#c9cdd4"))
            for y in range(18, h, 22):
                p.drawLine(12, y, w - 12, y)
            p.fillRect(10, 8, max(20, w // 4), 5, QColor("#8890a0"))
            p.end()
            return pix

        def _refresh_preview(self, *args):
            if not hasattr(self, "preview"):
                return
            framed = render_border(self._sample(), self._s)
            if framed.width() > self.PREVIEW_MAX.width() \
                    or framed.height() > self.PREVIEW_MAX.height():
                framed = framed.scaled(self.PREVIEW_MAX, Qt.KeepAspectRatio,
                                       Qt.SmoothTransformation)
            # 放在棋盘格底上，透明背景的阴影样式才看得出来
            canvas = QPixmap(self.PREVIEW_MAX)
            canvas.fill(QColor("#1f2126"))
            cp = QPainter(canvas)
            for y in range(0, self.PREVIEW_MAX.height(), 12):
                for x in range(0, self.PREVIEW_MAX.width(), 12):
                    if (x // 12 + y // 12) % 2 == 0:
                        cp.fillRect(x, y, 12, 12, QColor("#26292f"))
            cp.drawPixmap(
                (self.PREVIEW_MAX.width() - framed.width()) // 2,
                (self.PREVIEW_MAX.height() - framed.height()) // 2, framed)
            cp.end()
            self.preview.setPixmap(canvas)

        # ---------- 结果 ----------
        def settings(self) -> dict:
            self._s["style"] = self.style.currentData()
            self._s["width"] = self.width.value()
            self._s["radius"] = self.radius.value()
            self._s["tear"] = self.tear.value()
            self._s["shadow_alpha"] = int(round(self.alpha.value() * 255 / 100))
            return normalize_border(self._s)

        def _accept_apply(self):
            self._save_as_default = False
            self.accept()

        def _accept_default(self):
            self._save_as_default = True
            self.accept()

        def save_as_default(self) -> bool:
            return bool(getattr(self, "_save_as_default", False))


    # ========================================================================
    # 来自 shapes.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """标注图形对象：矩形 / 椭圆 / 直线 / 箭头 / 画笔 / 文字 / 序号 / 高亮 / 马赛克。

    所有图形使用图像像素坐标（与底图一致），由画布负责缩放。
    """
    import copy
    import math

    from PySide6.QtCore import QPointF, QRectF, QSize, Qt
    from PySide6.QtGui import (QColor, QFont, QPainter, QPainterPath, QPen, QPixmap,
                               QTransform)


    class Shape:
        """所有标注图形的基类。"""

        def __init__(self, color: QColor, width: int):
            self.color = QColor(color)
            self.width = max(1, int(width))
            # 旋转角度（度，顺时针）。绘制/命中/手柄都绕**外接矩形中心**旋转；
            # 图形自身的坐标仍按"未旋转"存，这样 move_by / apply_rect 都不用改。
            self.rotation = 0.0

        # --- 子类需实现 ---
        def draw(self, painter: QPainter, canvas):
            raise NotImplementedError

        def bounding_rect(self) -> QRectF:
            raise NotImplementedError

        def move_by(self, dx: float, dy: float):
            raise NotImplementedError

        def contains(self, pos: QPointF, tol: float = 6.0) -> bool:
            return self.bounding_rect().adjusted(-tol, -tol, tol, tol).contains(pos)

        # --- 旋转 ---
        def center(self) -> QPointF:
            return self.bounding_rect().center()

        def rotate_by(self, degrees: float):
            self.rotation = (self.rotation + float(degrees)) % 360.0

        def world_to_local(self, pos: QPointF) -> QPointF:
            """世界坐标 → 图形自身坐标（把点反向转回未旋转的位置）。"""
            if not self.rotation:
                return QPointF(pos)
            c = self.center()
            rad = math.radians(-self.rotation)
            dx, dy = pos.x() - c.x(), pos.y() - c.y()
            return QPointF(c.x() + dx * math.cos(rad) - dy * math.sin(rad),
                           c.y() + dx * math.sin(rad) + dy * math.cos(rad))

        def rotated_corners(self) -> list:
            """外接矩形四角旋转后的世界坐标（左上、右上、右下、左下）。"""
            r = self.bounding_rect()
            pts = [r.topLeft(), r.topRight(), r.bottomRight(), r.bottomLeft()]
            if not self.rotation:
                return [QPointF(p) for p in pts]
            c = r.center()
            rad = math.radians(self.rotation)
            out = []
            for p in pts:
                dx, dy = p.x() - c.x(), p.y() - c.y()
                out.append(QPointF(c.x() + dx * math.cos(rad) - dy * math.sin(rad),
                                   c.y() + dx * math.sin(rad) + dy * math.cos(rad)))
            return out

        def rotated_handles(self) -> list:
            """8 个缩放手柄（旋转后）+ 1 个旋转手柄；不可缩放的图形返回 []。"""
            local = self.handles()
            if not local:
                return []
            if not self.rotation:
                pts = list(local)
            else:
                c = self.bounding_rect().center()
                rad = math.radians(self.rotation)
                pts = []
                for p in local:
                    dx, dy = p.x() - c.x(), p.y() - c.y()
                    pts.append(QPointF(
                        c.x() + dx * math.cos(rad) - dy * math.sin(rad),
                        c.y() + dx * math.sin(rad) + dy * math.cos(rad)))
            r = self.bounding_rect()
            top_mid = QPointF((pts[0].x() + pts[2].x()) / 2.0,
                              (pts[0].y() + pts[2].y()) / 2.0)
            # 旋转手柄放在"上边中点再往外一点"的方向上
            rad = math.radians(self.rotation - 90.0)
            dist = max(18.0, r.height() * 0.12)
            pts.append(QPointF(top_mid.x() + dist * math.cos(rad),
                               top_mid.y() + dist * math.sin(rad)))
            return pts

        def apply_rotation_and_resize(self, index: int, pos: QPointF,
                                      keep_aspect: bool = False):
            """拖某个手柄：0~7 缩放、8 旋转（由画布调用）。

            未旋转时行为和以前完全一致（对角固定）。旋转之后，角手柄改为
            **以中心等比缩放**（避免坐标系斜着时"越拖越歪"）；边中手柄在图形
            自身坐标里缩放。
            """
            if index == 8:                              # 旋转手柄
                c = self.center()
                angle = math.degrees(math.atan2(pos.y() - c.y(), pos.x() - c.x()))
                self.rotate_by(angle - (self.rotation - 90.0))
                return
            if self.rotation and index in (0, 2, 4, 6):  # 旋转后角手柄：绕中心等比
                r = self.bounding_rect()
                c = r.center()
                d0 = math.hypot(r.width(), r.height()) / 2.0
                d1 = math.hypot(pos.x() - c.x(), pos.y() - c.y())
                if d0 > 0.5 and d1 > 0.5:
                    k = d1 / d0
                    self.apply_rect(QRectF(c.x() - r.width() * k / 2.0,
                                           c.y() - r.height() * k / 2.0,
                                           max(4.0, r.width() * k),
                                           max(4.0, r.height() * k)))
                return
            self.resize_by_handle(index, self.world_to_local(pos), keep_aspect)

        # --- 通用 ---
        def pen(self) -> QPen:
            pen = QPen(self.color, self.width, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
            pen.setCosmetic(False)
            return pen

        def clone(self):
            return copy.deepcopy(self)

        def transform(self, t: QTransform):
            """按仿射变换搬运几何（画布翻转/旋转/改尺寸时用）。

            默认实现用外接矩形：对矩形/椭圆/高亮/马赛克/序号都正确；
            线段、画笔、文字各自覆盖（否则会被"外接框化"变形）。
            """
            self.apply_rect(t.mapRect(self.bounding_rect()))

        def translate(self, dx: float, dy: float):
            """整体平移（裁剪时使用）。默认按 move_by 处理。"""
            self.move_by(dx, dy)

        # ---------- 缩放手柄 ----------
        # 顺序：0左上 1上中 2右上 3右中 4右下 5下中 6左下 7左中
        def handles(self) -> list:
            """可拖拽的缩放句柄（默认按外接矩形给 8 个；返回空列表表示不可缩放）。"""
            r = self.bounding_rect()
            if r.isNull() or r.width() < 1 or r.height() < 1:
                return []
            x0, y0, x1, y1 = r.left(), r.top(), r.right(), r.bottom()
            cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
            return [QPointF(x0, y0), QPointF(cx, y0), QPointF(x1, y0),
                    QPointF(x1, cy), QPointF(x1, y1), QPointF(cx, y1),
                    QPointF(x0, y1), QPointF(x0, cy)]

        def resize_by_handle(self, index: int, pos: QPointF,
                             keep_aspect: bool = False):
            """把第 index 个句柄拖到 pos。keep_aspect=True 时角手柄保持原宽高比。"""
            r = self.bounding_rect()
            x0, y0, x1, y1 = r.left(), r.top(), r.right(), r.bottom()
            if index in (0, 1, 2):
                y0 = pos.y()
            elif index in (4, 5, 6):
                y1 = pos.y()
            if index in (0, 6, 7):
                x0 = pos.x()
            elif index in (2, 3, 4):
                x1 = pos.x()
            if keep_aspect and index in (0, 2, 4, 6) and r.height() > 0.5:
                aspect = r.width() / r.height()
                w, h = abs(x1 - x0), abs(y1 - y0)
                if w / max(1e-6, h) > aspect:
                    h = w / aspect
                else:
                    w = h * aspect
                if index == 0:
                    x0, y0 = x1 - w, y1 - h
                elif index == 2:
                    x1, y0 = x0 + w, y1 - h
                elif index == 4:
                    x1, y1 = x0 + w, y0 + h
                else:
                    x0, y1 = x1 - w, y0 + h
            new = QRectF(QPointF(min(x0, x1), min(y0, y1)),
                         QPointF(max(x0, x1), max(y0, y1)))
            self.apply_rect(new)

        def apply_rect(self, rect: QRectF):
            """把图形拉伸到新的外接矩形（子类按自身语义实现）。"""
            self.move_by(rect.topLeft().x() - self.bounding_rect().left(),
                         rect.topLeft().y() - self.bounding_rect().top())


    class RectShape(Shape):
        def __init__(self, color, width, rect: QRectF, fill=False):
            super().__init__(color, width)
            self.rect = QRectF(rect).normalized()
            self.fill = fill

        def apply_rect(self, rect: QRectF):
            self.rect = QRectF(rect).normalized()

        def draw(self, painter, canvas):
            painter.setPen(self.pen())
            if self.fill:
                c = QColor(self.color)
                c.setAlpha(60)
                painter.setBrush(c)
            else:
                painter.setBrush(Qt.NoBrush)
            painter.drawRect(self.rect)

        def bounding_rect(self):
            return self.rect

        def move_by(self, dx, dy):
            self.rect.translate(dx, dy)


    class EllipseShape(RectShape):
        def draw(self, painter, canvas):
            painter.setPen(self.pen())
            if self.fill:
                c = QColor(self.color)
                c.setAlpha(60)
                painter.setBrush(c)
            else:
                painter.setBrush(Qt.NoBrush)
            painter.drawEllipse(self.rect)


    class LineShape(Shape):
        def __init__(self, color, width, p1: QPointF, p2: QPointF):
            super().__init__(color, width)
            self.p1 = QPointF(p1)
            self.p2 = QPointF(p2)

        def handles(self):
            return [QPointF(self.p1), QPointF(self.p2)]

        def resize_by_handle(self, index: int, pos: QPointF):
            if index == 0:
                self.p1 = QPointF(pos)
            else:
                self.p2 = QPointF(pos)

        def apply_rect(self, rect: QRectF):
            # 直线按外接矩形拉伸两个端点（保持方向）
            old = self.bounding_rect()
            if old.width() < 0.5 and old.height() < 0.5:
                return
            sx = rect.width() / old.width() if old.width() > 0.5 else 1.0
            sy = rect.height() / old.height() if old.height() > 0.5 else 1.0
            self.p1 = QPointF(rect.left() + (self.p1.x() - old.left()) * sx,
                              rect.top() + (self.p1.y() - old.top()) * sy)
            self.p2 = QPointF(rect.left() + (self.p2.x() - old.left()) * sx,
                              rect.top() + (self.p2.y() - old.top()) * sy)

        def draw(self, painter, canvas):
            painter.setPen(self.pen())
            painter.drawLine(self.p1, self.p2)

        def bounding_rect(self):
            return QRectF(self.p1, self.p2).normalized()

        def move_by(self, dx, dy):
            self.p1 += QPointF(dx, dy)
            self.p2 += QPointF(dx, dy)

        def transform(self, t: QTransform):
            """直线/箭头：两个端点各自变换（否则 90° 旋转会被外接框压扁）。"""
            self.p1 = t.map(self.p1)
            self.p2 = t.map(self.p2)


    class ArrowShape(LineShape):
        """带箭头头部的直线。"""

        def draw(self, painter, canvas):
            painter.setPen(self.pen())
            painter.drawLine(self.p1, self.p2)
            angle = math.atan2(self.p2.y() - self.p1.y(), self.p2.x() - self.p1.x())
            head = 8 + self.width * 3.0
            spread = math.radians(25)
            for sign in (1, -1):
                a = angle + math.pi + sign * spread
                tip = QPointF(self.p2.x() + head * math.cos(a),
                              self.p2.y() + head * math.sin(a))
                painter.drawLine(self.p2, tip)


    class PenShape(Shape):
        """自由画笔轨迹。"""

        def __init__(self, color, width, points=None):
            super().__init__(color, width)
            self.points = [QPointF(p) for p in (points or [])]

        def add_point(self, p: QPointF):
            self.points.append(QPointF(p))

        def draw(self, painter, canvas):
            if len(self.points) < 2:
                if self.points:
                    painter.setPen(self.pen())
                    painter.drawPoint(self.points[0])
                return
            path = QPainterPath(self.points[0])
            for p in self.points[1:]:
                path.lineTo(p)
            painter.setPen(self.pen())
            painter.setBrush(Qt.NoBrush)
            painter.drawPath(path)

        def bounding_rect(self):
            if not self.points:
                return QRectF()
            xs = [p.x() for p in self.points]
            ys = [p.y() for p in self.points]
            return QRectF(min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1)

        def apply_rect(self, rect: QRectF):
            old = self.bounding_rect()
            if old.width() < 1 or old.height() < 1 or not self.points:
                return
            sx = rect.width() / old.width()
            sy = rect.height() / old.height()
            self.points = [QPointF(rect.left() + (p.x() - old.left()) * sx,
                                   rect.top() + (p.y() - old.top()) * sy)
                           for p in self.points]

        def move_by(self, dx, dy):
            d = QPointF(dx, dy)
            self.points = [p + d for p in self.points]

        def transform(self, t: QTransform):
            """画笔：每个点都跟着变换，形状不会被"外接框化"。"""
            self.points = [t.map(p) for p in self.points]


    class TextShape(Shape):
        def __init__(self, color, width, pos: QPointF, text: str, font_size: int,
                     family: str = ""):
            super().__init__(color, width)
            self.pos = QPointF(pos)
            self.text = text
            self.font_size = max(8, int(font_size))
            self.family = family or ""      # 空 = 用默认字体（微软雅黑）
            self.bold = True

        def font(self) -> QFont:
            f = QFont(self.family or "Microsoft YaHei")
            f.setPixelSize(self.font_size)
            f.setBold(self.bold)
            return f

        def draw(self, painter, canvas):
            painter.setFont(self.font())
            painter.setPen(QPen(self.color))
            # 白色描边提升可读性
            metrics = painter.fontMetrics()
            for i, line in enumerate(self.text.split("\n")):
                y = self.pos.y() + i * metrics.lineSpacing()
                for ox, oy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    painter.setPen(QPen(QColor(255, 255, 255, 200)))
                    painter.drawText(QPointF(self.pos.x() + ox, y + oy), line)
                painter.setPen(QPen(self.color))
                painter.drawText(QPointF(self.pos.x(), y), line)

        def bounding_rect(self):
            metrics = _metrics(self.font())
            lines = self.text.split("\n")
            w = max((metrics.horizontalAdvance(s) for s in lines), default=0)
            h = metrics.lineSpacing() * len(lines)
            return QRectF(self.pos.x() - 2, self.pos.y() - metrics.ascent() - 2,
                          w + 6, h + 6)

        def apply_rect(self, rect: QRectF):
            """缩放文字：按高度比例改字号（8~400），并把左上角搬到新位置。"""
            old = self.bounding_rect()
            if old.height() < 2:
                return
            ratio = rect.height() / old.height()
            self.font_size = int(min(400, max(8, round(self.font_size * ratio))))
            metrics = _metrics(self.font())
            self.pos = QPointF(rect.left() + 2,
                               rect.top() + 2 + metrics.ascent())

        def move_by(self, dx, dy):
            self.pos += QPointF(dx, dy)

        def transform(self, t: QTransform):
            """文字：只搬位置、不改字号（翻转/旋转画布后文字要保持原来的大小）。"""
            self.pos = t.map(self.pos)


    def _metrics(font: QFont):
        from PySide6.QtGui import QFontMetrics
        return QFontMetrics(font)


    class StepShape(Shape):
        """序号步骤：圆形底 + 数字，做操作指引的核心工具。

        直径（diameter）独立可调，数字大小自动跟随直径，保证任何尺寸下都居中好看。
        """

        def __init__(self, color, width, center: QPointF, number: int,
                     font_size: int = 20, diameter: float | None = None):
            super().__init__(color, width)
            self.center = QPointF(center)
            self.number = int(number)
            self.font_size = max(8, int(font_size))
            # 未指定直径时按字号推算（兼容旧调用）
            self.diameter = float(diameter) if diameter else max(24.0, self.font_size * 1.8)

        @property
        def radius(self):
            return self.diameter / 2.0

        def digit_pixel_size(self) -> int:
            """数字字号：跟随直径，但不超过设定的字号上限。"""
            return max(8, int(min(self.diameter * 0.62, self.font_size * 1.8)))

        def set_diameter(self, diameter: float):
            self.diameter = max(16.0, float(diameter))

        def draw(self, painter, canvas):
            r = self.radius
            rect = QRectF(self.center.x() - r, self.center.y() - r, r * 2, r * 2)
            painter.setPen(QPen(QColor(255, 255, 255), max(2, self.width)))
            painter.setBrush(self.color)
            painter.drawEllipse(rect)
            font = QFont("Microsoft YaHei")
            font.setPixelSize(self.digit_pixel_size())
            font.setBold(True)
            painter.setFont(font)
            painter.setPen(QPen(QColor(255, 255, 255)))
            painter.drawText(rect, Qt.AlignCenter, str(self.number))

        def bounding_rect(self):
            r = self.radius
            return QRectF(self.center.x() - r, self.center.y() - r, r * 2, r * 2)

        def apply_rect(self, rect: QRectF):
            """缩放序号：改直径，圆心跟随。"""
            self.center = rect.center()
            self.set_diameter(max(rect.width(), rect.height()))

        def contains(self, pos, tol=6.0):
            return (math.hypot(pos.x() - self.center.x(),
                               pos.y() - self.center.y()) <= self.radius + tol)

        def move_by(self, dx, dy):
            self.center += QPointF(dx, dy)


    class HighlightShape(Shape):
        """荧光笔高亮：半透明色块。"""

        def __init__(self, color, width, rect: QRectF):
            super().__init__(color, width)
            self.rect = QRectF(rect).normalized()

        def draw(self, painter, canvas):
            c = QColor(self.color)
            c.setAlpha(110)
            painter.setPen(Qt.NoPen)
            painter.setBrush(c)
            painter.drawRect(self.rect)

        def bounding_rect(self):
            return self.rect

        def move_by(self, dx, dy):
            self.rect.translate(dx, dy)


    class MosaicShape(Shape):
        """马赛克：绘制时将底图对应区域像素化。"""

        PIXEL = 12

        def __init__(self, color, width, rect: QRectF):
            super().__init__(color, width)
            self.rect = QRectF(rect).normalized()

        def draw(self, painter, canvas):
            src = canvas.base_pixmap
            r = self.rect.toAlignedRect().intersected(src.rect())
            if r.isEmpty():
                return
            region = src.copy(r)
            region.setDevicePixelRatio(1.0)     # 避免源 dpr 影响贴图尺寸
            w = max(1, r.width() // self.PIXEL)
            h = max(1, r.height() // self.PIXEL)
            small = region.scaled(w, h, Qt.IgnoreAspectRatio, Qt.SmoothTransformation)
            blocky = small.scaled(r.size(), Qt.IgnoreAspectRatio, Qt.FastTransformation)
            blocky.setDevicePixelRatio(1.0)
            # 用显式目标/源矩形，坐标系与图形一致（图像物理像素）
            painter.drawPixmap(QRectF(r), blocky, QRectF(blocky.rect()))

        def bounding_rect(self):
            return self.rect

        def move_by(self, dx, dy):
            self.rect.translate(dx, dy)


    class WatermarkShape(Shape):
        """水印（文字/图片、九宫格或平铺、旋转、透明度）。

        非破坏性：和水印相关的参数都在这里，可以随时删除/撤销，不影响底图。
        """

        def __init__(self, settings: dict, image_size, offset=None):
            super().__init__(QColor(settings.get("color", "#ffffff")),
                             int(settings.get("font_size", 28)))
            self.settings = dict(settings)
            self.image_size = QSize(int(image_size.width()),
                                    int(image_size.height()))
            self.offset = QPointF(offset) if offset else QPointF(0, 0)
            self._bounds = None

        def _size(self):

            return watermark_size(self.settings, self.image_size)

        def draw(self, painter, canvas):

            draw_watermark(painter, self.settings, self.image_size, self.offset)

        def bounding_rect(self):

            size = self._size()
            pts = placements(self.settings, self.image_size, size)
            if not pts:
                return QRectF()
            if self.settings.get("position") == 9:      # 平铺：整幅都算
                return QRectF(0, 0, self.image_size.width(), self.image_size.height())
            pt = pts[0] + self.offset
            # 旋转后用一个足够大的外接矩形，保证点选/移动手感
            r = max(size.width(), size.height())
            return QRectF(pt.x(), pt.y(), size.width(), size.height()).adjusted(
                -(r - size.width()) / 2, -(r - size.height()) / 2,
                (r - size.width()) / 2, (r - size.height()) / 2)

        def move_by(self, dx, dy):
            self.offset += QPointF(dx, dy)
            self._bounds = None

        def transform(self, t: QTransform):
            """水印：只搬偏移位置（翻转/旋转画布不该改水印字号）。"""
            if self.offset is None:
                self.offset = QPointF(0.0, 0.0)
            self.offset = t.map(self.offset)
            self._bounds = None

        def apply_rect(self, rect: QRectF):
            """缩放水印：按高度比例调整字号或图片大小，并跟到新位置。"""
            old = self.bounding_rect()
            if old.height() < 2 or old.width() < 2:
                return
            ratio = max(0.1, min(8.0, rect.height() / old.height()))
            if self.settings.get("kind") == "image":
                self.settings["image_scale"] = max(
                    0.02, min(1.0, float(self.settings.get("image_scale", 0.2)) * ratio))
            else:
                self.settings["font_size"] = int(min(
                    400, max(8, round(int(self.settings.get("font_size", 28)) * ratio))))
            self._bounds = None
            new = self.bounding_rect()
            self.offset += QPointF(rect.left() - new.left(), rect.top() - new.top())


    def clone_shapes(shapes):
        return copy.deepcopy(shapes)


    # ========================================================================
    # 来自 style.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """现代化深色主题：全局 QSS + 自绘矢量工具图标。"""
    from PySide6.QtCore import QPointF, Qt
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import (QColor, QFont, QIcon, QPainter, QPainterPath,
                               QPalette, QPen, QPixmap)

    ACCENT = "#4c9aff"
    ACCENT_HOVER = "#66adff"
    ACCENT_ACTIVE = "#2f7fe0"
    ACCENT_SOFT = "rgba(76, 154, 255, 0.16)"
    DANGER = "#ff5c5c"

    BG = "#17181c"            # 窗口底色（接近黑）
    SURFACE = "#1f2126"       # 面板/工具栏
    SURFACE_2 = "#26292f"     # 浮起的控件
    BORDER = "#2c2f36"        # 细分隔线
    BORDER_STRONG = "#3a3e47" # 需要强调的分隔
    TEXT = "#e6e8ec"
    TEXT_DIM = "#a2a8b2"

    RADIUS = 8
    RADIUS_LG = 10

    import os as _os
    from pathlib import Path as _Path

    from PySide6.QtWidgets import (QSpinBox as _QSpinBox, QStyle,
                                   QStyleOptionSpinBox)

    # 注意：**必须在模块顶层导入**。函数内写 `from i18n import current_language`
    # 在单文件合并版里会被丢掉（合并只保留顶层导入），而 apply_font 里的
    # try/except 会把这个 NameError 吞掉 → 中文界面悄悄退回 Segoe UI（踩过）。



    class SpinBox(_QSpinBox):
        """深色主题的 SpinBox：自己画上/下箭头。

        Qt 的 QSS 在自定义 ::up-button 后就不再画箭头（实测无论调色板还是
        image: 都不可靠），所以这里在 paintEvent 里直接画两个小三角，
        任何主题下都保证可见。
        """

        def paintEvent(self, e):
            super().paintEvent(e)
            opt = QStyleOptionSpinBox()
            self.initStyleOption(opt)
            style = self.style()
            color = self.palette().color(QPalette.ButtonText)
            if not self.isEnabled():
                color = self.palette().color(QPalette.Disabled, QPalette.ButtonText)
            p = QPainter(self)
            p.setRenderHint(QPainter.Antialiasing)
            p.setPen(Qt.NoPen)
            p.setBrush(color)
            for sc, up in ((QStyle.SC_SpinBoxUp, True), (QStyle.SC_SpinBoxDown, False)):
                rect = style.subControlRect(QStyle.CC_SpinBox, opt, sc, self)
                if rect.isNull():
                    continue
                cx, cy = rect.center().x(), rect.center().y()
                s = max(2.5, min(rect.width(), rect.height()) * 0.30)
                pts = [(cx, cy - s), (cx + s, cy + s), (cx - s, cy + s)] if up else \
                      [(cx, cy + s), (cx + s, cy - s), (cx - s, cy - s)]
                path = QPainterPath(QPointF(*pts[0]))
                for x, y in pts[1:]:
                    path.lineTo(x, y)
                path.closeSubpath()
                p.drawPath(path)
            p.end()


    def apply_theme(app):
        """先铺一套深色 QPalette（Fusion 的很多细节——下拉箭头、复选框勾、
        禁用文字、数字框箭头——都靠调色板画），再叠加 QSS 精修。"""
        app.setStyle("Fusion")
        pal = QPalette()
        base = QColor(BG)
        panel = QColor(SURFACE)
        text = QColor(TEXT)
        dim = QColor(TEXT_DIM)
        accent = QColor(ACCENT)
        pal.setColor(QPalette.Window, panel)
        pal.setColor(QPalette.WindowText, text)
        pal.setColor(QPalette.Base, base)
        pal.setColor(QPalette.AlternateBase, panel)
        pal.setColor(QPalette.ToolTipBase, panel)
        pal.setColor(QPalette.ToolTipText, text)
        pal.setColor(QPalette.Text, text)
        pal.setColor(QPalette.Button, panel)
        pal.setColor(QPalette.ButtonText, text)
        pal.setColor(QPalette.BrightText, QColor("#ff5555"))
        pal.setColor(QPalette.Highlight, accent)
        pal.setColor(QPalette.HighlightedText, QColor("#ffffff"))
        pal.setColor(QPalette.Link, accent)
        pal.setColor(QPalette.LinkVisited, QColor("#8e24aa"))
        pal.setColor(QPalette.PlaceholderText, QColor("#6b7079"))
        # 禁用态
        disabled = QColor("#5a5e66")
        pal.setColor(QPalette.Disabled, QPalette.Text, disabled)
        pal.setColor(QPalette.Disabled, QPalette.ButtonText, disabled)
        pal.setColor(QPalette.Disabled, QPalette.WindowText, disabled)
        pal.setColor(QPalette.Disabled, QPalette.Highlight, QColor("#2a2d33"))
        pal.setColor(QPalette.Disabled, QPalette.HighlightedText, QColor("#8a8f98"))
        app.setPalette(pal)
        apply_font(app)
        app.setStyleSheet(APP_QSS)


    def apply_font(app):
        """设置全局字体（**不要**用 QSS 的 `* { font-family: ... }`，见下）。

        原来字体是靠 QSS 的 `* { font-family: "Segoe UI", "Microsoft YaHei UI" }`
        设的。实测这个写法代价极大：本机进程内**第一次中文排版**要 7~8 秒
        （`*` 把首选族钉在 Segoe UI 上，中文只能走回退扫描；而每次扫描都要
        枚举 800+ 字体族）。改成一次性 app.setFont(中文字体) 之后，
        第一次排版降到 1.3~2.6 秒 —— 这正是"启动后二十多秒按热键没反应"的主因。

        中文界面用「微软雅黑」（Windows 自带、含完整 CJK），其它语言用 Segoe UI。
        语言切换后要再调一次（字体不会自己换）。
        """
        fam = "Segoe UI"
        try:
            if str(current_language()).startswith("zh"):
                fam = "Microsoft YaHei UI"
        except Exception:                              # noqa: BLE001
            pass
        f = QFont(fam)
        f.setPixelSize(13)                             # 与原来 QSS 里的字号一致
        app.setFont(f)


    APP_QSS = f"""
    /* ============ PyShot 设计系统 ============ */
    /* 注意：这里**故意不写** `* {{ font-family: ... }}` —— 全局字体在
       apply_font() 里用 app.setFont() 设，理由见那里的注释（性能，7s → 2s）。 */
    QMainWindow, QDialog {{ background: {BG}; color: {TEXT}; }}

    /* ---------- 顶栏（流式布局，窗口变窄自动换行） ---------- */
    QWidget#topbar {{
        background: {SURFACE};
        border: none;
        border-bottom: 1px solid {BORDER};
    }}
    QWidget#topbar QLabel {{ color: {TEXT_DIM}; padding: 0 2px; }}
    QWidget#topbar QToolButton#topbtn {{
        background: transparent; border: none; border-radius: {RADIUS}px;
        padding: 6px 12px; color: {TEXT};
    }}
    QWidget#topbar QToolButton#topbtn:hover {{ background: {SURFACE_2}; }}
    QWidget#topbar QToolButton#topbtn:pressed {{ background: {BORDER_STRONG}; }}
    QWidget#topbar QToolButton#topbtn:disabled {{ color: #596069; }}
    QPushButton#primarybtn {{
        background: {ACCENT}; color: #ffffff; font-weight: 600;
        border: none; border-radius: {RADIUS}px; padding: 6px 14px;
    }}
    QPushButton#primarybtn:hover {{ background: {ACCENT_HOVER}; }}
    QPushButton#primarybtn:pressed {{ background: {ACCENT_ACTIVE}; }}

    /* ---------- 左侧工具轨道（工具分组，细线分隔） ---------- */
    QFrame#sidebar {{
        background: {SURFACE};
        border: none;
        border-right: 1px solid {BORDER};
    }}
    QToolButton#toolbtn {{
        background: transparent; border: none; border-radius: {RADIUS}px;
        padding: 8px;
    }}
    QToolButton#toolbtn:hover {{ background: {SURFACE_2}; }}
    QToolButton#toolbtn:checked {{
        background: {ACCENT_SOFT};
        border: none;
        border-left: 3px solid {ACCENT};
        border-radius: 4px {RADIUS}px {RADIUS}px 4px;
    }}
    QFrame#railsep {{ background: {BORDER}; max-height: 1px; margin: 4px 10px; border: none; }}

    QFrame#topsep {{ background: {BORDER_STRONG}; max-width: 1px; margin: 4px 4px; border: none; }}

    /* ---------- 圆形色板 ---------- */
    QPushButton#swatch {{ border-radius: 11px; border: 2px solid rgba(0,0,0,0); }}
    QPushButton#swatch:hover {{ border: 2px solid {TEXT_DIM}; }}
    QPushButton#swatch[selected="true"] {{ border: 2px solid #ffffff; }}
    QPushButton#swatchMore {{
        background: {SURFACE_2}; color: {TEXT}; border-radius: 11px; border: none;
    }}
    QPushButton#swatchMore:hover {{ background: {BORDER_STRONG}; }}

    /* ---------- 数字输入框 ---------- */
    QSpinBox {{
        background: {SURFACE_2}; color: {TEXT};
        border: 1px solid {BORDER}; border-radius: {RADIUS - 2}px;
        padding: 4px 6px;
    }}
    QSpinBox:focus {{ border: 1px solid {ACCENT}; }}
    QSpinBox::up-button, QSpinBox::down-button {{
        width: 16px; background: transparent; border: none;
    }}
    QSpinBox::up-button:hover, QSpinBox::down-button:hover {{ background: {BORDER_STRONG}; }}

    /* ---------- 画布滚动区 ---------- */
    QScrollArea {{ background: {BG}; border: none; }}
    QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
    QScrollBar::handle:vertical {{
        background: {BORDER_STRONG}; border-radius: 5px; min-height: 30px;
    }}
    QScrollBar::handle:vertical:hover {{ background: #4a5059; }}
    QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {{ height: 0; }}
    QScrollBar:horizontal {{ background: transparent; height: 10px; margin: 2px; }}
    QScrollBar::handle:horizontal {{
        background: {BORDER_STRONG}; border-radius: 5px; min-width: 30px;
    }}
    QScrollBar::handle:horizontal:hover {{ background: #4a5059; }}
    QScrollBar::add-line:horizontal, QScrollBar::sub-line:horizontal {{ width: 0; }}

    /* ---------- 左侧工具条的滚动条：细一点，别把 44px 的按钮挤掉 ---------- */
    QScrollArea#railscroll QScrollBar:vertical {{ width: 6px; margin: 0; background: transparent; }}
    QScrollArea#railscroll QScrollBar::handle:vertical {{
        background: {BORDER_STRONG}; border-radius: 3px; min-height: 24px;
    }}
    QScrollArea#railscroll QScrollBar::handle:vertical:hover {{ background: #4a5059; }}
    QScrollArea#railscroll {{ background: {SURFACE}; }}

    /* ---------- 画布标签页（下划线指示，现代风） ---------- */
    QTabWidget#canvasTabs::pane {{ border: none; background: {BG}; }}
    QTabBar {{ qproperty-drawBase: 0; }}
    QTabWidget#canvasTabs > QTabBar {{ background: {SURFACE}; }}
    QTabBar::tab {{
        background: transparent; color: {TEXT_DIM};
        padding: 8px 6px 9px 14px; margin: 0 2px;
        border: none; border-bottom: 2px solid transparent;
    }}
    QTabBar::tab:hover {{ color: {TEXT}; }}
    QTabBar::tab:selected {{ color: {TEXT}; border-bottom: 2px solid {ACCENT}; font-weight: 600; }}
    QToolButton#tabclose {{
        background: transparent; border: none; border-radius: 4px;
        color: {TEXT_DIM}; font-size: 11px; padding: 1px 4px;
    }}
    QToolButton#tabclose:hover {{ background: {SURFACE_2}; color: #ffffff; }}
    QLabel#sizelabel {{ color: {TEXT_DIM}; padding-right: 6px; }}

    /* ---------- 状态栏 ---------- */
    QStatusBar {{
        background: {SURFACE}; color: {TEXT_DIM};
        border-top: 1px solid {BORDER}; min-height: 30px;
    }}
    QStatusBar::item {{ border: none; }}
    QLabel#toolname {{ color: {TEXT_DIM}; padding-left: 6px; }}

    /* ---------- 状态栏右侧缩放胶囊 ---------- */
    QWidget#zoomgroup {{
        background: {SURFACE_2}; border: 1px solid {BORDER}; border-radius: {RADIUS}px;
    }}
    QPushButton#zoombtn {{
        background: transparent; border: none; border-radius: 5px;
        color: {TEXT}; font-size: 14px; font-weight: 600; padding: 0;
    }}
    QPushButton#zoombtn:hover {{ background: {BORDER_STRONG}; }}
    QPushButton#zoombtn:pressed {{ background: {ACCENT_SOFT}; }}
    QLabel#zoomlabel {{ color: #ffffff; font-weight: 700; font-size: 13px; padding: 0 2px; }}
    QFrame#zoomsep {{ color: {BORDER_STRONG}; background: {BORDER_STRONG};
        max-width: 1px; margin: 5px 4px; border: none; }}

    /* ---------- 菜单 / 提示 / 通用控件 ---------- */
    QMenu {{
        background: {SURFACE_2}; color: {TEXT};
        border: 1px solid {BORDER_STRONG}; border-radius: {RADIUS_LG}px; padding: 5px;
    }}
    QMenu::item {{ padding: 7px 28px 7px 14px; border-radius: 6px; }}
    QMenu::item:selected {{ background: {ACCENT_SOFT}; color: {TEXT}; }}
    QMenu::separator {{ height: 1px; background: {BORDER}; margin: 5px 10px; }}
    QToolTip {{
        background: {SURFACE_2}; color: {TEXT};
        border: 1px solid {BORDER_STRONG}; border-radius: 6px; padding: 5px 8px;
    }}
    QLineEdit, QPlainTextEdit, QComboBox, QSlider::groove:horizontal {{
        background: {SURFACE_2}; color: {TEXT};
        border: 1px solid {BORDER}; border-radius: {RADIUS - 2}px;
    }}
    QLineEdit:focus, QPlainTextEdit:focus {{ border: 1px solid {ACCENT}; }}
    QFileDialog QListView, QFileDialog QTreeView {{
        background: {BG}; color: {TEXT}; border: 1px solid {BORDER};
    }}
    QPushButton {{
        background: {SURFACE_2}; color: {TEXT};
        border: none; border-radius: {RADIUS}px; padding: 7px 16px;
    }}
    QPushButton:hover {{ background: {BORDER_STRONG}; }}
    QPushButton:default {{ background: {ACCENT}; color: white; }}
    QColorDialog {{ background: {BG}; }}
    QSlider::groove:horizontal {{ height: 4px; background: {BORDER}; border-radius: 2px; }}
    QSlider::handle:horizontal {{
        background: {ACCENT}; width: 14px; height: 14px; margin: -5px 0;
        border-radius: 7px;
    }}
    QSlider::handle:horizontal:hover {{ background: {ACCENT_HOVER}; }}
    """


    # ---------------------------------------------------------------- 工具图标

    def _icon_pixmap(draw_fn, color: QColor, size=24, dpr=2) -> QPixmap:
        pix = QPixmap(size * dpr, size * dpr)
        pix.setDevicePixelRatio(dpr)
        pix.fill(Qt.transparent)
        p = QPainter(pix)
        p.setRenderHint(QPainter.Antialiasing)
        pen = QPen(color, 2.0, Qt.SolidLine, Qt.RoundCap, Qt.RoundJoin)
        p.setPen(pen)
        p.setBrush(Qt.NoBrush)
        draw_fn(p, color)
        p.end()
        return pix


    def _draw_select(p, c):
        path = QPainterPath(QPointF(7, 3.5))
        for pt in [(7, 18.5), (10.8, 15), (13, 20.5), (15.6, 19.2), (13.4, 13.8), (18.5, 13.8)]:
            path.lineTo(*pt)
        path.closeSubpath()
        p.setBrush(c)
        p.drawPath(path)


    def _draw_rect(p, c):
        p.drawRoundedRect(4.5, 6.5, 15, 11, 1.5, 1.5)


    def _draw_ellipse(p, c):
        p.drawEllipse(4.5, 6.5, 15, 11)


    def _draw_line(p, c):
        p.drawLine(QPointF(5, 19), QPointF(19, 5))


    def _draw_arrow(p, c):
        p.drawLine(QPointF(4.5, 19.5), QPointF(17, 7))
        p.drawLine(QPointF(17, 7), QPointF(10.5, 7.8))
        p.drawLine(QPointF(17, 7), QPointF(16.2, 13.5))


    def _draw_pen(p, c):
        path = QPainterPath(QPointF(4, 19))
        path.cubicTo(QPointF(8, 10), QPointF(10, 15), QPointF(13, 11))
        path.cubicTo(QPointF(15, 8.5), QPointF(17, 8), QPointF(20, 5))
        p.drawPath(path)


    def _draw_step(p, c):
        p.drawEllipse(4, 4, 16, 16)
        f = QFont("Segoe UI")
        f.setPixelSize(12)
        f.setBold(True)
        p.setFont(f)
        p.drawText(4, 4, 16, 16, Qt.AlignCenter, "1")


    def _draw_text(p, c):
        f = QFont("Segoe UI")
        f.setPixelSize(17)
        f.setBold(True)
        p.setFont(f)
        p.drawText(4, 3, 16, 19, Qt.AlignCenter, "T")


    def _draw_highlight(p, c):
        fill = QColor(c)
        fill.setAlpha(90)
        p.setPen(Qt.NoPen)
        p.setBrush(fill)
        p.drawRoundedRect(4, 9, 16, 7, 2, 2)
        p.setPen(QPen(c, 2.0, Qt.SolidLine, Qt.RoundCap))
        p.drawLine(QPointF(4, 16.5), QPointF(20, 16.5))


    def _draw_mosaic(p, c):
        s = 4.6
        for i in range(3):
            for j in range(3):
                if (i + j) % 2 == 0:
                    p.fillRect(4.2 + j * (s + 0.8), 4.2 + i * (s + 0.8), s, s, c)


    def _draw_pick(p, c):
        # 滴管：斜杆 + 顶部菱形
        p.drawLine(QPointF(5.5, 18.5), QPointF(13.5, 10.5))
        path = QPainterPath(QPointF(15.5, 4))
        for pt in [(20, 8.5), (15.5, 13), (11, 8.5)]:
            path.lineTo(*pt)
        path.closeSubpath()
        p.drawPath(path)
        p.setBrush(c)
        p.drawEllipse(QPointF(5, 20), 1.8, 1.8)


    def _draw_crop(p, c):
        for x1, y1, x2, y2, x3, y3 in [
                (5, 10, 5, 5, 10, 5), (14, 5, 19, 5, 19, 10),
                (19, 14, 19, 19, 14, 19), (10, 19, 5, 19, 5, 14)]:
            path = QPainterPath(QPointF(x1, y1))
            path.lineTo(x2, y2)
            path.lineTo(x3, y3)
            p.drawPath(path)


    def _draw_camera(p, c):
        """相机图标（顶栏"截图"按钮用）。"""
        p.drawRoundedRect(3.5, 7.5, 17, 12, 2, 2)
        p.drawLine(QPointF(9, 7.5), QPointF(10.5, 5))
        p.drawLine(QPointF(10.5, 5), QPointF(13.5, 5))
        p.drawLine(QPointF(13.5, 5), QPointF(15, 7.5))
        p.drawEllipse(QPointF(12, 13.5), 3.4, 3.4)


    # ---- 托盘菜单图标 ----

    def _draw_monitor(p, c):
        """显示器：屏幕 + 底座。"""
        p.drawRoundedRect(3, 5, 18, 12, 2, 2)
        p.drawLine(QPointF(12, 17), QPointF(12, 20))
        p.drawLine(QPointF(8, 20), QPointF(16, 20))


    def _draw_scroll(p, c):
        """滚动长截图：向下的箭头 + 两横线。"""
        p.drawLine(QPointF(12, 3.5), QPointF(12, 14))
        p.drawLine(QPointF(12, 14), QPointF(8, 10))
        p.drawLine(QPointF(12, 14), QPointF(16, 10))
        p.drawLine(QPointF(5, 18), QPointF(19, 18))
        p.drawLine(QPointF(5, 21), QPointF(19, 21))


    def _draw_image(p, c):
        """图片：相框 + 山形。"""
        p.drawRoundedRect(3.5, 5, 17, 14, 2, 2)
        p.drawEllipse(QPointF(8, 9.5), 1.6, 1.6)
        p.drawLine(QPointF(5, 17), QPointF(10.5, 11.5))
        p.drawLine(QPointF(10.5, 11.5), QPointF(14, 15))
        p.drawLine(QPointF(14, 15), QPointF(16.5, 12.5))
        p.drawLine(QPointF(16.5, 12.5), QPointF(20, 17))


    def _draw_window(p, c):
        """窗口/编辑器：标题栏 + 内容。"""
        p.drawRoundedRect(3.5, 4.5, 17, 15, 2, 2)
        p.drawLine(QPointF(3.5, 9), QPointF(20.5, 9))
        p.drawLine(QPointF(6, 6.8), QPointF(6.2, 6.8))
        p.drawLine(QPointF(9, 6.8), QPointF(9.2, 6.8))


    def _draw_pin(p, c):
        """图钉：贴图用。"""
        p.drawLine(QPointF(12, 12), QPointF(12, 20))
        path = QPainterPath(QPointF(7, 11))
        path.lineTo(17, 11)
        path.lineTo(14.5, 5)
        path.lineTo(9.5, 5)
        path.closeSubpath()
        p.drawPath(path)


    def _draw_exit(p, c):
        """退出：电源符号。"""
        path = QPainterPath(QPointF(7, 5.5))
        path.cubicTo(QPointF(2.5, 9), QPointF(4, 19), QPointF(12, 19))
        path.cubicTo(QPointF(20, 19), QPointF(21.5, 9), QPointF(17, 5.5))
        p.drawPath(path)
        p.drawLine(QPointF(12, 3), QPointF(12, 10))


    def _draw_undo(p, c):
        """撤销：左向弧线箭头。"""
        path = QPainterPath(QPointF(5, 9))
        path.cubicTo(QPointF(11, 4), QPointF(19, 6), QPointF(19, 13))
        path.cubicTo(QPointF(19, 18), QPointF(14, 20), QPointF(9, 19))
        p.drawPath(path)
        p.drawLine(QPointF(5, 9), QPointF(5, 4))
        p.drawLine(QPointF(5, 9), QPointF(10, 9))


    def _draw_redo(p, c):
        """重做：右向弧线箭头（撤销的镜像）。"""
        path = QPainterPath(QPointF(19, 9))
        path.cubicTo(QPointF(13, 4), QPointF(5, 6), QPointF(5, 13))
        path.cubicTo(QPointF(5, 18), QPointF(10, 20), QPointF(15, 19))
        p.drawPath(path)
        p.drawLine(QPointF(19, 9), QPointF(19, 4))
        p.drawLine(QPointF(19, 9), QPointF(14, 9))


    def _draw_globe(p, c):
        """地球（语言切换菜单用）。"""
        p.drawEllipse(QPointF(12, 12), 8.5, 8.5)
        p.drawEllipse(QPointF(12, 12), 3.8, 8.5)          # 经线
        p.drawLine(QPointF(3.5, 12), QPointF(20.5, 12))   # 赤道
        p.drawArc(QRectF(3.5, 6.5, 17, 11), 0, 180 * 16)


    def _draw_hand(p, c):
        """抓手（拖动查看）：简化手掌 + 三根手指。"""
        p.drawRoundedRect(QRectF(7, 11, 10, 9), 3, 3)          # 掌
        for x in (8.6, 11.4, 14.2):                            # 手指
            p.drawLine(QPointF(x, 11), QPointF(x, 5.5))
        p.drawLine(QPointF(7, 13), QPointF(4.6, 9.5))          # 拇指
        p.drawLine(QPointF(17, 13.5), QPointF(19, 11))


    def _draw_cancel(p, c):
        """取消（圆圈加斜杠）。"""
        p.drawEllipse(QPointF(12, 12), 8.0, 8.0)
        p.drawLine(QPointF(6.4, 6.4), QPointF(17.6, 17.6))


    _ICON_DRAWERS = {
        "select": _draw_select, "rect": _draw_rect, "ellipse": _draw_ellipse,
        "line": _draw_line, "arrow": _draw_arrow, "pen": _draw_pen,
        "step": _draw_step, "text": _draw_text, "highlight": _draw_highlight,
        "mosaic": _draw_mosaic, "pick": _draw_pick, "crop": _draw_crop,
        "camera": _draw_camera, "undo": _draw_undo, "redo": _draw_redo,
        "monitor": _draw_monitor, "scroll": _draw_scroll, "image": _draw_image,
        "window": _draw_window, "pin": _draw_pin, "exit": _draw_exit,
        "globe": _draw_globe, "hand": _draw_hand, "pan": _draw_hand, "cancel": _draw_cancel,
    }


    def make_menu_icon(name: str) -> QIcon:
        """托盘/菜单项图标（浅灰，深色菜单上清晰）。"""
        return make_icon(name, off_color="#c8ccd4", on_color="#ffffff")


    def make_icon(name: str, off_color: str = "#b8c0cc",
                  on_color: str = "#ffffff") -> QIcon:
        """生成双色态图标：普通=浅灰，选中/悬停=白色。"""
        icon = QIcon()
        fn = _ICON_DRAWERS[name]
        icon.addPixmap(_icon_pixmap(fn, QColor(off_color)), QIcon.Normal, QIcon.Off)
        icon.addPixmap(_icon_pixmap(fn, QColor(on_color)), QIcon.Normal, QIcon.On)
        icon.addPixmap(_icon_pixmap(fn, QColor(on_color)), QIcon.Active, QIcon.Off)
        return icon


    def make_tool_icon(tool_id: str) -> QIcon:
        """工具图标：未选中=浅灰，选中/悬停=强调色（配合柔和的选中底色）。"""
        return make_icon(tool_id, off_color="#9aa3af", on_color=ACCENT)


    # ========================================================================
    # 来自 capture_utils.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """抓屏工具：内容空白检测 + PrintWindow 回退抓取。

    为什么需要
    ==========
    远程桌面 / 虚拟化应用（Citrix Workspace、RDP 里的应用等）常用硬件加速或
    内容保护渲染，常规的屏幕 BitBlt（Qt 的 QScreen.grabWindow）可能拿到**黑屏或
    纯色**。这里提供：

    - is_blank()：判断抓到的画面是不是"没内容"（纯黑/纯色），用于给出明确提示
    - grab_window_printwindow()：改用 Windows 的 PrintWindow(PW_RENDERFULLCONTENT)
      把指定窗口自己渲染一遍，能救回一部分 BitBlt 拿不到内容的窗口
    """
    import ctypes
    import ctypes.wintypes as wt

    from PySide6.QtGui import QImage, QPixmap

    user32 = ctypes.windll.user32
    gdi32 = ctypes.windll.gdi32

    PW_RENDERFULLCONTENT = 0x00000002
    DIB_RGB_COLORS = 0


    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [
            ("biSize", wt.DWORD), ("biWidth", ctypes.c_long),
            ("biHeight", ctypes.c_long), ("biPlanes", wt.WORD),
            ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
            ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", ctypes.c_long),
            ("biYPelsPerMeter", ctypes.c_long), ("biClrUsed", wt.DWORD),
            ("biClrImportant", wt.DWORD),
        ]


    def _gray_stats(pix: QPixmap):
        """返回 (均值, 标准差)；无法分析时返回 None。纯 Python，不依赖 numpy。"""
        if pix is None or pix.isNull():
            return None
        img = pix.toImage().convertToFormat(QImage.Format_RGB888)
        w, h, bpl = img.width(), img.height(), img.bytesPerLine()
        if w < 4 or h < 4:
            return None
        data = bytes(img.constBits())
        row_step = max(1, h // 60)
        col_step = max(1, w // 60)
        total = total_sq = 0.0
        n = 0
        for y in range(0, h, row_step):
            row = data[y * bpl: y * bpl + w * 3]
            for x in range(0, w * 3, col_step * 3):
                v = (row[x] + row[x + 1] + row[x + 2]) / 3.0
                total += v
                total_sq += v * v
                n += 1
        if n == 0:
            return None
        mean = total / n
        var = max(0.0, total_sq / n - mean * mean)
        return mean, var ** 0.5


    def pixmap_is_blank(pix: QPixmap, min_std: float = 2.0,
                        black_level: float = 12.0) -> bool:
        """判断画面是否"没内容"：整幅近乎纯色，或几乎全黑。"""
        stats = _gray_stats(pix)
        if stats is None:
            return True
        mean, std = stats
        return std < min_std or mean < black_level


    def looks_like_missing_content(pix: QPixmap, black_level: float = 18.0,
                                   uniform_std: float = 0.6) -> bool:
        """更像"抓不到内容"而非"用户就选了张素色图"：

        - 几乎全黑（远程桌面/受保护内容的典型表现），或
        - 完全没有变化且不是纯白（纯白页面可能是真实内容，不误报）
        """
        stats = _gray_stats(pix)
        if stats is None:
            return True
        mean, std = stats
        return mean < black_level or (std < uniform_std and mean < 250.0)


    def window_at(x: int, y: int) -> int:
        """返回屏幕坐标（物理像素）处的窗口句柄。"""
        pt = wt.POINT(int(x), int(y))
        return int(user32.WindowFromPoint(pt))


    def _hwnd_bitmap(hwnd: int):
        """用 PrintWindow 把窗口画进位图，返回 (hbitmap, memdc, hdc, rect)。"""
        rect = wt.RECT()
        if not user32.GetWindowRect(wt.HWND(hwnd), ctypes.byref(rect)):
            return None
        w, h = rect.right - rect.left, rect.bottom - rect.top
        if w <= 0 or h <= 0:
            return None
        hdc = user32.GetWindowDC(wt.HWND(hwnd))
        if not hdc:
            return None
        memdc = gdi32.CreateCompatibleDC(hdc)
        bmp = gdi32.CreateCompatibleBitmap(hdc, w, h)
        gdi32.SelectObject(memdc, bmp)
        ok = user32.PrintWindow(wt.HWND(hwnd), memdc, PW_RENDERFULLCONTENT)
        if not ok:                      # 老系统不支持 PW_RENDERFULLCONTENT 时退化为 0
            user32.PrintWindow(wt.HWND(hwnd), memdc, 0)
        return bmp, memdc, hdc, rect


    def _bitmap_to_image(bmp, memdc, w: int, h: int) -> QImage | None:
        info = BITMAPINFOHEADER()
        info.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        info.biWidth = w
        info.biHeight = -h              # 负数 = 自上而下
        info.biPlanes = 1
        info.biBitCount = 32
        info.biCompression = 0
        buf = ctypes.create_string_buffer(w * h * 4)
        got = gdi32.GetDIBits(memdc, bmp, 0, h, buf, ctypes.byref(info), DIB_RGB_COLORS)
        if not got:
            return None
        img = QImage(bytes(buf), w, h, w * 4, QImage.Format_RGB32).copy()
        return img


    def grab_window_printwindow(hwnd: int) -> QPixmap | None:
        """把窗口自身渲染成 pixmap（拿不到则返回 None）。"""
        if not hwnd or hwnd == 0:
            return None
        res = _hwnd_bitmap(hwnd)
        if res is None:
            return None
        bmp, memdc, hdc, rect = res
        try:
            img = _bitmap_to_image(bmp, memdc, rect.right - rect.left,
                                   rect.bottom - rect.top)
        finally:
            gdi32.DeleteObject(bmp)
            gdi32.DeleteDC(memdc)
            user32.ReleaseDC(wt.HWND(hwnd), hdc)
        if img is None or img.isNull():
            return None
        return QPixmap.fromImage(img)


    def grab_region_printwindow(region_physical, dpr: float = 1.0) -> QPixmap | None:
        """按屏幕物理像素矩形，用 PrintWindow 抓该区域（常用于 BitBlt 拿不到内容时）。

        region_physical: QRect，屏幕物理像素坐标。
        """
        from PySide6.QtCore import QRect
        hwnd = window_at(region_physical.center().x(), region_physical.center().y())
        pix = grab_window_printwindow(hwnd)
        if pix is None:
            return None
        rect = wt.RECT()
        if not user32.GetWindowRect(wt.HWND(hwnd), ctypes.byref(rect)):
            return None
        crop = QRect(region_physical.x() - rect.left, region_physical.y() - rect.top,
                     region_physical.width(), region_physical.height())
        crop = crop.intersected(QRect(0, 0, pix.width(), pix.height()))
        if crop.width() < 4 or crop.height() < 4:
            return None
        out = pix.copy(crop)
        out.setDevicePixelRatio(dpr)
        return out


    # ---------------------------------------------------------------- 原生滚动条

    OBJID_VSCROLL = -5
    OBJID_HSCROLL = -6
    STATE_SYSTEM_INVISIBLE = 0x00008000
    STATE_SYSTEM_UNAVAILABLE = 0x00000001


    class SCROLLBARINFO(ctypes.Structure):
        _fields_ = [
            ("cbSize", wt.DWORD),
            ("rcScrollBar", wt.RECT),
            ("dxyLineButton", ctypes.c_int),
            ("xyThumbTop", ctypes.c_int),
            ("xyThumbBottom", ctypes.c_int),
            ("reserved", ctypes.c_int),
            ("rgstate", wt.DWORD * 6),
        ]


    def thumb_rect_from_info(info) -> tuple:
        """从 SCROLLBARINFO 算出滑块矩形（屏幕物理像素）。返回 (QRect, 是否可见)。"""
        from PySide6.QtCore import QRect
        sb = info.rcScrollBar
        visible = not (info.rgstate[0] & (STATE_SYSTEM_INVISIBLE
                                          | STATE_SYSTEM_UNAVAILABLE))
        top = sb.top + info.xyThumbTop
        height = max(1, info.xyThumbBottom - info.xyThumbTop)
        return QRect(sb.left, top, max(1, sb.right - sb.left), height), visible


    def scrollbar_thumb_at(x: int, y: int, vertical: bool = True):
        """尽力找到 (x, y) 所在窗口的原生滚动条滑块矩形（屏幕物理像素）。

        只对使用系统标准滚动条的窗口有效；自绘滚动条（浏览器/Qt/虚拟桌面里的画面）
        会返回 None —— 那种情况只能相信用户点击的位置。
        """
        hwnd = window_at(x, y)
        if not hwnd:
            return None
        info = SCROLLBARINFO()
        info.cbSize = ctypes.sizeof(SCROLLBARINFO)
        obj = OBJID_VSCROLL if vertical else OBJID_HSCROLL
        if not user32.GetScrollBarInfo(wt.HWND(hwnd), obj, ctypes.byref(info)):
            return None
        rect, visible = thumb_rect_from_info(info)
        if not visible or rect.isNull() or rect.width() <= 0 or rect.height() <= 0:
            return None
        return rect


    # ---------------------------------------------------------------- 滚动位置 API

    SB_VERT, SB_HORZ = 1, 0
    SIF_RANGE, SIF_PAGE, SIF_POS, SIF_TRACKPOS, SIF_ALL = 0x1, 0x2, 0x4, 0x8, 0xF


    class SCROLLINFO(ctypes.Structure):
        _fields_ = [
            ("cbSize", wt.UINT), ("fMask", wt.UINT),
            ("nMin", ctypes.c_int), ("nMax", ctypes.c_int),
            ("nPage", wt.UINT), ("nPos", ctypes.c_int),
            ("nTrackPos", ctypes.c_int),
        ]


    def _get_scroll_info(hwnd: int) -> dict | None:
        """读取窗口的垂直滚动条信息（GetScrollInfo）。无滚动条返回 None。"""
        info = SCROLLINFO()
        info.cbSize = ctypes.sizeof(SCROLLINFO)
        info.fMask = SIF_RANGE | SIF_PAGE | SIF_POS
        if not user32.GetScrollInfo(wt.HWND(hwnd), SB_VERT, ctypes.byref(info)):
            return None
        if info.nMax <= info.nMin or info.nPage <= 0:
            return None
        return {"hwnd": int(hwnd), "min": int(info.nMin), "max": int(info.nMax),
                "page": int(info.nPage), "pos": int(info.nPos)}


    def get_scroll_info_at(x: int, y: int, max_ancestors: int = 6) -> dict | None:
        """在 (x, y) 物理像素处寻找可程序化滚动的窗口（向上找几层父窗口）。

        返回 {hwnd, min, max, page, pos} 或 None。
        """
        hwnd = window_at(x, y)
        tried = set()
        while hwnd and hwnd not in tried and max_ancestors > 0:
            tried.add(hwnd)
            info = _get_scroll_info(hwnd)
            if info is not None:
                return info
            parent = user32.GetParent(wt.HWND(hwnd))
            hwnd = int(parent) if parent else 0
            max_ancestors -= 1
        return None


    def set_scroll_pos(hwnd: int, pos: int) -> int:
        """用 SetScrollInfo 直接设置滚动位置（完全不用动鼠标）。返回设置后的位置。"""
        info = SCROLLINFO()
        info.cbSize = ctypes.sizeof(SCROLLINFO)
        info.fMask = SIF_POS
        info.nPos = int(pos)
        return int(user32.SetScrollInfo(wt.HWND(hwnd), SB_VERT,
                                        ctypes.byref(info), True))

    def exclude_from_capture(hwnd: int, enable: bool = True) -> bool:
        """让某个窗口**不被屏幕抓取**（WDA_EXCLUDEFROMCAPTURE）。

        用途：截图遮罩可以先 show() 出来（用户马上就看见反应），再抓屏回填底图；
        有了这个排除，抓屏就不会把遮罩自己拍进去（否则截出来是黑的/带遮罩）。
        enable=False 表示恢复（WDA_NONE）——抓完底图就恢复，免得遮罩在别的抓屏
        （录屏工具、我们自己的测试）里也一并隐身。
        Windows 10 2004+ 支持；更老的系统退回 WDA_MONITOR（拍出来是纯黑），
        再不行返回 False，调用方就保持"先抓屏再显示"的老顺序。
        """
        try:
            user32 = ctypes.windll.user32
            WDA_EXCLUDEFROMCAPTURE = 0x00000011
            WDA_MONITOR = 0x00000001
            WDA_NONE = 0x00000000
            user32.SetWindowDisplayAffinity.argtypes = [ctypes.c_void_p,
                                                        ctypes.c_uint]
            if not enable:
                user32.SetWindowDisplayAffinity(ctypes.c_void_p(hwnd), WDA_NONE)
                return True
            if user32.SetWindowDisplayAffinity(ctypes.c_void_p(hwnd),
                                               WDA_EXCLUDEFROMCAPTURE):
                return True
            if user32.SetWindowDisplayAffinity(ctypes.c_void_p(hwnd), WDA_MONITOR):
                return False          # 拍出来会是黑的，不能用来"先显示后抓屏"
        except Exception:             # noqa: BLE001
            pass
        return False

    def force_foreground(hwnd: int) -> bool:
        """把窗口抢到最前并争取键盘焦点（Windows 专用兜底）。

        为什么需要：当本进程**没有任何可见窗口**时（例如用户刚把编辑器关掉），
        新建的全屏置顶窗口有时拿不到前台激活 —— 窗口是画出来了，但收不到键盘
        事件（Esc 失效），看起来就是"遮罩挡住了、怎么都关不掉"。
        这里显式 SetWindowPos 置顶 + SetForegroundWindow。
        """
        try:
            user32 = ctypes.windll.user32
            HWND_TOPMOST = -1
            SWP_NOMOVE = 0x0002
            SWP_NOSIZE = 0x0001
            SWP_SHOWWINDOW = 0x0040
            user32.SetWindowPos(ctypes.c_void_p(hwnd), ctypes.c_void_p(HWND_TOPMOST),
                                0, 0, 0, 0,
                                SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW)
            user32.SetForegroundWindow(ctypes.c_void_p(hwnd))
            user32.SetActiveWindow(ctypes.c_void_p(hwnd))
            return True
        except Exception:                              # noqa: BLE001
            return False


    # ========================================================================
    # 来自 pinboard.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """贴图钉板（Snipaste 风格）：把图片钉在屏幕最上层。

    操作
    ====
    - 左键拖拽：移动
    - 滚轮：调整透明度
    - Ctrl + 滚轮：缩放
    - 双击 / Esc：关闭
    - 右键：菜单（复制图片 / 重置 / 关闭）
    """
    from PySide6.QtCore import QPoint, Qt, Signal
    from PySide6.QtGui import QAction, QColor, QPainter, QPen, QPixmap
    from PySide6.QtWidgets import QApplication, QMenu, QWidget



    class PinWindow(QWidget):
        closed = Signal(object)  # 参数为自身，便于宿主从列表移除

        def __init__(self, pixmap: QPixmap, pos: QPoint | None = None):
            super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                             | Qt.Tool)
            self.setAttribute(Qt.WA_DeleteOnClose)
            self._pix = QPixmap(pixmap)
            # 保留 dpr：按逻辑尺寸布局，绘制时铺满控件 → 100% 时 1:1 物理像素，不发虚
            self._dpr = float(self._pix.devicePixelRatio() or 1.0)
            self._scale = 1.0
            self._drag_pos: QPoint | None = None
            self.setWindowOpacity(1.0)
            self._apply_size()
            if pos is not None:
                self.move(pos)
            self.setCursor(Qt.SizeAllCursor)

        # ---------- 外观 ----------
        def _apply_size(self):
            w = max(24, round(self._pix.width() / self._dpr * self._scale))
            h = max(24, round(self._pix.height() / self._dpr * self._scale))
            self.setFixedSize(w, h)
            self.update()

        def paintEvent(self, e):
            p = QPainter(self)
            # 缩小时平滑滤波，放大时保持像素锐利
            p.setRenderHint(QPainter.SmoothPixmapTransform, self._scale < 1.0)
            p.drawPixmap(self.rect(), self._pix)   # 目标矩形重载：按逻辑尺寸 1:1 铺满
            p.setPen(QPen(QColor(30, 136, 229), 1))
            p.setBrush(Qt.NoBrush)
            p.drawRect(self.rect().adjusted(0, 0, -1, -1))

        # ---------- 交互 ----------
        def mousePressEvent(self, e):
            if e.button() == Qt.LeftButton:
                self._drag_pos = e.globalPosition().toPoint() - self.frameGeometry().topLeft()
            elif e.button() == Qt.RightButton:
                self._show_menu(e.globalPosition().toPoint())

        def mouseMoveEvent(self, e):
            if self._drag_pos is not None and e.buttons() & Qt.LeftButton:
                self.move(e.globalPosition().toPoint() - self._drag_pos)

        def mouseReleaseEvent(self, e):
            self._drag_pos = None

        def mouseDoubleClickEvent(self, e):
            self.close()

        def wheelEvent(self, e):
            steps = e.angleDelta().y() / 120
            if e.modifiers() & Qt.ControlModifier:
                self._scale = min(4.0, max(0.1, self._scale * (1.1 ** steps)))
                self._apply_size()
            else:
                self.setWindowOpacity(min(1.0, max(0.15, self.windowOpacity() + steps * 0.08)))

        def keyPressEvent(self, e):
            if e.key() == Qt.Key_Escape:
                self.close()

        # ---------- 菜单 ----------
        def _show_menu(self, global_pos: QPoint):
            menu = QMenu(self)
            act_copy = QAction(tr("复制图片"), self)
            act_copy.triggered.connect(
                lambda: QApplication.clipboard().setPixmap(self._pix))
            menu.addAction(act_copy)
            act_reset = QAction(tr("重置大小 / 透明度"), self)
            act_reset.triggered.connect(self._reset)
            menu.addAction(act_reset)
            menu.addSeparator()
            act_close = QAction(tr("关闭 (Esc)"), self)
            act_close.triggered.connect(self.close)
            menu.addAction(act_close)
            menu.exec(global_pos)

        def _reset(self):
            self._scale = 1.0
            self.setWindowOpacity(1.0)
            self._apply_size()

        def closeEvent(self, e):
            self.closed.emit(self)
            super().closeEvent(e)


    # ========================================================================
    # 来自 snipper.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """全屏覆盖层：框选截图区域 / 屏幕取色，带放大镜、尺寸和色值提示。

    模式
    ====
    - region：拖拽框选，松开后同时发出 captured(pixmap) 和 region_selected(rect)
    - color ：单击取色，发出 color_picked(QColor)

    用法::

        snipper = SnipperOverlay()                # 或 SnipperOverlay("color")
        snipper.captured.connect(on_pixmap)
        snipper.cancelled.connect(on_cancel)
        snipper.start()
    """
    import ctypes
    import weakref

    from PySide6.QtCore import QPoint, QRect, QRectF, Qt, QTimer, Signal
    from PySide6.QtGui import (QColor, QCursor, QFont, QGuiApplication, QImage,
                               QPainter, QPainterPath, QPen, QPixmap, QRegion)
    from PySide6.QtWidgets import QWidget

    # 诊断日志：直接顶层导入（**不要**用 try/except 包着导入 —— 单文件合并时
    # 本地导入行会被删掉，留下一个空的 try 块，直接语法错误）
    _dlog = log
    _dtimed = timed

    # ---------------------------------------------------------------- 实例注册表
    # 覆盖层是**无父窗口**的顶层窗口 —— findChildren() 找不到它们。
    # 一旦列表被重建（屏幕组合变化）或某次流程中途异常，旧实例就可能没人管、
    # 永远留在屏幕上挡住一切（用户表现："遮罩挡住了"）。
    # 所以留一份全局弱引用表，收尾时一律收掉，不依赖任何列表。
    _ALL_OVERLAYS = weakref.WeakSet()


    def finish_all_overlays():
        """把所有还活着的覆盖层收起来（兜底）。返回处理了几个。"""
        n = 0
        for ov in list(_ALL_OVERLAYS):
            try:
                if ov.isVisible() or getattr(ov, "_active", False):
                    ov.finish()
                ov.hide()
                n += 1
            except Exception:                          # noqa: BLE001
                continue
        return n


    MASK_COLOR = QColor(6, 10, 18, 150)   # 遮罩：偏深的蓝黑，任何背景都能看出"已进入截图状态"
    VK_LBUTTON = 0x01
    user32 = ctypes.windll.user32

    # 覆盖层窗口类型（测试可覆盖，用于对比不同标志对首屏速度的影响）
    OVERLAY_FLAGS = (Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                     | Qt.Tool | Qt.BypassWindowManagerHint)

    MAG_ZOOM = 9                      # 放大倍数（整数，保证像素格对齐）
    MAG_CELL = 15                     # 放大镜覆盖的源像素数（奇数，有正中心像素）
    MAG_SIZE = MAG_CELL * MAG_ZOOM    # 放大镜边长 135（屏幕像素）


    def screens_and_geometry() -> tuple:
        """返回 (所有屏幕, 虚拟桌面逻辑矩形)。"""
        screens = QGuiApplication.screens()
        geo = QRect()
        for s in screens:
            geo = geo.united(s.geometry()) if not geo.isNull() else s.geometry()
        return screens, geo


    def region_to_screen_pixels(region: QRect, screen_geo: QRect,
                                dpr: float) -> QRect:
        """把逻辑屏幕坐标的区域，换算成某块屏幕上抓屏图里的物理像素矩形。

        独立成纯函数便于测试（含负坐标的多屏布局、混合 DPI 都能算对）。
        """
        local = region.translated(-screen_geo.left(), -screen_geo.top())
        return QRect(int(round(local.x() * dpr)), int(round(local.y() * dpr)),
                     int(round(local.width() * dpr)),
                     int(round(local.height() * dpr)))


    def grab_logical_region(region: QRect) -> QPixmap:
        """按逻辑屏幕坐标抓一块区域：自动选中那块屏幕，并按它的 dpr 精确裁剪。

        多屏 + 混合 DPI 下这是唯一正确的做法（不能用主屏 dpr 去处理所有屏）。
        """
        screen = QGuiApplication.screenAt(region.center())
        if screen is None:                      # 区域中心不在任何屏上，退到主屏
            screen = QGuiApplication.primaryScreen()
        dpr = float(screen.devicePixelRatio() or 1.0)
        shot = screen.grabWindow(0)
        src = region_to_screen_pixels(region, screen.geometry(), dpr)
        out = shot.copy(src.intersected(shot.rect()))
        out.setDevicePixelRatio(dpr)
        return out


    def grab_screen(screen) -> QPixmap:
        """抓取一整块显示器；常规抓屏是空白/纯色时回退 PrintWindow。

        用于「全屏截图」与托盘里的「截取指定显示器」。
        """
        geo = screen.geometry()
        pix = grab_logical_region(geo)

        if not pixmap_is_blank(pix):
            return pix
        # 硬件加速 / 内容保护窗口（Citrix、远程桌面常见）：退到 PrintWindow。
        # 需要"桌面物理像素"坐标，所以要按该屏 dpr 换算。
        dpr = float(screen.devicePixelRatio() or 1.0)
        physical = QRect(int(round(geo.x() * dpr)), int(round(geo.y() * dpr)),
                         int(round(geo.width() * dpr)),
                         int(round(geo.height() * dpr)))
        alt = grab_region_printwindow(physical, dpr)
        if alt is not None and not pixmap_is_blank(alt):
            return alt
        return pix


    def grab_virtual_desktop() -> tuple[QPixmap, QRect]:
        """抓取所有屏幕拼成一张图，返回 (pixmap, 虚拟桌面逻辑矩形)。

        以参考 dpr（主屏）合成，每块屏按自己的 dpr 独立抓取后按逻辑位置摆放：
        单 DPI 环境下是像素精确的；混合 DPI 下次屏内容会按参考比例重采样
        （区域截图不受影响 —— 那条路径走 grab_logical_region，按屏精确裁剪）。
        """
        screens, geo = screens_and_geometry()
        if not screens:
            return QPixmap(), QRect()
        ref = float(QGuiApplication.primaryScreen().devicePixelRatio() or 1.0)
        big = QPixmap(int(geo.width() * ref), int(geo.height() * ref))
        big.setDevicePixelRatio(ref)
        big.fill(Qt.black)
        p = QPainter(big)
        for s in screens:
            shot = s.grabWindow(0)
            if shot.isNull():
                continue
            local = s.geometry().translated(-geo.left(), -geo.top())
            target = QRectF(local.x() * ref, local.y() * ref,
                            local.width() * ref, local.height() * ref)
            p.drawPixmap(target, shot, QRectF(shot.rect()))
        p.end()
        return big, geo


    class SnipperOverlay(QWidget):
        captured = Signal(QPixmap)
        region_selected = Signal(QRect)   # 逻辑屏幕坐标，滚动截图用
        point_selected = Signal(QPoint)   # 单击选一个点（如滚动条滑块）
        color_picked = Signal(QColor)
        cancelled = Signal()

        def __init__(self, mode: str = "region", screen=None):
            """mode: "region" 框选截图 | "color" 屏幕取色 | "scroll" 只选区 | "point" 选点

            screen: 该覆盖层负责的显示器。**每个显示器一个覆盖层实例** ——
            单个窗口横跨多显示器在 Windows 每显示器 DPI 下会被裁剪/缩放，直接不可用。
            """
            super().__init__(None, OVERLAY_FLAGS)
            self.mode = mode
            self.screen = screen or QGuiApplication.primaryScreen()
            self.setAttribute(Qt.WA_TranslucentBackground, False)
            self.setMouseTracking(True)
            self.setCursor(Qt.CrossCursor)
            self._bg: QPixmap | None = None
            self._img: QImage | None = None   # 取色用的缓存
            self._geo = QRect()
            self._origin = QPoint()
            self._current = QPoint()
            self._selecting = False
            self._active = False              # 是否处于截图会话中
            self._warmed = False
            # “选滚动条”模式：选区外遮罩、选区内鼠标穿透（能真的点到应用里的滚动条）
            self._point_local = QRect()
            self._point_pressed = False
            self._point_timer = QTimer(self)
            self._point_timer.setInterval(25)
            _ALL_OVERLAYS.add(self)   # 见文件头的注册表说明
            self._point_timer.timeout.connect(self._poll_point_click)

        def screen_geometry(self) -> QRect:
            """本覆盖层覆盖的显示器逻辑矩形。"""
            return self.screen.geometry()

        # ---------- 预热 ----------
        def warmup(self, hold_ms: int = 3000):
            """启动时预热窗口，消除"首次截图遮罩迟迟不出现"。

            实测（Windows）：进程内第一个置顶全屏窗口虽然很早 paintEvent 就画完了，
            但系统要好几秒才真正把它合成上屏（4~5 秒）；而一旦上屏过，之后每次
            show() 只要 ~0.3 秒。所以这里在启动时以**完全透明 + 鼠标穿透**的方式
            先上屏一次，代价在启动阶段付掉，用户第一次截图就是快的。

            透明（opacity=0）不会被合成进屏幕画面，因此也不会污染截图。
            """
            if self._warmed:
                return
            self._warmed = True
            self.setGeometry(self.screen.geometry())
            self.setAttribute(Qt.WA_TransparentForMouseEvents, True)
            self.setWindowOpacity(0.0)
            self.show()
            self.raise_()
            QTimer.singleShot(hold_ms, self._end_warmup)

        def _end_warmup(self):
            if self._active:          # 用户已经自己开始截图了，别去隐藏
                return
            self.hide()
            self.setWindowOpacity(1.0)
            self.setAttribute(Qt.WA_TransparentForMouseEvents, False)
            self._can_exclude = False      # 能否把自己排除在抓屏之外

        # ---------- 生命周期 ----------
        def start(self, mode: str | None = None):
            if mode:
                self.mode = mode
            # 万一在预热期间就开始截图：恢复正常不透明度并接收鼠标事件
            self.setWindowOpacity(1.0)
            self.setAttribute(Qt.WA_TransparentForMouseEvents, False)
            self._active = True
            self._selecting = False
            self._origin = QPoint(-1, -1)
            self._current = QPoint(-1, -1)
            self._geo = self.screen.geometry()
            # **必须"先抓屏、后显示"**。
            # 曾经为了降低首屏延迟改成"先显示遮罩、再抓屏"，靠
            # SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) 把遮罩排除在抓屏之外；
            # 但实测该排除在真实环境不可靠（Qt 的窗口带分层样式时会被忽略），
            # 结果抓到的整张图就是**我们自己的遮罩**（纯深色 + 蓝色选框边）——
            # 用户截出来的图全是废的。所以回到物理上不可能拍到自己的顺序：
            # 先抓本屏底图（多屏/混合 DPI 下按各自 dpr 裁剪才准确），再显示遮罩。
            with _dtimed("遮罩·抓底图", f"屏={self.screen.name()} "
                                        f"dpr={self.screen.devicePixelRatio()}"):
                self._bg = self.screen.grabWindow(0)
                self._img = self._bg.toImage() if not self._bg.isNull() else None
            _dlog("遮罩·抓底图结果", self.bg_report())
            if self._bg.isNull():
                self._ensure_bg()                      # 抓失败：兜底一张，别让流程断
            # 用显式几何 + show()，比 showFullScreen() 在多屏/首次显示时更可靠地铺满整屏
            with _dtimed("遮罩·显示窗口", f"geo={self._geo.width()}x"
                                         f"{self._geo.height()}"):
                self.setGeometry(self._geo)
                self.show()
                if self.geometry() != self._geo:
                    self.setGeometry(self._geo)   # 首次上屏尺寸不对时才再钉一次
                self.raise_()
                self.activateWindow()
                # 只有"本进程当前没有前台窗口"时才走原生抢前台 ——
                # 正常情况下这一步是白花钱（实测 SetWindowPos+SetForegroundWindow
                # +SetActiveWindow 三连是显示阶段的大头）。
                try:
                    from PySide6.QtWidgets import QApplication
                    need_force = QApplication.activeWindow() is None
                except Exception:                      # noqa: BLE001
                    need_force = True
                if need_force:
                    try:

                        _dlog("遮罩·抢前台", "无前台窗口，启用原生抢前台")
                        force_foreground(int(self.winId()))
                    except Exception:                  # noqa: BLE001
                        pass
            # 注意：这里不能用 repaint() —— 对尚未映射完成的窗口强制同步绘制后，
            # Qt 不会再补一次绘制，窗口就会"在但没画出来"（动一下鼠标才出现）。
            self.update()
            for delay in (0, 120):           # 兜底两次即可（原来三次，纯属多花时间）
                QTimer.singleShot(delay, self._ensure_cover)

        def bg_report(self) -> str:
            """底图自检信息（写进诊断日志，方便确认有没有拍到自己/抓成空白）。"""
            try:
                if self._bg is None or self._bg.isNull():
                    return "底图=空"
                img = self._bg.toImage()
                w, h = img.width(), img.height()
                colors = set()
                total = n = 0
                for y in range(0, h, max(1, h // 12)):
                    for x in range(0, w, max(1, w // 12)):
                        c = img.pixelColor(x, y)
                        colors.add(c.name())
                        total += c.red() + c.green() + c.blue()
                        n += 1
                avg = int(total / (n * 3)) if n else -1
                return (f"底图={w}x{h} 平均亮度={avg} 采样色数={len(colors)}"
                        + ("（疑似纯色/拍到自己！）" if len(colors) <= 2 else ""))
            except Exception:                          # noqa: BLE001
                return "底图=自检失败"

        def _ensure_bg(self):
            """确保底图已经就绪；没有就地抓一次，实在抓不到也要给一张兜底的。

            交互（框选/取色）需要底图；"先显示遮罩、后抓屏"期间底图是空的，
            这里保证不会因为底图没到就把用户的操作全部忽略（那会表现成遮罩没反应）。
            """
            if self._bg is not None and not self._bg.isNull():
                return self._bg
            try:
                self._bg = self.screen.grabWindow(0)
            except Exception:                          # noqa: BLE001
                self._bg = None
            if self._bg is None or self._bg.isNull():
                # 兜底：纯色图，保证后续交互不会因为 None 崩掉/被忽略
                pm = QPixmap(self._geo.size() if self._geo.isValid()
                             else self.size())
                pm.fill(QColor(24, 26, 32))
                pm.setDevicePixelRatio(self.devicePixelRatioF() or 1.0)
                self._bg = pm
            self._img = self._bg.toImage()
            self.update()
            return self._bg


        def finish(self):
            """结束本次截图会话：隐藏窗口但保留原生窗口，下次截图更快。"""
            _dlog("遮罩·收起", f"屏={self.screen.name()} active={self._active} "
                              f"visible={self.isVisible()}")
            self._point_timer.stop()
            self._clear_mask()
            self._point_local = QRect()
            self._active = False
            self._selecting = False
            self._bg = None
            self._img = None
            self.hide()

        # ---------- 选滚动条：选区外遮罩 + 选区内可点击 ----------
        def set_point_hole(self, region_global: QRect):
            """把选区"挖空"：外面继续遮罩，里面鼠标穿透 —— 用户能真的点到滚动条。

            用窗口 mask 实现：窗口在 mask 之外的区域既不绘制也不接收鼠标，
            事件自然落到下面的应用上。
            """
            local = region_global.translated(-self._geo.left(),
                                             -self._geo.top()).intersected(self.rect())
            self._point_local = local
            if local.width() > 2 and local.height() > 2:
                self.setMask(QRegion(self.rect()).subtracted(QRegion(local)))
            else:
                self._clear_mask()            # 与这块屏没有交集：整屏遮罩
            self._point_pressed = False
            self._active = True
            self._point_timer.start()
            self.update()

        def _clear_mask(self):
            if not self.mask().isEmpty():
                self.setMask(QRegion())

        def _poll_point_click(self):
            """在选区内轮询真实左键按下（因为选区内事件被穿透给了应用）。"""
            if not self._active or self.mode != "point":
                self._point_timer.stop()
                return
            try:
                pressed = bool(user32.GetAsyncKeyState(VK_LBUTTON) & 0x8000)
            except Exception:                     # noqa: BLE001
                pressed = False
            if pressed and not self._point_pressed:
                self._point_pressed = True
                pos = QCursor.pos()
                if self._point_local.contains(pos - self._geo.topLeft()):
                    self._point_timer.stop()
                    self._clear_mask()
                    self.finish()
                    self.point_selected.emit(pos)
            elif not pressed:
                self._point_pressed = False

        def _ensure_cover(self):
            _dlog("遮罩·铺满兜底", f"active={self._active} "
                                  f"visible={self.isVisible()} "
                                  f"bg={'有' if self._bg is not None else '无'}")
            """兜底：确保覆盖层真的铺满并且是画出来的。

            注意：**不能**因为 _bg 还没抓回来就跳过 —— 抓屏是延后做的（先显示遮罩、
            后抓底图），这里要是等 _bg，头几帧的兜底就全空转了，多屏/缩放下遮罩
            可能压根没铺好（曾因此表现成"遮罩卡住不动"）。
            """
            if not self._active or not self.isVisible():
                return
            if self.geometry() != self._geo:
                self.setGeometry(self._geo)
            self.raise_()
            self.update()

        def closeEvent(self, e):
            self._point_timer.stop()
            self._clear_mask()
            self._active = False
            self._bg = None
            self._img = None
            super().closeEvent(e)

        def color_at(self, logical_pos: QPoint) -> QColor:
            """读取覆盖层逻辑坐标处的颜色。"""
            if self._img is None:
                return QColor()
            dpr = self._bg.devicePixelRatio()
            x = int(logical_pos.x() * dpr)
            y = int(logical_pos.y() * dpr)
            if 0 <= x < self._img.width() and 0 <= y < self._img.height():
                return self._img.pixelColor(x, y)
            return QColor()

        # ---------- 交互 ----------
        def mousePressEvent(self, e):
            if not self._active:                       # 已结束：忽略残留事件
                return
            # 右键/取消必须**永远**能用，不能因为底图还没抓回来就失灵
            if e.button() == Qt.RightButton:
                self._cancel()
                return
            if e.button() != Qt.LeftButton:
                return
            self._ensure_bg()                          # 底图没到就补上，别忽略操作
            if self.mode == "color":
                color = self.color_at(e.position().toPoint())
                if color.isValid():
                    self.color_picked.emit(color)
                self.finish()
                return
            if self.mode == "point":
                # 选区内的点击会被穿透给应用（由 _poll_point_click 轮询捕获），
                # 落在遮罩区的左键一律忽略，避免误当成滑块位置。
                return
            self._origin = e.position().toPoint()
            self._current = self._origin
            self._selecting = True
            self.update()

        def mouseMoveEvent(self, e):
            if not self._active:
                return
            if self._bg is None:
                return                                 # 还没按下去，等底图即可
            self._current = e.position().toPoint()
            self.update()

        def mouseReleaseEvent(self, e):
            if (not self._active or e.button() != Qt.LeftButton
                    or not self._selecting):
                return
            self._ensure_bg()                          # 保证有底图可裁
            self._selecting = False
            rect = QRect(self._origin, self._current).normalized().intersected(self.rect())
            if rect.width() < 6 or rect.height() < 6:
                self.update()
                return
            dpr = self._bg.devicePixelRatio()
            img_rect = QRect(int(rect.x() * dpr), int(rect.y() * dpr),
                             int(rect.width() * dpr), int(rect.height() * dpr))
            # 滚动截图只需要选区坐标：绝不能同时发 captured，
            # 否则宿主会当成普通截图去打开/前置编辑器，正好盖住要滚动的区域。
            if self.mode == "scroll":
                self.finish()
                self.region_selected.emit(rect.translated(self._geo.topLeft()))
                return

            result = self._bg.copy(img_rect)
            result.setDevicePixelRatio(dpr)
            # 常规抓屏拿不到内容时（远程桌面/虚拟化应用的硬件加速或内容保护），
            # 用 PrintWindow 让目标窗口自己渲染一遍再试一次
            try:

                if looks_like_missing_content(result):
                    phys = QRect(int((rect.x() + self._geo.x()) * dpr),
                                 int((rect.y() + self._geo.y()) * dpr),
                                 img_rect.width(), img_rect.height())
                    alt = grab_region_printwindow(phys, dpr)
                    if alt is not None and not looks_like_missing_content(alt):
                        result = alt
            except Exception:                     # noqa: BLE001
                pass                              # 回退失败就用原图
            self.finish()              # 先隐藏再来发信号，避免处理期间残留事件重入
            # 逻辑屏幕坐标（供滚动截图等需要屏幕位置的调用方）
            self.region_selected.emit(rect.translated(self._geo.topLeft()))
            self.captured.emit(result)

        def keyPressEvent(self, e):
            if e.key() == Qt.Key_Escape:
                self._cancel()

        def _cancel(self):
            if not self._active:
                return
            self.finish()
            self.cancelled.emit()

        # ---------- 绘制 ----------
        def paintEvent(self, e):
            p = QPainter(self)
            has_bg = self._bg is not None and not self._bg.isNull()
            if has_bg:
                p.drawPixmap(0, 0, self._bg)
            else:
                p.fillRect(self.rect(), QColor(24, 26, 32))   # 抓图失败也要有遮罩

            if self.mode == "point":
                # 选滚动条：窗口 mask 已经"挖空"了选区，绘制只会落在遮罩区
                p.fillRect(self.rect(), MASK_COLOR)
                rect = self._point_local
                if rect.width() > 2 and rect.height() > 2:
                    p.setBrush(Qt.NoBrush)
                    p.setPen(QPen(QColor(61, 139, 253), 3))
                    p.drawRect(rect.adjusted(-3, -3, 2, 2))
                    p.setPen(QPen(QColor(61, 139, 253, 90), 1, Qt.DashLine))
                    p.drawLine(0, rect.center().y(), max(0, rect.left()),
                               rect.center().y())
                    p.drawLine(rect.right(), rect.center().y(), self.width(),
                               rect.center().y())
                self._draw_hint(p, self._hint_anchor(rect))
                return

            # 取色模式不压暗（保证看到的颜色真实），其余模式整体压暗
            if self.mode != "color":
                p.fillRect(self.rect(), MASK_COLOR)

            rect = QRect(self._origin, self._current).normalized().intersected(self.rect())
            selecting = (self.mode in ("region", "scroll") and self._selecting
                         and rect.width() >= 2 and rect.height() >= 2)
            if selecting:
                # 选区内恢复原图亮度（源矩形必须夹在图像范围内，否则 drawPixmap 抛异常）
                if has_bg:
                    dpr = self._bg.devicePixelRatio()
                    src = QRect(int(rect.x() * dpr), int(rect.y() * dpr),
                                int(rect.width() * dpr), int(rect.height() * dpr))
                    src = src.intersected(self._bg.rect())
                    if not src.isEmpty():
                        p.drawPixmap(QRectF(rect), self._bg, QRectF(src))
                self._draw_guides(p, rect)
                self._draw_selection_border(p, rect)
                self._draw_size_label(p, rect)
            else:
                # 未开始拖拽：用全屏十字准线告诉用户当前落点
                self._draw_crosshair(p, self._current)

            if has_bg:                       # 预热显示等场景下 _bg 可能为空
                self._draw_magnifier(p, self._current)
            self._draw_hint(p)

        # ---------- 选区视觉强化 ----------
        def _draw_guides(self, p: QPainter, rect: QRect):
            """把选区四条边延伸到全屏，方便看清边界对齐到了哪里。"""
            pen = QPen(QColor(61, 139, 253, 170), 1, Qt.DashLine)
            p.setPen(pen)
            p.drawLine(0, rect.top(), self.width(), rect.top())
            p.drawLine(0, rect.bottom(), self.width(), rect.bottom())
            p.drawLine(rect.left(), 0, rect.left(), self.height())
            p.drawLine(rect.right(), 0, rect.right(), self.height())

        def _draw_crosshair(self, p: QPainter, pos: QPoint):
            if pos.x() < 0 or pos.y() < 0:
                return
            p.setPen(QPen(QColor(61, 139, 253, 150), 1))
            p.drawLine(0, pos.y(), self.width(), pos.y())
            p.drawLine(pos.x(), 0, pos.x(), self.height())

        def _draw_selection_border(self, p: QPainter, rect: QRect):
            """外白内蓝双描边 + 四角把手：任何背景色下都清晰可见。"""
            p.setBrush(Qt.NoBrush)
            p.setPen(QPen(QColor(255, 255, 255, 220), 1))
            p.drawRect(rect.adjusted(0, 0, -1, -1))
            p.setPen(QPen(QColor(61, 139, 253), 2))
            p.drawRect(rect.adjusted(1, 1, -2, -2))
            # 四角把手
            hs = 5
            p.setPen(QPen(QColor(255, 255, 255), 1))
            p.setBrush(QColor(61, 139, 253))
            for cx, cy in [(rect.left(), rect.top()), (rect.right(), rect.top()),
                           (rect.left(), rect.bottom()), (rect.right(), rect.bottom())]:
                p.drawRect(QRect(cx - hs // 2, cy - hs // 2, hs, hs))

        def _draw_size_label(self, p: QPainter, rect: QRect):
            text = f"{rect.width()} × {rect.height()}"
            font = p.font()
            font.setPixelSize(13)
            font.setBold(True)
            p.setFont(font)
            metrics = p.fontMetrics()
            w = metrics.horizontalAdvance(text) + 18
            h = metrics.height() + 10
            below = rect.top() - h - 6 <= 0
            x = rect.left()
            y = rect.bottom() + 6 if below else rect.top() - h - 6
            x = min(max(0, x), self.width() - w)
            y = min(max(0, y), self.height() - h)
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(15, 17, 22, 225))
            p.drawRoundedRect(x, y, w, h, 5, 5)
            p.setPen(QPen(QColor(61, 139, 253), 1))
            p.drawRoundedRect(x, y, w, h, 5, 5)
            p.setPen(QColor(255, 255, 255))
            p.drawText(QRect(x, y, w, h), Qt.AlignCenter, text)
            p.setFont(QFont())

        def _draw_magnifier(self, p: QPainter, pos: QPoint):
            dpr = self._bg.devicePixelRatio()
            half = MAG_CELL // 2
            src = QRect(int((pos.x() - half) * dpr), int((pos.y() - half) * dpr),
                        int(MAG_CELL * dpr), int(MAG_CELL * dpr))
            # 放大镜位置：光标右下，越界则翻转到左上
            mx = pos.x() + 18
            my = pos.y() + 18
            if mx + MAG_SIZE > self.width() - 4:
                mx = pos.x() - MAG_SIZE - 18
            if my + MAG_SIZE > self.height() - 4:
                my = pos.y() - MAG_SIZE - 18
            target = QRect(mx, my, MAG_SIZE, MAG_SIZE)
            p.save()
            p.setClipRect(target)
            p.fillRect(target, QColor(40, 40, 40))
            # 源区域夹取到图像内，并同步修正目标子矩形（靠近屏幕边缘时）
            clamped = src.intersected(self._bg.rect())
            if not clamped.isEmpty():
                scale = MAG_SIZE / src.width()
                sub = QRectF(mx + (clamped.x() - src.x()) * scale,
                             my + (clamped.y() - src.y()) * scale,
                             clamped.width() * scale, clamped.height() * scale)
                p.drawPixmap(sub, self._bg, QRectF(clamped))
            # 网格线（整数格宽，逐像素对齐）
            p.setPen(QPen(QColor(255, 255, 255, 40), 1))
            for i in range(1, MAG_CELL):
                p.drawLine(mx + i * MAG_ZOOM, my, mx + i * MAG_ZOOM, my + MAG_SIZE)
                p.drawLine(mx, my + i * MAG_ZOOM, mx + MAG_SIZE, my + i * MAG_ZOOM)
            p.restore()
            p.setPen(QPen(QColor(255, 255, 255), 2))
            p.setBrush(Qt.NoBrush)
            p.drawRect(target)
            # 红框标出真正取样的中心像素（与 color_at 取样点一致）
            half = MAG_CELL // 2
            p.setPen(QPen(QColor(229, 57, 53), 2))
            p.drawRect(mx + half * MAG_ZOOM, my + half * MAG_ZOOM,
                       MAG_ZOOM, MAG_ZOOM)
            self._draw_color_label(p, pos, mx, my)

        def _hint_anchor(self, rect: QRect) -> QPoint:
            """给提示条挑一个落在遮罩区的位置（选区内部是穿透的，画在那看不见）。"""
            w = self.width()
            if rect.top() > 60:                     # 选区上方有空间
                return QPoint((w - 420) // 2, max(8, rect.top() - 56))
            if rect.bottom() < self.height() - 70:  # 选区下方有空间
                return QPoint((w - 420) // 2, rect.bottom() + 12)
            return QPoint((w - 420) // 2, 24)

        def _draw_hint(self, p: QPainter, anchor: QPoint | None = None):
            """提示条：明确告知当前模式和退出方式，避免看起来像卡死。"""
            if self.mode == "color":
                text = tr("屏幕取色：单击复制色值    ·    Esc / 右键 取消")
            elif self.mode == "scroll":
                text = tr("拖拽选择要滚动截图的区域    ·    Esc / 右键 取消")
            elif self.mode == "point":
                text = tr("蓝框内可直接点击滚动条【滑块】→ 自动开始滚动    ·    Esc 取消")
            else:
                text = tr("拖拽选择截图区域    ·    Esc / 右键 取消")
            metrics = p.fontMetrics()
            w = metrics.horizontalAdvance(text) + 36
            h = metrics.height() + 16
            x = (self.width() - w) // 2
            y = 24
            if anchor is not None:
                x = min(max(4, anchor.x()), max(4, self.width() - w - 4))
                y = anchor.y()
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(0, 0, 0, 190))
            p.drawRoundedRect(x, y, w, h, 8, 8)
            p.setPen(QColor(235, 238, 242))
            p.drawText(QRect(x, y, w, h), Qt.AlignCenter, text)

        def _draw_color_label(self, p: QPainter, pos: QPoint, mx: int, my: int):
            """在放大镜下方显示光标处的色值。"""
            color = self.color_at(pos)
            if not color.isValid():
                return
            text = color.name().upper()
            rgb = f"{color.red()},{color.green()},{color.blue()}"
            metrics = p.fontMetrics()
            w = max(metrics.horizontalAdvance(text), metrics.horizontalAdvance(rgb)) + 14
            h = metrics.height() * 2 + 10
            x = mx
            y = my + MAG_SIZE + 6
            if y + h > self.height() - 4:
                y = my - h - 6
            p.setPen(Qt.NoPen)
            p.setBrush(QColor(0, 0, 0, 190))
            p.drawRoundedRect(x, y, w, h, 4, 4)
            # 色块
            p.setBrush(color)
            p.drawRect(x + 4, y + 5, metrics.height() - 2, metrics.height() - 2)
            p.setPen(QColor(255, 255, 255))
            p.drawText(x + 8 + metrics.height(), y + 5 + metrics.ascent(), text)
            p.drawText(QRect(x, y + metrics.height() + 5, w, metrics.height() + 5),
                       Qt.AlignCenter, rgb)


    # ========================================================================
    # 来自 scroller.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """滚动长截图：选区后自动向下滚动，逐帧截取并按重叠像素拼接。

    工作流程
    ========
    1. 用户在覆盖层框选一个可滚动区域（如浏览器页面）
    2. ScrollCapture 启动：抓取首帧 → 发送滚轮滚动 → 等待渲染 → 再抓帧
    3. 每帧与上一帧做重叠匹配，算出本次滚动的像素数 s，把新帧底部 s 行拼上去
    4. 连续几帧没有新内容（滚到底）或用户点"停止"时结束，交给编辑器

    拼接核心是纯函数 find_scroll()，可离屏单测。
    """
    import ctypes
    import ctypes.wintypes
    import os
    from pathlib import Path

    from PySide6.QtCore import (QEventLoop, QObject, QPoint, QRect, Qt, QTimer, Signal)
    from PySide6.QtGui import QColor, QCursor, QGuiApplication, QImage, QPainter, QPen, QPixmap
    from PySide6.QtWidgets import QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget

    # 诊断日志（顶层导入：单文件合并时本地导入行会被删，
    # 绝不能用 try/except 包着导入，否则留下空 try 块 → 语法错误）
    _dlog = log

    MOUSEEVENTF_WHEEL = 0x0800
    user32 = ctypes.windll.user32          # 提到模块级，便于测试打桩


    def _sleep_ms(ms: int):
        """等待若干毫秒，同时保持界面响应（处理事件）。"""
        loop = QEventLoop()
        QTimer.singleShot(ms, loop.quit)
        loop.exec()


    # ---------------------------------------------------------------- 图像帧
    # 不依赖 numpy：一帧 = "每行 RGB 字节"的列表。纯 Python 足够快，
    # 而且"行哈希投票"找重叠对静态界面截图比逐像素差值更准。

    class Frame:
        __slots__ = ("rows", "w", "h", "dpr")

        def __init__(self, rows, w: int, h: int, dpr: float = 1.0):
            self.rows = rows            # [bytes, ...]，每行 w*3 字节
            self.w = w
            self.h = h
            self.dpr = dpr

        @classmethod
        def from_array(cls, arr) -> "Frame":
            """测试用：从 numpy 数组构造。"""
            h, w = int(arr.shape[0]), int(arr.shape[1])
            return cls([arr[y].tobytes() for y in range(h)], w, h, 1.0)

        def copy(self) -> "Frame":
            return Frame(list(self.rows), self.w, self.h, self.dpr)


    def _as_frame(x) -> Frame:
        """接受 Frame 或（测试用的）numpy 数组。"""
        if isinstance(x, Frame):
            return x
        if hasattr(x, "shape") and hasattr(x, "__getitem__"):
            return Frame.from_array(x)
        raise TypeError(f"需要 Frame 或数组，收到 {type(x).__name__}")


    def _crop_rows(fr: Frame, top: int, bpad: int) -> Frame:
        """裁掉上下各若干行（用于丢掉不随内容滚动的工具栏/列头/固定面板）。"""
        rows = fr.rows[top:fr.h - bpad] if bpad else fr.rows[top:]
        return Frame(rows, fr.w, len(rows), fr.dpr)


    def _crop_cols(fr: Frame, left: int, right: int) -> Frame:
        """只保留 [left, right) 这些列（用于丢掉不随内容滚动的侧栏）。"""
        b0, b1 = left * 3, right * 3
        rows = [r[b0:b1] for r in fr.rows]
        return Frame(rows, max(0, right - left), fr.h, fr.dpr)


    def pixmap_to_frame(pix: QPixmap) -> Frame:
        """QPixmap → Frame（只做一次拷贝）。"""
        img = pix.toImage().convertToFormat(QImage.Format_RGB888)
        w, h, bpl = img.width(), img.height(), img.bytesPerLine()
        data = bytes(img.constBits())
        rows = [data[y * bpl: y * bpl + w * 3] for y in range(h)]
        return Frame(rows, w, h, float(pix.devicePixelRatio() or 1.0))


    def frame_to_pixmap(frame: Frame, dpr: float | None = None) -> QPixmap:
        """Frame → QPixmap。"""
        data = b"".join(frame.rows)
        img = QImage(data, frame.w, frame.h, frame.w * 3,
                     QImage.Format_RGB888).copy()
        pix = QPixmap.fromImage(img)
        pix.setDevicePixelRatio(frame.dpr if dpr is None else dpr)
        return pix


    def frame_diff(a: Frame, b: Frame, row_step: int = 4, col_step: int = 4) -> float:
        """两帧的平均绝对差（抽样），用于判断画面是否已稳定。"""
        if a.h != b.h or a.w != b.w:
            return float("inf")
        total = n = 0
        for y in range(0, a.h, row_step):
            ra, rb = a.rows[y], b.rows[y]
            for x in range(0, a.w * 3, col_step * 3):
                total += abs(ra[x] - rb[x]) + abs(ra[x + 1] - rb[x + 1]) \
                    + abs(ra[x + 2] - rb[x + 2])
                n += 3
        return total / max(1, n)


    # ---- 兼容旧测试/诊断的 numpy 辅助（延迟导入，运行期完全不碰 numpy） ----

    def pixmap_to_array(pix: QPixmap):
        """仅供测试/诊断：转成 numpy 数组（应用本身不使用）。"""
        import numpy as np
        img = pix.toImage().convertToFormat(QImage.Format_RGB888)
        w, h = img.width(), img.height()
        arr = np.frombuffer(img.constBits(), np.uint8, img.sizeInBytes())
        return arr.reshape(h, img.bytesPerLine())[:, : w * 3].reshape(h, w, 3).copy()


    def array_to_pixmap(arr, dpr: float = 1.0) -> QPixmap:
        """仅供测试/诊断：numpy 数组转 QPixmap。"""
        import numpy as np
        arr = np.ascontiguousarray(arr)
        h, w, _ = arr.shape
        img = QImage(arr.data, w, h, w * 3, QImage.Format_RGB888).copy()
        pix = QPixmap.fromImage(img)
        pix.setDevicePixelRatio(dpr)
        return pix


    def _same_ratio(prev: Frame, cur: Frame, s: int, rows: int = 140) -> float:
        """重叠区域中"逐字节完全相同的行"占比（只做 bytes 比较，极快）。"""
        span = prev.h - s
        if span <= 0:
            return 0.0
        step = max(1, span // rows)
        same = total = 0
        for y in range(0, span, step):
            total += 1
            if prev.rows[s + y] == cur.rows[y]:
                same += 1
        return same / max(1, total)


    def _match_stats(prev: Frame, cur: Frame, s: int,
                     rows: int = 140, col_step: int = 6) -> tuple:
        """返回 (完全相同行占比, 平均像素差)。只有需要时才调用（较慢）。"""
        return _same_ratio(prev, cur, s, rows), _overlap_diff(prev, cur, s)


    def _overlap_diff(prev: Frame, cur: Frame, s: int,
                      row_step: int = 4, col_step: int = 6) -> float:
        """重叠区域的平均绝对差（稀疏抽样，仅作兜底判断）。"""
        total = n = 0
        for y in range(0, prev.h - s, row_step):
            a = prev.rows[s + y]
            b = cur.rows[y]
            if a == b:
                continue
            for x in range(0, len(a), col_step * 3):
                total += abs(a[x] - b[x]) + abs(a[x + 1] - b[x + 1]) \
                    + abs(a[x + 2] - b[x + 2])
                n += 3
        return total / max(1, n) if n else 0.0


    # ---------------------------------------------------------------- 抗噪匹配
    # 背景：Citrix HDX / 远程桌面 / 硬件解码送过来的是**有损**画面 —— 同一行每帧
    # 都被重新编码，字节不可能完全一样。原来的匹配是"整行字节哈希投票"，
    # 于是有损源一行都对不上、连候选都提不出来，只能报"画面内容变化过快"。
    # 下面这组用**分块均值 + 粗量化**做行的签名：编码噪声（±10 量级）落在同一个
    # 量化台阶里，签名不变，而真正不同的内容仍会区分开。
    def _row_key(rows: bytes, blocks: int = 12, quant: int = 24) -> tuple:
        """一行的抗噪签名：按列分块取绿色通道均值，再粗量化。"""
        n = len(rows)
        if n <= 0:
            return ()
        step = max(1, n // blocks)
        out = []
        for b in range(0, n, step):
            chunk = rows[b:b + step]
            cnt = 0
            total = 0
            for i in range(1, len(chunk), 3):          # 绿色通道足够、还省 2/3 计算
                total += chunk[i]
                cnt += 1
            out.append(int((total / cnt if cnt else 0) // quant))
        return tuple(out)


    def _frame_keys(frame: Frame, blocks: int = 12, quant: int = 24) -> list:
        """整帧每行的签名（每帧只算一次，供多个候选复用）。"""
        return [_row_key(frame.rows[r], blocks, quant) for r in range(frame.h)]


    def _vote_by_keys(pk: list, ck: list, min_overlap: int,
                      top_candidates: int = 6) -> dict:
        """按签名投票找候选位移（结构同精确哈希投票，但容忍编码噪声）。"""
        idx = {}
        for r, k in enumerate(ck):
            idx.setdefault(k, []).append(r)
        votes = {}
        H = len(pk)
        for r, k in enumerate(pk):
            for rc in idx.get(k, ())[:6]:
                d = r - rc
                if 0 <= d <= H - min_overlap:
                    votes[d] = votes.get(d, 0) + 1
        return votes


    def _same_ratio_keys(pk: list, ck: list, s: int, rows: int = 140) -> float:
        """重叠区域里"签名相同"的行占比（抗噪版的置信度）。"""
        span = len(pk) - s
        if span <= 0:
            return 0.0
        step = max(1, span // rows)
        same = total = 0
        for y in range(0, span, step):
            total += 1
            if pk[s + y] == ck[y]:
                same += 1
        return same / max(1, total)


    def _best_offset_and_ratio(prev: Frame, cur: Frame, min_overlap: int,
                               top_candidates: int = 6) -> tuple:
        """行哈希投票 + 精修 + **抗噪签名兜底**。

        返回 (最佳位移, 相同行占比, 抗噪签名占比)；位移 -1 表示没候选。
        第三个值用于有损画面（Citrix/远程桌面）：那里精确占比上不去，
        但签名占比能到 0.6 以上，可据此判定匹配成功。
        """
        H = prev.h
        sig_cur = {}
        for r in range(H):
            sig_cur.setdefault(hash(cur.rows[r]), []).append(r)
        votes = {}
        for r in range(H):
            for rc in sig_cur.get(hash(prev.rows[r]), ())[:6]:
                s = r - rc
                if 0 <= s <= H - min_overlap:
                    votes[s] = votes.get(s, 0) + 1
        if not votes:
            votes = {}
        candidates = [s for s, _ in
                      sorted(votes.items(), key=lambda kv: -kv[1])[:top_candidates]]
        if 0 not in candidates:
            candidates.append(0)

        def best_of(cands):
            ratios = [(s, _same_ratio(prev, cur, s)) for s in cands]
            top = max(r for _, r in ratios)
            tied = [s for s, r in ratios if r >= top - 1e-9]
            if len(tied) > 1:      # 打平时用像素差细分（最多 3 个，避免慢路径）
                scored = [(s, _overlap_diff(prev, cur, s)) for s in tied[:3]]
                return min(scored, key=lambda kv: kv[1])[0], top
            return tied[0], top

        if not candidates:                     # 精确哈希一个候选都没有
            best_s, best_same = -1, 0.0
        else:
            best_s, best_same = best_of(candidates)
            if best_s > 0:         # 精修 ±4，消除"行内容重复"带来的偏差
                cands = list(range(max(1, best_s - 4),
                                   min(H - min_overlap, best_s + 4) + 1))
                s2, same2 = best_of(cands)
                if same2 > best_same + 1e-9:
                    best_s, best_same = s2, same2

        # 精确匹配不够好（有损画面/编码噪声）→ 走抗噪签名再找一次
        key_ratio = 0.0
        if best_s < 0 or best_same < 0.5:
            pk, ck = _frame_keys(prev), _frame_keys(cur)
            kvotes = _vote_by_keys(pk, ck, min_overlap)
            if kvotes:
                kcands = [s for s, _ in sorted(kvotes.items(),
                                               key=lambda kv: -kv[1])[:top_candidates]]
                if 0 not in kcands:
                    kcands.append(0)

                def best_of_keys(cands_):
                    ratios = [(d, _same_ratio_keys(pk, ck, d)) for d in cands_]
                    top = max(r for _, r in ratios)
                    tied = [d for d, r in ratios if r >= top - 1e-9]
                    return (tied[0], top)

                kb, key_ratio = best_of_keys(kcands)
                if kb > 0:
                    kr = list(range(max(1, kb - 4), min(H - min_overlap, kb + 4) + 1))
                    kb2, kr2 = best_of_keys(kr)
                    if kr2 > key_ratio:
                        kb, key_ratio = kb2, kr2
                if key_ratio > best_same:
                    best_s, best_same = kb, key_ratio
        return best_s, best_same, key_ratio


    # ---------------------------------------------------------------- 条带匹配
    def _bands(prev: Frame, cur: Frame, strips: int = 6) -> list:
        """按竖直切分，返回**确实在动**的条带 [(byte_start, byte_end), ...]。

        完全静止的条带（标题栏/工具栏/侧边栏/滚动条所在的位置）必须剔除：
        它们每帧一模一样，会把最佳对齐死死锚在偏移 0，让真正的滚动算不出来。
        """
        W, H = prev.w, prev.h
        sw = max(8, W // strips)
        moving = []
        for i in range(strips):
            x0 = i * sw
            x1 = W if i == strips - 1 else min(W, x0 + sw)
            if x1 <= x0:
                continue
            b0, b1 = x0 * 3, x1 * 3
            # 整条带逐行比较（bytes 比较是 C 速度，很快）
            if all(prev.rows[r][b0:b1] == cur.rows[r][b0:b1] for r in range(H)):
                continue
            moving.append((b0, b1))
        return moving


    def _strip_offset(prev: Frame, cur: Frame, min_overlap: int,
                      strips: int = 6, blocks: int = 6, quant: int = 20,
                      top_candidates: int = 8, bands=None) -> tuple:
        """只在"在动"的条带上算位移。

        返回 (位移, 命中占比, 在动条带比例)；位移 -1 表示没算出来。
        """
        H = prev.h
        if bands is None:
            bands = _bands(prev, cur, strips)
        moving_ratio = len(bands) / max(1, strips)
        if not bands:
            return -1, 0.0, 0.0

        # 每个动条带的逐行签名 + **信息量权重**（算一次，后面反复用）
        # 权重：一行如果整行几乎同色（空白/分隔带），它在任何偏移下都"能对上"，
        # 拿它计分会让偏移 1、2、3… 都拿满分 —— 必须排除，只让有内容的行计分。
        def row_weight(row: bytes) -> int:
            """这一行"有没有内容"：看绿色通道采样点的明暗跨度。

            白底黑字的跨度极大（250 vs 35），空白行跨度接近 0。
            用跨度而不是"相邻点差异"：细文字行也能稳定判出来（之前稀疏采样
            会把细文字漏掉，导致权重全 0、条带结果被弃用）。
            """
            n = len(row)
            if n < 6:
                return 0
            lo, hi = 255, 0
            for i in range(1, n - 2, 12):          # 每 4 个像素取一个绿色通道
                v = row[i]
                if v < lo:
                    lo = v
                if v > hi:
                    hi = v
                if hi - lo > 26:
                    return 1
            return 0

        keys, weights = [], []
        for b0, b1 in bands:
            kp = [_row_key(prev.rows[r][b0:b1], blocks, quant) for r in range(H)]
            kc = [_row_key(cur.rows[r][b0:b1], blocks, quant) for r in range(H)]
            # 权重 = 有内容 **且** 这一行在该条带里确实变了。
            # 只按"有内容"是不够的：条带里还混着标题栏/列头这类静止行，
            # 它们在真位移处并不匹配，会把得分稀释掉。
            wt = [(row_weight(prev.rows[r][b0:b1])
                   if prev.rows[r][b0:b1] != cur.rows[r][b0:b1] else 0)
                  for r in range(H)]
            keys.append((kp, kc))
            weights.append(wt)

        # 投票：只统计动条带里的行
        votes = {}
        for kp, kc in keys:
            idx = {}
            for r, k in enumerate(kc):
                idx.setdefault(k, []).append(r)
            for r, k in enumerate(kp):
                for rc in idx.get(k, ())[:4]:
                    d = r - rc
                    if 0 <= d <= H - min_overlap:
                        votes[d] = votes.get(d, 0) + 1
        if not votes:
            return -1, 0.0, moving_ratio

        def score(d: int) -> float:
            """动条带上"有内容的行"里，签名相同者所占比例（空白行不计分）。"""
            tot = same = 0
            for (kp, kc), wt in zip(keys, weights):
                span = H - d
                if span <= 0:
                    continue
                for y in range(0, span):
                    if not wt[y + d]:
                        continue                   # 空白行不参与
                    tot += 1
                    if kp[y + d] == kc[y]:
                        same += 1
            return same / max(1, tot)

        cands = [d for d, _ in sorted(votes.items(), key=lambda kv: -kv[1])
                 [:top_candidates]]
        if 0 not in cands:
            cands.append(0)

        def rank(d: int):
            """先看加权命中率，再看票数 —— 票数能压住"空白行造成的假高分"。"""
            return (score(d), votes.get(d, 0))

        best_d = max(cands, key=rank)
        best_sc = score(best_d)
        if best_d > 0:                       # 精修 ±4
            fine = list(range(max(1, best_d - 4),
                              min(H - min_overlap, best_d + 4) + 1))
            fd = max(fine, key=rank)
            fs = score(fd)
            if fs > best_sc:
                best_d, best_sc = fd, fs
        return best_d, best_sc, moving_ratio


    def best_candidate_offset(prev, cur, min_overlap: int = 60) -> int:
        """不管置信度，返回匹配最好的候选位移（用于诊断"多块独立滚动区域"等场景）。"""
        prev, cur = _as_frame(prev), _as_frame(cur)
        if cur.h != prev.h or cur.w != prev.w:
            return -1
        return _best_offset_and_ratio(prev, cur, min_overlap)[0]


    def find_scroll(prev, cur, min_overlap: int = 60, thresh: float = 3.0,
                    loose_thresh: float = 12.0, top_candidates: int = 6,
                    min_same_ratio: float = 0.9) -> tuple[int, float]:
        """在 cur 中找 prev 向下滚动的像素数 s：prev[s:] 应与 cur[:H-s] 一致。

        算法：**先裁掉行方向静止边缘，再"行哈希投票定候选 + 行级精确比较定胜负"**。
        - 相同行占比最高者为胜（静态界面截图能到 1.0），比逐像素差值更准
        - 再在胜者 ±4 内精修，消除"行内容重复"带来的偏差
        - 成本与图幅无关（固定抽样行数），比逐像素扫描快一个量级

        返回 (s, 差异值)。s == 0 表示没变化（到底了）；s == -1 表示匹配失败。
        """
        prev, cur = _as_frame(prev), _as_frame(cur)
        H = prev.h
        if cur.h != H or cur.w != prev.w:
            return -1, float("inf")
        if prev.rows == cur.rows:            # 整帧相同 → 没滚动
            return 0, 0.0

        # 行方向也会混进静止外壳（工具栏/列头/固定明细面板）。实测 Citrix 选区
        # 660x380 里有 171 行是静止的 ribbon + 列头，占 39%：它们在 d>0 时必然不匹配，
        # 把真位移的命中率从 0.74 稀释到 0.29，反而让"没滚动"（d=0）拿到假高分。
        # 先裁掉上下静止边缘，只在真正会滚的那条带里对齐。
        top, bpad = static_strips(prev, cur)
        if top or bpad:
            if H - top - bpad >= max(min_overlap + 40, H // 3):
                prev, cur = _crop_rows(prev, top, bpad), _crop_rows(cur, top, bpad)
                H = prev.h

        # 先看竖条带：如果存在**完全静止的条带**，说明选区里混进了窗口外壳
        # （标题栏/工具栏/侧边栏/滚动条），此时全局匹配会被它们锚在错误的偏移上
        # （实测：整个窗口 1131x830 时全局给 0 或 10，真值是 252）。
        # 这种情况下直接以条带匹配为准。
        bands = _bands(prev, cur, 6)
        if 0 < len(bands) < 6:
            sd, ssc, _ = _strip_offset(prev, cur, min_overlap, bands=bands)
            if sd >= 0 and ssc >= 0.5:
                _dlog("滚动·条带匹配", f"静止条带 {6 - len(bands)}/6，"
                                      f"算得 s={sd}（占比 {ssc:.2f}）")
                return sd, 0.0

        best_s, best_same, key_ratio = _best_offset_and_ratio(prev, cur, min_overlap,
                                                              top_candidates)
        if best_s < 0:
            sd, ssc = find_scroll_strip(prev, cur, min_overlap)
            if sd >= 0 and ssc > 0:
                _dlog("滚动·条带匹配", f"全局对不上，条带算出 s={sd}（占比 {ssc:.2f}）")
                return sd, 0.0
            return -1, float("inf")
        if best_s == 0:
            # 全局说"没滚动"，但区域里混了静止外壳时全局会被带偏 ——
            # 先用条带匹配复核一次，有明确位移就以它为准。
            sd, ssc = find_scroll_strip(prev, cur, min_overlap)
            if sd > 0:
                _dlog("滚动·条带匹配", f"全局 s=0，条带算出 s={sd}（占比 {ssc:.2f}）")
                return sd, 0.0
            diff = _overlap_diff(prev, cur, 0)
            # "最佳对齐就是 0" = 画面没滚动。此时哪怕区域里有一小块在变
            # （时钟、光标、动画、Citrix 编码噪声），也不该判成"滚太多/对不上" ——
            # 那会让驱动以为跳太远而反复减半重试，最后报一个看不出真相的错。
            # 判据：多数行仍对齐（精确或抗噪签名任一到 0.5）就算"没滚动"。
            same0 = _same_ratio(prev, cur, 0)
            key0 = key_ratio if key_ratio > 0 else _same_ratio_keys(
                _frame_keys(prev), _frame_keys(cur), 0)
            if diff < thresh or same0 >= 0.5 or key0 >= 0.5:
                return 0, diff
            return -1, diff
        if best_same >= min_same_ratio:
            return best_s, 0.0
        diff = _overlap_diff(prev, cur, best_s)
        # 抗噪验收：有损源（Citrix HDX / 远程桌面）像素差天然偏大，
        # 但"签名相同的行占比"仍能到 0.6+ —— 用它判定命中，比死阈值可靠
        if key_ratio >= 0.6:
            return best_s, diff
        if diff < loose_thresh:
            return best_s, diff
        # "明显胜过'没滚动'这个竞争假设"也算命中：有损画面（Citrix HDX / 远程桌面）
        # 里精确占比上不了 0.9，滚动后每行还有半像素错位导致的编码噪声，
        # 逐像素差也超 12。此时只要真位移的占比**明显高于 d=0**，就是它了。
        # （实测 Citrix：真位移 0.87 vs d=0 的 0.47，而 diff=19.7 把死阈值顶掉了。）
        r_best = _same_ratio(prev, cur, best_s)
        r0 = _same_ratio(prev, cur, 0)
        if r_best >= 0.6 and r_best >= r0 + 0.15:
            _dlog("滚动·占优判定", f"d={best_s} 占比 {r_best:.2f} 明显高于 d=0 的 {r0:.2f}"
                                  f"（逐像素差 {diff:.1f} 偏大，按占优判为命中）")
            return best_s, diff
        return -1, diff


    def find_scroll_strip(prev, cur, min_overlap: int = 60,
                          strips: int = 6, min_score: float = 0.5,
                          min_moving: float = 0.15) -> tuple[int, float]:
        """**条带匹配**：区域里混有大块静止外壳（标题栏/工具栏/侧栏/滚动条）时用。

        返回 (s, 命中占比)；s == -1 表示没算出来。
        只在"在动"的竖条带上定位移，所以"框得太大"不再致命。
        """
        prev, cur = _as_frame(prev), _as_frame(cur)
        if cur.h != prev.h or cur.w != prev.w:
            return -1, 0.0
        d, sc, moving = _strip_offset(prev, cur, min_overlap, strips)
        if d < 0 or sc < min_score or moving < min_moving:
            return -1, sc
        return d, sc


    def static_strips(prev, cur, thresh: float = 3.0,
                      max_ratio: float = 0.45) -> tuple[int, int]:
        """检测两帧间静止的上/下边缘行数。

        用户框选的区域可能包含不随内容滚动的部分（窗口边框、固定工具栏、
        底部明细面板）。这类"静止条带"必须排除，否则每一帧都会把它们当新内容拼进去。
        max_ratio 放到 0.45：复杂业务界面（主列表 + 固定明细面板）里固定区域往往很高。
        """
        prev, cur = _as_frame(prev), _as_frame(cur)
        H = prev.h
        limit = max(1, int(H * max_ratio))

        def same(r: int) -> bool:
            a, b = prev.rows[r], cur.rows[r]
            if a == b:
                return True
            # 每 4 个像素比较一次（三通道都算），与原 numpy 版严格程度一致
            total = n = 0
            for x in range(0, len(a), 12):
                total += abs(a[x] - b[x]) + abs(a[x + 1] - b[x + 1]) \
                    + abs(a[x + 2] - b[x + 2])
                n += 3
            return total / max(1, n) < thresh

        top = 0
        while top < limit and same(top):
            top += 1
        bottom = 0
        while bottom < limit and same(H - 1 - bottom):
            bottom += 1
        return top, bottom


    def static_columns(prev, cur, thresh: float = 3.0, max_ratio: float = 0.5,
                       row_step: int = 7) -> tuple[int, int]:
        """检测两帧间静止的左/右边缘列数，返回 (左边静止列数, 右边静止列数)。

        和 static_strips（行方向）是一对：选区里混进**不随内容滚动的一列**时
        （Citrix 远程桌面左侧的导航树、网页的固定侧边栏、详情面板），
        每帧都会把它当新内容拼一次，长截图里就会出现重复的侧栏。
        逐列比较（抽样若干行），只有整列都没变过才算静止。
        """
        prev, cur = _as_frame(prev), _as_frame(cur)
        W, H = prev.w, prev.h
        if cur.w != W or cur.h != H:
            return 0, 0
        limit = max(1, int(W * max_ratio))
        rows = list(range(0, H, max(1, row_step)))
        if rows[-1] != H - 1:
            rows.append(H - 1)          # 保证最后一行的变化也能被发现

        def same(x: int) -> bool:
            b = x * 3
            for y in rows:
                a, c = prev.rows[y], cur.rows[y]
                if a[b] == c[b] and a[b + 1] == c[b + 1] and a[b + 2] == c[b + 2]:
                    continue
                total = abs(a[b] - c[b]) + abs(a[b + 1] - c[b + 1]) \
                    + abs(a[b + 2] - c[b + 2])
                if total / 3 >= thresh:
                    return False
            return True

        left = 0
        while left < limit and same(left):
            left += 1
        right = 0
        while right < limit and same(W - 1 - right):
            right += 1
        return left, right


    def content_band_residuals(prev, cur, s: int,
                               top: int, bottom: int, bands: int = 3) -> list:
        """在"已检测到的位移 s"下，检查内容区分成几带后是否都对得上。

        对不上（残差远大于其它带）说明那一带的滚动量和整体不一致 ——
        典型情况是选区里既有主列表又有固定/独立滚动的明细面板。
        返回每带的残差（无法判定的带为 None）。
        """
        prev, cur = _as_frame(prev), _as_frame(cur)
        out = []
        if bottom - top < 90 or s <= 0 or bands < 2:
            return out
        bands = min(bands, max(2, int((bottom - top) / (s * 1.3))))
        if (bottom - top) / bands <= s:          # 位移太大，分不了带
            return []
        step = max(1, (bottom - top) // bands)
        for i in range(bands):
            y0 = top + i * step
            y1 = bottom if i == bands - 1 else y0 + step
            if y1 - s <= y0:                     # 这一带装不下这个位移，跳过
                out.append(None)
                continue
            total = n = 0
            for y in range(y0, y1 - s, 4):
                a, b = prev.rows[y + s], cur.rows[y]
                if a == b:
                    continue
                for x in range(0, len(a), 12):
                    total += abs(a[x] - b[x]) + abs(a[x + 1] - b[x + 1]) \
                        + abs(a[x + 2] - b[x + 2])
                    n += 3
            out.append(total / max(1, n) if n else 0.0)
        return out


    # ---------------------------------------------------------------- 默认抓取/滚动

    def make_default_grab(region: QRect):
        """按逻辑屏幕坐标区域抓帧。

        多屏 / 混合 DPI 下必须按"区域所在的显示器"抓取并按该屏 dpr 裁剪
        （用主屏 dpr 去裁所有屏会错位）。若常规抓屏是空白/纯色（远程桌面、
        虚拟化应用常见），再回退到 PrintWindow 让目标窗口自己渲染一遍。
        """



        # 注意：用模块级已导入的 QGuiApplication（不要再局部 import），
        # 否则会绕过测试对 QGuiApplication 的打桩。
        def grab() -> QPixmap:
            out = grab_logical_region(region)
            if pixmap_is_blank(out):
                scr = QGuiApplication.screenAt(region.center()) \
                    or QGuiApplication.primaryScreen()
                dpr = float(scr.devicePixelRatio() or 1.0)
                src = region_to_screen_pixels(region, scr.geometry(), dpr)
                alt = grab_region_printwindow(src, dpr)
                if alt is not None and not pixmap_is_blank(alt):
                    return alt
            return out

        return grab


    def make_default_scroll(region: QRect, notches: int = 3):
        """把光标移到区域中心并发送滚轮事件（向下滚动）。"""
        user32 = ctypes.windll.user32

        def scroll():
            QCursor.setPos(region.center())
            user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, -120 * notches, 0)

        return scroll


    # ---------------------------------------------------------------- 滚动输入驱动

    MOUSEEVENTF_LEFTDOWN = 0x0002
    MOUSEEVENTF_LEFTUP = 0x0004
    KEYEVENTF_KEYUP = 0x0002
    VK_PAGEDOWN, VK_SPACE, VK_DOWN = 0x22, 0x20, 0x28

    # 各模式的"每单位输入能滚动多少内容像素"的初值与合理范围（会实测校准）
    _UNIT_DEFAULTS = {"wheel": 100.0, "drag": 3.0, "key": 420.0}
    _UNIT_BOUNDS = {"wheel": (5.0, 1500.0), "drag": (0.2, 400.0), "key": (20.0, 30000.0)}
    _PROBE_START = 4.0        # 拖拽模式首次试探的像素（长文档滑块行程短，必须从小往大试）
    _DRAG_MAX = 160.0         # 单次拖拽上限，避免一次把滑块拉到底


    def _send_vk(vk: int):
        user32.keybd_event(vk, 0, 0, 0)
        _sleep_ms(18)
        user32.keybd_event(vk, 0, KEYEVENTF_KEYUP, 0)


    def _drag_scrollbar(anchor: QPoint, dy: float, steps: int = 6):
        """在滚动条滑块上按住并向下拖拽 dy 像素（远程桌面里比滚轮可靠）。"""
        QCursor.setPos(anchor)
        _sleep_ms(30)
        user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        for i in range(1, steps + 1):
            QCursor.setPos(QPoint(anchor.x(), int(anchor.y() + dy * i / steps)))
            _sleep_ms(12)
        _sleep_ms(25)
        user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)


    class ScrollDriver:
        """把"想滚动多少内容像素"翻译成实际输入，并用实测位移自我校准。

        mode:
          wheel — 滚轮（默认；把光标移到区域中心后发滚轮）
          drag  — 在滚动条滑块上按住拖拽（远程桌面/Citrix 最可靠，步长可标定）
          key   — PageDown / 空格 / ↓（没有滚动条的应用）
        """

        def __init__(self, mode: str, region: QRect, anchor: QPoint | None = None,
                     key_vk: int = VK_PAGEDOWN):
            self.mode = mode
            self.region = QRect(region)
            self.anchor = QPoint(anchor) if anchor is not None else region.center()
            self.key_vk = key_vk
            self.px_per_unit = float(_UNIT_DEFAULTS.get(mode, 100.0))
            self.last_units = 0.0
            self.observations = 0
            self.moved_ever = False
            self.probe_px = _PROBE_START      # 拖拽模式：先用极小的步长试探
            self.probing = (mode == "drag")
            self.snapped = False              # 是否用系统接口校正过滑块位置
            self.native = None                # GetScrollInfo 可用时的原生滚动状态
            self.used_fallback = None         # 拖拽失效后自动降级到的模式

        # ---------- 前置 ----------
        def prepare(self):
            """开始前的准备。

            - 按键模式：把目标窗口拉到前台，否则按键会打到我们自己窗口
            - 拖拽模式：能读到原生滚动条状态就直接用 SetScrollInfo 设滚动位置
              （完全不动鼠标，绝对精准且不会溢出轨道）；读不到才用拖拽。
            """
            if self.mode == "key":
                try:

                    hwnd = window_at(self.region.center().x(), self.region.center().y())
                    if hwnd:
                        ctypes.windll.user32.SetForegroundWindow(ctypes.wintypes.HWND(hwnd))
                        _sleep_ms(120)
                except Exception:               # noqa: BLE001
                    pass
                return
            if self.mode != "drag":
                return
            try:
                from PySide6.QtGui import QGuiApplication

                dpr = 1.0
                scr = QGuiApplication.screenAt(self.anchor)
                if scr is not None:
                    dpr = float(scr.devicePixelRatio() or 1.0)
                ax, ay = int(self.anchor.x() * dpr), int(self.anchor.y() * dpr)
                # 先尽量找到可程序化滚动的窗口（比拖拽可靠得多）
                self.native = get_scroll_info_at(ax, ay)
                if self.native is not None:
                    return
                # 退而求其次：点偏了就把锚点校正到真实滑块中心
                thumb = scrollbar_thumb_at(ax, ay)
                if thumb is not None:
                    center = QPoint(int((thumb.left() + thumb.width() / 2) / dpr),
                                    int((thumb.top() + thumb.height() / 2) / dpr))
                    if (center - self.anchor).manhattanLength() <= 60:
                        self.anchor = center
                        self.snapped = True
            except Exception:                   # noqa: BLE001
                pass

        # ---------- 执行 ----------
        def __call__(self, step_px: float):
            units = step_px / max(0.05, self.px_per_unit)
            if self.mode == "wheel":
                notches = int(min(15, max(1, round(units))))
                self.last_units = float(notches)
                QCursor.setPos(self.region.center())
                user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, -120 * notches, 0)
            elif self.mode == "key":
                times = int(min(5, max(1, round(units))))
                self.last_units = float(times)
                for _ in range(times):
                    _send_vk(self.key_vk)
            else:                            # drag
                if self.native is not None:
                    # 原生滚动条：直接设滚动位置（不动鼠标，步长 = 视口的 45% 且绝对精准）
                    info = self.native
                    step_pos = max(1, int(info["page"] * 0.45))
                    new_pos = min(info["max"], info["pos"] + step_pos)
                    self.last_units = float(max(1, new_pos - info["pos"]))

                    set_scroll_pos(info["hwnd"], new_pos)
                    info["pos"] = new_pos
                    return
                if self.probing:
                    dy = self.probe_px
                else:
                    dy = float(min(_DRAG_MAX, max(4.0, units)))
                self.last_units = dy
                _drag_scrollbar(self.anchor, dy)
                # 关键：滑块已经被拖下去 dy，锚点必须跟着走。
                # 否则下一次会在原位置按下 —— 那里已经是轨道，变成翻页而不是继续拖拽。
                self.anchor = QPoint(self.anchor.x(), int(self.anchor.y() + dy))

        def recovery_after_jump(self) -> bool:
            """匹配失败（一次滚动太多，超出可拼接范围）时把步长改小再试。

            拖拽滚动条的"每像素滚动量"完全取决于内容长度（长文档滑块行程很短），
            事先无法得知，只能从小步试探并逐步收敛。最多试 4 次。
            """
            self._recovery_count = getattr(self, "_recovery_count", 0) + 1
            if self.observations >= 2 or self._recovery_count > 4:
                return False
            if self.mode == "drag":
                self.probing = True
                self.probe_px = max(1.5, self.probe_px / 2)
                self.px_per_unit = min(_UNIT_BOUNDS["drag"][1], self.px_per_unit * 2)
                return True
            lo, hi = _UNIT_BOUNDS.get(self.mode, (0.1, 10000.0))
            self.px_per_unit = min(hi, self.px_per_unit * 2)
            return True

        def observe(self, actual_px: int):
            """用实测位移校准"每单位输入滚动多少像素"。"""
            if self.last_units <= 0 or actual_px <= 0:
                return
            measured = actual_px / self.last_units
            lo, hi = _UNIT_BOUNDS.get(self.mode, (0.1, 10000.0))
            if not (lo <= measured <= hi):
                return                       # 明显被误匹配带偏，忽略这次
            weight = 0.6 if self.observations == 0 else 0.35
            self.px_per_unit = (1 - weight) * self.px_per_unit + weight * measured
            self.observations += 1
            if self.mode == "drag":
                self.probing = False         # 试探成功，之后按目标步长来

        def describe(self) -> str:
            return {"wheel": "滚轮", "drag": "拖拽滚动条", "key": "按键"}.get(self.mode, self.mode)


    # ---------------------------------------------------------------- 进度控制条

    class ScrollControlBar(QWidget):
        """浮在选区外的小条：显示帧数/总长，提供停止按钮。"""

        stopped = Signal()

        def __init__(self, region: QRect, manual: bool = False):
            super().__init__(None, Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
                             | Qt.Tool)
            self.manual = manual
            self.title = ""
            self.setAttribute(Qt.WA_StyledBackground, True)
            self.setStyleSheet(
                "QWidget { background: #2f3542; color: white; border-radius: 6px; }"
                "QPushButton { background: #e53935; border: none; padding: 4px 14px;"
                "  border-radius: 4px; color: white; }"
                "QLabel { padding: 4px; }")
            lay = QVBoxLayout(self)
            lay.setContentsMargins(10, 6, 10, 6)
            row = QHBoxLayout()
            self.label = QLabel(tr("滚动截图准备中…"))
            row.addWidget(self.label)
            btn = QPushButton("完成 (Enter)" if manual else "停止 (Esc)")
            btn.clicked.connect(self.stopped)
            row.addWidget(btn)
            lay.addLayout(row)
            if manual:
                hint = QLabel(tr("请用鼠标滚轮或 Page Down 自己滚动页面，滚到底后点「完成」"))
                hint.setStyleSheet("color: #aeb6c2; font-size: 11px;")
                lay.addWidget(hint)
            self.adjustSize()
            # 优先放在选区上方，放不下则放下方
            screen = QGuiApplication.screenAt(region.center()) or QGuiApplication.primaryScreen()
            sg = screen.availableGeometry()
            x = min(region.left(), sg.right() - self.width())
            y = region.top() - self.height() - 8
            if y < sg.top():
                y = region.bottom() + 8
            if y + self.height() > sg.bottom():
                y = region.top() + 8  # 实在没地方，放选区内顶部（会被拍到，用户可停止重来）
            self.move(x, y)

        def set_title(self, text: str):
            self.title = text
            self.adjustSize()

        def set_progress(self, frames: int, height: int, offset: int | None = None):
            prefix = f"{self.title} · " if self.title else ""
            text = prefix + tr("{}截图中… {} 帧 / {} px",
                                       tr("手动") if self.manual else tr("滚动"),
                                       frames, height)
            if offset:
                text += tr("（本帧 +{}）", offset)
            self.label.setText(text)
            self.adjustSize()

        def keyPressEvent(self, e):
            if e.key() == Qt.Key_Escape:
                self.stopped.emit()


    # ---------------------------------------------------------------- 主控制器

    class ScrollCapture(QObject):
        """滚动截图状态机。grab_fn / scroll_fn 可注入，便于离屏测试。"""

        finished_ok = Signal(QPixmap)
        failed = Signal(str)

        def __init__(self, region: QRect, grab_fn=None, scroll_fn=None,
                     interval_ms: int = 650, max_frames: int = 240,
                     manual: bool = False, driver=None, parent=None):
            super().__init__(parent)
            self.region = QRect(region)
            self.manual = manual            # 手动模式：用户自己滚动，不注入滚轮
            self.grab_fn = grab_fn or make_default_grab(region)
            self.driver = None              # 自动模式下的输入驱动（带自校准）
            if manual:
                self.scroll_fn = None
                self.interval_ms = min(interval_ms, 400)   # 采样更密，抓用户的滚动
            elif driver is not None:
                self.driver = driver
                self.scroll_fn = None
                self.interval_ms = interval_ms
            elif scroll_fn is not None:
                self.scroll_fn = scroll_fn  # 兼容：外部注入的滚动函数（无校准）
                self.interval_ms = interval_ms
            else:
                self.driver = ScrollDriver("wheel", region)
                self.scroll_fn = None
                self.interval_ms = interval_ms
            self.max_frames = max_frames

            self._acc: Frame | None = None    # 累积图像（行列表）
            self._prev: Frame | None = None   # 上一帧
            self._dpr = 1.0
            self._frames = 0
            self._no_progress = 0
            self._band_h = 0.0               # 实测"真正会滚"的内容高度（逻辑像素），0=未知
            self._col_span = None            # 实测"真正会滚"的列范围 [lo, hi)，None=未知
            self._stop_requested = False
            self._busy = False               # 抓帧内含嵌套事件循环，防重入

            self.bar = ScrollControlBar(self.region, manual=manual)
            self.bar.stopped.connect(self.stop)

            self._timer = QTimer(self)
            self._timer.setInterval(self.interval_ms)
            self._timer.timeout.connect(self._tick)

        def _fail(self, msg: str):
            """统一的失败出口：先写诊断日志，再发失败信号。"""
            _dlog("滚动·失败", msg.replace("\n", " / ")[:160])
            self.failed.emit(msg)

        def start(self):
            self.bar.show()
            if self.driver is not None:
                self.driver.prepare()        # 按键模式先把目标窗口拉到前台
            self._tick()                     # 首帧
            self._timer.start()

        def stop(self):
            self._stop_requested = True

        def _do_scroll(self):
            """执行一次滚动：希望滚动约半屏内容（保证足够重叠，拼接才稳）。

            步长按**真正会滚的那条带**算，而不是整个选区：选区里常常混着
            工具栏/列头（实测 Citrix 380 高的选区只有 208 在滚），按选区高度
            算会一次滚过头 —— 重叠不足就再也对不上。
            第一条带还没量出来（第一次滚动）时先用小步，量到之后按带高走。
            """
            frame_h = 0
            if self._prev is not None:
                frame_h = self._prev.h / max(0.01, self._dpr)
            step = max(60.0, frame_h * 0.45)
            if self._band_h > 0:
                step = min(step, max(48.0, self._band_h * 0.55))
            else:
                step = min(step, 60.0)       # 首次：1 格滚轮，稳妥起步
            if self.driver is not None:
                self.driver(step)
            elif self.scroll_fn is not None:
                self.scroll_fn()

        # ---------- 内部 ----------
        def _grab_settled(self) -> QPixmap:
            """抓一帧"稳定"的画面。

            远程桌面 / 虚拟化应用的画面重绘慢，刚滚完就抓容易拍到画了一半的中间态，
            拼接就会错位。手动模式和拖拽滚动条模式都多等一会儿再抓。
            """
            frame = self.grab_fn()
            slow = self.manual or (self.driver is not None
                                   and self.driver.mode == "drag")
            if not slow:
                return frame
            prev_fr = pixmap_to_frame(frame)
            # 判据从 1.0 放宽到 3.0：滚动动画/视频编码噪声下，"几乎逐字节相同"
            # 是等不到的，结果只会把中间态（撕裂帧）当成稳定帧拿去匹配 ——
            # 那正是 s=-1 的主要来源。3.0 仍远小于"滚动了一行"造成的差异。
            best, best_diff = frame, None
            for wait_ms in (110, 160, 240, 320):
                _sleep_ms(wait_ms)
                again = self.grab_fn()
                if again.isNull():
                    break
                fr = pixmap_to_frame(again)
                d = frame_diff(prev_fr, fr)
                _dlog("滚动·等静止", f"差异 {d:.2f}（阈值 3.0）")
                if best_diff is None or d < best_diff:
                    best, best_diff = again, d
                if d < 3.0:                            # 稳定了
                    return again
                frame, prev_fr = again, fr
            # 一直没稳定：用**差异最小**的那一帧，而不是最后一帧
            _dlog("滚动·等静止", f"未达阈值，取差异最小的帧（{best_diff:.2f}）")
            return best

        def _debug_dump(self, fr: Frame, note: str):
            """PYSHOT_SCROLL_DEBUG=1 时把每一帧和判定结果存盘，便于排查拼接异常。"""
            if os.environ.get("PYSHOT_SCROLL_DEBUG") != "1":
                return
            try:
                folder = Path.home() / ".pyshot" / "scroll_debug"
                folder.mkdir(parents=True, exist_ok=True)
                frame_to_pixmap(fr).save(str(folder / f"frame_{self._frames:03d}.png"))
                with open(folder / "offsets.txt", "a", encoding="utf-8") as f:
                    f.write(f"frame {self._frames:03d}: {note}\n")
            except Exception:                   # noqa: BLE001
                pass

        def _check_multi_pane(self, fr: Frame, s: int,
                              top: int, bottom: int) -> str | None:
            """识别"一个选区里有多块独立滚动的区域"，返回错误文案或 None。"""
            res = content_band_residuals(self._prev, fr, s, top, bottom)
            valid = [r for r in res if r is not None]
            if len(valid) < 2:
                return None
            if max(valid) > max(6.0, min(valid) * 3.0 + 4.0):
                return ("选区里似乎包含多块独立滚动的区域（例如上方列表 + 下方明细面板），"
                        "它们滚动量不同，拼不到一起。\n"
                        "请只框选其中一个面板（不含固定的明细面板/工具栏）后重试。\n"
                        "（排查用：设环境变量 PYSHOT_SCROLL_DEBUG=1 会把每帧存到 "
                        "~/.pyshot/scroll_debug）")
            return None

        def _tick(self):
            if self._busy:                   # 上一次还在抓帧（内部有事件循环），跳过这一次
                return
            self._busy = True
            try:
                self._tick_once()
            finally:
                self._busy = False

        def _tick_once(self):
            if self._frames == 0:
                _dlog("滚动·开始", f"模式={getattr(self.driver, 'mode', None)} "
                                  f"driver={'有' if self.driver is not None else '无'} "
                                  f"max_frames={self.max_frames}")
            if self._stop_requested or self._frames >= self.max_frames:
                self._finish()
                return
            try:
                frame = self._grab_settled()
            except Exception as ex:
                self._fail(tr("抓帧失败：") + str(ex))
                self._cleanup()
                return
            _dlog("滚动·帧", f"#{self._frames} 抓帧 {frame.width()}x{frame.height()}")
            # 每帧都存一份（PYSHOT_SCROLL_DEBUG=1）——出问题时能逐帧对比
            try:
                self._debug_dump(pixmap_to_frame(frame), f"帧#{self._frames}")
            except Exception:                          # noqa: BLE001
                pass
            if frame.isNull() or frame.width() < 8 or frame.height() < 80:
                self._fail(tr("抓帧失败：区域过小或被遮挡"))
                self._cleanup()
                return

            # 首帧就是空白/纯色：多半是硬件加速或内容保护窗口（Citrix/RDP 常见），
            # 早点说清楚原因，别让用户等一场拼不出东西的滚动。
            if self._prev is None and self._frames == 0:

                if pixmap_is_blank(frame, min_std=1.2, black_level=10):
                    self._fail(
                        tr("抓到的画面是空白/纯色，无法拼接。\n"
                           "目标窗口（Citrix / 远程桌面 / Java 应用）多半在用硬件加速或"
                           "内容保护，GDI 抓屏拿不到内容。按顺序试：\n"
                           "① Citrix Workspace：关掉「使用硬件加速进行图形处理」；"
                           "服务端策略把「视频编解码压缩」设为不使用\n"
                           "② Java 应用：启动参数加 -Dsun.java2d.d3d=false "
                           "-Dsun.java2d.opengl=false -Dsun.java2d.noddraw=true"
                           "（强制走 GDI 绘制）\n"
                           "③ 托盘菜单用「滚动长截图（手动滚动）」：你自己滚，程序只拼帧\n"
                           "④ 把窗口最大化或调整大小后重试"))
                    self._cleanup()
                    return

            self._dpr = frame.devicePixelRatio()
            fr = pixmap_to_frame(frame)
            s = 0                                  # 本帧检测到的位移（首帧为 0）
            if self._prev is None:
                self._acc = fr
                self._debug_dump(fr, "首帧")
            else:
                if fr.h != self._prev.h or fr.w != self._prev.w:
                    self._fail(tr("抓帧尺寸发生变化，已停止（请确保窗口未移动/缩放）"))
                    self._cleanup()
                    return
                s, diff = find_scroll(self._prev, fr)
                _dlog("滚动·位移", f"#{self._frames} s={s} diff={diff:.1f} "
                                  f"累计={int(self._acc.h / (self._dpr or 1))}")
                if s < 0:
                    # 一次滚太多（超出可拼接范围）：小步试探阶段可以自动减半重试，
                    # 已经校准过就不折腾了，直接如实报错。
                    if self.driver is not None and self.driver.recovery_after_jump():
                        _dlog("滚动·自动减半重试", f"#{self._frames} 对不上，"
                                                f"减小步长后重试")
                        self._prev = fr           # 画面确实动了，以新帧为基准继续
                        self._frames += 1
                        self._bar_call("set_progress", self._frames,
                                              int(self._acc.h / self._dpr))
                        self._do_scroll()
                        return
                    # 手动模式下用户可能正在拖动滚动条，容忍几次再继续
                    if self.manual and self._frames < self.max_frames:
                        self._prev = fr
                        self._frames += 1
                        self._bar_call("set_progress", self._frames,
                                              int(self._acc.h / self._dpr))
                        return
                    # 已经拼出明显长图后的个别不可匹配帧（典型是滚到底时滑块抖动），
                    # 不该当成失败丢掉整张图 —— 计数几次就正常收尾。
                    if (self._frames >= 3 and self._acc is not None
                            and self._acc.h > fr.h * 1.5):
                        self._no_progress += 1
                        self._prev = fr
                        self._frames += 1
                        self._bar_call("set_progress", self._frames,
                                              int(self._acc.h / self._dpr))
                        if self._no_progress >= 2:
                            self._finish()
                        return
                    # 匹配失败时先做一次"多块独立滚动区域"诊断，给出更具体的建议

                    guess = best_candidate_offset(self._prev, fr)
                    _dlog("滚动·位移", f"#{self._frames} s={guess} "
                                              f"累计高度 {int(getattr(getattr(self, '_acc', None), 'h', 0) / (self._dpr or 1))}")
                    if guess > 0:
                        t2, b2 = static_strips(self._prev, fr)
                        problem = self._check_multi_pane(fr, guess, t2, fr.h - b2)
                        if problem:
                            self._fail(problem)
                            self._cleanup()
                            return
                    self._fail(
                        "画面内容变化过快，无法对齐拼接。\n"
                        + ("拖拽滚动条模式下最常见的原因：点在了滚动条的**轨道**上而不是**滑块**上——"
                           "那样会一次翻整页，无法拼接。请重新框选并点中滑块本身。\n"
                           if self.driver is not None and self.driver.mode == "drag" else
                           "（请关闭动画/视频后重试）\n"))
                    self._cleanup()
                    return
                if s == 0:
                    self._no_progress += 1
                else:
                    H = fr.h
                    top, bpad = static_strips(self._prev, fr)
                    bottom = H - bpad
                    # 记下"真正会滚"的内容高度，步长按它算（见 _do_scroll）
                    self._band_h = max(0, bottom - top) / max(0.01, self._dpr)
                    # 再看列方向：左右有没有"整列都没动过"的静止侧栏
                    # （Citrix 左侧导航树 / 网页固定侧边栏）。有的画最后要裁掉，
                    # 否则长图里每接一次就重复一条侧栏。
                    cleft, cright = static_columns(self._prev, fr)
                    lo, hi = cleft, fr.w - cright
                    if hi - lo >= max(60, fr.w // 5):
                        if self._col_span is None:
                            self._col_span = (lo, hi)
                        else:
                            self._col_span = (max(self._col_span[0], lo),
                                              min(self._col_span[1], hi))
                    # 多块独立滚动区域（上方列表 + 下方明细面板）拼不出来，早点说清楚
                    problem = self._check_multi_pane(fr, s, top, bottom)
                    if problem:
                        self._fail(problem)
                        self._cleanup()
                        return
                    if self._frames == 1:
                        # 首次拼接：裁掉首帧的静止边缘，只保留真正的滚动内容区
                        kept = self._acc.rows[top:bottom]
                        self._acc = Frame(kept, self._acc.w, len(kept), self._acc.dpr)
                    start = max(top, bottom - s)
                    if bottom - start > 0:
                        self._acc.rows.extend(fr.rows[start:bottom])
                        self._acc.h = len(self._acc.rows)
                    self._debug_dump(fr, f"拼接 +{s}px（静止边缘 top={top} bottom={bpad}）")
                    self._no_progress = 0
                    if self.driver is not None:
                        self.driver.moved_ever = True
                        self.driver.observe(s)      # 用实测位移校准步长
            self._prev = fr
            self._frames += 1
            self._bar_call("set_progress", self._frames,
                                  int(self._acc.h / self._dpr),
                                  s if s > 0 else None)
            # 拖拽没生效会先自动降级到滚轮重试（见下方 no_progress 分支）；
            # 这里不再硬失败。
            # 自动模式：连续几帧没新内容说明滚到底了；手动模式由用户点"完成"结束
            if not self.manual and self._no_progress >= 3:
                d = self.driver
                if (d is not None and d.mode == "drag" and not d.moved_ever
                        and d.used_fallback is None):
                    # 拖拽一直没用（多半没点中滑块/该应用不吃拖拽）→ 自动改滚轮再试
                    d.used_fallback = "wheel"
                    d.mode = "wheel"
                    d.px_per_unit = _UNIT_DEFAULTS["wheel"]
                    self._no_progress = 0
                    self._bar_call("set_title", "拖拽没生效，改用滚轮重试")
                    self._bar_call("set_progress", self._frames,
                                          int(self._acc.h / self._dpr))
                    self._do_scroll()
                    return
                if d is not None and not d.moved_ever and d.used_fallback == "wheel":
                    self._fail(
                        tr("拖拽和滚轮都没能让页面滚动。\n"
                        "可能原因：点击位置不在滚动区域，或该窗口不响应注入的输入。\n"
                        "建议改用「滚动长截图（PageDown 自动滚动）」或「手动滚动」。"))
                    self._cleanup()
                    return
                self._finish()
                return
            self._do_scroll()

        def _finish(self):
            self._cleanup()
            if self._acc is None:
                self._fail(tr("没有抓到任何内容"))
                return
            acc = self._acc
            # 全程都没动过的左右侧栏（导航树/固定侧边栏）裁掉：留着的话
            # 每接一帧就重复一条，长图看起来像是坏了。
            span = getattr(self, "_col_span", None)
            if span is not None:
                lo, hi = span
                # 只有裁完还剩足够宽度（≥20%）才裁：多帧求交集后万一缩得太窄，
                # 那是检测出了岔子，宁可原样输出也不要交出一张细条。
                if (lo > 0 or hi < acc.w) and hi - lo >= max(60, acc.w // 5):
                    _dlog("滚动·裁侧栏", f"整幅 {acc.w} 列 → 保留 [{lo},{hi})"
                                        f"（左右共裁掉 {acc.w - (hi - lo)} 列）")
                    acc = _crop_cols(acc, lo, hi)
            self.finished_ok.emit(frame_to_pixmap(acc, self._dpr))

        def _cleanup(self):
            self._timer.stop()
            if self.bar is not None:
                # 控制条可能已经被 Qt 回收（例如父窗口先销毁）——
                # 直接调方法会抛 "Internal C++ object already deleted"，这里显式判活。
                try:
                    import shiboken6
                    alive = shiboken6.isValid(self.bar)
                except Exception:      # noqa: BLE001
                    alive = True
                if alive:
                    self.bar.hide()
                    self.bar.deleteLater()
                self.bar = None       # 之后所有 set_progress/set_title 都会跳过

        def _bar_call(self, method: str, *args):
            """安全地调用控制条方法（对象已销毁时静默跳过）。"""
            bar = self.bar
            if bar is None:
                return
            try:
                import shiboken6
                if not shiboken6.isValid(bar):
                    return
            except Exception:          # noqa: BLE001
                pass
            try:
                getattr(bar, method)(*args)
            except RuntimeError:       # 对象已删除
                self.bar = None


    # ========================================================================
    # 来自 editor.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """编辑器窗口：左侧工具栏 + 顶部属性栏 + 可缩放画布。"""
    import math
    from pathlib import Path

    from PySide6.QtCore import (QPoint, QPointF, QRect, QRectF, QSize, Qt, QTimer,
                                Signal)
    from PySide6.QtGui import (QAction, QColor, QGuiApplication, QIcon, QKeySequence,
                               QPainter, QPainterPath, QPen, QPixmap, QPolygonF,
                               QTransform)
    from PySide6.QtWidgets import (QDialogButtonBox, QFontDialog, QGridLayout, QMenu, QStackedWidget, QApplication, QColorDialog, QDialog, QFileDialog,
                                   QFrame, QHBoxLayout, QInputDialog, QLabel, QLayout, QLineEdit,
                                   QMainWindow, QMessageBox, QPushButton,
                                   QScrollArea, QSizePolicy, QSpinBox, QTabBar,
                                   QTabWidget, QToolButton, QVBoxLayout, QWidget,
                                   QButtonGroup)






    # 「截图时不最小化编辑器」的设置键（主程序截图时读同一个键）
    KEEP_EDITOR_SETTING = "capture_keep_editor"


    def keep_editor_on_capture() -> bool:
        """当前是否要求"截图时不要最小化编辑器"（默认 False = 自动让位）。"""
        try:

            return bool(get_setting(KEEP_EDITOR_SETTING, False))
        except Exception:                              # noqa: BLE001
            return False


    def _rail_visible_setting() -> bool:
        """左侧工具条是否显示（默认显示）。"""
        try:

            return bool(get_setting(RAIL_VISIBLE_SETTING, True))
        except Exception:                              # noqa: BLE001
            return True

    TOOLS = [
        ("select",    "选择",   "选择并移动已有标注（Delete 删除）"),
        ("rect",      "矩形",   "拖拽画矩形，Shift 画正方形"),
        ("ellipse",   "椭圆",   "拖拽画椭圆，Shift 画正圆"),
        ("line",      "直线",   "拖拽画直线，Shift 锁定水平/垂直/45°"),
        ("arrow",     "箭头",   "拖拽画箭头，指引方向"),
        ("pen",       "画笔",   "自由手绘"),
        ("step",      "序号",   "单击放置递增序号，做步骤指引"),
        ("text",      "文字",   "单击后输入文字，Enter 确认"),
        ("highlight", "高亮",   "拖拽涂抹半透明高亮"),
        ("mosaic",    "马赛克", "拖拽对区域打码"),
        ("pick",      "取色",   "单击吸取图上颜色作为当前标注颜色"),
        ("crop",      "裁剪",   "拖拽选择保留区域，Enter 应用"),
        ("pan",       "抓手",   "拖拽移动画面（图放大后看不同位置）；任何工具下按住中键或空格也能拖"),
    ]

    def basic_colors() -> list:
        """Windows 拾色器风格的「基本颜色」48 色（8 列 × 6 行）。

        前两行是经典 16 色，后面四行是它们的浅色/深色变体 —— 和系统对话框观感一致。
        """
        classic = ["#000000", "#800000", "#008000", "#808000",
                   "#000080", "#800080", "#008080", "#c0c0c0",
                   "#808080", "#ff0000", "#00ff00", "#ffff00",
                   "#0000ff", "#ff00ff", "#00ffff", "#ffffff"]
        out = list(classic)
        for factor, lighter in ((160, True), (130, True), (180, False), (140, False)):
            for c in classic:
                col = QColor(c)
                out.append(col.lighter(factor).name() if lighter
                           else col.darker(factor).name())
        return out[:48]


    CUSTOM_SLOTS = 16


    def _custom_colors() -> list:
        """读「自定义颜色」格子（最多 16 个，空的用 None 占位）。"""
        try:

            saved = get_setting("custom_colors", []) or []
        except Exception:                              # noqa: BLE001
            saved = []
        out = [c for c in saved if isinstance(c, str) and QColor(c).isValid()]
        return (out + [None] * CUSTOM_SLOTS)[:CUSTOM_SLOTS]


    def _remember_custom(color: QColor):
        """把颜色记进「自定义颜色」格子（去重、最新的排前面）并持久化。"""
        name = QColor(color).name()
        items = [c for c in _custom_colors() if c]
        if name in items:
            items.remove(name)
        items.insert(0, name)
        try:

            set_setting("custom_colors", items[:CUSTOM_SLOTS])
        except Exception:                              # noqa: BLE001
            pass


    class ColorPaletteDialog(QDialog):
        """颜色（仿 Windows 拾色器）：基本颜色 + 自定义颜色，两段式。

        - 基本颜色：48 色 8×6 网格，点一下即选中
        - 自定义颜色：16 个格子，记住用过的颜色（存 settings.json，重启还在）；
          点空白格会打开系统拾色器来定义
        """

        def __init__(self, parent=None, current=None):
            super().__init__(parent)
            self.setWindowTitle(tr("颜色"))
            self._color = QColor(current) if current is not None else QColor("#e53935")
            root = QVBoxLayout(self)
            root.setSpacing(6)

            # ---- 基本颜色 ----
            root.addWidget(QLabel(tr("基本颜色")))
            basic = QGridLayout()
            basic.setSpacing(2)
            self.buttons = []
            for i, hexs in enumerate(basic_colors()):
                b = QPushButton()
                b.setObjectName("swatch")
                b.setFixedSize(24, 24)
                b.setStyleSheet(f"background:{hexs};")
                b.setToolTip(hexs)
                b.clicked.connect(lambda checked, c=hexs: self._choose(QColor(c)))
                basic.addWidget(b, i // 8, i % 8)
                self.buttons.append(b)
            root.addLayout(basic)

            # ---- 自定义颜色 ----
            root.addWidget(QLabel(tr("自定义颜色")))
            custom = QGridLayout()
            custom.setSpacing(2)
            self.custom_buttons = []
            for i, hexs in enumerate(_custom_colors()):
                b = QPushButton()
                b.setObjectName("swatch" if hexs else "swatchEmpty")
                b.setFixedSize(24, 24)
                if hexs:
                    b.setStyleSheet(f"background:{hexs};")
                    b.setToolTip(hexs)
                    b.clicked.connect(lambda checked, c=hexs: self._choose(QColor(c)))
                else:
                    # 空白格：虚线框，点了去系统拾色器定义
                    b.setStyleSheet("background:transparent;"
                                    "border:1px dashed #5a6070;")
                    b.setToolTip(tr("点这里定义一个自定义颜色…"))
                    b.clicked.connect(self._define_custom)
                custom.addWidget(b, i // 8, i % 8)
                self.custom_buttons.append(b)
            root.addLayout(custom)

            box = QHBoxLayout()
            box.addStretch(1)
            self.btn_custom = QPushButton(tr("自定义…"))
            self.btn_custom.setToolTip(tr("打开系统拾色器"))
            self.btn_custom.clicked.connect(self._custom)
            box.addWidget(self.btn_custom)
            btns = QDialogButtonBox(self)
            btns.addButton(tr("取消"), QDialogButtonBox.RejectRole).clicked.connect(
                self.reject)
            box.addWidget(btns)
            root.addLayout(box)

        # ---------- 交互 ----------
        def _choose(self, color: QColor):
            self._color = QColor(color)
            _remember_custom(self._color)              # 选过的颜色进自定义格
            self.accept()

        def _define_custom(self, *args):
            self._custom()

        def _custom(self):
            c = QColorDialog.getColor(self._color, self, tr("自定义颜色"))
            if c.isValid():
                self._choose(c)

        def selected(self) -> QColor:
            return QColor(self._color)




    # 色板：两行 20 色（红橙黄绿青蓝紫 + 灰阶），常用色一眼可选
    PALETTE = ["#e53935", "#fb8c00", "#fdd835", "#43a047", "#00acc1",
               "#1e88e5", "#5e35b1", "#8e24aa", "#d81b60", "#6d4c41",
               "#ffffff", "#f5f5f5", "#bdbdbd", "#757575", "#424242",
               "#212121", "#000000", "#00e676", "#ff1744", "#ffea00"]

    HANDLE_SIZE = 8      # 选中图形四角/四边句柄的显示大小（屏幕像素）
    HANDLE_HIT = 11      # 句柄的点击容差

    RAIL_WIDTH = 56      # 左侧工具条总宽（44 按钮 + 3+3 边距 + 6 滚动条）
    RAIL_MIN_H = 64      # 工具条滚动区最小高度（约一个半按钮，窗口才能压得很矮）
    RAIL_VISIBLE_SETTING = "editor_tool_rail"   # 「显示左侧工具条」开关


    class FlowLayout(QLayout):
        """可换行的水平布局：空间不够时自动把控件换到下一行。

        用来替代 QToolBar 做顶栏 —— QToolBar 在窗口变窄时会把放不下的控件
        吞进溢出"»"菜单，用户就找不到了；流式布局会直接换行，始终可见。
        """

        def __init__(self, parent=None, margin=0, spacing=6):
            super().__init__(parent)
            if parent is not None:
                self.setContentsMargins(margin, margin, margin, margin)
            self._spacing = spacing
            self._items = []

        def __del__(self):
            while self.count():
                self.takeAt(0)

        def addItem(self, item):
            self._items.append(item)

        def count(self):
            return len(self._items)

        def itemAt(self, index):
            return self._items[index] if 0 <= index < len(self._items) else None

        def takeAt(self, index):
            if 0 <= index < len(self._items):
                return self._items.pop(index)
            return None

        def expandingDirections(self):
            return Qt.Orientations(Qt.Orientation(0))

        def hasHeightForWidth(self):
            return True

        def heightForWidth(self, width):
            return self._do_layout(QRect(0, 0, width, 0), True)

        def setGeometry(self, rect):
            super().setGeometry(rect)
            self._do_layout(rect, False)

        def sizeHint(self):
            return self.minimumSize()

        def minimumSize(self):
            size = QSize()
            for item in self._items:
                size = size.expandedTo(item.minimumSize())
            m = self.contentsMargins()
            return size + QSize(m.left() + m.right(), m.top() + m.bottom())

        def _do_layout(self, rect, test_only):
            """逐行排布：同一行内**垂直居中**（不同高度的控件才能对齐），
            放不下就换行。"""
            m = self.contentsMargins()
            eff = rect.adjusted(m.left(), m.top(), -m.right(), -m.bottom())
            right = eff.right() + 1
            x, y = eff.x(), eff.y()
            line_height = 0
            line = []                      # [(item, sizeHint, x)]

            def place_line():
                nonlocal y, line_height
                for it, hint, ix in line:
                    if not test_only:
                        iy = y + (line_height - hint.height()) // 2   # 垂直居中
                        it.setGeometry(QRect(QPoint(ix, iy), hint))
                y += line_height + self._spacing
                line.clear()
                line_height = 0

            for item in self._items:
                hint = item.sizeHint()
                if line and x + hint.width() > right:
                    place_line()
                    x = eff.x()
                line.append((item, hint, x))
                line_height = max(line_height, hint.height())
                x += hint.width() + self._spacing
            if line:
                for it, hint, ix in line:
                    if not test_only:
                        iy = y + (line_height - hint.height()) // 2
                        it.setGeometry(QRect(QPoint(ix, iy), hint))
                y += line_height
            return max(self._spacing, y - rect.y() + m.bottom())


    class Canvas(QWidget):
        """底图 + 标注列表的绘制与交互。坐标均为图像像素坐标。"""

        shapes_changed = Signal()
        color_picked = Signal(QColor)
        zoom_changed = Signal(float)
        escape_idle = Signal()   # Esc 按下且画布无任何待取消状态
        selection_changed = Signal(object)   # 当前选中的图形（或 None）
        float_changed = Signal()   # 浮动粘贴的开始/固定/取消（宿主据此刷新菜单）
        context_action = Signal(str)   # 右键菜单请求：front/up/down/back/dup/rot15/rot0

        def __init__(self, pixmap: QPixmap, parent=None):
            super().__init__(parent)
            self.base_pixmap = QPixmap(pixmap)
            # 保留截图自带的 devicePixelRatio：图形坐标统一用"图像物理像素"，
            # 画布控件尺寸用"逻辑像素"（物理 / dpr），这样 100% 缩放时
            # 1 个图像像素恰好落在 1 个屏幕物理像素上，不会被系统放大而发虚。
            self.dpr = float(self.base_pixmap.devicePixelRatio() or 1.0)
            self.shapes: list = []
            # 拖动查看（平移画面）的状态
            self._panning = False
            self._space_pan = False          # 按住空格临时抓手
            self._pan_from = QPointF()
            self._pan_scroll = (0, 0)
            self._scroll_area = None
            self.setFocusPolicy(Qt.StrongFocus)     # 为了接空格键
            self.tool = "select"
            # 适应模式：窗口大小变化时自动重算缩放。
            # 用户一旦手动缩放（滚轮/按钮）就退出，免得打断他看细节。
            self.fit_mode = True
            self.color = QColor(PALETTE[0])
            self.pen_width = 3
            self.font_size = 20
            self.step_diameter = 36        # 序号圆直径，独立于字号
            self.step_counter = 1

            self.zoom = 1.0
            self._current: Shape | None = None   # 正在拖拽中的图形
            self._drag_start = QPointF()
            self._dragging = False
            self._moving: Shape | None = None    # 选择模式下拖动的图形
            self._move_last = QPointF()
            self._move_snapshot = False
            self._selected: Shape | None = None
            self._resizing: tuple | None = None   # (shape, handle_index)
            self._crop_rect: QRectF | None = None
            self._hover_pos = None   # 取色放大镜用的光标位置（窗口坐标）

            self._undo_stack: list = []
            self._redo_stack: list = []

            # 浮动粘贴：把新截图贴到当前图上，先摆位置再固定（Enter 固定 / Esc 取消）
            self._float_pix: QPixmap | None = None
            self._float_rect_obj = QRectF()       # 权威尺寸：图像物理像素下的矩形
            self._float_aspect = 1.0              # 原始宽高比（Shift 等比时用）
            self._float_angle = 0.0               # 浮层旋转角（度，顺时针）
            self._float_from: QPointF | None = None    # 拖动时的抓取偏移
            self._float_handle: int | None = None      # 正在拖的句柄索引（8 = 旋转）
            # 粘贴图的外观（阴影/描边/圆角）——做指引时让贴上去的图"浮起来"
            self.float_style = {"shadow": False, "stroke": False, "radius": 0,
                                "stroke_color": "#ffffff", "stroke_width": 3}

            self._text_edit: QLineEdit | None = None
            self._text_pos = QPointF()
            self._text_target = None      # 正在改的已有文字（None = 新建）
            self.font_family = ""         # 文字字体（空 = 默认微软雅黑）

            self.setMouseTracking(True)
            self.setFocusPolicy(Qt.StrongFocus)
            self._apply_size()

        # ---------- 基础 ----------
        def _apply_size(self):
            """画布逻辑尺寸 = 图像物理像素 / dpr × 缩放。"""
            self.setFixedSize(max(1, round(self.base_pixmap.width() / self.dpr * self.zoom)),
                              max(1, round(self.base_pixmap.height() / self.dpr * self.zoom)))

        def to_image(self, widget_pos) -> QPointF:
            """控件坐标 → 图像物理像素坐标。"""
            return QPointF(widget_pos.x() * self.dpr / self.zoom,
                           widget_pos.y() * self.dpr / self.zoom)

        def to_widget(self, image_pos) -> QPointF:
            """图像物理像素坐标 → 控件坐标（paintEvent 里变换的逆）。

            这两个函数必须严格互逆 —— 否则鼠标位置和图形落点会错开，
            系统缩放不是 100% 时表现为"画图不跟手"。
            """
            return QPointF(image_pos.x() * self.zoom / self.dpr,
                           image_pos.y() * self.zoom / self.dpr)

        def clamp(self, p: QPointF) -> QPointF:
            r = QRectF(self.base_pixmap.rect())
            return QPointF(min(max(p.x(), r.left()), r.right()),
                           min(max(p.y(), r.top()), r.bottom()))

        # ---------- 撤销 / 重做 ----------
        def _snapshot(self):
            return (QPixmap(self.base_pixmap), clone_shapes(self.shapes),
                    self.step_counter)

        def push_undo(self):
            self._undo_stack.append(self._snapshot())
            if len(self._undo_stack) > 60:
                self._undo_stack.pop(0)
            self._redo_stack.clear()

        def undo(self):
            if not self._undo_stack:
                return
            self._redo_stack.append(self._snapshot())
            self._restore(self._undo_stack.pop())

        def redo(self):
            if not self._redo_stack:
                return
            self._undo_stack.append(self._snapshot())
            self._restore(self._redo_stack.pop())

        def _restore(self, snap):
            self.base_pixmap, self.shapes, self.step_counter = snap
            self.base_pixmap = QPixmap(self.base_pixmap)
            self.shapes = clone_shapes(self.shapes)
            self._selected = None
            self._crop_rect = None
            self._apply_size()
            self.update()
            self.shapes_changed.emit()

        # ---------- 鼠标交互 ----------
        # ---------- 拖动查看（放大后平移画面）----------
        def scroll_area(self):
            """找到承载自己的 QScrollArea（add_canvas 里会存一份引用）。"""
            area = getattr(self, "_scroll_area", None)
            if area is not None:
                return area
            w = self.parent()
            while w is not None:
                if isinstance(w, QScrollArea):
                    return w
                w = w.parent()
            return None

        def _pan_begin(self, e):
            """开始拖动：记下按下位置与当时的滚动量。"""
            area = self.scroll_area()
            if area is None:
                return False
            self._panning = True
            self._pan_from = e.position()
            self._pan_scroll = (area.horizontalScrollBar().value(),
                                area.verticalScrollBar().value())
            self._pan_moved = False
            self.setCursor(Qt.ClosedHandCursor)
            return True

        def _pan_update(self, e) -> bool:
            """拖动中：把鼠标位移反向加到滚动条上。"""
            if not self._panning:
                return False
            area = self.scroll_area()
            if area is None:
                return False
            d = e.position() - self._pan_from
            if abs(d.x()) > 1 or abs(d.y()) > 1:
                self._pan_moved = True
            area.horizontalScrollBar().setValue(int(self._pan_scroll[0] - d.x()))
            area.verticalScrollBar().setValue(int(self._pan_scroll[1] - d.y()))
            return True

        def _pan_end(self):
            was = self._panning
            self._panning = False
            self.set_tool_cursor()
            return was

        def can_pan(self) -> bool:
            """当前是否处于"拖动能平移"的状态（抓手工具 / 按住空格）。"""
            return self.tool == "pan" or self._space_pan

        def set_tool_cursor(self):
            """按当前工具设置鼠标形状。"""
            if self.tool == "pan" or self._space_pan:
                self.setCursor(Qt.ClosedHandCursor if self._panning
                               else Qt.OpenHandCursor)
            elif self.tool == "select":
                self.setCursor(Qt.ArrowCursor)
            else:
                self.setCursor(Qt.CrossCursor)

        def keyReleaseEvent(self, e):
            if e.key() == Qt.Key_Space and not e.isAutoRepeat():
                self._space_pan = False
                if not self._panning:
                    self.set_tool_cursor()
                e.accept()
                return
            super().keyReleaseEvent(e)

        def mousePressEvent(self, e):
            self._commit_text()
            # 中键：任何工具下都能拖动画面（以前这里直接 return，中键其实没用）
            if e.button() == Qt.MiddleButton:
                self._pan_begin(e)
                e.accept()
                return
            if e.button() != Qt.LeftButton:
                return
            # 抓手工具 / 按住空格：左键拖动 = 平移画面
            if self.can_pan():
                self._pan_begin(e)
                e.accept()
                return
            pos = self.clamp(self.to_image(e.position()))
            self._drag_start = pos
            self._dragging = True

            # 浮动粘贴：任何工具下都能拖/缩/转它（临时摆放状态，优先于画笔工具）
            if self._float_pix is not None:
                hit = max(8.0, (HANDLE_HIT + 2) / max(0.2, self.zoom))
                for i, hp in enumerate(self.float_handles()):
                    if (abs(hp.x() - pos.x()) <= hit and abs(hp.y() - pos.y()) <= hit):
                        self._float_handle = i        # 0~7 缩放，8 = 旋转
                        self._float_from = None
                        self._dragging = False
                        e.accept()
                        return
                if self.float_rect().contains(self.float_local(pos)):
                    self._float_from = self.float_local(pos) - self._float_rect_obj.topLeft()
                    self._dragging = False
                    e.accept()
                    return

            if self.tool == "select":
                self._resizing = None
                # 先看是否点在缩放/旋转句柄上（优先于选中/移动）
                if self._selected is not None:
                    hit = int(HANDLE_HIT / self.zoom) + 2
                    for i, hp in enumerate(self._selected.rotated_handles()):
                        if (abs(hp.x() - pos.x()) <= hit and abs(hp.y() - pos.y()) <= hit):
                            self.push_undo()
                            self._resizing = (self._selected, i)
                            self._dragging = False
                            self.update()
                            return
                self._moving = None
                self._selected = None
                self._move_snapshot = False
                for shape in reversed(self.shapes):  # 最上层优先
                    # 命中判定要在图形**自身坐标**里做（旋转过的图形点不准会很难选）
                    if shape.contains(shape.world_to_local(pos), 6 / self.zoom):
                        self._selected = shape
                        self._moving = shape
                        self._move_last = pos
                        break
                self.selection_changed.emit(self._selected)
                self.update()
                return

            if self.tool == "crop":
                self._crop_rect = QRectF(pos, pos)
                self.update()
                return

            if self.tool == "pick":
                img = self.base_pixmap.toImage()
                c = img.pixelColor(int(pos.x()), int(pos.y()))
                self.color = c
                self.color_picked.emit(c)
                self._dragging = False
                return

            if self.tool == "text":
                self._open_text_editor(pos)
                self._dragging = False
                return

            if self.tool == "step":
                self.push_undo()
                self.shapes.append(StepShape(self.color, self.pen_width, pos,
                                             self.step_counter, self.font_size,
                                             self.step_diameter))
                self.step_counter += 1
                self._dragging = False
                self.update()
                self.shapes_changed.emit()
                return

            if self.tool == "pen":
                self._current = PenShape(self.color, self.pen_width, [pos])
            elif self.tool == "rect":
                self._current = RectShape(self.color, self.pen_width, QRectF(pos, pos))
            elif self.tool == "ellipse":
                self._current = EllipseShape(self.color, self.pen_width, QRectF(pos, pos))
            elif self.tool == "line":
                self._current = LineShape(self.color, self.pen_width, pos, pos)
            elif self.tool == "arrow":
                self._current = ArrowShape(self.color, self.pen_width, pos, pos)
            elif self.tool == "highlight":
                self._current = HighlightShape(self.color, self.pen_width, QRectF(pos, pos))
            elif self.tool == "mosaic":
                self._current = MosaicShape(self.color, self.pen_width, QRectF(pos, pos))
            self.update()

        def mouseMoveEvent(self, e):
            if self._pan_update(e):                 # 拖动查看优先
                return
            self._hover_pos = e.position()
            if self.tool == "pick":
                self.update()  # 刷新取色放大镜
            pos = self.clamp(self.to_image(e.position()))
            # 拖动/缩放/旋转中的浮动粘贴
            if self._float_pix is not None and self._float_handle is not None:
                if self._float_handle == 8:
                    self.rotate_float_to(pos)
                elif self._float_angle:
                    # 转过之后：角手柄绕中心等比缩放，边的靠自身坐标处理
                    c = self._float_rect_obj.center()
                    if self._float_handle in (0, 2, 4, 6):
                        d0 = math.hypot(self._float_rect_obj.width(),
                                        self._float_rect_obj.height()) / 2.0
                        d1 = math.hypot(pos.x() - c.x(), pos.y() - c.y())
                        if d0 > 0.5 and d1 > 0.5:
                            self.scale_float(d1 / d0)
                    else:
                        self.resize_float_by_handle(self._float_handle,
                                                    self.float_local(pos),
                                                    bool(e.modifiers() & Qt.ShiftModifier))
                else:
                    self.resize_float_by_handle(self._float_handle, pos,
                                                bool(e.modifiers() & Qt.ShiftModifier))
                self.update()
                return
            if self._float_pix is not None and self._float_from is not None:
                top_left = self.float_local(pos) - self._float_from
                self._float_rect_obj = QRectF(top_left, self._float_rect_obj.size())
                self.update()
                return
            # 悬停在浮动图上时给"可拖动"的光标
            if self._float_pix is not None:
                over = self.float_rect().contains(self.float_local(pos))
                self.setCursor(Qt.SizeAllCursor if over else Qt.ArrowCursor)
                if over:
                    return
            if self.tool == "select" and self._resizing is not None:
                shape, index = self._resizing
                shape.apply_rotation_and_resize(
                    index, pos, bool(e.modifiers() & Qt.ShiftModifier))
                self.update()
                return
            if self.tool == "select" and self._moving is not None:
                if not self._move_snapshot:
                    self.push_undo()  # 移动开始前记录一次快照
                    self._move_snapshot = True
                d = pos - self._move_last
                self._moving.move_by(d.x(), d.y())
                self._move_last = pos
                self.update()
                return
            if self.tool == "crop" and self._dragging and self._crop_rect is not None:
                self._crop_rect = QRectF(self._drag_start, pos)
                self.update()
                return
            if not self._dragging or self._current is None:
                return
            cur = self._current
            if isinstance(cur, PenShape):
                cur.add_point(pos)
            elif isinstance(cur, LineShape):
                p2 = pos
                if e.modifiers() & Qt.ShiftModifier:  # 锁定 45° 方向
                    d = p2 - self._drag_start
                    ang = round(math.atan2(d.y(), d.x()) / (math.pi / 4))
                    length = math.hypot(d.x(), d.y())
                    p2 = self._drag_start + QPointF(
                        length * math.cos(ang * math.pi / 4),
                        length * math.sin(ang * math.pi / 4))
                cur.p2 = p2
            else:  # 矩形类
                rect = QRectF(self._drag_start, pos)
                if e.modifiers() & Qt.ShiftModifier:  # 正方形
                    side = max(abs(rect.width()), abs(rect.height()))
                    sx = side if pos.x() >= self._drag_start.x() else -side
                    sy = side if pos.y() >= self._drag_start.y() else -side
                    rect = QRectF(self._drag_start,
                                  self._drag_start + QPointF(sx, sy))
                cur.rect = rect.normalized()
            self.update()

        def leaveEvent(self, e):
            if self._hover_pos is not None:
                self._hover_pos = None
                if self.tool == "pick":
                    self.update()
            super().leaveEvent(e)

        def mouseReleaseEvent(self, e):
            if self._float_from is not None or self._float_handle is not None:
                self._float_from = None            # 松开：浮动图就停在当前位置/大小
                self._float_handle = None
                e.accept()
                return
            if self._panning and (e.button() in (Qt.MiddleButton, Qt.LeftButton)):
                self._pan_end()
                e.accept()
                return
            if e.button() != Qt.LeftButton:
                return
            if self.tool == "select":
                self._moving = None
                self._move_snapshot = False
                self._resizing = None
                self.shapes_changed.emit()
                return
            if self.tool == "crop":
                self._dragging = False
                return
            if self._current is not None:
                # 过滤掉过小的误触
                br = self._current.bounding_rect()
                too_small = (not isinstance(self._current, PenShape)
                             and br.width() < 3 and br.height() < 3)
                if isinstance(self._current, PenShape) and len(self._current.points) < 2:
                    too_small = True
                if not too_small:
                    self.push_undo()
                    self.shapes.append(self._current)
                    self.shapes_changed.emit()
                self._current = None
            self._dragging = False
            self.update()

        def mouseDoubleClickEvent(self, e):
            if self._float_pix is not None:        # 双击 = 固定（和 Enter 等价）
                self.commit_float()
                return
            if self.tool == "crop":
                self.apply_crop()
                return
            # 双击已有文字 = 改文字（以前只能删掉重写）
            pos = self.to_image(e.position())
            for shape in reversed(self.shapes):
                if isinstance(shape, TextShape) and shape.contains(
                        shape.world_to_local(pos), 6 / self.zoom):
                    self._selected = shape
                    self.selection_changed.emit(shape)
                    self._open_text_editor(shape.pos, target=shape)
                    self.update()
                    return

        def contextMenuEvent(self, e):
            """右键菜单：图层顺序 / 再制 / 旋转 / 删除 / 粘贴相关。

            以前画布右键没反应，只能去编辑菜单里找；做指引时这些操作很常用。
            """
            menu = QMenu(self)
            has_sel = self._selected is not None and self._selected in self.shapes
            if self._float_pix is not None:
                menu.addAction(tr("固定粘贴的图"), self.commit_float)
                menu.addAction(tr("取消粘贴"), self.cancel_float)
                menu.addSeparator()
            if has_sel:
                menu.addAction(tr("置于顶层"),
                               lambda: self._emit_ctx("front"))
                menu.addAction(tr("上移一层"), lambda: self._emit_ctx("up"))
                menu.addAction(tr("下移一层"), lambda: self._emit_ctx("down"))
                menu.addAction(tr("置于底层"), lambda: self._emit_ctx("back"))
                menu.addSeparator()
                menu.addAction(tr("再制一个"), lambda: self._emit_ctx("dup"))
                if isinstance(self._selected, TextShape):
                    menu.addAction(tr("修改文字…"),
                                   lambda: self._emit_ctx("edit_text"))
                menu.addAction(tr("旋转 15°"), lambda: self._emit_ctx("rot15"))
                menu.addAction(tr("摆正（0°）"), lambda: self._emit_ctx("rot0"))
                menu.addSeparator()
                menu.addAction(tr("删除"), lambda: self._emit_ctx("del"))
            if menu.isEmpty():
                menu.addAction(tr("撤销"), self.undo)
                menu.addAction(tr("重做"), self.redo)
            menu.exec(e.globalPos())

        def _emit_ctx(self, what: str):
            """画布右键菜单 → 交给宿主执行（宿主管撤销栈与状态栏提示）。"""
            if what == "del" and self._selected is not None:
                self.push_undo()
                self.shapes.remove(self._selected)
                self._selected = None
                self.selection_changed.emit(None)
                self.update()
                self.shapes_changed.emit()
                return
            self.context_action.emit(what)

        def keyPressEvent(self, e):
            # 方向键微调：选中的图形 1px，按 Shift 10px（画指引时对齐很有用）
            step = 10.0 if (e.modifiers() & Qt.ShiftModifier) else 1.0
            deltas = {Qt.Key_Left: (-step, 0.0), Qt.Key_Right: (step, 0.0),
                      Qt.Key_Up: (0.0, -step), Qt.Key_Down: (0.0, step)}
            if e.key() in deltas:
                if self._float_pix is not None:
                    dx, dy = deltas[e.key()]
                    self._float_rect_obj.translate(dx, dy)
                    self.update()
                    e.accept()
                    return
                if self._selected is not None and self._selected in self.shapes:
                    dx, dy = deltas[e.key()]
                    self.push_undo()               # 每次微调都能撤销
                    self._selected.move_by(dx, dy)
                    self.update()
                    self.shapes_changed.emit()
                    e.accept()
                    return
            # 浮动粘贴：Enter 固定 / Esc 取消（要排在其它 Esc 处理之前，
            # 否则会直接把编辑器关掉）
            if self._float_pix is not None:
                if e.key() in (Qt.Key_Return, Qt.Key_Enter):
                    self.commit_float()
                    e.accept()
                    return
                if e.key() == Qt.Key_Escape:
                    self.cancel_float()
                    e.accept()
                    return
            # 按住空格 = 临时抓手（和 Photoshop 一致，松开恢复原工具）
            if e.key() == Qt.Key_Space and not e.isAutoRepeat():
                self._space_pan = True
                self.set_tool_cursor()
                e.accept()
                return
            if e.key() in (Qt.Key_Delete, Qt.Key_Backspace):
                if self._selected is not None and self._selected in self.shapes:
                    self.push_undo()
                    self.shapes.remove(self._selected)
                    self._selected = None
                    self.selection_changed.emit(None)
                    self.update()
                    self.shapes_changed.emit()
                return
            if e.key() in (Qt.Key_Return, Qt.Key_Enter):
                if self.tool == "crop":
                    self.apply_crop()
                return
            if e.key() == Qt.Key_Escape:
                # 分层取消：文字输入 → 裁剪框 → 选中图形 → 绘制中 → 都空闲则请求关闭窗口
                if self._text_edit is not None:
                    self._cancel_text()
                elif self._crop_rect is not None:
                    self._crop_rect = None
                    self.update()
                elif self._selected is not None:
                    self._selected = None
                    self.selection_changed.emit(None)
                    self.update()
                elif self._current is not None:
                    self._current = None
                    self._dragging = False
                    self.update()
                else:
                    self.escape_idle.emit()
                return
            super().keyPressEvent(e)

        # ---------- 文字输入 ----------
        def _open_text_editor(self, pos: QPointF, target=None):
            """打开行内文字输入。target 是已有的 TextShape 时表示**改文字**。"""
            self._text_pos = pos
            self._text_target = target
            edit = QLineEdit(self)
            edit.setPlaceholderText(tr("输入文字，Enter 确认 / Esc 取消"))
            font = edit.font()
            size = int(getattr(target, "font_size", self.font_size) or self.font_size)
            font.setPixelSize(max(12, int(size * self.zoom)))
            fam = getattr(target, "family", "") or getattr(self, "font_family", "")
            if fam:
                font.setFamily(fam)
            edit.setFont(font)
            edit.setStyleSheet(f"color: {self.color.name()}; background: rgba(255,255,255,220);"
                               "border: 1px dashed #888;")
            edit.move(int(pos.x() * self.zoom), int(pos.y() * self.zoom))
            edit.resize(max(240, int(size * self.zoom * 12)), edit.sizeHint().height() + 6)
            if target is not None:                 # 改已有的：填上原文并全选，直接就能改
                edit.setText(str(target.text))
                edit.selectAll()
            edit.returnPressed.connect(self._commit_text)
            edit.editingFinished.connect(self._commit_text)
            edit.show()
            edit.setFocus()
            self._text_edit = edit

        def _cancel_text(self):
            """丢弃正在输入的文字。"""
            if self._text_edit is None:
                return
            edit = self._text_edit
            self._text_edit = None
            edit.blockSignals(True)   # 防止 editingFinished 触发提交
            edit.deleteLater()

        def _commit_text(self):
            if self._text_edit is None:
                return
            edit = self._text_edit
            target = getattr(self, "_text_target", None)
            self._text_edit = None
            self._text_target = None
            text = edit.text().strip()
            edit.deleteLater()
            if target is not None:                 # 改已有文字
                if not text:
                    self.push_undo()
                    if target in self.shapes:
                        self.shapes.remove(target)
                        if self._selected is target:
                            self._selected = None
                            self.selection_changed.emit(None)
                    self.update()
                    self.shapes_changed.emit()
                    return
                if text != target.text:
                    self.push_undo()
                    target.text = text
                    self.update()
                    self.shapes_changed.emit()
                return
            if text:
                self.push_undo()
                self.shapes.append(TextShape(self.color, self.pen_width, self._text_pos,
                                             text, self.font_size,
                                             getattr(self, "font_family", "")))
                self.update()
                self.shapes_changed.emit()

        # ---------- 裁剪 ----------
        def apply_crop(self):
            if self._crop_rect is None:
                return
            r = self._crop_rect.normalized().toAlignedRect().intersected(
                self.base_pixmap.rect())
            if r.width() < 10 or r.height() < 10:
                self._crop_rect = None
                self.update()
                return
            self.push_undo()
            cropped = self.base_pixmap.copy(r)
            cropped.setDevicePixelRatio(self.dpr)
            self.base_pixmap = cropped
            kept = []
            for shape in self.shapes:
                shape.translate(-r.x(), -r.y())
                if shape.bounding_rect().intersects(QRectF(self.base_pixmap.rect())):
                    kept.append(shape)
            self.shapes = kept
            self._crop_rect = None
            self._selected = None
            self._apply_size()
            self.update()
            self.shapes_changed.emit()

        def cancel_crop(self):
            self._crop_rect = None
            self.update()

        # ---------- 加边框（FSCapture 的「特效 → 边缘」）----------
        def apply_border(self, settings: dict, push_undo: bool = True) -> bool:
            """在图片四周加边框：底图变大，已有标注整体平移。

            和水印不同，边框是在**图片外面**加一圈（输出图更大），所以改的是
            base_pixmap；走撤销栈，加错了 Ctrl+Z 就能回去。
            """

            left, top, _right, _bottom = border_padding(settings)
            if left + top == 0:
                return False
            if push_undo:
                self.push_undo()
            self.base_pixmap = render_border(self.base_pixmap, settings)
            self.base_pixmap.setDevicePixelRatio(self.dpr)
            for shape in self.shapes:
                shape.translate(left, top)
            self._crop_rect = None
            self._selected = None
            self._apply_size()
            self.update()
            self.shapes_changed.emit()
            return True

        # ---------- 序号大小 ----------
        def selected_step(self):
            """当前选中的序号图形（没有则返回 None）。"""
            return self._selected if isinstance(self._selected, StepShape) else None

        def resize_selected_step(self, diameter: float, push_undo: bool = True):
            step = self.selected_step()
            if step is None:
                return False
            if abs(step.diameter - diameter) < 0.5:
                return False
            if push_undo:
                self.push_undo()
            step.set_diameter(diameter)
            self.update()
            self.shapes_changed.emit()
            return True

        # ---------- 缩放 ----------
        def set_zoom(self, zoom: float):
            # 任何"显式指定缩放"都算脱离适应模式（适应操作自己会再置回 True）
            self.fit_mode = False
            self.zoom = min(4.0, max(0.1, zoom))
            self._apply_size()
            self.update()
            self.zoom_changed.emit(self.zoom)

        # ---------- 浮动粘贴（把新截图贴到当前图上编辑） ----------
        def has_float(self) -> bool:
            return self._float_pix is not None

        def float_rect(self) -> QRectF:
            """浮动图在"图像物理像素"坐标下的矩形。"""
            return QRectF(self._float_rect_obj)

        def float_scale(self) -> float:
            """当前缩放倍数（1.0 = 原始像素大小），按宽度算。"""
            if self._float_pix is None or self._float_pix.width() <= 0:
                return 1.0
            return self._float_rect_obj.width() / self._float_pix.width()

        def float_handles(self) -> list:
            """浮动图的 8 个缩放手柄 + 1 个旋转手柄（最后一个是旋转）。

            顺序与 Shape.handles() 一致：0左上 1上中 2右上 3右中 4右下 5下中
            6左下 7左中；第 8 个是顶边外侧的旋转手柄。**都跟着旋转角走**。
            """
            if self._float_pix is None:
                return []
            r = self._float_rect_obj
            x0, y0, x1, y1 = r.left(), r.top(), r.right(), r.bottom()
            cx = (x0 + x1) / 2.0
            local = [QPointF(x0, y0), QPointF(cx, y0), QPointF(x1, y0),
                     QPointF(x1, (y0 + y1) / 2.0), QPointF(x1, y1),
                     QPointF(cx, y1), QPointF(x0, y1), QPointF(x0, (y0 + y1) / 2.0)]
            c = r.center()
            rad = math.radians(self._float_angle)
            pts = []
            for p in local:
                if not self._float_angle:
                    pts.append(QPointF(p))
                    continue
                dx, dy = p.x() - c.x(), p.y() - c.y()
                pts.append(QPointF(c.x() + dx * math.cos(rad) - dy * math.sin(rad),
                                   c.y() + dx * math.sin(rad) + dy * math.cos(rad)))
            # 旋转手柄：从"旋转后的上边中点"再往外一点
            top_mid = QPointF((pts[0].x() + pts[2].x()) / 2.0,
                              (pts[0].y() + pts[2].y()) / 2.0)
            dist = max(18.0, r.height() * 0.12)
            pts.append(QPointF(top_mid.x() + math.sin(rad) * dist,
                               top_mid.y() - math.cos(rad) * dist))
            return pts

        def float_corners(self) -> list:
            """浮层旋转后的四角（左上、右上、右下、左下）——虚线框按它画。"""
            r = self._float_rect_obj
            pts = [r.topLeft(), r.topRight(), r.bottomRight(), r.bottomLeft()]
            if not self._float_angle:
                return [QPointF(p) for p in pts]
            c = r.center()
            rad = math.radians(self._float_angle)
            out = []
            for p in pts:
                dx, dy = p.x() - c.x(), p.y() - c.y()
                out.append(QPointF(c.x() + dx * math.cos(rad) - dy * math.sin(rad),
                                   c.y() + dx * math.sin(rad) + dy * math.cos(rad)))
            return out

        def float_local(self, pos: QPointF) -> QPointF:
            """世界坐标 → 浮层自身坐标（把点按旋转角反向转回来）。"""
            if not self._float_angle:
                return QPointF(pos)
            c = self._float_rect_obj.center()
            rad = math.radians(-self._float_angle)
            dx, dy = pos.x() - c.x(), pos.y() - c.y()
            return QPointF(c.x() + dx * math.cos(rad) - dy * math.sin(rad),
                           c.y() + dx * math.sin(rad) + dy * math.cos(rad))

        def rotate_float_to(self, pos: QPointF) -> bool:
            """把旋转手柄拖到 pos：让浮层的"上边"朝向这个方向。"""
            if self._float_pix is None:
                return False
            c = self._float_rect_obj.center()
            dx, dy = pos.x() - c.x(), pos.y() - c.y()
            if abs(dx) < 0.5 and abs(dy) < 0.5:
                return False
            self._float_angle = math.degrees(math.atan2(dx, -dy)) % 360.0
            self.update()
            return True

        def _float_anchor(self) -> QRectF:
            """浮动图的默认落点：**当前看得见**的那块区域的中心。

            不能直接用整图中心：滚动长截图动辄几千像素高，图心多半在屏幕外，
            贴上去等于看不见。滚动区拿不到（未嵌入时）就退回图心。
            """
            pix = self._float_pix
            w = float(pix.width())
            h = float(pix.height())
            # 比底图还大就先缩到能看全（否则一贴上去半个图在画布外，很难摆）
            bw, bh = self.base_pixmap.width(), self.base_pixmap.height()
            if w > bw * 0.9 or h > bh * 0.9:
                k = min(bw * 0.6 / max(1.0, w), bh * 0.6 / max(1.0, h))
                w, h = w * k, h * k
            cx = bw / 2.0
            cy = bh / 2.0
            area = self._scroll_area
            try:
                if area is not None:
                    vp = area.viewport()
                    center_in_canvas = self.mapFrom(vp, vp.rect().center())
                    center_img = self.to_image(QPointF(center_in_canvas))
                    cx, cy = center_img.x(), center_img.y()
            except Exception:                          # noqa: BLE001
                pass
            x = min(max(cx - w / 2.0, 0.0), max(0.0, bw - w))
            y = min(max(cy - h / 2.0, 0.0), max(0.0, bh - h))
            return QRectF(x, y, w, h)

        def start_float(self, pixmap: QPixmap) -> bool:
            """把一张图变成"可拖动的浮动层"，等用户摆好位置再固定。

            贴上去先不动底图（所以不占撤销栈），Enter/双击才合成进底图。
            """
            if pixmap is None or pixmap.isNull() or self.base_pixmap is None:
                return False
            pix = QPixmap(pixmap)
            pix.setDevicePixelRatio(1.0)      # 统一按图像物理像素处理
            self._float_pix = pix
            self._float_aspect = (pix.width() / pix.height()) if pix.height() else 1.0
            self._float_rect_obj = self._float_anchor()
            self._float_angle = 0.0
            self._float_from = None
            self._float_handle = None
            self.setFocus(Qt.OtherFocusReason)   # 让 Enter/Esc 能直接生效
            self.float_changed.emit()
            self.update()
            return True

        def commit_float(self) -> bool:
            """把浮动图合成到底图上（可撤销）。"""
            if self._float_pix is None:
                return False
            self.push_undo()                     # 底图要变了，先记一次
            p = QPainter(self.base_pixmap)
            p.setRenderHint(QPainter.Antialiasing)
            p.setRenderHint(QPainter.SmoothPixmapTransform)
            self._draw_float(p)                  # 和预览用同一套画法，保证一致
            p.end()
            self._float_pix = None
            self._float_from = None
            self._float_handle = None
            self._apply_size()
            self.shapes_changed.emit()           # 宿主据此刷新按钮/会话缓存
            self.float_changed.emit()
            self.set_tool_cursor()
            self.update()
            return True

        # ---------- 画布变换：翻转 / 旋转 90° / 改尺寸 ----------
        # 标注图形跟着一起变换（不是"烧进图里"），所以变换完还能继续编辑。
        def _apply_canvas_transform(self, t: QTransform, new_size=None):
            """把仿射变换同时作用到底图和所有标注上。"""
            self.push_undo()
            old = self.base_pixmap
            if new_size is None:
                new_size = old.size()
            out = old.transformed(t, Qt.SmoothTransformation)
            if out.size() != new_size:                 # 兜底：尺寸必须和目标一致
                out = out.scaled(new_size, Qt.IgnoreAspectRatio,
                                 Qt.SmoothTransformation)
            out.setDevicePixelRatio(self.dpr)
            self.base_pixmap = out
            for shape in self.shapes:
                try:
                    shape.transform(t)
                except Exception:                      # noqa: BLE001
                    pass
            self._apply_size()
            self._selected = None
            self._crop_rect = None
            self.shapes_changed.emit()
            self.update()

        def flip_horizontal(self):
            """水平翻转（左右镜像），标注跟着翻。"""
            t = QTransform().translate(self.base_pixmap.width(), 0).scale(-1, 1)
            self._apply_canvas_transform(t)

        def flip_vertical(self):
            """垂直翻转（上下镜像），标注跟着翻。"""
            t = QTransform().translate(0, self.base_pixmap.height()).scale(1, -1)
            self._apply_canvas_transform(t)

        def rotate90(self, clockwise: bool = True):
            """顺时针/逆时针转 90°（宽高对调），标注跟着转。"""
            w, h = self.base_pixmap.width(), self.base_pixmap.height()
            if clockwise:
                t = QTransform().translate(h, 0).rotate(90)
                size = QSize(h, w)
            else:
                t = QTransform().translate(0, w).rotate(-90)
                size = QSize(h, w)
            self._apply_canvas_transform(t, new_size=size)

        def scale_canvas(self, width: int, height: int):
            """把整张图（含标注）缩放到指定像素尺寸。"""
            w, h = self.base_pixmap.width(), self.base_pixmap.height()
            if width < 8 or height < 8 or w < 1 or h < 1:
                return
            t = QTransform().scale(width / float(w), height / float(h))
            self._apply_canvas_transform(t, new_size=QSize(int(width), int(height)))

        def set_float_style(self, **kw) -> None:
            """调粘贴图外观（shadow / stroke / radius / stroke_color）。"""
            self.float_style.update({k: v for k, v in kw.items()
                                     if k in self.float_style})
            self.update()

        def _float_path(self) -> QPainterPath:
            """粘贴图的轮廓（圆角矩形或直角矩形）：阴影/裁剪/描边都用它。"""
            path = QPainterPath()
            r = float(self.float_style.get("radius") or 0)
            rect = self.float_rect()
            if r > 0:
                r = min(r, rect.width() / 2.0, rect.height() / 2.0)
                path.addRoundedRect(rect, r, r)
            else:
                path.addRect(rect)
            return path

        def _draw_float(self, painter: QPainter) -> None:
            """把浮动图画到给定 painter（预览与合成共用，避免两处画法不一致）。"""
            if self._float_pix is None:
                return
            rect = self.float_rect()
            style = self.float_style
            painter.save()
            if self._float_angle:                  # 绕中心旋转后再画
                c = rect.center()
                painter.translate(c)
                painter.rotate(self._float_angle)
                painter.translate(-c)
            path = self._float_path()
            if style.get("shadow"):
                # 便宜的"软阴影"：几层逐渐变淡的偏移轮廓（做指引够用，不引入模糊库）
                for off, alpha in ((7, 46), (5, 62), (3, 86)):
                    painter.save()
                    painter.translate(off, off)
                    painter.fillPath(path, QColor(0, 0, 0, alpha))
                    painter.restore()
            painter.save()
            painter.setClipPath(path)
            painter.drawPixmap(rect, self._float_pix, QRectF(self._float_pix.rect()))
            painter.restore()
            if style.get("stroke"):
                painter.setPen(QPen(QColor(style.get("stroke_color", "#ffffff")),
                                    max(1, int(style.get("stroke_width", 3)))))
                painter.setBrush(Qt.NoBrush)
                painter.drawPath(path)
            painter.restore()

        def cancel_float(self) -> bool:
            """丢掉浮动图，底图不动。"""
            if self._float_pix is None:
                return False
            self._float_pix = None
            self._float_from = None
            self._float_handle = None
            self.float_changed.emit()
            self.set_tool_cursor()
            self.update()
            return True

        def scale_float(self, factor: float) -> bool:
            """以中心为锚点等比缩放浮动图（0.05×~12×）。"""
            if self._float_pix is None:
                return False
            r = self._float_rect_obj
            new_w = r.width() * factor
            max_w = self._float_pix.width() * 12.0
            min_w = max(8.0, self._float_pix.width() * 0.05)
            new_w = min(max_w, max(min_w, new_w))
            k = new_w / max(1.0, r.width())
            if abs(k - 1.0) < 1e-6:
                return False
            c = r.center()
            self._float_rect_obj = QRectF(c.x() - r.width() * k / 2.0,
                                          c.y() - r.height() * k / 2.0,
                                          r.width() * k, r.height() * k)
            self.update()
            return True

        def resize_float_by_handle(self, index: int, pos: QPointF,
                                   keep_aspect: bool = False) -> bool:
            """拖动某个手柄改浮动图大小（0~7 为边角，Shift 保持宽高比）。"""
            if self._float_pix is None or not 0 <= index <= 7:
                return False
            r = QRectF(self._float_rect_obj)
            x0, y0, x1, y1 = r.left(), r.top(), r.right(), r.bottom()
            if index in (0, 1, 2):
                y0 = pos.y()
            elif index in (4, 5, 6):
                y1 = pos.y()
            if index in (0, 6, 7):
                x0 = pos.x()
            elif index in (2, 3, 4):
                x1 = pos.x()
            # 角上的手柄按 Shift 保持原比例：以"被拖的角"为基准反推另一边
            if keep_aspect and index in (0, 2, 4, 6):
                w = abs(x1 - x0)
                h = abs(y1 - y0)
                if self._float_aspect > 0:
                    if w / max(1e-6, h) > self._float_aspect:
                        h = w / self._float_aspect
                    else:
                        w = h * self._float_aspect
                if index in (0, 6):
                    x0 = x1 - w if index == 0 else x0
                if index in (0, 2):
                    y0 = y1 - h if index == 0 else y0
                if index == 0:
                    x0, y0 = x1 - w, y1 - h
                elif index == 2:
                    x1, y0 = x0 + w, y1 - h
                elif index == 4:
                    x1, y1 = x0 + w, y0 + h
                elif index == 6:
                    x0, y1 = x1 - w, y0 + h
            new = QRectF(QPointF(min(x0, x1), min(y0, y1)),
                         QPointF(max(x0, x1), max(y0, y1))).normalized()
            # 太小就贴个下限，免得被拖成一条线再也抓不住
            if new.width() < 8 or new.height() < 8:
                return False
            self._float_rect_obj = new
            self.update()
            return True

        # ---------- 导出 ----------
        def render_result(self) -> QPixmap:
            """导出为图像物理像素的完整结果（无损，不做任何缩放）。"""
            w, h = self.base_pixmap.width(), self.base_pixmap.height()
            out = QPixmap(w, h)          # 先在 dpr=1 的工作画布上按物理像素绘制
            out.fill(Qt.transparent)
            p = QPainter(out)
            p.setRenderHint(QPainter.Antialiasing)
            p.setRenderHint(QPainter.TextAntialiasing)
            # 用显式源/目标矩形绘制，避免源 pixmap 的 dpr 影响落点尺寸
            p.drawPixmap(QRect(0, 0, w, h), self.base_pixmap,
                         QRect(0, 0, w, h))
            for shape in self.shapes:
                self._draw_shape(p, shape)
            # 还没固定的浮动粘贴也算进导出结果（"看到什么就存什么"）
            if self._float_pix is not None:
                p.setRenderHint(QPainter.SmoothPixmapTransform,
                                self.float_scale() < 1.0)
                self._draw_float(p)
                p.setRenderHint(QPainter.SmoothPixmapTransform, False)
            p.end()
            out.setDevicePixelRatio(self.dpr)   # 带上 dpr，显示按逻辑尺寸、像素不丢
            return out

        # ---------- 绘制 ----------
        def _draw_shape(self, painter: QPainter, shape):
            """按图形自身的旋转角绘制（绕外接矩形中心转）。

            旋转放在这里统一处理，各个 Shape.draw() 就不用管旋转了 ——
            否则矩形/椭圆/箭头/画笔/文字每一种都要自己算一遍。
            """
            rot = float(getattr(shape, "rotation", 0.0) or 0.0)
            if not rot:
                shape.draw(painter, self)
                return
            c = shape.bounding_rect().center()
            painter.save()
            painter.translate(c)
            painter.rotate(rot)
            painter.translate(-c)
            shape.draw(painter, self)
            painter.restore()

        def paintEvent(self, e):
            painter = QPainter(self)
            painter.setRenderHint(QPainter.Antialiasing)
            painter.setRenderHint(QPainter.TextAntialiasing)
            painter.save()
            painter.scale(self.zoom, self.zoom)
            # 缩小时用平滑滤波（不然文字发虚/锯齿）；放大时保持像素锐利；
            # 只对底图启用，马赛克等图形的像素化效果不受影响。
            painter.setRenderHint(QPainter.SmoothPixmapTransform, self.zoom < 1.0)
            painter.drawPixmap(0, 0, self.base_pixmap)
            painter.setRenderHint(QPainter.SmoothPixmapTransform, False)
            # ---- 图形用图像物理像素坐标，而底图是 dpr 感知绘制的
            #      （QPixmap 带 devicePixelRatio 时 Qt 按逻辑尺寸画，即 P/dpr）。
            #      所以图形这里要再缩 1/dpr 才能与底图对齐；否则 dpr≠1（系统缩放
            #      非 100%）时图形会偏 dpr 倍，表现为画图不跟手。
            #      画笔宽度写成 /zoom 表示屏幕像素，在这个坐标系里恰好等于
            #      设备像素，所以无需改动。
            painter.save()
            painter.scale(1.0 / self.dpr, 1.0 / self.dpr)
            for shape in self.shapes:
                self._draw_shape(painter, shape)
            if self._current is not None:
                self._draw_shape(painter, self._current)
            # 浮动粘贴：虚线框 + 8 个缩放手柄 + 1 个旋转手柄（表示"还能拖/缩/转"）
            if self._float_pix is not None:
                self._draw_float(painter)
                # 虚线框必须用**旋转后的四角**画，否则转过之后框还是正的（用户报过）
                pen = QPen(QColor(ACCENT), 1.6 / self.zoom)
                pen.setStyle(Qt.DashLine)
                painter.setPen(pen)
                painter.setBrush(Qt.NoBrush)
                painter.drawPolygon(QPolygonF(self.float_corners()))
                hs = HANDLE_SIZE / self.zoom
                handles = self.float_handles()
                painter.setPen(QPen(QColor(ACCENT), 1.2 / self.zoom))
                painter.setBrush(QColor("#ffffff"))
                for hp in handles[:8]:
                    painter.drawRect(QRectF(hp.x() - hs / 2, hp.y() - hs / 2, hs, hs))
                if len(handles) > 8:               # 旋转手柄：画个圆点 + 连接线
                    rp = handles[8]
                    corners = self.float_corners()
                    top_mid = QPointF((corners[0].x() + corners[1].x()) / 2.0,
                                      (corners[0].y() + corners[1].y()) / 2.0)
                    painter.setPen(QPen(QColor(ACCENT), 1.2 / self.zoom))
                    painter.drawLine(top_mid, rp)
                    painter.setBrush(QColor(ACCENT))
                    painter.drawEllipse(rp, hs * 0.6, hs * 0.6)
            # 选中框 + 缩放句柄（细实线 + 白色句柄，现代编辑器风格）
            if self._selected is not None and self.tool == "select":
                hs = HANDLE_SIZE / self.zoom
                corners = self._selected.rotated_corners()
                painter.setPen(QPen(QColor(ACCENT), 1.4 / self.zoom))
                painter.setBrush(Qt.NoBrush)
                painter.drawPolygon(QPolygonF(corners))      # 跟着旋转的选中框
                handles = self._selected.rotated_handles()
                painter.setPen(QPen(QColor(ACCENT), 1.2 / self.zoom))
                painter.setBrush(QColor("#ffffff"))
                for hp in handles[:8]:
                    painter.drawRect(QRectF(hp.x() - hs / 2, hp.y() - hs / 2, hs, hs))
                if len(handles) > 8:                         # 旋转手柄
                    top_mid = QPointF((corners[0].x() + corners[1].x()) / 2.0,
                                      (corners[0].y() + corners[1].y()) / 2.0)
                    painter.setPen(QPen(QColor(ACCENT), 1.2 / self.zoom))
                    painter.drawLine(top_mid, handles[8])
                    painter.setBrush(QColor(ACCENT))
                    painter.drawEllipse(handles[8], hs * 0.6, hs * 0.6)
            painter.restore()
            # 裁剪遮罩
            if self.tool == "crop" and self._crop_rect is not None:
                painter.save()
                painter.scale(1.0 / self.dpr, 1.0 / self.dpr)
                rect = self._crop_rect.normalized()
                full = QRectF(self.base_pixmap.rect())
                path = QPainterPath()
                path.addRect(full)
                path.addRect(rect)
                painter.fillPath(path, QColor(0, 0, 0, 130))
                painter.setPen(QPen(QColor(255, 255, 255), 1.5 / self.zoom, Qt.DashLine))
                painter.setBrush(Qt.NoBrush)
                painter.drawRect(rect)
                painter.restore()
                # 尺寸提示：画在屏幕坐标里，字号不随缩放变形
                painter.setPen(QPen(QColor(255, 255, 255)))
                painter.drawText(
                    self.to_widget(rect.bottomRight()) + QPointF(-70, -6),
                    f"{int(rect.width())} × {int(rect.height())}")
            painter.restore()
            # 取色工具的像素放大镜（窗口坐标，不随画布缩放）
            if self.tool == "pick" and self._hover_pos is not None:
                self._draw_pick_magnifier(painter)
            painter.end()

        # ---------- 取色放大镜 ----------
        PICK_CELL_N = 9     # 奇数格，正中心即取样像素
        PICK_CELL_PX = 22   # 每格屏幕像素

        def _draw_pick_magnifier(self, p: QPainter):
            n, cpx = self.PICK_CELL_N, self.PICK_CELL_PX
            size = n * cpx
            half = n // 2
            img = self.base_pixmap.toImage()
            src = self.to_image(self._hover_pos)
            cx, cy = int(src.x()), int(src.y())

            # 位置：光标右下，越界翻转，最后整体夹回画布内
            wx, wy = self._hover_pos.x() + 20, self._hover_pos.y() + 20
            if wx + size > self.width() - 4:
                wx = self._hover_pos.x() - size - 20
            if wy + size + 34 > self.height() - 4:
                wy = self._hover_pos.y() - size - 54
            wx = min(max(4.0, wx), max(4.0, self.width() - size - 4))
            wy = min(max(4.0, wy), max(4.0, self.height() - size - 34 - 4))
            wx, wy = int(wx), int(wy)

            # 逐像素填格（真实源像素，未经缩放混合）
            for j in range(n):
                for i in range(n):
                    px, py = cx + i - half, cy + j - half
                    if 0 <= px < img.width() and 0 <= py < img.height():
                        p.fillRect(wx + i * cpx, wy + j * cpx, cpx, cpx,
                                   img.pixelColor(px, py))
                    else:
                        p.fillRect(wx + i * cpx, wy + j * cpx, cpx, cpx,
                                   QColor(40, 40, 40))
            # 网格 + 外框
            p.setPen(QPen(QColor(255, 255, 255, 36), 1))
            p.setBrush(Qt.NoBrush)
            for i in range(1, n):
                p.drawLine(wx + i * cpx, wy, wx + i * cpx, wy + size)
                p.drawLine(wx, wy + i * cpx, wx + size, wy + i * cpx)
            p.setPen(QPen(QColor(255, 255, 255), 2))
            p.drawRect(wx, wy, size, size)
            # 红框标出实际取样的像素
            if 0 <= cx < img.width() and 0 <= cy < img.height():
                p.setPen(QPen(QColor(229, 57, 53), 2))
                p.drawRect(wx + half * cpx, wy + half * cpx, cpx, cpx)
                # 色值标签
                color = img.pixelColor(cx, cy)
                text = color.name().upper()
                metrics = p.fontMetrics()
                lw = metrics.horizontalAdvance(text) + 30
                lh = metrics.height() + 10
                p.setPen(Qt.NoPen)
                p.setBrush(QColor(0, 0, 0, 200))
                p.drawRoundedRect(wx, wy + size + 6, lw, lh, 4, 4)
                p.setBrush(color)
                p.drawRect(wx + 6, wy + size + 11, lh - 12, lh - 12)
                p.setPen(QColor(255, 255, 255))
                p.drawText(wx + lh, wy + size + 6 + metrics.ascent() + 5, text)


    class EditorWindow(QMainWindow):
        """FSCapture 风格编辑器主窗口。"""

        pin_requested = Signal(QPixmap)
        session_dirty = Signal()      # 内容变了，提示主程序缓存会话
        closing = Signal()            # 窗口要关了：趁标签还在赶紧存一次
        tabs_closed = Signal()        # 用户主动关掉了标签（缓存可以相应减少）
        capture_requested = Signal()   # 点顶栏"截图"按钮：去截下一张（会自动最小化编辑器）

        def __init__(self, pixmap: QPixmap | None = None, parent=None):
            super().__init__(parent)
            self.setWindowTitle(tr("PyShot 编辑器"))
            self._prev_tool = "select"
            # 跨标签共享的绘制属性（切标签/新截图沿用当前工具与样式）
            self._shared = {"tool": "select", "color": QColor(PALETTE[0]),
                            "pen_width": 3, "font_size": 20, "step_diameter": 36,
                            "float_style": {"shadow": False, "stroke": False,
                                            "radius": 0, "stroke_color": "#ffffff",
                                            "stroke_width": 3}}

            # 标签页：一次会话里的多张截图
            self.tabs = QTabWidget()
            self.tabs.setObjectName("canvasTabs")
            self.tabs.setMovable(True)
            self.tabs.setDocumentMode(True)
            self.tabs.tabCloseRequested.connect(self.close_tab)
            self.tabs.currentChanged.connect(self._on_tab_changed)

            central = QWidget()
            root = QVBoxLayout(central)
            root.setContentsMargins(0, 0, 0, 0)
            root.setSpacing(0)
            root.addWidget(self._build_topbar())       # 可换行的顶栏
            row = QHBoxLayout()
            row.setContentsMargins(0, 0, 0, 0)
            row.setSpacing(0)
            row.addWidget(self._build_toolbar())
            # 空状态：没有标签页时显示提示页，而不是一片空白
            self.empty_page = self._build_empty_page()
            self.stack = QStackedWidget()
            self.stack.addWidget(self.empty_page)
            self.stack.addWidget(self.tabs)
            row.addWidget(self.stack, 1)
            root.addLayout(row, 1)
            self.setCentralWidget(central)

            self._build_menubar()
            self._build_shortcuts()
            self._update_empty_state()
            # 工具条显隐沿用上次的选择（首次默认显示）
            try:
                if not _rail_visible_setting() and getattr(self, "tool_scroll", None):
                    self.tool_scroll.setVisible(False)
            except Exception:                          # noqa: BLE001
                pass

            if pixmap is not None:
                self.add_canvas(pixmap)
                w = min(int(pixmap.width() * self.canvas.zoom) + 190,
                        int(QGuiApplication.primaryScreen().availableGeometry().width() * 0.92))
                h = min(int(pixmap.height() * self.canvas.zoom) + 120,
                        int(QGuiApplication.primaryScreen().availableGeometry().height() * 0.92))
                self.resize(max(w, 760), max(h, 500))
            self._refresh_actions()

        # ---------- 标签页 ----------
        @property
        def canvas(self) -> "Canvas | None":
            """当前标签的画布。"""
            page = self.tabs.currentWidget()
            return page.widget() if isinstance(page, QScrollArea) else None

        @property
        def scroll(self) -> "QScrollArea | None":
            page = self.tabs.currentWidget()
            return page if isinstance(page, QScrollArea) else None

        # ---------- 空状态 ----------
        def _build_empty_page(self) -> QWidget:
            """没有图片时的提示页（编辑器可以直接打开，不必先选文件）。"""
            page = QWidget()
            lay = QVBoxLayout(page)
            lay.setAlignment(Qt.AlignCenter)
            title = QLabel(tr("还没有图片"))
            title.setObjectName("emptytitle")
            title.setAlignment(Qt.AlignCenter)
            hint = QLabel(tr("从「文件」菜单打开图片，或直接截图 / 从剪贴板粘贴"))
            hint.setObjectName("emptyhint")
            hint.setAlignment(Qt.AlignCenter)
            self.empty_hint = hint
            lay.addWidget(title)
            lay.addWidget(hint)
            return page

        def _update_empty_state(self):
            """按有没有标签页切换空状态；并把依赖图片的菜单项置灰。"""
            has = self.tabs.count() > 0
            try:
                self.stack.setCurrentWidget(self.tabs if has else self.empty_page)
            except Exception:                          # noqa: BLE001
                pass
            for act in getattr(self, "_needs_canvas", []):
                act.setEnabled(has)

        def _build_menubar(self):
            """菜单栏：文件 / 编辑 / 视图 / 特效 / 选项 / 帮助。"""
            bar = self.menuBar()
            bar.setObjectName("editorMenuBar")

            # ---------- 文件 ----------
            m_file = bar.addMenu(tr("文件"))
            self.menus = {"file": m_file}
            self.act_open_img = QAction(tr("打开图片…"), self)
            self.act_open_img.setShortcut("Ctrl+O")
            self.act_open_img.triggered.connect(self.open_image)
            m_file.addAction(self.act_open_img)
            act_clip = QAction(tr("打开剪贴板图片"), self)
            act_clip.setShortcut("Ctrl+Shift+V")
            act_clip.setToolTip(tr("把剪贴板里的图片作为**新标签**打开"))
            act_clip.triggered.connect(self.open_from_clipboard)
            m_file.addAction(act_clip)
            m_file.addSeparator()
            self.act_save = QAction(tr("保存"), self)
            self.act_save.setShortcut("Ctrl+S")
            self.act_save.triggered.connect(self.save_as)
            m_file.addAction(self.act_save)
            m_file.addSeparator()
            self.act_close_tab = QAction(tr("关闭当前标签"), self)
            self.act_close_tab.setShortcut("Ctrl+W")
            self.act_close_tab.triggered.connect(
                lambda: self.close_tab(self.tabs.currentIndex()))
            m_file.addAction(self.act_close_tab)
            act_quit = QAction(tr("退出"), self)
            act_quit.setShortcut("Ctrl+Q")
            act_quit.triggered.connect(self.close)
            m_file.addAction(act_quit)

            # ---------- 编辑 ----------
            m_edit = bar.addMenu(tr("编辑"))
            self.menus["edit"] = m_edit
            self.act_m_undo = QAction(tr("撤销"), self)
            self.act_m_undo.setShortcut("Ctrl+Z")
            self.act_m_undo.triggered.connect(lambda: self.canvas and self.canvas.undo())
            m_edit.addAction(self.act_m_undo)
            self.act_m_redo = QAction(tr("重做"), self)
            self.act_m_redo.setShortcut("Ctrl+Y")
            self.act_m_redo.triggered.connect(lambda: self.canvas and self.canvas.redo())
            m_edit.addAction(self.act_m_redo)
            m_edit.addSeparator()
            # 粘贴到当前图上（浮层：可拖动/缩放后再固定）——做指引时把两张截图拼一张
            self.act_paste = QAction(tr("粘贴到当前图（浮动）"), self)
            self.act_paste.setShortcut("Ctrl+V")
            self.act_paste.setToolTip(
                tr("把剪贴板里的截图贴到当前图上：拖动摆位置、Ctrl+滚轮缩放，"
                   "Enter 固定、Esc 取消"))
            self.act_paste.triggered.connect(self.paste_onto_current)
            m_edit.addAction(self.act_paste)
            self.act_paste_ok = QAction(tr("固定粘贴的图"), self)
            self.act_paste_ok.setToolTip(tr("把正在摆放的粘贴图合成进当前图（Enter）"))
            self.act_paste_ok.triggered.connect(self.commit_pasted)
            m_edit.addAction(self.act_paste_ok)
            self.act_paste_cancel = QAction(tr("取消粘贴"), self)
            self.act_paste_cancel.setToolTip(tr("丢掉正在摆放的粘贴图（Esc）"))
            self.act_paste_cancel.triggered.connect(self.discard_pasted)
            m_edit.addAction(self.act_paste_cancel)
            # 粘贴图外观：阴影/描边/圆角（做指引时让贴上去的图"浮起来"）
            menu_paste_style = QMenu(tr("粘贴图外观"), m_edit)
            self.act_ps_shadow = QAction(tr("加阴影"), self)
            self.act_ps_shadow.setCheckable(True)
            self.act_ps_shadow.toggled.connect(
                lambda on: self._float_style(shadow=on))
            menu_paste_style.addAction(self.act_ps_shadow)
            self.act_ps_stroke = QAction(tr("加白色描边"), self)
            self.act_ps_stroke.setCheckable(True)
            self.act_ps_stroke.toggled.connect(
                lambda on: self._float_style(stroke=on))
            menu_paste_style.addAction(self.act_ps_stroke)
            menu_paste_style.addSeparator()
            for label, radius in ((tr("直角"), 0), (tr("小圆角"), 10),
                                  (tr("大圆角"), 24)):
                act = QAction(label, self)
                act.triggered.connect(
                    lambda checked=False, r=radius: self._float_style(radius=r))
                menu_paste_style.addAction(act)
            m_edit.addMenu(menu_paste_style)
            m_edit.addSeparator()
            # 选中图形的层级 / 微调 / 再制（做指引时会叠好几层，顺序很要紧）
            self.act_front = QAction(tr("置于顶层"), self)
            self.act_front.triggered.connect(lambda: self._layer("front"))
            m_edit.addAction(self.act_front)
            self.act_back = QAction(tr("置于底层"), self)
            self.act_back.triggered.connect(lambda: self._layer("back"))
            m_edit.addAction(self.act_back)
            self.act_up = QAction(tr("上移一层"), self)
            self.act_up.triggered.connect(lambda: self._layer("up"))
            m_edit.addAction(self.act_up)
            self.act_down = QAction(tr("下移一层"), self)
            self.act_down.triggered.connect(lambda: self._layer("down"))
            m_edit.addAction(self.act_down)
            self.act_dup = QAction(tr("再制一个"), self)
            self.act_dup.setShortcut("Ctrl+D")
            self.act_dup.setToolTip(tr("复制选中的图形/文字，向右下错开一点"))
            self.act_dup.triggered.connect(self.duplicate_selected)
            m_edit.addAction(self.act_dup)
            self.act_rotate = QAction(tr("旋转 15°"), self)
            self.act_rotate.setToolTip(
                tr("把选中图形转 15°（拖它上面的圆形手柄可以任意角度）"))
            self.act_rotate.triggered.connect(lambda: self.rotate_selected(15))
            m_edit.addAction(self.act_rotate)
            self.act_rotate0 = QAction(tr("摆正（0°）"), self)
            self.act_rotate0.triggered.connect(lambda: self.rotate_selected(None))
            m_edit.addAction(self.act_rotate0)
            m_edit.addSeparator()
            self.act_edit_text = QAction(tr("修改文字…"), self)
            self.act_edit_text.setShortcut("F2")
            self.act_edit_text.setToolTip(tr("改选中文字的内容（也可以直接双击文字）"))
            self.act_edit_text.triggered.connect(self.edit_selected_text)
            m_edit.addAction(self.act_edit_text)
            self.act_font = QAction(tr("字体…"), self)
            self.act_font.setToolTip(
                tr("选字体/字号/粗体：选中文字就改它，否则改之后新写的文字"))
            self.act_font.triggered.connect(self.choose_font)
            m_edit.addAction(self.act_font)
            m_edit.addSeparator()
            self.act_m_copy = QAction(tr("复制到剪贴板"), self)
            self.act_m_copy.setShortcut("Ctrl+C")
            self.act_m_copy.triggered.connect(self.copy_to_clipboard)
            m_edit.addAction(self.act_m_copy)
            self.act_m_pin = QAction(tr("贴图到屏幕"), self)
            self.act_m_pin.triggered.connect(self.pin_to_screen)
            m_edit.addAction(self.act_m_pin)

            # ---------- 视图 ----------
            m_view = bar.addMenu(tr("视图"))
            self.menus["view"] = m_view
            self.act_zoom_in = QAction(tr("放大"), self)
            self.act_zoom_in.setShortcut("Ctrl+=")
            self.act_zoom_in.triggered.connect(lambda: self._zoom_step(1.25))
            m_view.addAction(self.act_zoom_in)
            self.act_zoom_out = QAction(tr("缩小"), self)
            self.act_zoom_out.setShortcut("Ctrl+-")
            self.act_zoom_out.triggered.connect(lambda: self._zoom_step(1 / 1.25))
            m_view.addAction(self.act_zoom_out)
            self.act_zoom_100 = QAction(tr("实际像素 (1:1)"), self)
            self.act_zoom_100.setShortcut("Ctrl+0")
            self.act_zoom_100.triggered.connect(lambda: self._set_zoom(1.0))
            m_view.addAction(self.act_zoom_100)
            self.act_zoom_fit = QAction(tr("适应窗口"), self)
            self.act_zoom_fit.triggered.connect(self.fit_to_window)
            m_view.addAction(self.act_zoom_fit)
            m_view.addSeparator()
            # 工具条可以整条收起（屏幕小/想要更宽的画布时；工具快捷键仍然可用）
            self.act_rail = QAction(tr("显示左侧工具条"), self)
            self.act_rail.setCheckable(True)
            self.act_rail.setChecked(_rail_visible_setting())
            self.act_rail.setToolTip(
                tr("工具条可以滚动；嫌占地方就整条收起（工具快捷键依然可用）"))
            self.act_rail.toggled.connect(self.set_rail_visible)
            m_view.addAction(self.act_rail)

            # ---------- 特效 ----------
            # （画布翻转/旋转 90°/改尺寸 放在这里：都属于"整张图的变换"）
            m_fx = bar.addMenu(tr("特效"))
            self.menus["fx"] = m_fx
            self.act_m_wm = QAction(tr("水印…"), self)
            self.act_m_wm.triggered.connect(self.add_watermark)
            m_fx.addAction(self.act_m_wm)
            self.act_m_border = QAction(tr("边框…"), self)
            self.act_m_border.triggered.connect(self.add_border)
            m_fx.addAction(self.act_m_border)
            m_fx.addSeparator()
            self.act_flip_h = QAction(tr("水平翻转"), self)
            self.act_flip_h.setToolTip(tr("左右镜像（标注也跟着翻，可 Ctrl+Z 撤销）"))
            self.act_flip_h.triggered.connect(self.flip_h)
            m_fx.addAction(self.act_flip_h)
            self.act_flip_v = QAction(tr("垂直翻转"), self)
            self.act_flip_v.setToolTip(tr("上下镜像（标注也跟着翻，可 Ctrl+Z 撤销）"))
            self.act_flip_v.triggered.connect(self.flip_v)
            m_fx.addAction(self.act_flip_v)
            self.act_rot90 = QAction(tr("顺时针 90°"), self)
            self.act_rot90.triggered.connect(lambda: self.rot90(True))
            m_fx.addAction(self.act_rot90)
            self.act_rot270 = QAction(tr("逆时针 90°"), self)
            self.act_rot270.triggered.connect(lambda: self.rot90(False))
            m_fx.addAction(self.act_rot270)
            self.act_resize_img = QAction(tr("调整尺寸…"), self)
            self.act_resize_img.setToolTip(tr("按像素重设整张图（含标注），可 Ctrl+Z 撤销"))
            self.act_resize_img.triggered.connect(self.resize_image)
            m_fx.addAction(self.act_resize_img)

            # ---------- 选项 ----------
            m_opt = bar.addMenu(tr("选项"))
            self.menus["options"] = m_opt
            self.menu_lang = QMenu(tr("语言"), m_opt)
            self.menu_lang.aboutToShow.connect(self._rebuild_language_menu)
            m_opt.addMenu(self.menu_lang)
            m_opt.addSeparator()
            self.act_restore = QAction(tr("启动时恢复上次的截图"), self)
            self.act_restore.setCheckable(True)
            try:

                self.act_restore.setChecked(session_enabled())
            except Exception:                          # noqa: BLE001
                self.act_restore.setChecked(True)
            self.act_restore.setToolTip(
                tr("重启后自动把上次编辑的截图放回来（存在缓存里，不需要你保存）"))
            self.act_restore.toggled.connect(self._toggle_restore_session)
            m_opt.addAction(self.act_restore)
            m_opt.addSeparator()
            # 想截编辑器本身（写文档/做教程）时必须打开这条：否则一按截图，
            # 编辑器自己就最小化让位了，截不到它。
            self.act_keep_editor = QAction(tr("截图时不最小化编辑器"), self)
            self.act_keep_editor.setCheckable(True)
            self.act_keep_editor.setChecked(keep_editor_on_capture())
            self.act_keep_editor.setToolTip(
                tr("打开后截图时编辑器留在原地，方便截编辑器自己；"
                   "平时关着（截图时自动让位，免得被拍进图里）"))
            self.act_keep_editor.toggled.connect(self._toggle_keep_editor)
            m_opt.addAction(self.act_keep_editor)
            m_opt.addSeparator()
            self.act_clear_session = QAction(tr("清除上次的截图缓存"), self)
            self.act_clear_session.triggered.connect(self._clear_session_cache)
            m_opt.addAction(self.act_clear_session)
            m_opt.addSeparator()
            self.act_default_wm = QAction(tr("编辑默认水印…"), self)
            self.act_default_wm.triggered.connect(self.edit_default_watermark)
            m_opt.addAction(self.act_default_wm)
            self.act_default_border = QAction(tr("编辑默认边框…"), self)
            self.act_default_border.triggered.connect(self.edit_default_border)
            m_opt.addAction(self.act_default_border)

            # ---------- 帮助 ----------
            m_help = bar.addMenu(tr("帮助"))
            self.menus["help"] = m_help
            act_about = QAction(tr("关于 PyShot"), self)
            act_about.triggered.connect(self.show_about)
            m_help.addAction(act_about)

            # 依赖图片的菜单项：空状态时置灰
            self._needs_canvas = [self.act_save, self.act_close_tab, self.act_m_undo,
                                  self.act_m_redo, self.act_m_copy, self.act_m_pin,
                                  self.act_zoom_in, self.act_zoom_out,
                                  self.act_zoom_100, self.act_zoom_fit,
                                  self.act_m_wm, self.act_m_border]
            return bar

        def _rebuild_language_menu(self):
            """选项 → 语言（三种语言 + 跟随系统）。"""

            self.menu_lang.clear()
            cur = saved_language()
            for code, name in LANGUAGES:
                act = QAction(name, self.menu_lang)
                act.setCheckable(True)
                act.setChecked(cur == code)
                act.triggered.connect(
                    lambda checked=False, c=code: self._switch_language(c))
                self.menu_lang.addAction(act)
            self.menu_lang.addSeparator()
            act_auto = QAction(
                tr("跟随系统") + f"（{language_name(system_language())}）",
                self.menu_lang)
            act_auto.setCheckable(True)
            act_auto.setChecked(cur == AUTO)
            act_auto.triggered.connect(lambda: self._switch_language(AUTO))
            self.menu_lang.addAction(act_auto)

        def _switch_language(self, code: str):

            lang = set_language(code)
            self.retranslate()
            self.statusBar().showMessage(
                tr("界面语言已切换") + f"：{language_name(lang)}", 4000)

        # ---------- 文件 ----------
        def open_image(self):
            """从「文件 → 打开图片」载入图片（在编辑器内直接开）。"""
            path, _ = QFileDialog.getOpenFileName(
                self, tr("打开图片"), str(Path.home()),
                tr("图片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp)"))
            if not path:
                return
            pix = QPixmap(path)
            if not pix.isNull():
                self.add_canvas(pix)

        def open_from_clipboard(self):
            """把剪贴板里的图片作为新标签打开。"""
            img = QApplication.clipboard().image()
            if img is None or img.isNull():
                self.statusBar().showMessage(tr("剪贴板里没有图片"), 3000)
                return
            self.add_canvas(QPixmap.fromImage(img))

        def paste_onto_current(self):
            """把剪贴板里的截图**贴到当前这张图上**（浮层，摆好位置再固定）。

            和「打开剪贴板图片」（新标签）的区别：这条是"在现有图上继续拼"——
            贴上去是一个虚线框的浮动层，可以拖着摆位置、Ctrl+滚轮缩放，
            Enter（或双击）固定进图、Esc 丢弃；固定后 Ctrl+Z 可撤销。
            没有打开的图时退回"新标签"，不然用户按 Ctrl+V 会以为没反应。
            """
            canvas = self.canvas
            # 正在画布上输入文字时，Ctrl+V 应该粘贴**文字**，不能贴图
            edit = getattr(canvas, "_text_edit", None) if canvas is not None else None
            if edit is not None:
                edit.paste()
                return
            img = QApplication.clipboard().image()
            if img is None or img.isNull():
                self.statusBar().showMessage(tr("剪贴板里没有图片"), 3000)
                return
            pix = QPixmap.fromImage(img)
            if canvas is None:
                self.add_canvas(pix)
                return
            # 手上还有一个没固定的：先固定它，再贴新的 —— 否则会被直接覆盖丢掉
            if canvas.has_float():
                canvas.commit_float()
            canvas.start_float(pix)
            self.statusBar().showMessage(
                tr("已粘贴到当前图：拖动摆位置 · 拖手柄缩放、拖上方圆点旋转 · "
                   "Enter 固定 · Esc 取消"),
                6000)
            self._refresh_actions()

        def commit_pasted(self):
            """把正在摆放的浮动粘贴固定进图（菜单项用）。"""
            canvas = self.canvas
            if canvas is not None and canvas.has_float():
                canvas.commit_float()
                self.statusBar().showMessage(tr("已固定粘贴的图（Ctrl+Z 可撤销）"), 4000)

        # ---------- 选中图形的层级 / 再制 / 旋转 ----------
        def _layer(self, how: str):
            """调整选中图形的叠放顺序：front/back/up/down。"""
            canvas = self.canvas
            shape = canvas._selected if canvas is not None else None
            if shape is None or shape not in canvas.shapes:
                self.statusBar().showMessage(tr("先选一个图形（用「选择」工具点一下）"), 3000)
                return
            canvas.push_undo()
            i = canvas.shapes.index(shape)
            canvas.shapes.pop(i)
            if how == "front":
                canvas.shapes.append(shape)
            elif how == "back":
                canvas.shapes.insert(0, shape)
            elif how == "up":
                canvas.shapes.insert(min(len(canvas.shapes), i + 1), shape)
            else:
                canvas.shapes.insert(max(0, i - 1), shape)
            canvas.update()
            canvas.shapes_changed.emit()

        def duplicate_selected(self):
            """再制选中图形（错开 12px），新图形成为当前选中。"""
            canvas = self.canvas
            shape = canvas._selected if canvas is not None else None
            if shape is None or shape not in canvas.shapes:
                self.statusBar().showMessage(tr("先选一个图形（用「选择」工具点一下）"), 3000)
                return
            canvas.push_undo()
            dup = shape.clone()
            dup.move_by(12, 12)
            canvas.shapes.append(dup)
            canvas._selected = dup
            canvas.selection_changed.emit(dup)
            canvas.update()
            canvas.shapes_changed.emit()
            self.statusBar().showMessage(tr("已再制一个（Ctrl+Z 可撤销）"), 3000)

        def _on_canvas_context(self, what: str):
            """画布右键菜单的动作分发。"""
            if what in ("front", "up", "down", "back"):
                self._layer(what)
            elif what == "dup":
                self.duplicate_selected()
            elif what == "rot15":
                self.rotate_selected(15)
            elif what == "rot0":
                self.rotate_selected(None)
            elif what == "edit_text":
                self.edit_selected_text()

        def _selected_text(self):
            """当前选中的文字图形（没选中文字就返回 None）。"""
            canvas = self.canvas
            shape = canvas._selected if canvas is not None else None
            if isinstance(shape, TextShape) and shape in canvas.shapes:
                return shape, canvas
            return None, canvas

        def edit_selected_text(self):
            """改选中文字的内容（等效于双击它）。"""
            shape, canvas = self._selected_text()
            if shape is None:
                self.statusBar().showMessage(
                    tr("先选一段文字（用「选择」工具点一下，或直接双击文字）"), 3000)
                return
            canvas._open_text_editor(shape.pos, target=shape)

        def choose_font(self):
            """选字体/字号/粗体：选中文字就改它，否则作为新文字的默认。"""
            shape, canvas = self._selected_text()
            cur = QFont(shape.font()) if shape is not None else QFont(
                getattr(canvas, "font_family", "") or "Microsoft YaHei")
            if shape is None and canvas is not None:
                cur.setPixelSize(int(canvas.font_size))
            ok, font = QFontDialog.getFont(cur, self, tr("选择字体"))
            if not ok:
                return
            family = font.family()
            size = int(font.pixelSize()) if font.pixelSize() > 0 else int(
                font.pointSizeF() * 1.33) or 20
            bold = font.bold()
            if shape is not None:
                canvas.push_undo()
                shape.family = family
                shape.font_size = max(8, size)
                shape.bold = bold
                self.font_spin.setValue(shape.font_size)   # 让工具栏跟着变
                canvas.update()
                canvas.shapes_changed.emit()
                self.statusBar().showMessage(tr("已改字体（Ctrl+Z 可撤销）"), 3000)
                return
            if canvas is not None:
                canvas.font_family = family
                canvas.font_size = max(8, size)
            self.font_spin.setValue(max(10, min(96, size)))
            self.statusBar().showMessage(tr("之后的文字用这个字体"), 3000)

        def rotate_selected(self, degrees: float | None):
            """旋转选中图形；degrees=None 表示摆正（回到 0°）。"""
            canvas = self.canvas
            shape = canvas._selected if canvas is not None else None
            if shape is None or shape not in canvas.shapes:
                self.statusBar().showMessage(tr("先选一个图形（用「选择」工具点一下）"), 3000)
                return
            canvas.push_undo()
            if degrees is None:
                shape.rotation = 0.0
            else:
                shape.rotate_by(degrees)
            canvas.update()
            canvas.shapes_changed.emit()
            self.statusBar().showMessage(
                tr("旋转 {:.0f}°（Ctrl+Z 可撤销）", float(getattr(shape, "rotation", 0))),
                3000)

        def discard_pasted(self):
            """丢弃正在摆放的浮动粘贴。"""
            canvas = self.canvas
            if canvas is not None and canvas.has_float():
                canvas.cancel_float()
                self.statusBar().showMessage(tr("已取消粘贴"), 3000)

        def _float_style(self, **kw):
            """改粘贴图外观；这次没有浮层时也记住，下次粘贴就带上。"""
            for i in range(self.tabs.count()):
                c = self.tabs.widget(i).widget()
                if isinstance(c, Canvas):
                    c.set_float_style(**kw)
            if self._shared is not None:
                self._shared.setdefault("float_style", {}).update(kw)

        # ---------- 画布变换（菜单入口）----------
        def flip_h(self):
            if self.canvas is not None:
                self.canvas.flip_horizontal()
                self.statusBar().showMessage(tr("已水平翻转（Ctrl+Z 可撤销）"), 3000)

        def flip_v(self):
            if self.canvas is not None:
                self.canvas.flip_vertical()
                self.statusBar().showMessage(tr("已垂直翻转（Ctrl+Z 可撤销）"), 3000)

        def rot90(self, clockwise: bool = True):
            if self.canvas is not None:
                self.canvas.rotate90(clockwise)
                self.statusBar().showMessage(
                    tr("已旋转 90°（Ctrl+Z 可撤销）") if clockwise
                    else tr("已逆时针旋转 90°（Ctrl+Z 可撤销）"), 3000)

        def resize_image(self):
            """调整尺寸对话框：按像素重设整张图（含标注）。"""
            canvas = self.canvas
            if canvas is None:
                return
            w, h = canvas.base_pixmap.width(), canvas.base_pixmap.height()
            new_w, ok = QInputDialog.getInt(
                self, tr("调整尺寸"), tr("宽度（像素，当前 {}）", w), w, 8, 20000, 1)
            if not ok:
                return
            new_h, ok = QInputDialog.getInt(
                self, tr("调整尺寸"), tr("高度（像素，当前 {}）", h), h, 8, 20000, 1)
            if not ok:
                return
            canvas.scale_canvas(new_w, new_h)
            self.statusBar().showMessage(
                tr("已调整为 {} × {}（Ctrl+Z 可撤销）", new_w, new_h), 4000)

        def show_about(self):
            """关于：一句话 + 版本号 + 主要能力（三语齐全）。"""
            QMessageBox.about(
                self, tr("关于 PyShot"),
                tr("PyShot {} — {}\n"
                   "仿 FastStone Capture 的截图与标注工具\n\n"
                   "托盘右键：区域截图 / 全屏截图 / 滚动长截图 / 屏幕取色 / 贴图\n"
                   "编辑器：多标签标注 · 粘贴拼图 · 水印 · 加边框（含手撕纸）· 三语界面",
                   APP_VERSION, tr(VERSION_TITLE)))

        def _toggle_restore_session(self, on: bool):
            try:

                set_session_enabled(bool(on))
                if not on:
                    clear_session()
            except Exception:                          # noqa: BLE001
                pass

        def _toggle_keep_editor(self, on: bool):
            """「截图时不最小化编辑器」开关：存进设置，主程序截图时读它。"""
            try:

                set_setting(KEEP_EDITOR_SETTING, bool(on))
            except Exception:                          # noqa: BLE001
                pass
            self.statusBar().showMessage(
                tr("已开启：截图时编辑器留在原地（方便截编辑器自己）") if on
                else tr("已关闭：截图时编辑器自动最小化让位"), 4000)

        def set_rail_visible(self, on: bool, persist: bool = True):
            """显示/收起左侧工具条（收起后画布更宽，工具快捷键照旧可用）。"""
            if persist:
                try:

                    set_setting(RAIL_VISIBLE_SETTING, bool(on))
                except Exception:                      # noqa: BLE001
                    pass
            scroll = getattr(self, "tool_scroll", None)
            if scroll is not None:
                scroll.setVisible(bool(on))
            act = getattr(self, "act_rail", None)
            if act is not None and act.isChecked() != bool(on):
                act.blockSignals(True)
                act.setChecked(bool(on))
                act.blockSignals(False)
            self.statusBar().showMessage(
                tr("已收起左侧工具条（工具快捷键仍可用；想恢复：视图菜单）") if not on
                else tr("已显示左侧工具条"), 4000)

        def _clear_session_cache(self):
            """手动清掉上次的截图缓存（不影响当前打开的标签）。"""
            try:

                clear_session()
                self.statusBar().showMessage(tr("已清除上次的截图缓存"), 3000)
            except Exception:                          # noqa: BLE001
                pass

        def edit_default_watermark(self):
            """编辑"新截图自动加的水印"（不作用于当前标签）。"""

            wm_save = save_default
            canvas = self.canvas
            size = canvas.base_pixmap.size() if canvas else QSize(640, 400)
            dlg = WatermarkDialog(self, load_default(), size)
            if dlg.exec() == QDialog.Accepted:
                settings = dlg.settings()
                settings["auto"] = True
                wm_save(settings)
                self.statusBar().showMessage(
                    tr("已设为默认水印，之后每次新截图会自动添加"), 4000)

        def edit_default_border(self):
            """编辑"新截图自动加的边框"（不作用于当前标签）。"""

            bd_save = save_border_default
            canvas = self.canvas
            size = canvas.base_pixmap.size() if canvas else QSize(640, 400)
            dlg = BorderDialog(self, load_border_default(), size)
            if dlg.exec() == QDialog.Accepted:
                settings = dlg.settings()
                settings["auto"] = True
                bd_save(settings)
                self.statusBar().showMessage(
                    tr("已设为默认边框，之后每次新截图会自动加"), 4000)

        def _zoom_step(self, factor: float):
            canvas = self.canvas
            if canvas is None:
                return
            canvas.fit_mode = False                    # 手动缩放 → 退出适应模式
            canvas.set_zoom(canvas.zoom * factor)

        def _set_zoom(self, zoom: float):
            canvas = self.canvas
            if canvas is not None:
                canvas.fit_mode = False                # 指定缩放 → 退出适应模式
                canvas.set_zoom(zoom)

        def fit_to_window(self):
            scroll = self.scroll
            canvas = self.canvas
            if canvas is not None and scroll is not None:
                self._fit_canvas(canvas, scroll)

        # ---------- 会话（记住上次的截图）----------
        def session_tabs(self) -> list:
            """导出本窗口所有标签（底图 + 标注 + 缩放 + 标题）。"""
            out = []
            for i in range(self.tabs.count()):
                scroll = self.tabs.widget(i)
                canvas = scroll.widget() if isinstance(scroll, QScrollArea) else None
                if not isinstance(canvas, Canvas):
                    continue
                out.append({"title": self.tabs.tabText(i),
                            "zoom": float(canvas.zoom),
                            "pixmap": canvas.base_pixmap,
                            "shapes": list(canvas.shapes)})
            return out

        def restore_session(self, tabs: list):
            """把上次的标签放回来（含标注）。"""
            for tab in tabs:
                canvas = self.add_canvas(tab["pixmap"], tab.get("title"))
                for sh in tab.get("shapes", []):
                    canvas.shapes.append(sh)
                try:
                    canvas.set_zoom(float(tab.get("zoom", 1.0) or 1.0))
                except Exception:                      # noqa: BLE001
                    pass
                canvas.update()
                canvas.shapes_changed.emit()

        def notify_session_saved(self):
            """让主程序知道"内容变了，该更新会话缓存了"。"""
            self.session_dirty.emit()

        def add_canvas(self, pixmap: QPixmap, title: str | None = None) -> Canvas:
            """新增一个截图标签页并切换过去。"""
            canvas = Canvas(pixmap)
            canvas.tool = self._shared["tool"]
            canvas.color = QColor(self._shared["color"])
            canvas.pen_width = self._shared["pen_width"]
            canvas.font_size = self._shared["font_size"]
            canvas.step_diameter = self._shared["step_diameter"]
            canvas.set_float_style(**self._shared.get("float_style", {}))
            canvas.setCursor(Qt.CrossCursor if canvas.tool != "select" else Qt.ArrowCursor)
            canvas.shapes_changed.connect(self._refresh_actions)
            canvas.float_changed.connect(self._refresh_actions)
            canvas.context_action.connect(self._on_canvas_context)
            canvas.color_picked.connect(self._on_color_picked)
            canvas.selection_changed.connect(self._on_selection_changed)
            canvas.escape_idle.connect(self.close)  # 空闲时 Esc 关闭编辑器
            canvas.zoom_changed.connect(lambda z, c=canvas: self._on_canvas_zoom(c, z))

            scroll = QScrollArea()
            canvas._scroll_area = scroll            # 拖动查看时要用它调滚动条
            scroll.setWidget(canvas)
            scroll.setWidgetResizable(False)
            scroll.setAlignment(Qt.AlignCenter)

            idx = self.tabs.addTab(scroll, title or tr("截图 {}").format(self.tabs.count() + 1))
            self.tabs.setTabToolTip(
                idx, f"{pixmap.width()} × {pixmap.height()} px\n"
                     + tr("滚轮/Ctrl+滚轮 缩放 · 中键或空格拖动查看"))
            # 自定义关闭按钮（自带图标在深色主题下几乎看不见）
            close_btn = QToolButton()
            close_btn.setObjectName("tabclose")
            close_btn.setText("✕")
            close_btn.setToolTip(tr("关闭此标签 (Ctrl+W)"))
            close_btn.setCursor(Qt.PointingHandCursor)
            close_btn.clicked.connect(lambda _=False, page=scroll: self._close_page(page))
            self.tabs.tabBar().setTabButton(idx, QTabBar.RightSide, close_btn)

            self.tabs.setCurrentIndex(idx)
            self._fit_canvas(canvas, scroll)
            # 设为默认的水印 / 边框：新截图自动加上（可 Ctrl+Z 撤销）
            defaults = load_default()
            if defaults.get("auto"):
                canvas.push_undo()
                canvas.shapes.append(WatermarkShape(defaults,
                                                    canvas.base_pixmap.size()))
            try:

                bcfg = load_border_default()
                if bcfg.get("auto"):
                    canvas.apply_border(bcfg)      # 内部会 push_undo，可撤销
            except Exception:                      # noqa: BLE001
                pass
            self._update_empty_state()             # 有标签了：收起空状态、放开菜单
            self.session_dirty.emit()
            return canvas

        def closeEvent(self, e):
            """关窗口前把会话存一次。

            不然窗口一关、标签就没了，之后点「显示编辑器」只能得到空白窗口 ——
            用户会觉得"历史不见了"（就是这么被反馈的）。
            """
            try:
                self.closing.emit()
            except Exception:                          # noqa: BLE001
                pass
            super().closeEvent(e)

        def retranslate(self):
            """语言切换后刷新界面文案（画布与标注不受影响）。

            做法是"把当前显示的文案再翻译一次"：i18n 内部有译文→原文的反查，
            所以英文/繁体文本也能翻译回目标语言，反复切换不会错乱。
            """
            _tr = tr
            self.setWindowTitle(_tr("PyShot 编辑器"))
            # 通用扫描：按钮 / 标签 / 复选框 / 分组框的文本与提示
            for w in self.findChildren(object):
                try:
                    if hasattr(w, "text") and callable(getattr(w, "setText", None)):
                        txt = w.text()
                        if txt:
                            w.setText(_tr(txt))
                    if hasattr(w, "setToolTip"):
                        tip = w.toolTip()
                        if tip:
                            w.setToolTip(_tr(tip))
                except Exception:                      # noqa: BLE001
                    continue
            # 工具轨道与状态栏
            try:
                for tid, name, tip in TOOLS:
                    btn = self.tool_buttons.get(tid)
                    if btn is not None:
                        btn.setToolTip(_tr("{} — {}", _tr(name), _tr(tip)))
                self.set_tool(self.tool)
            except Exception:                          # noqa: BLE001
                pass

        def close_tab(self, idx: int):
            page = self.tabs.widget(idx)
            if page is not None:
                self._close_page(page)

            self.tabs_closed.emit()
        def _close_page(self, page):
            idx = self.tabs.indexOf(page)
            if idx < 0:
                return
            self.tabs.removeTab(idx)
            self._update_empty_state()
            page.setParent(None)
            page.deleteLater()
            if self.tabs.count() == 0:
                self.close()          # 关掉最后一个标签 → 关闭编辑器
            else:
                self._on_tab_changed(self.tabs.currentIndex())

        def _on_tab_changed(self, idx: int):
            canvas = self.canvas
            if canvas is None:
                return
            # 新标签沿用当前工具/颜色/线宽/字号
            canvas.tool = self._shared["tool"]
            canvas.color = QColor(self._shared["color"])
            canvas.pen_width = self._shared["pen_width"]
            canvas.font_size = self._shared["font_size"]
            canvas.step_diameter = self._shared["step_diameter"]
            canvas.set_float_style(**self._shared.get("float_style", {}))
            canvas.setCursor(Qt.CrossCursor if canvas.tool != "select" else Qt.ArrowCursor)
            self.zoom_label.setText(f"{round(canvas.zoom * 100)}%")
            self._refresh_swatch_state()
            self._refresh_actions()
            self._refresh_size_label()
            self._on_selection_changed(canvas._selected)

            QTimer.singleShot(0, self._autofit_current)
        def _on_canvas_zoom(self, canvas: Canvas, zoom: float):
            if canvas is self.canvas:
                self.zoom_label.setText(f"{round(zoom * 100)}%")
                self._refresh_size_label()

        def _refresh_size_label(self):
            canvas = self.canvas
            if canvas is None:
                return
            self.size_label.setText(
                f"{canvas.base_pixmap.width()} × {canvas.base_pixmap.height()} px")

        # ---------- 工具栏 ----------
        # 工具分组（用细线分隔），让工具轨道有清晰的层级
        _TOOL_GROUPS = [
            ["select"],
            ["rect", "ellipse", "line", "arrow", "pen"],
            ["step", "text", "highlight", "mosaic"],
            ["pick", "crop"],
            ["pan"],
        ]

        def _build_toolbar(self) -> QWidget:
            """左侧工具条：包一层滚动区，免得工具条把窗口的最小高度顶死。

            以前 13 个工具竖着排要 640px，窗口最小高度被顶到 782px —— 屏幕矮一点
            就没法把编辑器压小。现在工具条可以滚（鼠标滚轮也行），窗口能压到很矮；
            另外「视图 → 显示左侧工具条」可以整条收起。
            """
            bar = QFrame()
            bar.setObjectName("sidebar")
            bar.setAttribute(Qt.WA_StyledBackground, True)
            bar.setFrameShape(QFrame.NoFrame)      # 去掉默认立体边框
            v = QVBoxLayout(bar)
            # 左右留 3px：这样"44px 按钮 + 3+3" = 50px，正好塞进"56px 轨道 - 6px 滚动条"
            v.setContentsMargins(3, 10, 3, 8)
            v.setSpacing(4)
            self.tool_group = QButtonGroup(self)
            self.tool_group.setExclusive(True)
            self.tool_buttons = {}
            tips = {tid: (name, tip) for tid, name, tip in TOOLS}
            first_group = True
            for group in self._TOOL_GROUPS:
                if not first_group:
                    sep = QFrame()
                    sep.setObjectName("railsep")
                    sep.setFrameShape(QFrame.HLine)
                    v.addWidget(sep)
                first_group = False
                for tid in group:
                    name, tip = tips[tid]
                    btn = QToolButton()
                    btn.setObjectName("toolbtn")
                    btn.setIcon(make_tool_icon(tid))
                    btn.setIconSize(QSize(24, 24))
                    btn.setFixedSize(44, 42)
                    btn.setToolButtonStyle(Qt.ToolButtonIconOnly)
                    btn.setToolTip(tr("{} — {}", tr(name), tr(tip)))
                    btn.setCheckable(True)
                    btn.setCursor(Qt.PointingHandCursor)
                    btn.clicked.connect(lambda checked, t=tid: self.set_tool(t))
                    self.tool_group.addButton(btn)
                    self.tool_buttons[tid] = btn
                    v.addWidget(btn, 0, Qt.AlignHCenter)
            self.tool_buttons["select"].setChecked(True)
            v.addStretch(1)

            scroll = QScrollArea()
            scroll.setObjectName("railscroll")
            scroll.setWidget(bar)
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(QFrame.NoFrame)
            scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
            scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
            scroll.setFixedWidth(RAIL_WIDTH)
            # 只保证"能放下两三个按钮"，剩下的交给滚动 —— 这就是窗口能压矮的关键
            scroll.setMinimumHeight(RAIL_MIN_H)
            scroll.setSizePolicy(QSizePolicy.Fixed, QSizePolicy.Expanding)
            self.tool_rail = bar
            self.tool_scroll = scroll
            return scroll

        def _action_button(self, action: QAction) -> QToolButton:
            """把一个 QAction 包成普通按钮（用于流式顶栏）。"""
            btn = QToolButton()
            btn.setObjectName("topbtn")
            btn.setDefaultAction(action)
            btn.setCursor(Qt.PointingHandCursor)
            return btn

        _CTRL_H = 30          # 顶栏控件统一高度（对齐的关键）

        def _group(self, *widgets) -> QWidget:
            """把若干控件打包成"原子组"：换行时整组一起走，不会被拆散。"""
            box = QWidget()
            h = QHBoxLayout(box)
            h.setContentsMargins(0, 0, 0, 0)
            h.setSpacing(6)
            for w in widgets:
                h.addWidget(w)
            return box

        def _labeled(self, text: str, widget: QWidget) -> QWidget:
            """标签 + 控件的原子组（垂直居中，换行时不会分开）。"""
            lab = QLabel(text)
            lab.setAlignment(Qt.AlignVCenter | Qt.AlignRight)
            return self._group(lab, widget)

        def _top_sep(self) -> QFrame:
            """顶栏分组之间的细竖分隔线（与控件等高居中）。"""
            sep = QFrame()
            sep.setObjectName("topsep")
            sep.setFrameShape(QFrame.VLine)
            sep.setFixedSize(1, 20)
            return sep

        def _build_topbar(self):
            """顶栏：**两行有设计的分组**（不是随机换行）。

            第 1 行 = 截图 + 颜色 + 尺寸参数；第 2 行 = 编辑操作 + 输出操作。
            每行内部用流式布局，窗口过窄时该行内部才会继续折行；
            所有控件统一高度并垂直居中，保证水平基线对齐。
            """
            bar = QWidget()
            bar.setObjectName("topbar")
            bar.setAttribute(Qt.WA_StyledBackground, True)
            outer = QVBoxLayout(bar)
            outer.setContentsMargins(10, 8, 10, 8)
            outer.setSpacing(8)

            def row() -> FlowLayout:
                host = QWidget()
                fl = FlowLayout(host, margin=0, spacing=10)
                outer.addWidget(host)
                return fl

            # ---------- 第 1 行：截图 / 颜色 / 尺寸 ----------
            r1 = row()
            btn_shot = QPushButton(tr("截图"))
            btn_shot.setObjectName("primarybtn")
            btn_shot.setIcon(make_icon("camera"))
            btn_shot.setIconSize(QSize(17, 17))
            btn_shot.setFixedHeight(self._CTRL_H)
            btn_shot.setToolTip(tr("截取新区域\n会自动最小化编辑器，截完回到这里新增标签"))
            btn_shot.setCursor(Qt.PointingHandCursor)
            btn_shot.clicked.connect(self.capture_requested)
            self.btn_shot = btn_shot
            r1.addWidget(btn_shot)
            r1.addWidget(self._top_sep())

            color_label = QLabel(tr("颜色"))
            color_label.setAlignment(Qt.AlignVCenter)

            # 当前颜色：拾色器吸到的 / 点色板选的，都会实时反映在这里
            self.current_color_btn = QPushButton()
            self.current_color_btn.setObjectName("currentColor")
            self.current_color_btn.setFixedSize(28, 28)
            self.current_color_btn.setCursor(Qt.PointingHandCursor)
            self.current_color_btn.clicked.connect(self._pick_color)

            # 色板拼盘：两行网格（10 列），点一下即设为当前颜色
            palette_box = QWidget()
            grid = QGridLayout(palette_box)
            grid.setContentsMargins(0, 0, 0, 0)
            grid.setSpacing(3)
            self.color_buttons = []
            for i, hexs in enumerate(PALETTE):
                b = QPushButton()
                b.setObjectName("swatch")
                b.setFixedSize(18, 18)
                b.setStyleSheet(f"background:{hexs};")
                b.setToolTip(hexs)
                b.clicked.connect(lambda checked, c=hexs: self.set_color(QColor(c)))
                grid.addWidget(b, i // 10, i % 10)
                self.color_buttons.append(b)
            more_palette = QPushButton("▾")
            more_palette.setObjectName("swatchMore")
            more_palette.setFixedSize(18, 18)
            more_palette.setToolTip(tr("更多颜色…（基本颜色 + 自定义颜色）"))
            more_palette.clicked.connect(self._pick_from_palette)
            grid.addWidget(more_palette, 0, 10)
            more = QPushButton("…")
            more.setObjectName("swatchMore")
            more.setFixedSize(18, 18)
            more.setToolTip(tr("自定义颜色"))
            more.clicked.connect(self._pick_color)
            grid.addWidget(more, 1, 10)
            grid.setColumnStretch(10, 1)
            r1.addWidget(self._group(color_label, self.current_color_btn,
                                     palette_box))
            self._refresh_swatch_state()
            r1.addWidget(self._top_sep())

            self.width_spin = SpinBox()
            self.width_spin.setRange(1, 20)
            self.width_spin.setValue(self._shared["pen_width"])
            self.width_spin.setFixedHeight(self._CTRL_H)
            self.width_spin.setFixedWidth(62)
            self.width_spin.valueChanged.connect(self._on_width_changed)
            r1.addWidget(self._labeled(tr("线宽"), self.width_spin))

            self.font_spin = SpinBox()
            self.font_spin.setRange(10, 96)
            self.font_spin.setValue(self._shared["font_size"])
            self.font_spin.setFixedHeight(self._CTRL_H)
            self.font_spin.setFixedWidth(62)
            self.font_spin.valueChanged.connect(self._on_font_changed)
            r1.addWidget(self._labeled(tr("字号"), self.font_spin))

            self.step_spin = SpinBox()
            self.step_spin.setRange(16, 240)
            self.step_spin.setSingleStep(2)
            self.step_spin.setSuffix(" px")
            self.step_spin.setValue(int(self._shared["step_diameter"]))
            self.step_spin.setFixedHeight(self._CTRL_H)
            self.step_spin.setFixedWidth(80)
            self.step_spin.setToolTip(tr("序号圆的大小\n选中已有序号时可直接调整它的大小"))
            self.step_spin.valueChanged.connect(self._on_step_size_changed)
            r1.addWidget(self._labeled(tr("序号"), self.step_spin))

            # ---------- 第 2 行：编辑 / 输出 ----------
            r2 = row()
            self.act_undo = QAction(tr("撤销"), self)
            self.act_undo.setToolTip(tr("撤销 (Ctrl+Z)"))
            self.act_undo.triggered.connect(lambda: self.canvas and self.canvas.undo())
            self.act_redo = QAction(tr("重做"), self)
            self.act_redo.setToolTip(tr("重做 (Ctrl+Y)"))
            self.act_redo.triggered.connect(lambda: self.canvas and self.canvas.redo())
            self.act_crop_ok = QAction(tr("应用裁剪"), self)
            self.act_crop_ok.setToolTip(tr("应用裁剪框 (Enter)"))
            self.act_crop_ok.triggered.connect(
                lambda: self.canvas and self.canvas.apply_crop())
            act_copy = QAction(tr("复制"), self)
            act_copy.setToolTip(tr("复制到剪贴板 (Ctrl+C)"))
            act_copy.triggered.connect(self.copy_to_clipboard)
            act_pin = QAction(tr("贴图"), self)
            act_pin.setToolTip(tr("把当前结果钉在屏幕最上层（Snipaste 风格）"))
            act_pin.triggered.connect(self.pin_to_screen)
            act_wm = QAction(tr("水印"), self)
            act_wm.setToolTip(
                tr("水印：文字与图片可各自开关（也可同时用）\n"
                "九宫格位置或平铺、各自调不透明度、可旋转与设边距\n"
                "还能「应用并设为默认」，之后新截图自动加"))
            act_wm.triggered.connect(self.add_watermark)
            act_border = QAction(tr("边框"), self)
            act_border.setToolTip(
                tr("加边框（对应 FSCapture 的「特效 → 边缘」）\n"
                "单线/双线/虚线/圆角/投影阴影/立体浮雕/边缘渐隐/拍立得白边\n"
                "边框加在图片外面，图会变大；可 Ctrl+Z 撤销"))
            act_border.triggered.connect(self.add_border)
            act_save = QAction(tr("保存"), self)
            act_save.setToolTip(tr("保存为文件 (Ctrl+S)"))
            act_save.triggered.connect(self.save_as)
            act_close = QAction(tr("关闭"), self)
            act_close.setToolTip(tr("关闭编辑器 (Esc)"))
            act_close.triggered.connect(self.close)

            undo_btn = self._icon_button("undo", tr("撤销 (Ctrl+Z)"),
                                         lambda: self.canvas and self.canvas.undo())
            redo_btn = self._icon_button("redo", tr("重做 (Ctrl+Y)"),
                                         lambda: self.canvas and self.canvas.redo())
            self.btn_undo, self.btn_redo = undo_btn, redo_btn
            r2.addWidget(self._group(undo_btn, redo_btn))
            r2.addWidget(self._action_button(self.act_crop_ok))
            r2.addWidget(self._top_sep())
            for act in (act_copy, act_pin, act_wm, act_border, act_save,
                        act_close):
                r2.addWidget(self._action_button(act))

            self._build_statusbar_zoom()
            return bar

        def _icon_button(self, icon_name: str, tip: str, fn) -> QToolButton:
            btn = QToolButton()
            btn.setObjectName("topbtn")
            btn.setIcon(make_icon(icon_name))
            btn.setIconSize(QSize(18, 18))
            btn.setFixedSize(self._CTRL_H + 4, self._CTRL_H)
            btn.setToolTip(tip)
            btn.setCursor(Qt.PointingHandCursor)
            btn.clicked.connect(fn)
            return btn
            for act in (self.act_undo, self.act_redo, self.act_crop_ok,
                        act_copy, act_pin, act_wm, act_save, act_close):
                lay.addWidget(self._action_button(act))

            self._build_statusbar_zoom()
            return bar

        def _build_statusbar_zoom(self):
            """状态栏：左侧当前工具，右侧缩放胶囊。"""
            sb = self.statusBar()
            sb.setSizeGripEnabled(False)      # 去掉右下角的多余手柄
            self.tool_name_label = QLabel()
            self.tool_name_label.setObjectName("toolname")
            self.tool_name_label.setText(tr("工具：选择"))
            sb.addWidget(self.tool_name_label)
            self.size_label = QLabel("")
            self.size_label.setObjectName("sizelabel")
            sb.addPermanentWidget(self.size_label)
            zoom_group = QWidget()
            zoom_group.setObjectName("zoomgroup")
            zoom_group.setAttribute(Qt.WA_StyledBackground, True)
            zlay = QHBoxLayout(zoom_group)
            zlay.setContentsMargins(6, 2, 6, 2)
            zlay.setSpacing(2)

            def _zbtn(text, tip, fn, width=28):
                b = QPushButton(text)
                b.setObjectName("zoombtn")
                b.setFixedSize(width, 24)
                b.setToolTip(tip)
                b.clicked.connect(fn)
                return b

            zoom_out = _zbtn("−", tr("缩小 (Ctrl+滚轮)"),
                             lambda: self.canvas and self.canvas.set_zoom(self.canvas.zoom / 1.2))
            self.zoom_label = QLabel("100%")
            self.zoom_label.setObjectName("zoomlabel")
            self.zoom_label.setMinimumWidth(46)
            self.zoom_label.setAlignment(Qt.AlignCenter)
            zoom_in = _zbtn("＋", tr("放大 (Ctrl+滚轮)"),
                            lambda: self.canvas and self.canvas.set_zoom(self.canvas.zoom * 1.2))
            zlay.addWidget(zoom_out)
            zlay.addWidget(self.zoom_label)
            zlay.addWidget(zoom_in)
            sep = QFrame()
            sep.setObjectName("zoomsep")
            sep.setFrameShape(QFrame.VLine)
            zlay.addWidget(sep)
            zlay.addWidget(_zbtn("100%", tr("实际像素 (1:1)"),
                                 lambda: self.canvas and self.canvas.set_zoom(1.0), width=44))
            zlay.addWidget(_zbtn(tr("适应"), tr("缩放以适应窗口"),
                                 self._zoom_fit, width=44))
            sb.addPermanentWidget(zoom_group)

        def _build_shortcuts(self):
            # 注意：Ctrl+Z / Ctrl+Y / Ctrl+S / Ctrl+C / Ctrl+W / Ctrl+O 这些
            # **已经由菜单栏的 QAction 提供**，这里不能再注册一遍 ——
            # 同一个窗口里两个动作用同一个按键序列会被 Qt 判为"歧义"，
            # 结果是**两个都不触发**（Ctrl+Z 失效就是这么来的）。
            # 这里只放菜单里没有的：重做备选键、切标签、以及单字母工具键。
            for seq, fn in [
                ("Ctrl+Shift+Z", lambda: self.canvas and self.canvas.redo()),
                ("Ctrl+Tab", lambda: self.tabs.setCurrentIndex(
                    (self.tabs.currentIndex() + 1) % max(1, self.tabs.count()))),
            ]:
                a = QAction(self)
                a.setShortcut(QKeySequence(seq))
                a.triggered.connect(fn)
                self.addAction(a)
            # 工具快捷键
            for key, tid in zip("VRELAPSTHMIC", [t[0] for t in TOOLS]):
                a = QAction(self)
                a.setShortcut(QKeySequence(key))
                a.triggered.connect(lambda checked, t=tid: self.set_tool(t))
                self.addAction(a)

        def set_hotkey_hint(self, hotkey: str):
            """把当前生效的全局热键告知编辑器（显示在截图按钮提示里）。"""
            if not hasattr(self, "btn_shot"):
                return
            suffix = f"（{hotkey}）" if hotkey else ""
            self.btn_shot.setToolTip(
                tr("截取新区域{}\n会自动最小化编辑器，截完回到这里新增标签", suffix))

        # ---------- 行为 ----------
        def set_tool(self, tid: str):
            canvas = self.canvas
            if canvas is not None:
                canvas._commit_text()
            if tid != "pick":
                self._prev_tool = tid
            self._shared["tool"] = tid
            # 应用到所有标签，切换标签时保持一致
            for i in range(self.tabs.count()):
                c = self.tabs.widget(i).widget()
                if isinstance(c, Canvas):
                    c.tool = tid
                    c.cancel_crop() if tid != "crop" else None
                    c._selected = None
                    c._hover_pos = None
                    c.set_tool_cursor()            # 抓手工具显示手型
                    c.update()
            self.tool_buttons[tid].setChecked(True)
            # 工具条可滚动：用快捷键/取色切回来的工具也要滚进可见区
            try:
                if getattr(self, "tool_scroll", None) is not None:
                    self.tool_scroll.ensureWidgetVisible(self.tool_buttons[tid], 0, 12)
            except Exception:                          # noqa: BLE001
                pass
            self._refresh_actions()
            name = dict((t, n) for t, n, _ in TOOLS).get(tid, tid)
            self.tool_name_label.setText(tr("工具：") + tr(name))

        def _on_color_picked(self, color: QColor):
            self._refresh_swatch_state()
            self.statusBar().showMessage(
                tr("已取色") + f" {color.name().upper()}" + tr("，切回")
                + tr(dict((t, n) for t, n, _ in TOOLS)[self._prev_tool]) + tr(" 工具"),
                3000)
            self.set_tool(self._prev_tool)  # 取色后自动切回之前的工具

        def set_color(self, color: QColor):
            self._shared["color"] = QColor(color)
            for i in range(self.tabs.count()):
                c = self.tabs.widget(i).widget()
                if isinstance(c, Canvas):
                    c.color = QColor(color)
            self._refresh_swatch_state()

        def _on_width_changed(self, v: int):
            self._shared["pen_width"] = v
            for i in range(self.tabs.count()):
                c = self.tabs.widget(i).widget()
                if isinstance(c, Canvas):
                    c.pen_width = v

        def _on_font_changed(self, v: int):
            """字号：作用于新文字，同时实时调整**选中的文字**（和序号大小一致的手感）。"""
            self._shared["font_size"] = v
            for i in range(self.tabs.count()):
                c = self.tabs.widget(i).widget()
                if isinstance(c, Canvas):
                    c.font_size = v
            canvas = self.canvas
            shape = canvas._selected if canvas is not None else None
            if isinstance(shape, TextShape) and shape in canvas.shapes:
                if int(shape.font_size) != int(v):
                    canvas.push_undo()
                    shape.font_size = max(8, int(v))
                    canvas.update()
                    canvas.shapes_changed.emit()

        def _on_step_size_changed(self, v: int):
            """序号大小：作用于新序号，同时也实时调整选中的序号。"""
            self._shared["step_diameter"] = v
            for i in range(self.tabs.count()):
                c = self.tabs.widget(i).widget()
                if isinstance(c, Canvas):
                    c.step_diameter = v
            canvas = self.canvas
            if canvas is not None:
                canvas.resize_selected_step(v)

        def _on_selection_changed(self, shape):
            """选中序号时把它的实际大小同步到控件上（控件即所见：新序号也用这个值）。"""
            if not hasattr(self, "step_spin"):
                return
            if isinstance(shape, StepShape):
                d = int(round(shape.diameter))
                self.step_spin.blockSignals(True)
                self.step_spin.setValue(d)
                self.step_spin.blockSignals(False)
                self._shared["step_diameter"] = d
                for i in range(self.tabs.count()):
                    c = self.tabs.widget(i).widget()
                    if isinstance(c, Canvas):
                        c.step_diameter = d

        def _refresh_swatch_state(self):
            canvas = self.canvas
            cur = canvas.color.name() if canvas is not None else self._shared["color"].name()
            for b, hexs in zip(self.color_buttons, PALETTE):
                b.setProperty("selected", QColor(hexs).name() == cur)
                b.style().unpolish(b)
                b.style().polish(b)
            # 当前颜色按钮：背景就是当前色，提示里带上色值
            try:
                name = QColor(self._shared["color"]).name()
                self.current_color_btn.setStyleSheet(
                    f"background:{name}; border:2px solid #ffffff;"
                    "border-radius:6px;")
                self.current_color_btn.setToolTip(tr("当前颜色") + f"  {name}")
            except Exception:                          # noqa: BLE001
                pass

        def _pick_from_palette(self):
            """打开大调色板（系统拾色盘风格）。"""
            dlg = ColorPaletteDialog(self, self._shared["color"])
            if dlg.exec() == QDialog.Accepted:
                self.set_color(dlg.selected())

        def _pick_color(self):
            current = self.canvas.color if self.canvas is not None else self._shared["color"]
            c = QColorDialog.getColor(current, self, "选择颜色")
            if c.isValid():
                self.set_color(c)

        def _fit_canvas(self, canvas: Canvas, scroll: QScrollArea):
            """让新标签的图片适配可视区（小图不放大超过 100%）。"""
            iw = max(1, canvas.base_pixmap.width() / canvas.dpr)
            ih = max(1, canvas.base_pixmap.height() / canvas.dpr)
            vw = scroll.viewport().width()
            vh = scroll.viewport().height()
            if vw > 80 and vh > 80:
                zx = (vw - 24) / iw
                zy = (vh - 24) / ih
            else:
                screen = QGuiApplication.primaryScreen().availableGeometry()
                zx = (screen.width() * 0.85 - 190) / iw
                zy = (screen.height() * 0.85 - 120) / ih
            target = min(1.0, max(0.1, min(zx, zy)))
            canvas.fit_mode = True                     # 这就是「适应窗口」
            # 滞回：适配本身会让画布尺寸变化 → 滚动条出现/消失 → 视口又变一点，
            # 阈值太小就会来回抖（实测差约 2.4%）。差异小于 3% 视为已经合身。
            if abs(canvas.zoom - target) < 0.03:
                return
            canvas.set_zoom(target)                    # 它会清掉 fit_mode
            canvas.fit_mode = True                     # 适应窗口：再置回

        def resizeEvent(self, e):
            """窗口尺寸变化时，处于"适应模式"的标签跟着重新适配。

            用防抖：拖动窗口会连续触发 resizeEvent，攒一下再算一次。
            """
            super().resizeEvent(e)
            if getattr(self, "_fitting", False):
                return
            if getattr(self, "_resize_timer", None) is None:
                self._resize_timer = QTimer(self)
                self._resize_timer.setSingleShot(True)
                self._resize_timer.timeout.connect(self._autofit_current)
            self._resize_timer.start(60)

        def _autofit_current(self):
            """把当前标签按窗口重新适配（仅当它处于适应模式）。"""
            if getattr(self, "_fitting", False):
                return
            canvas, scroll = self.canvas, self.scroll
            if canvas is None or scroll is None or not getattr(canvas, "fit_mode",
                                                               False):
                return
            self._fitting = True
            try:
                self._fit_canvas(canvas, scroll)
            finally:
                self._fitting = False

        def _zoom_fit(self):
            """缩放画布以适应当前窗口可视区。"""
            canvas, scroll = self.canvas, self.scroll
            if canvas is None or scroll is None:
                return
            iw = max(1, canvas.base_pixmap.width() / canvas.dpr)
            ih = max(1, canvas.base_pixmap.height() / canvas.dpr)
            zx = (scroll.viewport().width() - 24) / iw
            zy = (scroll.viewport().height() - 24) / ih
            canvas.set_zoom(min(4.0, max(0.1, min(zx, zy))))

        def _refresh_actions(self):
            canvas = self.canvas
            self.act_undo.setEnabled(bool(canvas and canvas._undo_stack))
            self.act_redo.setEnabled(bool(canvas and canvas._redo_stack))
            self.act_crop_ok.setEnabled(bool(canvas and canvas.tool == "crop"))
            # 浮动粘贴的两个动作只在真的有个浮动图时才可用
            floating = bool(canvas and canvas.has_float())
            self.act_paste_ok.setEnabled(floating)
            self.act_paste_cancel.setEnabled(floating)
            # 图层/再制/旋转要有选中的图形才有意义
            has_sel = bool(canvas and canvas._selected is not None
                           and canvas._selected in canvas.shapes)
            for act in (self.act_front, self.act_back, self.act_up, self.act_down,
                        self.act_dup, self.act_rotate, self.act_rotate0):
                act.setEnabled(has_sel)

        def copy_to_clipboard(self):
            canvas = self.canvas
            if canvas is None:
                return
            canvas._commit_text()
            QApplication.clipboard().setPixmap(canvas.render_result())
            self.statusBar().showMessage(tr("已复制到剪贴板"), 2000)

        def pin_to_screen(self):
            canvas = self.canvas
            if canvas is None:
                return
            canvas._commit_text()
            self.pin_requested.emit(canvas.render_result())

        # ---------- 水印 ----------
        def add_watermark(self):
            """打开水印设置对话框，把水印加到当前标签（可撤销、可拖动）。"""
            canvas = self.canvas
            if canvas is None:
                return
            dlg = WatermarkDialog(self, load_default(), canvas.base_pixmap.size())
            if dlg.exec() != QDialog.Accepted:
                return
            settings = dlg.settings()
            if settings.get("auto"):
                saved = save_default(settings)
                msg = ("已设为默认水印，之后每次新截图会自动添加"
                       if saved else "已设为默认水印（本次运行有效，配置写入失败）")
                self.statusBar().showMessage(msg, 4000)
            self.apply_watermark(canvas, settings)

        def apply_watermark(self, canvas: Canvas, settings: dict):
            canvas.push_undo()
            canvas.shapes.append(WatermarkShape(settings, canvas.base_pixmap.size()))
            canvas.update()
            canvas.shapes_changed.emit()

        # ---------- 边框（FSCapture 的「特效 → 边缘」）----------
        def add_border(self):
            """打开边框对话框，给当前标签加边框（图会变大，可撤销）。

            注意：这里导入的是**真实名字**，不要用 `as` 起别名 ——
            合并成单文件时本地 import 会被删掉，别名就悬空了（曾因此崩过）。
            """
            canvas = self.canvas
            if canvas is None:
                return


            dlg = BorderDialog(self, load_border_default(),
                               canvas.base_pixmap.size())
            if dlg.exec() != QDialog.Accepted:
                return
            settings = dlg.settings()
            if dlg.save_as_default():
                settings["auto"] = True
                saved = save_border_default(settings)
                self.statusBar().showMessage(
                    "已设为默认边框，之后每次新截图会自动加"
                    if saved else "已设为默认边框（本次运行有效，配置写入失败）",
                    4000)
            if not self.apply_border(canvas, settings):
                self.statusBar().showMessage(tr("边框宽度为 0，未做改动"), 3000)
            else:
                self._fit_canvas(canvas, self.tabs.currentWidget())

        def apply_border(self, canvas: Canvas, settings: dict) -> bool:
            ok = canvas.apply_border(settings)
            if ok:
                self.statusBar().showMessage(
                    tr("已加边框：") + f"{canvas.base_pixmap.width()}×"
                    f"{canvas.base_pixmap.height()} px", 4000)
            return ok

        def save_as(self):
            canvas = self.canvas
            if canvas is None:
                return
            canvas._commit_text()
            idx = self.tabs.currentIndex() + 1
            default = f"screenshot-{idx}.png"
            path, _ = QFileDialog.getSaveFileName(
                self, tr("保存截图"), default,
                tr("PNG 图片 (*.png);;JPEG 图片 (*.jpg);;BMP 图片 (*.bmp)"))
            if not path:
                return
            img = canvas.render_result().toImage()
            if path.lower().endswith((".jpg", ".jpeg")):
                # JPEG 无透明通道，补白底；先归一化 dpr 以免按逻辑尺寸缩小
                img.setDevicePixelRatio(1.0)
                bg = QPixmap(img.size())
                bg.fill(QColor("white"))
                p = QPainter(bg)
                p.drawPixmap(0, 0, QPixmap.fromImage(img))
                p.end()
                bg.save(path, "JPG", 92)
            else:
                img.setDevicePixelRatio(1.0)   # PNG 存原始像素，不带 dpr 元数据
                img.save(path)
            self.statusBar().showMessage(tr("已保存：") + path, 4000)

        def keyPressEvent(self, e):
            if e.key() == Qt.Key_Escape:
                self.close()
                return
            super().keyPressEvent(e)

        def wheelEvent(self, e):
            # 正在摆放浮动粘贴时，Ctrl+滚轮改缩放浮层（比画布缩放更常用；
            # 想缩放画布先 Enter/Esc 结束摆放）
            if (e.modifiers() & Qt.ControlModifier and self.canvas is not None
                    and self.canvas.has_float()):
                factor = 1.15 if e.angleDelta().y() > 0 else 1 / 1.15
                self.canvas.scale_float(factor)
                e.accept()
                return
            if e.modifiers() & Qt.ControlModifier and self.canvas is not None:
                delta = e.angleDelta().y()
                factor = 1.15 if delta > 0 else 1 / 1.15
                self.canvas.fit_mode = False           # 手动缩放 → 退出适应模式
                self.canvas.set_zoom(self.canvas.zoom * factor)
                e.accept()
                return
            super().wheelEvent(e)


    # ========================================================================
    # 来自 main.py
    # ========================================================================
    # -*- coding: utf-8 -*-
    """PyShot —— 仿 FSCapture 的截图 + 标注编辑工具。

    功能
    ====
    - 区域截图：全屏覆盖层拖拽框选，带放大镜与尺寸提示
    - 全屏截图：一键截取整个虚拟桌面
    - 打开图片编辑：把已有图片载入编辑器
    - 标注工具：选择 / 矩形 / 椭圆 / 直线 / 箭头 / 画笔 / 序号步骤 / 文字 / 高亮 / 马赛克 / 裁剪
    - 撤销(Ctrl+Z) / 重做(Ctrl+Y)、复制(Ctrl+C)、保存(Ctrl+S)
    - 系统托盘常驻，PrintScreen 全局热键唤起截图

    运行::

        python main.py
    """
    import ctypes
    import ctypes.wintypes
    import os
    import signal
    import sys
    import time
    from pathlib import Path

    # 依赖自举：缺 PySide6 / numpy 时自动 pip 安装（必须在导入 PySide6 之前）



    from PySide6.QtCore import (QAbstractNativeEventFilter, QObject, QPoint, QRect,
                                Qt, QTimer)
    from PySide6.QtGui import (QAction, QColor, QCursor, QFontMetrics,
                               QGuiApplication, QIcon, QPainter, QPixmap)
    from PySide6.QtWidgets import (QApplication, QCheckBox, QFileDialog, QLabel,
                                   QMenu, QMessageBox, QSystemTrayIcon)









    WM_HOTKEY = 0x0312
    MOD_ALT, MOD_CONTROL, MOD_SHIFT, MOD_WIN, MOD_NOREPEAT = 0x1, 0x2, 0x4, 0x8, 0x4000
    HOTKEY_ID_BASE = 0x5053          # "PS"

    # 滚动长截图的开关（默认关闭）。
    # 这个功能对普通网页/文档还行，但遇到 Citrix、远程桌面、Java、虚拟机里的画面
    # 经常拼不上或者拼出重复内容，所以默认不开放，用户要在托盘菜单里显式启用，
    # 启用前会先弹一段说明讲清"不稳定"。
    SCROLL_ENABLED_KEY = "scroll_capture_enabled"
    SCROLL_NOTICE_KEY = "scroll_capture_notice_off"
    # 「截图时不最小化编辑器」的设置键在 editor.py（KEEP_EDITOR_SETTING），
    # 主程序与编辑器菜单共用同一个键，避免两处各写一份字符串而对不上。

    # 进程开始的时刻：日志里用来报"启动到就绪共多久"
    _PROC_T0 = time.perf_counter()

    # 托盘图标"认双击"的时间窗口（毫秒）。
    # Windows 只在系统"双击速度"范围内才发 DoubleClick，手慢一点就只有两次
    # Trigger —— 设得比系统默认（约 500ms）宽一点，避免"第一次双击没反应"。
    TRAY_CLICK_WINDOW_MS = 700

    # 候选全局热键（按优先级尝试，选第一个没被占用的）。
    # 刻意避开被系统或常用软件注册的组合：
    #   PrintScreen / Win+Shift+S  → Windows 11 截图工具
    #   Ctrl+Alt+A / Ctrl+Shift+A / Alt+A → QQ、微信的截图
    DEFAULT_HOTKEYS = ["ctrl+alt+x", "ctrl+shift+x", "ctrl+alt+f9", "ctrl+shift+f9"]

    # 全屏截图热键（截"鼠标所在的那块显示器"），与区域截图分开注册、互不干扰
    FULLSCREEN_HOTKEYS = ["ctrl+alt+f", "ctrl+shift+f", "ctrl+alt+f10",
                          "ctrl+shift+f10"]

    _VK_NAMES = {
        "printscreen": 0x2C, "prtsc": 0x2C, "insert": 0x2D, "delete": 0x2E,
        "home": 0x24, "end": 0x23, "pageup": 0x21, "pagedown": 0x22,
        "space": 0x20, "tab": 0x09, "enter": 0x0D, "esc": 0x1B, "escape": 0x1B,
    }
    for _i in range(1, 13):                     # F1..F12
        _VK_NAMES[f"f{_i}"] = 0x6F + _i
    for _c in "abcdefghijklmnopqrstuvwxyz":     # A..Z
        _VK_NAMES[_c] = ord(_c.upper())
    for _d in "0123456789":                     # 0..9
        _VK_NAMES[_d] = ord(_d)


    def parse_hotkey(spec: str):
        """解析 "ctrl+alt+x" 这类热键描述，返回 (modifiers, vk, 显示名)；非法返回 None。"""
        if not spec:
            return None
        parts = [p.strip().lower() for p in spec.replace(" ", "").split("+") if p.strip()]
        if not parts:
            return None
        mods = 0
        labels = []
        vk = None
        for part in parts:
            if part in ("ctrl", "control"):
                mods |= MOD_CONTROL
                labels.append("Ctrl")
            elif part == "alt":
                mods |= MOD_ALT
                labels.append("Alt")
            elif part == "shift":
                mods |= MOD_SHIFT
                labels.append("Shift")
            elif part in ("win", "super", "meta"):
                mods |= MOD_WIN
                labels.append("Win")
            elif part in _VK_NAMES:
                if vk is not None:
                    return None                 # 两个主键，非法
                vk = _VK_NAMES[part]
                labels.append(part.upper() if len(part) == 1 else part.capitalize())
            else:
                return None
        if vk is None or mods == 0:
            return None                          # 必须有主键，且至少一个修饰键
        return mods | MOD_NOREPEAT, vk, "+".join(labels)


    def register_global_hotkeys(candidates, id_offset: int = 0) -> dict:
        """依次尝试注册，返回 {热键 id: 显示名}（只注册第一个成功的）。

        candidates 为空表示不注册。注册失败（被其他程序占用）会自动尝试下一个。
        id_offset 把多组热键的 id 错开（同进程内 id 不能重复）。
        """
        user32 = ctypes.windll.user32
        for i, spec in enumerate(candidates):
            parsed = parse_hotkey(spec)
            if parsed is None:
                continue
            mods, vk, name = parsed
            hid = HOTKEY_ID_BASE + id_offset + i
            if user32.RegisterHotKey(None, hid, mods, vk):
                return {hid: name}
        return {}


    def make_tray_icon() -> QIcon:
        """自绘一个醒目的相机图标，避免系统标准图标在任务栏里认不出来。"""
        pix = QPixmap(64, 64)
        pix.fill(Qt.transparent)
        p = QPainter(pix)
        p.setRenderHint(QPainter.Antialiasing)
        p.setPen(Qt.NoPen)
        p.setBrush(QColor("#1e88e5"))
        p.drawRoundedRect(4, 4, 56, 56, 14, 14)
        p.setBrush(QColor("#ffffff"))
        p.drawRoundedRect(14, 22, 36, 26, 5, 5)          # 机身
        p.drawRect(24, 15, 16, 9)                         # 顶部凸起
        p.setBrush(QColor("#1e88e5"))
        p.drawEllipse(24, 26, 16, 16)                     # 镜头
        p.setBrush(QColor("#ffffff"))
        p.drawEllipse(29, 31, 6, 6)
        p.end()
        return QIcon(pix)


    class HotkeyFilter(QAbstractNativeEventFilter):
        """监听已注册的全局热键（Windows WM_HOTKEY）。

        回调带上热键 id，便于区分"区域截图"和"全屏截图"。
        """

        def __init__(self, ids, callback):
            super().__init__()
            self.ids = set(ids)
            self.callback = callback

        def nativeEventFilter(self, eventType, message):
            if eventType == b"windows_generic_MSG":
                msg = ctypes.wintypes.MSG.from_address(int(message))
                if msg.message == WM_HOTKEY and msg.wParam in self.ids:
                    self.callback(msg.wParam)
            return False, 0


    class PyShotApp(QObject):
        def __init__(self, app: QApplication):
            super().__init__()
            self.app = app
            self.tray_available = QSystemTrayIcon.isSystemTrayAvailable()
            self.snipper: SnipperOverlay | None = None
            self._overlay: SnipperOverlay | None = None   # 主屏覆盖层（兼容）
            self._overlays: list = []                     # 每块屏一个
            self._overlay_screens: list = []
            self._want_scroll = False
            self.scroller: ScrollCapture | None = None
            self.editors: list[EditorWindow] = []
            self.pins: list[PinWindow] = []
            self._minimized_by_capture: list[EditorWindow] = []
            self._hotkey_ok = False
            self.hotkey_text = ""
            self._hotkeys: dict = {}
            self._scroll_mode: str | None = None   # None / "wheel" / "drag" / "key" / "manual"
            self._pending_scroll_region = None

            # 托盘单击/双击去抖：见 _on_tray_activated()。
            # 窗口设得比系统默认双击间隔（约 500ms）宽一点，手慢的双击也能认出来。
            self._tray_click_timer = QTimer(self)
            self._tray_click_timer.setSingleShot(True)
            self._tray_click_timer.setInterval(TRAY_CLICK_WINDOW_MS)
            self._tray_click_timer.timeout.connect(self._tray_single_click_hint)
            self._tray_click_fired_at = 0.0        # 上次真的触发截图的时间（防余波）
            self._tray_hint_at = 0.0               # 上次弹"单击不截图"提示的时间（限流）

            self._init_hotkey()   # 先注册热键，托盘文案才知道该显示哪个按键
            self._init_tray()
            # 启动后台预热（延迟一点，不影响启动速度）
            QTimer.singleShot(150, self._warmup)

        # ---------- 全局热键 ----------
        def _init_hotkey(self):
            """注册两组全局热键：区域截图 + 全屏截图（各自挑第一个没被占用的组合）。"""
            env_spec = os.environ.get("PYSHOT_HOTKEY")
            region_cands = [env_spec] if env_spec else DEFAULT_HOTKEYS
            self._region_hotkeys = register_global_hotkeys(region_cands, 0)
            self._full_hotkeys = register_global_hotkeys(FULLSCREEN_HOTKEYS, 100)
            self._hotkeys = {**self._region_hotkeys, **self._full_hotkeys}
            self._hotkey_ok = bool(self._hotkeys)
            self.hotkey_text = next(iter(self._region_hotkeys.values()), "")
            self.full_hotkey_text = next(iter(self._full_hotkeys.values()), "")
            # id → 动作，供 nativeEventFilter 分发
            self._hotkey_actions = {}
            for hid in self._region_hotkeys:
                self._hotkey_actions[hid] = "region"
            for hid in self._full_hotkeys:
                self._hotkey_actions[hid] = "fullscreen"
            if self._hotkey_ok:
                self._filter = HotkeyFilter(self._hotkeys.keys(), self._on_hotkey)
                self.app.installNativeEventFilter(self._filter)
                parts = []
                if self.hotkey_text:
                    parts.append(f"区域 {self.hotkey_text}")
                if self.full_hotkey_text:
                    parts.append(f"全屏 {self.full_hotkey_text}")
                print("[PyShot] 全局热键已注册：" + "、".join(parts))
            else:
                print("[PyShot] 热键注册失败，已尝试：" + "、".join(region_cands))

        # ---------- 托盘 ----------
        def _init_tray(self):
            if not self.tray_available:
                # 无托盘环境：关掉最后一个窗口就退出，避免程序"隐身"
                self.app.setQuitOnLastWindowClosed(True)
                return
            self.tray = QSystemTrayIcon(make_tray_icon(), self.app)
            self._build_tray_menu()
            # 这两行**必须留在初始化里**：_build_tray_menu 只负责重建菜单，
            # 如果把 connect/show 也放进它，重建（切换语言）时会重复连接；
            # 但要是从初始化里删掉，托盘图标就根本不显示（曾因此出过 bug）。
            self.tray.activated.connect(self._on_tray_activated)
            self.tray.show()

        def _build_tray_menu(self):
            """构建/重建托盘菜单（切换语言时也会调它）。"""
            menu = QMenu()
            self.menu = menu

            # ---------- 截图 ----------
            # 高频动作置顶；快捷键用 "\t" 放到右侧列（只是显示，不注册 Qt 快捷键，
            # 避免与全局热键同时触发一次截图）
            act_region = QAction(make_menu_icon("crop"), tr("区域截图"), self.app)
            act_region.setToolTip(tr("框选一块区域截图"))
            act_region.triggered.connect(lambda: self._deferred(self.capture_region))
            menu.addAction(act_region)
            self.act_region = act_region

            act_full = QAction(make_menu_icon("camera"), tr("全屏截图"), self.app)
            act_full.setToolTip(tr("截取鼠标所在的那块显示器"))
            act_full.triggered.connect(lambda: self._deferred(self.capture_fullscreen))
            menu.addAction(act_full)
            self.act_full = act_full

            # 选择显示器（含"所有显示器拼一张"）：弹出时按当前屏幕列表重建
            self.menu_screens = QMenu(tr("选择显示器截图"), menu)
            self.menu_screens.setIcon(make_menu_icon("monitor"))
            self.menu_screens.aboutToShow.connect(self._rebuild_screen_menu)
            menu.addMenu(self.menu_screens)

            menu.addSeparator()

            # ---------- 滚动长截图（实验性，默认关闭）----------
            # 功能不稳定（重复/错位/拼不上），所以默认只显示一个开关，
            # 四种滚动方式在启用之前一律置灰，避免用户误点后拿到一张坏图。
            scroll_on = self.scroll_enabled()
            menu_scroll = QMenu(tr("滚动长截图（实验性）"), menu)
            menu_scroll.setIcon(make_menu_icon("scroll"))
            # QMenu 默认不显示 action 的 tooltip，说明就等于白写
            menu_scroll.setToolTipsVisible(True)

            # 说明就写在开关这一条上（灰条，点不动），不用去别处找
            act_scroll_note = QAction(
                tr("说明：实验性功能，长图可能重复、错位或拼不上"), menu_scroll)
            act_scroll_note.setEnabled(False)
            menu_scroll.addAction(act_scroll_note)

            act_scroll_on = QAction(tr("启用滚动长截图（不稳定）"), menu_scroll)
            act_scroll_on.setCheckable(True)
            act_scroll_on.setChecked(scroll_on)
            act_scroll_on.setToolTip(tr("默认关闭：这个功能还在实验阶段，"
                                        "长图可能重复、错位或拼不上"))
            act_scroll_on.toggled.connect(self._toggle_scroll_enabled)
            menu_scroll.addAction(act_scroll_on)
            self.act_scroll_enable = act_scroll_on
            menu_scroll.addSeparator()

            self._scroll_actions = []
            for label, tip, fn in [
                    ("自动滚轮",
                     "框选可滚动区域，程序自己发滚轮逐屏拼接（普通网页/文档）",
                     lambda: self.capture_scrolling()),
                    ("拖拽滚动条",
                     "框选区域后点一下滚动条滑块，程序按住滑块匀速拖拽。\n"
                     "远程桌面 / Citrix 里最稳：步长会实测标定",
                     lambda: self.capture_scrolling(mode="drag")),
                    ("按键翻页",
                     "框选区域后程序发送 PageDown 翻页（适合没有滚动条的应用）",
                     lambda: self.capture_scrolling(mode="key")),
                    ("手动滚动",
                     "自己用滚轮滚动，程序只负责逐帧拼接",
                     lambda: self.capture_scrolling(manual=True))]:
                act = QAction(tr(label), menu_scroll)
                act.setToolTip(tr(tip))
                act.setEnabled(scroll_on)      # 没启用就点不动
                act.triggered.connect(
                    lambda checked=False, f=fn: self._deferred(f))
                menu_scroll.addAction(act)
                self._scroll_actions.append(act)
            menu.addMenu(menu_scroll)

            menu.addSeparator()

            # ---------- 小工具 ----------
            act_color = QAction(make_menu_icon("pick"), tr("屏幕取色"), self.app)
            act_color.setToolTip(tr("单击屏幕任意位置，把色值复制到剪贴板"))
            act_color.triggered.connect(lambda: self._deferred(self.pick_color))
            menu.addAction(act_color)

            act_pin_clip = QAction(make_menu_icon("pin"), tr("贴出剪贴板图片"), self.app)
            act_pin_clip.setToolTip(tr("把剪贴板里的图片钉在屏幕最上层"))
            act_pin_clip.triggered.connect(self.pin_clipboard)
            menu.addAction(act_pin_clip)

            menu.addSeparator()

            # ---------- 窗口 ----------
            act_open = QAction(make_menu_icon("image"), tr("打开图片编辑…"), self.app)
            act_open.setToolTip(tr("打开一张已有图片进行标注"))
            act_open.triggered.connect(self.open_image)
            menu.addAction(act_open)

            act_editor = QAction(make_menu_icon("window"), tr("显示编辑器"), self.app)
            act_editor.setToolTip(
                tr("直接打开编辑器窗口（空白也能用，从它的「文件」菜单打开图片）"))
            act_editor.triggered.connect(self.show_editor)
            menu.addAction(act_editor)

            menu.addSeparator()

            # ---------- 语言 ----------
            self.menu_lang = QMenu(tr("语言"), menu)
            self.menu_lang.setIcon(make_menu_icon("globe"))
            self.menu_lang.aboutToShow.connect(self._rebuild_language_menu)
            menu.addMenu(self.menu_lang)

            menu.addSeparator()
            act_cancel = QAction(make_menu_icon("cancel"), tr("取消截图"), self.app)
            act_cancel.setToolTip(tr("收起正在显示的截图遮罩（Esc / 再按一次热键也可以）"))
            act_cancel.triggered.connect(lambda: self._deferred(self._cancel_capture))
            menu.addAction(act_cancel)
            menu.addSeparator()
            act_quit = QAction(make_menu_icon("exit"), tr("退出 PyShot"), self.app)
            act_quit.triggered.connect(self.app.quit)
            menu.addAction(act_quit)

            self.tray.setContextMenu(menu)
            # 快捷键写进右侧列（\t 之后的部分由 Qt 右对齐显示）
            if self.hotkey_text:
                act_region.setText(tr("区域截图") + "\t" + self.hotkey_text)
            if self.full_hotkey_text:
                act_full.setText(tr("全屏截图") + "\t" + self.full_hotkey_text)
            hints = []
            if self.hotkey_text:
                hints.append(tr("{} 区域截图", self.hotkey_text))
            if self.full_hotkey_text:
                hints.append(tr("{} 全屏截图", self.full_hotkey_text))
            if hints:
                self.tray.setToolTip(
                    tr("PyShot 截图工具\n{}\n双击图标截图", " · ".join(hints)))
            else:
                self.tray.setToolTip(
                    tr("PyShot 截图工具\n双击图标截图 · 右键菜单"))
            # 注意：启动提示不在这里弹 —— 由 notify_ready() 统一负责，
            # 否则构造托盘和 main() 会各弹一次，用户看到两个气泡。

        def _on_hotkey(self, hotkey_id=None):
            """来自原生消息回调（WM_HOTKEY）——按热键 id 分发，延后一拍再动作。

            逃生口：如果遮罩正开着（用户可能因为窗口没拿到焦点而按不动 Esc），
            再按一次区域截图热键就**取消**这次截图。全局热键不依赖窗口焦点，
            所以这是最可靠的退出方式。
            """
            action = self._hotkey_actions.get(hotkey_id, "region")
            if action != "fullscreen":
                live = [ov for ov in getattr(self, "_overlays", [])
                        if getattr(ov, "_active", False)]
                if getattr(self, "snipper", None) is not None or live:
                    self._cap_log("热键按下：取消进行中的截图")
                    self._deferred(self._cancel_capture, delay=10)
                    return
            if action == "fullscreen":
                self._deferred(self.capture_fullscreen, delay=30)
            else:
                self._deferred(self.capture_region, delay=30)

        def shutdown(self):
            # 退出前把编辑器里的截图存进会话缓存（用户不需要手动保存）
            try:
                self.save_session_now()
            except Exception:                          # noqa: BLE001
                pass
            if getattr(self, "_hotkeys", None):
                user32 = ctypes.windll.user32
                for hid in self._hotkeys:
                    user32.UnregisterHotKey(None, hid)

        # ---------- 截图流程 ----------
        def capture_region(self):
            self._cap_log("触发区域截图")
            self._start_snipper("region")

        def _start_snipper(self, mode: str, scroll_mode: str | None = None,
                           point_region: QRect | None = None):
            if self.snipper is not None:
                # 已有覆盖层在运行。但如果它其实已经不活跃/不可见（上次没收干净），
                # 就直接当作残留清掉继续走 —— 否则这一句会让之后每次截图都"没反应"
                live = [ov for ov in getattr(self, "_overlays", [])
                        if getattr(ov, "_active", False)]
                if live:
                    self._cap_log("已有覆盖层在运行，忽略本次触发")
                    return
                self._cap_log("清理残留覆盖层后继续")
                self._on_snip_done()
            self._prepare_capture()
            self._scroll_mode = scroll_mode      # None / "wheel" / "drag" / "key" / "manual"
            overlays = self._ensure_overlays()
            self.snipper = overlays[0]           # 代表整个会话（哪个屏先按就用哪个屏）
            for ov in overlays:
                ov.start(mode)
                try:
                    self._cap_log("遮罩已显示；", ov.bg_report())
                except Exception:                      # noqa: BLE001
                    pass
                if mode == "point" and point_region is not None:
                    # 选区挖空后可穿透点击（能真的点到应用里的滚动条）
                    ov.set_point_hole(point_region)

        # ---------- 截图触发（统一延后到事件循环） ----------
        def _deferred(self, fn, delay: int = 40):
            """把截图动作延后到 Qt 事件循环里执行。

            托盘双击/托盘菜单都发生在 shell 的原生消息回调中，此时直接创建并显示
            全屏覆盖层会被前台激活锁和鼠标捕获影响，表现为"窗口在但没画出来"。
            延后一拍即可稳定显示；延迟保持很小，避免拖慢首帧。
            """
            # 记下"用户动作 → 真正开始"的延迟：双击慢就是慢在这里或后面
            try:
                import time

                name = getattr(fn, "__name__", str(fn))
                t0 = time.perf_counter()

                def _run():
                    log("延迟执行", f"{name} 排队 {delay}ms，实际等了 "
                                   f"{(time.perf_counter() - t0) * 1000:.0f}ms")
                    fn()
                QTimer.singleShot(delay, _run)
            except Exception:                          # noqa: BLE001
                QTimer.singleShot(delay, fn)

        # ---------- 语言 ----------
        def _rebuild_language_menu(self):
            """重建语言子菜单（勾选当前语言；含"跟随系统"）。"""
            self.menu_lang.clear()
            saved = saved_language()
            for code, name in LANGUAGES:
                act = QAction(name, self.menu_lang)
                act.setCheckable(True)
                act.setChecked(saved == code)
                act.triggered.connect(
                    lambda checked=False, c=code: self._switch_language(c))
                self.menu_lang.addAction(act)
            self.menu_lang.addSeparator()
            act_auto = QAction(
                tr("跟随系统") + f"（{language_name(system_language())}）",
                self.menu_lang)
            act_auto.setCheckable(True)
            act_auto.setChecked(saved == AUTO)
            act_auto.setToolTip(tr("按系统语言自动选择"))
            act_auto.triggered.connect(lambda: self._switch_language(AUTO))
            self.menu_lang.addAction(act_auto)

        def _switch_language(self, code: str):
            """切换界面语言：重建托盘菜单，并让已打开的编辑器刷新文案。"""
            lang = set_language(code)
            # 全局字体也要跟着换（中文界面用微软雅黑，其它用 Segoe UI）：
            # 字体是 app.setFont 设的，不会自己随语言变。
            try:
                apply_font(self.app)
            except Exception:                          # noqa: BLE001
                pass
            self._retranslate()
            self._notify(tr("界面语言已切换"), language_name(lang))

        def _retranslate(self):
            """语言变化后刷新界面文案。

            托盘菜单直接重建；已打开的编辑器窗口调用各自的 retranslate()；
            对话框每次打开都会新建，所以自动生效。
            """
            try:
                self._build_tray_menu()
            except Exception:                          # noqa: BLE001
                pass
            for ed in list(getattr(self, "editors", [])):
                try:
                    ed.retranslate()
                except Exception:                      # noqa: BLE001
                    pass

        def _rebuild_screen_menu(self):
            """按当前显示器列表重建子菜单（插拔显示器后自动更新）。

            除了每块屏一项，末尾再放"所有显示器拼成一张"——都属于"截哪块屏"这件事。
            """
            self.menu_screens.clear()
            primary = QGuiApplication.primaryScreen()
            for i, scr in enumerate(QGuiApplication.screens()):
                geo = scr.geometry()
                dpr = float(scr.devicePixelRatio() or 1.0)
                tag = tr("主屏") if scr is primary else tr("显示器 {}").format(i + 1)
                scale = f" @{int(round(dpr * 100))}%" if abs(dpr - 1.0) > 1e-6 else ""
                act = QAction(
                    f"{tag}：{geo.width()}×{geo.height()}{scale}  ({scr.name()})",
                    self.menu_screens)
                act.setIcon(make_menu_icon("monitor"))
                act.triggered.connect(
                    lambda checked=False, s=scr: self._deferred(
                        lambda: self.capture_fullscreen(s)))
                self.menu_screens.addAction(act)
            if not self.menu_screens.actions():
                act = QAction(tr("（未检测到显示器）"), self.menu_screens)
                act.setEnabled(False)
                self.menu_screens.addAction(act)
            self.menu_screens.addSeparator()
            act_all = QAction(tr("所有显示器拼成一张"), self.menu_screens)
            act_all.setIcon(make_menu_icon("monitor"))
            act_all.setToolTip(tr("把每块显示器按逻辑位置拼成一张长图"))
            act_all.triggered.connect(
                lambda: self._deferred(self.capture_all_screens))
            self.menu_screens.addAction(act_all)

        def _on_tray_activated(self, reason):
            """托盘图标被左键点了：**单击/双击都按"双击"来判**，带一个去抖窗口。

            为什么不能只听 DoubleClick：Windows 的托盘区是否把两次点击合成
            DoubleClick，取决于系统"双击速度"设置。手慢一点（或系统设得快）时
            只会发两次 Trigger、**永远不发 DoubleClick** —— 用户表现为
            "双击托盘图标第一次没反应"（实测日志里就是 Trigger、Trigger）。
            所以这里自己认双击：窗口内第二次点击就算双击，单击什么都不做。
            """
            try:

                log("托盘事件", f"reason={reason}")
            except Exception:                          # noqa: BLE001
                pass
            if reason not in (QSystemTrayIcon.Trigger, QSystemTrayIcon.DoubleClick):
                return
            now = time.perf_counter()
            if self._tray_click_fired_at and now - self._tray_click_fired_at < 0.35:
                return                    # 刚触发过：忽略快速双击多出来的余波事件
            if self._tray_click_timer.isActive():
                self._tray_click_timer.stop()
                self._tray_click_fired_at = now
                try:

                    log("托盘事件", "判定为双击 → 区域截图")
                except Exception:                      # noqa: BLE001
                    pass
                self._deferred(self.capture_region)
            else:
                self._tray_click_timer.start()         # 单击：窗口到期后什么都不做

        def _tray_single_click_hint(self):
            """单击（没能构成双击）时给个提示。

            有些情况下用户"双击了却什么都没发生"：比如托盘图标刚出现时，
            第一次点击会被任务栏/通知区域吃掉，程序只收到一个 Trigger。
            这里给一句明确的反馈，总比"点了没反应"好。限流 15 秒一次。
            """
            now = time.perf_counter()
            if now - self._tray_hint_at < 15.0:
                return
            self._tray_hint_at = now
            if self.hotkey_text:
                self._notify(tr("PyShot 截图工具"),
                             tr("单击不截图：双击托盘图标开始截图（也可以按 {}）",
                                self.hotkey_text))
            else:
                self._notify(tr("PyShot 截图工具"), tr("单击不截图：双击托盘图标开始截图"))

        # ---------- 覆盖层复用与预热 ----------
        def _cap_log(self, *parts):
            """截图流程诊断日志（设 PYSHOT_DEBUG=1 打开，细节见 diag.py）。"""
            try:

                log("截图", *parts)
            except Exception:                          # noqa: BLE001
                pass

        def _ensure_overlays(self) -> list:
            """确保每一块显示器都有一个覆盖层。

            多屏必须"一屏一窗"：单个窗口横跨多显示器时，Windows 的每显示器 DPI
            会让非主屏部分被裁剪或缩放，导致多屏基本不可用。
            """
            screens = QGuiApplication.screens()
            names = [s.name() for s in screens]
            self._cap_log("屏幕列表", names)
            if self._overlays and self._overlay_screens == names:
                return self._overlays
            for ov in self._overlays:             # 屏幕组合变了：重建
                ov.deleteLater()
            self._overlays = []
            for scr in screens:
                ov = SnipperOverlay("region", screen=scr)
                ov.captured.connect(self._on_captured)
                ov.region_selected.connect(self._on_region_selected)
                ov.point_selected.connect(self._on_scroll_anchor)
                ov.color_picked.connect(self._on_color_picked)
                ov.cancelled.connect(self._on_snip_cancelled)
                g = scr.geometry()
                self._cap_log("新建遮罩", f"{scr.name()} geo=({g.x()},{g.y()},"
                                       f"{g.width()}x{g.height()}) "
                                       f"dpr={scr.devicePixelRatio()}")
                self._overlays.append(ov)
            self._overlay_screens = names
            self._overlay = self._overlays[0] if self._overlays else None
            return self._overlays

        def _warmup(self):
            """启动预热：把冷启动的一次性开销（首次排版 + 首次建编辑器 + 首次抓屏）提前付掉。

            注意：这段跑在**主线程**，日志里会显示为一段空白 —— 所以它被安排在
            托盘/热键就绪之后（见 main() 里的 schedule_boot），
            用户不会因为它在启动时按不动热键。
            """
            import time
            t0 = time.perf_counter()
            self._cap_log("预热·开始")
            self._warm_ui()
            try:
                t1 = time.perf_counter()
                grab_virtual_desktop()
                self._cap_log("预热·首次抓屏", f"耗时 {(time.perf_counter()-t1)*1000:.0f} ms")
                t2 = time.perf_counter()
                overlays = self._ensure_overlays()
                self._cap_log("预热·建遮罩窗口",
                              f"{len(overlays)} 块屏，耗时 {(time.perf_counter()-t2)*1000:.0f} ms")
                for ov in overlays:
                    t3 = time.perf_counter()
                    ov.warmup()
                    self._cap_log("预热·单屏上屏",
                                  f"{ov.screen.name()} 耗时 {(time.perf_counter()-t3)*1000:.0f} ms")
            except Exception:                          # noqa: BLE001
                pass                               # 预热失败不影响正常使用
            self._cap_log("预热·结束", f"总耗时 {(time.perf_counter()-t0)*1000:.0f} ms")

        def _warm_ui(self):
            """把进程内"第一次用 Qt 界面"的几笔一次性开销在这里付掉。

            本机实测（Qt 6.11 / Windows，800+ 字体族），这些都只跟"第一次"有关、
            跟控件数量无关，但加起来好几秒：
              · 第一次量一段文字（字体库 + 中文回退族扫描）   1.7~7.8 s
                原来字体是 QSS 的 `* { font-family: "Segoe UI", ... }` 设的，
                中文只能走回退扫描，实测 7.8 s；改成 app.setFont(中文字体) 后
                降到 1.9 s 左右（见 style.apply_font）。
              · 第一次建编辑器标签页（标签 + 关闭按钮 + 画布）3.3 s
                直接建一个**隐藏的编辑器窗口**付掉；此后建编辑器只要几十毫秒。
            不先付掉的话，这笔钱会落在"启动时恢复上次截图"或"第一次截图弹出编辑器"
            上 —— 用户看到的就是启动后二十多秒没反应、截图后界面卡住。
            """
            import time
            t_f = time.perf_counter()
            try:
                # 探针文字取**当前界面语言**的文案：英文界面 + Segoe UI 不需要中文
                # 回退，写死中文反而会强制走最贵的回退扫描。
                probe_text = tr("工具：选择")
                QFontMetrics(self.app.font()).horizontalAdvance(probe_text)
                probe = QLabel(probe_text)
                probe.adjustSize()
                probe.deleteLater()
            except Exception:                          # noqa: BLE001
                pass
            self._cap_log("预热·字体排版",
                          f"耗时 {(time.perf_counter()-t_f)*1000:.0f} ms（一次性）")
            t_e = time.perf_counter()
            try:
                dummy = EditorWindow()
                pix = QPixmap(64, 64)
                pix.fill()
                dummy.add_canvas(pix, "warmup")        # 建标签 + 关闭按钮 + 画布
                dummy.close()                          # 没接任何信号，直接丢掉
                dummy.deleteLater()
            except Exception:                          # noqa: BLE001
                pass
            self._cap_log("预热·编辑器",
                          f"耗时 {(time.perf_counter()-t_e)*1000:.0f} ms（一次性）")

        def schedule_boot(self, delay_ms: int = 350):
            """安排"恢复上次截图 + 弹就绪提示"在事件循环里跑（不在 exec() 之前）。

            delay_ms 排在预热（150ms）之后：让预热先把字体/编辑器那两笔一次性开销
            付掉，这里再建编辑器窗口就只要几十毫秒。
            """
            QTimer.singleShot(delay_ms, self.boot_restore)

        def boot_restore(self):
            """事件循环跑起来之后再做：恢复上次截图 + 弹"已就绪"提示。

            为什么不放在 app.exec() 之前：恢复会话要建编辑器窗口，会触发上面那些
            一次性开销（本机 5 秒级）。放在 exec() 之前会把托盘和全局热键**一起**
            卡住 —— 用户按热键完全没反应（实测启动后 21 秒空白）。
            现在托盘/热键先可用，这一步随后在事件循环里进行，日志能看到各段耗时。
            """
            import time
            t0 = time.perf_counter()
            restored = 0
            try:
                restored = self.restore_session()
            except Exception:                          # noqa: BLE001
                restored = 0
            self._cap_log("启动·恢复会话",
                          f"{restored} 张，耗时 {(time.perf_counter()-t0)*1000:.0f} ms")
            try:
                self.notify_ready(restored)
            except Exception:                          # noqa: BLE001
                pass
            self._cap_log("启动·就绪",
                          f"从进程开始到就绪 {(time.perf_counter()-_PROC_T0)*1000:.0f} ms")

        def _on_region_selected(self, region):
            self._cap_log("滚动·选区确定", f"region={region.x()},{region.y()} "
                                        f"{region.width()}x{region.height()} "
                                        f"mode={self._scroll_mode}")
            mode = self._scroll_mode
            self._scroll_mode = None
            if not mode:
                return
            if mode == "drag":
                # 选区外遮罩、选区内可点击：让用户直接点到应用里的滚动条滑块
                self._on_snip_done()      # 先释放覆盖层引用，才能再用它做选点
                self._pending_scroll_region = QRect(region)
                self._start_snipper("point", point_region=QRect(region))
                return
            if mode == "manual":
                self._start_scrolling(region, manual=True)
            else:
                self._start_scrolling(region, mode=mode)

        # ---------- 截图会话：截图时最小化编辑器，结束后恢复 ----------
        def keep_editor_on_capture(self) -> bool:
            """截图时是否**不要**最小化编辑器（想截编辑器本身时要打开）。

            设置键与编辑器「选项 → 截图时不最小化编辑器」共用（见 editor.py）。
            """
            try:
                return bool(get_setting(KEEP_EDITOR_SETTING, False))
            except Exception:                          # noqa: BLE001
                return False

        def _prepare_capture(self):
            """开始截图前把编辑器最小化，免得自己被拍进图里。

            例外：用户勾了「截图时不最小化编辑器」就原地保留 —— 想截编辑器
            本身（写文档/做教程）时必须这样，否则一按截图它就自己缩下去了。
            """
            if self.keep_editor_on_capture():
                self._minimized_by_capture = []
                self._cap_log("截图·保留编辑器", "已开启「截图时不最小化编辑器」")
                return
            self._minimized_by_capture = [
                ed for ed in list(self.editors)
                if ed.isVisible() and not ed.isMinimized()
            ]
            for ed in self._minimized_by_capture:
                ed.showMinimized()

        def _finish_capture_session(self):
            """截图流程结束后把之前最小化的编辑器还原。"""
            for ed in getattr(self, "_minimized_by_capture", []):
                if ed in self.editors:
                    ed.showNormal()
                    ed.raise_()
                    ed.activateWindow()
            self._minimized_by_capture = []

        def _on_snip_cancelled(self, *args):
            self._on_snip_done()
            self._pending_scroll_region = None   # 取消时清掉滚动截图的待选状态
            self._finish_capture_session()

        def _cancel_capture(self):
            """取消当前截图（热键逃生口 / 托盘菜单都用它）。"""
            try:
                self._on_snip_done()
                self._finish_capture_session()
            except Exception:                          # noqa: BLE001
                pass

        def _on_snip_done(self, *args):
            # 所有屏幕的覆盖层都要收起（多屏时可能有好几个）
            self.snipper = None                    # 先清，避免重入时提前 return
            seen = []
            for ov in list(getattr(self, "_overlays", [])):
                seen.append(ov)
            # 兜底：把"Qt 知道的所有覆盖层实例"都收掉。屏幕组合变化时
            # _ensure_overlays 会重建列表，旧实例如果还可见就成了孤儿，
            # 永远盖在屏幕上（用户看到的就是"遮罩挡住了"）。
            try:
                for ov in self.app.findChildren(SnipperOverlay):
                    if ov not in seen:
                        seen.append(ov)
            except Exception:                          # noqa: BLE001
                pass
            for ov in seen:
                try:
                    if ov.isVisible() or getattr(ov, "_active", False):
                        ov.finish()
                    ov.hide()                      # 双保险：无论如何都别留在屏上
                except Exception:                      # noqa: BLE001
                    continue
            # 最终兜底：走全局注册表把所有还活着的遮罩都收掉。
            # findChildren 找不到它们（顶层无父窗口），不能靠 Qt 树兜底。
            try:

                n = finish_all_overlays()
            except Exception:                          # noqa: BLE001
                n = 0
            self._cap_log("收起覆盖层", len(seen), "个；全局兜底", n, "个")
            if not self.tray_available and not self.editors:
                self.app.quit()  # 无托盘且无窗口时退出，避免程序"隐身"残留

        def _on_captured(self, pixmap: QPixmap):
            self._cap_log("截图完成", pixmap.width(), "x", pixmap.height())
            self._on_snip_done()
            if self._scroll_mode:      # 滚动截图的选区，不是要编辑的截图
                self._scroll_mode = None
                return

            # 等覆盖层彻底关闭再开编辑器，否则置顶的覆盖层可能压在编辑器上面；
            # 并且把异常显式暴露出来，避免"截图后什么都没发生"这种静默失败。
            def _open():
                try:
                    self.open_editor(pixmap)
                except Exception as ex:  # noqa: BLE001
                    import traceback
                    traceback.print_exc()
                    self._notify(tr("打开编辑器失败"), f"{type(ex).__name__}: {ex}")
                finally:
                    self._finish_capture_session()

            QTimer.singleShot(120, _open)

        def capture_fullscreen(self, screen=None):
            """全屏截图。

            screen 为 None 时截"鼠标所在的那块显示器"（多屏下最符合直觉）；
            也可以显式指定某块屏（托盘菜单"截取指定显示器"）。
            另外保留"所有显示器拼成一张"的旧行为，见 capture_all_screens。
            """
            if screen is None:
                screen = QGuiApplication.screenAt(QCursor.pos()) \
                    or QGuiApplication.primaryScreen()
            self._prepare_capture()

            def _grab():
                try:
                    pix = grab_screen(screen)
                except Exception as ex:  # noqa: BLE001
                    self._notify(tr("全屏截图失败"), f"{type(ex).__name__}: {ex}")
                    self._finish_capture_session()
                    return
                label = f"{screen.name()} {pix.width()}×{pix.height()}"
                self.open_editor(pix)
                self._notify(tr("全屏截图完成"), label)
                self._finish_capture_session()

            # 等最小化动画结束再抓，否则窗口残影会进图
            QTimer.singleShot(280, _grab)

        def capture_all_screens(self):
            """把所有显示器拼成一张长图（旧的全屏行为）。"""
            self._prepare_capture()

            def _grab():
                pix, _ = grab_virtual_desktop()
                self.open_editor(pix)
                self._finish_capture_session()

            QTimer.singleShot(280, _grab)

        # ---------- 滚动长截图 ----------
        def scroll_enabled(self) -> bool:
            """滚动长截图是否已启用（默认关闭，见 SCROLL_ENABLED_KEY）。"""
            try:
                return bool(get_setting(SCROLL_ENABLED_KEY, False))
            except Exception:                    # noqa: BLE001
                return False

        def _apply_scroll_enabled(self, enabled: bool):
            """切换四种滚动方式的可用状态（不重建菜单，避免关掉正在弹的菜单）。"""
            for act in getattr(self, "_scroll_actions", ()):
                act.setEnabled(enabled)

        def _toggle_scroll_enabled(self, checked: bool):
            """托盘里勾选/取消「启用滚动长截图」。

            打开之前先把"不稳定"讲清楚；用户在说明里点了取消就把勾去掉。
            """
            if checked and not self._scroll_notice():
                act = getattr(self, "act_scroll_enable", None)
                if act is not None:
                    act.blockSignals(True)       # 避免 setChecked 再触发一次本函数
                    act.setChecked(False)
                    act.blockSignals(False)
                return
            try:
                set_setting(SCROLL_ENABLED_KEY, bool(checked))
            except Exception:                    # noqa: BLE001
                pass                             # 写不进去也要让本次运行生效
            self._apply_scroll_enabled(bool(checked))
            self._cap_log(f"滚动长截图开关 = {bool(checked)}")

        def _scroll_notice(self) -> bool:
            """启用前的说明。返回 True = 用户确认要开。"""
            if get_setting(SCROLL_NOTICE_KEY, False):
                return True                      # 用户勾过"不再提示"
            box = QMessageBox()
            box.setWindowTitle(tr("滚动长截图（实验性功能）"))
            box.setIcon(QMessageBox.Warning)
            box.setText(tr("滚动长截图还是实验性功能，默认关闭。"))
            box.setInformativeText(tr(
                "它靠「逐帧拼接」实现：程序自己滚动画面，再把每一帧接起来。"
                "遇到下面这些情况很容易出问题：\n"
                "· 只对普通网页/文档比较可靠；Citrix、远程桌面、Java、"
                "虚拟机里的画面经常拼不上\n"
                "· 可能拼出重复内容或错位，也可能滚到一半就停住\n"
                "· 滚动期间不要动鼠标键盘，窗口也不要移动或缩放\n\n"
                "只要一张普通截图的话，用「区域截图 / 全屏截图」就够了。"
                "确实需要长图再启用。"))
            no_more = QCheckBox(tr("不再提示"))
            box.setCheckBox(no_more)
            yes = box.addButton(tr("仍然启用"), QMessageBox.AcceptRole)
            box.addButton(tr("取消"), QMessageBox.RejectRole)
            box.exec()
            if box.clickedButton() is not yes:
                return False
            if no_more.isChecked():
                try:
                    set_setting(SCROLL_NOTICE_KEY, True)
                except Exception:                # noqa: BLE001
                    pass
            return True

        def capture_scrolling(self, manual: bool = False, mode: str = "wheel"):
            """mode: wheel 滚轮 | drag 拖拽滚动条 | key 按键；manual=True 为手动模式。"""
            if not self.scroll_enabled():
                # 正常路径下菜单项已经置灰，这里是兜底（热键/旧调用）
                self._notify(
                    tr("滚动长截图未启用"),
                    tr("这是实验性功能，默认关闭。请在托盘菜单"
                       "「滚动长截图（实验性）」里勾选"
                       "「启用滚动长截图（不稳定）」后再用。"))
                return
            if self.snipper is not None or self.scroller is not None:
                return
            # 用 "scroll" 模式：只取选区，不会触发普通截图流程（否则编辑器会被弹到前面挡住目标）
            self._start_snipper("scroll", scroll_mode="manual" if manual else mode)

        def _start_scrolling(self, region, manual: bool = False, mode: str = "wheel"):
            self._on_snip_done()   # 只清引用：滚动期间编辑器保持最小化，否则会被拍进画面
            if region.width() < 50 or region.height() < 120:
                self._notify(tr("滚动截图"), tr("区域太小，请框选更高的可滚动区域"))
                self._finish_capture_session()
                return
            driver = None
            if not manual:
                driver = ScrollDriver(mode, region)
            self._launch_scroller(region, manual=manual, driver=driver)

        def _launch_scroller(self, region, manual=False, driver=None, title=None):
            self.scroller = ScrollCapture(region, manual=manual, driver=driver)
            if title:
                self.scroller.bar.set_title(title)
            self.scroller.finished_ok.connect(self._on_scroll_finished)
            self.scroller.failed.connect(self._on_scroll_failed)
            # 等覆盖层完全关闭再开始，否则会拍到残影
            QTimer.singleShot(500, self.scroller.start)

        def _on_scroll_anchor(self, point):
            """用户在滚动条滑块上点了一下：开始"拖拽滚动条"自动滚动。"""
            self._on_snip_done()
            region = self._pending_scroll_region
            self._pending_scroll_region = None
            if region is None:
                self._finish_capture_session()
                return
            driver = ScrollDriver("drag", region, anchor=point)
            self._launch_scroller(region, manual=False, driver=driver,
                                  title="拖拽滚动条自动滚动")
            self._notify(tr("已记录滚动条位置"),
                         tr("滑块锚点 ({}, {})，开始自动拖拽滚动。\n", point.x(), point.y()) +
                         "滚到底会自动结束；想中途停止点控制条上的按钮。")

        def _on_scroll_finished(self, pixmap: QPixmap):
            self.scroller = None
            self._notify(tr("滚动截图完成"), f"已拼接 {pixmap.height()} px 长图")
            self.open_editor(pixmap)
            self._finish_capture_session()

        def _on_scroll_failed(self, msg: str):
            self.scroller = None
            self._notify(tr("滚动截图失败"), msg)
            self._finish_capture_session()

        # ---------- 屏幕取色 ----------
        def pick_color(self):
            self._start_snipper("color")

        def _on_color_picked(self, color):
            self._on_snip_done()
            text = color.name().upper()
            QApplication.clipboard().setText(text)
            self._notify(tr("屏幕取色"),
                         f"{text}  RGB({color.red()}, {color.green()}, {color.blue()})" + tr("已复制"))

        # ---------- 贴图钉板 ----------
        def pin_pixmap(self, pixmap: QPixmap, pos=None):
            pin = PinWindow(pixmap, pos)
            pin.closed.connect(
                lambda w: self.pins.remove(w) if w in self.pins else None)
            self.pins.append(pin)
            pin.show()
            return pin

        def pin_clipboard(self):
            pix = QApplication.clipboard().pixmap()
            if pix.isNull():
                self._notify(tr("贴图"), tr("剪贴板里没有图片"))
                return
            self.pin_pixmap(pix, QCursor.pos())

        def _notify(self, title: str, msg: str):
            if self.tray_available:
                self.tray.showMessage(title, msg, QSystemTrayIcon.Information, 4000)
            else:
                print(f"[{title}] {msg}")

        def notify_ready(self, restored: int = 0):
            """启动就绪提示（整个启动过程只弹这一条）。

            把热键、托盘用法、退出方式一次说清，避免"启动"和"就绪"两条气泡。
            恢复了上次的截图时，在标题上提一句。
            """
            if not self._hotkey_ok:
                tried = "、".join(DEFAULT_HOTKEYS)
                self._notify(
                    tr("PyShot 热键不可用"),
                    tr("热键（{}）都被占用，请双击托盘图标截图。\n", tried) +
                    tr("可用环境变量 PYSHOT_HOTKEY 指定其他组合，"
                       "例如 PYSHOT_HOTKEY=ctrl+alt+j"))
                return
            title = (tr("PyShot 已启动（恢复了 {} 张上次的截图）").format(restored)
                     if restored else tr("PyShot 已启动"))
            self._notify(
                title,
                tr("按 {} 框选截图，或双击托盘图标。\n", self.hotkey_text) +
                tr("右键托盘图标：滚动长截图 / 屏幕取色 / 贴图 / 退出。\n"
                   "找不到图标时点任务栏右侧的 ∧ 展开。"))

        def open_image(self):
            path, _ = QFileDialog.getOpenFileName(
                None, tr("打开图片"), str(Path.home()),
                tr("图片 (*.png *.jpg *.jpeg *.bmp *.gif *.webp)"))
            if not path:
                return
            pix = QPixmap(path)
            if pix.isNull():
                return
            self.open_editor(pix)

        # ---------- 会话（记住上次的截图，重启后还在）----------
        def _hook_session(self, editor):
            """编辑器内容变化时（防抖）把会话写到磁盘。"""
            editor.session_dirty.connect(self._schedule_session_save)
            # 关窗口时**立刻**存：这时标签还在，晚了就取不到了
            editor.closing.connect(self.save_session_now)
            for i in range(editor.tabs.count()):
                scroll = editor.tabs.widget(i)
                canvas = scroll.widget() if hasattr(scroll, "widget") else None
                if canvas is not None and hasattr(canvas, "shapes_changed"):
                    canvas.shapes_changed.connect(self._schedule_session_save)

        def _schedule_session_save(self):
            """延迟 1.5 秒写盘：连续操作只写一次，也不阻塞界面。"""
            if getattr(self, "_session_timer", None) is None:
                self._session_timer = QTimer()
                self._session_timer.setSingleShot(True)
                self._session_timer.timeout.connect(self.save_session_now)
            self._session_timer.start(1500)

        def save_session_now(self):
            """把所有编辑器的标签写进会话缓存（用户不用手动保存）。"""

            if not session_enabled():
                return False
            tabs = []
            for ed in list(self.editors):
                try:
                    tabs.extend(ed.session_tabs())
                except Exception:                      # noqa: BLE001
                    continue
            if not tabs and not self.editors:
                # 编辑器窗口都关了（不是"用户删光了标签"）—— 保留缓存，
                # 别把上次的截图清掉，否则下次点「显示编辑器」就是空的
                return False
            # 保护：当前标签比缓存里还少，且少掉的那些并不是用户主动关掉的
            # （编辑器是新建的、或标签数凭空变少），就不要覆盖缓存 ——
            # 否则"关窗口再截图"会把历史缓存冲掉，连重启都找不回来。
            try:
                cached = len(load_session())
            except Exception:                          # noqa: BLE001
                cached = 0
            if tabs and cached > len(tabs) and getattr(self, "_tabs_closed_by_user",
                                                       0) == 0:
                self._cap_log(f"跳过保存：当前 {len(tabs)} 个标签少于缓存的 {cached} 个")
                return False
            return save_session(tabs)

        def _restore_into(self, editor) -> int:
            """把会话缓存里的截图恢复到指定编辑器（已有标签则不动）。"""

            if not session_enabled() or editor.tabs.count() > 0:
                return 0
            try:
                tabs = load_session()
            except Exception:                          # noqa: BLE001
                return 0
            if not tabs:
                return 0
            editor.restore_session(tabs)
            return len(tabs)

        def restore_session(self):
            """启动时恢复上次的截图（有内容才显示编辑器）。"""

            if not session_enabled():
                return 0
            tabs = load_session()
            if not tabs:
                return 0
            editor = self._create_editor()
            if editor.tabs.count() == 0:       # _create_editor 没恢复成（比如关掉了开关）
                editor.restore_session(tabs)
            editor.show()
            editor.raise_()
            editor.activateWindow()
            return editor.tabs.count()

        def toggle_restore_session(self):
            """选项：启动时是否恢复上次截图。"""

            on = not session_enabled()
            set_session_enabled(on)
            if not on:
                clear_session()
            else:
                self.save_session_now()
            return on

        def show_editor(self):
            """显示编辑器：优先显示"有内容"的那个，空的就把上次的截图放回来。

            以前这里没有编辑器时会弹"打开图片"对话框，用户只是想看看编辑器却先被
            要求选文件；现在直接给一个空白编辑器。
            另外：窗口被关掉后再点这里，如果新窗口是空的，就把会话缓存里的截图
            恢复回来 —— 否则用户会觉得"历史不见了"。
            """
            # 保险：万有残留的截图遮罩（上次截图没正常结束），先收起来。
            # 遮罩是全屏置顶的，不收掉的话编辑器开了也被它盖住，
            # 用户看到的就是"点了显示编辑器但历史没出来"。
            for ov in getattr(self, "_overlays", []):
                try:
                    if ov.isVisible() or getattr(ov, "_active", False):
                        ov.finish()
                except Exception:                      # noqa: BLE001
                    pass
            self.snipper = None
            if not self.editors:
                self._create_editor()
            if not self.editors:                # 无托盘等极端情况
                return
            # 有标签的窗口优先（避免只显示到最新建的空窗口）
            with_tabs = [e for e in self.editors if e.tabs.count() > 0]
            ed = with_tabs[-1] if with_tabs else self.editors[-1]
            self._last_shown_editor = ed            # 便于测试断言选了哪个窗口
            if ed.tabs.count() == 0:
                self._restore_into(ed)          # 空窗口 → 把上次的截图放回来
            ed.show()
            ed.setWindowState(ed.windowState() & ~Qt.WindowMinimized)
            ed.raise_()
            ed.activateWindow()

        def _create_editor(self):
            """建一个编辑器窗口并接好信号（内容可以为空）。"""
            editor = EditorWindow()
            editor.setWindowIcon(make_tray_icon())
            editor.setAttribute(Qt.WA_DeleteOnClose)
            editor.destroyed.connect(
                lambda: self.editors.remove(editor) if editor in self.editors
                else None)
            editor.pin_requested.connect(
                lambda pix: self.pin_pixmap(pix, QCursor.pos()))
            editor.capture_requested.connect(self.capture_region)
            self._hook_session(editor)
            if hasattr(editor, "set_hotkey_hint"):
                editor.set_hotkey_hint(getattr(self, "hotkey_text", "") or "")
            self.editors.append(editor)
            # 新建的编辑器 = "用户又把编辑器打开了"：先把上次还在的标签放回来。
            # 关掉窗口后再截图（open_editor）走的也是这里 —— 以前只有「显示编辑器」
            # 会恢复，于是关窗口后新截的编辑器里只剩新图，历史像是丢了。
            try:
                self._restore_into(editor)
            except Exception:                          # noqa: BLE001
                pass
            return editor

        def open_editor(self, pixmap: QPixmap):
            """把截图送进编辑器：已有编辑器就新增标签页，否则新建窗口。"""
            editor = self.editors[-1] if self.editors else self._create_editor()
            editor.add_canvas(pixmap)
            editor.set_hotkey_hint(self.hotkey_text)
            editor.show()
            editor.setWindowState(editor.windowState() & ~Qt.WindowMinimized)
            editor.raise_()
            editor.activateWindow()


    def main():
        # --check-deps：只检查依赖，不开界面
        if "--check-deps" in sys.argv:
            print(deps_report())
            return

        # Windows 任务栏图标分组
        try:
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID("pyshot.app")
        except Exception:
            pass
        QGuiApplication.setHighDpiScaleFactorRoundingPolicy(
            Qt.HighDpiScaleFactorRoundingPolicy.PassThrough)
        try:

            install_excepthook()
            if enabled():
                log("启动", "诊断日志已开启，写入 ~/.pyshot/debug.log")
        except Exception:                              # noqa: BLE001
            pass
        app = QApplication(sys.argv)
        app.setQuitOnLastWindowClosed(False)  # 托盘常驻
        app.setApplicationName("PyShot")
        apply_theme(app)

        core = PyShotApp(app)
        try:

            dump_env()
        except Exception:                              # noqa: BLE001
            pass
        app.aboutToQuit.connect(core.shutdown)

        # Ctrl+C 优雅退出。
        # 直接在控制台按 Ctrl+C 时，Python 会把 KeyboardInterrupt 抛进 Qt 的原生事件
        # 过滤器回调里，表现为一大段 "Error calling Python override of
        # QAbstractNativeEventFilter::nativeEventFilter()" 报错、而且进程不一定退。
        # 这里把 SIGINT 接管掉：用一个空转的 QTimer 让 Python 有机会处理信号，
        # 收到信号就正常 quit()（会走 shutdown，把托盘图标和热键都收干净）。
        def _on_sigint(signum, frame):
            print()  # 让 ^C 后面换行，提示更清楚
            print("[PyShot] 收到 Ctrl+C，正在退出…")
            app.quit()

        try:
            signal.signal(signal.SIGINT, _on_sigint)
            _sigint_timer = QTimer()
            _sigint_timer.timeout.connect(lambda: None)   # 空转，仅用来跑信号处理
            _sigint_timer.start(200)
            core._sigint_timer = _sigint_timer           # 持有引用，别被回收
        except Exception:                                 # noqa: BLE001
            pass

        # 命令行直接给图片路径则直接进入编辑
        if len(sys.argv) > 1 and Path(sys.argv[1]).is_file():
            pix = QPixmap(sys.argv[1])
            if not pix.isNull():
                core.open_editor(pix)
            else:
                core.capture_region()
        elif not core.tray_available:
            # 没有系统托盘的环境（极少数）：直接进截图，否则用户看不到任何入口
            core.capture_region()
        else:
            # 正常启动：只驻留托盘，不自动开始截图（避免启动就被全屏覆盖层挡住而以为卡死）
            #
            # 关键：恢复会话/就绪提示**推迟到事件循环里**（见 boot_restore 的注释）。
            # 它们要建编辑器窗口，会触发进程内第一次文字排版和首次标签页开销
            # （本机 5 秒级），放在 exec() 之前会把托盘和全局热键一起卡住。
            _cap = getattr(core, "_cap_log", None)
            if _cap:
                _cap("启动·托盘就绪",
                     f"PyShot {APP_VERSION} · 从进程开始 "
                     f"{(time.perf_counter()-_PROC_T0)*1000:.0f} ms"
                     f"（热键={core.hotkey_text or '无'}）")
            core.schedule_boot()

        sys.exit(app.exec())



    # ---------------------------------------------------------------------------
    # 单文件版入口
    # ---------------------------------------------------------------------------
    if __name__ == "__main__":
        if "--check-deps" in sys.argv:
            print(deps_report())
        else:
            main()

# ---- 双模式 (3/3): 独立运行 = 直接跑原程序(原程序的 `__main__` 块就在 `_app_main()` 里) ----
if __name__ == '__main__':
    _auto = os.environ.get('WGIME_STANDALONE_AUTOEXIT_MS')      # 回归测试钩子: 不出界面
    if _auto:
        os.environ.setdefault('PYSHOT_SKIP_DEPS', '1')          # 别联网装包
        os.environ.setdefault('PYSHOT_NO_ALERT', '1')           # 别弹模态框
        if '--check-deps' not in sys.argv:
            sys.argv.append('--check-deps')                     # 只报依赖就退
    try:
        _app_main()
    except ImportError as _ex:                                  # 缺 PySide6: 自动化里当"跳过"而不是红
        if not _auto:
            raise
        print('STANDALONE-SKIP-DEPS %s' % _ex, flush=True)
    finally:
        if _auto:
            print('STANDALONE-OK', flush=True)
