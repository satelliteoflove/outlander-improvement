#!/usr/bin/env python3
"""Merge coverage files from tools/cov.lua:  covmerge.py out.txt in1.txt in2.txt ..."""
import sys
cov = {}
for p in sys.argv[2:]:
    for l in open(p):
        a, c, f = l.split(None, 2)
        if a in cov: cov[a] = (cov[a][0] + int(c), cov[a][1])
        else: cov[a] = (int(c), f.strip())
with open(sys.argv[1], 'w') as f:
    for a in sorted(cov): f.write('%s %d %s\n' % (a, cov[a][0], cov[a][1]))
print('%s: %d addresses' % (sys.argv[1], len(cov)))
