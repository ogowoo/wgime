# -*- coding: utf-8 -*-
"""wgime-py engine: dict loading, candidate assembly, freq learning.

逐行对齐 C# WordBoard 语义 (wgime.bat):
- 码表格式: "code word1 word2 ..." (小写 code; 文件源不拆 packed chars)
- 候选顺序 (ShowCharatar): exact dict -> prefix 单字 -> 简拼 -> 模糊音 -> 词频排序(稳定) -> lastpick 置顶
- 模式: 0=混合(五笔先) 1=拼音 2=五笔 3=词典(英汉/汉英)
- 词频: FreqM[mode] 分桶 + Freq 合并视图; userdict_{mix,py,wb}.txt / lastpick_*.txt 与 C# 版同格式
"""
import bisect
import math
import os
import re
import threading
import time

CAND_CAP = 60
PAGE_SIZE = 9
MODE_SUFFIX = ('mix', 'py', 'wb')
FUZZY_PAIRS = (('zh', 'z'), ('ch', 'c'), ('sh', 's'), ('ang', 'an'), ('eng', 'en'), ('ing', 'in'), ('n', 'l'))

# ---------- vf 符号面板数据 (抽自 C# SymCats) ----------
SYM_CAT_NAMES = ['单位符号', '标点符号', '图形符号', '数学符号', '表情emoji']
SYM_CATS = [
    '℃ ℉ ° ′ ″ ‰ ㎎ ㎏ ㎜ ㎝ ㎞ ㎡ ㎥ ㏄ №',
    '… — ～ · § ※ 《 》 〈 〉 「 」 『 』 〔 〕 〖 〗 【 】 ￥',
    '★ ☆ ● ○ ◆ ◇ ■ □ ▲ △ ► ◄ ♥ ♣ ♠ ♦ ♪ ♫ ♀ ♂ ☀ ☁ ☂ ☃ ☺ ☹ ✓ ✔ ✕ ✖ ☑ ➜ → ← ↑ ↓ ↔',
    '± × ÷ ≤ ≥ ≠ ≈ ∞ √ ∑ ∫ ∮ ∂ ∇ ∈ ∉ ⊂ ⊃ ⊆ ∪ ∩ ∅ ∴ ∵ α β γ δ θ λ μ π σ φ ω',
    '😀 😁 😂 🤣 😊 😍 😘 😎 🤔 😴 😢 😭 😡 👍 👎 👌 ✌ 🤝 🙏 💪 👀 🎉 ❤️ 💔 💯 🔥 ⭐ 🚀 🌈 🍀 ⚡ 🌙 ☕',
]

# ---------- 双拼规则 (抽自 C# SpRules; rime preedit_format, $1 -> \g<1>) ----------
def _R(rules):
    return [(re.compile(p), r.replace('$1', '\\g<1>').replace('$2', '\\g<2>')) for p, r in rules]

SP_RULES = [
    _R([  # 1: 小鹤 (flypy)
        (r'([bpmfdtnljqx])n', '$1iao'), (r'(\w)g', '$1eng'), (r'(\w)q', '$1iu'),
        (r'(\w)w', '$1ei'), (r'([dtnlgkhjqxyvuirzcs])r', '$1uan'), (r'(\w)t', '$1ve'),
        (r'(\w)y', '$1un'), (r'([dtnlgkhvuirzcs])o', '$1uo'), (r'(\w)p', '$1ie'),
        (r'([jqx])s', '$1iong'), (r'(\w)s', '$1ong'), (r'(\w)d', '$1ai'),
        (r'(\w)f', '$1en'), (r'(\w)h', '$1ang'), (r'(\w)j', '$1an'),
        (r'([gkhvuirzcs])k', '$1uai'), (r'(\w)k', '$1ing'), (r'([jqxnl])l', '$1iang'),
        (r'(\w)l', '$1uang'), (r'(\w)z', '$1ou'), (r'([gkhvuirzcs])x', '$1ua'),
        (r'(\w)x', '$1ia'), (r'(\w)c', '$1ao'), (r'([dtgkhvuirzcs])v', '$1ui'),
        (r'(\w)b', '$1in'), (r'(\w)m', '$1ian'), (r'([aoe])\1(\w)', '$1$2'),
        (r'^v', 'zh'), (r'^i', 'ch'), (r'^u', 'sh'),
        (r'([jqxy])v', '$1u'), (r'([nl])v', '$1ü'),
    ]),
    _R([  # 2: 自然码
        (r'([bpmnljqxy])n', '$1in'), (r'(\w)g', '$1eng'), (r'(\w)q', '$1iu'),
        (r'([gkhvuirzcs])w', '$1ua'), (r'(\w)w', '$1ia'), (r'([dtnlgkhjqxyvuirzcs])r', '$1uan'),
        (r'(\w)t', '$1ve'), (r'([gkhvuirzcs])y', '$1uai'), (r'(\w)y', '$1ing'),
        (r'([dtnlgkhvuirzcs])o', '$1uo'), (r'(\w)p', '$1un'), (r'([jqx])s', '$1iong'),
        (r'(\w)s', '$1ong'), (r'([jqxnl])d', '$1iang'), (r'(\w)d', '$1uang'),
        (r'(\w)f', '$1en'), (r'(\w)h', '$1ang'), (r'(\w)j', '$1an'),
        (r'(\w)k', '$1ao'), (r'(\w)l', '$1ai'), (r'(\w)z', '$1ei'),
        (r'(\w)x', '$1ie'), (r'(\w)c', '$1iao'), (r'([dtgkhvuirzcs])v', '$1ui'),
        (r'(\w)b', '$1ou'), (r'(\w)m', '$1ian'), (r'([aoe])\1(\w)', '$1$2'),
        (r'^v', 'zh'), (r'^i', 'ch'), (r'^u', 'sh'),
        (r'([jqxy])v', '$1u'), (r'([nl])v', '$1ü'),
    ]),
    _R([  # 3: 微软 (ing 在 ; 键)
        (r'([aoe])(\w)', '0$2'), (r'([bpmnljqxy])n', '$1in'), (r'(\w)g', '$1eng'),
        (r'(\w)q', '$1iu'), (r'([gkhvuirzcs])w', '$1ua'), (r'(\w)w', '$1ia'),
        (r'([dtnlgkhjqxyvuirzcs])r', '$1uan'), (r'0r', 'er'), (r'([dtgkhvuirzcs])v', '$1ui'),
        (r'(\w)v', '$1ve'), (r'(\w)t', '$1ve'), (r'([gkhvuirzcs])y', '$1uai'),
        (r'(\w)y', '$1v'), (r'([dtnlgkhvuirzcs])o', '$1uo'), (r'(\w)p', '$1un'),
        (r'([jqx])s', '$1iong'), (r'(\w)s', '$1ong'), (r'([jqxnl])d', '$1iang'),
        (r'(\w)d', '$1uang'), (r'(\w)f', '$1en'), (r'(\w)h', '$1ang'),
        (r'(\w)j', '$1an'), (r'(\w)k', '$1ao'), (r'(\w)l', '$1ai'),
        (r'(\w)z', '$1ei'), (r'(\w)x', '$1ie'), (r'(\w)c', '$1iao'),
        (r'(\w)b', '$1ou'), (r'(\w)m', '$1ian'), (r'(\w);', '$1ing'),
        (r'0(\w)', '$1'), (r'^v', 'zh'), (r'^i', 'ch'),
        (r'^u', 'sh'), (r'([jqxy])v', '$1u'), (r'([nl])v', '$1ü'),
    ]),
]


