# -*- coding: utf-8 -*-
r"""update.py — 从 GitHub Releases 自更新 (第八十五轮): 检查 / 下载校验 / 换文件重启.

**只更新纯 Python 单文件 `wgime-py.py`**(用户选的方案): 服务器就是本仓库的 GitHub Releases ——
`GET {api}/repos/{repo}/releases/latest` 拿最新 tag, 比 `main.VERSION` 新就下载新的单文件,
落到**同目录**的 `wgime-py.py.new`, 再由一个 detached 小助手(等本进程退出 → 备份 → `os.replace` →
用 pythonw 重启) 完成替换。config.txt / dicts / plugins 一概不碰。

**四条硬安全线**(改这块别退):
  ① **先校验再落盘**: 必须是我们的单文件(含 `MODULES =`/`PLUGIN_SRC =`/`THIRD_ZIP_B64` 三个标记)、
     能 `compile()`、大小 >= `MIN_BYTES`, 且里面的 `VERSION` 必须**比当前版本新**、不旧于 release tag ——
     防半截下载 / HTML 错误页 / 挂错资产;
  ② **asset 那条路要核对 sha256**: release body 的资产表里带 SHA256(本仓库发布流程会写), 对得上才解包;
  ③ **替换前先备份** `wgime-py.py.bak-<旧版本>`, `.new` 与目标同目录(同卷才能原子 replace), 失败保留旧文件;
  ④ **只在用户点「更新」后才动手**: 启动时只做一次后台检查 + 托盘提示, 绝不在打字/录音中途自动重启。

**两条下载路**(自动降级): `raw`(仓库里的 `wgime-py-pure/dist/wgime-py.py`, ~1.1MB) 优先, 失败退
`asset`(发行包 `*-python.zip`, ~25MB 但带 sha256 校验); 网络先 urllib **直连**
(`ProxyHandler({})` —— 本机 WinINET 代理常年是黑洞), 失败退 PowerShell `HttpWebRequest`
(本仓库吃过 python urllib 到 github SSL EOF 的亏, 见 AGENTS-DETAIL §D15)。
`update_mirror` 可给下载 URL 加前缀(如 `https://ghproxy.net/`)。
日志: `%LOCALAPPDATA%\wgime-py\update.log`(always-on; 助手进程也往同一个文件写)。
"""
import base64
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import zipfile

API_DEFAULT = 'https://api.github.com'
RAW_DEFAULT = 'https://raw.githubusercontent.com'
REPO_DEFAULT = 'ogowoo/wgime'
ASSET_SUFFIX = '-python.zip'
INNER_NAME = 'wgime-py.py'
RAW_PATH = 'wgime-py-pure/dist/wgime-py.py'
MARKERS = ('MODULES =', 'PLUGIN_SRC =', 'THIRD_ZIP_B64')
MIN_BYTES = 200 * 1024          # 实测单文件 ~1.1MB; 小于 200KB 一定不是它
UA = 'wgime-update/1.0'
_WIN_FLAGS = 0x00000008 | 0x00000200 | 0x08000000        # DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP|CREATE_NO_WINDOW


class UpdateError(Exception):
    """检查/下载/校验/替换失败 —— 一律带人话, 直接可以塞进托盘气泡。"""


# ---------------- 日志 ----------------
def data_dir():
    la = os.environ.get('LOCALAPPDATA') or os.path.expanduser('~')
    return os.path.join(la, 'wgime-py')


def log(text):
    """always-on 诊断(助手进程也在写同一个文件, 所以格式固定 '[helper] ' 前缀区分)。"""
    try:
        d = data_dir()
        os.makedirs(d, exist_ok=True)
        with io.open(os.path.join(d, 'update.log'), 'a', encoding='utf-8') as f:
            f.write('%.3f %s\n' % (time.time(), text))
    except Exception:
        pass


# ---------------- 版本号 ----------------
def parse_version(text):
    """`v1.2.14` / `1.2.14-py` / `'1.2.14'` -> (1,2,14); 抠不出来返回 ()。"""
    m = re.search(r'(\d+)\.(\d+)\.(\d+)', str(text or ''))
    return tuple(int(x) for x in m.groups()) if m else ()


def is_newer(latest, current):
    """latest 严格比 current 新才算 —— 任一边解析不出就 **不更新**(宁可不升, 也别被垃圾版本号带着跑)。"""
    a, b = parse_version(latest), parse_version(current)
    return bool(a) and bool(b) and a > b


