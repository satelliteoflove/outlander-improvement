#!/usr/bin/env python3
"""Print a Lua table of the build's symbols: SYM = { name = 0xADDR, ... }.

Labels come from the Asar symbol file.  The shared variables of src/defs.asm (defines in
the BW-RAM window, $7000-$7FFF) are added as NAME_addr = offset into BW-RAM, for use with
emu.memType.snesSaveRam.
"""
import os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = []
for l in open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build/outlander-sa1.sym')):
    m = re.match(r'([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\w+)$', l.strip())
    if m: out.append('%s=0x%s%s' % (m.group(3), m.group(1), m.group(2)))
for l in open(os.path.join(ROOT, 'src/defs.asm')):
    m = re.match(r'!(\w+)\s*=\s*\$00([67][0-9A-Fa-f]{3})\b', l)
    if m: out.append('%s_addr=0x%04X' % (m.group(1), int(m.group(2), 16) - 0x6000))
print('SYM = {' + ', '.join(out) + '}')