def sp_segment(seg, scheme):
    """一个两键音节 -> 全拼 (与 C# SpSegment 一致)"""
    for pat, rep in SP_RULES[scheme - 1]:
        seg = pat.sub(rep, seg)
    if len(seg) == 2 and seg[0] == seg[1] and seg[0] in 'aoe':
        seg = seg[:1]                                # 零声母单韵母: aa/oo/ee -> a/o/e
    if scheme != 1 and seg == 'r':
        seg = 'er'                                   # 自然码/微软: er 单击 r
    return seg.replace('üe', 'ue').replace('ü', 'v')  # 码表约定: lü->lv


def shuangpin_expand(keys, scheme):
    """双拼键串 -> 全拼前缀 (与 C# ShuangpinExpand 一致)"""
    if scheme < 1 or scheme > 3 or not keys:
        return keys
    sb = []
    i = 0
    while i < len(keys):
        n = 2 if i + 1 < len(keys) else 1
        sb.append(sp_segment(keys[i:i + n], scheme))
        i += n
    return ''.join(sb)

CN_DIGIT = '零壹贰叁肆伍陆柒捌玖'
CN_UNIT4 = ('', '拾', '佰', '仟')
CN_BIG = ('', '万', '亿', '兆', '京')


def upper_amount(ds):
    """1234 -> 壹仟贰佰叁拾肆元整 (与 C# UpperAmount 一致)"""
    s = ds.lstrip('0')
    if not s:
        return '零元整'
    if len(s) > 16:
        return None
    head = len(s) % 4 or 4
    groups = (len(s) - head) // 4 + 1
    sb = []
    pending_zero = False
    for g in range(groups):
        start = 0 if g == 0 else head + (g - 1) * 4
        ln = head if g == 0 else 4
        grp = s[start:start + ln]
        if all(c == '0' for c in grp):
            pending_zero = True
            continue
        if g > 0 and pending_zero and sb:
            sb.append('零')
        pending_zero = False
        grp_zero = False
        for i, ch in enumerate(grp):
            d = ord(ch) - 48
            if d == 0:
                grp_zero = True
                continue
            if grp_zero:
                sb.append('零')
                grp_zero = False
            sb.append(CN_DIGIT[d])
            sb.append(CN_UNIT4[len(grp) - 1 - i])
        if g < groups - 1:
            sb.append(CN_BIG[groups - 1 - g])
    sb.append('元整')
    return ''.join(sb)


def thousands(ds):
    """1234567 -> 1,234,567"""
    s = ds.lstrip('0') or '0'
    out = []
    for i, ch in enumerate(s):
        out.append(ch)
        left = len(s) - 1 - i
        if left > 0 and left % 3 == 0:
            out.append(',')
    return ''.join(out)


def vmode_candidates(code):
    """v+数字 -> [大写金额, 千分位] (与 AddVMode 一致: 大写在前)"""
    if len(code) < 2 or code[0] != 'v':
        return []
    ds = code[1:]
    if not ds.isdigit() or len(ds) > 16:
        return []
    out = []
    up = upper_amount(ds)
    if up is not None:
        out.append(up)
    out.append(thousands(ds))
    return out


