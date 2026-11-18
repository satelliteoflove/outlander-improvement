#!/usr/bin/env python3
"""Enter a password from power-on, as an input script for tools/run.py (--input).

  tools/password.py 'KN*B*C78*G9*B9K'          # prints the script; '*' is the heart
  tools/password.py 'KN*B*C78*G9*B9K' --start 1000

Select at the title screen opens the password screen, a grid of 6 x 6 with the cursor on
B; any of A, B, Y enters the character under it, and END ends the entry.  The heart is
'.' and the smiley '$' in the ROM's text; here they are '*' (or '.') and '$'.  The menus
run on the S-CPU and no patched code, so the same script reaches the same vblank on both
ROMs.
"""
import argparse

GRID = ['BCDFGH', 'JKLMNP', 'QRSTVW', 'XYZ*$0', '123456', '789!<E']
POS = {c: (r, k) for r, row in enumerate(GRID) for k, c in enumerate(row)}
POS['.'] = POS['*']
PRESS, GAP = 4, 16         # vblanks a button is held, and between presses


def script(pw, start=1000):
    """(input script, first vblank after the last press)."""
    pw = pw.upper().replace('♥', '*')
    assert len(pw) == 15, 'a password has 15 characters: %r' % pw
    out, t, cur = [], start, (0, 0)

    def press(b):
        nonlocal t
        out.append('%d-%d:%s' % (t, t + PRESS - 1, b)); t += PRESS + GAP
    press('select'); t += 120          # the screen fades in
    for c in list(pw) + ['E']:
        r, k = POS[c]
        for _ in range(r - cur[0]): press('down')
        for _ in range(cur[0] - r): press('up')
        for _ in range(k - cur[1]): press('right')
        for _ in range(cur[1] - k): press('left')
        cur = (r, k)
        press('a')
    return ';'.join(out), t


if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('pw'); ap.add_argument('--start', type=int, default=1000)
    a = ap.parse_args()
    s, t = script(a.pw, a.start)
    print(s)
    print('# done at vblank %d' % t)
