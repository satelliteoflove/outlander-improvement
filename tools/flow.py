#!/usr/bin/env python3
"""Summarise tools/flow.lua output: what must be copied to the SA-1 before the driving block
and back after it.

  tools/flow.py build/flow_*.txt [--gap 8]

  to SA-1  = block inputs that the S-CPU side writes
  to S-CPU = block outputs that the S-CPU side reads before writing them itself
"""
import sys
gap = 8; files = []; it = iter(sys.argv[1:])
for a in it:
    if a == '--gap': gap = int(next(it))
    else: files.append(a)
F = {}
for p in files:
    for l in open(p):
        a, _, fl = l.strip().partition(' '); F.setdefault(int(a, 16), set()).update(fl)


def rng(s):
    out = []
    for x in sorted(s):
        if out and x <= out[-1][1] + gap: out[-1][1] = x
        else: out.append([x, x])
    return out


def show(title, s):
    r = rng(s); tot = sum(b - a + 1 for a, b in r)
    print('%s: %d bytes used, %d in %d ranges (gaps up to %d merged)' % (title, len(s), tot, len(r), gap))
    line = '   '
    for a, b in r:
        t = '%04X-%04X ' % (a, b) if a != b else '%04X ' % a
        if len(line) + len(t) > 110: print(line); line = '   '
        line += t
    print(line)


def sel(pred, lo, hi): return set(a for a, f in F.items() if lo <= a <= hi and pred(f))


for name, lo, hi in (('low RAM', 0, 0x7FF), ('$7E:2000-$30E4', 0x2000, 0x30E4), ('frame buffer', 0x30E5, 0x70E4),
                     ('$7E:70E5-$7FFF', 0x70E5, 0x7FFF)):
    print('==== ' + name)
    show('  block inputs          ', sel(lambda f: 'I' in f, lo, hi))
    show('  block outputs         ', sel(lambda f: 'O' in f, lo, hi))
    show('  to SA-1  (I and w/x)  ', sel(lambda f: 'I' in f and ('w' in f or 'x' in f), lo, hi))
    show('  to S-CPU (O and r)    ', sel(lambda f: 'O' in f and 'r' in f, lo, hi))
    show('  S-CPU reads while the SA-1 runs, of block outputs', sel(lambda f: 'O' in f and 'y' in f, lo, hi))
    show('  S-CPU writes while the SA-1 runs, of block inputs or outputs', sel(lambda f: 'x' in f and ('I' in f or 'O' in f), lo, hi))
