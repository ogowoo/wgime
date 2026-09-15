# -*- coding: utf-8 -*-
"""tray-swap-test.py — 托盘"换图"状态机回归（第五十七轮的真 bug，纯桩、不碰真托盘）.

为什么要有它
------------
第五十六轮把"换图成没成"判成了 `bool(icon._message(...))`，而 **pystray 的 `_win32._message()`
调完 `Shell_NotifyIcon` 根本没有 return** —— `bool(None)` 恒为 False。后果两个：
① `_cur_key` 永不推进，于是"同 key 就只刷菜单"的分支拿旧状态当"图标已经是新的" ->
   切回混合模式 / 打开输入法时**图标纹丝不动**（用户报"现在托盘图标都不会变了"、
   "混合的模式切换不过去" —— 空闲隐藏下候选条不显示，托盘图标是切模式**唯一**的反馈）；
② 旧句柄永不销毁 -> 每刷新一次漏一个 HICON。

**本文件的假 icon 严格照抄真 pystray 的语义：`_message()` 返回 `None`。**
第五十三轮那个探针的假 icon `return True`，比现实宽松，所以漏掉了这个回归 ——
**桩不能比真的更宽容**，这是本文件存在的全部理由。

跑法:  python wgime-py-pure\\tests\\tray-swap-test.py
"""
import os
import sys
import types

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BASE)

# ---------------------------------------------------------------- 假 win 模块
# tray.py 内部用 `import win as _w`, 所以先把它换成一个假的 (记录造/销毁的句柄)。
class FakeWin(types.ModuleType):
    def __init__(self):
        super().__init__('win')
        self.created = []      # (key, h) 每次 icon_from_ico_bytes 的结果
        self.destroyed = []    # destroy_icon 收到的句柄
        self._next = 1000

    def icon_from_ico_bytes(self, data, key):
        self._next += 1
        self.created.append((key, self._next))
        return self._next

    def destroy_icon(self, h):
        self.destroyed.append(h)
        return True

    def dfn_always(self, *a, **k):
        pass

    def _dlog(self, *a, **k):
        pass

    def __getattr__(self, name):          # 其它 win.x(): 无害空实现
        return lambda *a, **k: None


WIN = FakeWin()
sys.modules['win'] = WIN

import tray                                                          # noqa: E402


# ---------------------------------------------------------------- 桩
class FakeIcon:
    """够真实: `_message()` **不返回**(同 pystray); `visible` 模拟 NIM_ADD 前后。"""

    def __init__(self):
        self.visible = False
        self._icon = None
        self._icon_handle = None
        self._icon_valid = False
        self.menu_updates = 0
        self.messages = []           # (code, flags, hIcon)
        self.last_return = 'unset'
        self.modify_result = True    # 模拟 shell 对 NIM_MODIFY 的回答

    def update_menu(self):
        self.menu_updates += 1

    def _message(self, code, flags, **kw):
        h = kw.get('hIcon')
        self.messages.append((int(code), int(flags), h))
        if int(code) == 1 and (int(flags) & 0x2):        # NIM_MODIFY | NIF_ICON
            tray.NIM['modify_ok'] = bool(self.modify_result)
        self.last_return = None
        return None                  # <-- 真 pystray 就是这样: 没有 return


class BadVisibleIcon(FakeIcon):
    @property
    def visible(self):
        raise RuntimeError('visible 读失败')

    @visible.setter
    def visible(self, v):
        pass                     # FakeIcon.__init__ 会写它; 忽略即可(读的时候才炸)


class FakeRoot:
    def __init__(self):
        self.after_calls = []

    def after(self, ms, fn):
        self.after_calls.append((ms, fn))
        return 'after-id-%d' % len(self.after_calls)


MODE = [0]          # 可变单元: 当前模式
ACTIVE = [True]
RUNMODE = ['ime']


def make(icon=None, mode=0, active=True):
    MODE[0], ACTIVE[0], RUNMODE[0] = mode, active, 'ime'
    WIN.created, WIN.destroyed = [], []
    root = FakeRoot()
    api = {'get_mode': lambda: MODE[0], 'is_active': lambda: ACTIVE[0],
           'get_runmode': lambda: RUNMODE[0]}
    t = tray.Tray(root, api)
    ic = icon if icon is not None else FakeIcon()
    ic.messages, ic.menu_updates = [], 0
    t.icon = ic
    return t, ic, root


