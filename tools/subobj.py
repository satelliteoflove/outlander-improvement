#!/usr/bin/env python3
"""Reads tools/subobj.lua's list (a SUBMOVE=0 build) and says which objects the in-between
frames draw unlike their game step, by type of object and kind of difference.

  python3 tools/build.py SUBMOVE=0
  python3 tools/run.py build/outlander-sa1.sfc --frames 5800 --lua build/sym.lua --lua tools/subobj.lua --out build/subobj
  python3 tools/subobj.py build/subobj/subobj.txt [-v]      # -v: every differing object
  python3 tools/build.py
"""
import collections, sys

frames, cur = [], None
for l in open(sys.argv[1]):
    f = l.split()
    if f[0] == 'F':
        cur = {'vb': int(f[1]), 'kind': f[2], 'objs': collections.OrderedDict()}; frames.append(cur)
    elif f[0] == 'O' and cur is not None:
        cur['objs'][f[1]] = {'ty': f[2], 'draw': (f[3], f[4], f[5], f[6]), 'rec': f[7], 'n': int(f[3]) + int(f[5])}
verbose = '-v' in sys.argv
tally, steps, subs, bad_frames, step = collections.Counter(), 0, 0, 0, None
first = {}
for fr in frames:
    if fr['kind'] == 'STEP':
        step = fr; steps += 1; continue
    if step is None: continue
    subs += 1
    bad = False
    for slot in list(step['objs']) + [s for s in fr['objs'] if s not in step['objs']]:
        a, b = step['objs'].get(slot), fr['objs'].get(slot)
        if a and b and a['draw'] == b['draw']: continue
        if a and b:
            what = 'drawn otherwise' if a['n'] and b['n'] else ('drawn by the step only' if a['n'] else 'drawn in between only')
            if a['ty'] != b['ty']: what += ' (type %s then)' % a['ty']
        elif a: what = 'drawn by the step only: not in the pass in between' if a['n'] else None
        else: what = 'drawn in between only: not in the step\'s pass' if b['n'] else None
        if what is None: continue
        ty = (b or a)['ty'] if slot != 'pre' else 'before the pass'
        key = (ty, what); tally[key] += 1; bad = True
        first.setdefault(key, (step['vb'], fr['vb'], slot))
        if verbose:
            print('step at %d, %s at %d: slot %s type %s %s\n    step %s %s\n    sub  %s %s' % (
                step['vb'], fr['kind'], fr['vb'], slot, ty, what,
                a and ' '.join(a['draw']), a and a['rec'], b and ' '.join(b['draw']), b and b['rec']))
    bad_frames += bad
print('%d game steps, %d in-between frames, %d with an object drawn unlike the step' % (steps, subs, bad_frames))
for (ty, what), n in sorted(tally.items(), key=lambda x: -x[1]):
    print('  %5d  type %-15s %-50s first: step at vblank %d, in-between at %d, slot %s' % ((n, ty, what) + first[(ty, what)]))
