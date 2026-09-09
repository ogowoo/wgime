# -*- coding: utf-8 -*-
"""悬浮时钟 (纯 Python 移植版, 1:1 对齐 C# 插件 plugins/clock.txt):
时钟(秒环/闹钟多提醒/整点报时) + 倒计时(圆环/预设/自定义提醒) + 秒表(计次) + 番茄(统计/7日图).
数据存 %LOCALAPPDATA%\\wgime\\clock.cfg / pomodoro.txt (文件路径与格式与 C# 版完全兼容).
入口 run() 在宿主 tkinter 主线程建窗 (ui.py 设计系统); 报时/闹钟守护线程经队列派发回主线程.
"""
import datetime
import os
import queue
import re
import threading
import time
import urllib.parse
import tkinter as tk
from tkinter import ttk

import ui

CODE = 'sz'
NAME = '悬浮时钟'
DESC = '现代风时钟: 秒环/闹钟/整点报时/倒计时圆环/预设/秒表计次/番茄统计与7日图'
VERSION = ''
AUTHOR = ''
PERM = 'low'

try:
    import winsound
except Exception:
    winsound = None

# ---------- 持久化 (与 C# 版同路径同格式) ----------
CFG_DIR = os.path.join(os.environ.get('LOCALAPPDATA', os.path.expanduser('~')), 'wgime')
CFG_PATH = os.path.join(CFG_DIR, 'clock.cfg')
POMO_PATH = os.path.join(CFG_DIR, 'pomodoro.txt')

CFG = {'hourly': True, 'reminder': '休息一下, 喝点水'}
ALARMS = []                       # [{'time','name','enabled','repeat','mode'}]  mode: popup/full/tray
_CFG_LOCK = threading.Lock()
_ALARM_RE = re.compile(r'^([01]\d|2[0-3]):[0-5]\d$')
_WD = '日一二三四五六'            # 索引 = C# DayOfWeek (日=0..六=6); python weekday() Mon=0 -> (w+1)%7


def _cs_dow(d):
    return (d.weekday() + 1) % 7


def week_cn(d):
    return '星期' + _WD[_cs_dow(d)]


def valid_alarm_time(t):
    return bool(_ALARM_RE.match(t or ''))


def escape_cfg(s):
    s = (s or '').replace('\r', ' ').replace('\n', ' ')
    return urllib.parse.quote(s, safe='')


def unescape_cfg(s):
    try:
        return urllib.parse.unquote(s or '')
    except Exception:
        return s or ''


def load_cfg():
    try:
        with _CFG_LOCK:
            ALARMS.clear()
            if not os.path.isfile(CFG_PATH):
                return
            alarm_time = ''
            alarm_on = False
            with open(CFG_PATH, encoding='utf-8-sig') as f:
                for raw in f:
                    t = raw.strip()
                    eq = t.find('=')
                    if eq < 1:
                        continue
                    k = t[:eq].strip().lower()
                    v = t[eq + 1:].strip()
                    if k == 'hourly':
                        CFG['hourly'] = v != '0'
                    elif k == 'reminder':
                        CFG['reminder'] = v
                    elif k == 'alarm':
                        alarm_time = v
                    elif k == 'alarmon':
                        alarm_on = v == '1'
                    elif k.startswith('alarm.'):
                        a = v.split('|', 4)
                        if len(a) >= 2 and valid_alarm_time(a[0]):
                            nm = unescape_cfg(a[2]) if len(a) >= 3 else '闹钟'
                            rp = unescape_cfg(a[3]) if len(a) >= 4 else '每天'
                            md = unescape_cfg(a[4]) if len(a) >= 5 else 'popup'
                            if md not in ('popup', 'full', 'tray'):
                                md = 'popup'
                            ALARMS.append({'time': a[0], 'name': nm, 'enabled': a[1] == '1',
                                           'repeat': rp, 'mode': md})
            # 旧版配置兼容: 首次发现 alarm/alarmon 时自动迁移
            if not ALARMS and valid_alarm_time(alarm_time):
                ALARMS.append({'time': alarm_time, 'name': '旧版闹钟', 'enabled': alarm_on,
                               'repeat': '每天', 'mode': 'popup'})
    except Exception:
        pass


def save_cfg():
    try:
        os.makedirs(CFG_DIR, exist_ok=True)
        lines = ['hourly = %s\n' % ('1' if CFG['hourly'] else '0'),
                 'reminder = %s\n' % CFG['reminder']]
        with _CFG_LOCK:
            items = list(ALARMS)
        for i, a in enumerate(items):
            lines.append('alarm.%d = %s|%s|%s|%s|%s\n' % (
                i + 1, a['time'], '1' if a['enabled'] else '0',
                escape_cfg(a['name']), escape_cfg(a['repeat']), escape_cfg(a['mode'])))
        with open(CFG_PATH, 'w', encoding='utf-8', newline='\n') as f:   # UTF-8 无 BOM, LF
            f.write(''.join(lines))
    except Exception:
        pass


