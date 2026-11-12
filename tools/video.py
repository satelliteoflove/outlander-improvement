#!/usr/bin/env python3
"""A before-and-after video: one playthrough, shown on the original and on the patched ROM
side by side, each with its frame rate and how busy its CPUs are.

  tools/video.py play                 # 1. play the patched ROM in Mesen's window; close it when done
  tools/video.py play --demo          #    or: the game's attract demo, which needs no window and no player
  tools/video.py render               # 2. replay on both ROMs without a window, compare, make the video
  tools/video.py compose --start 3 --seconds 45     # the video again from what render captured
  tools/video.py serve                # a page with the video, for other machines on the LAN (port 8000)

play     puts the game at the title screen (a savestate of this build) and records the pad
         while you play (tools/vrec.lua): press Start, drive.  Leave the map alone (Start
         while driving): only the driving scene can be replayed on the other ROM.  The take is
         build/video/take.txt; a rebuilt ROM needs a new take.
render   replays the take on the patched ROM vblank for vblank, exactly as played, and on the
         original step for step (the two reach a given step of the game at different times, so
         the original is given the buttons each step found; tools/play.lua works the same way).
         Both runs must leave the same game state after every step, and the patched run must
         be the one that was played: render says so, or stops.  Captured per ROM into
         build/video/{orig,sa1}: every frame (v*.png), the sound (audio.wav, through
         tools/wavrec.c) and per-vblank figures (stats.txt: tools/vcap.lua).
compose  build/video/outlander-sa1.mp4, 1920x1080.  Both clips start at their first frame of
         the driving scene and run in real time.  --start/--seconds pick the part (default:
         from 1 s before the scene to its end, 60 s at most); --audio sa1|orig|both.

How busy a CPU is: the share of each vblank's master clocks it spends outside a wait loop
(a loop that reads one byte of RAM and branches back until an interrupt or the other CPU
changes it; found by pattern in the ROM, wait_loops() below).  Frames per second: flips of
the driving scene's frame buffer ($00:81C5) in the last 60 vblanks.
"""
import argparse, hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ORIG = os.path.join(ROOT, 'Outlander.sfc')
SA1 = os.path.join(ROOT, 'build/outlander-sa1.sfc')
V = os.path.join(ROOT, 'build/video')
T = os.path.join(ROOT, 'tools')
STATE_AT = 780                  # the title screen, "PRESS START" (the demo starts near 2100)
BTN = 'a b x y l r up down left right select start'.split()
BITS = {'a': 0x80, 'x': 0x40, 'l': 0x20, 'r': 0x10, 'b': 0x8000, 'y': 0x4000, 'select': 0x2000,
        'start': 0x1000, 'up': 0x800, 'down': 0x400, 'left': 0x200, 'right': 0x100}


def sha1(path):
    return hashlib.sha1(open(path, 'rb').read()).hexdigest()


def names(word):
    return ' '.join(b for b in BTN if word & BITS[b]) or '-'


def run(rom, frames, luas, out, load=None, env=None, timeout=3600):
    cmd = [sys.executable, os.path.join(T, 'run.py'), rom, '--frames', str(frames), '--out', out,
           '--timeout', str(timeout)]
    if load: cmd += ['--load', load]
    for l in luas: cmd += ['--lua', l]
    e = dict(os.environ); e.update(env or {})
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=e)
    if p.returncode:
        sys.exit(p.stdout + '\nrun.py failed for ' + rom)
    return p.stdout


def sym_lua():
    p = os.path.join(ROOT, 'build/sym.lua')
    if not os.path.exists(p): sys.exit('no build/sym.lua: run tools/build.py')
    return p


