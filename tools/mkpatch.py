#!/usr/bin/env python3
"""Generate the patches that let the SA-1 run a copy of chosen routines.

The build puts an unmodified copy of the whole ROM in SA-1 block 1 (banks $20-$3F).
This tool walks the code reachable from the given entry points (statically, with M/X
flag tracking, seeded by the flags the trace saw) and emits Asar patches for the copy:

  * JSL/JML into the game's banks       -> the same address in the copy ($20-$3F)
  * LDA #$7E / PHA / PLB                -> #$40  (WRAM bank -> BW-RAM)
  * long operands in bank $7E/$7F       -> $40/$41
  * MVN/MVP with bank $7E/$7F           -> $40/$41
  * low RAM.  The SA-1's copy of it is in two places.  Page 0 ($0000-$00FF), which nearly
    all direct-page code uses, is in I-RAM at the same address: I-RAM is the SA-1's fast
    memory (BW-RAM costs a cycle more per access) and it shows at $0000 in every system
    bank.  Pages 1-7 are in BW-RAM at $40:0100-$07FF, so that code running with the data
    bank at $7E (now $40) finds them with absolute addressing as it does on the S-CPU.
    Everything else is moved to match:
      - direct page set-up other than 0 (PEA $0100 / PLD and the like) -> $6000 + value:
        the BW-RAM window at $6000-$7FFF shows $40:0000-$1FFF
      - absolute operands $0100-$1FFF where the data bank is a ROM bank -> + $6000
      - JMP ($01xx) and up through a low-RAM pointer -> + $6000
      - long operands $00:0100-$1FFF -> bank $40;  $7E:0000-$00FF -> bank $00
      - absolute operands in page 0 where the data bank is $7E -> a trampoline that does
        the same with a long address in bank $00 (only instructions that have a long form)
  * the PPU multiplier: reads of $2134-$2136 -> the SA-1's product register $2306-$2308;
    writes of $211B/$211C -> JSL to helpers (JSR to a trampoline for 3-byte forms)
  * the S-CPU's divider: writes of $4204/$4205 and reads of $4214-$4217 -> variables
    (!div_a, !div_q, !div_r in src/defs.asm); the write of $4206 that starts a division ->
    JSR to a trampoline to a helper that does it on the SA-1's arithmetic unit
  * a constant $7E/$7F that is stored as the bank byte of a long pointer -> $40/$41, for the
    addresses given with --bankimm (they cannot be told from ordinary constants, so every
    immediate $7E/$7F is reported until it is listed there or under --ok)

Trampolines are 5 bytes each (JSL helper / RTS) and have to sit in the same bank as the
instruction; --tramp BANK:ADDR:SIZE names a stretch of the copy that the SA-1 never uses.

and a report of everything it could not handle (register access, indirect jumps) plus the
set of low-RAM addresses the code reads and writes with direct/absolute addressing.

  tools/mkpatch.py Outlander.sfc build/cov.txt --entry 81CC3B --name r1 -o build/r1_patch.asm
"""
import argparse, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dis import OPS, MODES, rom_off, load_cov

WRITE_OPS = {'STA', 'STX', 'STY', 'STZ', 'INC', 'DEC', 'ASL', 'LSR', 'ROL', 'ROR', 'TSB', 'TRB'}
HELPERS = {  # (mnemonic, long address) -> helper label
    ('STA', 0x00211B): 'sa1_wr_m7a', ('STA', 0x00211C): 'sa1_wr_m7b',
}
# 3-byte "STA $211B" cannot hold a JSL: it becomes a JSR to a trampoline in the same bank of
# the copy (src/sa1.asm puts them over the copy's unused reset code, bank $20 only)
TRAMPOLINES = {0x211B: 'sa1_wr_m7a', 0x211C: 'sa1_wr_m7b'}       # 8-bit STA -> helper
DIV_VARS = {0x4204: '!div_a', 0x4205: '!div_a+1', 0x4214: '!div_q', 0x4215: '!div_q+1',
            0x4216: '!div_r', 0x4217: '!div_r+1'}