def repeat_matches(a, now):
    rp = a['repeat']
    if rp in ('仅一次', '每天'):
        return True
    if rp == '工作日':
        return now.weekday() < 5
    if rp == '周末':
        return now.weekday() >= 5
    return bool(rp) and rp.startswith('自定义:') and _WD[_cs_dow(now)] in rp


# ---------- 声音 (winsound, 对齐 SystemSounds) ----------
def _ding(exc=True):
    if not winsound:
        return
    try:
        winsound.MessageBeep(winsound.MB_ICONEXCLAMATION if exc else winsound.MB_ICONASTERISK)
    except Exception:
        pass


# ---------- 后台守护线程 -> UI 线程派发 (队列 + root.after 轮询) ----------
_UIQ = queue.Queue()
_dispatcher_on = [False]


def _post_ui(fn):
    _UIQ.put(fn)


def _ensure_dispatcher():
    """常驻派发器: 挂在宿主默认 root 上, 主窗口关了闹钟/报时仍能弹窗."""
    if _dispatcher_on[0]:
        return
    root = tk._default_root
    if root is None:
        return
    _dispatcher_on[0] = True

    def poll():
        try:
            while True:
                fn = _UIQ.get_nowait()
                try:
                    fn()
                except Exception:
                    pass
        except queue.Empty:
            pass
        try:
            if root.winfo_exists():
                root.after(300, poll)
        except Exception:
            pass
    root.after(300, poll)


# ---------- 常驻报时/闹钟守护 (对齐 C# StartChimeWatcher; 主窗关闭后仍工作) ----------
_watch_started = [False]
_snooze_timers = []
_fullscreen_alarms = []


def _start_watcher():
    if _watch_started[0]:
        return
    _watch_started[0] = True
    threading.Thread(target=_watch_loop, name='ClockChime', daemon=True).start()


def _watch_loop():
    last_hour = -1
    fired = set()
    fired_day = ''
    while True:
        time.sleep(5)
        try:
            load_cfg()
            now = datetime.datetime.now()
            if CFG['hourly'] and now.minute == 0 and now.hour != last_hour:
                last_hour = now.hour
                _ding(False)
            day = now.strftime('%Y-%m-%d')
            if day != fired_day:
                fired_day = day
                fired.clear()
            hm = now.strftime('%H:%M')
            with _CFG_LOCK:
                items = list(ALARMS)
            for i, a in enumerate(items):
                key = '%s %s#%d' % (day, hm, i)
                if a['enabled'] and hm == a['time'] and repeat_matches(a, now) and key not in fired:
                    fired.add(key)
                    _post_ui(lambda a=a: dispatch_alarm(a['time'], a['name'], a['repeat'], a['mode']))
                    if a['repeat'] == '仅一次':
                        a['enabled'] = False
                        save_cfg()
        except Exception:
            pass


def dispatch_alarm(time_s, name, repeat, mode):
    try:
        if mode == 'full':
            show_fullscreen_alarm(time_s, name, repeat)
            return
        if mode == 'tray':
            show_tray_alarm(time_s, name, repeat)
            return
        show_alarm_popup(time_s, name, repeat)
    except Exception:
        pass


# ---------- 格式化 (对齐 C# FmtCd/FmtSw/FmtMinutes) ----------
def fmt_cd(sec):
    sec = max(0, int(sec))
    h, m, s = sec // 3600, (sec % 3600) // 60, sec % 60
    if h >= 1:
        return '%d:%02d:%02d' % (h, m, s)
    return '%02d:%02d' % (m, s)


