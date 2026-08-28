# -*- coding: utf-8 -*-
"""tools.py — 纯 tkinter 内置工具窗体, 遵循 docs/WGIME_窗体设计语言.md (浅蓝灰底+白卡片+深色控制台+圆角)."""
import os
import threading
import time
import tkinter as tk
from tkinter import messagebox

import plugins as plugmod
import win as w32
import ui


def _bg(fn):
    threading.Thread(target=fn, daemon=True).start()


def _msgbox(title, text):
    messagebox.showinfo(title, text)


def _confirm(text):
    return messagebox.askyesno('确认', text)


# ---------- 工具箱 (tools.txt tab/按钮 -> 步骤 DSL; 自绘标签页) ----------
def show_toolbox(tools, dict_dir):
    if not tools:
        _msgbox('工具箱', 'tools.txt 无内容')
        return
    win, content = ui.make_window('WgIme 工具箱', 520, 420)
    W, H = 520, 420
    tabbar = tk.Frame(content, bg=ui.BG)
    tabbar.place(x=10, y=8, width=W - 20, height=34)
    body = tk.Frame(content, bg=ui.BG)
    body.place(x=10, y=48, width=W - 20, height=H - 48 - 14)
    pages = []
    tabbtns = []

    def show_tab(i):
        for j, p in enumerate(pages):
            p.place_forget()
        pages[i].place(x=0, y=0, width=W - 20, height=H - 62)
        for j, b in enumerate(tabbtns):
            b.configure(fg=ui.ACCENT if j == i else ui.SUB)

    for i, tab in enumerate(tools):
        tb = ui.flat_button(tabbar, tab['name'], (lambda i=i: show_tab(i)), x=i * 92, y=0, w=84, h=28)
        tabbtns.append(tb)
        page = tk.Frame(body, bg=ui.BG)
        cols = max(1, min(6, tab.get('cols', 2)))
        btns = tab['buttons']
        for bi, b in enumerate(btns):
            bw = (W - 20 - (cols - 1) * 8) // cols
            btn = ui.flat_button(page, b['name'], (lambda s='\n'.join(b['steps']): _run_tool_steps(s)),
                                 x=(bi % cols) * (bw + 8), y=(bi // cols) * 46, w=bw, h=38)
        pages.append(page)
    show_tab(0)


def _run_tool_steps(steps):
    try:
        fails = plugmod.run_steps(steps, lambda m: print('[tool]', m), _msgbox, _confirm)
        if fails:
            _msgbox('工具箱', '部分步骤失败 (%d)' % fails)
    except Exception as ex:
        _msgbox('工具箱', '失败: %s' % ex)


# ---------- 剪贴板历史 ----------
_CLIPT = []


def _clip_poll():
    last = None
    while True:
        time.sleep(1.0)
        try:
            t = w32.clipboard_text()
            if t and t != last:
                last = t
                if not _CLIPT or _CLIPT[0] != t:
                    _CLIPT.insert(0, t)
                    del _CLIPT[30:]
        except Exception:
            pass


def show_clipboard():
    _bg(_clip_poll)
    win, content = ui.make_window('WgIme 剪贴板历史', 420, 400)
    lst = tk.Listbox(content, font=ui.font(9.5), bg=ui.CARD, fg=ui.TEXT, bd=0,
                     highlightthickness=1, highlightbackground=ui.BORDER, selectbackground=ui.ACCENT)
    lst.place(x=10, y=10, width=400, height=320)

    def refresh():
        lst.delete(0, 'end')
        for t in _CLIPT:
            lst.insert('end', t.replace('\r', ' ').replace('\n', ' ')[:60])

    def copy():
        i = lst.curselection()
        if i and 0 <= i[0] < len(_CLIPT):
            win.clipboard_clear()
            win.clipboard_append(_CLIPT[i[0]])

    def paste():
        i = lst.curselection()
        if i and 0 <= i[0] < len(_CLIPT):
            win.clipboard_clear()
            win.clipboard_append(_CLIPT[i[0]])
            _bg(lambda: (time.sleep(0.12), w32.paste_text(_CLIPT[i[0]])))
    ui.flat_button(content, '复制选中', copy, x=10, y=342, w=90, h=30)
    ui.flat_button(content, '粘贴上屏', paste, primary=True, x=110, y=342, w=90, h=30)
    ui.flat_button(content, '刷新', refresh, x=210, y=342, w=70, h=30)
    refresh()


# ---------- 便签 ----------
def show_notes(data_dir):
    win, content = ui.make_window('WgIme 便签', 420, 320)
    path = os.path.join(data_dir, 'notes.txt')
    frame = tk.Frame(content, bg=ui.CARD, highlightthickness=1, highlightbackground=ui.BORDER)
    frame.place(x=10, y=10, width=400, height=270)
    tb = tk.Text(frame, font=ui.font(11), bg=ui.CARD, fg=ui.TEXT, bd=0, highlightthickness=0,
                 padx=8, pady=8, wrap='word')
    tb.pack(fill='both', expand=True)
    try:
        tb.insert('1.0', open(path, encoding='utf-8').read())
    except OSError:
        pass
    win.protocol('WM_DELETE_WINDOW', lambda: (_save(tb, path), win.destroy()))


def _save(tb, path):
    try:
        open(path, 'w', encoding='utf-8').write(tb.get('1.0', 'end'))
    except OSError:
        pass


# ---------- 取色器 ----------
def show_color():
    win, content = ui.make_window('WgIme 取色器', 220, 200)
    prev = tk.Frame(content, bg='#000')
    prev.place(x=10, y=10, width=200, height=120)
    lbl = tk.Label(content, text='', bg=ui.BG, fg=ui.TEXT, font=ui.font(12, bold=True))
    lbl.place(x=10, y=138, width=200, height=24)
    state = {'hex': '#000000'}

    def tick():
        x, y = w32.cursor_pos()
        if win.winfo_x() <= x <= win.winfo_x() + win.winfo_width() and win.winfo_y() <= y <= win.winfo_y() + win.winfo_height():
            return
        r, g, b = w32.get_pixel(x, y)
        state['hex'] = '#%02X%02X%02X' % (r, g, b)
        prev.configure(bg=state['hex'])
        lbl.config(text='%s  (%d,%d)' % (state['hex'], x, y))
        win.after(60, tick)

    def copy(_):
        win.clipboard_clear()
        win.clipboard_append(state['hex'])
        lbl.config(text='已复制 ' + state['hex'])
    prev.bind('<Button-1>', copy)
    lbl.bind('<Button-1>', copy)
    tick()


# ---------- 网络工具 (7 页签: Ping/Tracert/DNS/HTTP/端口/子网/本机) ----------
def show_nettools():
    win, content = ui.make_window('WgIme 网络工具', 640, 420)
    W, H = 640, 420
    out = ui.console_text(content, x=12, y=88, w=W - 24, h=H - 88 - 12)

    def log(s):
        win.after(0, lambda: (out.insert('end', s + '\n'), out.see('end')))

    def run_bg(fn):
        _bg(fn)

    # 页签
    pages = []
    names = ['Ping', 'Tracert', 'DNS', 'HTTP', '端口', '子网', '本机']
    tbs = []

    def show_tab(i):
        for j, p in enumerate(pages):
            pass
        for j, b in enumerate(tbs):
            b.configure(fg=ui.ACCENT if j == i else ui.SUB)
        run_tab(i)

    def run_tab(i):
        out.delete('1.0', 'end')
        run_bg(lambda: _run_page(i))

    chipw = (W - 24) // len(names)
    for i, n in enumerate(names):
        b = ui.flat_button(content, n, (lambda i=i: show_tab(i)), x=12 + i * chipw, y=12, w=chipw - 4, h=28)
        tbs.append(b)
    # host 输入框 (页签下方)
    host = ui.rounded_entry(content, x=12, y=48, w=300, h=30, initial='www.baidu.com')

    def _run_page(i):
        h = host.get().strip()
        try:
            if i == 0:
                _shell('ping -n 4 ' + h)
            elif i == 1:
                _shell('tracert -d ' + h)
            elif i == 2:
                _shell('nslookup ' + h)
            elif i == 3:
                _http(h)
            elif i == 4:
                _ports(h)
            elif i == 5:
                _subnet()
            elif i == 6:
                _local()
        except Exception as ex:
            log('ERR %s' % ex)

    def _shell(cmd):
        log('> ' + cmd)
        p = __import__('subprocess').Popen(cmd, shell=True, stdout=-1, stderr=-1, universal_newlines=True)
        for line in p.stdout:
            log(line.rstrip('\n'))
        p.stdout.close()
        p.wait()
        log('-- done --')

    def _http(h):
        import urllib.request
        url = h if h.startswith('http') else 'https://' + h
        log('> GET ' + url)
        req = urllib.request.Request(url, headers={'User-Agent': 'WgIme-Py-NetTools'})
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                log('HTTP %s  %dms' % (r.status, int((time.time() - t0) * 1000)))
                log('Server: %s' % r.headers.get('Server', '-'))
                log('Content-Type: %s' % r.headers.get('Content-Type', '-'))
        except Exception as ex:
            log('ERR %s' % ex)

    def _ports(h):
        import socket as _s
        log('> 端口探测 %s' % h)
        for port in (80, 443, 22, 21, 25, 3306, 3389, 8080):
            try:
                s = _s.create_connection((h, port), timeout=2)
                s.close()
                log('%d 开放' % port)
            except Exception:
                log('%d 关闭' % port)

    def _subnet():
        import socket as _s
        log('> 子网信息')
        try:
            hn = _s.gethostname()
            log('主机名: %s' % hn)
            for info in _s.getaddrinfo(hn, None, _s.AF_INET):
                log('IP: %s' % info[4][0])
        except Exception as ex:
            log('ERR %s' % ex)

    def _local():
        import socket as _s
        log('> 本机信息')
        log('主机名: %s' % _s.gethostname())
        try:
            log('内网IP: %s' % _s.gethostbyname(_s.gethostname()))
        except Exception:
            pass
        try:
            import urllib.request
            ip = urllib.request.urlopen('https://api.ipify.org', timeout=5).read().decode()
            log('公网IP: %s' % ip)
        except Exception:
            log('公网IP: (获取失败)')

    show_tab(0)


# ---------- 造词对话框 ----------
def show_makeword(data_dir, engine, prefill=''):
    win, content = ui.make_window('WgIme 造词', 380, 200)
    tk.Label(content, text='词语 (2-8 字)', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5)).place(x=14, y=10)
    wentry = ui.rounded_entry(content, x=14, y=30, w=352, h=32, initial=prefill)
    tk.Label(content, text='编码 (留空自动推导)', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5)).place(x=14, y=68)
    centry = ui.rounded_entry(content, x=14, y=88, w=352, h=32)
    status = tk.Label(content, text='', bg=ui.BG, fg=ui.SUB, font=ui.font(8.5))
    status.place(x=14, y=126)

    def autofill(*_a):
        if not centry.get().strip():
            c = engine.code_for(wentry.get().strip())
            if c:
                centry.delete(0, 'end')
                centry.insert(0, c)
    wentry.bind('<KeyRelease>', autofill)
    autofill()

    def do_make():
        w = wentry.get().strip()
        c = centry.get().strip()
        if not (2 <= len(w) <= 8):
            status.config(text='词语需 2-8 字', fg=ui.RED)
            return
        if not c:
            c = engine.code_for(w)
        if not c:
            status.config(text='无法推导编码', fg=ui.RED)
            return
        if engine.add_user_word(w, c):
            status.config(text='已造词: %s (%s)' % (w, c), fg=ui.GREEN)
            win.after(900, win.destroy)
        else:
            status.config(text='已存在: %s' % w, fg=ui.RED)
    ui.flat_button(content, '造词', do_make, primary=True, x=14, y=152, w=100, h=32)
    ui.flat_button(content, '取消', win.destroy, x=120, y=152, w=90, h=32)
    wentry.focus_set()


