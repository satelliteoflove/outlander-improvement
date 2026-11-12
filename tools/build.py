#!/usr/bin/env python3
"""Build build/outlander-sa1.sfc from Outlander.sfc.

Layout of the 4 MB image (SA-1 "blocks" of 1 MB):
  block 0  the original game, patched only with hooks      S-CPU: banks $00-$1F, $80-$9F
  block 1  a second copy of the game, patched for the SA-1 SA-1:  banks $20-$3F
  block 2  unused
  block 3  new code (src/)                                 both:  banks $A0-$BF

Steps: verify the original, regenerate the SA-1 patches (tools/mkpatch.py), lay out the
image, run Asar on src/main.asm, fix the header checksum.
"""
import hashlib, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
SHA1 = '4dd01cd2f950b70bd08a6b16115cd647c7147c04'
OUT = os.path.join(ROOT, 'build', 'outlander-sa1.sfc')

# Code the SA-1 runs: name -> mkpatch arguments.
# "blk" is the body of the driving scene's main loop, from its first call ($00:8D12) to the
# jump back to the loop head ($00:8F14); $00:8E41 and $00:8D92 are its other ways out (JMLs
# to scene changes).  The jump tables are the ones its JSR (addr,X) instructions use.
BLK_ENTRY, BLK_EXITS = 0x008D12, (0x008F14, 0x008E41, 0x008D92)
ROUTINES = {
    'blk': ['--entry', '%06X' % BLK_ENTRY] + [x for e in BLK_EXITS for x in ('--end', '%06X' % e)] + [
            '--table', '809F5C:18', '--table', '809F80:18', '--table', '80B92B:26',
            '--table', '80C76A:5', '--table', '80BDB3:26', '--table', '80AED6:18',
            '--seeds', 'build/cov_blk.txt', '--stop', '81DB9E',
            # room for trampolines in the copy: its reset code, the rest of the sound routine
            # that is replaced at $81:DB9E, and the on-foot main loop
            '--tramp', '20:8004:B0', '--tramp', '21:DBA2:38', '--tramp', '30:824A:60',
            # immediates that are the bank byte of a pointer into $7E
            '--bankimm', '90BECA', '--bankimm', '90C16D',
            # looked at: constants that happen to be $7E/$7F
            '--ok', '81B4AD', '--ok', '81CF2E', '--ok', '80C486',
            # looked at: reached with 8- and 16-bit A, by instructions that are the same either way
            '--ok', '80B9FB', '--ok', '81B641',
            # the sound routine itself is replaced (src/sa1.asm, sa1_snd)
            '--ok', '81DBB8', '--ok', '81DBC0', '--ok', '81DBCA', '--ok', '81DBCD',
            # $90:BD66 is replaced (sa1_fill_7abd)
            '--ok', '90BD69', '--ok', '90BD6C', '--ok', '90BD71', '--ok', '90BD76', '--ok', '90BD7B',
            '--ok', '90BD81', '--ok', '90BD86', '--ok', '90BD8C', '--ok', '90BD91',
            # indexed accesses to low RAM, and what they can reach:
            #   the random number generator's 8 bytes of state
            '--indexed', '8098C1:013F-0146', '--indexed', '8098C3:013F-0146', '--indexed', '8098C5:013F-0146',
            '--indexed', '80BBA4:013F-0146', '--indexed', '80C0F3:013F-0146', '--indexed', '80C0FC:013F-0146',
            '--indexed', '80C1B8:013F-0146',
            #   a second generator, 4 bytes
            '--indexed', '81C986:0097-009A', '--indexed', '81C988:0097-009A', '--indexed', '81C98A:0097-009A',
            #   a countdown picked by $012D, which is only ever $50 or $53
            '--indexed', '809B8A:0150-0153', '--indexed', '809B8E:0150-0153', '--indexed', '809B96:0150-0153',
            #   three bytes at $015B and $015E, X = 0..2
            '--indexed', '809140:015E-0160', '--indexed', '809143:015B-015D', '--indexed', '809163:015B-015D',
            '--indexed', '809165:015B-015D', '--indexed', '8095F2:015B-015D', '--indexed', '8095F4:015B-015D'],
    # The status display's part of the NMI handler ($90:B337, shared with the on-foot
    # scenes) uploads buffers at $7E:78BD-$7B1C that the block fills in.  In the driving scene
    # the S-CPU runs it from the copy instead, with the bank bytes of its pointers changed to
    # BW-RAM's (src/offload.asm, nmi_hud); the original stays as it is for the other scenes.
    'hud': ['--entry', '90B337', '--scpu',
            '--bankimm', '90BD1A', '--bankimm', '90C1D5', '--bankimm', '90C217', '--bankimm', '90C22F'],
    # the main loop's head, up to the block (or to the pause code, or out of the demo), stays
    # on the S-CPU; walked only to learn what low RAM it uses (the patch file is not used)
    'head': ['--entry', '008C54', '--end', '008D12', '--end', '00805C', '--stop', '81BD2F'],
    # the interrupt handlers stay on the S-CPU; walked only to learn what low RAM they use
    'irq': ['--entry', '008111', '--entry', '0082CA', '--table', '00830C:9',
            '--indexed', '008A07:01A3-01A8', '--indexed', '008A0C:01A3-01A8',      # animation phases
            '--indexed', '008207:01B6-01BD', '--indexed', '00869D:01B6-01BD'],     # sprite data for the NMI
}
# low RAM the block appears to write but must not be copied back from the SA-1:
#   $00FF        "the IRQ handler used the multiplier" flag, meaningless on the SA-1
#   $01AC-$01AD  the sound routine's handshake counter (sound commands are queued and
#                replayed by the S-CPU, see sa1_snd)
LOW_OUT_EXCLUDE = {0x00FF, 0x01AC, 0x01AD}
# low RAM that holds the bank byte of a pointer into $7E (the --bankimm constants above are
# what gets stored there).  The SA-1's code wants $40 in them and the S-CPU's $7E, so they
# are translated on the way in and on the way out.
LOW_BANK_BYTES = (0x0439, 0x043D)
# The pointers to the two HDMA tables the road renderer built, which the NMI handler gives
# to the PPU when it shows the frame.  With PIPE=1 the S-CPU is not given the block's
# values but the addresses of copies of the tables (src/pipe.asm, sa1_split), so they are
# left out of the per-frame copy back.
LOW_SHOWN = {0x002F, 0x0030, 0x0032, 0x0033}
PIPE = 'PIPE=0' not in sys.argv


