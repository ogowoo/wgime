# -*- coding: utf-8 -*-
"""未定义全局量扫描 (mini-pyflakes, 走 symtable) —— 第四十轮加.

起因: `win.py` 曾把两个全局量写进了上一行的**行尾注释**里:
    _helper_t0=[0.0]; _helper_fail=[0]   # ... ; _ipc_req_hwnd={}; _last_fg=[0]
于是 `_ipc_req_hwnd` / `_last_fg` 从未定义, 而 `request_caret_refresh()` 会 `_ipc_req_hwnd[rid]=hwnd`
(抛 NameError -> 被自己的 except 吞掉 -> **p.kill() 杀掉跟随 helper**), `get_caret_pos()` 第一行就
读 `_last_fg[0]` (NameError 直接抛出去 -> 候选条定位失败)。这类"名字写进注释/拼错/忘记定义"的错误
在运行期只留一行 debug.log, 表现成完全无关的现象, 所以用静态扫描兜住.

原理: symtable 逐作用域取符号; 凡 `is_global()` 且既不是本模块定义的名字、也不是内置名、
也没有 `global x` 声明的, 就是"引用了不存在的全局量".

用法:
    python tests\\undefined-globals.py                 # 扫 wgime-py-pure\\*.py + plugins\\*.py
    python tests\\undefined-globals.py <文件或目录>...  # 扫指定目标
退出码 0 = 干净, 1 = 有未定义全局量 (直接打印 作用域 / 名字).
"""
import builtins
import os
import symtable
import sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # wgime-py-pure
EXTRA_GLOBALS = {           # 运行期由外部注入的模块级名字 (dist 单文件 wrapper / 解释器)
    '__file__', '__name__', '__doc__', '__builtins__', '__spec__', '__loader__', '__package__',
    'MODULES', 'PLUGIN_SRC', 'THIRD_ZIP_B64', '_EMBEDDED_PLUGINS', '_load', '_mk',
}
BUILTINS = set(dir(builtins)) | {'__import__'}


def scan(path):
    src = open(path, encoding='utf-8', errors='replace').read()
    try:
        top = symtable.symtable(src, path, 'exec')
    except SyntaxError as e:
        return [('<syntax>', 'SyntaxError: %s' % e)]
    module_names = {s.get_name() for s in top.get_symbols()}
    findings = []

    def walk(table, scope):
        for s in table.get_symbols():
            n = s.get_name()
            if not s.is_referenced() or not s.is_global():
                continue
            if s.is_local() or s.is_parameter() or s.is_free() or s.is_imported():
                continue
            if n in module_names or n in BUILTINS or n in EXTRA_GLOBALS:
                continue
            findings.append((scope, n))
        for child in table.get_children():
            walk(child, scope + '.' + child.get_name())

    walk(top, os.path.basename(path))
    return findings


def main(argv):
    roots = argv or [BASE]
    targets = []
    for a in roots:
        if os.path.isdir(a):
            for dirpath, dirnames, filenames in os.walk(a):
                dirnames[:] = [d for d in dirnames
                               if d not in ('__pycache__', 'dist', 'package', 'testing', 'tests')]
                targets += [os.path.join(dirpath, fn) for fn in filenames if fn.endswith('.py')]
        else:
            targets.append(a)
    total = 0
    for t in sorted(targets):
        for scope, name in scan(t):
            print('%s: %s -> %s' % (os.path.relpath(t, BASE), scope, name))
            total += 1
    print('scanned %d file(s), undefined-global references: %d' % (len(targets), total))
    print('RESULT: %s' % ('OK' if total == 0 else 'PROBLEM'))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
