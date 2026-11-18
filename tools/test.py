#!/usr/bin/env python3
"""Regression tests: the patched ROM against recordings of the original game.

  tools/test.py record [name...]   # once (and after changing a scenario): run the ORIGINAL through them
  tools/test.py [name...]          # check build/outlander-sa1.sfc; exit status 1 on any difference
  tools/test.py -v60 demo          # list up to 60 differences per file
  tools/test.py later              # the later levels, from passwords (play_l4 ... play_lend; about
                                   # 5 minutes each, so not in the default run)
  tools/test.py xcheck 3000 ["input script"] [-DXC_SAVE="path"] [--pad=play_drive]
                                   # differential test over the patched game's own play: every
                                   # pass through the block is run both ways and compared
                                   # (tools/xcheck.lua; -D lines set its options; --pad replays
                                   # a play scenario's buttons instead of an input script)

Two kinds of scenario:

block  The driving block ($00:8D12 to $00:8F14), which is what the SA-1 runs.  A recording
       holds, for a sample of game frames, all the RAM the block can see at its entry and at
       its exit, plus registers (tools/golden_rec.lua).  The check puts each entry state into
       the patched game, lets it run the block its own way (SA-1, rewritten routines and all)
       and compares every byte at the exit (tools/golden_chk.lua).  Not compared: the stack
       pages, low RAM the interrupt handlers write (their timing differs), NOT_COMPARED.

timing Things about the display and the hand-over that no RAM comparison would notice.
       How late the S-CPU's interrupt handlers start (tools/irqlat.lua): the driving scene
       splits the screen with timed IRQs, and anything that holds the S-CPU up garbles the
       picture.  Whether the S-CPU side ever uses RAM of which only the SA-1 has the current
       copy, or writes RAM that never reaches the SA-1, and whether everything comes back
       when the scene ends, shows the map or is left for the title screen (tools/stale.lua).
       Whether video memory is written after the vertical blank has ended, which emulators
       forgive and hardware does not (tools/vbudget.lua).  And that the SA-1 touches no
       memory it does not have (tools/sa1guard.lua).

play   The game as a whole: it must play the same, game frame for game frame, however long
       a frame takes, and show the same (tools/play.lua).  These run with pipelining and the
       in-between frames on (src/pipe.asm, src/sub.asm), which the block scenarios and
       xcheck switch off, and with the timing checks as well.  The three in-between frames
       the patch shows after every step of the game are not the original's and are left out
       of the comparison, but each must be in VRAM as drawn when it is shown, and may write
       nothing that is not put back (tools/sa1guard.lua).

foot   The on-foot scenes, which must not change at all.  The recording is all of work RAM
       at the first pass through the on-foot main loop and a hash of it at every later pass,
       under a fixed input script; the check starts the patched game from the same RAM and
       inputs and compares every pass (tools/foot.lua).
"""
import os, random, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import build as B

ROM = 'build/outlander-sa1.sfc'
START = '1000-1005:start;1310-:y'       # start a game and hold the accelerator
# name: (input script, vblanks to run, first vblank sampled, every n-th pass, most passes)
BLOCK = {
    'drive':  (START, 2700, 1300, 2, 200),
    'demo':   ('', 4200, 2100, 2, 250),
    'weave':  (START + ';1500-1560:left;1600-1700:right+x;1750-1800:left+x;1850-1900:x;'
               '2000-2060:right;2100-2200:left+x;2300-2330:right;2400-2500:x', 3000, 1300, 3, 150),
}
# name: (input script that gets to an on-foot scene, random seed for the inputs there, game frames)
FOOT = {
    'foot1': (START, 1, 1500),
    'foot2': (START, 2, 1500),
}
# Low RAM not compared, with the reason:
NOT_COMPARED = {
    0x00FF: 'flag "an interrupt used the PPU multiplier"; meaningless on the SA-1',
    0x01AC: 'sound hand-shake counter: depends on what the sound CPU is doing at that moment',
    0x01AD: 'same',
}


# work RAM left out of the on-foot comparison (in the recording's hashes too): the sound
# hand-shake counter, as above, and the top of the stack page, where what is left behind
# by an interrupt depends on the exact instruction it interrupted
FOOT_MASK = 'FOOT_MASK = {[0x01AC]=true, [0x01AD]=true}\nfor a = 0x03A0, 0x03FF do FOOT_MASK[a] = true end\n'
# Bytes that only tell where in the frame the on-foot main loop was when it was sampled (see
# tools/foot.lua): $04C7/8 count the frame's IRQs so far, $04B9-$04BC are scroll values the
# IRQ handlers derive, $0445/6 is a scratch index of the status display.  The original
# differs from its own recording in these when started at another moment (try
# FOOT[...] with the start moved by 137 vblanks on Outlander.sfc).
FOOT_MASK += 'FOOT_TIMING = {[0x04C7]=true, [0x04C8]=true, [0x04B9]=true, [0x04BA]=true, [0x04BB]=true, [0x04BC]=true, [0x0445]=true, [0x0446]=true}\n'


