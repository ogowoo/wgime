# -*- coding: utf-8 -*-
r"""自动更新回归 (第八十五轮): 假 GitHub 服务器 + 真替换助手, 不碰外网.

**被测**: `wgime-py-pure\update.py`(检查/下载/校验) 与它的 detached 助手(等进程退出 → 备份 → 原子替换 → 重启)。

判据四组:
  S 纯函数: 版本号解析/比较(任一边解析不出就**不更新**)、单文件判据(`is_single_file`)、
    release body 里的 SHA256 抠取、镜像前缀;
  A 检查/下载(打**本地假服务器**): 有新版本 -> 计划里带版本/资产/sha256; 已是最新 -> None;
    raw 路成功; raw 坏 -> **自动退到发行包**; 发行包 sha 不符 -> 拒绝; 两条路都坏 -> 报两条原因;
    下载到的东西版本比当前旧 / 太短 / 是 HTML -> 一律拒绝且**不留 .new**;
  B 替换助手(真跑它): 目标进程已退出 -> 备份 + 原子替换; 目标进程还活着 -> **先等它退出**再替换;
    新文件不存在 -> 拒绝(退出码非 0)且目标文件原样;
  C 端到端: `spawn_apply()`(真拉起 detached 助手, relaunch 留空) -> 文件被换掉。

跑法: python wgime-py-pure\tests\update-test.py
"""
import hashlib
import http.server
import io
import json
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
sys.path.insert(0, PURE)
import update as u          # noqa: E402

fails, n = [], [0]

TAG = 'v9.9.9'
ASSET = 'wgime-v9.9.9-python.zip'
RAW_PATH_SUFFIX = 'wgime-py-pure/dist/wgime-py.py'


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-58s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def fake_single(version='9.9.9-py', pad=210 * 1024):
    """一个"长得像单文件"的假货: 三个标记 + VERSION + 能 compile + 体积过线。"""
    head = "# -*- coding: utf-8 -*-\n\"\"\"fake single file (update-test)\"\"\"\n"
    core = ("VERSION = '%s'\nMODULES = {'win': 'x'}\nPLUGIN_SRC = {}\nTHIRD_ZIP_B64 = 'AAAA'\n"
            % version)
    filler = '# ' + 'x' * 74 + '\n'
    text = head + core
    while len(text.encode('utf-8')) < pad:
        text += filler
    return text.encode('utf-8')


RAW_OK = fake_single()
RAW_OLD = fake_single('1.0.0-py')
RAW_HTML = b'<html><body>404 not found</body></html>'


def make_zip(inner):
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('wgime-py.py', inner)
        z.writestr('config.txt', 'voice = 0\n')
    return bio.getvalue()


ZIP_OK = make_zip(RAW_OK)
ZIP_BAD = make_zip(RAW_HTML)

STATE = {'raw': RAW_OK, 'zip': ZIP_OK, 'sha_in_body': True, 'fail_raw': False}


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'      # 不用 keep-alive: 免得 urllib 读完就关连接把服务端日志刷成一片 reset

    def log_message(self, *a):
        pass

    def _send(self, body, ctype='application/octet-stream', code=200):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        p = self.path
        if p.endswith('/releases/latest'):
            sha = hashlib.sha256(STATE['zip']).hexdigest().upper()
            body_md = ('## WgIme v9.9.9\n\n| 文件 | 说明 | SHA256 |\n|---|---|---|\n'
                       '| `%s` | 纯 Python 版 | `%s` |\n' % (ASSET, sha if STATE['sha_in_body'] else '0' * 64))
            rel = {'tag_name': TAG, 'name': 'WgIme v9.9.9', 'body': body_md, 'draft': False,
                   'prerelease': False,
                   'assets': [{'name': ASSET, 'size': len(STATE['zip']),
                               'browser_download_url': BASE + '/dl/' + ASSET}]}
            self._send(json.dumps(rel).encode('utf-8'), 'application/json')
        elif p.endswith(RAW_PATH_SUFFIX):
            if STATE['fail_raw']:
                self._send(b'boom', 'text/plain', 500)
            else:
                self._send(STATE['raw'])
        elif p.endswith(ASSET):
            self._send(STATE['zip'])
        else:
            self._send(b'nope', 'text/plain', 404)


srv = socketserver.ThreadingTCPServer(('127.0.0.1', 0), H)
srv.daemon_threads = True
PORT = srv.server_address[1]
BASE = 'http://127.0.0.1:%d' % PORT
threading.Thread(target=srv.serve_forever, daemon=True).start()
print('假 GitHub: %s' % BASE)

# ---------------- S: 纯函数 ----------------
print('--- S. 纯函数 ---')
check('版本号解析', (u.parse_version('v1.2.14'), u.parse_version('1.2.14-py'), u.parse_version('x')) ==
      ((1, 2, 14), (1, 2, 14), ()))
