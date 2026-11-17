# -*- coding: utf-8 -*-
"""CandBar 绘制事务与透明圆角回归检查。直接运行，不依赖 unittest。"""
from __future__ import annotations

import ast
import os
import sys
import unittest
from unittest import mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
BAR_PATH = HERE.parent / "bar.py"
PASSED = 0
FAILED = 0


def check(name, ok, detail=""):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("  %-70s OK" % name)
    else:
        FAILED += 1
        print("  %-70s FAIL %s" % (name, detail))


def has_desktop():
    if sys.platform != "win32" and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return False
    try:
        import tkinter as tk
        root = tk.Tk()
        root.withdraw()
        root.update_idletasks()
        root.destroy()
        return True
    except Exception:
        return False


def find_method(tree, cls_name, method_name):
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == cls_name:
            for item in node.body:
                if isinstance(item, ast.FunctionDef) and item.name == method_name:
                    return item
    raise AssertionError("%s.%s not found" % (cls_name, method_name))


def call_name(node):
    if not isinstance(node, ast.Call):
        return ""
    cur = node.func
    parts = []
    while isinstance(cur, ast.Attribute):
        parts.append(cur.attr)
        cur = cur.value
    if isinstance(cur, ast.Name):
        parts.append(cur.id)
    return ".".join(reversed(parts))


def static_checks():
    src = BAR_PATH.read_text(encoding="utf-8")
    tree = ast.parse(src, filename=str(BAR_PATH))
    show = find_method(tree, "CandBar", "show")
    show_src = ast.get_source_segment(src, show) or ""
    calls = [(n.lineno, call_name(n), n) for n in ast.walk(show) if isinstance(n, ast.Call)]

    deicons = sorted(line for line, name, _ in calls if name.endswith("top.deiconify"))
    withdraws = sorted(line for line, name, _ in calls if name.endswith("top.withdraw"))
    updates = sorted(line for line, name, _ in calls if name.endswith("top.update_idletasks"))
    deletes = sorted(line for line, name, _ in calls if name.endswith("delete"))
    configs = []
    for line, name, node in calls:
        if name.endswith("canvas.configure") or name == "c.configure":
            keys = {kw.arg for kw in node.keywords if kw.arg}
            if {"width", "height"}.issubset(keys):
                configs.append(line)

    midpoint = show.lineno + (show.end_lineno - show.lineno) // 2
    check("ast 定位 CandBar.show", bool(show))
    check("show 前段没有提前 deiconify",
          len(deicons) == 1 and deicons[0] > midpoint,
          "deiconify lines=%r" % deicons)
    check("可见刷新路径不再调用 top.withdraw", not withdraws,
          "withdraw lines=%r" % withdraws)
    check("canvas.configure(width=w,height=h) 位于 delete('all') 前",
          bool(configs and deletes and min(configs) < min(deletes)),
          "configure=%r delete=%r" % (configs, deletes))
    check("update_idletasks 位于最终 deiconify 前",
          bool(updates and deicons and max(updates) < max(deicons)),
          "update=%r deiconify=%r" % (updates, deicons))

    old_rect = False
    for node in ast.walk(show):
        if not isinstance(node, ast.Call) or not call_name(node).endswith("create_rectangle"):
            continue
        names = {n.id for arg in node.args for n in ast.walk(arg) if isinstance(n, ast.Name)}
        if names & {"old_w", "old_width"}:
            old_rect = True
    check("不存在覆盖旧窗口宽度的 create_rectangle", not old_rect)
    check("_round_rect 仍用于主题背景绘制",
          "self._round_rect(c, 0, 0, w - 1, h - 1" in show_src)


def dynamic_checks():
    if not has_desktop():
        print("  SKIP: 没有可用桌面/Tk，动态几何检查跳过")
        return

    import tkinter as tk
    sys.path.insert(0, str(HERE.parent))
    import bar

    root = tk.Tk()
    root.withdraw()
    obj = None
    try:
        obj = bar.CandBar(root)
        cases = [
            ("短候选", ["一", "二"], 0),
            ("长候选", ["这是一个较长的候选文本", "另一个用于宽度变化的候选文本", "第三项"], 1),
            ("再次缩短", ["短"], 0),
        ]
        for label, cands, sel in cases:
            obj.show("WgIme ", "test", cands, sel, follow=False, fixed=(40, 40))
            root.update_idletasks()
            root.update()
            cw, ch = obj.canvas.winfo_width(), obj.canvas.winfo_height()
            tw, th = obj.top.winfo_width(), obj.top.winfo_height()
            check("%s: Canvas 与 Toplevel 尺寸一致" % label,
                  abs(cw - tw) <= 1 and abs(ch - th) <= 1,
                  "canvas=%sx%s top=%sx%s" % (cw, ch, tw, th))
            bbox = obj.canvas.bbox("all")
            inside = bool(bbox and bbox[0] >= -1 and bbox[1] >= -1 and
                          bbox[2] <= tw + 1 and bbox[3] <= th + 1)
            check("%s: 所有图元 bbox 不越界" % label, inside,
                  "bbox=%r size=%sx%s" % (bbox, tw, th))

        full_rect = False
        for item in obj.canvas.find_all():
            if obj.canvas.type(item) != "rectangle":
                continue
            xy = obj.canvas.coords(item)
            if len(xy) >= 4 and xy[0] <= 0 and xy[1] <= 0 and \
                    xy[2] >= obj.top.winfo_width() - 1 and xy[3] >= obj.top.winfo_height() - 1:
                full_rect = True
                break
        check("四角没有被全窗口实心矩形覆盖", not full_rect,
              "full-size rectangle found")
    finally:
        try:
            if obj is not None:
                obj.top.destroy()
        finally:
            root.destroy()


def main():
    if not BAR_PATH.exists():
        print("FAIL: bar.py not found: %s" % BAR_PATH)
        return 2
    static_checks()
    dynamic_checks()
    if FAILED:
        print("\n失败 %d 项，通过 %d 项" % (FAILED, PASSED))
        return 1
    print("\n全部通过 (%d 项)" % PASSED)
    return 0


class CandBarRenderTests(unittest.TestCase):
    def test_render(self):
        global PASSED, FAILED
        PASSED = FAILED = 0
        with mock.patch("builtins.print"):
            self.assertEqual(main(), 0)


# 直接 `python test_bar_render.py` 也要真跑并返回退出码 —— 原来只有 unittest 入口,
# 直接运行时**一行不跑、rc=0**(一个不会失败的测试等于没写)。
if __name__ == "__main__":
    sys.exit(main())