def dynamic_candidates(code):
    """rq/sj/xq 动态候选 (与 AddDynamic 一致)"""
    n = time.localtime()
    if code == 'rq':
        return [time.strftime('%Y-%m-%d', n), '%d年%d月%d日' % (n.tm_year, n.tm_mon, n.tm_mday), time.strftime('%Y/%m/%d', n)]
    if code == 'sj':
        return [time.strftime('%H:%M', n), time.strftime('%H:%M:%S', n), time.strftime('%Y-%m-%d %H:%M', n)]
    if code == 'xq':
        w = '日一二三四五六'[(n.tm_wday + 1) % 7]
        return ['星期' + w, '周' + w]
    return []


def is_all_cjk(s):
    return all('\u4e00' <= c <= '\u9fff' for c in s)


# ---------- config.txt (与 C# LoadConfig 同格式) ----------
def load_config(path):
    """返回 dict: fuzzy/showcode/hideidle/shuangpin/trad/sentence/assoc/starton/apps"""
    cfg = dict(fuzzy=list(FUZZY_PAIRS), showcode=False, hideidle=True, shuangpin=0,
               trad=False, sentence=True, assoc=True, starton=True, apps={},
               paste=3, keyfix=True, followcaret=True, theme='dark')
    try:
        with open(path, encoding='utf-8') as f:
            for raw in f:
                t = raw.strip()
                if not t or t[0] in '#;':
                    continue
                eq = t.find('=')
                if eq < 1:
                    continue
                k = t[:eq].strip().lower()
                v = t[eq + 1:].strip()
                if k == 'fuzzy':
                    if not v or v in ('none', 'off'):
                        cfg['fuzzy'] = []
                    else:
                        pairs = []
                        for pair in v.split(','):
                            d = pair.find('-')
                            if 0 < d < len(pair) - 1:
                                pairs.append((pair[:d].strip(), pair[d + 1:].strip()))
                        if pairs:
                            cfg['fuzzy'] = pairs
                elif k == 'showcode':
                    cfg['showcode'] = v in ('1', 'on', 'true')
                elif k == 'hideidle':
                    cfg['hideidle'] = v in ('1', 'on', 'true')
                elif k == 'shuangpin':
                    cfg['shuangpin'] = {'xiaohe': 1, '小鹤': 1, 'flypy': 1, 'ziranma': 2, '自然码': 2,
                                        'zrm': 2, 'ms': 3, '微软': 3, 'mspy': 3}.get(v, 0)
                elif k == 'trad':
                    cfg['trad'] = v in ('1', 'on', 'true')
                elif k == 'sentence':
                    cfg['sentence'] = v not in ('0', 'off', 'false')
                elif k == 'assoc':
                    cfg['assoc'] = v not in ('0', 'off', 'false')
                elif k == 'starton':
                    cfg['starton'] = v in ('1', 'on', 'true')
                elif k == 'paste':
                    cfg['paste'] = {'on': 1, 'always': 1, 'off': 2, 'key': 3, 'unicode': 3}.get(v, 0)
                elif k == 'keyfix':
                    cfg['keyfix'] = v in ('1', 'on', 'true')
                elif k == 'followcaret':
                    cfg['followcaret'] = v not in ('0', 'off', 'false')
                elif k == 'theme':
                    cfg['theme'] = 'light' if v.lower() in ('light', '浅色', '白') else 'dark'
                elif k == 'phrase':
                    sp = v.find('\t')
                    if sp < 1:
                        sp = v.find(' ')
                    if sp > 0:
                        cfg.setdefault('phrases', {})[v[:sp].strip().lower()] = v[sp + 1:].strip()
                elif k == 'app':
                    ap = v.split('\t')
                    if len(ap) >= 3:
                        code, name, cmd = ap[0], ap[1], ap[2]
                        args = ap[3] if len(ap) > 3 else ''
                    else:
                        m = re.match(r'^(\S+)\s+(\S+)\s+("(?:[^"]*)"|\'[^\']*\'|\S+)(?:\s+(.*))?$', v)
                        if not m:
                            continue
                        code, name, cmd, args = m.group(1), m.group(2), m.group(3).strip('"\''), m.group(4) or ''
                    code = code.strip().lower()
                    if code:
                        cfg['apps'][code] = (name.strip(), os.path.expandvars(cmd.strip()), os.path.expandvars(args.strip()))
    except OSError:
        pass
    return cfg


def parse_dict(path):
    """code -> space-joined words (与 AddDictLine 一致: 小写 code, 后段原样)."""
    d = {}
    try:
        with open(path, encoding='utf-8') as f:
            for raw in f:
                t = raw.strip()
                if len(t) < 3:
                    continue
                sp = t.find(' ')
                if sp < 1:
                    continue
                k = t[:sp].strip().lower()
                v = t[sp + 1:].strip()
                if k and v:
                    d[k] = v
    except OSError:
        pass
    return d


def build_sorted(d):
    ks = sorted(d.keys())              # Python str 比较 = ordinal (BMP)
    return ks, [d[k] for k in ks]