check('严格更新判断', (u.is_newer('v1.2.15', '1.2.14-py'), u.is_newer('v1.2.14', '1.2.14'),
                      u.is_newer('garbage', '1.2.14'), u.is_newer('v2.0.0', 'garbage')) ==
      (True, False, False, False))
_tmp = tempfile.mkdtemp(prefix='wg-upd-')
_f1 = os.path.join(_tmp, 'fake.py')
open(_f1, 'wb').write(RAW_OK)
check('is_single_file(带 MODULES 的文件)=True', u.is_single_file(_f1) is True)
check('is_single_file(源码 main.py)=False', u.is_single_file(os.path.join(PURE, 'main.py')) is False)
check('version_in_text 抠得出版本', u.version_in_text(RAW_OK.decode('utf-8')) == '9.9.9-py')
_body = '| a | b | c |\n| `%s` | x | `%s` |\n' % (ASSET, 'A' * 64)
check('从 release body 抠 sha256', u.sha256_from_body(_body, ASSET) == 'a' * 64)
check('body 里没有该资产时不瞎猜', u.sha256_from_body('nothing here', ASSET) == '')
check('镜像前缀拼接', (u._mirror('https://x/y.zip', 'https://gh/'),
                       u._mirror('https://x/y.zip', '')) == ('https://gh/https://x/y.zip', 'https://x/y.zip'))

# ---------------- A: 检查 / 下载 ----------------
print('--- A. 检查 + 下载校验(假服务器) ---')
info = u.plan('1.2.14-py', repo='o/r', api=BASE, timeout=10,
              raw_base=BASE + '/rawbase')
check('发现新版 -> 计划里有版本', info and info['version'] == '9.9.9', repr(info and info['version']))
check('计划里选到了 python 资产', info and info['asset'] and info['asset']['name'] == ASSET)
check('计划里带上 body 的 sha256', info and info['sha256'] == hashlib.sha256(ZIP_OK).hexdigest())
check('raw 地址带上了 tag', info and (TAG in info['raw_url']))
check('已是最新 -> None', u.plan('99.0.0', repo='o/r', api=BASE, timeout=10, raw_base=BASE + '/rawbase') is None)

new_path, sha = u.stage(info, _tmp, '1.2.14-py', timeout=20)
check('raw 路: 落出 .new', os.path.exists(new_path))
check('raw 路: .new 内容 == 服务器那份', open(new_path, 'rb').read() == RAW_OK)
check('raw 路: 返回内层 sha256', sha == hashlib.sha256(RAW_OK).hexdigest())
os.remove(new_path)

STATE['fail_raw'] = True
new2, _sha2 = u.stage(info, _tmp, '1.2.14-py', timeout=20)
check('raw 坏 -> 自动退到发行包', os.path.exists(new2) and open(new2, 'rb').read() == RAW_OK)
os.remove(new2)

info_asset = dict(info, source='asset')
STATE['sha_in_body'] = False                     # body 里给一个错的 sha
info_badsha = u.plan('1.2.14-py', repo='o/r', api=BASE, timeout=10, raw_base=BASE + '/rawbase')
info_badsha['source'] = 'asset'
try:
    u.stage(info_badsha, _tmp, '1.2.14-py', timeout=20)
    check('发行包 sha256 不符 -> 拒绝', False, '没有抛异常')
except u.UpdateError as e:
    check('发行包 sha256 不符 -> 拒绝', 'sha256' in str(e), repr(str(e)))
check('拒绝时不留 .new', not os.path.exists(os.path.join(_tmp, 'wgime-py.py.new')))
STATE['sha_in_body'] = True

STATE['fail_raw'] = True
STATE['zip'] = ZIP_BAD                            # 两条路都坏
try:
    u.stage(info, _tmp, '1.2.14-py', timeout=20)
    check('两条路都坏 -> 抛错', False, '没有抛异常')
except u.UpdateError as e:
    check('两条路都坏 -> 抛错且带两边原因', ('仓库原文件' in str(e) and '发行包' in str(e)), repr(str(e))[:120])
check('两条路都坏时不留 .new', not os.path.exists(os.path.join(_tmp, 'wgime-py.py.new')))

STATE.update({'raw': RAW_OLD, 'zip': make_zip(RAW_OLD), 'fail_raw': False})
info_old = u.plan('1.2.14-py', repo='o/r', api=BASE, timeout=10, raw_base=BASE + '/rawbase')
try:
    u.stage(info_old, _tmp, '1.2.14-py', timeout=20)
    check('下载到的文件比当前旧 -> 拒绝', False, '没有抛异常')
except u.UpdateError as e:
    check('下载到的文件比当前旧 -> 拒绝', '旧版本' in str(e) or '不比当前' in str(e), repr(str(e))[:120])