def parse_ranges(line):
    s = set()
    for t in line.split()[1:]:
        a, _, b = t.partition('-'); a = int(a, 16); b = int(b, 16) if b else a
        s |= set(range(a, b + 1))
    return s


def ranges(s):
    out = []
    for x in sorted(s):
        if out and x == out[-1][1] + 1: out[-1][1] = x
        else: out.append([x, x])
    return out


def low_tables():
    """The tables and code that carry low RAM between the CPUs (build/blk_low.asm), and the
    same facts for the test tools (build/blk_low.lua).

    The SA-1 keeps its own copy of the low RAM the block uses, for as long as the driving
    scene runs.  Everything is copied to it when the scene starts and back when it ends or
    pauses ("full").  In between, per frame, only what the two sides really share crosses:
    the S-CPU's side of the scene is the loop head and the interrupt handlers, and what
    those read and write is known from the same static analysis as the block's.
      to the SA-1 before the block:  what the block uses  and the S-CPU side writes
      back after it:                 what the block writes and the S-CPU side uses at all
    The rest of what the block writes is seen by nobody else until the scene ends.
    tools/stale.lua checks all of this against what the S-CPU actually does."""
    def load(n):
        L = open('build/%s_lowram.txt' % n).read().splitlines(); return parse_ranges(L[0]), parse_ranges(L[1])
    (rd, wr), (ird, iwr), (hrd, hwr) = load('blk'), load('irq'), load('head')
    assert max(rd | wr) < 0x0800, 'the block uses low RAM above $07FF'
    assert not any(0x0200 <= a < 0x0400 for a in rd | wr), 'the block uses the stack pages as data'
    # (src/defs.asm, !LOW_A and !LOW_B: what the in-between frames keep and put back of pages 4 to 7)
    assert all(0x0400 <= a < 0x04C0 or 0x07C0 <= a < 0x07D0 for a in wr if a >= 0x0400), \
        'the block writes low RAM outside !LOW_A / !LOW_B (src/defs.asm)'
    s_rd, s_wr = ird | hrd, iwr | hwr
    out = wr - LOW_OUT_EXCLUDE
    # Bytes both the block and the interrupt handlers write.  $2E is a hand-shake the
    # handler only clears when no block is running, so it is copied like the rest.  The
    # others are copied back only if the SA-1 changed them.
    clash = (out & iwr) - {0x002E}
    out -= clash
    # Full copy to the SA-1: all it reads, and all it might write (what is copied back must
    # be current even when the block did not write it).  Small gaps are copied too: a range
    # costs more to set up than a few bytes do to move.
    inp = rd | wr
    merged = []
    for a, b in ranges(inp):
        if merged and a - merged[-1][1] <= 6: merged[-1][1] = b
        else: merged.append([a, b])
    nar_in = (inp & s_wr) - clash           # (the clash bytes go with their snapshot)
    nar_out = out & (s_rd | s_wr)
    assert clash <= inp & s_wr
    # (to try out tools/stale.lua: LOW_DROP="0014 0036" in the environment leaves bytes out
    # of the per-frame copies, as if the analysis had missed that the S-CPU side uses them)
    drop = set(int(x, 16) for x in os.environ.get('LOW_DROP', '').split())
    nar_in -= drop; nar_out -= drop
    shown = LOW_SHOWN if PIPE else set()
    assert shown <= nar_out
    nar_out -= shown
    priv = out - nar_out                    # written by the block, seen by nobody else

    def split(rr):          # page 0 (I-RAM) and the rest (BW-RAM) are copied separately
        p0, hi = [], []
        for a, b in rr:
            if a < 0x100: p0.append([a, min(b, 0xFF)])
            if b >= 0x100: hi.append([max(a, 0x100), b])
        return p0, hi
    game = lambda a: '$%02X' % a if a < 0x100 else '$%04X' % a           # as the S-CPU has it (D = 0, DB = 0)
    copy = lambda a: '$%04X' % ((0x3000 if a < 0x100 else 0x6000) + a)   # the SA-1's, from bank 0

    def moves(f, addrs, to_sa1):    # words where two bytes are neighbours, then the odd bytes
        s = sorted(addrs); w, b, i = [], [], 0
        while i < len(s):
            if i + 1 < len(s) and s[i + 1] == s[i] + 1 and (s[i] < 0x100) == (s[i + 1] < 0x100): w.append(s[i]); i += 2
            else: b.append(s[i]); i += 1
        for a in w: f.write('        LDA %s : STA %s\n' % ((game(a), copy(a)) if to_sa1 else (copy(a), game(a))))
        f.write('        SEP #$20\n')
        for a in b: f.write('        LDA %s : STA %s\n' % ((game(a), copy(a)) if to_sa1 else (copy(a), game(a))))
    with open('build/blk_low.asm', 'w') as f:
        f.write('; generated by tools/build.py from the static analysis -- do not edit\n')
        f.write('; ---- full copies: tables of start, length-1\n')
        for name, rr in (('blk_low_in', merged), ('blk_low_out', ranges(out))):
            for suffix, part in zip(('0', ''), split(rr)):
                f.write('%s%s:            ; %d bytes in %d ranges\n' % (name, suffix, sum(b - a + 1 for a, b in part), len(part)))
                for a, b in part: f.write('        dw $%04X,%d\n' % (a, b - a))
                f.write('        dw $FFFF\n')
        f.write('blk_low_bank:\n')
        for a in LOW_BANK_BYTES:
            assert a >= 0x100 and a in inp and (a in out or a in clash), 'bank byte $%04X is not copied both ways' % a
            f.write('        dw $%04X\n' % a)
        f.write('        dw $FFFF\n')
        f.write('; ---- per frame.  A 16 bit on entry and return, direct page 0, data bank 0.\n')
        f.write('low_in:                 ; %d bytes, and %d the interrupt handlers also write\n' % (len(nar_in), len(clash)))
        moves(f, nar_in, True)
        for i, a in enumerate(sorted(clash)):       # the SA-1's copy and the snapshot get the same value
            f.write('        LDA %s : STA %s : STA.w !clash_snap+%d\n' % (game(a), copy(a), i))
            if a == 0x00C5: c5 = i
        f.write('        REP #$20\n        RTS\n')
        f.write('low_out:                ; %d bytes\n' % len(nar_out))
        moves(f, nar_out, False)
        for i, a in enumerate(sorted(clash)):       # only if the SA-1 changed it
            f.write('        LDA %s : CMP.w !clash_snap+%d : BEQ + : STA %s\n+\n' % (copy(a), i, game(a)))
        f.write('        REP #$20\n        RTS\n')
        f.write('assert %d <= !CLASH_MAX\n' % len(clash))
        f.write('!clash_c5 = !clash_snap+%d      ; the snapshot of $C5\n' % c5)
    lua = lambda s: '{' + ','.join('[%d]=true' % a for a in sorted(s)) + '}'
    with open('build/blk_low.lua', 'w') as f:
        f.write('-- generated by tools/build.py -- do not edit\n')
        f.write('LOW_PRIV = %s      -- written by the block and not copied back per frame\n' % lua(priv))
        f.write('LOW_IN = %s        -- copied to the SA-1 per frame\n' % lua(nar_in | clash))
        f.write('LOW_BLK = %s       -- all the block reads or writes\n' % lua(inp))
        f.write('LOW_OUT = %s       -- what a full copy back brings (not the bytes the interrupt handlers also write)\n' % lua(out))
        f.write('LOW_BANK = %s\n' % lua(LOW_BANK_BYTES))
        f.write('LOW_SHOWN = %s     -- the S-CPU has its own values of these (pointers to the tables on show)\n' % lua(shown))


