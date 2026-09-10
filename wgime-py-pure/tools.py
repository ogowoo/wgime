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


_TOOLS_CACHE = []                                    # 工具数据缓存 (code= 启动编码消费方)
_NOTIFIER = [None]                                   # 托盘气泡回调 (main 启动时注册, 对齐 C# trayRef.ShowBalloonTip)


def set_tools_cache(tabs):
    """main.reload_plugins 在 load_tools 后调用, 缓存工具数据供 code= 启动编码查询."""
    global _TOOLS_CACHE
    _TOOLS_CACHE = tabs


def set_notifier(fn):
    """main 启动时注册托盘气泡函数 (msg 步骤/工具结果用气泡, 对齐 C# ShowBalloonTip)."""
    _NOTIFIER[0] = fn


def _bg(fn):
    threading.Thread(target=fn, daemon=True).start()


def _msgbox(title, text):
    """线程安全弹窗: 后台线程调用经 tk default root marshal 回主线程."""
    try:
        r = getattr(tk, '_default_root', None)
        if r:
            r.after(0, lambda: messagebox.showinfo(title, text))
        else:
            messagebox.showinfo(title, text)
    except Exception:
        pass


def _tip(title, text):
    """气泡提示 (优先托盘气泡, 无托盘退回弹窗) —— 对齐 C# ShowBalloonTip."""
    fn = _NOTIFIER[0]
    if fn is not None:
        try:
            fn(title, text)
            return
        except Exception:
            pass
    _msgbox(title, text)


def _confirm(text):
    """线程安全确认: 主线程 askyesno, 后台线程阻塞等待结果."""
    ev = threading.Event()
    res = [False]
    try:
        r = getattr(tk, '_default_root', None)
        if r:
            def ask():
                try:
                    res[0] = messagebox.askyesno('确认', text)
                except Exception:
                    pass
                ev.set()
            r.after(0, ask)
            ev.wait()
        else:
            return messagebox.askyesno('确认', text)
    except Exception:
        return False
    return res[0]


# ---------- 工具箱 (复刻 C# ToolsForm: 标签/磁贴滚动/日志控制台/防重入/单例) ----------
_toolbox_win = [None]


def _bind_wheel(widget, canvas):
    """给 widget 及其全部子控件绑滚轮 -> canvas 滚动 (tkinter 事件不向父冒泡, 必须逐个绑)."""
    def wheel(e):
        try:
            canvas.yview_scroll(-1 if e.delta > 0 else 1, 'units')
        except Exception:
            pass
        return 'break'

    def walk(w):
        try:
            w.bind('<MouseWheel>', wheel)
        except Exception:
            pass
        for c in w.winfo_children():
            walk(c)

    walk(widget)