def local_version_from_file(path):
    """从单文件里抠版本号(顶层明文 `WGIME_VERSION`, 旧文件退正则抠 `VERSION = '...'`)。"""
    try:
        with io.open(path, encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        return ''
    return version_in_text(text)


def is_single_file(path):
    """这个正在跑的文件是不是**发布的单文件**?

    判据: 头 8KB 里有 `MODULES = ` 标记 —— 单文件(dist)一开头就是那张内嵌模块表, 而源码布局的
    `main.py` 只有 import。**自动更新只对单文件生效**: 源码目录里替换 main.py 是灾难(用户在开发)。
    """
    try:
        with io.open(path, encoding='utf-8', errors='replace') as f:
            head = f.read(8192)
    except OSError:
        return False
    return 'MODULES = ' in head


def version_in_text(text):
    """抠单文件自称的版本号。

    **先认顶层明文 `WGIME_VERSION = '...'`**(第八十五轮补起构建期就会写这一行) —— 它是唯一
    无歧义的判据。旧单文件没有这一行, 才退回去正则搜 `VERSION = '数字...'`。

    为什么非要有这条明文(真事故, 别删): 老实现只做正则, 而 `MODULES` 里 update.py 自己的文档
    就含一句 `VERSION = '<某个具体版本号>'` 这样的示例、且排在 main 之前 —— 于是下载到新版单文件
    被读成**示例里那个旧版本**, `verify_source` 判"下载到的是旧版本"**直接拒绝更新**。
    (所以本函数文档里也**不许**再写带数字的 `VERSION = ` 示例 —— 那会自己把自己带沟里。)
    正则兜底那两条注释也是踩出来的: 反斜杠要允许**任意多个**(dist 里 main.py 是嵌套 repr, 只写
    `\\?` 抠不到); 版本号必须**以数字开头** —— 否则会先撞上文档里那句 `VERSION = '...'`。
    """
    t = text or ''
    m = re.search(r"WGIME_VERSION\s*=\s*['\"]([^'\"]+)", t)
    if m:
        return m.group(1)
    m = re.search(r"VERSION\s*=\s*\\*['\"](\d+\.\d+[^'\"\\]*)", t)
    return m.group(1) if m else ''


# ---------------- 网络 ----------------
def _mirror(url, prefix=''):
    """给 URL 加镜像前缀(ghproxy 那类镜像的用法就是前缀拼接); 空前缀=原样。"""
    return (prefix.rstrip('/') + '/' + url) if (prefix and url) else url


def _http_direct(url, timeout=15):
    req = urllib.request.Request(url, headers={'User-Agent': UA,
                                               'Accept': 'application/vnd.github+json'})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))   # 直连, 不走那个黑洞代理
    with opener.open(req, timeout=timeout) as r:
        return r.read()


_PS_COMMON = ("$ErrorActionPreference='Stop';"
              "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;"
              "[Net.WebRequest]::DefaultWebProxy=$null;"
              "$r=[Net.HttpWebRequest]::Create($env:WGIME_UPDATE_URL);"
              "$r.UserAgent='wgime-update';$r.Proxy=$null;"
              "$r.Timeout=%d;$r.ReadWriteTimeout=%d;"
              "$resp=$r.GetResponse();")


def _powershell(url, timeout, dest=None):
    """兜底通道: PowerShell HttpWebRequest。dest 给了就写文件, 否则 base64 回传(只管小 JSON)。"""
    if dest:
        script = (_PS_COMMON % (timeout * 1000, timeout * 1000)) + \
                 "$fs=[IO.File]::Create($env:WGIME_UPDATE_DEST);" \
                 "$resp.GetResponseStream().CopyTo($fs);$fs.Close();$resp.Close()"
        env = dict(os.environ, WGIME_UPDATE_URL=url, WGIME_UPDATE_DEST=dest)
    else:
        script = (_PS_COMMON % (timeout * 1000, timeout * 1000)) + \
                 "$ms=New-Object IO.MemoryStream;$resp.GetResponseStream().CopyTo($ms);$resp.Close();" \
                 "[Convert]::ToBase64String($ms.ToArray())"
        env = dict(os.environ, WGIME_UPDATE_URL=url)
    try:
        out = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script],
                             env=env, capture_output=True, timeout=timeout + 30)
    except Exception as e:
        raise UpdateError('PowerShell 兜底通道也起不来: %r' % (e,))
    if out.returncode != 0:
        err = (out.stderr or b'').decode('utf-8', 'replace').strip().splitlines()
        raise UpdateError('PowerShell 兜底通道失败: %s' % (err[-1] if err else 'rc=%d' % out.returncode))
    if dest:
        return b''
    return base64.b64decode((out.stdout or b'').strip() or b'')


