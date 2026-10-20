# -*- coding: utf-8 -*-
r"""网络工具窗体回归 (第九十一轮): 每个页签的输出必须落在**自己页**的控制台里.

历史 bug(自首次迁移起就存在): `show_nettools()` 里 7 个页签的处理函数都是闭包, 引用的 `log`
是**同一个函数局部变量**, 被 `p, top, log = make_page(...)` 重复绑定 7 次 —— 闭包捕获的是变量不是值,
所以**所有页签的按钮输出全写进最后一页(本机)的日志**: 用户在 Ping/子网/… 页点按钮, 永远看不到结果
(用户原话: "做子网查询等等完全看不到结果")。修法: 每个处理函数默认参数绑定 `log=log`。

本测试: 打桩所有网络出口(不联网), 逐页**真点击**驱动, 断言输出落在**本页**且**本机页不被污染**。
驱动方式是"等条件"而不是"等固定毫秒": 点页签后等该页 Text 变成 mapped 再点按钮、点完等该页 Text
出现预期内容 —— 否则切页尚未映射时 `event_generate` 会丢事件(第九十一轮补真踩过这个 flaky)。
全程留在 `mainloop()` 里(后台线程的 `win.after` 只有在真 mainloop 下才合法)。

跑法: python wgime-py-pure\tests\nettools-test.py
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
sys.path.insert(0, PURE)

fails = []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-52s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def main():
    try:
        import tkinter as tk
        r = tk.Tk()
        r.destroy()
    except Exception as ex:
        print('SKIP: 没有可用桌面/Tk (%r)' % (ex,))
        return 0

    import tkinter as tk
    import tools

    # 打桩网络出口(测试自足, 不联网)
    tools.ping_rtt = lambda h, sz, ms: (True, 12)
    tools.hop_once = lambda h, ttl, ms: ('  ttl=%d  1.2.3.4  12ms' % ttl, ttl >= 3)
    tools.dns_query = lambda nm, tp, sv, ms: ['  %s %s = 1.2.3.4' % (tp, nm)]
    tools.test_port = lambda h, pt, ms: 'open'
    tools.http_check = lambda u, ms: ['  200 OK', '  TTFB 30ms']
    tools.local_net_info = lambda: '适配器(打桩)\n  IPv4: 10.0.0.1 / 255.255.255.0'
    tools.public_ip = lambda ms: '1.2.3.4(打桩)'

    # 偷梁换柱: 收集 7 个 _NetLog 实例 (顺序 = 页签顺序 Ping/Tracert/DNS/HTTP/端口/子网/本机)
    built = []
    orig_init = tools._NetLog.__init__

    def spy_init(self, *a, **kw):
        orig_init(self, *a, **kw)
        built.append(self)

    tools._NetLog.__init__ = spy_init

    root = tk.Tk()
    root.withdraw()
    tools.show_nettools()
    win = [w for w in root.winfo_children() if isinstance(w, tk.Toplevel)][-1]

    chips = []

    def walk(w):
        for c in w.winfo_children():
            walk(c)
            if isinstance(c, tk.Label) and str(c.cget('cursor')) == 'hand2':
                chips.append(c)

    walk(win)

    def chip(name, idx=0):
        out = [c for c in chips if str(c.cget('text')) == name]
        return out[idx] if len(out) > idx else None

    def click(w):
        w.event_generate('<ButtonPress-1>')
        w.event_generate('<ButtonRelease-1>')

    def text(i):
        return built[i].tb.get('1.0', 'end')

    def visible(i):
        def c():
            try:
                return bool(built[i].tb.winfo_ismapped())
            except Exception:
                return False
        return c

    def got(i, needle):
        def c():
            try:
                return needle in text(i)
            except Exception:
                return False
        return c

    jobs = []

    def job(desc, fn, cond, timeout=3.0):
        jobs.append((desc, fn, cond, timeout))

    def run_next():
        if not jobs:
            report()
            return
        desc, fn, cond, timeout = jobs.pop(0)
        try:
            # 关键: 先让 Tk 画一轮再点。刚 place 出来的页(切页后)若还没经过一次绘制,
            # `event_generate` 的事件会被丢掉(真鼠标点击不受影响 —— 这只是测试驱动的问题)。
            # 第九十一轮补实测: 少了这句, 第 2~5 个页签的按钮点击全丢(稳定 4/14 红)。
            win.update()
            fn()
        except Exception as ex:
            check('步骤 %s 不抛异常' % desc, False, repr(ex))
        t0 = time.time()

        def wait():
            win.update()            # 同上: 等条件期间也让它继续画
            if cond() or time.time() - t0 > timeout:
                run_next()
            else:
                win.after(30, wait)

        win.after(30, wait)

    # --- 子网(全同步) ---
    job('切子网', lambda: click(chip('子网', 0)), visible(5), 2.0)
    job('点拆分', lambda: click(chip('拆分')), got(5, '192.168.1.64/26'))
    job('点速查表', lambda: click(chip('速查表')), got(5, '/32'))
    job('点范围转CIDR', lambda: click(chip('▶')), got(5, '-- 范围转 CIDR --'))
    # --- Ping ---
    job('切Ping', lambda: click(chip('Ping', 0)), visible(0), 2.0)
    job('点Ping按钮', lambda: click(chip('Ping', 1)), got(0, '统计:'), 8.0)
    # --- Tracert ---
    job('切Tracert', lambda: click(chip('Tracert')), visible(1), 2.0)
    job('点开始路由跟踪', lambda: click(chip('开始路由跟踪')), got(1, 'ttl=3'))
    # --- DNS ---
    job('切DNS', lambda: click(chip('DNS')), visible(2), 2.0)
    job('点查询', lambda: click(chip('查询')), got(2, 'A www.baidu.com = 1.2.3.4'))
    # --- 端口 ---
    job('切端口', lambda: click(chip('端口')), visible(4), 2.0)
    job('点检测', lambda: click(chip('检测')), got(4, 'open'))
    # --- HTTP ---
    job('切HTTP', lambda: click(chip('HTTP')), visible(3), 2.0)
    job('点请求', lambda: click(chip('请求')), got(3, '200 OK'))
    # --- 本机 ---
    job('切本机', lambda: click(chip('本机')), visible(6), 2.0)

    def report():
        ben = text(6)
        check('7 个页签 / 7 个独立日志缓冲', len(built) == 7)
        check('子网: 初始计算开窗即有', '掩码' in built[5].tb.get('1.0', 'end'))
        check('子网: 拆分落在本页', '192.168.1.64/26' in text(5))
        check('子网: 速查表落在本页', '/32' in text(5))
        check('子网: 范围转 CIDR 落在本页', '-- 范围转 CIDR --' in text(5))
        ping_txt = text(0)          # 先取证, 再验清除
        check('Ping: 回复与统计落在本页', 'reply: seq=' in ping_txt and '统计:' in ping_txt,
              repr(ping_txt[-120:]))
        click(chip('Ping', 0))      # 切回 Ping 页再点清除
        win.update()
        clears = [c for c in chips if str(c.cget('text')) == '清除' and c.winfo_ismapped()]
        if clears:
            click(clears[0])
        win.update()                # 清除走 after(0) marshal: update() 才会收(update_idletasks 不收)
        win.update()
        check('Ping: 清除清的是本页', len(text(0).strip()) <= 1, repr(text(0)[:60]))
        check('Tracert: 跳数落在本页', 'ttl=3' in text(1))
        check('DNS: 查询结果落在本页', 'A www.baidu.com = 1.2.3.4' in text(2))
        check('HTTP: 200/TTFB 落在本页', '200 OK' in text(3))
        check('端口: 检测结果落在本页', 'open' in text(4))
        check('本机: 自己内容在(打桩适配器)', '适配器(打桩)' in ben and '公网 IP' in ben)
        check('本机: **没有**被别的页污染 (核心回归)',
              '/26' not in ben and 'reply' not in ben and 'ttl=' not in ben
              and '200 OK' not in ben and '1.2.3.4 = ' not in ben,
              repr(ben[-120:]))
        check('缓冲独立: 子网页内容切走切回不丢', '192.168.1.64/26' in text(5))
        win.destroy()
        root.quit()

    win.after(300, run_next)
    root.mainloop()
    root.destroy()

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
