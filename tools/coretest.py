#!/usr/bin/env python3
"""Run a ROM in another emulator (a libretro core) and report how it behaves there.

  tools/coretest.py CORE ROM SCENARIO OUTDIR      # CORE: bsnes or snes9x; one run
  tools/coretest.py all                           # every core, both ROMs, every scenario

Scenarios: demo (the attract demo, nobody at the pad), drive (a new game, accelerator held,
until the car leaves the road and the game goes on foot), foot (the level 12 password: walk
right, kept alive, until the drive starts, then accelerate).  Reported from work RAM, once per
frame: vblanks per shown frame ($DC changes at each flip), vblanks per game step ($2C changes
once per step, on the patched ROM too), when each scene starts, and on foot how far the player
walks.  Every 240th frame goes on <OUT>/sheet.png, to be looked at.
"""
import collections, ctypes, json, os, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
CORES = {'bsnes': 'bsnes_mercury_accuracy_libretro.so', 'snes9x': 'snes9x_libretro.so'}
ROMS = {'orig': 'Outlander.sfc', 'sa1': 'build/outlander-sa1.sfc'}
FRAMES = {'demo': 5900, 'drive': 3700, 'foot': 8000}
PASSWORD = 'S7*C*JN*HPMFBG2'


def hist(gaps):
    c = collections.Counter(gaps)
    return {'n': len(gaps), 'mean': round(sum(gaps) / len(gaps), 2) if gaps else None, 'hist': {str(k): c[k] for k in sorted(c)}}


def run(core, rom, scen, out):
    os.environ['SNES_CORE'] = os.path.expanduser('~/.config/retroarch/cores/' + CORES[core])
    import emu, numpy as np
    from PIL import Image
    os.makedirs(out, exist_ok=True)
    e = emu.Emu(rom, core=os.environ['SNES_CORE'])
    inp = []
    if scen == 'drive': inp = emu.parse_input('1000-1005:start;1310-:y')
    if scen == 'foot':
        s = subprocess.run([sys.executable, os.path.join(ROOT, 'tools/password.py'), PASSWORD], stdout=subprocess.PIPE, text=True, check=True).stdout
        inp = emu.parse_input(next(l for l in s.splitlines() if not l.startswith('#')))
    ptr = e.core.retro_get_memory_data(2)
    w = (ctypes.c_ubyte * 0x20000).from_address(ptr)
    prev_dc = prev_2c = None; last_dc = last_2c = None
    flips, steps, scenes, sheet = [], [], [], []
    scene = None; foot_x = {}; foot_at = None; drive_after = None
    for f in range(1, FRAMES[scen] + 1):
        m = 0
        for a, b, c in inp:
            if a <= f <= b: m |= c
        if scen == 'foot' and f > 2750:
            if w[0] == 1: m = emu.parse_buttons('right')
            elif foot_at is not None: m = emu.parse_buttons('y')
        e.run(1, m)
        s, dc, c2 = w[0], w[0xDC], w[0x2C]
        if s != scene: scenes.append((f, s)); scene = s
        if scen == 'foot' and f > 2000 and s == 1:
            w[0x404], w[0x405] = 0xFF, 0x01
            if foot_at is None: foot_at = f
            k = f - foot_at
            if k in (60, 360): foot_x[k] = w[0xCB3D] + w[0xCB3E] * 256
        if s == 0 and f > 1100:
            if dc != prev_dc:
                if last_dc is not None and f - last_dc <= 40: flips.append(f - last_dc)
                last_dc = f
            if c2 != prev_2c:
                if last_2c is not None and f - last_2c <= 40: steps.append(f - last_2c)
                last_2c = f
        prev_dc, prev_2c = dc, c2
        if f % 240 == 0 and f >= 960 and e.frame is not None: sheet.append(e.frame.copy())
    r = {'core': core, 'rom': os.path.basename(rom), 'scenario': scen, 'flips': hist(flips), 'steps': hist(steps),
         'scenes': scenes[:12], 'last_step_frame': last_2c, 'health': w[0x404] + w[0x405] * 256}
    if len(foot_x) == 2: r['walk_300'] = (foot_x[360] - foot_x[60]) & 0xFFFF
    json.dump(r, open(os.path.join(out, 'result.json'), 'w'))
    if sheet:
        h, wd = 224, 256; cols = 6; rows = (len(sheet) + cols - 1) // cols
        im = Image.new('RGB', (cols * wd, rows * h))
        for i, fr in enumerate(sheet):
            im.paste(Image.fromarray(fr[:h * (fr.shape[0] // h)][:: fr.shape[0] // h][:h, :: max(1, fr.shape[1] // wd)]), ((i % cols) * wd, (i // cols) * h))
        im.save(os.path.join(out, 'sheet.png'))
    print(json.dumps(r))


if __name__ == '__main__':
    os.chdir(ROOT)
    if sys.argv[1:] == ['all']:
        jobs = [(c, r, s) for c in CORES for r in ROMS for s in FRAMES]
        procs, n = [], max(1, (os.cpu_count() or 2) - 1)
        for c, r, s in jobs:
            while sum(p.poll() is None for p in procs) >= n:
                import time; time.sleep(0.5)
            d = 'build/coretest/%s-%s-%s' % (c, r, s); os.makedirs(d, exist_ok=True)
            procs.append(subprocess.Popen([sys.executable, __file__, c, ROMS[r], s, d], stdout=open(d + '/log.txt', 'w'), stderr=subprocess.STDOUT))
        for p in procs: p.wait()
        print('exit codes', [p.returncode for p in procs])
    else:
        run(*sys.argv[1:5])
