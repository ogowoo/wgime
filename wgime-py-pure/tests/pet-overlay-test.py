# -*- coding: utf-8 -*-
r"""桌面宠物 widget 回归 (目标轮次 2): plugins\wgpet.py 的契约 + 浮层的**客观判据**.

为什么这么测(而不是靠肉眼看"狗在不在动"): AGENTS-DETAIL.md §D36 定下的判据全是 Win32 客观量 ——
  ① `GetPixel` 精灵处 == 颜色      => 分层窗**真的可见**(有了这条, 下面那条才不是空转)
  ② 窗口内空白点像素显示前后不变   => 键色**真透明**(没把屏幕糊住)
  ③ `WindowFromPoint` 不是本窗      => 鼠标**真穿透**
  ④ `GetForegroundWindow` 前后一致  => **没抢焦点**(输入法旁边挂件最要紧的性质)
  ⑤ `GWL_EXSTYLE` 四条样式齐
外加交互态(要用户点工具时): 去掉 TRANSPARENT 后 —— 面板处点得到、面板外仍穿透、前台仍不变。

S 段(纯结构, 无桌面也跑): 清单契约 / `_` 开头不被收 / 工具去重且不含自己 / **模块导入不建窗**
  (§8.8 陷阱 1: 模块级代码在输入法启动时就执行) / **入口只有一个 `__main__` 块**(§45)。
L 段(真起浮层, 无桌面 SKIP): 上面 ①~⑤ + 交互态 + 点格子会"叼出去" + 帧率 + 干净退出。

跑法: python wgime-py-pure\tests\pet-overlay-test.py
"""
import ctypes
import ctypes.wintypes as w
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
PET = os.path.join(PURE, 'plugins', 'wgpet.py')

fails, n = [], [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


# ---------------- Win32 (判据用) ----------------
user32 = ctypes.windll.user32
gdi32 = ctypes.windll.gdi32
user32.FindWindowW.restype, user32.FindWindowW.argtypes = ctypes.c_void_p, [w.LPCWSTR, w.LPCWSTR]
user32.GetForegroundWindow.restype, user32.GetForegroundWindow.argtypes = ctypes.c_void_p, []
user32.WindowFromPoint.restype, user32.WindowFromPoint.argtypes = ctypes.c_void_p, [w.POINT]
user32.GetAncestor.restype, user32.GetAncestor.argtypes = ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_uint]
user32.GetWindowLongPtrW.restype, user32.GetWindowLongPtrW.argtypes = ctypes.c_ssize_t, [ctypes.c_void_p,
                                                                                        ctypes.c_int]
