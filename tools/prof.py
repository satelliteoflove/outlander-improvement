#!/usr/bin/env python3
"""Time profile of the SA-1 inside the driving block, by routine and by instruction.

  tools/prof.py record [--from 1900] [--blocks 6] [--input "1000-1005:start;1310-:y"] [-o build/prof.txt]
  tools/prof.py report [build/prof.txt] [--top 30]          # routines, exclusive time
  tools/prof.py lines  [build/prof.txt] 21CC3B [21CD40]     # annotated listing of an address range
  tools/prof.py diff   a.txt b.txt                          # routine times side by side

record runs build/outlander-sa1.sfc in Mesen with tools/prof.lua (about 25 s per pass through
the block).  With no --input the attract demo plays; driving starts near vblank 2150 there.
Times are in vblanks per pass (357,366 master clocks); "%" is of the block's total.
"""
import argparse, bisect, os, re, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from dis import OPS, MODES
VB = 357366.0
ROM = 'build/outlander-sa1.sfc'


def off(addr):
    """SA-1 view of the 4 MB image as build.py lays it out (sa1rom 0,1,0,3)."""
    bank = addr >> 16
    block = {0: 0, 1: 1, 4: 0, 5: 3}[bank >> 5]
    return (block << 20) + (bank & 0x1F) * 0x8000 + (addr & 0x7FFF)


def decode(rom, addr, p):
    o = off(addr); op = rom[o]; mn, mode = OPS[op]
    n, fmt = MODES[mode]
    if n == 'm': n = 1 if p & 0x20 else 2
    if n == 'x': n = 1 if p & 0x10 else 2
    b = rom[o + 1:o + 1 + n]; v = int.from_bytes(b, 'little'); tgt = None
    if mode == 'rel':
        tgt = (addr & 0xFF0000) | ((addr + 2 + (v - 256 if v > 127 else v)) & 0xFFFF); s = '$%04X' % (tgt & 0xFFFF)
    elif mode == 'rell':
        tgt = (addr & 0xFF0000) | ((addr + 3 + (v - 65536 if v > 32767 else v)) & 0xFFFF); s = '$%04X' % (tgt & 0xFFFF)
    elif mode == 'blk': s = '$%02X,$%02X' % (b[1], b[0])
    else:
        s = fmt.format(v, w=n * 2)
        if mn in ('JSR', 'JMP') and mode == 'abs': tgt = (addr & 0xFF0000) | v
        if mn in ('JSL', 'JML') and mode == 'long': tgt = v
    return 1 + n, (mn + ' ' + s).strip(), tgt, rom[o:o + 1 + n]


def load(path):
    d = {}; hdr = {}
    for l in open(path):
        f = l.split()
        if f[0] == '#':
            hdr = dict(zip(f[1::2], map(int, f[2::2]))); continue
        d[int(f[0], 16)] = (int(f[1]), int(f[2]), int(f[3], 16))
    return hdr, d


def symbols():
    """Global labels of the build (the [labels] section of the WLA symbol file)."""
    s = {}; sec = ''
    try:
        for l in open('build/outlander-sa1.sym'):
            l = l.strip()
            if l.startswith('['): sec = l; continue
            f = l.split()
            if sec == '[labels]' and len(f) == 2 and re.fullmatch(r'[0-9A-Fa-f]{2}:[0-9A-Fa-f]{4}', f[0]) \
               and re.fullmatch(r'[A-Za-z_]\w*', f[1]):
                s[int(f[0].replace(':', ''), 16)] = f[1]
    except OSError: pass
    return s


def routines(rom, d):
    """-> {entry: [clocks, count, calls]}; entries are JSR/JSL targets seen, plus symbols."""
    sym = symbols(); ent = set(a for a in sym if a in d)
    for ad, (c, t, p) in d.items():
        ln, txt, tgt, _ = decode(rom, ad, p)
        if tgt is not None and txt[:3] in ('JSR', 'JSL'): ent.add(tgt)
    es = sorted(ent); r = {}
    for ad, (c, t, p) in d.items():
        i = bisect.bisect_right(es, ad) - 1
        e = es[i] if i >= 0 and (es[i] >> 16) == (ad >> 16) else (ad & 0xFF0000)
        x = r.setdefault(e, [0, 0, 0]); x[0] += t; x[1] += c
        if ad == e: x[2] = c
    return r, sym