# ---- wait loops, by pattern
def wait_loops(rom, patched):
    """Addresses of the instructions of every loop that only reads a byte and branches back:
    LDA dp / [CMP #n] / Bxx self (the game waits for its interrupt handlers this way in every
    scene), and in the patch's own megabyte LDA long / Bxx self, with or without a SEP in
    front (the SA-1 waiting for work or for the S-CPU's word)."""
    d = open(rom, 'rb').read()
    s, a = set(), set()
    def addr(o, bank0): return ((bank0 + (o >> 15)) << 16) | 0x8000 | (o & 0x7FFF)
    def both(o, offs, bank0=0x80):
        for x in offs:
            v = addr(o + x, bank0); s.add(v)
            if bank0 == 0x80: s.add(v & 0x7FFFFF)
    def scan(lo, hi, bank0):
        for m in re.finditer(rb'\xA5[\x00-\xFF]\xC9[\x00-\xFF][\xD0\xF0\x90\xB0]\xFA', d[lo:hi], re.S):
            both(m.start(), (0, 2, 4), bank0) if bank0 == 0x80 else [s.add(addr(m.start() + x, bank0)) for x in (0, 2, 4)]
        for m in re.finditer(rb'\xA5[\x00-\xFF][\xD0\xF0]\xFC', d[lo:hi], re.S):
            both(m.start(), (0, 2), bank0) if bank0 == 0x80 else [s.add(addr(m.start() + x, bank0)) for x in (0, 2)]
    scan(0, 0x100000, 0x80)
    if patched:
        lo = 0x300000
        scan(lo, len(d), 0xA0)
        blk = d[lo:]
        for m in re.finditer(rb'\xAF[\x00-\xFF]{2}\x00[\xD0\xF0]\xFA', blk, re.S):
            for x in (0, 4): a.add(addr(m.start() + x, 0xA0)); s.add(addr(m.start() + x, 0xA0))
        for m in re.finditer(rb'\xE2\x20\xAF[\x00-\xFF]{2}\x00[\xD0\xF0]\xF8', blk, re.S):
            for x in (0, 2, 6): a.add(addr(m.start() + x, 0xA0))
    return sorted(s), sorted(a)


def lua_list(xs):
    return '{' + ','.join('0x%06X' % x for x in xs) + '}'


# ---- the take
class Take:
    def __init__(self, path):
        self.pads, self.samples, self.steps, self.last = {}, [], [], 0
        for l in open(path):
            f = l.split()
            if not f or f[0] == 'take': continue
            n = int(f[1]); self.last = max(self.last, n)
            if f[0] == 'p': self.pads[n] = ' '.join(f[2:])
            elif f[0] == 's': self.samples.append((n, int(f[2], 16)))
            elif f[0] == 'x': self.steps.append((n, f[2]))
    def idle(self):
        """Nobody touched the pad: the take is the game's attract demo."""
        return not any(v != '-' for v in self.pads.values())
    def events(self):
        return [('s', '%04X' % v) for _, v in self.samples], [h for _, h in self.steps]


def read_steps(path):
    s, x = [], []
    for l in open(path):
        f = l.split()
        if f[0] == 's': s.append((int(f[1]), f[2]))
        elif f[0] == 'x': x.append((int(f[1]), f[2]))
    return s, x


def need_take():
    p = os.path.join(V, 'take.txt')
    if not os.path.exists(p): sys.exit('no take: tools/video.py play')
    if open(os.path.join(V, 'take.sha1')).read().strip() != sha1(SA1):
        sys.exit('the ROM has been rebuilt since the take was recorded: tools/video.py play')
    t = Take(p)
    if not t.steps: sys.exit('the take never reached the driving scene')
    return t


# ---- play
REC_TEST = r'''
-- (self-test: a scripted pad in place of a player, without a window)
emu.addEventCallback(function()
  if not VREC.loaded then return end
  local n = (VREC.n or 0) + 1
  local t = {}
  if n >= 200 and n <= 205 then t.start = true end
  if n >= 520 then
    t.y = true
    local q = (n // 97) %% 5
    if q == 1 then t.left = true elseif q == 3 then t.right = true end
    if n %% 173 < 9 then t.x = true end
  end
  emu.setInput(t, 0)
  if n >= %d then emu.stop(0) end
end, emu.eventType.inputPolled)
'''

