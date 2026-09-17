# -*- coding: utf-8 -*-
"""语音包 wrapper 的「仓库参考副本 vs 机器上真正在用的那份」一致性测试.

背景: 常驻 sherpa 的**客户端**在仓库里 (`voice.py::_SherpaSrv`), **服务端** wrapper 在仓库外
(`C:\\Tools\\wgime-local-asr\\wgime-stt.py`, 与 228MB 模型一起按机器各装一份)。
2026-09-16 因为这个"一半在里、一半在外"出过一次缺口: 客户端已经要 `--serve`, 而本机 wrapper
还是一次性版本 -> `voice_engine = sherpa` 的助手起不来。这个测试就是防它再发生。

  A 参考副本 `wgime-py-pure\\voicepack\\wgime-stt.py` 存在、**能编译**、**协议要点齐全**;
  B 机器上真在用的那份 (取 `package\\config.txt` 的 `stt_script`; 也可 `--installed <路径>`):
    先比字节; 不一致就比**协议 token 集合** —— 集合不同 = **协议漂移, FAIL**;
    文件不存在 = SKIP (没装语音包的机器不算错)。
  C (可选) 用**真在用的那份**起一次 `--serve` 只验协议: ready / ping 立刻回 / 坏路径回 ok=false
    且不退出 / `exit` 干净退出。没有模型目录就 SKIP。

跑法: python wgime-py-pure\\tests\\voicepack-sync-test.py [--installed <path>] [--no-live]
"""
import argparse
import io
import re
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PURE = os.path.dirname(HERE)
REF = os.path.join(PURE, 'voicepack', 'wgime-stt.py')
PKG_CFG = os.path.join(PURE, 'package', 'config.txt')

# 协议要点 (bare 词, 不带引号 —— 未来换引号风格不该误报):
# 服务模式开关 / ready 与结果字段 / 心跳 / 退出 / 单句失败 / 中文转义 / 一次性模式的 {wav}
TOKENS = ['--serve', 'ready', 'boot_ms', 'audio_ms', 'ping', 'exit', 'ensure_ascii',
          'ok', 'text', 'segs', 'wav', 'id']

fails, skips = [], []
n = [0]


def check(name, cond, extra=''):
    n[0] += 1
    print('  %-54s %s %s' % (name, 'OK' if cond else 'FAIL', '' if cond else extra))
    if not cond:
        fails.append(name)


def skip(name, why):
    skips.append(name)
    print('  %-54s SKIP %s' % (name, why))


def read(path):
    return io.open(path, encoding='utf-8', errors='replace', newline='').read()


def missing_tokens(text):
    return [t for t in TOKENS if t not in text]


def proto_keys(src):
    """源码里所有 dict 字面量的键 = 这套协议实际收发哪些字段 (比"某个词出现过"强得多)。"""
    return sorted(set(re.findall(r"'([a-z_]{2,})'\s*:", src)))


def emit_keys(src):
    """`emit({...})` 里打出去的字段 = 服务端**发给客户端**的协议面。"""
    return sorted(set(re.findall(r"emit\(\{[^}]*", src)) and
                  set(re.findall(r"'([a-z_]{2,})'\s*:", ''.join(re.findall(r"emit\(\{[^}]*\}", src)))))


def installed_path(cli):
    if cli:
        return cli
    if not os.path.exists(PKG_CFG):
        return None
    for line in read(PKG_CFG).split('\n'):
        s = line.strip()
        if s.startswith('stt_script'):
            v = s.split('=', 1)[1].strip() if '=' in s else ''
            return v or None
    return None


def models_ok(wrapper):
    d = os.path.join(os.path.dirname(os.path.abspath(wrapper)), 'models', 'sense-voice')
    return (os.path.isfile(os.path.join(d, 'model.int8.onnx'))
            and os.path.isfile(os.path.join(d, 'tokens.txt')))