# ---------- 插件管理 ----------
def show_plugin_mgr(plugins, data_dir, reload_fn):
    win, content = ui.make_window('WgIme 插件管理', 400, 320)
    frame = tk.Frame(content, bg=ui.BG)
    frame.place(x=12, y=10, width=376, height=270)
    vars_ = []
    try:
        disabled = set(l.strip() for l in open(os.path.join(data_dir, 'plugins-disabled.txt'), encoding='utf-8') if l.strip())
    except OSError:
        disabled = set()
    for m in plugins:
        code = getattr(m, 'CODE', '?')
        name = getattr(m, 'NAME', code)
        v = tk.BooleanVar(value=(code not in disabled))
        cb = tk.Checkbutton(frame, text='%s (%s)  %s' % (name, code, getattr(m, 'DESC', '')), variable=v,
                            anchor='w', bg=ui.BG, fg=ui.TEXT, font=ui.font(9.5), activebackground=ui.BG)
        cb.pack(fill='x')
        vars_.append((code, v))

    def apply():
        dis = set(code for code, v in vars_ if not v.get())
        try:
            open(os.path.join(data_dir, 'plugins-disabled.txt'), 'w', encoding='utf-8').write('\n'.join(sorted(dis)))
        except OSError:
            pass
        reload_fn()
        _msgbox('插件管理', '已应用并重载')
    ui.flat_button(content, '应用', apply, primary=True, x=12, y=282, w=90, h=30)


