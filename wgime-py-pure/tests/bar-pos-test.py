# -*- coding: utf-8 -*-
"""bar-pos-test.py — 候选条位置持久化回归 (pos.txt = "x,y", 对齐 C# LoadPos/SavePos).

第九十五轮起因: 用户报"重启后候选条不用退出前的位置"。实测四个组合(拖动/隐藏/新实例/映射)都对,
但翻代码发现两条真缺陷, 本回归把它们钉死:

  S 段(AST, 不需要桌面): main.quit_app 退出前落盘 / CandBar 有公开 save_pos / _save_pos 有"没显示过就不写"守卫 /
    固定分支按 _user_moved 而不是一次性 _pos_applied 决定用哪个位置
  B 段(真建 Tk 窗口, 不显示): ①没 show 过时 _save_pos 不许把 pos.txt 覆写成 0,0
    ②用户没拖动时, 每次 show 都用 sessaved 位置(哪怕窗口被别的东西挪过)
    ③拖动后(save)才改为跟随实时位置   ④新实例首屏用 pos.txt   ⑤save_pos() 落盘的是实时位置

无 Tk 环境整段 SKIP(仍返 0)。直接跑或 `python -m unittest` 均可用。
"""
import ast
import os
import sys
import tempfile
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
BAR_PY = os.path.join(PURE, 'bar.py')
MAIN_PY = os.path.join(PURE, 'main.py')

CHECKS = []


def check(name, cond, extra=''):
    CHECKS.append((name, bool(cond), extra))
    print('  %s %s%s' % ('OK  ' if cond else 'FAIL', name,
                        ('  ' + str(extra)) if (extra and not cond) else ''))


def _tree(path):
    with open(path, 'rb') as f:
        src = f.read().decode('utf-8')
    return ast.parse(src), src


def _methods(tree, cls_name):
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == cls_name:
            return {n.name: n for n in node.body if isinstance(n, ast.FunctionDef)}
    return {}


def structural():
    print('[S] 结构断言')
    mtree, msrc = _tree(MAIN_PY)
    btree, bsrc = _tree(BAR_PY)

    # S1: quit_app 退出前落盘 (用户的"退出前的位置")
    quit_fn = None
    for node in ast.walk(mtree):
        if isinstance(node, ast.FunctionDef) and node.name == 'quit_app':
            quit_fn = node
    calls = []
    if quit_fn is not None:
        calls = [n.func.attr for n in ast.walk(quit_fn)
                 if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)]
    check('S1 quit_app 调用了 save_pos()', 'save_pos' in calls, calls)

    methods = _methods(btree, 'CandBar')
    check('S2 CandBar 有公开 save_pos 方法', 'save_pos' in methods, sorted(methods)[:8])

    save_src = ast.dump(methods['_save_pos']) if '_save_pos' in methods else ''
    check('S3 _save_pos 有"没显示过就别写"守卫(_shown_once)',
          '_shown_once' in save_src, 'guard missing')

    show_src = ast.dump(methods['show']) if 'show' in methods else ''
    check('S4 show() 固定分支看 _user_moved(不再只靠一次性 _pos_applied)',
          '_user_moved' in show_src, 'user_moved missing')

    drag = ''
    for nm in ('_drag_end', '_drag_move'):
        if nm in methods:
            drag += ast.dump(methods[nm])
    check('S5 拖动时置 _user_moved(松手/移动两处任一)', '_user_moved' in drag, 'drag flag missing')
    _drag_end_src = ast.dump(methods['_drag_end']) if '_drag_end' in methods else ''
    check('S6 拖动结束仍调用 _save_pos()', '_save_pos' in _drag_end_src)
    return bsrc


