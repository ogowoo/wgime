# -*- coding: utf-8 -*-
"""wgime-py engine: dict loading + lookup (phase 0: pinyin only)."""
import time


class Engine:
    def __init__(self, dict_dir):
        t0 = time.time()
        self.py = {}            # code -> [words in freq order]
        with open(dict_dir + '/py.txt', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line or ' ' not in line:
                    continue
                code, words = line.split(' ', 1)
                self.py[code] = words.split(' ')
        self.load_ms = (time.time() - t0) * 1000

    def lookup(self, code, limit=9):
        return (self.py.get(code) or [])[:limit]