def record(a):
    lua = 'PROF_FROM = %d\nPROF_BLOCKS = %d\nPROF_PATH = "%s"\n' % (a.start, a.blocks, os.path.abspath(a.o))
    sym = subprocess.run([sys.executable, 'tools/symlua.py'], stdout=subprocess.PIPE, text=True, check=True).stdout
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as f:
        f.write(sym + lua); path = f.name
    try:
        subprocess.run([sys.executable, 'tools/run.py', a.rom, '--frames', str(a.start + 100 * a.blocks + 200),
                        '--input', a.input, '--lua', path, '--lua', 'tools/prof.lua', '--out', 'build/shots_prof',
                        '--timeout', '3000'])
    finally:
        os.unlink(path)


def report(a):
    rom = open(ROM, 'rb').read(); hdr, d = load(a.file); r, sym = routines(rom, d)
    n = hdr.get('blocks', 1); tot = sum(x[0] for x in r.values())
    print('%d passes, %.3f vblanks each; %.3f of that while the S-CPU was in an interrupt handler'
          % (n, tot / n / VB, hdr.get('scpu_irq_clocks', 0) / n / VB))
    print('  routine     vblanks      %   instr/pass  calls/pass  clocks/instr')
    for e, (t, c, k) in sorted(r.items(), key=lambda x: -x[1][0])[:a.top]:
        print('  %06X     %7.4f  %5.1f  %10.0f  %10.1f  %6.1f  %s' % (e, t / n / VB, 100.0 * t / tot, c / n, k / n, t / c, sym.get(e, '')))


def lines(a):
    rom = open(ROM, 'rb').read(); hdr, d = load(a.file); n = hdr.get('blocks', 1)
    tot = sum(x[1] for x in d.values()); lo = int(a.lo, 16); hi = int(a.hi, 16) if a.hi else lo + 0x200
    prev = None
    for ad in sorted(x for x in d if lo <= x <= hi):
        c, t, p = d[ad]; ln, txt, tgt, raw = decode(rom, ad, p)
        if prev is not None and ad != prev: print('        ...')
        print('%06X %8.1f %6.2f%%  %-10s %s' % (ad, c / n, 100.0 * t / tot, raw.hex().upper(), txt)); prev = ad + ln


def diff(a):
    rom = open(ROM, 'rb').read(); ha, da = load(a.a); hb, db = load(a.b)
    ra, _ = routines(rom, da); rb, sym = routines(rom, db); na, nb = ha.get('blocks', 1), hb.get('blocks', 1)
    rows = [(ra.get(e, [0])[0] / na / VB, rb.get(e, [0])[0] / nb / VB, e) for e in set(ra) | set(rb)]
    print('  total       %7.4f  %7.4f' % (sum(x[0] for x in rows), sum(x[1] for x in rows)))
    for x, y, e in sorted(rows, key=lambda r: -max(r[0], r[1]))[:40]:
        print('  %06X     %7.4f  %7.4f  %+8.4f  %s' % (e, x, y, y - x, sym.get(e, '')))


def main():
    os.chdir(os.path.dirname(HERE))
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    p = sp.add_parser('record'); p.add_argument('--from', dest='start', type=int, default=1900)
    p.add_argument('--blocks', type=int, default=6); p.add_argument('--input', default='')
    p.add_argument('-o', default='build/prof.txt'); p.add_argument('--rom', default=ROM); p.set_defaults(fn=record)
    p = sp.add_parser('report'); p.add_argument('file', nargs='?', default='build/prof.txt')
    p.add_argument('--top', type=int, default=30); p.set_defaults(fn=report)
    p = sp.add_parser('lines'); p.add_argument('file'); p.add_argument('lo'); p.add_argument('hi', nargs='?'); p.set_defaults(fn=lines)
    p = sp.add_parser('diff'); p.add_argument('a'); p.add_argument('b'); p.set_defaults(fn=diff)
    a = ap.parse_args(); a.fn(a)


if __name__ == '__main__':
    main()
