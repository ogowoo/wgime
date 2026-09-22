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
COLOR_FUR = 0x337ac0          # '#c07a33' -> COLORREF
COLOR_PANEL = 0x261c14        # '#141c26'
COLOR_SLOT = 0x473424         # '#243447'
COLOR_SLOT_H = 0x6f5339       # '#39536f'


def pixel(x, y):
    hdc = user32.GetDC(None)
    try:
        return int(gdi32.GetPixel(hdc, int(x), int(y))) & 0xFFFFFF
    finally:
        user32.ReleaseDC(None, hdc)


def root_of(h):
    h = int(h or 0)
    return (int(user32.GetAncestor(ctypes.c_void_p(h), 2) or 0) or h) if h else 0


def scan_row(x0, x1, y, colors, step=6):
    """在一条水平线上找某个颜色 —— 用来客观证明"东西真的画上去了"。"""
    for x in range(int(x0), int(x1), step):
        if pixel(x, y) in colors:
            return x
    return None


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

        bx0, by0, bx1, by1 = d['dog_bbox']
        found = scan_row(bx0, bx1, int(d['dog_y']) - 45, {COLOR_FUR, 0x5aa0dd}, step=3)
        check('狗**真的画在**屏幕下缘了(在它身上扫到毛色)', found is not None,
              'bbox=%s y=%s' % (d['dog_bbox'], int(d['dog_y']) - 45))

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
                sx = (slots[0][0] + slots[0][2]) // 2
                sy = (slots[0][1] + slots[0][3]) // 2
                check('交互态: 面板处 WindowFromPoint **就是本窗**',
                      root_of(user32.WindowFromPoint(w.POINT(sx, sy))) == root_of(hwnd),
                      'hit=%x own=%x' % (root_of(user32.WindowFromPoint(w.POINT(sx, sy))),
                                         root_of(hwnd)))
            pl = d3.get('panel') or [0, 0, 0, 0]
            py = pl[1] + 12
            drawn = scan_row(pl[0], pl[2], py, {COLOR_PANEL, COLOR_SLOT, COLOR_SLOT_H}, step=4)
            check('交互态: 面板**真的画出来了**(扫到面板底色)', drawn is not None,
                  'panel=%s row_y=%s' % (pl, py))
            check('交互态: 面板外的空白处**仍然穿透**',
                  root_of(user32.WindowFromPoint(w.POINT(1920, 700))) != root_of(hwnd))
            check('开面板期间前台窗口没变', int(user32.GetForegroundWindow() or 0) == fg_before,
                  '%x -> %x' % (fg_before, int(user32.GetForegroundWindow() or 0)))

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
                check('执行期间前台窗口仍没变', int(user32.GetForegroundWindow() or 0) == fg_before,
                      '%x -> %x' % (fg_before, int(user32.GetForegroundWindow() or 0)))

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
            check('全程没抢过焦点(终版复核)', int(user32.GetForegroundWindow() or 0) == fg_before,
                  '%x -> %x' % (fg_before, int(user32.GetForegroundWindow() or 0)))
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


def main():
    md = part_s()
    part_l(md)
    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
