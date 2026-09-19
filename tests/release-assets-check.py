# -*- coding: utf-8 -*-
r"""发布资产预检 (第七十六轮补充: 发布事故的永久守卫).

**为什么有这个东西**: v1.2.13 的 `wgime-v1.2.13-python.zip` 里混进了开发机正在用的 `config.txt`
(含一把硅基流动 API key + `C:\Tools\...` 本机路径)。根因是 `build-release-assets.ps1` 逐字节打包
`wgime-py-pure\package\`, 而那个目录里的 `config.txt` 常常是"本机在用的活配置"—— 发布的人不会注意到。

所以**发版前**必须跑这一条 (它只读本地文件, 不联网):

    python tests\release-assets-check.py --version 1.2.14 --assets .release-stage-v1214

判据 (任一不满足就退出码 1):
  1. 三个 zip 的条目都用 `/`、没有绝对路径/上跳条目;
  2. 每个 zip 恰好一个 `config.txt`, 且**与仓库模板逐字节一致** (python 包对根 `config.txt`,
     bat/ps1 包对 `release\config.txt`);
  3. `config.txt` 里**没有 API key** (`sk-` + 20 位以上)、没有 `C:\Users\...` 私用路径、
     没有**启用**的 `stt_key/stt_script/stt_python/stt_cmd` 行 (注释掉的示例行不算);
  4. python 包内层 `wgime-py.py` 与 `wgime-py-pure\dist\wgime-py.py` **逐字节一致**, 且带 `dicts/` 与 `plugins/`;
  5. bat/ps1 包里有 `wgime.bat` / `WgIme.ps1`。

自检过守卫有效性: 拿**那份泄漏的** v1.2.13 python 包跑它 -> 第 3 条必须红 (见 CHANGELOG 第七十六轮)。
"""
import argparse
import hashlib
import os
import re
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KEY_RE = re.compile(r'sk-[A-Za-z0-9]{20,}')
PRIVATE_RE = re.compile(r'[A-Za-z]:\\Users\\', re.I)
ACTIVE_STT_RE = re.compile(r'^\s*(stt_key|stt_script|stt_python|stt_cmd)\s*=\s*\S')
MAIN = {'bat': 'wgime.bat', 'ps1': 'WgIme.ps1', 'python': 'wgime-py.py'}

fails = []
n = [0]


def mask(line):
    """报错时别把 key 原样打出来 (它已经泄漏过一次了, 日志/CI 里不必再抄一遍)。"""
    return KEY_RE.sub('sk-***MASKED***', line)


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-56s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else mask(str(extra))))
    if not cond:
        fails.append(name)


def read(path):
    with open(path, 'rb') as f:
        return f.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--version', required=True, help='e.g. 1.2.14')
    ap.add_argument('--assets', required=True, help='stage dir holding the three zips')
    ap.add_argument('--repo', default=REPO)
    a = ap.parse_args()

    dist = read(os.path.join(a.repo, 'wgime-py-pure', 'dist', 'wgime-py.py'))
    tpl = {'python': read(os.path.join(a.repo, 'config.txt')),
           'bat': read(os.path.join(a.repo, 'release', 'config.txt')),
           'ps1': read(os.path.join(a.repo, 'release', 'config.txt'))}

    print('资产目录: %s' % a.assets)
    print('dist\\wgime-py.py: %d B sha256=%s' % (len(dist), hashlib.sha256(dist).hexdigest()[:16].upper()))
    for kind in ('bat', 'ps1', 'python'):
        zp = os.path.join(a.assets, 'wgime-v%s-%s.zip' % (a.version, kind))
        if not os.path.exists(zp):
            check('%s: 文件存在' % kind, False, zp)
            continue
        raw = read(zp)
        print('== %s (%d B) sha256=%s' % (os.path.basename(zp), len(raw),
                                          hashlib.sha256(raw).hexdigest().upper()))
        z = zipfile.ZipFile(zp)
        names = z.namelist()
        check('%s: 条目全部用 /' % kind, not any('\\' in x for x in names))
        check('%s: 没有绝对路径/上跳条目' % kind,
              not any(x.startswith('/') or '..' in x.split('/') for x in names))
        cfgs = [x for x in names if x.endswith('config.txt')]
        check('%s: 恰好一个 config.txt' % kind, len(cfgs) == 1, repr(cfgs))
        if cfgs:
            cfg = z.read(cfgs[0])
            check('%s: config.txt 与模板逐字节一致' % kind, cfg == tpl[kind],
                  '%d B vs 模板 %d B' % (len(cfg), len(tpl[kind])))
            txt = cfg.decode('utf-8-sig', 'replace')
            mo = KEY_RE.search(txt)
            check('%s: config.txt 没有 API key' % kind, mo is None,
                  '发现 sk- 形式的私钥 (%d 字符), 位置 %d' % (len(mo.group(0)), mo.start()) if mo else '')
            check('%s: config.txt 没有 C:\\Users 私用路径' % kind, PRIVATE_RE.search(txt) is None)
            active = [ln for ln in txt.splitlines()
                      if ln.strip() and not ln.lstrip().startswith(';')]
            bad = [ln for ln in active if ACTIVE_STT_RE.match(ln)]
            check('%s: 没有启用的本机 stt_* 项' % kind, not bad, repr(bad))
        check('%s: 含 %s' % (kind, MAIN[kind]), any(x == MAIN[kind] for x in names))
        if kind == 'python':
            inner = [x for x in names if x.endswith('wgime-py.py')]
            check('python: 恰好一个内层 wgime-py.py', len(inner) == 1, repr(inner))
            if inner:
                d = z.read(inner[0])
                check('python: 内层 wgime-py.py == dist(逐字节)', d == dist,
                      '%d B vs dist %d B' % (len(d), len(dist)))
            check('python: 带 dicts/ 与 plugins/',
                  any(x.startswith('dicts/') for x in names)
                  and any(x.startswith('plugins/') for x in names))

    print('')
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        print('**不要发布**: 先跑 wgime-py-pure\\build-package.ps1 重建 package, 再重建资产。')
        return 1
    print('预检全部通过 (%d 项) —— 可以发布' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