def fmt_sw(sec):
    ms = int((sec * 1000) % 1000)
    total = int(sec)
    if total >= 3600:
        return '%d:%02d:%02d.%03d' % (total // 3600, (total % 3600) // 60, total % 60, ms)
    return '%02d:%02d.%03d' % (total // 60, total % 60, ms)


def fmt_minutes(minutes):
    if minutes >= 60:
        return '%d小时%d分' % (int(minutes / 60), int(minutes % 60))
    return '%d分钟' % int(minutes)


# ---------- 闹钟提醒弹窗 (居中弹窗, 停止/5分钟后提醒) ----------
def show_alarm_popup(time_s, name, repeat):
    on = [True]

    def closed():
        on[0] = False

    w, c = ui.make_window('WgIme 闹钟提醒', 340, 224, on_close=closed)
    tk.Label(c, text=time_s, font=ui.font(32), fg=ui.ORANGE, bg=ui.BG,
             anchor='center').place(x=0, y=14, width=340, height=52)
    tk.Label(c, text=name, font=ui.font(12, bold=True), fg=ui.TEXT, bg=ui.BG,
             anchor='center').place(x=20, y=70, width=300, height=28)
    tk.Label(c, text='重复：' + (repeat or ''), font=ui.font(8.5), fg=ui.SUB, bg=ui.BG,
             anchor='center').place(x=20, y=98, width=300, height=20)

    def beep():
        if on[0]:
            _ding(True)
            try:
                w.after(1400, beep)
            except Exception:
                pass

    def stop():
        on[0] = False
        try:
            w.destroy()
        except Exception:
            pass

    def snooze():
        on[0] = False
        try:
            w.destroy()
        except Exception:
            pass

        def later():
            _post_ui(lambda: show_alarm_popup(datetime.datetime.now().strftime('%H:%M'),
                                              name + '（稍后提醒）', '单次延后'))
        t = threading.Timer(300.0, later)
        t.daemon = True
        _snooze_timers.append(t)
        t.start()

    ui.flat_button(c, '停止提醒', stop, primary=True, x=20, y=136, w=142, h=34)
    b = ui.flat_button(c, '5分钟后提醒', snooze, x=178, y=136, w=142, h=34)
    b.configure(fg=ui.ORANGE)
    _ding(True)
    beep()
    try:
        w.lift()
        w.focus_force()
    except Exception:
        pass


# ---------- 全屏强制休息 (同一时刻只保留一个, 每 3 秒重响) ----------
def show_fullscreen_alarm(time_s, name, repeat):
    for f in list(_fullscreen_alarms):
        try:
            f.destroy()
        except Exception:
            pass
        try:
            _fullscreen_alarms.remove(f)
        except ValueError:
            pass
    root = tk._default_root
    if root is None:
        return
    a = tk.Toplevel(root)
    a.overrideredirect(True)
    a.attributes('-topmost', True)
    try:
        a.attributes('-alpha', 0.96)
    except Exception:
        pass
    sw, sh = a.winfo_screenwidth(), a.winfo_screenheight()
    a.geometry('%dx%d+0+0' % (sw, sh))
    a.configure(bg='#12161E')
    on = [True]
    tk.Label(a, text=name or '休息一下', font=ui.font(30, bold=True), fg='#EBEBF0',
             bg='#12161E', anchor='center').place(x=0, y=sh // 2 - 150, width=sw, height=60)
    tk.Label(a, text=time_s + '  ' + (repeat or ''), font=ui.font(16), fg='#96A0B4',
             bg='#12161E', anchor='center').place(x=0, y=sh // 2 - 80, width=sw, height=40)
    tk.Label(a, text='☕', font=ui.font(72), fg=ui.ACCENT, bg='#12161E',
             anchor='center').place(x=0, y=sh // 2 - 40, width=sw, height=130)

    def ok():
        on[0] = False
        try:
            a.destroy()
        except Exception:
            pass
        try:
            _fullscreen_alarms.remove(a)
        except ValueError:
            pass

    btn = ui.flat_button(a, '我知道了，继续工作', ok, primary=True,
                         x=sw // 2 - 140, y=sh // 2 + 120, w=280, h=52)
    btn.configure(font=ui.font(13, bold=True))

    def beep():
        if on[0]:
            _ding(True)
            try:
                a.after(3000, beep)
            except Exception:
                pass
    _ding(True)
    beep()
    _fullscreen_alarms.append(a)
    try:
        a.lift()
        a.focus_force()
    except Exception:
        pass


# ---------- 轻提醒 (对齐 C# 托盘气泡: 不打断, 声音一次, 8 秒自动消失) ----------
def show_tray_alarm(time_s, name, repeat):
    _ding(False)
    root = tk._default_root
    if root is None:
        return
    try:
        t = tk.Toplevel(root)
        t.overrideredirect(True)
        t.attributes('-topmost', True)
        tw, th = 320, 92
        sw, sh = t.winfo_screenwidth(), t.winfo_screenheight()
        t.geometry('%dx%d+%d+%d' % (tw, th, sw - tw - 16, sh - th - 48))
        t.configure(bg=ui.CARD, highlightthickness=1, highlightbackground=ui.BORDER)
        tk.Label(t, text='WgIme 提醒  ' + time_s, font=ui.font(10, bold=True), fg=ui.TEXT,
                 bg=ui.CARD, anchor='w').place(x=14, y=10, width=tw - 28, height=24)
        tk.Label(t, text=(name or '闹钟') + '  (' + (repeat or '') + ')', font=ui.font(9),
                 fg=ui.SUB, bg=ui.CARD, anchor='nw', justify='left',
                 wraplength=tw - 28).place(x=14, y=38, width=tw - 28, height=44)

        def dismiss(_=None):
            try:
                t.destroy()
            except Exception:
                pass
        t.bind('<Button-1>', dismiss)
        t.after(8000, dismiss)
    except Exception:
        pass


# ---------- 闹钟管理窗 ----------
def show_alarm_manager(changed=None):
    m, mc = ui.make_window('WgIme 闹钟管理', 360, 456)

    lst = tk.Listbox(mc, bg=ui.CARD, fg=ui.TEXT, font=ui.font(9), bd=0,
                     highlightthickness=1, highlightbackground=ui.BORDER,
                     selectbackground=ui.SURF2, selectforeground=ui.TEXT,
                     activestyle='none')
    lst.place(x=16, y=14, width=328, height=154)
    ed_time = ui.rounded_entry(mc, x=16, y=182, w=76, h=30, initial='07:30')
    ed_name = ui.rounded_entry(mc, x=100, y=182, w=148, h=30, initial='闹钟')
    edit_enabled = [True]

    def do_toggle():
        edit_enabled[0] = not edit_enabled[0]
        set_toggle()

    toggle = ui.flat_button(mc, '已开启', do_toggle, x=256, y=181, w=88, h=32)
    repeat = ttk.Combobox(mc, state='readonly', font=ui.font(9),
                          values=['仅一次', '每天', '工作日', '周末',
                                  '自定义:一二三四五', '自定义:一三五', '自定义:二四六', '自定义:日六'])
    repeat.place(x=16, y=222, width=328, height=28)
    repeat.set('每天')
    mode = ttk.Combobox(mc, state='readonly', font=ui.font(9),
                        values=['居中弹窗', '全屏强制休息', '托盘气泡'])
    mode.place(x=16, y=258, width=328, height=28)
    mode.current(0)
    note = tk.Label(mc, text='选择项目可编辑；提醒方式可单独设置', font=ui.font(8.5),
                    fg=ui.SUB, bg=ui.BG, anchor='w')
    note.place(x=16, y=294, width=328, height=20)

    def set_toggle():
        toggle.configure(text='已开启' if edit_enabled[0] else '已关闭',
                         fg=ui.GREEN if edit_enabled[0] else ui.SUB)

    set_toggle()

    def refresh():
        lst.delete(0, 'end')
        with _CFG_LOCK:
            items = list(ALARMS)
        for a in items:
            lst.insert('end', ('● ' if a['enabled'] else '○ ') + a['time'] + '   ' +
                       a['name'] + '   [' + a['repeat'] + ']')
        if changed:
            changed()

    def load_item(idx):
        with _CFG_LOCK:
            if idx < 0 or idx >= len(ALARMS):
                return
            a = dict(ALARMS[idx])
        ed_time.delete(0, 'end')
        ed_time.insert(0, a['time'])
        ed_name.delete(0, 'end')
        ed_name.insert(0, a['name'])
        edit_enabled[0] = a['enabled']
        set_toggle()
        vals = list(repeat['values'])
        repeat.set(a['repeat'] if a['repeat'] in vals else '每天')
        mode.set({'full': '全屏强制休息', 'tray': '托盘气泡'}.get(a['mode'], '居中弹窗'))

    def on_select(_=None):
        sel = lst.curselection()
        if sel:
            load_item(sel[0])
    lst.bind('<<ListboxSelect>>', on_select)

    def normalize():
        t = ed_time.get().strip().replace('：', ':')
        d = t.replace(':', '')
        if len(d) in (3, 4) and d.isdigit():
            hh, mm = int(d[:-2]), int(d[-2:])
            if 0 <= hh <= 23 and 0 <= mm <= 59:
                t = '%02d:%02d' % (hh, mm)
        ed_time.delete(0, 'end')
        ed_time.insert(0, t)

    def read_item():
        normalize()
        t = ed_time.get().strip()
        if not valid_alarm_time(t):
            note.configure(text='时间格式错误，请输入 00:00–23:59', fg=ui.RED)
            return None
        nm = ed_name.get().strip() or '闹钟'
        note.configure(text='已保存', fg=ui.GREEN)
        return {'time': t, 'name': nm, 'enabled': edit_enabled[0],
                'repeat': repeat.get() or '每天',
                'mode': {'全屏强制休息': 'full', '托盘气泡': 'tray'}.get(mode.get(), 'popup')}

    def add():
        a = read_item()
        if a is None:
            return
        with _CFG_LOCK:
            ALARMS.append(a)
        save_cfg()
        refresh()
        lst.selection_clear(0, 'end')
        lst.selection_set('end')
        on_select()

    def save_mod():
        sel = lst.curselection()
        if not sel:
            note.configure(text='请先选择一个闹钟', fg=ui.RED)
            return
        i = sel[0]
        a = read_item()
        if a is None:
            return
        with _CFG_LOCK:
            if i < len(ALARMS):
                ALARMS[i] = a
        save_cfg()
        refresh()
        lst.selection_set(i)

    def delete():
        sel = lst.curselection()
        if not sel:
            return
        i = sel[0]
        with _CFG_LOCK:
            if i < len(ALARMS):
                del ALARMS[i]
            n = len(ALARMS)
        save_cfg()
        refresh()
        if n > 0:
            lst.selection_set(min(i, n - 1))
            on_select()

    def clear():
        ed_time.delete(0, 'end')
        ed_time.insert(0, '07:30')
        ed_name.delete(0, 'end')
        ed_name.insert(0, '闹钟')
        edit_enabled[0] = True
        set_toggle()
        repeat.set('每天')
        mode.current(0)
        lst.selection_clear(0, 'end')
        note.configure(text='填写后点击新增', fg=ui.SUB)

    ui.flat_button(mc, '新增', add, primary=True, x=16, y=334, w=76, h=34)
    b = ui.flat_button(mc, '保存修改', save_mod, x=100, y=334, w=92, h=34)
    b.configure(fg=ui.ACCENT)
    b = ui.flat_button(mc, '删除', delete, x=200, y=334, w=68, h=34)
    b.configure(fg=ui.RED)
    b = ui.flat_button(mc, '清空', clear, x=276, y=334, w=68, h=34)
    b.configure(fg=ui.SUB)

    def on_close():
        # make_window 的 on_close 需在创建时传入, 这里用 <Destroy> 兜底:
        # 每次操作已即时 SaveCfg, 关窗再保存一次并刷新主窗摘要.
        save_cfg()
        if changed:
            try:
                changed()
            except Exception:
                pass
    mc.bind('<Destroy>', lambda e: on_close() if e.widget is mc else None)
    refresh()


# ---------- 主窗口 ----------
def run():
    _ensure_dispatcher()
    load_cfg()
    _start_watcher()

    alive = [True]

    def on_close():
        alive[0] = False
        if tick_id[0] is not None:
            try:
                win.after_cancel(tick_id[0])
            except Exception:
                pass
            tick_id[0] = None

    win, content = ui.make_window('WgIme 悬浮时钟', 400, 400, on_close=on_close)
    tick_id = [None]

    # ---------- tab 条 ----------
    strip = tk.Frame(content, bg=ui.BG)
    strip.place(x=0, y=0, width=400, height=40)
    tab_names = ['时钟', '倒计时', '秒表', '番茄']
    tab_labels = []
    tab_lines = []
    pages = []
    cur_tab = [0]

    def select(i):
        cur_tab[0] = i
        for j in range(4):
            tab_labels[j].configure(fg=ui.TEXT if j == i else ui.SUB)
            if j == i:
                tab_lines[j].place(x=14 + j * 94 + 12, y=30, width=64, height=3)
                pages[j].tkraise()
            else:
                tab_lines[j].place_forget()

    for i, nm in enumerate(tab_names):
        lbl = tk.Label(strip, text=nm, font=ui.font(9.5), bg=ui.BG, fg=ui.SUB, cursor='hand2')
        lbl.place(x=14 + i * 94, y=6, width=88, height=28)
        lbl.bind('<Button-1>', lambda e, i=i: select(i))
        tab_labels.append(lbl)
        tab_lines.append(tk.Frame(strip, bg=ui.ACCENT))
    for i in range(4):
        p = tk.Frame(content, bg=ui.BG)
        p.place(x=0, y=40, width=400, height=322)
        pages.append(p)

    # =========================================================
    #  page 0: 时钟 (秒环 / 闹钟 / 整点报时)
    # =========================================================
    p0 = pages[0]
    lbl_time = tk.Label(p0, text='00:00:00', font=ui.font(40), fg=ui.GREEN, bg=ui.BG, anchor='center')
    lbl_time.place(x=0, y=16, width=400, height=58)
    lbl_date = tk.Label(p0, text='', font=ui.font(10.5), fg=ui.SUB, bg=ui.BG, anchor='center')
    lbl_date.place(x=0, y=78, width=400, height=22)
    lbl_dayof = tk.Label(p0, text='', font=ui.font(8.5), fg=ui.SUB, bg=ui.BG, anchor='center')
    lbl_dayof.place(x=0, y=100, width=400, height=18)
    ring_clock = tk.Canvas(p0, width=140, height=140, bg=ui.BG, bd=0, highlightthickness=0)
    ring_clock.place(x=130, y=126)

    def draw_clock_ring():
        ring_clock.delete('all')
        ring_clock.create_oval(8, 8, 132, 132, outline=ui.SURF2, width=7)
        now = datetime.datetime.now()
        pct = (now.second * 1000.0 + now.microsecond / 1000.0) / 60000.0
        if pct > 0.0005:
            ring_clock.create_arc(8, 8, 132, 132, start=90, extent=-360.0 * pct,
                                  style='arc', outline=ui.GREEN, width=7)
        ring_clock.create_text(70, 70, text=str(now.second), font=ui.font(26), fill=ui.TEXT)

    def toggle_hourly():
        CFG['hourly'] = not CFG['hourly']
        save_cfg()
        chk_hourly.configure(text='整点报时: 开' if CFG['hourly'] else '整点报时: 关',
                             fg=ui.GREEN if CFG['hourly'] else ui.SUB)

    chk_hourly = ui.flat_button(p0, '', toggle_hourly, x=16, y=282, w=118, h=32)
    chk_hourly.configure(text='整点报时: 开' if CFG['hourly'] else '整点报时: 关',
                         fg=ui.GREEN if CFG['hourly'] else ui.SUB)
    tk.Label(p0, text='闹钟', font=ui.font(9), fg=ui.SUB, bg=ui.BG, anchor='w').place(
        x=144, y=288, width=40, height=22)
    lbl_al_summary = tk.Label(p0, text='', font=ui.font(8.5), fg=ui.SUB, bg=ui.BG, anchor='w')
    lbl_al_summary.place(x=184, y=288, width=104, height=22)

    def refresh_alarm_summary():
        with _CFG_LOCK:
            items = list(ALARMS)
        enabled = 0
        nxt = ''
        for a in items:
            if a['enabled']:
                enabled += 1
                if not nxt or a['time'] < nxt:
                    nxt = a['time']
        lbl_al_summary.configure(text='未设置' if not items else
                                 '%d个开启%s' % (enabled, ' · ' + nxt if nxt else ''))

    btn_manage = ui.flat_button(p0, '管理闹钟', lambda: show_alarm_manager(refresh_alarm_summary),
                                x=292, y=282, w=92, h=32)
    btn_manage.configure(fg=ui.ACCENT)
    refresh_alarm_summary()

    # =========================================================
    #  page 1: 倒计时 (圆环 / 预设 / 自定义提醒)
    # =========================================================
    p1 = pages[1]
    cd = {'total': 25 * 60.0, 'remain': 25 * 60.0, 'target': 0.0,
          'running': False, 'paused': False, 'flash': 0, 'state': '就绪'}

    ring_cd = tk.Canvas(p1, width=180, height=180, bg=ui.BG, bd=0, highlightthickness=0)
    ring_cd.place(x=110, y=8)

    def draw_cd_ring():
        ring_cd.delete('all')
        ring_cd.create_oval(9, 9, 171, 171, outline=ui.SURF2, width=9)
        pct = cd['remain'] / cd['total'] if cd['total'] > 0 else 0
        flashing = cd['flash'] > 0
        arc_color = ui.RED if (flashing and cd['flash'] % 2 == 1) else ui.ORANGE
        if pct > 0.0005:
            ring_cd.create_arc(9, 9, 171, 171, start=90, extent=-360.0 * pct,
                               style='arc', outline=arc_color, width=9)
        main = CFG['reminder'] if flashing else fmt_cd(cd['remain'])
        mc = arc_color if flashing else ui.ORANGE
        ring_cd.create_text(90, 72, text=main, font=ui.font(26), fill=mc)
        ring_cd.create_text(90, 110, text=cd['state'], font=ui.font(8.5), fill=ui.SUB)

    ed_min = ui.rounded_entry(p1, x=16, y=201, w=46, h=28, initial='25')
    tk.Label(p1, text='分', font=ui.font(9), fg=ui.SUB, bg=ui.BG, anchor='w').place(
        x=68, y=206, width=20, height=20)
    ed_rm = ui.rounded_entry(p1, x=16, y=237, w=368, h=28, initial=CFG['reminder'])

    def save_reminder(_=None):
        CFG['reminder'] = ed_rm.get().strip() or '休息一下'
        save_cfg()
    ed_rm.bind('<FocusOut>', save_reminder)

    def cd_go():
        if cd['running']:
            cd['running'] = False
            cd['paused'] = True
            btn_cd_go.configure(text='继续')
            cd['state'] = '已暂停'
            return
        if cd['paused']:
            cd['target'] = time.time() + cd['remain']
            cd['running'] = True
            cd['paused'] = False
            btn_cd_go.configure(text='暂停')
            cd['state'] = '进行中'
            return
        try:
            m = float(ed_min.get().strip())
            if m <= 0:
                m = 25.0
        except (ValueError, TypeError):
            m = 25.0
        save_reminder()
        cd['total'] = m * 60.0
        cd['remain'] = cd['total']
        cd['target'] = time.time() + cd['remain']
        cd['running'] = True
        cd['paused'] = False
        btn_cd_go.configure(text='暂停')
        cd['state'] = '进行中'

    def cd_reset():
        cd['running'] = False
        cd['paused'] = False
        cd['flash'] = 0
        try:
            m = float(ed_min.get().strip())
            if m <= 0:
                m = 25.0
        except (ValueError, TypeError):
            m = 25.0
        cd['total'] = m * 60.0
        cd['remain'] = cd['total']
        btn_cd_go.configure(text='开始')
        cd['state'] = '就绪'

    btn_cd_go = ui.flat_button(p1, '开始', cd_go, primary=True, x=16, y=276, w=180, h=36)
    btn_cd_reset = ui.flat_button(p1, '重置', cd_reset, x=204, y=276, w=180, h=36)
    btn_cd_reset.configure(fg=ui.SUB)

    def cd_preset(m):
        ed_min.delete(0, 'end')
        ed_min.insert(0, str(int(m)))
        cd['running'] = False
        cd['paused'] = False
        cd['flash'] = 0
        cd['total'] = m * 60.0
        cd['remain'] = cd['total']
        btn_cd_go.configure(text='开始')
        cd['state'] = '就绪'

    for i, pm_min in enumerate((5, 10, 15, 25, 45)):
        chip = ui.flat_button(p1, str(pm_min), lambda m=pm_min: cd_preset(m),
                              x=86 + i * 44, y=202, w=38, h=26)
        chip.configure(font=ui.font(8.5), fg=ui.SUB)

    # =========================================================
    #  page 2: 秒表 (计次)
    # =========================================================
    p2 = pages[2]
    sw = {'start': 0.0, 'acc': 0.0, 'running': False}
    laps = []

    lbl_sw = tk.Label(p2, text='00:00.0', font=ui.font(40), fg=ui.BLUE, bg=ui.BG, anchor='center')
    lbl_sw.place(x=0, y=22, width=400, height=60)

    def refresh_laps():
        lst_laps.delete(0, 'end')
        for i in range(len(laps) - 1, -1, -1):
            diff = '  (+' + fmt_sw(laps[i] - laps[i - 1]) + ')' if i > 0 else ''
            lst_laps.insert('end', '  #%d   %s%s' % (i + 1, fmt_sw(laps[i]), diff))

    def sw_go():
        if sw['running']:
            sw['acc'] += time.time() - sw['start']
            sw['running'] = False
            btn_sw_go.configure(text='继续')
        else:
            sw['start'] = time.time()
            sw['running'] = True
            btn_sw_go.configure(text='暂停')

    def sw_lap():
        if not sw['running'] and sw['acc'] == 0:
            return
        laps.append(sw['acc'] + (time.time() - sw['start'] if sw['running'] else 0.0))
        refresh_laps()

    def sw_reset():
        sw['acc'] = 0.0
        sw['running'] = False
        btn_sw_go.configure(text='开始')
        laps.clear()
        refresh_laps()

    btn_sw_go = ui.flat_button(p2, '开始', sw_go, primary=True, x=16, y=96, w=118, h=36)
    btn_sw_lap = ui.flat_button(p2, '计次', sw_lap, x=141, y=96, w=118, h=36)
    btn_sw_lap.configure(fg=ui.SUB)
    btn_sw_reset = ui.flat_button(p2, '重置', sw_reset, x=266, y=96, w=118, h=36)
    btn_sw_reset.configure(fg=ui.SUB)
    lst_laps = tk.Listbox(p2, bg=ui.CARD, fg=ui.SUB, font=ui.font(9), bd=0,
                          highlightthickness=1, highlightbackground=ui.BORDER,
                          selectbackground=ui.SURF2, selectforeground=ui.TEXT,
                          activestyle='none')
    lst_laps.place(x=16, y=146, width=368, height=158)

    # =========================================================
    #  page 3: 番茄 (正计时专注 / 统计 / 7日图)
    # =========================================================
    p3 = pages[3]
    pm = {'start': 0.0, 'running': False}
    day_min = [0.0] * 7

    lbl_pm = tk.Label(p3, text='00:00', font=ui.font(40), fg=ui.RED, bg=ui.BG, anchor='center')
    lbl_pm.place(x=0, y=14, width=400, height=56)
    lbl_today = tk.Label(p3, text='今日 0 次 / 0分钟', font=ui.font(9), fg=ui.TEXT, bg=ui.BG, anchor='w')
    lbl_today.place(x=146, y=84, width=240, height=22)
    lbl_total = tk.Label(p3, text='总计 0 次 / 0分钟', font=ui.font(8.5), fg=ui.SUB, bg=ui.BG, anchor='w')
    lbl_total.place(x=146, y=106, width=240, height=18)
    chart = tk.Canvas(p3, width=368, height=108, bg=ui.CARD, bd=0, highlightthickness=1,
                      highlightbackground=ui.BORDER)
    chart.place(x=16, y=136)
    lst_pomo = tk.Listbox(p3, bg=ui.CARD, fg=ui.SUB, font=ui.font(8.5), bd=0,
                          highlightthickness=1, highlightbackground=ui.BORDER,
                          selectbackground=ui.SURF2, selectforeground=ui.TEXT,
                          activestyle='none')
    lst_pomo.place(x=16, y=252, width=368, height=56)

    def draw_chart():
        chart.delete('all')
        mx = 25.0
        for v in day_min:
            if v > mx:
                mx = v
        bw, gap = 28, (368 - 7 * 28) // 8
        today = datetime.date.today()
        for i in range(7):
            x = gap + i * (bw + gap)
            bh = int(70 * day_min[i] / mx)
            if bh < 2 and day_min[i] > 0:
                bh = 2
            chart.create_rectangle(x, 80 - bh, x + bw, 80,
                                   fill=ui.RED if i == 6 else ui.SURF2, outline='')
            day = today + datetime.timedelta(days=i - 6)
            chart.create_text(x + bw // 2, 88, text='周' + _WD[_cs_dow(day)],
                              font=ui.font(7.5), fill=ui.TEXT if i == 6 else ui.SUB, anchor='n')

    def refresh_pomo():
        try:
            for i in range(7):
                day_min[i] = 0.0
            if not os.path.isfile(POMO_PATH):
                lst_pomo.delete(0, 'end')
                lbl_today.configure(text='今日 0 次 / 0分钟')
                lbl_total.configure(text='总计 0 次 / 0分钟')
                draw_chart()
                return
            with open(POMO_PATH, encoding='utf-8-sig') as f:
                lines = f.read().splitlines()
            today_s = datetime.datetime.now().strftime('%Y-%m-%d')
            n_today = n_all = 0
            m_today = m_all = 0.0
            for ln in lines:
                mm = re.match(r'^(\d{4}-\d{2}-\d{2}).*\+(\d+)m', ln)
                if not mm:
                    continue
                v = float(mm.group(2))
                n_all += 1
                m_all += v
                if mm.group(1) == today_s:
                    n_today += 1
                    m_today += v
                try:
                    d = datetime.datetime.strptime(mm.group(1), '%Y-%m-%d').date()
                    ago = (datetime.date.today() - d).days
                    if 0 <= ago < 7:
                        day_min[6 - ago] += v
                except Exception:
                    pass
            lbl_today.configure(text='今日 %d 次 / %s' % (n_today, fmt_minutes(m_today)))
            lbl_total.configure(text='总计 %d 次 / %s' % (n_all, fmt_minutes(m_all)))
            lst_pomo.delete(0, 'end')
            for ln in lines[-3:][::-1]:
                lst_pomo.insert('end', '  ' + ln)
            draw_chart()
        except Exception:
            pass

    def pm_go():
        if not pm['running']:
            pm['start'] = time.time()
            pm['running'] = True
            btn_pm_go.configure(text='结束专注')
            return
        pm['running'] = False
        btn_pm_go.configure(text='开始专注')
        span = time.time() - pm['start']
        mins = int(round(span / 60.0))
        if mins < 1:
            mins = 1
        try:
            os.makedirs(CFG_DIR, exist_ok=True)
            with open(POMO_PATH, 'a', encoding='utf-8', newline='\n') as f:
                f.write('%s +%dm\n' % (datetime.datetime.fromtimestamp(pm['start'])
                                       .strftime('%Y-%m-%d %H:%M'), mins))
        except Exception:
            pass
        refresh_pomo()
        lbl_pm.configure(text='00:00')

    btn_pm_go = ui.flat_button(p3, '开始专注', pm_go, primary=True, x=16, y=78, w=118, h=34)
    refresh_pomo()

    # ---------- 主定时器 (100ms; 秒表运行时 30ms 让毫秒位动起来) ----------
    def tick():
        if not alive[0]:
            return
        try:
            now = datetime.datetime.now()
            lbl_time.configure(text=now.strftime('%H:%M:%S'))
            lbl_date.configure(text='%d年%d月%d日 %s' % (now.year, now.month, now.day, week_cn(now)))
            yday = now.timetuple().tm_yday
            lbl_dayof.configure(text='今年第 %d 天 · 第 %d 周' % (yday, (yday - 1) // 7 + 1))
            draw_clock_ring()
            if cd['running']:
                left = cd['target'] - time.time()
                if left <= 0:
                    cd['running'] = False
                    cd['remain'] = 0.0
                    btn_cd_go.configure(text='开始')
                    _ding(True)
                    cd['flash'] = 12
                    cd['state'] = CFG['reminder']
                    try:
                        win.lift()
                        win.focus_force()
                    except Exception:
                        pass
                else:
                    cd['remain'] = left
            if cd['flash'] > 0:
                cd['flash'] -= 1
            draw_cd_ring()
            el = sw['acc'] + (time.time() - sw['start'] if sw['running'] else 0.0)
            lbl_sw.configure(text=fmt_sw(el))
            if pm['running']:
                lbl_pm.configure(text=fmt_cd(time.time() - pm['start']))
        except Exception:
            pass
        if alive[0]:
            try:
                tick_id[0] = win.after(30 if sw['running'] else 100, tick)
            except Exception:
                alive[0] = False

    select(0)
    tick_id[0] = win.after(100, tick)