def overlay_import(target, imp):
    """C# OverlayImport 语义: 已有候选保持优先, 新候选追加去重 (import_*.txt 叠加)."""
    for k, v in imp.items():
        cur = target.get(k)
        if cur is None:
            target[k] = v
        else:
            existing = set(cur.split(' '))
            for w in v.split(' '):
                if w and w not in existing:
                    cur = cur + ' ' + w
                    existing.add(w)
            target[k] = cur


def build_char_py(py):
    """char -> [pinyin...] (按 key 排序遍历, 与 BuildCharPy 一致)"""
    char_py = {}
    for code in sorted(py.keys()):
        for w in py[code].split(' '):
            if len(w) == 1:
                lst = char_py.setdefault(w, [])
                if code not in lst:
                    lst.append(code)
    return char_py


def build_acro(py, char_py):
    """简拼: 词每字首字母 -> [words] (与 BuildAcro 一致, 每 key 上限 60)"""
    acro = {}
    for code in sorted(py.keys()):
        for w in py[code].split(' '):
            if len(w) < 2:
                continue
            ini = []
            ok = True
            for ch in w:
                ps = char_py.get(ch)
                if ps:
                    ini.append(ps[0][0])
                else:
                    ok = False
                    break
            if not ok:
                continue
            lst = acro.setdefault(''.join(ini), [])
            if len(lst) < 60 and w not in lst:
                lst.append(w)
    return acro


def build_reverse(ec):
    """CN word -> EN words (BuildReverse: 每词上限 8)"""
    rev = {}
    for en in sorted(ec.keys()):
        for cn in ec[en].split(' '):
            if not cn:
                continue
            lst = rev.setdefault(cn, [])
            if len(lst) < 8 and en not in lst:
                lst.append(en)
    return {k: ' '.join(v) for k, v in rev.items()}


# ---------- 码表导入 (转换常见码表 -> import_py/wb/ec.txt, 对齐 C# ImportCodeTable) ----------
def is_pure_ascii(s):
    return bool(s) and all(ord(c) <= 0x7F for c in s)


def is_all_digits(s):
    return bool(s) and all('0' <= c <= '9' for c in s)


def valid_code(s):
    """^[a-z][a-z0-9']{0,31}$"""
    if not s or len(s) > 32 or not ('a' <= s[0] <= 'z'):
        return False
    return all(('a' <= c <= 'z') or ('0' <= c <= '9') or c == "'" for c in s[1:])


def skip_line(t):
    """空 / # ; // --- ... / yaml 'key: value' 头"""
    t = t.strip()
    if not t:
        return True
    if t[0] in ('#', ';') or t.startswith('//') or t.startswith('---') or t.startswith('...'):
        return True
    ci = t.find(':')
    return ci > 0 and (ci + 1 == len(t) or t[ci + 1] in (' ', '\t'))


def read_import_text(path):
    """读文件: UTF-8 -> GB18030 -> GBK; >64MB 返回 None"""
    try:
        b = open(path, 'rb').read()
        if len(b) > 64 * 1024 * 1024:
            return None
        for enc in ('utf-8', 'gb18030', 'gbk'):
            try:
                return b.decode(enc)
            except (UnicodeDecodeError, LookupError):
                continue
        return b.decode('utf-8', 'replace')
    except OSError:
        return None


def detect_format(lines):
    """1 = 词在前(Rime), 2 = 码在前, 0 = 未检测"""
    word_first = code_first = seen = 0
    for raw in lines:
        if seen >= 200:
            break
        t = raw.strip()
        if not t or skip_line(t):
            continue
        seen += 1
        if '\t' in t:
            word_first += 1
            continue
        sp = t.find(' ')
        if sp < 1:
            continue
        if is_pure_ascii(t[:sp]):
            code_first += 1
        else:
            word_first += 1
    if word_first == 0 and code_first == 0:
        return 0
    return 1 if word_first >= code_first else 2


def convert_file(text, fmt, acc):
    """转换并追加到 acc {code: [words]}; 返回 (skipped, trunc_codes, trunc_total)"""
    skipped = trunc_codes = trunc_total = 0
    for raw in text.split('\n'):
        t = raw.strip()
        if not t or skip_line(t):
            continue
        tab = '\t' in t
        fs = [f.strip() for f in (t.split('\t') if tab else t.split(' ')) if f.strip()]
        if len(fs) < 2:
            skipped += 1
            continue
        if is_all_digits(fs[-1]):
            fs = fs[:-1]                                # 尾权重字段
        if len(fs) < 2:
            skipped += 1
            continue
        code = None
        words = []
        if fmt == 1:                                    # 词在前: word code [weight]
            cd = fs[1].strip().lower()
            if valid_code(cd):
                code = cd
                words.append(fs[0])
            elif is_pure_ascii(fs[0]) and valid_code(fs[0].lower()):   # EN word + CN meanings
                code = fs[0].strip().lower()
                words = [w for w in fs[1:] if w]
            else:
                skipped += 1
                continue
        else:                                           # 码在前: code word word ...
            cd = fs[0].strip().lower()
            if not valid_code(cd):
                skipped += 1
                continue
            code = cd
            words = [w for w in fs[1:] if w]
        if code is None or not words:
            skipped += 1
            continue
        lst = acc.get(code)
        if lst is None:
            if len(acc) >= 500000:
                trunc_total += 1
                continue
            lst = []
            acc[code] = lst
        for w in words:
            if not w or w in lst:
                continue
            if ' ' in w:
                skipped += 1
                continue
            if len(lst) >= 300:
                trunc_codes += 1
                break
            lst.append(w)
    return skipped, trunc_codes, trunc_total


