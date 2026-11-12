#!/usr/bin/env python3
"""Disassemble the code a coverage run actually executed (see tools/cov.lua).

  tools/dis.py Outlander.sfc build/cov.txt > build/drive.lst
  tools/dis.py Outlander.sfc build/cov.txt --top 40        # hottest routines by instruction count

Each line: address, executions, bytes, instruction.  M/X flags come from the trace, so
immediate sizes are right.  Gaps in coverage are shown as '...'.
"""
import argparse, sys

# mode -> (operand bytes, format); 'm'/'x' sizes depend on flags
MODES = {
 'imp': (0, ''), 'acc': (0, 'A'), 'imm8': (1, '#${:02X}'), 'immm': ('m', '#${:0{w}X}'),
 'immx': ('x', '#${:0{w}X}'), 'dp': (1, '${:02X}'), 'dpx': (1, '${:02X},X'), 'dpy': (1, '${:02X},Y'),
 'idp': (1, '(${:02X})'), 'idx': (1, '(${:02X},X)'), 'idy': (1, '(${:02X}),Y'),
 'ildp': (1, '[${:02X}]'), 'ildy': (1, '[${:02X}],Y'), 'sr': (1, '${:02X},S'), 'sry': (1, '(${:02X},S),Y'),
 'abs': (2, '${:04X}'), 'abx': (2, '${:04X},X'), 'aby': (2, '${:04X},Y'), 'iabs': (2, '(${:04X})'),
 'iax': (2, '(${:04X},X)'), 'ilabs': (2, '[${:04X}]'), 'long': (3, '${:06X}'), 'lngx': (3, '${:06X},X'),
 'rel': (1, None), 'rell': (2, None), 'blk': (2, None),
}
T = """
00 BRK imm8|01 ORA idx|02 COP imm8|03 ORA sr|04 TSB dp|05 ORA dp|06 ASL dp|07 ORA ildp|08 PHP imp|09 ORA immm|0A ASL acc|0B PHD imp|0C TSB abs|0D ORA abs|0E ASL abs|0F ORA long
10 BPL rel|11 ORA idy|12 ORA idp|13 ORA sry|14 TRB dp|15 ORA dpx|16 ASL dpx|17 ORA ildy|18 CLC imp|19 ORA aby|1A INC acc|1B TCS imp|1C TRB abs|1D ORA abx|1E ASL abx|1F ORA lngx
20 JSR abs|21 AND idx|22 JSL long|23 AND sr|24 BIT dp|25 AND dp|26 ROL dp|27 AND ildp|28 PLP imp|29 AND immm|2A ROL acc|2B PLD imp|2C BIT abs|2D AND abs|2E ROL abs|2F AND long
30 BMI rel|31 AND idy|32 AND idp|33 AND sry|34 BIT dpx|35 AND dpx|36 ROL dpx|37 AND ildy|38 SEC imp|39 AND aby|3A DEC acc|3B TSC imp|3C BIT abx|3D AND abx|3E ROL abx|3F AND lngx
40 RTI imp|41 EOR idx|42 WDM imm8|43 EOR sr|44 MVP blk|45 EOR dp|46 LSR dp|47 EOR ildp|48 PHA imp|49 EOR immm|4A LSR acc|4B PHK imp|4C JMP abs|4D EOR abs|4E LSR abs|4F EOR long
50 BVC rel|51 EOR idy|52 EOR idp|53 EOR sry|54 MVN blk|55 EOR dpx|56 LSR dpx|57 EOR ildy|58 CLI imp|59 EOR aby|5A PHY imp|5B TCD imp|5C JML long|5D EOR abx|5E LSR abx|5F EOR lngx
60 RTS imp|61 ADC idx|62 PER rell|63 ADC sr|64 STZ dp|65 ADC dp|66 ROR dp|67 ADC ildp|68 PLA imp|69 ADC immm|6A ROR acc|6B RTL imp|6C JMP iabs|6D ADC abs|6E ROR abs|6F ADC long
70 BVS rel|71 ADC idy|72 ADC idp|73 ADC sry|74 STZ dpx|75 ADC dpx|76 ROR dpx|77 ADC ildy|78 SEI imp|79 ADC aby|7A PLY imp|7B TDC imp|7C JMP iax|7D ADC abx|7E ROR abx|7F ADC lngx
80 BRA rel|81 STA idx|82 BRL rell|83 STA sr|84 STY dp|85 STA dp|86 STX dp|87 STA ildp|88 DEY imp|89 BIT immm|8A TXA imp|8B PHB imp|8C STY abs|8D STA abs|8E STX abs|8F STA long
90 BCC rel|91 STA idy|92 STA idp|93 STA sry|94 STY dpx|95 STA dpx|96 STX dpy|97 STA ildy|98 TYA imp|99 STA aby|9A TXS imp|9B TXY imp|9C STZ abs|9D STA abx|9E STZ abx|9F STA lngx
A0 LDY immx|A1 LDA idx|A2 LDX immx|A3 LDA sr|A4 LDY dp|A5 LDA dp|A6 LDX dp|A7 LDA ildp|A8 TAY imp|A9 LDA immm|AA TAX imp|AB PLB imp|AC LDY abs|AD LDA abs|AE LDX abs|AF LDA long
B0 BCS rel|B1 LDA idy|B2 LDA idp|B3 LDA sry|B4 LDY dpx|B5 LDA dpx|B6 LDX dpy|B7 LDA ildy|B8 CLV imp|B9 LDA aby|BA TSX imp|BB TYX imp|BC LDY abx|BD LDA abx|BE LDX aby|BF LDA lngx
C0 CPY immx|C1 CMP idx|C2 REP imm8|C3 CMP sr|C4 CPY dp|C5 CMP dp|C6 DEC dp|C7 CMP ildp|C8 INY imp|C9 CMP immm|CA DEX imp|CB WAI imp|CC CPY abs|CD CMP abs|CE DEC abs|CF CMP long
D0 BNE rel|D1 CMP idy|D2 CMP idp|D3 CMP sry|D4 PEI idp|D5 CMP dpx|D6 DEC dpx|D7 CMP ildy|D8 CLD imp|D9 CMP aby|DA PHX imp|DB STP imp|DC JML ilabs|DD CMP abx|DE DEC abx|DF CMP lngx
E0 CPX immx|E1 SBC idx|E2 SEP imm8|E3 SBC sr|E4 CPX dp|E5 SBC dp|E6 INC dp|E7 SBC ildp|E8 INX imp|E9 SBC immm|EA NOP imp|EB XBA imp|EC CPX abs|ED SBC abs|EE INC abs|EF SBC long
F0 BEQ rel|F1 SBC idy|F2 SBC idp|F3 SBC sry|F4 PEA abs|F5 SBC dpx|F6 INC dpx|F7 SBC ildy|F8 SED imp|F9 SBC aby|FA PLX imp|FB XCE imp|FC JSR iax|FD SBC abx|FE INC abx|FF SBC lngx
"""
OPS = {}
for ent in T.replace('\n', '|').split('|'):
    if ent.strip():
        h, mn, mode = ent.split(); OPS[int(h, 16)] = (mn, mode)