def live_serve(wrapper):
    """真起一次 --serve, 只验协议 (不验识别)。"""
    p = subprocess.Popen([sys.executable, '-u', wrapper, '--serve', '--threads=4'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, encoding='utf-8', errors='replace', bufsize=1,
                         creationflags=0x08000000)
    def rd(timeout=120):
        t0 = time.monotonic()
        while time.monotonic() - t0 < timeout:
            line = p.stdout.readline()
            if not line:
                return None
            line = line.strip()
            if line:
                try:
                    return json.loads(line)
                except ValueError:
                    return {'__bad__': line}
        return {'__timeout__': 1}
    r = rd()
    check('真起 --serve: 第一行是 ready', bool(r and r.get('ready')), repr(r))
    check('ready 带 boot_ms/model', bool(r and r.get('boot_ms') is not None and r.get('model')), repr(r))
    p.stdin.write(json.dumps({'cmd': 'ping', 'id': 1}) + '\n')
    p.stdin.flush()
    q = rd(30)
    check('cmd=ping 立刻回 ok (text 空)', bool(q and q.get('ok') is True and not q.get('text')), repr(q))
    p.stdin.write(json.dumps({'id': 2, 'wav': os.path.join(HERE, 'no-such.wav')}) + '\n')
    p.stdin.flush()
    b = rd(30)
    check('坏 wav 回 ok=false', bool(b and b.get('ok') is False), repr(b))
    check('坏 wav 之后助手仍然活着', p.poll() is None, 'rc=%s' % p.poll())
    p.stdin.write(json.dumps({'cmd': 'exit'}) + '\n')
    p.stdin.flush()
    try:
        rc = p.wait(timeout=15)
    except subprocess.TimeoutExpired:
        p.kill()
        rc = None
    check('cmd=exit 干净退出 rc=0', rc == 0, 'rc=%s' % rc)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--installed', default=None, help='机器上真在用的 wrapper 路径')
    ap.add_argument('--no-live', action='store_true', help='跳过 --serve 实起')
    args = ap.parse_args()

    print('参考副本 = %s' % REF)
    check('参考副本存在', os.path.exists(REF), REF)
    if not os.path.exists(REF):
        return 1
    ref_src = read(REF)
    try:
        compile(ref_src, REF, 'exec')
        ok_compile = True
    except SyntaxError as e:
        ok_compile = False
        print('    编译错误: %s' % e)
    check('参考副本能编译', ok_compile)
    miss = missing_tokens(ref_src)
    check('参考副本协议要点齐全 (%d 个)' % len(TOKENS), not miss, '缺: %s' % miss)
    check('参考副本有 --serve 分支', 'if opts.get(\'serve\')' in ref_src or "'serve'" in ref_src)
    print('    参考副本协议字段: %s' % ', '.join(proto_keys(ref_src)))

    print('--- B. 与机器上真在用的那份比对 ---')
    inst = installed_path(args.installed)
    print('    stt_script = %s' % (inst or '(config 里没配)'))
    inst_ok = bool(inst and os.path.exists(inst))
    if not inst_ok:
        skip('与在用副本比对', '(文件不存在 —— 这台机器没装语音包)')
    else:
        inst_src = read(inst)
        same = open(inst, 'rb').read() == open(REF, 'rb').read()
        print('    字节一致 = %s; 在用副本协议缺失 = %s' % (same, missing_tokens(inst_src) or '无'))
        check('在用副本协议要点不缺', not missing_tokens(inst_src),
              '缺: %s (说明协议漂移了 —— 两侧都要改)' % missing_tokens(inst_src))
        # **强判据**: 协议字段集合必须完全相同 (少一个 = 协议丢了; 多一个 = 只改了一侧)
        rk, ik = proto_keys(ref_src), proto_keys(inst_src)
        check('两侧协议字段集合完全一致 (%d 个字段)' % len(rk), rk == ik,
              '参考独有=%s 在用独有=%s' % (sorted(set(rk) - set(ik)), sorted(set(ik) - set(rk))))
        re_, ie = emit_keys(ref_src), emit_keys(inst_src)
        check('两侧"发给客户端的字段"一致', re_ == ie,
              '参考独有=%s 在用独有=%s' % (sorted(set(re_) - set(ie)), sorted(set(ie) - set(re_))))
        if not same:
            print('    提示: 字节不同(正常, 机器上那份可能带本地改动); 只要协议要点一致就行')

    print('--- C. 实起 --serve 验协议 (可选) ---')
    target = inst if inst_ok else REF
    if args.no_live:
        skip('--serve 实起', '(--no-live)')
    elif not models_ok(target):
        skip('--serve 实起', '(没有 models/sense-voice 模型)')
    else:
        print('    用 %s 起服务' % target)
        live_serve(target)

    print('')
    if skips:
        print('SKIP: %s' % ', '.join(skips))
    if fails:
        print('%d/%d 项失败: %s' % (len(fails), n[0], ', '.join(fails)))
        return 1
    print('全部通过 (%d 项)' % n[0])
    return 0


if __name__ == '__main__':
    sys.exit(main())
