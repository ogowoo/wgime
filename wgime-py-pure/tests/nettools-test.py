# -*- coding: utf-8 -*-
r"""网络工具窗体回归 (第九十一轮): 每个页签的输出必须落在**自己页**的控制台里.

历史 bug(自首次迁移起就存在): `show_nettools()` 里 7 个页签的处理函数都是闭包, 引用的 `log`
是**同一个函数局部变量**, 被 `p, top, log = make_page(...)` 重复绑定 7 次 —— 闭包捕获的是变量不是值,
所以**所有页签的按钮输出全写进最后一页(本机)的日志**: 用户在 Ping/子网/… 页点按钮, 永远看不到结果
(用户原话: "做子网查询等等完全看不到结果")。修法: 每个处理函数默认参数绑定 `log=log`。

本测试: 打桩所有网络出口(不联网), 逐页真点击(或事件)驱动, 断言输出落在**本页**且**本机页不被污染**。
无桌面(SKIP 整体)。

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

    steps = []

    def step(ms, name, fn):
        steps.append((ms, name, fn))

    # 子网页: 同步处理器
    step(200, '子网 chip', lambda: click(chip('子网')))
    step(150, '子网 拆分', lambda: click(chip('拆分')))
    step(150, '子网 速查表', lambda: click(chip('速查表')))
    step(150, '子网 ▶', lambda: click(chip('▶')))
    # Ping 页: 次数改成 1 再点(省时间)
    def ping_page():
        click(chip('Ping', 0))

    def ping_set_cnt():
        cnt = [w for w in chips]  # noqa
        pass

    def ping_click():
        click(chip('Ping', 1))

    step(150, 'Ping chip', ping_page)
    step(150, 'Ping 按钮', ping_click)
    step(2500, '等 ping', lambda: None)
    # Tracert
    step(100, 'Tracert chip', lambda: click(chip('Tracert')))
    step(100, 'Tracert 开始', lambda: click(chip('开始路由跟踪')))
    step(900, '等 tracert', lambda: None)
    # DNS
    step(100, 'DNS chip', lambda: click(chip('DNS')))
    step(100, 'DNS 查询', lambda: click(chip('查询')))
    step(700, '等 dns', lambda: None)
    # 端口
    step(100, '端口 chip', lambda: click(chip('端口')))
    step(100, '端口 检测', lambda: click(chip('检测')))
    step(700, '等端口', lambda: None)
    # HTTP
    step(100, 'HTTP chip', lambda: click(chip('HTTP')))
    step(100, 'HTTP 请求', lambda: click(chip('请求')))
    step(700, '等 http', lambda: None)
    # 本机
    step(100, '本机 chip', lambda: click(chip('本机')))

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
        click([c for c in chips if str(c.cget('text')) == '清除' and c.winfo_ismapped()][0])
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
        # 换页后缓冲还在 (独立缓冲)
        check('缓冲独立: 子网页内容切走切回不丢', '192.168.1.64/26' in text(5))
        win.destroy()
        root.quit()

    def run_next():
        if not steps:
            report()
            return
        ms, _name, fn = steps.pop(0)
        try:
            fn()
        except Exception as ex:
            check('步骤 %s 不抛异常' % _name, False, repr(ex))
        if steps:
            win.after(ms, run_next)
        else:
            win.after(ms, report)

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