REC_DEMO = r'''
-- (the attract demo: nobody at the pad, without a window)
emu.addEventCallback(function()
  if VREC.loaded and (VREC.n or 0) + 1 >= %d then emu.stop(0) end
end, emu.eventType.inputPolled)
'''
DEMO_VBLANKS = 5200             # (from the title screen: the demo starts after 1320 and takes about 3550)

def make_state():
    """The title screen, as a savestate of this build, and how many times the pad had been
    polled when it was taken (the original gets there from power-on)."""
    st = os.path.join(V, 'title.mss')
    lua = os.path.join(V, 'mkstate.lua')
    open(lua, 'w').write(r'''
local polls, want = 0, false
emu.addEventCallback(function() polls = polls + 1 end, emu.eventType.inputPolled)
function on_frame(n) if n == %d then want = true end end
emu.addMemoryCallback(function()
  if want then
    want = false
    local f = assert(io.open(%s, "wb")); f:write(emu.createSavestate()); f:close()
    print("polls " .. polls)
  end
end, emu.callbackType.exec, 0x000000, 0xFFFFFF, emu.cpuType.snes, emu.memType.snesMemory)
''' % (STATE_AT, '"%s"' % st))
    out = run(SA1, STATE_AT + 2, [lua], os.path.join(V, 'tmp'))
    m = re.search(r'polls (\d+)', out)
    if not m: sys.exit(out + '\nno savestate made')
    open(os.path.join(V, 'title.polls'), 'w').write(m.group(1) + '\n')
    return st