def show_toolbox(tools, dict_dir):
    """工具箱: tools.txt 标签页 + 磁贴按钮; 底部深色日志控制台逐步可见."""
    if not tools:
        _tip('工具箱', 'tools.txt 为空或不存在——在 wgime.py 同目录建一个即可添加功能')   # 对齐 C# TrayTip
        return
    if _toolbox_win[0] is not None:                      # 单例: 已开则激活 (对齐 C# ShowTools)
        try:
            if _toolbox_win[0].winfo_exists():
                _toolbox_win[0].deiconify()
                _toolbox_win[0].lift()
                return
        except Exception:
            pass
        _toolbox_win[0] = None
    win, content = ui.make_window('WgIme 工具箱', 560, 470)
    _toolbox_win[0] = win
    W, H = 560, 470
    tabbar = tk.Frame(content, bg=ui.BG)
    tabbar.place(x=10, y=8, width=W - 20, height=34)
    body = tk.Frame(content, bg=ui.BG)
    body.place(x=10, y=46, width=W - 20, height=H - 46 - 118)
    logarea = ui.console_text(content, x=10, y=H - 118, w=W - 20, h=104)   # 底部深色日志
    logarea.configure(state='disabled')

    def log(s):
        win.after(0, lambda: (logarea.configure(state='normal'), logarea.insert('end', s + '\n'),
                              logarea.see('end'), logarea.configure(state='disabled')))

    pages = []
    tabbtns = []
    running = [False]

    def show_tab(i):
        for j, p in enumerate(pages):
            p.place_forget()
        pages[i].place(x=0, y=0, width=W - 20, height=H - 46 - 118)
        pages[i].lift()
        for j, b in enumerate(tabbtns):
            b.configure(fg=ui.ACCENT if j == i else ui.SUB)

    def run_action(btn, name, steps):
        if running[0]:                                   # 防重入 (对齐 C# 点击即禁用)
            return
        running[0] = True
        try:
            btn.configure(bg=ui.SURF2)
        except Exception:
            pass
        log('== %s ==' % name)

        def work():
            def _log(m):
                log(m)

            def _step(shown, delta, slines):
                # C# RunAction: 先输出本步日志(sb), 再打 [ok]/[失败] 行
                if delta:
                    log('  [失败] %s  ->  %s' % (shown, slines[-1] if slines else ''))
                else:
                    log('  [ok] %s' % shown)

            try:
                r = plugmod.run_steps(steps, _log, _tip, _confirm, on_step=_step)
                if getattr(r, 'aborted', False):
                    log('-- 已取消 --')
                else:
                    log('-- %s --' % ('完成' if r == 0 else '完成, %d 个步骤失败' % r))
            except Exception as ex:
                log('-- 失败: %s --' % ex)
            finally:
                running[0] = False
                try:
                    btn.configure(bg=ui.CARD)
                except Exception:
                    pass
        threading.Thread(target=work, daemon=True).start()

    ntabs = len(tools)
    for i, tab in enumerate(tools):
        # 标签宽度自适应 (对齐 C#: min(110, (W-28)/tab数))
        tw = min(110, (W - 20 - 8) // max(1, ntabs))
        tb = ui.flat_button(tabbar, tab['name'], (lambda i=i: show_tab(i)), x=i * tw, y=0, w=tw - 6, h=28)
        tabbtns.append(tb)
        page = tk.Frame(body, bg=ui.BG)
        # 磁贴区用 Canvas + 内层 Frame 实现滚动 (对齐 C# viewport + 滚动条)
        canvas = tk.Canvas(page, bg=ui.BG, bd=0, highlightthickness=0)
        vsb = tk.Scrollbar(page, orient='vertical', command=canvas.yview)
        canvas.configure(yscrollcommand=vsb.set)
        inner = tk.Frame(canvas, bg=ui.BG)
        inner.bind('<Configure>', lambda e, c=canvas: c.configure(scrollregion=c.bbox('all')))
        canvas.create_window((0, 0), window=inner, anchor='nw')
        canvas.place(x=0, y=0, width=W - 20 - 12, height=H - 46 - 118)
        vsb.place(x=W - 20 - 12, y=0, width=12, height=H - 46 - 118)
        cols = max(1, min(6, tab.get('cols', 2)))
        for bi, b in enumerate(tab['buttons']):
            bw = (W - 20 - 12 - (cols - 1) * 10 - 2 * 14) // cols
            holder = []
            # 按钮引用经 holder 传入 (防重入时改色需要真实 widget; 默认参数在创建时拿不到自己)
            holder.append(ui.flat_button(
                inner, b['name'],
                (lambda nm=b['name'], s='\n'.join(b['steps']), hd=holder: run_action(hd[0], nm, s)),
                x=14 + (bi % cols) * (bw + 10), y=14 + (bi // cols) * 56, w=bw, h=46))
        # 滚轮滚动磁贴区 (对齐 C# WheelFilter: 指针在磁贴上也滚得动)
        _bind_wheel(page, canvas)
        pages.append(page)
    show_tab(0)

    def on_close():
        _toolbox_win[0] = None
        win.destroy()

    win.protocol('WM_DELETE_WINDOW', on_close)
    win.bind('<Escape>', lambda e: on_close())


def run_tool_code(code, notify=None):
    """从启动器以 code= 触发 tools.txt 按钮 (对齐 C# RunToolCode: 无窗体, 汇总输出后气泡提示)."""
    global _TOOLS_CACHE
    act = None
    for tab in _TOOLS_CACHE:
        for b in tab.get('buttons', []):
            if b.get('code') == code:
                act = b
                break
        if act is not None:
            break
    if act is None:
        (notify or _tip)('工具', '没有匹配此编码的按钮: %s' % code)
        return False
    lines = []

    def _log(m):
        s = str(m).strip()
        if s:
            lines.append(s)

    try:
        r = plugmod.run_steps('\n'.join(act['steps']), _log, _tip, _confirm)
        aborted = getattr(r, 'aborted', False)
        tail = ('已取消' if aborted else
                '完成' if r == 0 else '完成, %d 个步骤失败' % r)
        body = ' | '.join(lines) if lines else tail
        (notify or _tip)(act.get('name', '工具'), body)
    except Exception as ex:
        (notify or _tip)(act.get('name', '工具'), '失败: %s' % ex)
    return True

# ---------- 剪贴板历史 (复刻 C# ClipForm: 事件去重+移置顶+容量200+清空+单击复制) ----------
_CLIPT = []
_clip_started = [False]
_CLIP_CAP = 200


def _clip_push(t):
    """去重 + 移置顶 + 容量上限 (对齐 C# ClipPush). 返回是否变化."""
    if not t:
        return False
    if _CLIPT and _CLIPT[0] == t:
        return False
    if t in _CLIPT:
        _CLIPT.remove(t)
        _CLIPT.insert(0, t)
        return True
    _CLIPT.insert(0, t)
    del _CLIPT[_CLIP_CAP:]
    return True


def _clip_poll():
    last = None
    while True:                                        # daemon 线程, 进程退出自动停
        time.sleep(0.3)                                # 0.3s 轮询 (tk 无 WM_CLIPBOARDUPDATE 事件钩子; 折中降延迟)
        try:
            t = w32.clipboard_text()
            if t and t != last:
                last = t
                if _clip_push(t) and _clip_win[0] is not None:
                    try:
                        _clip_win[0].after(0, _clip_refresh)
                    except Exception:
                        pass
        except Exception:
            pass


_clip_win = [None]
_clip_refresh = [None]


def show_clipboard():
    if not _clip_started[0]:                            # 守卫: 轮询线程只启动一次(防多开叠加)
        _clip_started[0] = True
        _bg(_clip_poll)
    win, content = ui.make_window('WgIme 剪贴板历史', 520, 380)
    _clip_win[0] = win
    lst = tk.Listbox(content, font=ui.font(10), bg=ui.CARD, fg=ui.TEXT, bd=0,
                     highlightthickness=1, highlightbackground=ui.BORDER, selectbackground=ui.ACCENT,
                     activestyle='none')
    lst.place(x=10, y=48, width=500, height=290)

    def refresh():
        lst.delete(0, 'end')
        for t in _CLIPT:
            lst.insert('end', (t[:80] + '…') if len(t) > 80 else t)

    _clip_refresh[0] = refresh

    def copy_sel():
        i = lst.curselection()
        if i and 0 <= i[0] < len(_CLIPT):
            win.clipboard_clear()
            win.clipboard_append(_CLIPT[i[0]])

    def clear():
        _CLIPT.clear()
        refresh()

    def paste():
        i = lst.curselection()
        if i and 0 <= i[0] < len(_CLIPT):
            win.clipboard_clear()
            win.clipboard_append(_CLIPT[i[0]])
            _bg(lambda: (time.sleep(0.12), w32.paste_text(_CLIPT[i[0]])))

    # 单击/双击条目即复制回剪贴板 (对齐 C# Click/DoubleClick -> CopySel)
    lst.bind('<Button-1>', lambda e: win.after(50, copy_sel))
    lst.bind('<Double-Button-1>', lambda e: copy_sel())

    ui.flat_button(content, '复制选中', copy_sel, x=10, y=348, w=90, h=30)
    ui.flat_button(content, '粘贴上屏', paste, primary=True, x=110, y=348, w=90, h=30)
    ui.flat_button(content, '清空历史', clear, x=210, y=348, w=90, h=30)
    ui.flat_button(content, '刷新', refresh, x=310, y=348, w=70, h=30)
    tk.Label(content, text='点条目=复制回剪贴板; 本窗开着也持续收集', bg=ui.BG, fg=ui.SUB,
             font=ui.font(8.5)).place(x=390, y=352)

    def on_close():
        _clip_win[0] = None
        _clip_refresh[0] = None
        win.destroy()

    win.protocol('WM_DELETE_WINDOW', on_close)
    win.bind('<Escape>', lambda e: on_close())
    refresh()

# ---------- 便签 (复刻 C# NoteForm: 多便签/防抖自动保存/6色主题/窄滚动条/单例) ----------
_NOTE_CN = ['yellow', 'pink', 'purple', 'blue', 'green', 'white']
_NOTE_BODY = ['#FFF4C2', '#FCD9E4', '#E9DCF7', '#D4E9FA', '#D9F2DC', '#FFFFFF']
_NOTE_HEAD = ['#FCE9A8', '#F8C2D4', '#DBC7F1', '#BFDCF7', '#C5EACB', '#F0F0F3']
_NOTE_TEXT = '#3A3A3F'
_NOTE_SUB = '#8A8A90'

_note_win = [None]   # 单例: 已开窗口引用


class _NoteChip(tk.Frame):
    """便签标签 chip: 标题取首行, 活动态主题色填充, 右侧 ✕ 删除区."""

    def __init__(self, parent, title, active, center, body_color, text_color, sub_color,
                 on_click, on_delete_zone):
        super().__init__(parent, bg=body_color, cursor='hand2')
        self.title = title
        self.active = active
        self.center = center
        self.body_color = body_color
        self.text_color = text_color
        self.sub_color = sub_color
        self.on_click = on_click
        self.on_delete_zone = on_delete_zone
        # 标题 label
        txt = self.text_color if active else self.sub_color
        self.lbl = tk.Label(self, text=title, bg=body_color if active else parent.cget('bg'),
                            fg=txt, font=ui.font(8.5), anchor='w' if not center else 'center')
        self.lbl.pack(fill='both', expand=True, padx=(8, 22 if active else 14) if not center else 0)
        if active:
            # ✕ 删除区
            self.x = tk.Label(self, text='✕', bg=body_color, fg=sub_color, font=ui.font(8.5), cursor='hand2')
            self.x.place(relx=1.0, x=-20, rely=0, relwidth=0, width=20, relheight=1.0)
            self.x.bind('<Button-1>', lambda e: on_delete_zone())
        for w in (self, self.lbl):
            w.bind('<Button-1>', lambda e: on_click())
        self._paint_active()

    def _paint_active(self):
        bg = self.body_color if self.active else self.master.cget('bg')
        self.configure(bg=bg)
        self.lbl.configure(bg=bg, fg=self.text_color if self.active else self.sub_color)


def show_notes(data_dir):
    """便签窗体 (复刻 C# NoteForm)."""
    if _note_win[0] is not None:
        try:
            if _note_win[0].winfo_exists():
                _note_win[0].deiconify()
                _note_win[0].lift()
                return
        except Exception:
            pass
        _note_win[0] = None

    win = tk.Toplevel()
    win.overrideredirect(True)
    win.attributes('-topmost', True)
    win.geometry('430x330')
    ui.center(win, 430, 330)

    notes_dir = os.path.join(data_dir, 'notes')
    meta_path = os.path.join(data_dir, 'notes-meta.txt')
    color_path = os.path.join(data_dir, 'note-color.txt')
    legacy = os.path.join(data_dir, 'notes.txt')

    state = {'files': [], 'cur': 0, 'ci': 0, 'chips': [], 'save_id': None}

    # ---- 主题色 ----
    saved_color = 'yellow'
    try:
        if os.path.exists(color_path):
            saved_color = open(color_path, encoding='utf-8').read().strip() or 'yellow'
    except OSError:
        pass
    if saved_color in _NOTE_CN:
        state['ci'] = _NOTE_CN.index(saved_color)

    body = tk.Frame(win, bg=_NOTE_BODY[state['ci']])
    body.place(x=0, y=72, width=430, height=330 - 72)
    strip = tk.Frame(win, bg=_NOTE_HEAD[state['ci']], height=34)
    strip.place(x=0, y=38, width=430, height=34)
    header = tk.Frame(win, bg=_NOTE_HEAD[state['ci']], height=38)
    header.place(x=0, y=0, width=430, height=38)

    cap = tk.Label(header, text='便签', bg=_NOTE_HEAD[state['ci']], fg=_NOTE_TEXT, font=ui.font(10, bold=True))
    cap.place(x=14, y=9)
    status = tk.Label(header, text='', bg=_NOTE_HEAD[state['ci']], fg=_NOTE_SUB, font=ui.font(8))
    status.place(x=56, y=12)
    close = tk.Label(header, text='✕', bg=_NOTE_HEAD[state['ci']], fg=_NOTE_TEXT, font=ui.font(10), cursor='hand2')
    close.place(x=392, y=6, width=30, height=26)
    close.bind('<Enter>', lambda e: close.configure(bg='#E81123', fg='white'))
    close.bind('<Leave>', lambda e: close.configure(bg=_NOTE_HEAD[state['ci']], fg=_NOTE_TEXT))
    close.bind('<Button-1>', lambda e: win.destroy())

    # 主题色点
    dots = []

    def apply_theme(i):
        state['ci'] = i
        try:
            open(color_path, 'w', encoding='utf-8').write(_NOTE_CN[i])
        except OSError:
            pass
        body.configure(bg=_NOTE_BODY[i])
        strip.configure(bg=_NOTE_HEAD[i])
        header.configure(bg=_NOTE_HEAD[i])
        cap.configure(bg=_NOTE_HEAD[i]); status.configure(bg=_NOTE_HEAD[i]); close.configure(bg=_NOTE_HEAD[i])
        box.configure(bg=_NOTE_BODY[i])
        for k, d in enumerate(dots):
            d.configure(highlightthickness=2 if k == i else 0, highlightbackground=_NOTE_TEXT)
        rebuild_tabs()

    for i in range(6):
        d = tk.Frame(header, bg=_NOTE_BODY[i], cursor='hand2', highlightthickness=2 if i == state['ci'] else 0,
                     highlightbackground=_NOTE_TEXT, bd=0)
        d.place(x=246 + i * 23, y=11, width=15, height=15)
        d.bind('<Button-1>', lambda e, i=i: apply_theme(i))
        dots.append(d)

    # 拖动 (header)
    def _drag_start(e):
        win._dx, win._dy = e.x_root - win.winfo_x(), e.y_root - win.winfo_y()
    def _drag_move(e):
        win.geometry('+%d+%d' % (e.x_root - win._dx, e.y_root - win._dy))
    for w in (header, cap, status):
        w.bind('<Button-1>', _drag_start)
        w.bind('<B1-Motion>', _drag_move)

    # 正文 + 窄滚动条
    box = tk.Text(body, bg=_NOTE_BODY[state['ci']], fg=_NOTE_TEXT, bd=0, highlightthickness=0,
                  wrap='word', font=ui.font(11))
    box.place(x=16, y=8, width=430 - 16 - 14, height=330 - 72 - 20)
    sb = tk.Scrollbar(body, command=box.yview, width=10)
    sb.place(x=430 - 18, y=8, width=10, height=330 - 72 - 20)
    box.configure(yscrollcommand=sb.set)

    # ---- 存储 ----
    def load_notes():
        state['files'] = []
        try:
            os.makedirs(notes_dir, exist_ok=True)
            # 旧单文件迁移
            if os.path.exists(legacy) and not any(f.endswith('.txt') for f in os.listdir(notes_dir)):
                try:
                    with open(legacy, encoding='utf-8') as f:
                        open(os.path.join(notes_dir, '1.txt'), 'w', encoding='utf-8').write(f.read())
                    os.remove(legacy)
                except OSError:
                    pass
            nums = {}
            for f in os.listdir(notes_dir):
                if f.endswith('.txt'):
                    try:
                        nums[int(os.path.splitext(f)[0])] = os.path.join(notes_dir, f)
                    except ValueError:
                        pass
            state['files'] = [nums[k] for k in sorted(nums)]
            if not state['files']:
                p = os.path.join(notes_dir, '1.txt')
                open(p, 'w', encoding='utf-8').close()
                state['files'] = [p]
            state['cur'] = 0
            try:
                a = int(open(meta_path, encoding='utf-8').read().strip())
                if 1 <= a <= len(state['files']):
                    state['cur'] = a - 1
            except (OSError, ValueError):
                pass
        except OSError:
            if not state['files']:
                state['files'] = [None]
            state['cur'] = 0

    def save_meta():
        try:
            open(meta_path, 'w', encoding='utf-8').write(str(state['cur'] + 1))
        except OSError:
            pass

    def load_cur():
        try:
            p = state['files'][state['cur']] if 0 <= state['cur'] < len(state['files']) else None
            txt = open(p, encoding='utf-8').read() if p and os.path.exists(p) else ''
        except OSError:
            txt = ''
        box.delete('1.0', 'end')
        box.insert('1.0', txt)
        box.see('end')

    def title_of(path, idx):
        try:
            if path and os.path.exists(path):
                with open(path, encoding='utf-8') as f:
                    for ln in f:
                        ln = ln.strip()
                        if ln:
                            return ln
        except OSError:
            pass
        return '便签 %d' % (idx + 1)

    def save_now():
        try:
            p = state['files'][state['cur']] if 0 <= state['cur'] < len(state['files']) else None
            if p:
                txt = box.get('1.0', 'end')
                if txt.endswith('\n'):
                    txt = txt[:-1]  # tk.Text 隐含尾部换行
                open(p, 'w', encoding='utf-8').write(txt)
                status.configure(text='已保存 ' + time.strftime('%H:%M:%S'))
                if state['cur'] < len(state['chips']):
                    state['chips'][state['cur']].title = title_of(p, state['cur'])
                    state['chips'][state['cur']].lbl.configure(text=title_of(p, state['cur']))
        except OSError as ex:
            status.configure(text='Err: %s' % ex)

    def schedule_save(*_):
        if state['save_id']:
            win.after_cancel(state['save_id'])
        state['save_id'] = win.after(800, save_now)

    box.bind('<KeyRelease>', schedule_save)

    def rebuild_tabs():
        for c in strip.winfo_children():
            c.destroy()
        state['chips'] = []
        n = len(state['files'])
        w = min(96, max(56, (430 - 20 - 36) // max(1, n)))
        x = 10
        for i in range(n):
            active = (i == state['cur'])
            chip = _NoteChip(strip, title_of(state['files'][i], i), active, False,
                             _NOTE_BODY[state['ci']] if active else _NOTE_HEAD[state['ci']],
                             _NOTE_TEXT, _NOTE_SUB,
                             on_click=(lambda i=i: switch_to(i)),
                             on_delete_zone=(lambda i=i: delete_note(i)))
            chip.place(x=x, y=4, width=w, height=26)
            state['chips'].append(chip)
            x += w + 4
        if n < 9:
            plus = tk.Label(strip, text='+', bg=_NOTE_HEAD[state['ci']], fg=_NOTE_TEXT,
                            font=ui.font(10, bold=True), cursor='hand2')
            plus.place(x=x, y=4, width=30, height=26)
            plus.bind('<Button-1>', lambda e: add_note())

    def switch_to(i):
        if i < 0 or i >= len(state['files']) or i == state['cur']:
            return
        if state['save_id']:
            win.after_cancel(state['save_id'])
            state['save_id'] = None
        save_now()
        state['cur'] = i
        save_meta()
        load_cur()
        rebuild_tabs()

    def add_note():
        if len(state['files']) >= 9:
            return
        if state['save_id']:
            win.after_cancel(state['save_id']); state['save_id'] = None
        save_now()
        p = os.path.join(notes_dir, '%d.txt' % (len(state['files']) + 1))
        try:
            open(p, 'w', encoding='utf-8').close()
        except OSError:
            pass
        state['files'].append(p)
        state['cur'] = len(state['files']) - 1
        save_meta()
        load_cur()
        rebuild_tabs()

    def delete_note(i):
        if i < 0 or i >= len(state['files']):
            return
        if len(state['files']) <= 1:
            box.delete('1.0', 'end')
            if state['save_id']:
                win.after_cancel(state['save_id']); state['save_id'] = None
            save_now()
            return
        try:
            if state['files'][i] and os.path.exists(state['files'][i]):
                os.remove(state['files'][i])
        except OSError:
            pass
        state['files'].pop(i)
        # 稠密重编号 1..n
        try:
            tmp = []
            for k, f in enumerate(state['files']):
                if f is None:
                    tmp.append(None)
                    continue
                t = os.path.join(notes_dir, 'tmp_%d.txt' % k)
                os.rename(f, t)
                tmp.append(t)
            for k, f in enumerate(tmp):
                if f is None:
                    continue
                fin = os.path.join(notes_dir, '%d.txt' % (k + 1))
                os.rename(f, fin)
                state['files'][k] = fin
        except OSError:
            pass
        if state['cur'] >= len(state['files']):
            state['cur'] = len(state['files']) - 1
        elif i < state['cur']:
            state['cur'] -= 1
        save_meta()
        load_cur()
        rebuild_tabs()

    def on_close():
        if state['save_id']:
            win.after_cancel(state['save_id'])
        save_now()
        _note_win[0] = None
        win.destroy()

    win.protocol('WM_DELETE_WINDOW', on_close)
    win.bind('<Escape>', lambda e: on_close())
    close.bind('<Button-1>', lambda e: on_close())

    load_notes()
    load_cur()
    rebuild_tabs()
    _note_win[0] = win
    return win

# ---------- 取色器 (复刻 C# ColorForm: 钩子点取+锁定+吞点击+右键取消; 三格式 HEX/rgb/HSV) ----------
import ctypes
from ctypes import wintypes as _w

_WH_MOUSE_LL = 14
_WM_LBUTTONDOWN = 0x0201
_WM_RBUTTONDOWN = 0x0204
_MOUSEPROC = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
_col_user32 = ctypes.windll.user32
_col_kernel32 = ctypes.windll.kernel32


class _ColPT(ctypes.Structure):
    _fields_ = [('x', _w.LONG), ('y', _w.LONG)]


class _ColMSLL(ctypes.Structure):
    _fields_ = [('pt', _ColPT), ('mouseData', _w.DWORD), ('flags', _w.DWORD), ('time', _w.DWORD), ('extra', ctypes.c_void_p)]


def _rgb_to_hsv(r, g, b):
    """RGB -> HSV 文本 (对齐 C# ColorHsv: 'H 210  S 78%  V 100%')."""
    rf, gf, bf = r / 255.0, g / 255.0, b / 255.0
    mx, mn = max(rf, gf, bf), min(rf, gf, bf)
    d = mx - mn
    h = 0.0
    if d > 0:
        if mx == rf:
            h = 60 * (((gf - bf) / d) % 6)
        elif mx == gf:
            h = 60 * ((bf - rf) / d + 2)
        else:
            h = 60 * ((rf - gf) / d + 4)
    if h < 0:
        h += 360
    sv = 0 if mx == 0 else d / mx
    return 'H %d  S %d%%  V %d%%' % (round(h), round(sv * 100), round(mx * 100))


def show_color():
    """取色器窗体 (复刻 C# ColorForm)."""
    win, content = ui.make_window('WgIme 取色器', 320, 210)
    swatch = tk.Frame(content, bg='#FFFFFF', highlightthickness=1, highlightbackground=ui.BORDER)
    swatch.place(x=14, y=14, width=290, height=90)
    lbl = tk.Label(content, text='—', bg=ui.BG, fg=ui.TEXT, font=ui.font(10.5, mono=True),
                   justify='left', anchor='w')
    lbl.place(x=14, y=116, width=290, height=44)

    state = {'rgb': None, 'hook': [None], 'proc': [None]}

    def pick_at(x, y):
        px = w32.get_pixel(x, y)
        if px is None:
            return
        r, g, b = px
        state['rgb'] = (r, g, b)
        swatch.configure(bg='#%02X%02X%02X' % (r, g, b))
        lbl.configure(text='#%02X%02X%02X   rgb(%d,%d,%d)\n%s' % (r, g, b, r, g, b, _rgb_to_hsv(r, g, b)))

    def stop_pick():
        h = state['hook'][0]
        if h:
            try:
                _col_user32.UnhookWindowsHookEx(h)
            except Exception:
                pass
            state['hook'][0] = None

    def start_pick():
        if state['hook'][0]:
            return
        lbl.configure(text='点击屏幕任意处取色, 右键取消')
        def hook_thread():
            def proc(nCode, wParam, lParam):
                if nCode >= 0:
                    wm = wParam
                    if wm == _WM_LBUTTONDOWN:
                        st = ctypes.cast(lParam, ctypes.POINTER(_ColMSLL)).contents
                        win.after(0, lambda: pick_at(st.pt.x, st.pt.y))
                        stop_pick()
                        return 1                      # 吞掉这次点击 (对齐 C# return 1)
                    if wm == _WM_RBUTTONDOWN:
                        win.after(0, stop_pick)
                        return 1
                return _col_user32.CallNextHookEx(state['hook'][0], nCode, wParam, lParam)
            cb = _MOUSEPROC(proc)
            state['proc'][0] = cb                      # 保持回调引用防 GC (对齐 C#)
            h = _col_user32.SetWindowsHookExW(_WH_MOUSE_LL, cb, _col_kernel32.GetModuleHandleW(None), 0)
            state['hook'][0] = h
            msg = _w.MSG()
            while state['hook'][0]:
                if _col_user32.GetMessageW(ctypes.byref(msg), None, 0, 0) <= 0:
                    break
                _col_user32.TranslateMessage(ctypes.byref(msg))
                _col_user32.DispatchMessageW(ctypes.byref(msg))
        threading.Thread(target=hook_thread, daemon=True).start()

    def copy_hex():
        if state['rgb']:
            r, g, b = state['rgb']
            win.clipboard_clear()
            win.clipboard_append('#%02X%02X%02X' % (r, g, b))

    ui.flat_button(content, '拾取 (点屏幕)', start_pick, x=14, y=168, w=150, h=30)
    ui.flat_button(content, '复制 HEX', copy_hex, primary=True, x=172, y=168, w=132, h=30)

    def on_close():
        stop_pick()
        win.destroy()

    win.protocol('WM_DELETE_WINDOW', on_close)
    win.bind('<Escape>', lambda e: on_close())

import ipaddress
import socket
import struct
import subprocess
import time
import urllib.request
from tkinter import filedialog

# ===================== 探测纯函数 (对齐 C# statics) =====================

def ping_rtt(host, size, timeout_ms):
    """单发 ping -> (ok, rtt_ms). 用系统 ping 子进程自持 Popen 以便停止 (对齐 C# PingRtt)."""
    if size < 1:
        size = 1
    if size > 65500:
        size = 65500
    timeout_s = max(1, timeout_ms // 1000)
    try:
        # ping -n 1 -l <size> -w <ms> host
        p = subprocess.Popen(['ping', '-n', '1', '-l', str(size), '-w', str(timeout_ms), host],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             encoding='mbcs', errors='replace')
        out, _ = p.communicate(timeout=timeout_s + 3)
        # 从输出解析 time=XXms (中英文系统: time= / 时间=)
        for ln in out.splitlines():
            ln_low = ln.lower()
            if 'time=' in ln_low or 'time<' in ln_low:
                m = None
                for tok in ln.replace('<', '=').replace('ms', '').split():
                    if tok.startswith('time='):
                        try:
                            m = int(tok.split('=')[1])
                        except ValueError:
                            pass
                if m is None and '=' in ln_low:
                    try:
                        m = int(ln_low.split('time=')[1].split('ms')[0].strip())
                    except Exception:
                        pass
                if m is not None:
                    return True, m
            if 'ttl=' in ln_low and ('bytes=' in ln_low or '字节' in ln):
                return True, 0
        return p.returncode == 0, -1
    except Exception:
        return False, -1


def ping_once(host, timeout_ms):
    """一发 ICMP echo 结果行 (对齐 C# PingOnce)."""
    ok, rtt = ping_rtt(host, 32, timeout_ms)
    if ok and rtt >= 0:
        return 'reply from %s: time=%dms' % (host, rtt)
    return 'status: %s' % ('timeout' if not ok else 'unknown')


def hop_once(host, ttl, timeout_ms):
    """一跳 traceroute (对齐 C# HopOnce) -> (line, done)."""
    # Windows tracert 不支持单跳; 用 ping -i <ttl> -n 1 实现 TTL 递增
    timeout_s = max(1, timeout_ms // 1000)
    try:
        p = subprocess.Popen(['ping', '-i', str(ttl), '-n', '1', '-w', str(timeout_ms), host],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             encoding='mbcs', errors='replace')
        out, _ = p.communicate(timeout=timeout_s + 3)
        for ln in out.splitlines():
            low = ln.lower()
            if 'reply from' in low or ('time=' in low and 'ttl=' in low):
                return '%d  %s  (done)' % (ttl, host), True
            if 'ttl expired' in low or 'ttl 过期' in ln:
                # 提取中转地址
                parts = ln.split()
                addr = parts[-1] if parts else '?'
                return '%d  %s' % (ttl, addr), False
        return '%d  timeout' % ttl, False
    except Exception as ex:
        return '%d  error: %s' % (ttl, ex), False


def test_port(host, port, timeout_ms):
    """TCP connect 探测 (对齐 C# TestPort) -> 'open  Xms' / 'closed (...)'."""
    t0 = time.time()
    try:
        s = socket.create_connection((host, port), timeout=timeout_ms / 1000.0)
        s.close()
        return 'open  %dms' % int((time.time() - t0) * 1000)
    except socket.timeout:
        return 'closed (timeout %dms)' % timeout_ms
    except Exception as ex:
        return 'closed (%s)' % type(ex).__name__


def public_ip(timeout_ms):
    """公网 IP (对齐 C# PublicIp, ipify)."""
    try:
        req = urllib.request.Request('https://api.ipify.org', headers={'User-Agent': 'WgIme-Py-NetTools'})
        with urllib.request.urlopen(req, timeout=timeout_ms / 1000.0) as r:
            return r.read().decode('utf-8', 'replace').strip()
    except Exception:
        return None


# ---- DNS 手写协议 (对齐 C# DnsQuery, UDP/53) ----
_DNS_TYPES = {'A': 1, 'NS': 2, 'CNAME': 5, 'PTR': 12, 'MX': 15, 'TXT': 16, 'AAAA': 28}


def _dns_be16(v):
    return struct.pack('>H', v)


def _dns_read_name(msg, pos):
    """读域名(支持压缩指针), 返回 (name, new_pos). 防环."""
    labels = []
    jumped = False
    p = pos
    guard = 0
    while True:
        if guard > 128:
            raise ValueError('dns name loop')
        ln = msg[p]
        if ln == 0:
            if not jumped:
                pos = p + 1
            break
        if (ln & 0xC0) == 0xC0:
            ptr = ((ln & 0x3F) << 8) | msg[p + 1]
            if not jumped:
                pos = p + 2
            p = ptr
            jumped = True
            continue
        labels.append(msg[p + 1:p + 1 + ln].decode('ascii', 'replace'))
        p += 1 + ln
        if not jumped:
            pos = p
        guard += 1
    return '.'.join(labels), pos


def dns_query(name, qtype, server, timeout_ms):
    """原始 DNS 查询 -> [行...] (对齐 C# DnsQuery)."""
    qt = _DNS_TYPES.get(qtype.upper())
    if qt is None:
        raise ValueError('bad type')
    import random
    rid = random.randint(0, 65535)
    pkt = _dns_be16(rid) + _dns_be16(0x0100) + _dns_be16(1) + _dns_be16(0) + _dns_be16(0) + _dns_be16(0)
    for label in name.strip().rstrip('.').split('.'):
        lb = label.encode('ascii', 'replace')
        pkt += bytes([len(lb)]) + lb
    pkt += b'\x00' + _dns_be16(qt) + _dns_be16(1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout_ms / 1000.0)
    try:
        sock.sendto(pkt, (server, 53))
        resp, _ = sock.recvfrom(4096)
    finally:
        sock.close()
    rcode = resp[3] & 15
    if rcode != 0:
        return ['DNS rcode=%d%s' % (rcode, ' (NXDOMAIN)' if rcode == 3 else '')]
    qd = struct.unpack('>H', resp[4:6])[0]
    an = struct.unpack('>H', resp[6:8])[0]
    pos = 12
    for _ in range(qd):
        _, pos = _dns_read_name(resp, pos)
        pos += 4
    lines = []
    for _ in range(an):
        owner, pos = _dns_read_name(resp, pos)
        rtype = struct.unpack('>H', resp[pos:pos + 2])[0]
        ttl = struct.unpack('>I', resp[pos + 4:pos + 8])[0]
        rdlen = struct.unpack('>H', resp[pos + 8:pos + 10])[0]
        rstart = pos + 10
        if rtype == 1:
            val = '.'.join(str(b) for b in resp[rstart:rstart + 4])
        elif rtype == 28:
            val = socket.inet_ntop(socket.AF_INET6, resp[rstart:rstart + 16])
        elif rtype in (2, 5, 12):
            val, _ = _dns_read_name(resp, rstart)
        elif rtype == 15:
            pref = struct.unpack('>H', resp[rstart:rstart + 2])[0]
            mx, _ = _dns_read_name(resp, rstart + 2)
            val = '%d %s' % (pref, mx)
        elif rtype == 16:
            p2, end = rstart, rstart + rdlen
            parts = []
            while p2 < end:
                ln = resp[p2]
                parts.append(resp[p2 + 1:p2 + 1 + ln].decode('utf-8', 'replace'))
                p2 += 1 + ln
            val = ' | '.join(parts)
        else:
            val = 'type %d (%d bytes)' % (rtype, rdlen)
        tn = {1: 'A', 28: 'AAAA', 2: 'NS', 5: 'CNAME', 12: 'PTR', 15: 'MX', 16: 'TXT'}.get(rtype, str(rtype))
        lines.append('%s   ttl=%d   %s   %s' % (owner, ttl, tn, val))
        pos = rstart + rdlen
    if not lines:
        lines.append('无记录')
    return lines


def http_check(url, timeout_ms):
    """HTTP 探测 (对齐 C# HttpCheck) -> [行...]."""
    if '://' not in url:
        url = 'https://' + url
    t0 = time.time()
    lines = []
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'WgIme-Py-NetTools'})
        with urllib.request.urlopen(req, timeout=timeout_ms / 1000.0) as r:
            ttfb = int((time.time() - t0) * 1000)
            final = r.geturl()
            redir = '  (-> %s)' % urllib.request.urlparse(final).hostname if final != url else ''
            lines.append('HTTP %d %s%s' % (r.status, getattr(r, 'reason', ''), redir))
            if r.headers.get('Server'):
                lines.append('Server: %s' % r.headers['Server'])
            if r.headers.get('Content-Type'):
                lines.append('Content-Type: %s' % r.headers['Content-Type'])
            body = r.read()
            lines.append('Body: %d bytes' % len(body))
            lines.append('TTFB: %dms   Total: %dms' % (ttfb, int((time.time() - t0) * 1000)))
    except urllib.error.HTTPError as he:
        lines.append('HTTP %d %s' % (he.code, he.reason))
    except Exception as ex:
        lines.append('Err: %s' % ex)
    return lines


# ---- 子网计算 (用标准库 ipaddress, 对齐 C# SubnetCalc/SubnetSplit/RangeToCidr/MaskTable) ----

def _ip_type(ip):
    """地址类型描述 (对齐 C# IpType)."""
    a = ip.packed[0]
    b = ip.packed[1]
    if int(ip) == 0:
        return '未指定地址'
    if a == 127:
        return '回环地址 (loopback)'
    if a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168):
        return '私有地址 (RFC1918)'
    if a == 169 and b == 254:
        return '链路本地 (APIPA)'
    if a == 100 and 64 <= b <= 127:
        return '运营商级 NAT (CGNAT)'
    if 224 <= a <= 239:
        return '组播 (multicast)'
    if a >= 240:
        return '保留 (reserved)'
    return '公网地址'


def _ip_class(ip):
    a = ip.packed[0]
    if a < 128:
        return 'A'
    if a < 192:
        return 'B'
    if a < 224:
        return 'C'
    if a < 240:
        return 'D'
    return 'E'


def subnet_calc(ip_text, mask_text):
    """子网计算 -> [行...] (对齐 C# SubnetCalc). 掩码接受 24 / /24 / 255.255.255.0."""
    net = _parse_net(ip_text, mask_text)
    bits = net.prefixlen
    mask = int(net.netmask)
    mb = bin(mask)[2:].zfill(32)
    mb = '.'.join(mb[i:i + 8] for i in range(0, 32, 8))
    return [
        '掩码:        %s  (/%d)' % (net.netmask, bits),
        '通配符:    %s' % net.hostmask,
        '网络地址:   %s' % net.network_address,
        '广播地址: %s' % net.broadcast_address,
        '可用范围:  %s - %s' % (net.network_address + (0 if bits >= 31 else 1),
                                net.broadcast_address - (0 if bits >= 31 else 1)),
        '可用主机数:     %d' % (net.num_addresses if bits == 32 else (2 if bits == 31 else net.num_addresses - 2)),
        '地址类型:      %s  (类别 %s)' % (_ip_type(net.network_address), _ip_class(net.network_address)),
        '二进制:      %s' % mb,
    ]


def _parse_net(ip_text, mask_text):
    """解析 IP + 掩码(24//24/255.255.255.0) -> ip_network. 对齐 C# ParseIpMask 非连续掩码报错."""
    ip = ipaddress.IPv4Address(ip_text.strip())
    mt = mask_text.strip().lstrip('/')
    if '.' in mt:
        m = ipaddress.IPv4Address(mt)
        bits = bin(int(m)).count('1')
        # 非连续掩码校验 (对齐 C# MaskToBits)
        s = bin(int(m))[2:].zfill(32)
        if '01' in s:
            raise ValueError('掩码不连续')
        net = ipaddress.IPv4Network('%s/%d' % (ip, bits), strict=False)
    else:
        bits = int(mt)
        if bits < 0 or bits > 32:
            raise ValueError('bad prefix')
        net = ipaddress.IPv4Network('%s/%d' % (ip, bits), strict=False)
    return net


def subnet_split(ip_text, mask_text, count):
    """拆分子网 (对齐 C# SubnetSplit) -> [行...]."""
    net = _parse_net(ip_text, mask_text)
    if count < 2:
        count = 2
    extra = 0
    while (1 << extra) < count:
        extra += 1
    nb = net.prefixlen + extra
    if nb > 30:
        raise ValueError('拆得太碎了 (主机数不足)')
    subs = list(net.subnets(prefixlen_diff=extra))
    lines = ['拆分 %s/%d 为 %d 个 /%d:' % (net.network_address, net.prefixlen, len(subs), nb)]
    for sn in subs:
        hosts = sn.num_addresses - 2
        lines.append('  %s/%d   %s - %s   (%d)' % (sn.network_address, nb, sn.network_address + 1, sn.broadcast_address - 1, hosts))
    return lines


def range_to_cidr(a, b):
    """范围转最小 CIDR 集 (对齐 C# RangeToCidr, 用 ipaddress.summarize_address_range)."""
    lo = ipaddress.IPv4Address(a.strip())
    hi = ipaddress.IPv4Address(b.strip())
    if hi < lo:
        lo, hi = hi, lo
    return [str(c) for c in ipaddress.summarize_address_range(lo, hi)]


def mask_table():
    """常用前缀速查表 (对齐 C# MaskTable)."""
    lines = ['前缀    掩码              可用主机     通配符']
    for b in (8, 16, 20, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32):
        net = ipaddress.IPv4Network('0.0.0.0/%d' % b)
        hosts = 1 if b == 32 else (2 if b == 31 else net.num_addresses - 2)
        lines.append('/%-7d%-16s%-13d%s' % (b, net.netmask, hosts, net.hostmask))
    return lines


def local_net_info():
    """本机网络信息 (对齐 C# LocalNetInfo): 主机名 + 网卡枚举(经 ipconfig /all) + 公网 IP."""
    import re as _re
    sb = ['主机名: %s' % socket.gethostname()]
    try:
        out = subprocess.run(['ipconfig', '/all'], capture_output=True, text=True,
                             encoding='mbcs', errors='replace', timeout=8).stdout
        # 解析每个适配器: 名称/IPv4/掩码/网关/DNS
        cur = None
        data = []
        for ln in out.splitlines():
            s = ln.rstrip()
            m = _re.search(r'^\S.*(adapter|适配器)\s+(.+?):\s*$', s, _re.I)
            if m:
                cur = {'name': m.group(2).strip(), 'ips': [], 'mask': [], 'gw': [], 'dns': []}
                data.append(cur)
                continue
            if cur is None:
                continue
            t = s.strip()
            if _re.search(r'IPv4.*[：:]', t) or _re.search(r'IPv4.*Address', t, _re.I):
                ip = t.split(':')[-1].strip().split('(')[0].strip()
                cur['ips'].append(ip)
            elif '子网掩码' in t or 'Subnet Mask' in t:
                cur['mask'].append(t.split(':')[-1].strip())
            elif '默认网关' in t or 'Default Gateway' in t:
                v = t.split(':')[-1].strip()
                if v:
                    cur['gw'].append(v)
            elif 'DNS' in t and '服务器' in t or 'DNS Servers' in t:
                v = t.split(':')[-1].strip()
                if v:
                    cur['dns'].append(v)
        for a in data:
            if not a['ips']:
                continue
            sb.append('[%s]' % a['name'])
            for i, ip in enumerate(a['ips']):
                mk = a['mask'][i] if i < len(a['mask']) else ''
                sb.append('  IPv4: %s / %s' % (ip, mk))
            for g in a['gw']:
                sb.append('  网关: %s' % g)
            for d in a['dns']:
                sb.append('  DNS: %s' % d)
    except Exception as ex:
        sb.append('网卡枚举失败: %s' % ex)
    return '\n'.join(sb)


class _NetLog:
    """深色控制台 + 独立缓冲 (对齐 C# NLog; 切页保留缓冲, 显示文本经主线程 marshal)."""
    def __init__(self, parent, x, y, w, h, root):
        self.root = root
        self.tb = ui.console_text(parent, x=x, y=y, w=w, h=h)
        self.buf = []                      # 独立缓冲 (切页不丢)

    def line(self, s):
        self.buf.append(s)
        self.root.after(0, lambda: (self.tb.insert('end', s + '\n'), self.tb.see('end')))

    def set(self, s):
        self.buf = [s] if s else []
        self.root.after(0, lambda: (self.tb.delete('1.0', 'end'), self.tb.insert('end', s)))

    def text(self):
        return self.tb.get('1.0', 'end')

    def save(self):
        p = filedialog.asksaveasfilename(defaultextension='.txt',
                                         initialfile='netlog-%s.txt' % time.strftime('%Y%m%d-%H%M%S'),
                                         filetypes=[('log', '*.txt')])
        if p:
            try:
                with open(p, 'w', encoding='utf-8') as f:
                    f.write(self.text())
            except OSError:
                pass

    def copy_all(self):
        try:
            self.root.clipboard_clear()
            self.root.clipboard_append(self.text())
        except Exception:
            pass


def _stamp(s):
    return time.strftime('%H:%M:%S') + '  ' + s


def show_nettools():
    """网络工具窗体: 640x520, 7 页签, 每页独立控制台缓冲."""
    win, content = ui.make_window('WgIme 网络工具', 640, 520)
    W, H = 640, 520

    # 页签条
    names = ['Ping', 'Tracert', 'DNS', 'HTTP', '端口', '子网', '本机']
    chipw = (W - 28) // len(names)
    chips = []
    pages = []          # 每页 (top 区 Frame, _NetLog)
    cur = [0]

    contentH = H - 78
    strip = tk.Frame(content, bg=ui.BG)
    strip.place(x=0, y=0, width=W, height=40)

    body = tk.Frame(content, bg=ui.BG)
    body.place(x=0, y=40, width=W, height=contentH)

    # ---------- 页签构建 (每页 top 参数区 + 日志) ----------
    def make_page(i, top_h):
        page = tk.Frame(body, bg=ui.BG)
        top = tk.Frame(page, bg=ui.BG)
        top.place(x=0, y=0, width=W, height=top_h)
        log = _NetLog(page, 0, top_h, W, contentH - top_h, win)
        pages.append((page, top, log))
        return page, top, log

    def show_tab(i):
        cur[0] = i
        for j, (page, _t, _l) in enumerate(pages):
            if j == i:
                page.place(x=0, y=0, width=W, height=contentH)
                page.lift()
            else:
                page.place_forget()
        for j, c in enumerate(chips):
            c.configure(fg=ui.ACCENT if j == i else ui.SUB)

    # ---------- Ping ----------
    p, top, log = make_page(0, 44)
    host = ui.rounded_entry(top, x=12, y=8, w=180, h=28, initial='223.5.5.5')
    cnt = ui.rounded_entry(top, x=200, y=8, w=50, h=28, initial='4')
    size = ui.rounded_entry(top, x=258, y=8, w=64, h=28, initial='32')
    tk.Label(top, text='B', bg=ui.BG, fg=ui.SUB, font=ui.font(9)).place(x=326, y=13)
    cancel = [False]

    def ping_go():
        n = _int(cnt.get(), 4)
        sz = _int(size.get(), 32)
        h = host.get().strip()
        cancel[0] = False
        log.line(_stamp('-- ping %s x%s  size=%dB --' % (h, '∞' if n == 0 else n, sz)))
        def work():
            sent = ok = 0
            mn, mx, tot = None, 0, 0
            while not cancel[0] and (n == 0 or sent < n):
                sent += 1
                okr, rtt = ping_rtt(h, sz, 2000)
                if okr:
                    ok += 1
                    tot += rtt
                    mn = rtt if mn is None else min(mn, rtt)
                    mx = max(mx, rtt)
                    log.line(_stamp('reply: seq=%d time=%dms' % (sent, rtt)))
                else:
                    log.line(_stamp('timeout: seq=%d' % sent))
                if n == 0 or sent < n:
                    time.sleep(0.8)
            if sent > 0 and n != 0:
                loss = 100.0 * (sent - ok) / sent
                stat = '统计: 已发 %d 已收 %d 丢包 %.1f%%' % (sent, ok, loss)
                if ok:
                    stat += ' 时延 min/avg/max = %d/%d/%dms' % (mn, tot // ok, mx)
                log.line(_stamp('-- %s --' % stat))
        _bg(work)

    def ping_stop():
        cancel[0] = True

    ui.flat_button(top, 'Ping', ping_go, primary=True, x=348, y=8, w=70, h=28)
    ui.flat_button(top, '停止', ping_stop, x=424, y=8, w=60, h=28)
    ui.flat_button(top, '清除', lambda: log.set(''), x=514, y=8, w=52, h=28)
    ui.flat_button(top, '保存', log.save, x=572, y=8, w=56, h=28)
    log.line('主机 + 次数 (0=持续) + 包大小(字节); 有限次数跑完输出 丢包率/时延统计')

    # ---------- Tracert ----------
    p, top, log = make_page(1, 44)
    thost = ui.rounded_entry(top, x=12, y=8, w=210, h=28, initial='223.5.5.5')

    def trace_go():
        h = thost.get().strip()
        log.line(_stamp('-- tracert %s --' % h))
        def work():
            for ttl in range(1, 31):
                ln, done = hop_once(h, ttl, 2000)
                log.line(ln)
                if done:
                    break
        _bg(work)

    ui.flat_button(top, '开始路由跟踪', trace_go, primary=True, x=230, y=8, w=120, h=28)
    ui.flat_button(top, '清除', lambda: log.set(''), x=514, y=8, w=52, h=28)
    ui.flat_button(top, '保存', log.save, x=572, y=8, w=56, h=28)

    # ---------- DNS ----------
    p, top, log = make_page(2, 76)
    dname = ui.rounded_entry(top, x=12, y=8, w=240, h=28, initial='www.baidu.com')
    dserver = ui.rounded_entry(top, x=260, y=8, w=130, h=28, initial='223.5.5.5')
    types = ['A', 'AAAA', 'CNAME', 'MX', 'TXT', 'NS', 'PTR']
    curtype = ['A']
    tchips = []

    def pick_type(i):
        curtype[0] = types[i]
        for j, c in enumerate(tchips):
            c.configure(fg='white' if j == i else ui.SUB, bg=ui.ACCENT if j == i else ui.CARD)

    for i, t in enumerate(types):
        c = ui.flat_button(top, t, (lambda i=i: pick_type(i)), x=12 + i * 66, y=42, w=60, h=26)
        tchips.append(c)
    pick_type(0)

    def dns_go():
        nm, sv, tp = dname.get().strip(), dserver.get().strip(), curtype[0]
        log.line(_stamp('-- dns %s %s  @%s --' % (tp, nm, sv)))
        def work():
            try:
                for ln in dns_query(nm, tp, sv, 3000):
                    log.line(ln)
            except Exception as ex:
                log.line('Err: %s' % ex)
        _bg(work)

    ui.flat_button(top, '查询', dns_go, primary=True, x=398, y=8, w=90, h=28)
    ui.flat_button(top, '清除', lambda: log.set(''), x=514, y=8, w=52, h=28)
    ui.flat_button(top, '保存', log.save, x=572, y=8, w=56, h=28)
    log.line('原始 DNS 协议查询 (UDP 53), 记录类型点选; 服务器默认阿里 223.5.5.5')

    # ---------- HTTP ----------
    p, top, log = make_page(3, 44)
    hurl = ui.rounded_entry(top, x=12, y=8, w=330, h=28, initial='https://www.baidu.com')

    def http_go():
        u = hurl.get().strip()
        log.line(_stamp('-- http %s --' % u))
        def work():
            for ln in http_check(u, 6000):
                log.line(ln)
        _bg(work)

    ui.flat_button(top, '请求', http_go, primary=True, x=350, y=8, w=90, h=28)
    hurl.bind('<Return>', lambda e: http_go())
    ui.flat_button(top, '清除', lambda: log.set(''), x=514, y=8, w=52, h=28)
    ui.flat_button(top, '保存', log.save, x=572, y=8, w=56, h=28)
    log.line('状态码/Server/Content-Type/Body 大小/TTFB/总耗时; 自动跟随跳转, 无 scheme 默认 https://')

    # ---------- 端口 ----------
    p, top, log = make_page(4, 44)
    phost = ui.rounded_entry(top, x=12, y=8, w=190, h=28, initial='223.5.5.5')
    pport = ui.rounded_entry(top, x=210, y=8, w=64, h=28, initial='443')

    def port_check():
        h = phost.get().strip()
        pt = _int(pport.get(), 443)
        def work():
            log.line(_stamp('%s:%d  %s' % (h, pt, test_port(h, pt, 2000))))
        _bg(work)

    def port_scan():
        h = phost.get().strip()
        ports = [21, 22, 23, 25, 53, 80, 110, 143, 443, 445, 3306, 3389, 8080]
        log.line(_stamp('-- scan %s (%d 个常用端口) --' % (h, len(ports))))
        def work():
            for pt in ports:
                log.line('  %d  %s' % (pt, test_port(h, pt, 600)))
            log.line(_stamp('-- 扫描完成 --'))
        _bg(work)

    ui.flat_button(top, '检测', port_check, primary=True, x=282, y=8, w=76, h=28)
    ui.flat_button(top, '常用端口扫描', port_scan, x=364, y=8, w=130, h=28)
    ui.flat_button(top, '清除', lambda: log.set(''), x=514, y=8, w=52, h=28)
    ui.flat_button(top, '保存', log.save, x=572, y=8, w=56, h=28)

    # ---------- 子网 ----------
    p, top, log = make_page(5, 76)
    tk.Label(top, text='IP', bg=ui.BG, fg=ui.SUB, font=ui.font(9.5)).place(x=14, y=13)
    sip = ui.rounded_entry(top, x=38, y=8, w=150, h=28, initial='192.168.1.10')
    tk.Label(top, text='前缀/掩码', bg=ui.BG, fg=ui.SUB, font=ui.font(9.5)).place(x=198, y=13)
    smk = ui.rounded_entry(top, x=280, y=8, w=120, h=28, initial='24')

    def recompute(_=None):
        try:
            log.set('\n'.join(subnet_calc(sip.get(), smk.get())))
        except Exception as ex:
            log.set('Err: %s' % ex)

    sip.bind('<KeyRelease>', recompute)
    smk.bind('<KeyRelease>', recompute)

    tk.Label(top, text='拆分为', bg=ui.BG, fg=ui.SUB, font=ui.font(9.5)).place(x=14, y=47)
    scnt = ui.rounded_entry(top, x=70, y=42, w=48, h=28, initial='4')
    tk.Label(top, text='个子网', bg=ui.BG, fg=ui.SUB, font=ui.font(9.5)).place(x=124, y=47)

    def do_split():
        n = _int(scnt.get(), 4)
        if n < 2:
            n = 4
        try:
            for ln in subnet_split(sip.get(), smk.get(), n):
                log.line(ln)
        except Exception as ex:
            log.line('Err: %s' % ex)

    def do_table():
        for ln in mask_table():
            log.line(ln)

    tk.Label(top, text='范围', bg=ui.BG, fg=ui.SUB, font=ui.font(9.5)).place(x=344, y=47)
    sip1 = ui.rounded_entry(top, x=384, y=42, w=106, h=28, initial='192.168.1.10')
    sip2 = ui.rounded_entry(top, x=496, y=42, w=106, h=28, initial='192.168.1.99')

    def do_cidr():
        try:
            log.line('-- 范围转 CIDR --')
            for ln in range_to_cidr(sip1.get(), sip2.get()):
                log.line('  ' + ln)
        except Exception as ex:
            log.line('Err: %s' % ex)

    ui.flat_button(top, '拆分', do_split, primary=True, x=186, y=42, w=64, h=28)
    ui.flat_button(top, '速查表', do_table, x=256, y=42, w=76, h=28)
    ui.flat_button(top, '▶', do_cidr, primary=True, x=608, y=42, w=24, h=28)
    recompute()

    # ---------- 本机 ----------
    p, top, log = make_page(6, 44)

    def local_refresh():
        def work():
            try:
                info = local_net_info()
                pub = public_ip(3000)
                info += '\n公网 IP: %s' % (pub if pub else '查询失败 (需联网)')
            except Exception as ex:
                info = 'Err: %s' % ex
            win.after(0, lambda: log.set(info))
        _bg(work)

    ui.flat_button(top, '刷新', local_refresh, primary=True, x=12, y=8, w=100, h=28)
    ui.flat_button(top, '复制全部', log.copy_all, x=120, y=8, w=100, h=28)
    local_refresh()

    # ---------- 页签条 ----------
    for i, n in enumerate(names):
        c = ui.flat_button(strip, n, (lambda i=i: show_tab(i)), x=14 + i * chipw, y=6, w=chipw, h=28)
        chips.append(c)

    # 初始显示第一页 (pages 由各 make_page 逐次加入, 顺序与 names 一致)
    show_tab(0)


def _int(s, default):
    try:
        return int(str(s).strip())
    except Exception:
        return default

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


# ---------- 用户词表 (复刻 C# UserWordsDialog + ManageUserWords) ----------
def show_user_words(engine):
    """用户词表: 列表(词/编码) + 全选/全不选/删除选中; 删除后后台重建词库 (对齐 C# BuildDicts+ApplySwap)."""
    if not engine.user_words:
        _msgbox('用户词表', '还没有用户词。用「造词」或「批量造词…」添加。')
        return
    win, content = ui.make_window('WgIme 用户词表 (选中后点删除)', 420, 342)
    lb = tk.Listbox(content, bg=ui.CARD, fg=ui.TEXT, font=ui.font(9.5, mono=True),
                    selectmode='extended', activestyle='none',
                    highlightthickness=1, highlightbackground=ui.BORDER, bd=0)
    lb.place(x=14, y=10, width=392, height=272)
    items = sorted(engine.user_words.items(), key=lambda kv: kv[0])
    for w, c in items:
        lb.insert('end', '%s\t%s' % (w, c))
    status = tk.Label(content, text='共 %d 个词' % len(items), bg=ui.BG, fg=ui.SUB, font=ui.font(8.5))
    status.place(x=14, y=288)

    def sel_all():
        lb.selection_set(0, 'end')

    def sel_none():
        lb.selection_clear(0, 'end')

    def do_del():
        idx = list(lb.curselection())
        if not idx:
            status.config(text='没有选中任何词', fg=ui.RED)
            return
        words = [items[i][0] for i in idx]
        for i in reversed(idx):
            lb.delete(i)
        n = engine.remove_user_words(words)
        status.config(text='已删除 %d 个词, 正在重建词库…' % n, fg=ui.ACCENT)

        def work():
            try:
                engine.reload()                        # 重建索引 (对齐 C# BuildDicts + ApplySwap)
                win.after(0, lambda: status.config(text='已删除 %d 个词, 词库已重建' % n, fg=ui.GREEN))
            except Exception as ex:
                win.after(0, lambda: status.config(text='重建失败: %s' % ex, fg=ui.RED))
        threading.Thread(target=work, daemon=True).start()

    ui.flat_button(content, '全选', sel_all, x=14, y=302, w=80, h=28)
    ui.flat_button(content, '全不选', sel_none, x=102, y=302, w=80, h=28)
    ui.flat_button(content, '删除选中', do_del, primary=True, x=218, y=302, w=96, h=28)
    ui.flat_button(content, '关闭', win.destroy, x=322, y=302, w=84, h=28)


# ---------- 批量造词 (复刻 C# BatchMakeWords + ConfirmWordsDialog) ----------
def show_batch_makeword(engine, data_dir=None):
    """批量造词: 选文件(每行一个词) -> 收集 2-8 汉字去重 -> 确认 -> 批量造词."""
    from tkinter import filedialog
    import engine as engmod

    path = filedialog.askopenfilename(
        title='选择词表文件 (每行一个词)',
        filetypes=[('文本文件', '*.txt'), ('所有文件', '*.*')])
    if not path:
        return
    text = engmod.read_import_text(path)               # UTF-8 / GB18030 自动识别, 64MB 上限
    if text is None:
        _tip('批量造词', '文件超过 64MB 或无法读取')    # 对齐 C# TrayTip(警告)
        return
    words = []
    seen = set()
    skipped = 0
    for raw in text.split('\n'):
        w = raw.strip()
        if not w:
            continue
        if not (2 <= len(w) <= 8) or not engmod.is_all_cjk(w):
            skipped += 1
            continue
        if w in seen:
            skipped += 1
            continue
        seen.add(w)
        words.append(w)
    if not words:
        _tip('批量造词', '没有发现 2-8 个汉字的词')     # 对齐 C# TrayTip(警告)
        return
    if not _confirm_dialog('批量造词', '检测到 %d 个词 (跳过 %d 行)。\n全部用拼音编码造词?' % (len(words), skipped)):
        return
    added, sk = engine.add_user_words_batch(words)
    _tip('批量造词', '已造词 %d 个 (跳过 %d 个: 已存在或无编码)' % (added, sk))


def _confirm_dialog(title, text):
    """是/否 确认框 (ui 设计系统风格; 返回 True=确定)."""
    win = tk.Toplevel()
    win.title(title)
    win.attributes('-topmost', True)
    win.resizable(False, False)
    win.configure(bg=ui.BG)
    res = {'ok': False}
    tk.Label(win, text=text, bg=ui.BG, fg=ui.TEXT, font=ui.font(9.5), justify='left',
             wraplength=340).place(x=14, y=16)

    def ok():
        res['ok'] = True
        win.destroy()

    win.protocol('WM_DELETE_WINDOW', win.destroy)      # 点 X = 取消
    ui.flat_button(win, '确定', ok, primary=True, x=176, y=104, w=96, h=28)
    ui.flat_button(win, '取消', win.destroy, x=282, y=104, w=96, h=28)
    win.geometry('400x152')
    win.wait_window()
    return res['ok']


# ---------- 插件管理 ----------
# ---------- 插件管理 (复刻 C# PluginMgrForm: 重载/启停/打开目录/编辑/删除/新建/运行) ----------
def show_plugin_mgr(plugins, data_dir, reload_fn, run_file_fn=None, list_files_fn=None, plugin_dir_fn=None):
    """完整插件管理器(对齐 C# 版 PluginMgrForm):
    列表(名称/编码/类型/启停/文件) + 按钮(重载/启用禁用/打开目录/编辑/删除/新建模板/运行)."""
    import subprocess
    pdir = plugin_dir_fn() if plugin_dir_fn else os.path.join(data_dir, 'plugins')
    try:
        os.makedirs(pdir, exist_ok=True)
    except OSError:
        pass

    win, content = ui.make_window('WgIme 插件管理', 560, 420)
    # 顶部按钮条
    bar = tk.Frame(content, bg=ui.BG)
    bar.place(x=10, y=10, width=540, height=34)
    lst = tk.Listbox(content, font=ui.font(9.5), bg=ui.CARD, fg=ui.TEXT, bd=0,
                     highlightthickness=1, highlightbackground=ui.BORDER, selectbackground=ui.ACCENT,
                     activestyle='none', selectmode='single')
    lst.place(x=10, y=52, width=540, height=300)
    # 底部说明
    ui.flat_button(content, '关闭', win.destroy, x=470, y=372, w=78, h=32)

    _rows = []

    def _meta(p):
        if hasattr(p, 'CODE'):
            return {'name': getattr(p, 'NAME', getattr(p, 'CODE', '?')), 'code': getattr(p, 'CODE', '?'),
                    'kind': 'py', 'file': getattr(p, '__file__', None), 'perm': getattr(p, 'PERM', 'low'),
                    'desc': getattr(p, 'DESC', ''), 'ver': str(getattr(p, 'VERSION', '') or '')}
        return {'name': p.name or os.path.basename(p.path), 'code': p.code or '?', 'kind': p.kind,
                'file': p.path, 'perm': getattr(p, 'perm', 'low'), 'desc': getattr(p, 'desc', ''),
                'ver': getattr(p, 'version', '')}

    def _disabled_set():
        try:
            return set(l.strip().lower() for l in open(os.path.join(data_dir, 'plugins-disabled.txt'), encoding='utf-8') if l.strip())
        except OSError:
            return set()

    def _save_disabled(dis):
        try:
            open(os.path.join(data_dir, 'plugins-disabled.txt'), 'w', encoding='utf-8').write('\n'.join(sorted(dis)))
        except OSError:
            pass

    def refresh():
        lst.delete(0, 'end')
        _rows[:] = []
        dis = _disabled_set()
        # 目录下全部插件文件 (list_files_fn 提供, 含 .py/.txt, 含禁用项)
        if list_files_fn:
            for info in list_files_fn():
                disd = info.get('file', '').lower() and os.path.basename(info['file']).lower() in dis
                typ = {'py': 'py', 'csharp': 'C#', 'python': 'py块', 'steps': 'DSL'}.get(info.get('kind'), info.get('kind'))
                state = '已禁用' if disd else '启用'
                ver = (' v%s' % info['version']) if info.get('version') else ''
                lst.insert('end', '%s  (%s)  [%s]  %s%s  — %s' % (info.get('name'), info.get('code'), typ, state, ver, os.path.basename(info['file'])))
                _rows.append(info)
        else:
            # 兜底: 只列已加载 .py 模块 (plugins 参数)
            for m in plugins:
                mt = _meta(m)
                disd = mt['code'] in dis
                lst.insert('end', '%s  (%s)  [py]  %s%s' % (mt['name'], mt['code'], '已禁用' if disd else '启用', os.path.basename(mt['file'] or '')))
                _rows.append(mt)

    def sel():
        i = lst.curselection()
        return _rows[i[0]] if i and 0 <= i[0] < len(_rows) else None

    def on_reload():
        reload_fn()
        refresh()

    def on_toggle():
        r = sel()
        if not r or not r.get('file'):
            return
        dis = _disabled_set()
        fn = os.path.basename(r['file']).lower()
        if fn in dis:
            dis.discard(fn)
        else:
            dis.add(fn)
        _save_disabled(dis)
        reload_fn()
        refresh()

    def on_open_dir():
        try:
            os.startfile(pdir)
        except Exception:
            pass

    def on_edit():
        r = sel()
        if not r or not r.get('file'):
            return
        try:
            os.startfile(r['file'])
        except Exception:
            pass

    def on_delete():
        r = sel()
        if not r or not r.get('file'):
            return
        if not messagebox.askyesno('删除插件', '删除插件文件 %s ?' % os.path.basename(r['file']), parent=win):
            return
        try:
            os.remove(r['file'])
        except OSError:
            pass
        reload_fn()
        refresh()

    def on_new():
        try:
            os.makedirs(pdir, exist_ok=True)
            f = os.path.join(pdir, 'new-%s.py' % time.strftime('%H%M%S'))
            with open(f, 'w', encoding='utf-8') as fh:
                fh.write("# -*- coding: utf-8 -*-\n\"\"\"WgIme 纯 Python 插件 (规范: docs/WGIME_插件规范.md).\"\"\"\n\nCODE = 'mycode'\nNAME = '我的插件'\nDESC = ''\nPERM = 'low'\n\n\ndef run():\n    # 在这里实现插件逻辑 (窗口用 ui.py 设计系统, 不建 tk.Tk())\n    pass\n")
            os.startfile(f)
        except Exception:
            pass
        reload_fn()
        refresh()

    def on_run():
        r = sel()
        if not r or not r.get('file'):
            return
        if run_file_fn:
            run_file_fn(r['file'])
        else:
            _msgbox('插件管理', '该插件无运行入口')

    x = 10
    for cap, fn, prim, w in (('重载', on_reload, False, 56), ('启用/禁用', on_toggle, False, 84),
                             ('打开目录', on_open_dir, False, 80), ('编辑', on_edit, False, 56),
                             ('删除…', on_delete, False, 66), ('新建模板…', on_new, False, 92),
                             ('运行', on_run, True, 60)):
        ui.flat_button(bar, cap, fn, primary=prim, x=x, y=2, w=w, h=30)
        x += w + 8
    lst.bind('<Double-Button-1>', lambda e: on_run())
    win.bind('<Escape>', lambda e: win.destroy())
    refresh()


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

    win.protocol('WM_DELETE_WINDOW', cancel)   # 点标题栏 X = 取消(否则被当"确定"导致误导入)

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