# ---------- 导入码表 (转换常见码表 -> import_py/wb/ec.txt) ----------
def _import_dialog(target, detected):
    """目标(五笔/拼音/英汉) + 格式(自动/词在前/码在前)确认; 返回 (target, fmt) 或 None."""
    import engine as engmod
    win = tk.Toplevel()
    win.title('导入码表')
    win.attributes('-topmost', True)
    win.resizable(False, False)
    win.configure(bg=ui.BG)
    result = {'target': target, 'fmt': 0, 'cancel': False}

    tk.Label(win, text='目标词库', bg=ui.BG, fg=ui.TEXT, font=ui.font(9.5)).grid(
        row=0, column=0, columnspan=3, sticky='w', padx=14, pady=(12, 2))
    tvar = tk.IntVar(value=target)
    for i, n in enumerate(('五笔', '拼音', '英汉')):
        tk.Radiobutton(win, text=n, variable=tvar, value=i, bg=ui.BG, fg=ui.TEXT,
                       selectcolor=ui.BG, activebackground=ui.BG, font=ui.font(9.5)).grid(
            row=1, column=i, padx=10, pady=4)

    tk.Label(win, text='格式', bg=ui.BG, fg=ui.TEXT, font=ui.font(9.5)).grid(
        row=2, column=0, columnspan=3, sticky='w', padx=14, pady=(10, 2))
    fvar = tk.IntVar(value=0)
    for i, (n, v) in enumerate((('自动', 0), ('词在前', 1), ('码在前', 2))):
        tk.Radiobutton(win, text=n, variable=fvar, value=v, bg=ui.BG, fg=ui.TEXT,
                       selectcolor=ui.BG, activebackground=ui.BG, font=ui.font(9.5)).grid(
            row=3, column=i, padx=10, pady=4)

    def ok():
        result['target'] = tvar.get()
        result['fmt'] = fvar.get()
        win.destroy()

    def cancel():
        result['cancel'] = True
        win.destroy()

    btns = tk.Frame(win, bg=ui.BG)
    btns.grid(row=4, column=0, columnspan=3, pady=14)
    tk.Button(btns, text='确定', command=ok, width=8).pack(side='left', padx=6)
    tk.Button(btns, text='取消', command=cancel, width=8).pack(side='left', padx=6)
    win.wait_window()
    if result['cancel']:
        return None
    return result['target'], result['fmt']