MPY = {0x2134: 0x2306, 0x2135: 0x2307, 0x2136: 0x2308}   # PPU product -> SA-1 product
LONG_FORM = {'ORA', 'AND', 'EOR', 'ADC', 'STA', 'LDA', 'CMP', 'SBC'}     # instructions with a long-address form
READ_OPS = {'LDA', 'ADC', 'SBC', 'CMP', 'AND', 'ORA', 'EOR', 'LDX', 'LDY', 'CPX', 'CPY', 'BIT'}


def copy_bank(b):
    return 0x20 | (b & 0x1F)


class Walker:
    def __init__(self, rom, cov, stop=()):
        self.rom, self.cov = rom, cov
        self.seen = {}          # addr -> (m, x)
        self.exits = {}         # sub entry -> set of (m, x) at return
        self.report = []
        self.patches = {}       # addr -> (text, comment)
        self.low_rd, self.low_wr = set(), set()
        self.dp_rd, self.dp_wr = set(), set()
        self.stop = set(stop)
        self.d = 0
        self.db = 0
        self.ends = set()
        self.dsetup = []
        self.indexed = set()
        self.stk = []           # abstract stack: ('db', bank) / ('a', constant or None) / ('k', bank) / ('x', None)
        self.aconst = None      # low byte of A when it is a known constant
        self.tables = {}
        self.ranges = {}        # addr of an indexed instruction -> (lo, hi) low RAM it can reach
        self.tramp_area = {}    # copy bank -> [next address, end]
        self.tramps = {}        # (copy bank, helper) -> label
        self.tramp_code = []
        self.scpu = False       # the copy is to be run by the S-CPU: see --scpu
        self.bankimm = set()    # addresses of immediates that are bank bytes
        self.ok = set()         # addresses whose reports have been looked at and are fine

    def tramp(self, pc, helper):
        """Label of a trampoline to helper in pc's bank of the copy, or None if there is no room."""
        b = copy_bank(pc >> 16); key = (b, helper)
        if key not in self.tramps:
            area = self.tramp_area.get(b)
            if not area or area[0] + 5 > area[1]: return None
            label = 'tramp_%s_%02X' % (helper, b)
            self.tramp_code.append('org $%02X%04X\n%s:\n        JSL %s\n        RTS' % (b, area[0], label, helper))
            area[0] += 5; self.tramps[key] = label
        return self.tramps[key]

    def tramp_code_for(self, pc, body, key):
        """Label of a trampoline in pc's bank of the copy that runs body (one instruction) and
        returns, or None if there is no room."""
        b = copy_bank(pc >> 16); k = (b, key)
        if k not in self.tramps:
            area = self.tramp_area.get(b)
            if not area or area[0] + 5 > area[1]: return None
            label = 'tramp_%s_%02X' % (key, b)
            self.tramp_code.append('org $%02X%04X\n%s:\n        %s\n        RTS' % (b, area[0], label, body))
            area[0] += 5; self.tramps[k] = label
        return self.tramps[k]

    def note(self, pc, text):
        if pc not in self.ok: self.report.append('%06X: %s' % (pc, text))

    def ins(self, addr, m, x):
        o = rom_off(addr); op = self.rom[o]; mn, mode = OPS[op]
        n, _ = MODES[mode]
        if n == 'm': n = 1 if m else 2
        if n == 'x': n = 1 if x else 2
        raw = self.rom[o:o + 1 + n]
        return mn, mode, n, int.from_bytes(raw[1:], 'little'), raw

    def walk_sub(self, entry, m, x, depth=0):
        """Walk a subroutine; return the set of (m, x) flag states at its returns."""
        key = (entry, m, x)
        if key in self.exits: return self.exits[key]
        self.exits[key] = set()   # recursion guard
        exits = set()
        work = [(entry, m, x, self.d, self.db, list(self.stk), self.aconst)]
        while work:
            pc, m, x, self.d, self.db, self.stk, self.aconst = work.pop()
            while True:
                if pc in self.ends: break
                if (pc & 0xFFFF) < 0x8000:
                    self.report.append('%06X: execution leaves ROM' % pc); break
                if pc in self.cov:      # trust the trace's flags and direct page
                    p = self.cov[pc][1]; m, x = bool(p & 0x20), bool(p & 0x10)
                    self.d = self.cov[pc][2]
                    if self.cov[pc][3] is not None: self.db = self.cov[pc][3]
                if pc in self.seen:
                    if self.seen[pc] != (m, x):
                        self.note(pc, 'reached with flags %s and %s' % (self.seen[pc], (m, x)))
                    break
                self.seen[pc] = (m, x)
                mn, mode, n, v, raw = self.ins(pc, m, x)
                nxt = (pc & 0xFF0000) | ((pc + 1 + n) & 0xFFFF)
                self.rules(pc, mn, mode, n, v, raw, m)
                self.track(pc, mn, mode, v)
                if mn == 'REP':
                    if v & 0x20: m = False
                    if v & 0x10: x = False
                elif mn == 'SEP':
                    if v & 0x20: m = True
                    if v & 0x10: x = True
                elif mn == 'PLP' and nxt not in self.cov:
                    self.report.append('%06X: PLP on an untraced path, flags assumed unchanged' % pc)
                if mn in ('RTS', 'RTL', 'RTI'):
                    exits.add((m, x, pc in self.cov)); break
                if mn in ('JMP', 'JML'):
                    if mode == 'abs': pc = (pc & 0xFF0000) | v; continue
                    if mode == 'long': pc = v; continue
                    self.report.append('%06X: indirect jump %s, not followed' % (pc, raw.hex())); break
                if mn in ('JSR', 'JSL'):
                    if mode in ('abs', 'long'):
                        tgt = v if mode == 'long' else (pc & 0xFF0000) | v
                        if tgt in self.stop:
                            pass
                        else:
                            keep = (self.d, self.db, list(self.stk))   # callees preserve these
                            ex = self.walk_sub(tgt, m, x, depth + 1)
                            self.d, self.db, self.stk = keep; self.aconst = None
                            if any(e[2] for e in ex):   # prefer the flags seen at traced returns
                                ex = set(e for e in ex if e[2])
                            ex = set(e[:2] for e in ex)
                            if nxt not in self.cov:
                                if len(ex) == 1: m, x = next(iter(ex))
                                elif len(ex) > 1:
                                    self.report.append('%06X: callee %06X returns with mixed flags' % (pc, tgt))
                    elif mode == 'iax' and ((pc & 0xFF0000) | v) in self.tables:
                        t = (pc & 0xFF0000) | v
                        keep = (self.d, self.db, list(self.stk))
                        for i in range(self.tables[t]):
                            o = rom_off(t + 2 * i)
                            self.d, self.db, self.stk = keep[0], keep[1], list(keep[2])
                            self.walk_sub((pc & 0xFF0000) | int.from_bytes(self.rom[o:o + 2], 'little'), m, x, depth + 1)
                        self.d, self.db, self.stk = keep; self.aconst = None
                    else:
                        self.report.append('%06X: indirect call %s, not followed' % (pc, raw.hex()))
                    pc = nxt; continue
                if mode in ('rel', 'rell'):
                    d = v - (1 << (8 * n)) if v >> (8 * n - 1) else v
                    tgt = (pc & 0xFF0000) | ((pc + 1 + n + d) & 0xFFFF)
                    if mn in ('BRA', 'BRL'): pc = tgt; continue
                    if mn != 'PER': work.append((tgt, m, x, self.d, self.db, list(self.stk), self.aconst))
                if mn in ('BRK', 'COP', 'STP', 'WAI'):
                    self.report.append('%06X: %s' % (pc, mn)); break
                pc = nxt
        self.exits[key] = exits
        return exits

    A_KEEP = {'SEP', 'REP', 'PHA', 'PHB', 'PHD', 'PHK', 'PHP', 'PHX', 'PHY', 'PLB', 'PLD', 'PLX', 'PLY', 'PEA', 'PEI',
              'PER', 'CLC', 'SEC', 'CLI', 'SEI', 'CLD', 'SED', 'CLV', 'NOP', 'TAX', 'TAY', 'TCD', 'TCS', 'TXY', 'TYX',
              'TXS', 'TSX', 'INX', 'INY', 'DEX', 'DEY', 'LDX', 'LDY', 'STA', 'STX', 'STY', 'STZ', 'CMP', 'CPX', 'CPY',
              'BIT', 'BCC', 'BCS', 'BEQ', 'BNE', 'BMI', 'BPL', 'BVC', 'BVS', 'BRA', 'BRL', 'JMP', 'JML', 'WDM'}

    def track(self, pc, mn, mode, v):
        """Follow what is pushed and pulled, to know the data bank after a PLB on code the
        trace never reached (on traced code the trace's own value is used)."""
        if mn == 'PHA': self.stk.append(('a', self.aconst))
        elif mn == 'PHB': self.stk.append(('db', self.db))
        elif mn == 'PHK': self.stk.append(('k', pc >> 16))
        elif mn in ('PHX', 'PHY', 'PHP', 'PHD', 'PEA', 'PEI', 'PER'): self.stk.append(('x', None))
        elif mn in ('PLA', 'PLX', 'PLY', 'PLP', 'PLD'):
            if self.stk: self.stk.pop()
        elif mn == 'PLB':
            kind, val = self.stk.pop() if self.stk else ('x', None)
            if pc not in self.cov:
                self.db = val if kind in ('db', 'a', 'k') else None
                if self.db is None: self.note(pc, 'PLB: cannot tell the data bank from here on  (untraced)')
        del self.stk[:-12]
        if mn == 'LDA' and mode == 'immm': self.aconst = v & 0xFF
        elif mn not in self.A_KEEP or (mn in ('BIT',) and False): self.aconst = None

    def rules(self, pc, mn, mode, n, v, raw, m):
        cp = (copy_bank(pc >> 16) << 16) | (pc & 0xFFFF)
        traced = pc in self.cov
        tag = '' if traced else '  (untraced)'
        if self.scpu:
            # code the S-CPU itself runs from the copy: it has work RAM and the registers, so
            # only calls (to stay in the copy) and the listed bank bytes change
            if mn in ('JSL', 'JML') and mode == 'long' and ((v >> 16) < 0x20 or 0x80 <= (v >> 16) < 0xA0):
                self.patches[cp] = ('%s $%06X' % (mn, (copy_bank(v >> 16) << 16) | (v & 0xFFFF)), '%s $%06X' % (mn, v))
            elif mn in ('LDA', 'LDX', 'LDY') and mode in ('immm', 'immx') and v in (0x7E, 0x7F):
                if pc in self.bankimm:
                    self.patches[cp + 1] = ('db $%02X' % (v - 0x3E), '%s #$%02X (bank byte of a pointer)' % (mn, v))
                else:
                    self.note(pc, '%s #$%0*X: a bank byte? (--bankimm or --ok)%s' % (mn, 2 * n, v, tag))
            elif mode in ('long', 'lngx') and (v >> 16) in (0x7E, 0x7F):
                self.note(pc, '%s $%06X: work RAM by long address%s' % (mn, v, tag))
            return
        if mn in ('JSL', 'JML') and mode == 'long':
            b = v >> 16
            if b < 0x20 or 0x80 <= b < 0xA0:
                self.patches[cp] = ('%s $%06X' % (mn, (copy_bank(b) << 16) | (v & 0xFFFF)), '%s $%06X' % (mn, v))
            else:
                self.report.append('%06X: %s to $%06X' % (pc, mn, v))
            return
        if mn in ('LDA', 'LDX', 'LDY') and mode in ('immm', 'immx') and v in (0x7E, 0x7F):
            o = rom_off(pc)
            if mn == 'LDA' and n == 1 and (self.rom[o + 2:o + 4] == b'\x48\xAB' or self.rom[o + 2:o + 5] == b'\x8B\x48\xAB'):
                self.patches[cp] = ('LDA #$%02X' % (v - 0x3E), 'LDA #$%02X / PHA / PLB' % v)
            elif pc in self.bankimm:
                self.patches[cp + 1] = ('db $%02X' % (v - 0x3E), '%s #$%02X (bank byte of a pointer)' % (mn, v))
            else:
                self.note(pc, '%s #$%0*X: a bank byte? (--bankimm or --ok)%s' % (mn, 2 * n, v, tag))
            return
        if mn == 'PEA' and ((v >> 8) in (0x7E, 0x7F) or (v & 0xFF) in (0x7E, 0x7F)):
            self.note(pc, 'PEA $%04X: a bank byte? (--ok)%s' % (v, tag))
        if mn in ('MVN', 'MVP'):
            d, s = raw[1], raw[2]
            nd = d - 0x3E if d in (0x7E, 0x7F) else d; ns = s - 0x3E if s in (0x7E, 0x7F) else s
            if (nd, ns) != (d, s):
                self.patches[cp] = ('db $%02X,$%02X,$%02X' % (raw[0], nd, ns), '%s dst=%02X src=%02X' % (mn, d, s))
            return
        if mode in ('long', 'lngx'):
            b = v >> 16
            if b == 0x7E and (v & 0xFFFF) < 0x100:      # page 0 is in I-RAM
                if mode == 'long': (self.low_wr if mn in WRITE_OPS else self.low_rd).add(v & 0xFFFF)
                else: self.note(pc, '%s $%06X,x long indexed page 0%s' % (mn, v, tag))
                self.patches[cp + 3] = ('db $00', '%s $%06X' % (mn, v)); return
            if b in (0x7E, 0x7F):
                if (v & 0xFFFF) < 0x2000:
                    if mode == 'long': (self.low_wr if mn in WRITE_OPS else self.low_rd).add(v & 0xFFFF)
                    else: self.note(pc, '%s $%06X,x long indexed low RAM%s' % (mn, v, tag))
                self.patches[cp + 3] = ('db $%02X' % (b - 0x3E), '%s $%06X' % (mn, v)); return
            if (b < 0x40 or 0x80 <= b < 0xC0) and (v & 0xFFFF) < 0x8000:
                lo = v & 0xFFFF
                if lo in MPY and mn in READ_OPS and mode == 'long':
                    self.patches[cp + 1] = ('dw $%04X' % MPY[lo], '%s $%06X' % (mn, v)); return
                h = HELPERS.get((mn, lo))
                if h and mode == 'long' and not m:
                    self.report.append('%06X: %s $%06X with 16-bit A' % (pc, mn, v)); return
                if h and mode == 'long':
                    self.patches[cp] = ('JSL ' + h, '%s $%06X' % (mn, v)); return
                if lo < 0x2000:
                    if mode == 'long': (self.low_wr if mn in WRITE_OPS else self.low_rd).add(lo)
                    else: self.note(pc, '%s $%06X,x long indexed low RAM%s' % (mn, v, tag))
                    if lo >= 0x100: self.patches[cp + 3] = ('db $40', '%s $%06X' % (mn, v))
                    return
                self.report.append('%06X: %s long $%06X%s' % (pc, mn, v, tag))
            return
        if mn in ('PLD', 'TCD'):
            # direct page set-up: recognise the constant being loaded and move it to $6000+
            o = rom_off(pc); r = self.rom
            cb = cp & 0xFF0000
            pat = None
            if mn == 'PLD' and r[o - 3] == 0xF4: pat = (o - 3, 'PEA')                       # PEA #
            elif mn == 'PLD' and r[o - 1] == 0xDA and r[o - 4] == 0xA2: pat = (o - 4, 'LDX')  # LDX # / PHX
            elif mn == 'PLD' and r[o - 1] == 0x5A and r[o - 4] == 0xA0: pat = (o - 4, 'LDY')  # LDY # / PHY
            elif mn == 'PLD' and r[o - 1] == 0x48 and r[o - 4] == 0xA9: pat = (o - 4, 'LDA')  # LDA # / PHA
            elif mn == 'TCD' and r[o - 3] == 0xA9: pat = (o - 3, 'LDA')                     # LDA # / TCD
            if pat:
                po, kind = pat
                val = int.from_bytes(r[po + 1:po + 3], 'little')
                paddr = (pc & 0xFF0000) | ((pc - (o - po)) & 0xFFFF)
                if val < 0x2000:
                    if val & 0xFF: self.note(pc, 'direct page set to $%04X, not a page boundary' % val)
                    if val >= 0x100:
                        self.patches[(copy_bank(pc >> 16) << 16) | ((paddr + 1) & 0xFFFF)] = (
                            'dw $%04X' % (val + 0x6000), '%s #$%04X ... %s (direct page)' % (kind, val, mn))
                    self.dsetup.append('%06X: %s #$%04X ... %s%s' % (paddr, kind, val, mn, tag))
                    if not traced: self.d = val
                else:
                    self.report.append('%06X: direct page set to $%04X' % (pc, val))
            elif not traced:
                self.report.append('%06X: %s on an untraced path, taken to restore a saved direct page' % (pc, mn))
            return
        if mn in ('TDC', 'PHD') and mn == 'TDC':
            self.report.append('%06X: TDC (direct page used as a value)%s' % (pc, tag)); return
        if mode in ('dp', 'dpx', 'dpy', 'idp', 'idx', 'idy', 'ildp', 'ildy') and mn != 'PEI':
            wide = 1 if (m and mn not in ('STX', 'STY', 'LDX', 'LDY', 'CPX', 'CPY')) else 2
            v += self.d
            if mode == 'dp':
                for i in range(wide):
                    if mn in WRITE_OPS: self.dp_wr.add(v + i)
                    if mn not in ('STA', 'STX', 'STY', 'STZ'): self.dp_rd.add(v + i)
            elif mode in ('dpx', 'dpy'):
                if pc in self.ranges:
                    lo, hi = self.ranges[pc]
                    if (lo < 0x100) != (self.d < 0x100) or (hi < 0x100) != (self.d < 0x100):
                        self.note(pc, '%s $%04X,x/y reaches $%04X-$%04X across the page 0 boundary' % (mn, v, lo, hi))
                    for a in range(lo, hi + 1):
                        if mn in WRITE_OPS: self.dp_wr.add(a)
                        if mn not in ('STA', 'STX', 'STY', 'STZ'): self.dp_rd.add(a)
                else:
                    self.report.append('%06X: %s $%04X,x/y indexed direct page%s' % (pc, mn, v, tag))
            else:
                for i in range(3 if mode in ('ildp', 'ildy') else 2): self.dp_rd.add(v + i)
            return
        if mode in ('iabs', 'ilabs') and v < 0x2000:
            if v >= 0x100:
                self.patches[cp + 1] = ('dw $%04X' % (v + 0x6000), '%s through a low-RAM pointer at $%04X' % (mn, v))
            self.low_rd.add(v); self.low_rd.add(v + 1)
            return
        if mode in ('abs', 'abx', 'aby') and mn not in ('JSR', 'JMP', 'PEA'):
            db = self.db
            rombank = db is not None and (db < 0x40 or 0x80 <= db < 0xC0)
            if db is None:
                if v < 0x8000: self.report.append('%06X: %s $%04X with an unknown data bank%s' % (pc, mn, v, tag))
                return
            if v < 0x2000:
                if mode == 'abs':
                    w = 1 if (m and mn not in ('STX', 'STY', 'LDX', 'LDY', 'CPX', 'CPY')) else 2
                    for i in range(w):
                        if mn in WRITE_OPS: self.low_wr.add(v + i)
                        if mn not in ('STA', 'STX', 'STY', 'STZ'): self.low_rd.add(v + i)
                elif pc in self.ranges:
                    lo, hi = self.ranges[pc]
                    for a in range(lo, hi + 1):
                        if mn in WRITE_OPS: self.low_wr.add(a)
                        if mn not in ('STA', 'STX', 'STY', 'STZ'): self.low_rd.add(a)
                    if (lo < 0x100) != (v < 0x100) or (hi < 0x100) != (v < 0x100):
                        self.note(pc, '%s $%04X,x/y reaches $%04X-$%04X across the page 0 boundary' % (mn, v, lo, hi))
                else:
                    self.indexed.add('%06X %s $%04X' % (pc, mn, v))
                if rombank:
                    if v >= 0x100:
                        self.patches[cp + 1] = ('dw $%04X' % (v + 0x6000), '%s $%04X (data bank $%02X)' % (mn, v, db))
                elif db != 0x7E:
                    self.report.append('%06X: %s $%04X with data bank $%02X%s' % (pc, mn, v, db, tag))
                elif v < 0x100:
                    # page 0 through the $7E data bank: it is not in bank $40
                    lab = None
                    if mn in LONG_FORM and mode in ('abs', 'abx'):
                        body = '%s.l $%06X%s' % (mn, v, ',x' if mode == 'abx' else '')
                        lab = self.tramp_code_for(pc, body, 'p0_%s_%04X%s' % (mn, v, 'x' if mode == 'abx' else ''))
                    if lab: self.patches[cp] = ('JSR ' + lab, '%s $%04X%s (page 0, data bank $7E)' % (mn, v, ',X' if mode == 'abx' else ''))
                    else: self.note(pc, '%s $%04X (%s) reaches page 0 through data bank $7E%s' % (mn, v, mode, tag))
            elif v < 0x8000 and rombank:      # hardware register
                if mode == 'abs' and v in MPY and mn in READ_OPS:
                    self.patches[cp + 1] = ('dw $%04X' % MPY[v], '%s $%04X' % (mn, v))
                elif mode == 'abs' and v in TRAMPOLINES and mn == 'STA' and m and self.tramp(pc, TRAMPOLINES[v]):
                    self.patches[cp] = ('JSR ' + self.tramp(pc, TRAMPOLINES[v]), 'STA $%04X' % v)
                elif mode == 'abs' and v in TRAMPOLINES and mn == 'STZ' and m and self.tramp(pc, TRAMPOLINES[v] + '_z'):
                    self.patches[cp] = ('JSR ' + self.tramp(pc, TRAMPOLINES[v] + '_z'), 'STZ $%04X' % v)
                elif mode == 'abs' and v in DIV_VARS and (mn in READ_OPS if v >= 0x4214 else mn in ('STA', 'STX', 'STY', 'STZ')):
                    self.patches[cp + 1] = ('dw %s' % DIV_VARS[v], '%s $%04X' % (mn, v))
                elif mode == 'abs' and v == 0x4206 and mn == 'STA' and m and self.tramp(pc, 'sa1_div_a'):
                    self.patches[cp] = ('JSR ' + self.tramp(pc, 'sa1_div_a'), 'STA $4206')
                elif mode == 'abs' and v == 0x4206 and mn == 'STX' and self.tramp(pc, 'sa1_div_x'):
                    self.patches[cp] = ('JSR ' + self.tramp(pc, 'sa1_div_x'), 'STX $4206')
                else:
                    self.note(pc, '%s $%04X is a hardware register%s' % (mn, v, tag))
            elif v < 0x8000 and db == 0x7F:
                self.report.append('%06X: %s $%04X in bank $7F%s' % (pc, mn, v, tag))
            return


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('rom'); ap.add_argument('cov')
    ap.add_argument('--entry', action='append', required=True); ap.add_argument('--name', default='r')
    ap.add_argument('--stop', action='append', default=[], help='subroutine not to descend into')
    ap.add_argument('--table', action='append', default=[], help='ADDR:N jump table for JSR (addr,X)')
    ap.add_argument('--end', action='append', default=[], help='address where the walk stops (block exit)')
    ap.add_argument('--indexed', action='append', default=[],
                    help='ADDR:LO-HI low RAM an indexed instruction at ADDR can reach (direct page,X or absolute,X)')
    ap.add_argument('--tramp', action='append', default=[], help='BANK:ADDR:SIZE room for trampolines in a bank of the copy')
    ap.add_argument('--bankimm', action='append', default=[], help='address of an immediate $7E/$7F that is a bank byte')
    ap.add_argument('--ok', action='append', default=[], help='address whose report has been looked at and is fine')
    ap.add_argument('--scpu', action='store_true',
                    help='the routine stays on the S-CPU but runs from the copy: only relocate calls and patch --bankimm')
    ap.add_argument('--seeds', help='coverage file recorded inside the routine (cov.lua with COV_WINDOW)')
    ap.add_argument('-o', required=True)
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read(); cov = load_cov(a.cov)
    w = Walker(rom, cov, stop=[int(s, 16) for s in a.stop])
    w.ends = set(int(e, 16) for e in a.end)
    for t in a.table:
        ad, n = t.split(':'); w.tables[int(ad, 16)] = int(n)
    for t in a.tramp:
        b, ad, n = (int(x, 16) for x in t.split(':')); w.tramp_area[b] = [ad, ad + n]
    w.bankimm = set(int(x, 16) for x in a.bankimm); w.ok = set(int(x, 16) for x in a.ok); w.scpu = a.scpu
    for t in a.indexed:
        ad, r = t.split(':'); lo, hi = r.split('-'); w.ranges[int(ad, 16)] = (int(lo, 16), int(hi, 16))
    for e in a.entry:
        e = int(e, 16); p = cov[e][1] if e in cov else 0x20
        w.walk_sub(e, bool(p & 0x20), bool(p & 0x10))
    if a.seeds:     # addresses a windowed trace saw executing inside the routine
        for ad in sorted(load_cov(a.seeds)):
            if (ad & 0xFFFF) >= 0x8000 and ad not in w.seen and ad in cov:
                p = cov[ad][1]; w.walk_sub(ad, bool(p & 0x20), bool(p & 0x10))
    with open(a.o, 'w') as f:
        f.write('; generated by tools/mkpatch.py for %s -- do not edit\n' % ', '.join(a.entry))
        for ad in sorted(w.patches):
            t, c = w.patches[ad]
            f.write('org $%06X : %-22s ; was %s\n' % (ad, t, c))
        for t in w.tramp_code: f.write(t + '\n')
    un = sorted(x for x in w.seen if x not in cov)
    print('%s: %d instructions reachable, %d never traced, %d patches' % (a.name, len(w.seen), len(un), len(w.patches)))
    for r in sorted(set(w.report)):
        if int(r[:6], 16) not in w.ok: print('  ! ' + r)
    for r in sorted(set(w.dsetup)): print('  direct page set-up: ' + r)
    if w.indexed: print('  ! indexed low RAM with no --indexed range: ' + ', '.join(sorted(w.indexed)))

    def rng(s):
        out = []
        for x in sorted(s):
            if out and x == out[-1][1] + 1: out[-1][1] = x
            else: out.append([x, x])
        return ' '.join('%04X-%04X' % (p, q) if p != q else '%04X' % p for p, q in out)
    print('  low RAM read :', rng(w.dp_rd | w.low_rd))
    print('  low RAM write:', rng(w.dp_wr | w.low_wr))
    with open(a.o.replace('_patch.asm', '_lowram.txt'), 'w') as f:
        f.write('read ' + rng(w.dp_rd | w.low_rd) + '\nwrite ' + rng(w.dp_wr | w.low_wr) + '\n')
    with open(a.o.replace('_patch.asm', '_code.txt'), 'w') as f:      # every byte of every instruction walked
        f.write(' '.join('%06X' % (ad + i) for ad in sorted(w.seen) for i in range(1 + w.ins(ad, *w.seen[ad])[2])) + '\n')


if __name__ == '__main__':
    main()