def dry_copy(img):
    """A second copy of $80:9132 (the gauges' needles) for the SA-1, at the same address in
    bank $A1, in which every store into $7E:2000-$7FFF goes to bank $C0 instead, which is
    ROM: it does all the routine does to low RAM and draws nothing (src/pipe.asm)."""
    lo, hi = 0x9132, 0x9652
    src = lambda a: 0x100000 + (a & 0x7FFF)             # bank $20: block 1
    dst = lambda a: 0x300000 + 0x8000 + (a & 0x7FFF)    # bank $A1: block 3
    assert all(b == 0xFF for b in img[dst(lo):dst(hi)])
    img[dst(lo):dst(hi)] = img[src(lo):src(hi)]
    # the bank byte of: STA $402F36, LDA #$40 / PHA / PLB (for STA $2D36,Y and STA ($35),Y),
    # and the eight STA $40xxxx,X at the end
    sites = [0x91B3, 0x91CB] + [0x9605 + 10 * i for i in range(8)]
    for a in sites:
        assert img[dst(a)] == 0x40, 'dry copy: $%04X is not a bank byte' % a
        img[dst(a)] = 0xC0
    # and nothing else in it writes outside low RAM: every $40 that is left is looked at here
    left = [a for a in range(lo, hi) if img[dst(a)] == 0x40 and not 0x92A0 <= a < 0x95E8]
    # ($9182: the operand of LDA $9440,X;  $91A9: LDA $402F36)
    assert left == [0x9182, 0x91A9], ['%04X' % a for a in left]


