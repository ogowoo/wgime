# -*- coding: utf-8 -*-
"""chat-interop-test.py — 纯 Python chat 插件与 Node 参考端 (relay) 互通验证."""
import os
import subprocess
import sys
import threading
import time
import tkinter as tk

BASE = 'C:/Tools/wgime-py-pure'
sys.path.insert(0, BASE)
sys.path.insert(0, BASE + '/plugins')
os.chdir(BASE)

# 启动插件窗口 (无 IME, 直接驱动)
import chat  # noqa: E402
root = tk.Tk()
root.withdraw()
chat.run()
c = chat._current
c.nick.delete(0, 'end'); c.nick.insert(0, 'PyChat')
c.room.delete(0, 'end'); c.room.insert(0, 'wgtestpure')
c.key.delete(0, 'end'); c.key.insert(0, '')
c.broker.set('wss://chat.seee.uno')

# 拦截收到的消息
got = []
orig = c.add_msg
c.add_msg = lambda t: got.append(t)
root.after(100, c.join)

# Node 参考端 (relay, 同房间, 每 5s 发一条)
node = subprocess.Popen(['node', r'C:\Tools\wgime\tests\interop\ref-client.js', 'relay', 'wss://chat.seee.uno',
                         'wgtestpure', 'NodeRef', 'nokey', '12000', 'hello-from-python-pure'],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8', creationflags=0x08000000)

t0 = time.time()
out = []
while time.time() - t0 < 24:
    root.update()
    time.sleep(0.1)
    try:
        line = node.stdout.readline()
        if line:
            out.append(line.strip())
    except Exception:
        pass

# 关闭
c.state['running'] = False
try:
    if c.state['ws']:
        c.state['ws'].close()
except Exception:
    pass
root.destroy()
node.kill()

print('--- plugin received ---')
for g in got:
    print(repr(g))
print('--- node saw ---')
for o in out:
    if 'chat' in o or 'WgIme' in o or 'PyChat' in o:
        print(o)
received = any('hello-from-python-pure' in g for g in got)
print('INTEROP PASS' if received else 'INTEROP FAIL')