def load_import_base(path):
    """读现有 import 文件 -> {code: [words]} (重导入幂等)"""
    acc = {}
    try:
        with open(path, encoding='utf-8') as f:
            for raw in f:
                t = raw.strip()
                if len(t) < 3:
                    continue
                sp = t.find(' ')
                if sp < 1:
                    continue
                k = t[:sp].strip().lower()
                lst = []
                for w in t[sp + 1:].split(' '):
                    if w and w not in lst:
                        lst.append(w)
                if k and lst:
                    acc[k] = lst
    except OSError:
        pass
    return acc


def write_import_file(path, acc):
    """写 import 文件: 'code w1 w2 ...' 每行, 按 code 排序, UTF-8 无 BOM"""
    with open(path, 'w', encoding='utf-8') as f:
        for k in sorted(acc.keys()):
            f.write(k)
            for w in acc[k]:
                f.write(' ' + w)
            f.write('\n')


def suggest_target(file_name):
    """0=五笔 1=拼音 2=英汉"""
    n = (file_name or '').lower()
    if 'wubi' in n or '五笔' in n or n.startswith('wb') or '_wb' in n or '-wb' in n:
        return 0
    if 'english' in n or '英汉' in n or n.startswith('ec') or '_ec' in n or '-ec' in n:
        return 2
    if 'pinyin' in n or '拼音' in n or '双拼' in n or '全拼' in n or n.startswith('py') or '_py' in n or '-py' in n:
        return 1
    if n.endswith('.yaml') or n.endswith('.yml') or n.endswith('.dict'):
        return 0
    return 1


def fuzzy_variants(code):
    """单替换模糊音, 上限 16 (与 FuzzyVariants 一致)"""
    seen = set()
    out = []
    made = 0
    for pr in FUZZY_PAIRS:
        for side in range(2):
            frm, to = pr[side], pr[1 - side]
            pos = 0
            while made < 16:
                at = code.find(frm, pos)
                if at < 0:
                    break
                pos = at + 1
                v = code[:at] + to + code[at + len(frm):]
                if v not in seen:
                    seen.add(v)
                    out.append(v)
                    made += 1
    return out