# ---------------------------------------------------------------- 断言
PASS = [0]
FAIL = [0]


def ok(cond, label):
    if cond:
        PASS[0] += 1
        print('  OK   %s' % label)
    else:
        FAIL[0] += 1
        print('  ** FAIL ** %s' % label)


def section(title):
    print('\n--- %s ---' % title)


# 内嵌图标可用 -> 走 tray.py 的 HICON 路径 (否则会走 PIL 分支, 那就不是本测试的对象)
tray._embedded_icons = lambda: {'0a': 'AA==', '4a': 'AA==', 'tool': 'AA=='}

print('tray-swap-test: 托盘换图状态机回归 (假 icon 照抄真 pystray: _message() 不返回)')

# ================================================================ A 未登记不上图
section('A. 图标还没登记上(visible=False)时绝不换图 —— 第五十六轮的回归点')
t, ic, root = make(mode=0)
ic.visible = False
t._refresh()
ok(len(ic.messages) == 0, 'A1 未登记: 不发 NIM_MODIFY')
ok(len(WIN.destroyed) == 0, 'A2 未登记: 不销毁任何句柄(shell 还没认识我们)')
ok(t._cur_key is None, 'A3 未登记: 不推进 _cur_key')
ok(len(root.after_calls) == 1 and root.after_calls[0][0] == 150, 'A4 未登记: 安排一次 150ms 重试')
ok(ic.menu_updates == 1, 'A5 未登记: 仍然刷新菜单勾选态')
t._refresh()
ok(len(root.after_calls) == 1, 'A6 仍未登记: 不重复安排重试')
ic.visible = True
t._refresh()
ok(t._retry_pending[0] is False, 'A7 登记后: _retry_pending 复位')
ok(len(ic.messages) == 1, 'A8 登记后: 正常换图')

# ================================================================ B 换图成功
section('B. 换图成功路径(shell 接受)')
t, ic, root = make(mode=0)
ic.visible = True
t._refresh()
ok(len(ic.messages) == 1, 'B1 发了一次 NIM_MODIFY')
ok(ic.messages[0][0] == 1 and (ic.messages[0][1] & 0x2), 'B2 code=NIM_MODIFY(1) 且 flags 含 NIF_ICON')
h = ic._icon_handle
ok(ic.messages[0][2] == h, 'B3 hIcon 就是注入的新句柄')
ok(t._cur_key == '0a', 'B4 _cur_key 推进到 0a')
ok(t._shown_key == '0a', 'B5 _shown_key 推进')
ok(t._shown_handle == h, 'B6 _shown_handle = 新句柄')
ok(ic.last_return is None and t._shown_key == '0a',
   'B7 ★ 假 icon 返回 None 而状态仍推进 -> 证明判据是 NIM[modify_ok] 而不是 _message() 的返回值')

# ================================================================ C 同 key 只刷菜单
section('C. 同一张图重复刷新: 不惊动 shell、不重建 HICON')
n_msg, n_created, n_menu = len(ic.messages), len(WIN.created), ic.menu_updates
t._refresh()
ok(len(ic.messages) == n_msg, 'C1 同 key: 不再发 NIM_MODIFY')
ok(len(WIN.created) == n_created, 'C2 同 key: 不重建 HICON')
ok(ic.menu_updates == n_menu + 1, 'C3 同 key: 仍然刷新菜单勾选态')