STATE.update({'raw': RAW_OK, 'zip': ZIP_OK})
# 另一条独立的路: 内层版本**正好等于 tag**, 但比"当前在跑的"旧 (有人拿旧构建重新打了 tag) -> 也必须拒绝。
# 这条专门盯 `verify_source` 里最后那道 `is_newer(inner, current_version)` (上面那条先被"低于 tag"拦住了)。
info_same = u.plan('1.2.14-py', repo='o/r', api=BASE, timeout=10, raw_base=BASE + '/rawbase')
try:
    u.stage(info_same, _tmp, '10.0.0', timeout=20)
    check('内层不比当前新 -> 拒绝', False, '没有抛异常')
except u.UpdateError as e:
    check('内层不比当前新 -> 拒绝', '不比当前' in str(e), repr(str(e))[:110])
check('这一条也不留 .new', not os.path.exists(os.path.join(_tmp, 'wgime-py.py.new')))
try:
    u.verify_source(RAW_HTML, {'version': '9.9.9'}, '1.2.14')
    check('verify_source(HTML) -> 拒绝', False, '没抛')
except u.UpdateError as e:
    check('verify_source(HTML) -> 拒绝', ('字节' in str(e) or '不是 WgIme' in str(e)), repr(str(e))[:100])
try:
    small = RAW_OK[:1024]
    u.verify_source(small, {'version': '9.9.9'}, '1.2.14')
    check('verify_source(太短) -> 拒绝', False, '没抛')
except u.UpdateError as e:
    check('verify_source(太短) -> 拒绝', '字节' in str(e), repr(str(e))[:100])

# ---------------- B: 替换助手 ----------------
print('--- B. 替换助手(真跑) ---')


def run_helper(job, timeout=25):
    return subprocess.run([sys.executable, '-u', '-c', u.HELPER_BOOTSTRAP],
                          env=u.helper_env(job), capture_output=True, timeout=timeout)


work = tempfile.mkdtemp(prefix='wg-upd-work-')
dst = os.path.join(work, 'wgime-py.py')
open(dst, 'wb').write(b'OLD CONTENT\n')
src = os.path.join(work, 'wgime-py.py.new')
open(src, 'wb').write(b'NEW CONTENT\n')
dead = subprocess.Popen([sys.executable, '-c', 'pass'])
dead.wait()
r = run_helper({'src': src, 'dst': dst, 'wait_pid': dead.pid, 'old_version': '1.2.14',
                'relaunch': [], 'cwd': work})
check('助手: 目标已退出 -> 替换成功', r.returncode == 0 and open(dst, 'rb').read() == b'NEW CONTENT\n',
      'rc=%s body=%r' % (r.returncode, open(dst, 'rb').read()[:20]))
check('助手: 替换前留了备份', os.path.exists(dst + '.bak-1.2.14'),
      str(os.listdir(work))[:120])

# 目标还活着 -> 必须先等它退出
open(dst, 'wb').write(b'OLD2\n')
open(src, 'wb').write(b'NEW2\n')
alive = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(1.6)'])
th = threading.Thread(target=run_helper, args=({'src': src, 'dst': dst, 'wait_pid': alive.pid,
                                                'relaunch': [], 'cwd': work},))
th.start()
time.sleep(0.7)
mid = open(dst, 'rb').read()
check('助手: 目标还没退出时不替换', mid == b'OLD2\n', repr(mid[:20]))
th.join(timeout=25)
alive.wait()
check('助手: 目标退出后才替换', open(dst, 'rb').read() == b'NEW2\n', repr(open(dst, 'rb').read()[:20]))

open(dst, 'wb').write(b'KEEP\n')
r3 = run_helper({'src': os.path.join(work, 'nope.new'), 'dst': dst, 'wait_pid': 0, 'relaunch': []})
check('助手: 新文件不存在 -> 拒绝且不动目标',
      r3.returncode != 0 and open(dst, 'rb').read() == b'KEEP\n', 'rc=%s' % r3.returncode)

# ---------------- C: 端到端 spawn_apply ----------------
print('--- C. spawn_apply 端到端 ---')
open(dst, 'wb').write(b'C-OLD\n')
newsrc = os.path.join(work, 'wgime-py.py.new')
open(newsrc, 'wb').write(b'C-NEW\n')
pid = u.spawn_apply(newsrc, dst, wait_pid=0, old_version='0.0.1', relaunch=[], cwd=work)
ok = False
for _ in range(40):
    time.sleep(0.25)
    if open(dst, 'rb').read() == b'C-NEW\n':
        ok = True
        break
check('spawn_apply: 拉起助手后文件被换掉', ok, 'helper pid=%s dst=%r' % (pid, open(dst, 'rb').read()[:20]))

srv.shutdown()
shutil.rmtree(_tmp, ignore_errors=True)
shutil.rmtree(work, ignore_errors=True)
print('')
if fails:
    print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
    sys.exit(1)
print('全部通过 (%d 项)' % n[0])