def foot_input(seed, frames):
    """A fixed pseudo-random pad script: mostly walking right, with jumps and attacks."""
    r = random.Random(seed); out = []; t = 10
    while t < frames + 200:
        n = r.randint(15, 90)
        d = r.choices(['right', 'left', 'up', 'down', None], [8, 2, 1, 2, 2])[0]
        if d: out.append((t, t + n, [d]))
        for _ in range(r.randint(0, 3)):
            a = t + r.randint(0, n); out.append((a, a + r.randint(1, 12), [r.choice('byxalr')]))
        t += n + r.randint(0, 20)
    return '{' + ','.join('{%d,%d,{%s}}' % (a, b, ','.join('"%s"' % x for x in l)) for a, b, l in out) + '}'


def prelude(extra):
    sym = subprocess.run([sys.executable, 'tools/symlua.py'], stdout=subprocess.PIPE, text=True, check=True).stdout
    f = tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False)
    f.write(sym + open('build/blk_low.lua').read() + extra); f.close(); return f.name


def run(rom, inp, frames, pre, *scripts):
    try:
        return subprocess.run([sys.executable, 'tools/run.py', rom, '--frames', str(frames), '--input', inp, '--lua', pre]
                              + [x for s in scripts for x in ('--lua', s)]
                              + ['--out', 'build/shots_test', '--timeout', '3000']).returncode
    finally:
        os.unlink(pre)


def record(names):
    os.makedirs('build/golden', exist_ok=True)
    for n in names:
        path = os.path.abspath('build/golden/%s.bin' % n)
        if n in BLOCK:
            inp, frames, start, every, most = BLOCK[n]
            run('Outlander.sfc', inp, frames, prelude('GOLD_PATH = "%s"\nGOLD_FROM = %d\nGOLD_EVERY = %d\nGOLD_MAX = %d\n'
                % (path, start, every, most)), 'tools/golden_rec.lua')
        else:
            inp, seed, frames = FOOT[n]
            run('Outlander.sfc', inp, 20000, prelude('FOOT_MODE = "record"\nFOOT_PATH = "%s"\nFOOT_FRAMES = %d\nFOOT_INPUT = %s\n%s'
                % (path, frames, foot_input(seed, frames), FOOT_MASK)), 'tools/foot.lua')


def need(names):
    for n in names:
        if not os.path.exists('build/golden/%s.bin' % n): sys.exit('build/golden/%s.bin missing: run tools/test.py record' % n)


def check_block(names, verbose):
    irq = B.parse_ranges(open('build/irq_lowram.txt').read().splitlines()[1])
    mask = sorted(irq | set(NOT_COMPARED))
    pre = prelude('GC_FILES = {%s}\nGC_MASK = {%s}\nGC_VERBOSE = %d\n' % (
        ','.join('"%s"' % os.path.abspath('build/golden/%s.bin' % n) for n in names),
        ','.join('[%d]=true' % a for a in mask), verbose))
    return run(ROM, START, 200000, pre, 'tools/golden_chk.lua', 'tools/sa1guard.lua')


def xcheck(inp, frames, extra='', every=1, pad=None):
    """Differential test over the patched game's own play (tools/xcheck.lua).  pad = name of
    a play scenario: its recorded buttons are replayed per game frame (tools/play.lua)."""
    irq = B.parse_ranges(open('build/irq_lowram.txt').read().splitlines()[1])
    mask = sorted(irq | set(NOT_COMPARED))
    scripts = ['tools/xcheck.lua', 'tools/sa1guard.lua']
    if pad:
        extra += 'PLAY_MODE = "pad"\nPLAY_PATH = "%s"\n' % os.path.abspath('build/golden/%s.txt' % pad)
        inp = PLAY[pad][0]; scripts[:0] = ['tools/play.lua'] + list(PLAY[pad][5] if len(PLAY[pad]) > 5 else [])
    pre = prelude('GC_MASK = {%s}\nXC_EVERY = %d\n%s' % (','.join('[%d]=true' % a for a in mask), every, extra))
    return run(ROM, inp, frames, pre, *scripts)