def rom_off(addr):
    """LoROM: any bank, $8000-$FFFF."""
    return ((addr >> 16) & 0x7F) * 0x8000 + (addr & 0x7FFF)


def decode(rom, addr, p):
    """-> (length, text, target or None)"""
    o = rom_off(addr); op = rom[o]; mn, mode = OPS[op]
    n, fmt = MODES[mode]
    if n == 'm': n = 1 if p & 0x20 else 2
    if n == 'x': n = 1 if p & 0x10 else 2
    b = rom[o + 1:o + 1 + n]; v = int.from_bytes(b, 'little')
    tgt = None
    if mode == 'rel':
        tgt = (addr & 0xFF0000) | ((addr + 2 + (v - 256 if v > 127 else v)) & 0xFFFF); s = '$%04X' % (tgt & 0xFFFF)
    elif mode == 'rell':
        tgt = (addr & 0xFF0000) | ((addr + 3 + (v - 65536 if v > 32767 else v)) & 0xFFFF); s = '$%04X' % (tgt & 0xFFFF)
    elif mode == 'blk':
        s = '$%02X,$%02X' % (b[1], b[0])
    else:
        s = fmt.format(v, w=n * 2)
        if mn in ('JSR', 'JMP') and mode == 'abs': tgt = (addr & 0xFF0000) | v
        if mn in ('JSL', 'JML') and mode == 'long': tgt = v
    return 1 + n, (mn + ' ' + s).strip(), tgt, rom[o:o + 1 + n]


def load_cov(path):
    cov = {}
    for line in open(path):
        f = line.split(); cov[int(f[0], 16)] = (int(f[1]), int(f[2], 16), int(f[3], 16) if len(f) > 3 else 0,
                              int(f[4], 16) if len(f) > 4 else None)
    return cov


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('rom'); ap.add_argument('cov')
    ap.add_argument('--top', type=int, default=0, help='list the hottest routines instead')
    ap.add_argument('--range', help='only addresses A-B (hex, e.g. 808000-8090FF)')
    a = ap.parse_args()
    rom = open(a.rom, 'rb').read(); cov = load_cov(a.cov)
    # subroutine entry points seen in the executed code
    entries = set()
    for ad, (c, p, _d, _b) in cov.items():
        if (ad & 0xFFFF) < 0x8000: continue
        ln, txt, tgt, _ = decode(rom, ad, p)
        if tgt is not None and txt[:3] in ('JSR', 'JSL'): entries.add(tgt)
    addrs = sorted(x for x in cov if (x & 0xFFFF) >= 0x8000)
    if a.top:
        # attribute each instruction to the nearest entry point at or below it
        es = sorted(entries); import bisect
        tot = {}; total = 0
        for ad in addrs:
            i = bisect.bisect_right(es, ad) - 1
            e = es[i] if i >= 0 and (es[i] >> 16) == (ad >> 16) else (ad & 0xFF0000)
            tot[e] = tot.get(e, 0) + cov[ad][0]; total += cov[ad][0]
        for e, c in sorted(tot.items(), key=lambda t: -t[1])[:a.top]:
            print('%06X %10d %5.1f%%' % (e, c, 100.0 * c / total))
        return
    lo, hi = 0, 0xFFFFFF
    if a.range: lo, hi = (int(x, 16) for x in a.range.split('-'))
    prev_end = None
    for ad in addrs:
        if not lo <= ad <= hi: continue
        c, p = cov[ad][:2]
        ln, txt, tgt, raw = decode(rom, ad, p)
        if prev_end is not None and ad != prev_end: print('        ...')
        if ad in entries: print('\nsub_%06X:' % ad)
        print('%06X %8d  %-12s %s' % (ad, c, raw.hex().upper(), txt))
        prev_end = ad + ln


if __name__ == '__main__':
    main()