user32.PostMessageW.restype, user32.PostMessageW.argtypes = ctypes.c_int, [
    ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
user32.IsWindow.restype, user32.IsWindow.argtypes = ctypes.c_int, [ctypes.c_void_p]
user32.GetDC.restype, user32.GetDC.argtypes = ctypes.c_void_p, [ctypes.c_void_p]
user32.ReleaseDC.restype, user32.ReleaseDC.argtypes = ctypes.c_int, [ctypes.c_void_p]
gdi32.GetPixel.restype, gdi32.GetPixel.argtypes = w.DWORD, [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]

GWL_EXSTYLE = -20
EX_LAYERED, EX_TRANSPARENT, EX_NOACTIVATE, EX_TOOLWINDOW, EX_TOPMOST = 0x80000, 0x20, 0x8000000, 0x80, 0x8
WM_LBUTTONDOWN, WM_APP_TOGGLE = 0x0201, 0x8002
COLOR_FUR = 0x3f8bd9          # '#d98b3f' -> COLORREF(新配色)
COLOR_PANEL = 0x261c14        # '#141c26'
COLOR_SLOT = 0x473424         # '#243447'
COLOR_SLOT_H = 0x6f5339       # '#39536f'
_SCREEN = [None]


def pixel(x, y):
    """读一个屏幕像素。

    **本机 GetPixel 实测 ~8.5ms/次**(4K + DWM + 分层窗还在动) —— 所以断言里**绝不允许整屏/整条扫描**:
    实测扫一条 3840x178 要 162 秒, 直接把被测进程的存活窗口耗光, 后面几条全成假红(真踩过)。
    规矩: 先用 `WM_APP_PAUSE` 冻住动画, 再按 dump 里的坐标**只扫几十个像素**。
    (也试过 BitBlt 抓一块再在内存里找, 但 BitBlt 抓不到这个分层窗, 见 §D38。)
    """
    if _SCREEN[0] is None:
        _SCREEN[0] = user32.GetDC(None)
    return int(gdi32.GetPixel(_SCREEN[0], int(x), int(y))) & 0xFFFFFF


def release_dc():
    if _SCREEN[0] is not None:
        try:
            user32.ReleaseDC(None, _SCREEN[0])
        except Exception:
            pass
        _SCREEN[0] = None


def pause(hwnd):
    """冻住动画(WM_APP_PAUSE, wp=1), 让"状态里的坐标" == "屏幕上的像素"。"""
    user32.PostMessageW(ctypes.c_void_p(int(hwnd)), 0x8005, 1, 0)
    time.sleep(0.35)


def wait_still(live, timeout=4.0):
    """等到 dump 里的位置**连续两次一样**(= 真冻住了) 再返回那份 dump。

    为什么要这一步: dump 每 0.4s 才写一次, 按下暂停时手里那份可能是上一拍的 —— 主角在爬(甚至
    正在横跳, 400px/0.4s), 拿旧坐标去扫像素必然扫空(踩过一次)。
    """
    end = time.time() + timeout
    prev = None
    while time.time() < end:
        d = read_dump(live)
        if d:
            pos = d.get('dog_pos')
            if prev is not None and pos == prev:
                return d
            prev = pos
        time.sleep(0.15)
    return read_dump(live)


def unpause(hwnd):
    user32.PostMessageW(ctypes.c_void_p(int(hwnd)), 0x8005, 0, 0)
    time.sleep(0.2)

def root_of(h):
    h = int(h or 0)
    return (int(user32.GetAncestor(ctypes.c_void_p(h), 2) or 0) or h) if h else 0


def release_dc():
    if _SCREEN[0] is not None:
        try:
            user32.ReleaseDC(None, _SCREEN[0])
        except Exception:
            pass
        _SCREEN[0] = None


def scan_box(x0, y0, x1, y1, colors, step=5):
    """在矩形里找颜色 -> 屏幕坐标 (x, y) 或 None。**只用于小范围**(见 pixel() 的告警)。"""
    for y in range(int(y0), int(y1), max(1, int(step))):
        hit = scan_row(x0, x1, y, colors, step=step)
        if hit is not None:
            return (hit, y)
    return None


def scan_row(x0, x1, y, colors, step=4):
    for x in range(int(x0), int(x1), max(1, int(step))):
        if pixel(x, y) in colors:
            return x
    return None


def wait_pixel(x, y, colors, timeout=4.0):
    """等到某个像素真的被画出来。**别用状态 dump 当"已经画好了"** —— dump 是状态快照,
    而 InvalidateRect -> WM_PAINT 是异步的, 差一两帧就会让"命中测试"那条假红。"""
    end = time.time() + timeout
    while time.time() < end:
        if pixel(x, y) in colors:
            return True
        time.sleep(0.04)
    return False


# ======================================================================
# S 段: 结构 / 契约 (无桌面也跑)
# ======================================================================
def part_s():
    print('--- S. 结构与契约(不建窗) ---')
    src = open(PET, encoding='utf-8').read()
    check('文件存在且是 UTF-8 无 BOM(以 # -*- coding 开头)',
          src.startswith('# -*- coding: utf-8 -*-') and '\r\n' not in src)

    spec = importlib.util.spec_from_file_location('wgpet_s_test', PET)
    md = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(md)                    # 宿主也是这样装载的(__name__ != '__main__')
    check('CODE 非空(宿主登记条件)', bool(getattr(md, 'CODE', '')))
    check('NAME/DESC/VERSION/PERM 齐', all(getattr(md, k, '') for k in ('NAME', 'DESC', 'VERSION', 'PERM')))
    check('STANDALONE = True(双模式标记)', getattr(md, 'STANDALONE', False) is True)
    check('run() 可调用且无参', callable(getattr(md, 'run', None))
          and md.run.__code__.co_argcount == 0)
    check('CHILD_ARG 存在(宿主入口靠它另起浮层进程)', bool(getattr(md, 'CHILD_ARG', '')))
    check('窗口标题含文件名主干 wgpet(§46 结束窗口要靠它认出来)',
          'wgpet' in getattr(md, 'WIN_TITLE', ''))
    check('入口只有一个 __main__ 块(§45)', src.count("if __name__ == '__main__':") == 1,
          'count=%d' % src.count("if __name__ == '__main__':"))
    check('独立运行契约齐(STANDALONE-OK 标记 + AUTOEXIT 钩子)',
          'STANDALONE-OK' in src and 'WGIME_STANDALONE_AUTOEXIT_MS' in src)

    # §8.8 陷阱 1: 模块级不许建窗口/占资源 —— 刚才 exec_module 之后屏幕上不该多出我们的窗口
    check('模块导入**没有**建窗(模块级无副作用)',
          int(user32.FindWindowW(md.CLASS_NAME, md.WIN_TITLE) or 0) == 0)

    fg = int(user32.GetForegroundWindow() or 0)
    time.sleep(0.25)
    check('模块导入没抢焦点', int(user32.GetForegroundWindow() or 0) == fg)

    # 工具发现: 去重 / 不含自己 / 字段齐
    tools = md.discover_tools()
    codes = [t['code'].lower() for t in tools]
    check('工具清单非空(能列出你的插件)', len(tools) >= 1, 'n=%d' % len(tools))
    check('工具按 code 去重(同一插件不在两个目录里重复出现)', len(codes) == len(set(codes)),
          repr(sorted(c for c in codes if codes.count(c) > 1)))
    check('工具清单不含宠物自己', 'pet' not in codes, repr(codes))
    check('每个工具有 code/name/kind/path',
          all(t.get('code') and t.get('name') and t.get('kind') in ('py', 'txt') and t.get('path')
              for t in tools))
    print('    工具: %s' % ', '.join('%s(%s)' % (t['code'], t['kind']) for t in tools))

    # _py_meta: 没有 CODE / 没有 run() 的文件不算插件
    tmp = tempfile.mkdtemp(prefix='wg-pet-s-')
    try:
        p1 = os.path.join(tmp, 'no_code.py')
        open(p1, 'w', encoding='utf-8').write('def run():\n    pass\n')
        p2 = os.path.join(tmp, 'no_run.py')
        open(p2, 'w', encoding='utf-8').write("CODE = 'zz'\n")
        check('_py_meta: 缺 CODE 返回 None(不算插件)', md._py_meta(p1) is None)
        check('_py_meta: 缺 run() 返回 None(不算插件)', md._py_meta(p2) is None)
        p3 = os.path.join(tmp, 'ok.py')
        open(p3, 'w', encoding='utf-8').write("CODE = 'zz'\nNAME = '测试'\nPERM = 'low'\n"
                                              "def run():\n    pass\n")
        m = md._py_meta(p3)
        check('_py_meta: 正常插件读出 CODE/NAME', bool(m) and m['code'] == 'zz' and m['name'] == '测试',
              repr(m))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 宠物自己那条 API 路径(第八十六轮"点工具没反应"的守卫):
    # 发行版是单文件, 插件的 run() 要 import ui/win, 子进程 import 不到 -> 必须由宿主本体来跑。
    host = md._host_file()
    check('宠物找得到宿主本体(跑插件只能由它跑)', bool(host) and os.path.exists(host), repr(host))
    api = md._api_call(['list-plugins'], timeout=60)
    check('宿主 API 通(list-plugins 返回插件清单)', bool(api and api.get('plugins')),
          repr(api)[:140])
    if api and api.get('plugins'):
        codes = [p.get('code') for p in api['plugins']]
        check('API 清单里有工具(不只是它自己)', len(codes) >= 2, repr(codes))
    app = md._find_app_dir()
    check('_find_app_dir 找到码表目录(插件目录靠它定位)', os.path.exists(os.path.join(app, 'py.txt'))
          or os.path.exists(os.path.join(app, 'dicts', 'py.txt')), app)
    return md


# ======================================================================
# L 段: 真起浮层 (需要桌面)
# ======================================================================
def read_dump(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except Exception:
        return None


def wait_dump(path, pred, timeout=12.0):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        d = read_dump(path)
        if d:
            last = d
            if pred(d):
                return d
        time.sleep(0.15)
    return last


def part_l(md):
    print('--- L. 真起浮层(客观判据) ---')
    try:
        import tkinter as tk
        r = tk.Tk()
        r.destroy()
    except Exception as ex:
        print('SKIP: 没有可用桌面 (%r)' % (ex,))
        return

    tmp = tempfile.mkdtemp(prefix='wg-pet-l-')
    live = os.path.join(tmp, 'live.json')
    final = os.path.join(tmp, 'final.json')
    env = dict(os.environ)
    env.update({'WGIME_PET_SELFTEST_MS': '9000', 'WGIME_PET_DUMP_LIVE': live,
                'WGIME_PET_DUMP': final, 'WGIME_PET_NO_LAUNCH': '1',
                'LOCALAPPDATA': tmp, 'PYTHONIOENCODING': 'utf-8'})
    proc = subprocess.Popen([sys.executable, '-X', 'utf8', PET], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    before_center = pixel(1920, 700)              # 屏幕中部(宠物只在下缘活动)
    fg_before = int(user32.GetForegroundWindow() or 0)
    try:
        d = wait_dump(live, lambda x: x.get('frames', 0) > 20, timeout=15)
        if not d:
            check('浮层起来了(能读到状态)', False, 'live dump 没出现')
            out, err = proc.communicate(timeout=5)
            print('    stdout=%r stderr=%r' % ((out or b'')[-200:], (err or b'')[-400:]))
            return
        hwnd = int(d['hwnd'])
        check('窗口在(FindWindow 找得到)', hwnd > 0 and user32.IsWindow(ctypes.c_void_p(hwnd)) != 0)
        check('标题能被插件管理器认出来(§46)',
              int(user32.FindWindowW(md.CLASS_NAME, md.WIN_TITLE) or 0) == hwnd)

        st = int(user32.GetWindowLongPtrW(ctypes.c_void_p(hwnd), GWL_EXSTYLE))
        check('LAYERED|TRANSPARENT|NOACTIVATE|TOOLWINDOW|TOPMOST 五条齐',
              bool(st & EX_LAYERED) and bool(st & EX_TRANSPARENT) and bool(st & EX_NOACTIVATE)
              and bool(st & EX_TOOLWINDOW) and bool(st & EX_TOPMOST), '0x%08x' % st)
        check('起窗后**没抢焦点**', int(user32.GetForegroundWindow() or 0) == fg_before,
              '%x -> %x' % (fg_before, int(user32.GetForegroundWindow() or 0)))
        hit = root_of(user32.WindowFromPoint(w.POINT(1920, 700)))
        check('屏幕中部鼠标**穿透**(WindowFromPoint 不是本窗)', hit != root_of(hwnd),
              'hit=%x own=%x' % (hit, root_of(hwnd)))
        check('屏幕中部像素没被糊住(键色真透明)', pixel(1920, 700) == before_center,
              '%06x -> %06x' % (before_center, pixel(1920, 700)))

        # 冻住动画再验像素: 坐标与屏幕严格一致, 于是只扫几十个像素就够(GetPixel 很贵)
        pause(hwnd)
        d = wait_still(live) or d
        bx0, by0, bx1, by1 = d['dog_bbox']
        found = scan_row(bx0, bx1, int(d['dog_y']) - 45, {COLOR_FUR, 0x8ac4f0, 0x1f63a9}, step=3)
        check('狗**真的画在**屏幕下缘了(在它身上扫到毛色)', found is not None,
              'bbox=%s y=%s' % (d['dog_bbox'], int(d['dog_y']) - 45))
        unpause(hwnd)

        f0 = d['frames']
        time.sleep(1.2)
        d2 = read_dump(live) or d
        fps = (d2['frames'] - f0) / 1.2
        check('动画在跑(>=30fps, 实测目标 59)', fps >= 30, '%.1f fps' % fps)
        check('狗在自己走动(位置变了)', abs(d2['dog_x'] - d['dog_x']) > 0.5,
              '%s -> %s' % (d['dog_x'], d2['dog_x']))

        # ---- 交互态: 开面板 ----
        user32.PostMessageW(ctypes.c_void_p(hwnd), WM_APP_TOGGLE, 0, 0)
        d3 = wait_dump(live, lambda x: x.get('palette_open'), timeout=6)
        check('呼出后 palette_open=True', bool(d3 and d3.get('palette_open')),
              repr(d3 and d3.get('palette_open')))
        if d3 and d3.get('palette_open'):
            st3 = int(user32.GetWindowLongPtrW(ctypes.c_void_p(hwnd), GWL_EXSTYLE))
            check('交互态: TRANSPARENT 已去掉(点得到工具)', not (st3 & EX_TRANSPARENT),
                  '0x%08x' % st3)
            check('交互态: NOACTIVATE **仍在**(点工具不抢焦点)', bool(st3 & EX_NOACTIVATE))
            slots = d3.get('slots') or []
            check('面板格子算得出来', len(slots) == d3['tools_n'] and len(slots) > 0,
                  '%d slots / %d tools' % (len(slots), d3['tools_n']))
            if slots:
                pause(hwnd)                            # 面板位置冻住再验像素/命中
                d3 = wait_still(live) or d3
                slots = d3.get('slots') or slots
                sx = (slots[0][0] + slots[0][2]) // 2
                sy = (slots[0][1] + slots[0][3]) // 2
                # 先等这一格真的被画出来, 再问"点得到吗"(否则命中测试会撞上还没重绘的那一两帧)
                painted = wait_pixel(sx, sy, {COLOR_SLOT, COLOR_SLOT_H, COLOR_PANEL})
                check('交互态: 那一格已经画好了(不是靠状态 dump 猜的)', painted)
                check('交互态: 面板处 WindowFromPoint **就是本窗**',
                      root_of(user32.WindowFromPoint(w.POINT(sx, sy))) == root_of(hwnd),
                      'hit=%x own=%x' % (root_of(user32.WindowFromPoint(w.POINT(sx, sy))),
                                         root_of(hwnd)))
            pl = d3.get('panel') or [0, 0, 0, 0]
            py = pl[1] + 12
            drawn = scan_row(pl[0], pl[2], py, {COLOR_PANEL, COLOR_SLOT, COLOR_SLOT_H}, step=8)
            check('交互态: 面板**真的画出来了**(扫到面板底色)', drawn is not None,
                  'panel=%s row_y=%s' % (pl, py))
            unpause(hwnd)
            check('交互态: 面板外的空白处**仍然穿透**',
                  root_of(user32.WindowFromPoint(w.POINT(1920, 700))) != root_of(hwnd))
            check('开面板期间**焦点没被我们抢走**(前台不是本窗)',
                  root_of(int(user32.GetForegroundWindow() or 0)) != root_of(hwnd),
                  'fg=%x own=%x' % (int(user32.GetForegroundWindow() or 0), root_of(hwnd)))

            # ---- 点一个格子: 应该"叼出去"(抛向屏幕中心) ----
            if slots:
                lparam = (sy << 16) | (sx & 0xFFFF)
                user32.PostMessageW(ctypes.c_void_p(hwnd), WM_LBUTTONDOWN, 1, lparam)
                d4 = wait_dump(live, lambda x: x.get('threw'), timeout=6)
                check('点格子后"叼出去"了(记录到工具 code)',
                      bool(d4 and d4.get('threw')), repr(d4 and d4.get('threw')))
                if d4 and d4.get('threw'):
                    check('叼的正是点的那个工具', d4['threw'][0] == d4['tools'][0],
                          '%s vs %s' % (d4['threw'], d4['tools'][:1]))
                    check('叼出去后面板收起(不再占据鼠标)', not d4.get('palette_open'))
                d5 = wait_dump(live, lambda x: x.get('launched'), timeout=6)
                check('抛到屏幕中间后**触发了执行**(测试钩子只记不跑)',
                      bool(d5 and d5.get('launched')), repr(d5 and d5.get('launched')))
                check('执行期间**焦点仍在别人那儿**(前台不是本窗)',
                      root_of(int(user32.GetForegroundWindow() or 0)) != root_of(hwnd),
                      'fg=%x own=%x' % (int(user32.GetForegroundWindow() or 0), root_of(hwnd)))

        # ---- 收尾: 自动退出 + 终版 dump + 无残留 ----
        out, err = proc.communicate(timeout=25)
        check('到点自己退出(rc=0)', proc.returncode == 0,
              'rc=%s err=%r' % (proc.returncode, (err or b'')[-300:]))
        out_s = (out or b'').decode('utf-8', 'replace')
        check('独立运行打印 STANDALONE-OK', 'STANDALONE-OK' in out_s, repr(out_s[-120:]))
        fin = read_dump(final)
        check('终版 dump 写出来了', bool(fin))
        if fin:
            check('退出前窗口已销毁', user32.IsWindow(ctypes.c_void_p(int(fin['hwnd']))) == 0)
            check('终版复核: 焦点始终没被本窗抢走',
                  root_of(int(user32.GetForegroundWindow() or 0)) != root_of(int(fin['hwnd'])),
                  'fg=%x own=%x' % (int(user32.GetForegroundWindow() or 0), int(fin['hwnd'])))
        check('没留下我们自己的窗口(FindWindow 为空)',
              int(user32.FindWindowW(md.CLASS_NAME, md.WIN_TITLE) or 0) == 0)
    finally:
        if proc.poll() is None:
            proc.kill()
            try:
                proc.communicate(timeout=5)
            except Exception:
                pass
        shutil.rmtree(tmp, ignore_errors=True)


def _spawn(tmp, scene, live, final, extra=None, secs='9000'):
    env = dict(os.environ)
    env.update({'WGIME_PET_SELFTEST_MS': secs, 'WGIME_PET_DUMP_LIVE': live,
                'WGIME_PET_DUMP': final, 'WGIME_PET_NO_LAUNCH': '1',
                'WGIME_PET_SCENE': str(scene), 'LOCALAPPDATA': tmp,
                'PYTHONIOENCODING': 'utf-8'})
    env.update(extra or {})
    return subprocess.Popen([sys.executable, '-X', 'utf8', PET], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _kill(proc):
    if proc.poll() is None:
        try:
            proc.kill()
            proc.communicate(timeout=5)
        except Exception:
            pass


def part_smear(md):
    """走过不留残影: 精灵放大了但脏矩形没跟上 -> 走一路攒一条拖尾(用户截图那个"横带")。

    做法: 起宠**之前**先记住底部几个点的像素 -> 等狗从它们身上走过去 -> 冻住动画 ->
    再读这几个点, 必须与基线**完全一致**。残影就是"那里还留着狗的颜色"。
    (比"扫一条线找毛色"可靠: 不依赖壁纸/任务栏里有没有相近颜色 —— 这个坑我也踩了。)
    """
    print('--- L4. 走过不留残影(脏矩形) ---')
    try:
        import tkinter as tk
        r = tk.Tk()
        r.destroy()
    except Exception as ex:
        print('SKIP: 没有可用桌面 (%r)' % (ex,))
        return
    sw = user32.GetSystemMetrics(0)
    sh = user32.GetSystemMetrics(1)
    tmp = tempfile.mkdtemp(prefix='wg-pet-smear-')
    live, final = os.path.join(tmp, 'live.json'), os.path.join(tmp, 'final.json')
    # 高度取狗身那一段(而不是最底下 45px): 最底下是任务栏, 它是半透明的, 像素本来就会变
    pts = [(int(sw * 0.45), sh - 150), (int(sw * 0.35), sh - 150), (int(sw * 0.28), sh - 150)]
    base = [pixel(x, y) for (x, y) in pts]          # 起宠前的基线
    proc = _spawn(tmp, 2, live, final, {'WGIME_PET_FAKE_MOUSE': '10,10'}, secs='20000')
    try:
        d = wait_dump(live, lambda x: x.get('frames', 0) > 20, timeout=15)
        if not d:
            check('残影检查: 宠物起来了', False, 'no live dump')
            return
        # 等它从这几个点**走过去**(狗默认向左走): x 小于最左那个点 200px 以上
        end = time.time() + 20
        while time.time() < end:
            d = read_dump(live) or d
            if (d.get('dog_x') or sw) < pts[-1][0] - 200:
                break
            time.sleep(0.2)
        pause(d['hwnd'])
        d = wait_still(live) or d
        check('残影检查: 狗确实走过去了', (d.get('dog_x') or sw) < pts[-1][0],
              'dog_x=%s 目标<%s' % (d.get('dog_x'), pts[-1][0]))
        after = [pixel(x, y) for (x, y) in pts]
        same = sum(1 for a, b in zip(base, after) if a == b)
        check('走过不留残影(走过的点上像素回到基线 %d/%d)' % (same, len(pts)),
              same == len(pts),
              ' '.join('(%d,%d) %06x->%06x' % (x, y, b, a)
                       for (x, y), b, a in zip(pts, base, after) if a != b))
        unpause(d['hwnd'])
        _kill(proc)
    finally:
        _kill(proc)
        shutil.rmtree(tmp, ignore_errors=True)


def part_scene1(md):
    """场景 1(篮球): 运球 / 回车投篮(球进筐+篮筐亮) / 呼出=砸球->炸开->面板。"""
    print('--- L2. 场景 1: 篮球 ---')
    tmp = tempfile.mkdtemp(prefix='wg-pet-s1-')
    live, final = os.path.join(tmp, 'live.json'), os.path.join(tmp, 'final.json')
    proc = _spawn(tmp, 1, live, final, {'WGIME_PET_FAKE_MOUSE': '10,10'}, secs='25000')
    try:
        d = wait_dump(live, lambda x: x.get('frames', 0) > 20, timeout=15)
        if not d:
            out, err = proc.communicate(timeout=5)
            check('场景 1 起来了', False, 'no live dump; err=%r' % ((err or b'')[-300:],))
            return
        check('场景 1 起来了', d.get('scene') == 1, 'scene=%s' % d.get('scene'))
        # 篮板/篮筐真的画在屏幕两边: 在筐的位置扫到筐色 (#e04b3a -> COLORREF 0x3a4be0)
        hy = d.get('hoop_y')
        hx = (d.get('hoop_x') or [0, 0])[0]
        rx0, rx1 = hx - 34, hx + 34
        rim = None
        for yy in range(int(hy) - 12, int(hy) + 13, 3) if hy else []:
            if scan_row(rx0, rx1, yy, {0x3a4be0}, step=2) is not None:
                rim = yy
                break
        check('左右篮筐真的画出来了(左边筐位置扫到筐色)', rim is not None,
              'hoop=%s,%s' % (hx, hy))
        pause(d['hwnd'])                          # 球在弹, 冻住再扫
        d = wait_still(live) or d
        bx, by = d['ball']
        # 别扫正中心那一行: 球的十字线正好画在 y=by 上(会扫到深色线而不是橙色填充)
        found = scan_row(bx - 26, bx + 26, int(by) - 8, {0x1e70e2}, step=2)
        check('球**真的画在**屏幕下缘(扫到球色)', found is not None, 'ball=%s,%s' % (bx, by))
        unpause(d['hwnd'])
        check('起始状态在运球', d.get('ball_mode') == 'dribble', repr(d.get('ball_mode')))

        # 打字 -> 原地运球(活动度起来)
        user32.PostMessageW(ctypes.c_void_p(int(d['hwnd'])), 0x8004, 0, 0)     # WM_APP_ACTIVITY
        d2 = wait_dump(live, lambda x: x.get('activity', 0) > 0.2, timeout=4)
        check('打字 -> activity 起来(他改成原地运球)', bool(d2 and d2.get('activity', 0) > 0.2),
              repr(d2 and d2.get('activity')))

        # 回车 -> 投篮: 球会经历 shoot -> back, 进筐时 hoop_flash > 0
        user32.PostMessageW(ctypes.c_void_p(int(d['hwnd'])), 0x8003, 0, 0)     # WM_APP_ENTER
        shot = wait_dump(live, lambda x: x.get('ball_mode') in ('shoot', 'back')
                         or x.get('hoop_flash', 0) > 0, timeout=5)
        check('回车 -> 投篮(球离手/在回手路上)',
              bool(shot and (shot.get('ball_mode') in ('shoot', 'back') or shot.get('hoop_flash', 0) > 0)),
              repr(shot and (shot.get('ball_mode'), shot.get('hoop_flash'))))
        made = wait_dump(live, lambda x: x.get('hoop_flash', 0) > 0.05, timeout=5)
        check('球进筐了(篮筐亮起来 hoop_flash>0)', bool(made and made.get('hoop_flash', 0) > 0.05),
              repr(made and made.get('hoop_flash')))
        back = wait_dump(live, lambda x: x.get('ball_mode') == 'dribble', timeout=6)
        check('投完自己把球捡回来接着运', bool(back and back.get('ball_mode') == 'dribble'),
              repr(back and back.get('ball_mode')))

        # 呼出 = 砸球 -> 炸开 -> 面板
        user32.PostMessageW(ctypes.c_void_p(int(d['hwnd'])), 0x8002, 0, 0)     # WM_APP_TOGGLE
        d3 = wait_dump(live, lambda x: x.get('slam') or x.get('palette_open'), timeout=4)
        check('呼出先是"把球砸向屏幕中间"(slam=True)', bool(d3 and d3.get('slam')),
              repr(d3 and (d3.get('slam'), d3.get('palette_open'))))
        d4 = wait_dump(live, lambda x: x.get('palette_open'), timeout=5)
        check('砸到位之后炸开并弹出工具面板', bool(d4 and d4.get('palette_open')),
              repr(d4 and d4.get('palette_open')))
        check('砸完就没 slam 了(动画收尾)', bool(d4 and not d4.get('slam')))
        _kill(proc)
        check('场景 1 收尾干净(杀得掉)',
              int(user32.FindWindowW(md.CLASS_NAME, md.WIN_TITLE) or 0) == 0
              or proc.poll() is not None)
    finally:
        _kill(proc)
        shutil.rmtree(tmp, ignore_errors=True)


def _critter_start(screen):
    """ClimbScene 的起始位置(测试要知道鼠标该放哪): s = sw*0.35 -> 底边。"""
    return (screen[0] * 0.35, screen[1] - 6)


def part_scene3(md):
    """场景 3(四边框): 沿边框巡游 / 鼠标贴脸就躲 / 闲了横跳(全屏都是它的地盘)。"""
    print('--- L3. 场景 3: 四边框攀爬 + 躲猫猫 ---')
    tmp = tempfile.mkdtemp(prefix='wg-pet-s3-')
    live, final = os.path.join(tmp, 'live.json'), os.path.join(tmp, 'final.json')
    # (a) 鼠标在远处 -> 自己沿着边框巡游, 并且到点会横跳
    proc = _spawn(tmp, 3, live, final, {'WGIME_PET_FAKE_MOUSE': '10,10',
                                        'WGIME_PET_LEAP_MS': '900'})
    try:
        d = wait_dump(live, lambda x: x.get('frames', 0) > 20, timeout=15)
        if not d:
            out, err = proc.communicate(timeout=5)
            check('场景 3 起来了', False, 'no live dump; err=%r' % ((err or b'')[-300:],))
            return
        check('场景 3 起来了', d.get('scene') == 3, 'scene=%s' % d.get('scene'))
        check('鼠标远 -> 自己在巡游(climb_mode=roam)', d.get('climb_mode') == 'roam',
              repr(d.get('climb_mode')))
        pause(d['hwnd'])                          # 主角在爬, 冻住再扫
        d = wait_still(live) or d
        px, py = d['dog_pos']
        found = scan_row(px - 70, px + 70, int(py) - 30, {0x3f8bd9, 0x8ac4f0, 0x1f63a9}, step=4)
        check('主角真的画在边框上了(扫到毛色)', found is not None, 'pos=%s,%s' % (px, py))
        unpause(d['hwnd'])
        s0 = d.get('leaped')
        time.sleep(1.0)
        d2 = read_dump(live) or d
        p2 = d2.get('dog_pos') or [px, py]
        moved = abs(p2[0] - px) + abs(p2[1] - py)
        # 注意: 横跳途中 self.s 只在落地那一刻才更新, 所以别只盯 s —— 位置动了才算真的在动
        check('沿边框在移动(位置真的变了)',
              moved > 5 or abs((d2.get('leaped') or 0) - (s0 or 0)) > 5,
              'pos %s -> %s ; s %s -> %s' % ((px, py), p2, s0, d2.get('leaped')))
        leap = wait_dump(live, lambda x: x.get('climb_mode') == 'leap', timeout=6)
        check('闲得慌会横跳(活动范围扩到全屏, 不只是四边)',
              bool(leap and leap.get('climb_mode') == 'leap'),
              repr(leap and leap.get('climb_mode')))
        if leap:
            lp = leap['dog_pos']
            check('横跳确实换了地方(不是原地蹦)',
                  abs(lp[0] - px) + abs(lp[1] - py) > 200, '%s -> %s' % ((px, py), lp))
        _kill(proc)
    finally:
        _kill(proc)
        shutil.rmtree(tmp, ignore_errors=True)

    # (b) 鼠标就贴在它身上 -> 躲(缩起来)
    tmp2 = tempfile.mkdtemp(prefix='wg-pet-s3b-')
    live2, final2 = os.path.join(tmp2, 'live.json'), os.path.join(tmp2, 'final.json')
    try:
        sw = user32.GetSystemMetrics(0)
        sh = user32.GetSystemMetrics(1)
        cx, cy = _critter_start((sw, sh))
        proc = _spawn(tmp2, 3, live2, final2, {'WGIME_PET_FAKE_MOUSE': '%d,%d' % (cx, cy)})
        try:
            d3 = wait_dump(live2, lambda x: x.get('frames', 0) > 20, timeout=15)
            check('鼠标贴脸 -> 立刻反应(要么缩起来要么跑)',
                  bool(d3 and d3.get('climb_mode') in ('hide', 'flee')),
                  repr(d3 and d3.get('climb_mode')))
            d4 = wait_dump(live2, lambda x: x.get('hide', 0) > 0.3
                           or x.get('climb_mode') == 'flee', timeout=5)
            check('躲猫猫真的发生了(贴边缩起来 hide>0.3, 或撒腿就跑)',
                  bool(d4 and (d4.get('hide', 0) > 0.3 or d4.get('climb_mode') == 'flee')),
                  repr(d4 and (d4.get('hide'), d4.get('climb_mode'))))
            check('鼠标真被读到了(用的是打桩坐标, 没动用户的鼠标)',
                  bool(d4 and abs(d4['mouse'][0] - cx) < 3 and abs(d4['mouse'][1] - cy) < 3),
                  repr(d4 and d4.get('mouse')))
        finally:
            _kill(proc)
    finally:
        shutil.rmtree(tmp2, ignore_errors=True)


def main():
    md = part_s()
    part_l(md)
    part_scene1(md)
    part_smear(md)
    part_scene3(md)
    release_dc()
    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
