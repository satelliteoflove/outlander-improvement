#!/usr/bin/env python3
"""Static disassembly of everything reachable from an entry point, traced or not.

  tools/sdis.py Outlander.sfc build/cov.txt 81CC3B [--range 81D09C-81D17A]
  tools/sdis.py Outlander.sfc build/cov.txt blk --range 80D430-80D460     # the driving block

Flags, direct page and data bank come from the trace where it has them and are propagated
otherwise (tools/mkpatch.py).  Untraced instructions are marked with '*'.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dis import decode, load_cov
from mkpatch import Walker

ap = argparse.ArgumentParser(); ap.add_argument('rom'); ap.add_argument('cov'); ap.add_argument('entry')
ap.add_argument('--range')
a = ap.parse_args()
rom = open(a.rom, 'rb').read(); cov = load_cov(a.cov)
state = {}


class W(Walker):
    def rules(self, pc, mn, mode, n, v, raw, m):
        Walker.rules(self, pc, mn, mode, n, v, raw, m)
        state[pc] = (self.d, self.db)


if a.entry == 'blk':
    w = W(rom, cov, stop=[0x81DB9E]); w.ends = {0x008F14, 0x008E41, 0x008D92}
    w.tables = {0x809F5C: 18, 0x809F80: 18, 0x80B92B: 26, 0x80C76A: 5, 0x80BDB3: 26, 0x80AED6: 18}
    seeds = [0x008D12] + sorted(x for x in load_cov(os.path.join(os.path.dirname(a.cov), 'cov_blk.txt'))
                                if (x & 0xFFFF) >= 0x8000 and x in cov)
else:
    w = W(rom, cov); seeds = [int(a.entry, 16)]
for e in seeds:
    if e in w.seen: continue
    p = cov[e][1] if e in cov else 0x20
    w.walk_sub(e, bool(p & 0x20), bool(p & 0x10))
lo, hi = (int(x, 16) for x in a.range.split('-')) if a.range else (0, 0xFFFFFF)
prev = None
for ad in sorted(w.seen):
    if not lo <= ad <= hi: continue
    m, x = w.seen[ad]
    ln, txt, tgt, raw = decode(rom, ad, (0x20 if m else 0) | (0x10 if x else 0))
    if prev is not None and ad != prev: print('        ...')
    d, db = state.get(ad, (0, None))
    print('%06X %s %-10s %-18s D=%04X DB=%s' % (ad, ' ' if ad in cov else '*', raw.hex().upper(), txt, d,
                                                  '??' if db is None else '%02X' % db))
    prev = ad + ln