def http_get(url, timeout=15):
    """小文件(JSON) 取回 bytes: 先直连, 失败退 PowerShell。"""
    try:
        return _http_direct(url, timeout)
    except Exception as e:
        log('update: direct GET failed %s -> %r' % (url[:90], e))
        return _powershell(url, timeout)


def download_file(url, dest, timeout=90):
    """下载到文件: 先直连(流式), 失败退 PowerShell(直接落盘, 不走管道)。"""
    try:
        req = urllib.request.Request(url, headers={'User-Agent': UA})
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(req, timeout=timeout) as r, open(dest, 'wb') as f:
            while True:
                chunk = r.read(65536)
                if not chunk:
                    break
                f.write(chunk)
        return dest
    except Exception as e:
        log('update: direct download failed %s -> %r' % (url[:90], e))
        _powershell(url, timeout, dest=dest)
        return dest


# ---------------- GitHub Releases ----------------
def fetch_latest(repo=REPO_DEFAULT, api=API_DEFAULT, timeout=15):
    """最新**正式版** release: 先 `/releases/latest`, 拿不到就退 `/releases` 取第一个非 draft/prerelease。"""
    base = api.rstrip('/')
    data = None
    try:
        data = json.loads(http_get('%s/repos/%s/releases/latest' % (base, repo), timeout).decode('utf-8'))
    except UpdateError as e:
        log('update: /latest 失败(%s), 退 /releases 列表' % e)
    if not isinstance(data, dict) or not data.get('tag_name'):
        lst = json.loads(http_get('%s/repos/%s/releases' % (base, repo), timeout).decode('utf-8'))
        cands = [r for r in (lst or []) if isinstance(r, dict) and not r.get('draft') and not r.get('prerelease')]
        if not cands:
            raise UpdateError('这个仓库没有正式版 release')
        data = cands[0]
    assets = [{'name': a.get('name') or '', 'size': a.get('size') or 0,
               'url': a.get('browser_download_url') or ''}
              for a in (data.get('assets') or []) if a.get('name')]
    tag = str(data.get('tag_name'))
    return {'tag': tag, 'version': tag.lstrip('vV'), 'body': data.get('body') or '',
            'assets': assets, 'repo': repo}


def sha256_from_body(body, asset_name):
    """release body 里那张资产表带 SHA256(本仓库发布流程会写): 找含资产名的那一行, 抠出 64 位十六进制。"""
    if not body or not asset_name:
        return ''
    for line in str(body).splitlines():
        if asset_name in line:
            m = re.search(r'\b([0-9a-fA-F]{64})\b', line)
            if m:
                return m.group(1).lower()
    m = re.search(r'\b([0-9a-fA-F]{64})\b', str(body))
    return m.group(1).lower() if m else ''


def plan(current_version, repo=REPO_DEFAULT, api=API_DEFAULT, timeout=15,
         asset_suffix=ASSET_SUFFIX, source='raw', raw_base=RAW_DEFAULT):
    """检查 + 规划: 有新版本返回 info(含下载地址), 已是最新返回 None, 失败抛 UpdateError。"""
    info = fetch_latest(repo, api, timeout)
    if not is_newer(info['tag'], current_version):
        return None
    asset = next((a for a in info['assets'] if a['name'].endswith(asset_suffix)), None)
    info['asset'] = asset
    info['source'] = 'asset' if str(source).lower() == 'asset' else 'raw'
    info['asset_suffix'] = asset_suffix
    info['raw_url'] = '%s/%s/%s/%s' % (raw_base.rstrip('/'), repo, info['tag'], RAW_PATH)
    info['sha256'] = sha256_from_body(info['body'], asset['name']) if asset else ''
    log('update: 发现新版 %s (当前 %s) source=%s asset=%s sha=%s'
        % (info['tag'], current_version, info['source'], (asset or {}).get('name'), info['sha256'][:12] or '-'))
    return info


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_source(raw, info, current_version):
    """落盘前的四道校验 —— 任何一条不过都抛 UpdateError(带人话), 绝不写 .new。"""
    if len(raw) < MIN_BYTES:
        raise UpdateError('下载到的东西只有 %d 字节, 不像 WgIme 单文件(至少 %d)'
                          % (len(raw), MIN_BYTES))
    text = raw.decode('utf-8', 'replace')
    missing = [m for m in MARKERS if m not in text]
    if missing:
        raise UpdateError('不是 WgIme 的单文件(缺 %s)' % '/'.join(missing))
    try:
        compile(text, INNER_NAME, 'exec')
    except SyntaxError as e:
        raise UpdateError('下载到的文件编译不过: %s' % e)
    inner = version_in_text(text)
    want = parse_version(info.get('version'))
    if not inner:
        raise UpdateError('下载到的文件里没有 VERSION 标记')
    if want and parse_version(inner) < want:
        raise UpdateError('下载到的文件是旧版本(%s < %s)' % (inner, info.get('version')))
    if not is_newer(inner, current_version):
        raise UpdateError('下载到的版本 %s 不比当前 %s 新' % (inner, current_version))
    return inner