# ================================================================ D shell 拒收
section('D. shell 拒收(NIM_MODIFY 返回假)时不谎报, 下次用同一句柄补发')
t, ic, root = make(mode=0)
ic.visible = True
t._refresh()                       # 先建立"已显示 0a"的状态
h0 = t._shown_handle
ok(h0 is not None and t._shown_key == '0a', 'D1 前置: 已显示 0a')
ic.modify_result = False           # shell 开始拒收
MODE[0] = 4                        # 切到「语音」
t._refresh()
ok(t._cur_key == '4a', 'D2 拒收时 _cur_key 仍推进(pystray 侧句柄确实换了)')
ok(t._shown_key == '0a', 'D3 拒收时 _shown_key 不推进(不谎报)')
ok(t._shown_handle == h0, 'D4 拒收时 _shown_handle 保持旧句柄')
ok(len(WIN.destroyed) == 0, 'D5 拒收时不销毁旧句柄(先销毁会让 shell 引用野句柄)')
h_new = ic._icon_handle
ok(h_new != h0, 'D6 新句柄已注入 pystray')
n_msg, n_created = len(ic.messages), len(WIN.created)
ic.modify_result = True            # shell 恢复
t._refresh()
ok(len(ic.messages) == n_msg + 1, 'D7 下一次刷新: 补发一次 NIM_MODIFY')
ok(ic.messages[-1][2] == h_new, 'D8 补发用的是**同一个**句柄(不重建)')
ok(len(WIN.created) == n_created, 'D9 补发不重新造 HICON')
ok(t._shown_key == '4a', 'D10 补发被接受后 _shown_key 跟上')
ok(t._shown_handle == h_new, 'D11 接受后才销毁旧的 _shown_handle')
ok(WIN.destroyed == [h0], 'D12 销毁的正是旧句柄本身')

# ================================================================ E 模式来回切
section('E. 模式来回切, 图标必须每次都变(用户报"图标都不会变了"的场景)')
t, ic, root = make(mode=0)
ic.visible = True
t._refresh()                       # 混合 -> 0a
m0 = len(ic.messages)
MODE[0] = 4
t._refresh()                       # -> 语音 4a
m1 = len(ic.messages)
MODE[0] = 0
t._refresh()                       # -> 回混合 0a (原 bug: 这里被"同 key"分支拦住, 图标不动)
m2 = len(ic.messages)
ok(m1 == m0 + 1, 'E1 混合 -> 语音: 换图发生了')
ok(m2 == m1 + 1, 'E2 语音 -> 混合: 换图也发生了(原 bug 就在这一步纹丝不动)')
ok(t._cur_key == '0a' and t._shown_key == '0a', 'E3 回到混合后两个 key 状态一致')

# ================================================================ F 句柄不泄漏
section('F. GDI 句柄不泄漏')
t, ic, root = make(mode=0)
ic.visible = True
for i in range(5):
    MODE[0] = i
    t._refresh()
ok(len(WIN.created) == 5, 'F1 5 次换图造了 5 个 HICON')
ok(len(WIN.destroyed) == 4, 'F2 每次销毁"上一个已显示"的句柄 -> 共 4 次, 无累积泄漏')
ok(t._shown_handle not in WIN.destroyed, 'F3 当前正显示的句柄没有被销毁')
t, ic, root = make(mode=0)
ic.visible = True
ic.modify_result = False           # shell 全程拒收
for i in range(5):
    MODE[0] = i
    t._refresh()
ok(len(WIN.destroyed) == 0, 'F4 shell 全程拒收时一个句柄都不销毁(宁可留着也不给野句柄)')

# ================================================================ G 边界
section('G. 边界')
t, ic, root = make(mode=0)
ic.visible = True
t.icon = None
try:
    t._refresh()
    ok(True, 'G1 icon=None 时 _refresh 安全返回')
except Exception as e:
    ok(False, 'G1 icon=None 时抛异常: %r' % (e,))
t, ic, root = make(icon=BadVisibleIcon(), mode=0)
try:
    t._refresh()
    ok(len(ic.messages) == 0 and len(WIN.destroyed) == 0,
       'G2 visible 读失败当作"未登记": 不换图、不销毁(不抛)')
except Exception as e:
    ok(False, 'G2 visible 读失败时抛异常: %r' % (e,))

# ================================================================ H key 映射
section('H. 图标 key 映射(防第五十一轮 `% 4` 那种退化)')
t, ic, root = make(mode=0)
ok(t._key_for(4, True) == '4a', 'H1 语音模式(4) 的 key 是 4a —— 5 个模式不许退化成 0a')
ok(t._key_for(0, False) == '0i', 'H2 未激活用 i 后缀')
RUNMODE[0] = 'tray'
ok(t._key_for(0, True) == 'tool', 'H3 tray 模式统一用 tool')

# ---------------------------------------------------------------- 汇总
print('\n' + '=' * 60)
print('tray-swap-test: %d 通过, %d 失败 (共 %d 项)' % (PASS[0], FAIL[0], PASS[0] + FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