def main():
    os.chdir(ROOT); os.makedirs('build', exist_ok=True)
    rom = open('Outlander.sfc', 'rb').read()
    if hashlib.sha1(rom).hexdigest() != SHA1: sys.exit('Outlander.sfc is not the expected ROM')
    if not os.path.exists('build/cov.txt') or not os.path.exists('build/cov_blk.txt'):
        sys.exit('build/cov.txt missing: see CLAUDE.md ("Coverage trace") for how to record it')
    for name, args in ROUTINES.items():
        subprocess.run([sys.executable, 'tools/mkpatch.py', 'Outlander.sfc', 'build/cov.txt', '--name', name,
                        '-o', 'build/%s_patch.asm' % name] + args, check=True,
                       stdout=None if '-v' in sys.argv else subprocess.DEVNULL)
    low_tables()
    # the S-CPU's routines in the copy and the SA-1's must not share a single instruction
    code = lambda n: set(open('build/%s_code.txt' % n).read().split())
    # ($90:BD66-$90:BD96 is replaced by sa1_fill_7abd, which suits both)
    both = set(a for a in code('blk') & code('hud') if not 0x90BD66 <= int(a, 16) <= 0x90BD96)
    if both: sys.exit('the block and the status display code overlap in the copy: ' + ' '.join(sorted(both)[:8]))
    img = bytearray(rom) + bytearray(rom) + bytearray(b'\xFF' * (2 << 20))
    open(OUT, 'wb').write(img)
    defs = ['-D' + a for a in sys.argv[1:] if a != '-v']
    r = subprocess.run(['asar', '--fix-checksum=off', '--symbols=wla', '--symbols-path=build/outlander-sa1.sym'] + defs + ['src/main.asm', OUT])
    if r.returncode:
        os.remove(OUT); sys.exit('asar failed')
    img = bytearray(open(OUT, 'rb').read())
    assert len(img) == 4 << 20, len(img)
    if PIPE:
        try: dry_copy(img)
        except AssertionError:
            os.remove(OUT); raise
    img[0x7FDC:0x7FE0] = b'\xFF\xFF\x00\x00'
    s = sum(img) & 0xFFFF
    img[0x7FDC:0x7FE0] = bytes([(s ^ 0xFFFF) & 255, (s ^ 0xFFFF) >> 8, s & 255, s >> 8])
    open(OUT, 'wb').write(img)
    print('%s: %d bytes, checksum $%04X' % (os.path.relpath(OUT), len(img), s))
    # symbols for the Lua tools (run.py --lua build/sym.lua --lua tools/timeline.lua ...)
    with open('build/sym.lua', 'w') as f:
        f.write(subprocess.run([sys.executable, 'tools/symlua.py'], stdout=subprocess.PIPE, text=True, check=True).stdout)


if __name__ == '__main__':
    main()