def show_import(engine, dict_dir):
    """导入码表: 选文件 -> 检测 -> 确认 -> 转换写 import_*.txt -> 热重载."""
    from tkinter import filedialog
    import engine as engmod

    path = filedialog.askopenfilename(
        title='选择要导入的码表',
        filetypes=[('码表文件', '*.txt *.dict *.yaml *.yml'), ('所有文件', '*.*')])
    if not path:
        return
    text = engmod.read_import_text(path)
    if text is None:
        _msgbox('导入失败', '文件超过 64MB 或无法读取')
        return
    detected = engmod.detect_format(text.split('\n'))
    target = engmod.suggest_target(os.path.basename(path))
    r = _import_dialog(target, detected)
    if r is None:
        return
    target, fmt = r
    if fmt == 0:
        fmt = detected if detected else 2                      # 自动 -> 检测结果(默认码在前)
    import_path = os.path.join(dict_dir, ('import_wb.txt' if target == 0 else ('import_py.txt' if target == 1 else 'import_ec.txt')))
    try:
        acc = engmod.load_import_base(import_path)
        base_words = sum(len(v) for v in acc.values())
        skipped, trunc_codes, trunc_total = engmod.convert_file(text, fmt, acc)
        new_words = sum(len(v) for v in acc.values()) - base_words
        if new_words <= 0:
            _msgbox('导入', '没有新增词条')
            return
        engmod.write_import_file(import_path, acc)
        engine.reload()
        _msgbox('导入完成', '新增 %d 词条 (跳过 %d 行, 截断 %d 码)' % (new_words, skipped, trunc_codes))
    except Exception as ex:
        _msgbox('导入失败', str(ex))