# The original's interrupt handlers never start more than 170 master clocks late (measured
# with tools/irqlat.lua over these same runs).
#   timing_map:  Start while driving shows the map and Start again goes back: everything the
#                SA-1 holds is handed back to the S-CPU and taken over again.  (The game itself
#                keeps NMIs off for a while when it leaves the map, so no limit on those.)
#   timing_quit: Start during the demonstration goes to the title screen; then a game is started.
TIMING = {'timing_drive': (START, 2600, 200), 'timing_demo': ('', 4000, 200),
          'timing_map': (START + ';1600-1605:start;1800-1805:start', 2300, 60000),
          'timing_quit': ('2600-2605:start;3300-3305:start;3610-:y', 4300, 200)}
LAT_LIMIT = 200


def check_timing(n):
    inp, frames, nmi = TIMING[n]
    return run(ROM, inp, frames, prelude('LAT_MAX_IRQ = %d\nLAT_MAX_NMI = %d\nSTALE_FAIL = true\n'
                                         'SA1_GUARD_FAIL = function(msg) print(msg); EXIT_CODE = 1 end\n'
                                         'VB_FAIL = true\nVB_MARGIN = 1.0\n'
                                         # leaving the map, the game turns NMIs back on late and its own
                                         # palette fade lands on line 0 (the original does the same)
                                         'VB_ALLOW = {[0x808B94]=true, [0x808B9C]=true, [0x808BAA]=true, [0x808BB2]=true}\n'
                                         % (LAT_LIMIT, nmi)),
               'tools/irqlat.lua', 'tools/stale.lua', 'tools/sa1guard.lua', 'tools/vbudget.lua')


def check_foot(n):
    inp, seed, frames = FOOT[n]
    pre = prelude('FOOT_MODE = "check"\nFOOT_PATH = "%s"\nFOOT_INPUT = %s\n%s' % (
        os.path.abspath('build/golden/%s.bin' % n), foot_input(seed, frames), FOOT_MASK))
    return run(ROM, inp, 20000, pre, 'tools/foot.lua')


# name: (input script, vblanks to record on the original, vblanks the build gets,
#        autopilot settings or None, most game frames[, extra Lua files])
PLAY = {
    'play_demo':  ('', 6400, 6600, None, 600),
    'play_drive': ('1000-1005:start', 9000, 9000, '{fire = 37, fire_len = 4}', 900),
}
# Later levels, from the game's own passwords (published ones; tools/password.py types
# them in at the title screen).  A password puts the player down on foot by the road; he
# walks right, kept alive by tools/foothold.lua, until the stage ends and the drive begins
# (at the vblank given; the same on both ROMs).  Only holding right on foot: the on-foot
# scenes drop frames in different places on the two ROMs (foot_nmi_on moves where in the
# frame their loop runs), so a press timed by vblank could land on different passes.
# name: (password, vblank the drive starts)
PASSWORDS = {
    'play_l4':   ('KN*B*C78*G9*B9K', 4976),
    'play_l8':   ('BK*B*GDC*H8CBDM', 5736),
    'play_l12':  ('S7*C*JN*HPMFBG2', 5925),
    'play_l16':  ('B8*C*NMD**QFBC5', 5935),
    'play_l20':  ('R**DBCCD*M6FBG5', 6025),
    'play_lend': ('2M*F*JCLK66CBKP', 6220),       # "five towns from the final boss"
}


# The on-foot scenes' random generator ($90:F673, eight bytes at $046F).  The on-foot
# loop counts the vblanks each pass waited, so where frames drop changes the play, and
# the two ROMs drop them in different places (above): at level 16 the stage before the
# drive ends with other values here.  Nothing in the driving scene uses them.
FOOT_RNG = set(range(0x046F, 0x0477))


def _password_scenarios():
    import password
    for n, (pw, drive) in PASSWORDS.items():
        s, done = password.script(pw)
        PLAY[n] = ('%s;%d-%d:right' % (s, done + 300, drive + 9000), drive + 7600, drive + 8400,
                   '{fire = 37, fire_len = 4}', 900, ['tools/foothold.lua'])


_password_scenarios()