def behaviour():
    print('[B] 行为断言 (真建窗口, 不显示)')
    try:
        import tkinter as tk
        root = tk.Tk()
        root.withdraw()
    except Exception as exc:            # 无桌面/无 Tk
        print('  SKIP 无 Tk 环境: %s' % exc)
        for nm in ('B1 没 show 过时 _save_pos 不覆写 pos.txt',
                   'B2 未拖动时每次 show 都用会话位置',
                   'B3 拖动后 pos.txt = 实时位置',
                   'B4 新实例首屏用 pos.txt',
                   'B5 save_pos() 落盘实时位置'):
            CHECKS.append((nm, True, 'SKIP'))
        return

    sys.path.insert(0, PURE)
    import bar as barmod
    import win as winmod

    winmod.get_ipc_caret = lambda: None
    winmod.get_caret_pos = lambda: None
    winmod.foreground_process_name = lambda: 'explorer'
    winmod.set_topmost = lambda *_a, **_k: None

    tmp = tempfile.mkdtemp(prefix='wg-barpos-')
    pos_path = os.path.join(tmp, 'pos.txt')

    def write_pos(x, y):
        with open(pos_path, 'w', encoding='utf-8', newline='\n') as f:
            f.write('%d,%d' % (x, y))

    def read_pos():
        try:
            return open(pos_path, encoding='utf-8').read().strip()
        except OSError:
            return ''

    def geom(b):
        s = b.top.geometry()          # e.g. 166x54+600+700
        xy = s.split('+')
        return (int(xy[1]), int(xy[2]))

    def make():
        b = barmod.CandBar(root, tmp)
        b.top.deiconify = lambda: None    # 不真显示, 但 Tk 仍应用 geometry
        return b

    write_pos(600, 700)
    b = make()
    check('B0 新实例读到 pos.txt', b._saved_pos == (600, 700), b._saved_pos)

    # B1: 没显示过就 _save_pos -> 不许写
    b._save_pos()
    check('B1 没 show 过时 _save_pos 不覆写 pos.txt', read_pos() == '600,700', read_pos())

    # B2: 未拖动 -> 每次 show 都回会话位置(窗口被别的东西挪过也一样)
    b.show('h', '', ['甲', '乙'], 0, 0, 1, False, None)
    root.update_idletasks()
    first = geom(b)
    bar_mod = barmod
    b.top.geometry('+1000+1000')
    root.update_idletasks()
    b.show('h', '', ['甲', '乙'], 0, 0, 1, False, None)
    root.update_idletasks()
    second = geom(b)
    check('B2 未拖动时每次 show 都用会话位置', first == (600, 700) and second == (600, 700),
          (first, second))

    # B3: 拖动落盘
    b.top.geometry('+300+320')
    root.update_idletasks()
    b._drag_end(None)
    check('B3 拖动后 pos.txt = 实时位置', read_pos() == '300,320', read_pos())

    # B3b: 拖动后改为跟随实时位置(不再回旧位置)
    b.top.geometry('+520+540')
    root.update_idletasks()
    b.show('h', '', ['甲', '乙'], 0, 0, 1, False, None)
    root.update_idletasks()
    check('B3b 拖动后 show 跟随实时位置', geom(b) == (520, 540) or geom(b)[0] >= 520, geom(b))

    # B4: 新实例首屏用 pos.txt (300,320)
    b2 = make()
    b2.show('h', '', ['甲'], 0, 0, 1, False, None)
    root.update_idletasks()
    check('B4 新实例首屏用 pos.txt', b2._saved_pos == (300, 320) and geom(b2) == (300, 320),
          (b2._saved_pos, geom(b2)))

    # B5: 公开 save_pos 落盘实时位置
    b2.top.geometry('+777+888')
    root.update_idletasks()
    b2.save_pos()
    check('B5 save_pos() 落盘实时位置', read_pos() == '777,888', read_pos())

    root.destroy()
    del bar_mod


def main():
    print('bar-pos-test: %s' % PURE)
    try:
        structural()
    except Exception:
        traceback.print_exc()
        CHECKS.append(('S 段异常', False, 'exception'))
    try:
        behaviour()
    except Exception:
        traceback.print_exc()
        CHECKS.append(('B 段异常', False, 'exception'))
    bad = [c for c in CHECKS if not c[1]]
    print('')
    if bad:
        print('%d 项失败 / 共 %d 项' % (len(bad), len(CHECKS)))
        for nm, _, extra in bad:
            print('  FAIL %s  %s' % (nm, extra))
        return 1
    print('全部通过 (%d 项)' % len(CHECKS))
    return 0


if __name__ == '__main__':
    sys.exit(main())
