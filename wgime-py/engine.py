# -*- coding: utf-8 -*-
"""wgime-py engine: dict loading, candidate assembly, freq learning.

逐行对齐 C# WordBoard 语义 (wgime.bat):
- 码表格式: "code word1 word2 ..." (小写 code; 文件源不拆 packed chars)
- 候选顺序 (ShowCharatar): exact dict -> prefix 单字 -> 简拼 -> 模糊音 -> 词频排序(稳定) -> lastpick 置顶
- 模式: 0=混合(五笔先) 1=拼音 2=五笔 3=词典(英汉/汉英)
- 词频: FreqM[mode] 分桶 + Freq 合并视图; userdict_{mix,py,wb}.txt / lastpick_*.txt 与 C# 版同格式
"""
import bisect
import os
import threading
import time

CAND_CAP = 60
PAGE_SIZE = 9
MODE_SUFFIX = ('mix', 'py', 'wb')
FUZZY_PAIRS = (('zh', 'z'), ('ch', 'c'), ('sh', 's'), ('ang', 'an'), ('eng', 'en'), ('ing', 'in'), ('n', 'l'))


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

    def __init__(self, dict_dir, data_dir):
        t0 = time.time()
        self.data_dir = data_dir
        os.makedirs(data_dir, exist_ok=True)
        paths = [os.path.join(dict_dir, n) for n in ('py.txt', 'wb.txt', 'ec.txt')]
        paths.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'trad.txt'))
        if not self._load_cache(paths):
            self.py = parse_dict(paths[0])
            self.wb = parse_dict(paths[1])
            self.ec = parse_dict(paths[2])
            self.pk, self.pv = build_sorted(self.py)
            self.wk, self.wv = build_sorted(self.wb)
            self.ek, self.ev = build_sorted(self.ec)
            self.char_py = build_char_py(self.py)
            self.acro = build_acro(self.py, self.char_py)
            self.ce = build_reverse(self.ec)
            self._save_cache(paths)
        self.load_ms = (time.time() - t0) * 1000
        self._init_state()

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
        # 繁简
        self.trad_map = None
        tp = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'trad.txt')
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
            except OSError:
                pass

    # ---------- candidate assembly (对齐 ShowCharatar) ----------
    def candidates(self, keys, mode):
        """返回 (cands, exact_wubi, extendable). 不含: 造句/动态rq/vf/应用启动/短语/通配 (后续阶段)."""
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
            add_from_dict(self.py, self.pk, self.pv, False, keys)
        elif mode == 1:
            add_from_dict(self.py, self.pk, self.pv, False, keys)
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
            for w in self.acro.get(keys, []):
                if len(cands) >= CAND_CAP:
                    break
                if len(keys) >= 2 and w not in cands:
                    cands.append(w)
            if len(cands) < PAGE_SIZE:
                for v in fuzzy_variants(keys):
                    exact = self.py.get(v)
                    if exact:
                        add(exact)
                    if len(cands) >= CAND_CAP:
                        break
        # 词频排序 (稳定) + lastpick 置顶
        fb = self.freq_m[mode] if mode < 3 else self.freq
        if len(cands) > 1 and fb:
            cands = sorted(cands, key=lambda w: -fb.get(w, 0))
        if len(cands) > 1 and mode < 3:
            lp = self.lastpick_m[mode].get(keys)
            if lp and lp in cands:
                cands.remove(lp)
                cands.insert(0, lp)
        return cands, exact_wubi[0], extendable[0]

    def to_trad(self, s, enabled):
        if not enabled or not self.trad_map or not s:
            return s
        return ''.join(self.trad_map.get(c, c) for c in s)