class Engine:
    CACHE_VER = 1

    def _paths(self):
        ps = [os.path.join(self.dict_dir, n) for n in ('py.txt', 'wb.txt', 'ec.txt', 'trad.txt')]
        ps += [os.path.join(self.dict_dir, n) for n in ('import_py.txt', 'import_wb.txt', 'import_ec.txt')]
        return ps

    def _build(self):
        self.py = parse_dict(os.path.join(self.dict_dir, 'py.txt'))
        self.wb = parse_dict(os.path.join(self.dict_dir, 'wb.txt'))
        self.ec = parse_dict(os.path.join(self.dict_dir, 'ec.txt'))
        overlay_import(self.py, parse_dict(os.path.join(self.dict_dir, 'import_py.txt')))
        overlay_import(self.wb, parse_dict(os.path.join(self.dict_dir, 'import_wb.txt')))
        overlay_import(self.ec, parse_dict(os.path.join(self.dict_dir, 'import_ec.txt')))
        self.pk, self.pv = build_sorted(self.py)
        self.wk, self.wv = build_sorted(self.wb)
        self.ek, self.ev = build_sorted(self.ec)
        self.char_py = build_char_py(self.py)
        self.acro = build_acro(self.py, self.char_py)
        self.ce = build_reverse(self.ec)

    def __init__(self, dict_dir, data_dir):
        t0 = time.time()
        self.data_dir = data_dir
        self.dict_dir = dict_dir
        os.makedirs(data_dir, exist_ok=True)
        if not self._load_cache(self._paths()):
            self._build()
            self._save_cache(self._paths())
        self.load_ms = (time.time() - t0) * 1000
        self._init_state()

    def reload(self):
        """导入码表后热重载: 重建索引 + 刷新缓存."""
        self._build()
        self._save_cache(self._paths())

    def _cache_sig(self, paths):
        return [(os.path.getsize(p), int(os.path.getmtime(p))) if os.path.exists(p) else None for p in paths]

    def _cache_path(self):
        return os.path.join(self.data_dir, 'dict-cache.pkl')

    def _load_cache(self, paths):
        try:
            import pickle
            with open(self._cache_path(), 'rb') as f:
                obj = pickle.load(f)
            if obj.get('ver') != self.CACHE_VER or obj.get('sig') != self._cache_sig(paths):
                return False
            (self.py, self.wb, self.ec, self.pk, self.pv, self.wk, self.wv,
             self.ek, self.ev, self.char_py, self.acro, self.ce) = obj['data']
            return True
        except Exception:
            return False

    def _save_cache(self, paths):
        try:
            import pickle
            obj = {'ver': self.CACHE_VER, 'sig': self._cache_sig(paths),
                   'data': (self.py, self.wb, self.ec, self.pk, self.pv, self.wk, self.wv,
                            self.ek, self.ev, self.char_py, self.acro, self.ce)}
            tmp = self._cache_path() + '.tmp'
            with open(tmp, 'wb') as f:
                pickle.dump(obj, f, protocol=pickle.HIGHEST_PROTOCOL)
            os.replace(tmp, self._cache_path())
        except Exception:
            pass

    def _init_state(self):
        # 词频: 分模式桶 + 合并视图
        self.freq_m = [dict(), dict(), dict()]
        self.lastpick_m = [dict(), dict(), dict()]
        self.freq = {}
        self._load_freq()
        self.freq_dirty = 0
        self.last_save = time.time()
        self._save_lock = threading.Lock()
        # 用户词 (五笔反查字表: 最长码)
        self.user_words = self.load_user_words()
        if self.user_words:
            for w, c in self.user_words.items():
                cur = self.py.get(c)
                if cur:
                    if (' ' + cur + ' ').find(' ' + w + ' ') < 0:
                        self.py[c] = cur + ' ' + w
                else:
                    self.py[c] = w
            self.pk, self.pv = build_sorted(self.py)
        self.char_wb = {}
        for code in sorted(self.wb.keys()):
            if len(code) < 2:
                continue
            for w in self.wb[code].split(' '):
                if len(w) == 1 and (w not in self.char_wb or len(code) > len(self.char_wb[w])):
                    self.char_wb[w] = code
        # 简拼候选按词频重排 (ApplySwap: stable desc by combined freq)
        for k in self.acro:
            lst = self.acro[k]
            if len(lst) > 1:
                self.acro[k] = sorted(lst, key=lambda w: -self.freq.get(w, 0))
        # 造句词频 (pywfreq.txt: word:freq)
        self.word_freq = {}
        wtot = 0
        try:
            with open(os.path.join(self.dict_dir, 'pywfreq.txt'), encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    c = line.rfind(':')
                    if c < 1:
                        continue
                    try:
                        n = int(line[c + 1:])
                    except ValueError:
                        continue
                    self.word_freq[line[:c]] = n
                    wtot += n
        except OSError:
            pass
        self.log_total_w = math.log(max(wtot, 1000))
        # 联想 (commit 二元组)
        self.assoc = {}
        self._load_assoc()
        # 繁简
        self.trad_map = None
        tp = os.path.join(self.dict_dir, 'trad.txt')
        try:
            lines = open(tp, encoding='utf-8').read().split('\n')
            self.trad_map = {}
            for i in range(min(len(lines[0]), len(lines[1]))):
                if lines[0][i] not in self.trad_map:
                    self.trad_map[lines[0][i]] = lines[1][i]
        except (OSError, IndexError):
            self.trad_map = None

    # ---------- freq / lastpick persistence (与 C# 版同格式, 可互换) ----------
    def _load_freq(self):
        for m in range(3):
            p = os.path.join(self.data_dir, 'userdict_%s.txt' % MODE_SUFFIX[m])
            try:
                with open(p, encoding='utf-8') as f:
                    for line in f:
                        sp = line.rstrip('\n').rfind(' ')
                        if sp < 1:
                            continue
                        try:
                            n = int(line[sp + 1:])
                        except ValueError:
                            continue
                        self.freq_m[m][line[:sp]] = n
            except OSError:
                pass
            p = os.path.join(self.data_dir, 'lastpick_%s.txt' % MODE_SUFFIX[m])
            try:
                with open(p, encoding='utf-8') as f:
                    for line in f:
                        sp = line.find(' ')
                        if sp < 1:
                            continue
                        self.lastpick_m[m][line[:sp]] = line[sp + 1:].rstrip('\n')
            except OSError:
                pass
        for b in self.freq_m:
            for k, v in b.items():
                self.freq[k] = self.freq.get(k, 0) + v

    def learn(self, code, w, mode):
        if not w:
            return
        self.freq[w] = self.freq.get(w, 0) + 1
        if len(self.freq) > 90000:
            self.freq.pop(next(iter(self.freq)))
        if 0 <= mode < 3:
            fb = self.freq_m[mode]
            fb[w] = fb.get(w, 0) + 1
            if len(fb) > 30000:
                fb.pop(next(iter(fb)))
            if code:
                lb = self.lastpick_m[mode]
                lb[code] = w
                if len(lb) > 30000:
                    lb.pop(next(iter(lb)))
        self.freq_dirty += 1
        if self.freq_dirty >= 50 or time.time() - self.last_save >= 5:
            self.freq_dirty = 0
            self.last_save = time.time()
            threading.Thread(target=self.save_freq, daemon=True).start()

    # ---------- 造句 (BestSentence: 单字/词一元格架, score=sum(log(f+1))-edges*log_total) ----------
    def best_sentence(self, code):
        n = len(code)
        if n < 4 or n > 32:
            return None
        NEG = float('-inf')
        best = [0.0] + [NEG] * n
        frm = [0] * (n + 1)
        word = [''] * (n + 1)
        for i in range(n):
            if best[i] == NEG:
                continue
            for ln in range(1, min(12, n - i) + 1):
                val = self.py.get(code[i:i + ln])
                if val is None:
                    continue
                bw, bwf = None, -1
                for t in val.split(' '):
                    f = self.word_freq.get(t, 0)
                    if f > bwf:
                        bwf, bw = f, t
                if bw is None:
                    continue
                sc = best[i] + math.log(bwf + 1) - self.log_total_w
                if sc > best[i + ln]:
                    best[i + ln] = sc
                    frm[i + ln] = i
                    word[i + ln] = bw
        if best[n] == NEG:
            return None
        parts = []
        p = n
        while p > 0:
            parts.append(word[p])
            p = frm[p]
        return ''.join(reversed(parts))

    # ---------- 联想 (与 C# Assoc 一致: prev commit -> cur counts) ----------
    def learn_assoc(self, prev, cur):
        if not prev or not cur or prev == cur or len(prev) > 8 or len(cur) > 8:
            return
        if not is_all_cjk(prev) or not is_all_cjk(cur):
            return
        m = self.assoc.get(prev)
        if m is None:
            if len(self.assoc) >= 20000:
                self.assoc.pop(next(iter(self.assoc)))
            m = {}
            self.assoc[prev] = m
        m[cur] = m.get(cur, 0) + 1
        if len(m) > 12:                              # 超上限: 丢最弱
            weak = min(m, key=lambda k: m[k])
            del m[weak]
        self.freq_dirty += 1

    def get_assoc(self, w, limit=9):
        m = self.assoc.get(w)
        if not m:
            return []
        return [k for k, _ in sorted(m.items(), key=lambda kv: -kv[1])[:limit]]

    def _load_assoc(self):
        try:
            with open(os.path.join(self.data_dir, 'assoc.txt'), encoding='utf-8') as f:
                for line in f:
                    tab = line.find('\t')
                    if tab < 1:
                        continue
                    m = {}
                    for t in line[tab + 1:].strip().split(' '):
                        c = t.rfind(':')
                        if c < 1:
                            continue
                        try:
                            m[t[:c]] = int(t[c + 1:])
                        except ValueError:
                            pass
                    if m:
                        self.assoc[line[:tab]] = m
        except OSError:
            pass

    def _save_assoc(self):
        try:
            snap = sorted(self.assoc.items(), key=lambda kv: -sum(kv[1].values()))[:20000]
            with open(os.path.join(self.data_dir, 'assoc.txt'), 'w', encoding='utf-8') as f:
                for k, m in snap:
                    tops = sorted(m.items(), key=lambda kv: -kv[1])[:8]
                    f.write('%s\t%s\n' % (k, ' '.join('%s:%d' % (w, c) for w, c in tops)))
        except OSError:
            pass

    def save_freq(self):
        with self._save_lock:
            try:
                for m in range(3):
                    snaps = sorted(self.freq_m[m].items(), key=lambda kv: -kv[1])[:20000]
                    with open(os.path.join(self.data_dir, 'userdict_%s.txt' % MODE_SUFFIX[m]), 'w', encoding='utf-8') as f:
                        for k, v in snaps:
                            f.write('%s %d\n' % (k, v))
                    lasts = list(self.lastpick_m[m].items())[:20000]
                    with open(os.path.join(self.data_dir, 'lastpick_%s.txt' % MODE_SUFFIX[m]), 'w', encoding='utf-8') as f:
                        for k, v in lasts:
                            f.write('%s %s\n' % (k, v))
                self._save_assoc()
            except OSError:
                pass

    # ---------- candidate assembly (对齐 ShowCharatar) ----------
    def candidates(self, keys, mode, py_code=None):
        """返回 (cands, exact_wubi, extendable). py_code: 双拼展开后的全拼 (mode<2 拼音侧用).
        造句/动态rq/vf/应用启动/短语在 wgime.py refresh 层."""
        if py_code is None:
            py_code = keys
        cands = []
        exact_wubi = [False]
        extendable = [False]

        def add(val):
            for t in val.split(' '):
                if len(cands) >= CAND_CAP:
                    break
                if t and t not in cands:
                    cands.append(t)

        def add_from_dict(d, ks, vs, is_wubi, code):
            exact = d.get(code)
            if exact is not None:
                if is_wubi:
                    exact_wubi[0] = True
                add(exact)
            i = bisect.bisect_left(ks, code)
            while i < len(ks) and ks[i].startswith(code) and len(cands) < CAND_CAP:
                if ks[i] != code:
                    extendable[0] = True
                    for t in vs[i].split(' '):      # 前缀匹配: 只收单字
                        if len(cands) >= CAND_CAP:
                            break
                        if len(t) == 1 and t not in cands:
                            cands.append(t)
                i += 1

        if not keys:
            return cands, False, False
        if mode == 0:
            add_from_dict(self.wb, self.wk, self.wv, True, keys)
            add_from_dict(self.py, self.pk, self.pv, False, py_code)
            add_from_dict(self.ec, self.ek, self.ev, False, keys)   # 英汉 (vest->背心)
        elif mode == 1:
            add_from_dict(self.py, self.pk, self.pv, False, py_code)
            add_from_dict(self.ec, self.ek, self.ev, False, keys)   # 英汉
        elif mode == 2:
            add_from_dict(self.wb, self.wk, self.wv, True, keys)
        else:
            # 词典: EN->CN exact + 前缀, CN->EN 经全拼/简拼反查
            exact = self.ec.get(keys)
            if exact is not None:
                add(exact)
            i = bisect.bisect_left(self.ek, keys)
            while i < len(self.ek) and self.ek[i].startswith(keys) and len(cands) < CAND_CAP:
                if self.ek[i] != keys:
                    first = self.ev[i].split(' ')[0]
                    if first and first not in cands:
                        cands.append(first)
                i += 1
            cn_words = []
            exact = self.py.get(keys)
            if exact:
                for w in exact.split(' '):
                    if w not in cn_words:
                        cn_words.append(w)
            for w in self.acro.get(keys, []):
                if w not in cn_words:
                    cn_words.append(w)
            for cn in cn_words:
                en = self.ce.get(cn)
                if en:
                    add(en)
        if mode < 2:
            for w in self.acro.get(py_code, []):
                if len(cands) >= CAND_CAP:
                    break
                if len(py_code) >= 2 and w not in cands:
                    cands.append(w)
            if len(cands) < PAGE_SIZE:
                for v in fuzzy_variants(py_code):
                    exact = self.py.get(v)
                    if exact:
                        add(exact)
                    if len(cands) >= CAND_CAP:
                        break
        # 字频排序 (稳定, python 版更优, 保留): 语料基础词频 (pywfreq) + 学习词频 (每次提交 +5000)
        # → 常见词天然靠前, 学习词频把用户常用词往上顶; 相比 C# 版(只按学习词频) 结合了语料先验
        fb = self.freq_m[mode] if mode < 3 else self.freq
        if len(cands) > 1 and (fb or self.word_freq):
            cands = sorted(cands, key=lambda w: -(self.word_freq.get(w, 0) + fb.get(w, 0) * 5000))
        if len(cands) > 1 and mode < 3:
            lp = self.lastpick_m[mode].get(keys)
            if lp and lp in cands:
                cands.remove(lp)
                cands.insert(0, lp)
        # 五笔 z 通配 (仅纯五笔模式, 追加在最后, 不参与排序)
        if mode == 2 and 'z' in keys:
            for k in self.wk:
                if len(cands) >= CAND_CAP:
                    break
                if len(k) != len(keys):
                    continue
                ok = True
                for i, ch in enumerate(k):
                    if keys[i] != 'z' and ch != keys[i]:
                        ok = False
                        break
                if ok:
                    for t in self.wb[k].split(' '):
                        if len(cands) >= CAND_CAP:
                            break
                        if t and t not in cands:
                            cands.append(t)
        return cands, exact_wubi[0], extendable[0]

    def to_trad(self, s, enabled):
        if not enabled or not self.trad_map or not s:
            return s
        return ''.join(self.trad_map.get(c, c) for c in s)

    # ---------- 用户词 (与 C# AddUserWord/LoadUserWords 同格式) ----------
    def load_user_words(self):
        uw = {}
        try:
            with open(os.path.join(self.data_dir, 'userwords.txt'), encoding='utf-8') as f:
                for raw in f:
                    t = raw.strip()
                    sp = t.find(' ')
                    if sp < 1:
                        continue
                    for w in t[sp + 1:].split(' '):
                        if w:
                            uw[w] = t[:sp]
        except OSError:
            pass
        return uw

    def save_user_words(self):
        try:
            by_code = {}
            for w, c in self.user_words.items():
                by_code.setdefault(c, []).append(w)
            with open(os.path.join(self.data_dir, 'userwords.txt'), 'w', encoding='utf-8') as f:
                for c, ws in by_code.items():
                    f.write('%s %s\n' % (c, ' '.join(ws)))
        except OSError:
            pass

    def code_for(self, w):
        """全拼码 (CodeFor: 每字取第一个拼音)"""
        out = []
        for ch in w:
            ps = self.char_py.get(ch)
            if not ps:
                return None
            out.append(ps[0])
        return ''.join(out)

    def wubi_code_for(self, w):
        """五笔 86 构词码 (WubiCodeFor)"""
        n = len(w)
        if n < 2:
            return None
        cs = []
        for ch in w:
            c = self.char_wb.get(ch)
            if not c:
                return None
            cs.append(c)
        if n == 2:
            return cs[0][:2] + cs[1][:2]
        if n == 3:
            return cs[0][0] + cs[1][0] + cs[2][:2]
        return cs[0][0] + cs[1][0] + cs[2][0] + cs[n - 1][0]

    def add_user_word(self, word, code):
        """造词: 进拼音表 + 排序数组重建 + 简拼索引 + 五笔表 (双注册)"""
        if not code or word in self.user_words:
            return False
        cur = self.py.get(code)
        if cur and (' ' + cur + ' ').find(' ' + word + ' ') >= 0:
            return False
        self.user_words[word] = code
        self.py[code] = (cur + ' ' + word) if cur else word
        self.pk, self.pv = build_sorted(self.py)
        wbc = self.wubi_code_for(word)
        if wbc:
            curw = self.wb.get(wbc)
            if not (curw and (' ' + curw + ' ').find(' ' + word + ' ') >= 0):
                self.wb[wbc] = (curw + ' ' + word) if curw else word
                self.wk, self.wv = build_sorted(self.wb)
        ini = []
        ok = True
        for ch in word:
            ps = self.char_py.get(ch)
            if ps:
                ini.append(ps[0][0])
            else:
                ok = False
                break
        if ok:
            lst = self.acro.setdefault(''.join(ini), [])
            if word not in lst:
                lst.append(word)
        self.save_user_words()
        return True