def play(n, mode):
    inp, t_orig, t_new, auto, most = PLAY[n][:5]
    more = list(PLAY[n][5]) if len(PLAY[n]) > 5 else []
    irq = B.parse_ranges(open('build/irq_lowram.txt').read().splitlines()[1])
    mask = sorted(irq | set(NOT_COMPARED) | (FOOT_RNG if n in PASSWORDS else set()))
    extra = 'PLAY_MODE = "%s"\nPLAY_PATH = "%s"\nPLAY_MASK = {%s}\nPLAY_MAX = %d\n' % (
        mode, os.path.abspath('build/golden/%s.txt' % n), ','.join('[%d]=true' % a for a in mask), most)
    extra += ''.join(a[2:] + '\n' for a in sys.argv[1:] if a.startswith('-D'))      # -DNAME=value: Lua options
    if mode == 'record':
        if auto: extra += 'PLAY_AUTO = %s\n' % auto
        f = tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False); f.write(extra); f.close()
        return run('Outlander.sfc', inp, t_orig, f.name, 'tools/play.lua', *more)
    # (and the timing checks, as in check_timing: these runs are the longest stretches of play)
    # No limit on the NMI: the screens that follow the drive turn NMIs on in mid-vblank, on
    # the original as well (14,732 clocks late after play_drive's last frame).
    extra += ('LAT_MAX_IRQ = %d\nLAT_MAX_NMI = %d\nSTALE_FAIL = true\nVB_FAIL = true\nVB_MARGIN = 1.0\n'
              'SA1_GUARD_FAIL = function(msg) print(msg); EXIT_CODE = 1 end\n' % (LAT_LIMIT, 60000))
    # an on-foot stage's set-up writes video memory on lines 1 to 5 (seen before the level 16
    # drive, at the same vblank on the original)
    # and a drive that begins after another (in the bank-$80 mirror) fades its palette in as
    # leaving the map does (timing_map): 0.8 lines from the end of vblank on the original
    extra += ('VB_ALLOW = {[0x90ACC0]=true, [0x90C739]=true, [0x90C757]=true, [0x808B94]=true, [0x808B9C]=true,'
              ' [0x808BAA]=true, [0x808BB2]=true, [0x008B94]=true, [0x008B9C]=true, [0x008BAA]=true, [0x008BB2]=true}\n')
    return run(ROM, inp, t_new, prelude(extra), 'tools/play.lua', *more, 'tools/irqlat.lua', 'tools/stale.lua',
               'tools/sa1guard.lua', 'tools/vbudget.lua')


def main():
    os.chdir(ROOT)
    args = [a for a in sys.argv[1:] if not a.startswith('-')]
    if args[:1] != ['record'] and os.path.exists(ROM):
        with open(ROM, 'rb') as f:
            f.seek(0x3FFFE0)
            if f.read(6) == b'TWEAKS':
                sys.exit('%s has the gameplay changes (src/tweaks.asm) and cannot be held to the original:\n'
                         'build with  python3 tools/build.py TWEAKS=0  for the tests' % ROM)
    verbose = 12
    for a in sys.argv[1:]:
        if a.startswith('-v'): verbose = int(a[2:] or 60)
    if args and args[0] == 'record':
        names = args[1:] or list(BLOCK) + list(FOOT) + [n for n in PLAY if n not in PASSWORDS]
        if names == ['later']: names = list(PASSWORDS)
        record([n for n in names if n not in PLAY])
        for n in names:
            if n in PLAY: play(n, 'record')
        return
    if args and args[0] == 'xcheck':      # xcheck FRAMES [INPUT]   (default input: start and accelerate)
        pad = [a[6:] for a in sys.argv[1:] if a.startswith('--pad=')]
        sys.exit(xcheck(args[2] if len(args) > 2 else START, int(args[1]) if len(args) > 1 else 3000,
                        ''.join(a[2:] + '\n' for a in sys.argv[1:] if a.startswith('-D')), pad=pad[0] if pad else None))
    names = args or list(BLOCK) + list(FOOT) + list(TIMING) + [n for n in PLAY if n not in PASSWORDS]
    if names == ['later']: names = list(PASSWORDS)      # the later levels: not in the default run
    for n in names:
        if n not in BLOCK and n not in FOOT and n not in TIMING and n not in PLAY: sys.exit('unknown scenario %s' % n)
    need([n for n in names if n in BLOCK or n in FOOT])
    for n in names:
        if n in PLAY and not os.path.exists('build/golden/%s.txt' % n): sys.exit('build/golden/%s.txt missing: run tools/test.py record %s' % (n, n))
    bad = 0
    blk = [n for n in names if n in BLOCK]
    if blk: bad |= check_block(blk, verbose)
    for n in names:
        if n in FOOT: bad |= check_foot(n)
        if n in TIMING: bad |= check_timing(n)
        if n in PLAY: bad |= play(n, 'check')
    print('FAILED' if bad else 'all tests passed')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
