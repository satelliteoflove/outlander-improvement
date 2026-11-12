#!/usr/bin/env python3
"""Summarise tools/ramio.lua output:  ramio_report.py file... [--lo ADDR --hi ADDR]"""
import collections, sys
args = [a for a in sys.argv[1:] if not a.startswith('--')]
lo = int(sys.argv[sys.argv.index('--lo') + 1], 16) if '--lo' in sys.argv else 0x7E2000
hi = int(sys.argv[sys.argv.index('--hi') + 1], 16) if '--hi' in sys.argv else 0x7FFFFF
args = [a for a in args if not all(c in '0123456789ABCDEFabcdef' for c in a)]
A = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0, 0]))
for p in args:
    for l in open(p):
        r = l.split()
        if r[1] == 'REG': continue
        v = A[r[0]][int(r[1], 16)]; v[0] += int(r[2][2:]); v[1] += int(r[3][2:]); v[2] |= int(r[4][3:])
def rng(s, gap=16):
    out = []
    for x in sorted(s):
        if out and x <= out[-1][1] + gap: out[-1][1] = x
        else: out.append([x, x])
    return ' '.join('%04X-%04X' % (p & 0xffff, q & 0xffff) if p != q else '%04X' % (p & 0xffff) for p, q in out)
for k in sorted(A):
    sel = {a: v for a, v in A[k].items() if lo <= a <= hi}
    print('%-5s reads  : %s' % (k, rng(a for a, v in sel.items() if v[0])))
    print('%-5s inputs : %s' % (k, rng(a for a, v in sel.items() if v[2])))
    print('%-5s writes : %s' % (k, rng(a for a, v in sel.items() if v[1])))