def stage(info, dest_dir, current_version, timeout=90, mirror=''):
    """下载 + 校验 + 写 `<dest_dir>/wgime-py.py.new`; 返回 (new_path, sha256)。

    先走 `raw`(小, ~1.1MB), 失败自动改走 `asset`(发行包, 带 SHA256 核对) —— 两条路的**原因都会报出来**。
    """
    def _raw_bytes():
        tmp = os.path.join(dest_dir, INNER_NAME + '.raw.part')
        try:
            download_file(_mirror(info['raw_url'], mirror), tmp, timeout)
            with open(tmp, 'rb') as f:
                return f.read()
        finally:
            _rm(tmp)

    def _asset_bytes():
        asset = info.get('asset')
        if not asset or not asset.get('url'):
            raise UpdateError('这个 release 里没有 `%s` 资产' % info.get('asset_suffix') or ASSET_SUFFIX)
        tmp = os.path.join(dest_dir, INNER_NAME + '.zip.part')
        try:
            download_file(_mirror(asset['url'], mirror), tmp, timeout)
            with open(tmp, 'rb') as f:
                blob = f.read()
        finally:
            _rm(tmp)
        if info.get('sha256') and _sha256(blob) != info['sha256']:
            raise UpdateError('发行包 sha256 与 release 说明不符(可能下了一半)')
        try:
            with zipfile.ZipFile(io.BytesIO(blob)) as z:
                names = [n for n in z.namelist() if n == INNER_NAME or n.endswith('/' + INNER_NAME)]
                if len(names) != 1:
                    raise UpdateError('发行包里找不到唯一的 %s' % INNER_NAME)
                return z.read(names[0])
        except zipfile.BadZipFile as e:
            raise UpdateError('发行包不是合法 zip: %s' % e)

    order = [_asset_bytes, _raw_bytes] if info.get('source') == 'asset' else [_raw_bytes, _asset_bytes]
    reasons, raw = [], None
    for fn in order:
        try:
            raw = fn()
            verify_source(raw, info, current_version)
            log('update: 取到 %s via %s (%d 字节)' % (info.get('version'), fn.__name__, len(raw)))
            break
        except UpdateError as e:
            reasons.append('%s 不行: %s' % ('发行包' if fn is _asset_bytes else '仓库原文件', e))
            log('update: %s' % reasons[-1])
            raw = None
    if raw is None:
        raise UpdateError('；'.join(reasons) or '下载失败')

    new_path = os.path.join(dest_dir, INNER_NAME + '.new')
    with open(new_path, 'wb') as f:
        f.write(raw)
    return new_path, _sha256(raw)


def _rm(path):
    try:
        os.remove(path)
    except OSError:
        pass