def cmd_play(a):
    os.makedirs(V, exist_ok=True)
    if not os.path.exists(SA1): sys.exit('no build: tools/build.py')
    st = make_state()
    take = os.path.join(V, 'take.txt')
    rec = os.path.join(V, 'rec.lua')
    body = open(sym_lua()).read() + '\nVREC = { state = "%s", out = "%s" }\n' % (st, take)
    if a.selftest: body += REC_TEST % a.selftest
    elif a.demo: body += REC_DEMO % DEMO_VBLANKS
    body += open(os.path.join(T, 'vstep.lua')).read() + '\n' + open(os.path.join(T, 'vrec.lua')).read()
    open(rec, 'w').write(body)
    open(os.path.join(V, 'take.sha1'), 'w').write(sha1(SA1) + '\n')
    if a.selftest or a.demo:
        subprocess.run(['mesen2', '--testRunner', SA1, rec], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    else:
        print('Mesen opens at the title screen.  Press Start, drive, close Mesen when done.')
        subprocess.run(['mesen2', SA1, rec])
    t = Take(take)
    if not t.steps:
        sys.exit('the take never reached the driving scene (%d vblanks recorded)' % t.last)
    print('take: %.0f s, of which %.0f s of driving (%d steps of the game).  Next: tools/video.py render'
          % (t.last / 60.1, (t.steps[-1][0] - t.steps[0][0]) / 60.1, len(t.steps)))


# ---- render
def capture(which, t, a, mode):
    patched = (which == 'sa1')
    rom = SA1 if patched else ORIG
    out = os.path.join(V, which); os.makedirs(out, exist_ok=True)
    for n in os.listdir(out):
        if re.fullmatch(r'v\d+\.png|audio\.wav.*|stats\.txt|steps\.txt', n): os.remove(os.path.join(out, n))
    base = 0 if patched else int(open(os.path.join(V, 'title.polls')).read())
    s_idle, a_idle = wait_loops(rom, patched)
    pads = dict(t.pads)
    if mode == 'sample':
        # by vblank up to the first sample, then what that sample found until this run
        # takes its own first
        first = t.samples[0][0]
        pads = {n: p for n, p in pads.items() if n < first}
        pads[first] = names(t.samples[0][1])
    last = t.last if a.to_end else t.steps[-1][0]
    frames = last + 30
    if not patched:
        # (its steps take 6 to 11 vblanks, not 8; the demo's come to the same on both)
        frames = base + (int(last * 1.6) + 600 if mode == 'sample' else last + 300)
    cfg = os.path.join(V, which + '_cfg.lua')
    open(cfg, 'w').write('VC = { mode = "%s", base = %d, from = %d,\n pads = {%s},\n samples = {%s},\n s_idle = %s,\n a_idle = %s }\n' % (
        mode, base, base + 1,
        ','.join('[%d]="%s"' % (n, p) for n, p in sorted(pads.items())),
        ','.join('"%s"' % names(v) for _, v in t.samples),
        lua_list(s_idle), lua_list(a_idle)))
    so = os.path.join(ROOT, 'build/wavrec.so')
    src = os.path.join(T, 'wavrec.c')
    if not os.path.exists(so) or os.path.getmtime(so) < os.path.getmtime(src):
        subprocess.run(['gcc', '-shared', '-fPIC', '-O1', '-o', so, src, '-ldl', '-lpthread'], check=True)
    env = {'MESEN_PRELOAD': so, 'MESEN_WAV': os.path.join(out, 'audio.wav'),
           'MESEN_CORE': os.path.expanduser('~/.config/Mesen2/MesenCore.so')}
    luas = ([sym_lua()] if patched else []) + [cfg, os.path.join(T, 'vstep.lua'), os.path.join(T, 'vcap.lua')]
    print('%s: %d vblanks, the pad by %s ...' % (which, frames, mode), flush=True)
    o = run(rom, frames, luas, out, load=os.path.join(V, 'title.mss') if patched else None, env=env)
    print('  ' + o.strip().splitlines()[-1])
    return read_steps(os.path.join(out, 'steps.txt'))


def cmd_render(a):
    t = need_take()
    ts, tx = [v for _, v in t.samples], [h for _, h in t.steps]
    def same(s, x):
        gs, gx = [int(v, 16) for _, v in s], [h for _, h in x]
        return gs[:len(ts)] == ts and gx[:len(tx)] == tx and len(gx) >= len(tx)
    # the patched ROM: the playthrough itself, vblank for vblank
    if same(*capture('sa1', t, a, 'vblank')):
        print('  the patched ROM replays the take exactly: %d steps' % len(tx))
    else:
        # (Mesen with a window and without did not run alike: go by the game's steps, as on
        # the original.  The in-between frames then always see the next step's buttons
        # coming, which a player's hands do not promise.)
        print('  that is not the take as it was played; replaying it step for step instead')
        if not same(*capture('sa1', t, a, 'sample')):
            sys.exit('the patched ROM does not replay the take')
        print('  the patched ROM plays the take\'s game: %d steps' % len(tx))
    # the original: the same game, step for step.  (Not the attract demo: there the game's
    # samples are its script's, which must not go on the pad, and nobody presses anything.)
    s, x = capture('orig', t, a, 'vblank' if t.idle() else 'sample')
    ox = [h for _, h in x]
    n = min(len(ox), len(tx))
    bad = next((i for i in range(n) if ox[i] != tx[i]), None)
    if bad is not None:
        sys.exit('the original plays a different game from step %d of %d on' % (bad + 1, len(tx)))
    if len(ox) < len(tx): sys.exit('the original only got to step %d of %d' % (len(ox), len(tx)))
    print('  the original plays the same game: %d steps, the same state after each' % n)
    cmd_compose(a)


def cmd_compose(a):
    sys.path.insert(0, T)
    import vcompose
    p = os.path.join(V, 'take.txt')
    if os.path.exists(p) and Take(p).idle():
        a.note = "The game's own demonstration, run on both in Mesen 2"
    vcompose.compose(V, a)


def figures(which):
    """Means over the driving scene of one capture (its first minute, as the video shows)."""
    rows = [l.split() for l in open(os.path.join(V, which, 'stats.txt'))]
    fl = [i for i, r in enumerate(rows) if int(r[4])]
    if not fl: sys.exit(which + ': the driving scene was never shown')
    fl = [i for i in fl if i <= fl[0] + 3606]
    part = rows[fl[0]:fl[-1] + 1]
    gaps = [b - a for a, b in zip(fl, fl[1:])]
    return {'fps': sum(int(r[4]) for r in part) * 60.0988 / len(part),
            's': 100 * sum(float(r[2]) for r in part) / len(part),
            'a': 100 * sum(max(float(r[3]), 0) for r in part) / len(part),
            'two': 100 * sum(1 for g in gaps if g <= 2) / max(len(gaps), 1)}


def cmd_serve(a):
    """A page with the video and its figures, for other machines on the LAN."""
    import shutil, time
    if not os.path.exists(a.video): sys.exit('no video: tools/video.py render')
    site = os.path.join(V, 'site'); os.makedirs(site, exist_ok=True)
    mp4 = os.path.join(site, 'outlander-sa1.mp4')
    shutil.copyfile(a.video, mp4)
    dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', mp4],
                               stdout=subprocess.PIPE, text=True, check=True).stdout)
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-ss', '%.2f' % (dur * 0.5), '-i', mp4,
                    '-frames:v', '1', '-q:v', '3', os.path.join(site, 'poster.jpg')], check=True)
    o, n = figures('orig'), figures('sa1')
    p = os.path.join(V, 'take.txt')
    demo = os.path.exists(p) and Take(p).idle()
    f = {'what': "The game's own demonstration on the original cartridge and with an SA-1 chip added" if demo
                 else 'One playthrough on the original cartridge and with an SA-1 chip added',
         'shows': ("Both sides run the demonstration the game plays when left at its title screen, so nobody is "
                   "at the pad and both get the same game: after every step the two were checked to hold the same state."
                   if demo else
                   "One playthrough was recorded on the patched game and replayed on both, the original getting the "
                   "buttons each step of the game found: after every step the two were checked to hold the same state.")
                  + " On the left is the game as released, on the right the same game with an SA-1 added to the cartridge.",
         'length': '%d seconds' % round(dur), 'size': '%.0f MB' % (os.path.getsize(mp4) / 1e6),
         'fps_o': '%.0f' % o['fps'], 'fps_a': '%.0f' % n['fps'], 'at30': '%.0f%%' % n['two'],
         's_o': '%.0f' % o['s'], 's_a': '%.0f' % n['s'], 'a_a': '%.0f' % n['a'],
         'made': 'Page made %s.' % time.strftime('%-d %B %Y')}
    page = open(os.path.join(T, 'video_page.html')).read()
    for k, v in f.items(): page = page.replace('{{%s}}' % k, v)
    if '{{' in page: sys.exit('video_page.html has a field this does not fill in')
    open(os.path.join(site, 'index.html'), 'w').write(page)
    print(site + '/index.html')
    if a.no_server: return
    sys.path.insert(0, T)
    import vserve
    vserve.serve(site, a.port)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('play'); p.add_argument('--selftest', type=int, metavar='VBLANKS', help=argparse.SUPPRESS)
    p.add_argument('--demo', action='store_true', help="record the game's attract demo: no window, nobody plays")
    for name in ('render', 'compose'):
        p = sub.add_parser(name)
        p.add_argument('--start', type=float, default=-1.0, help='seconds from the first frame of the driving scene')
        p.add_argument('--seconds', type=float, default=60.0)
        p.add_argument('--audio', choices=['sa1', 'orig', 'both', 'none'], default='sa1')
        p.add_argument('--to-end', action='store_true', help='capture to the end of the take, not of its driving')
        p.add_argument('--out', default=os.path.join(V, 'outlander-sa1.mp4'))
        p.add_argument('--title', help='the heading (default: "Outlander (SNES) with the SA-1")')
        p.add_argument('--still', type=float, metavar='S', help='only one picture, S seconds in, as a PNG beside --out')
    p = sub.add_parser('serve')
    p.add_argument('--video', default=os.path.join(V, 'outlander-sa1.mp4'))
    p.add_argument('--port', type=int, default=8000)
    p.add_argument('--no-server', action='store_true', help='only write the page (build/video/site)')
    a = ap.parse_args()
    {'play': cmd_play, 'render': cmd_render, 'compose': cmd_compose, 'serve': cmd_serve}[a.cmd](a)


if __name__ == '__main__':
    main()