# ---------------- 替换 + 重启(小助手) ----------------
# 助手源码走**环境变量**(照 §17 helper 的老规矩: 不落盘 .py, 也不让进程命令行变成一大坨 -c)。
# 它是**自足**的: 只 import 标准库, 不 import wgime 的任何模块(那时旧文件正被换掉)。
HELPER_SRC = r'''
import ctypes, json, os, shutil, subprocess, sys, time


def _log(text):
    try:
        la = os.environ.get('LOCALAPPDATA') or os.path.expanduser('~')
        d = os.path.join(la, 'wgime-py')
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, 'update.log'), 'a', encoding='utf-8') as f:
            f.write('%.3f [helper] %s\n' % (time.time(), text))
    except Exception:
        pass


def _wait_pid_exit(pid, timeout):
    """等 pid 退出(最多 timeout 秒)。OpenProcess(SYNCHRONIZE)+WaitForSingleObject —— 比轮询进程表准。"""
    if not pid or pid <= 0:
        return True
    try:
        k = ctypes.windll.kernel32
        k.OpenProcess.restype = ctypes.c_void_p
        k.OpenProcess.argtypes = [ctypes.c_uint, ctypes.c_int, ctypes.c_uint]
        k.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        k.CloseHandle.argtypes = [ctypes.c_void_p]
        h = k.OpenProcess(0x00100000, 0, int(pid))          # SYNCHRONIZE
        if not h:
            return True                                      # 已经没了
        try:
            return k.WaitForSingleObject(ctypes.c_void_p(h), int(max(0.0, timeout) * 1000)) == 0
        finally:
            k.CloseHandle(ctypes.c_void_p(h))
    except Exception as e:
        _log('wait pid failed (%r), 直接往下走' % (e,))
        return True


def apply_job(job):
    """等旧进程退出 -> 备份 -> os.replace -> (可选)重启新文件。返回退出码(0=成功)。"""
    src, dst = job['src'], job['dst']
    _log('job: %s -> %s (waits %s)' % (src, dst, job.get('wait_pid')))
    _wait_pid_exit(int(job.get('wait_pid') or 0), float(job.get('wait_max') or 60))
    if not os.path.exists(src):
        _log('新文件不见了: %s' % src)
        return 2
    if os.path.exists(dst):
        try:
            shutil.copy2(dst, dst + '.bak-' + str(job.get('old_version') or 'old'))
            _log('备份 -> %s.bak-%s' % (dst, job.get('old_version') or 'old'))
        except Exception as e:
            _log('备份失败(继续): %r' % (e,))
    last = None
    for _ in range(40):                                      # 个别机器上文件会被杀软/索引短时占住
        try:
            os.replace(src, dst)
            last = None
            break
        except Exception as e:
            last = e
            time.sleep(0.25)
    if last is not None:
        _log('替换失败: %r' % (last,))
        return 3
    _log('已替换: %s' % dst)
    argv = list(job.get('relaunch') or [])
    if argv:
        flags = 0
        if sys.platform == 'win32':
            flags = 0x00000008 | 0x00000200 | 0x08000000        # DETACHED|NEW_PROCESS_GROUP|NO_WINDOW
        try:
            subprocess.Popen(argv, cwd=job.get('cwd') or None, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             close_fds=True, creationflags=flags)
            _log('已重启: %s' % (argv,))
        except Exception as e:
            _log('重启失败: %r' % (e,))
            return 4
    return 0


sys.exit(apply_job(json.loads(os.environ.pop('WGIME_UPDATE_JOB'))))
'''
HELPER_BOOTSTRAP = ("import os, sys\n"
                    "sys.path[:] = [p for p in sys.path if p not in ('', '.', os.getcwd())]\n"
                    "exec(compile(os.environ.pop('WGIME_UPDATE_SRC'), '<wgime-update-helper>', 'exec'))\n")


def pythonw_path():
    """优先用 pythonw.exe(不弹黑框); 找不到就用当前解释器。"""
    exe = sys.executable or ''
    cand = os.path.join(os.path.dirname(exe), 'pythonw.exe')
    return cand if os.path.exists(cand) else exe


def helper_env(job):
    env = dict(os.environ)
    env['WGIME_UPDATE_SRC'] = HELPER_SRC
    env['WGIME_UPDATE_JOB'] = json.dumps(job)
    return env


def spawn_apply(new_path, cur_path, wait_pid, old_version='', relaunch=None, cwd=None, python_exe=None):
    """拉起 detached 小助手(它等我们退出后替换并重启)。返回助手 pid。"""
    job = {'src': os.path.abspath(new_path), 'dst': os.path.abspath(cur_path),
           'wait_pid': int(wait_pid or 0), 'wait_max': 60,
           'old_version': old_version or '', 'relaunch': list(relaunch or []),
           'cwd': cwd or os.path.dirname(os.path.abspath(cur_path))}
    exe = python_exe or pythonw_path()
    flags = _WIN_FLAGS if sys.platform == 'win32' else 0
    p = subprocess.Popen([exe, '-u', '-c', HELPER_BOOTSTRAP], env=helper_env(job),
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         close_fds=True, creationflags=flags)
    log('update: 已拉起替换助手 pid=%s (等 %s 退出)' % (p.pid, wait_pid))
    return p.pid


# ---------------- 自动检查的节流 ----------------
def _state_path():
    return os.path.join(data_dir(), 'update-state.txt')


def should_auto_check(hours=6.0):
    """启动时那次检查别太频繁(默认 6 小时内不重复查)。读不到状态=该查。"""
    try:
        with io.open(_state_path(), encoding='utf-8') as f:
            for line in f:
                if line.startswith('last_check='):
                    return (time.time() - float(line.split('=', 1)[1].strip())) > hours * 3600.0
    except Exception:
        pass
    return True


def mark_checked():
    try:
        os.makedirs(data_dir(), exist_ok=True)
        with io.open(_state_path(), 'w', encoding='utf-8') as f:
            f.write('last_check=%.0f\n' % time.time())
    except Exception:
        pass
