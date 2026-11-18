#!/usr/bin/env python3
"""Make a BPS patch, and check one by applying it.

  tools/mkbps.py create ORIGINAL PATCHED OUT.bps
  tools/mkbps.py apply  ORIGINAL IN.bps OUT      # applies it, checking all three checksums

BPS can copy from the original ROM, which matters here: the patched ROM holds a second, nearly
identical copy of the game, and a patch that spelled that out (as IPS must) would be the game.
The format is bps_spec.md in Floating IPS's source.
"""
import sys, zlib
import numpy as np


def num(v):
    out = bytearray()
    while True:
        x = v & 0x7F
        v >>= 7
        if v == 0:
            out.append(0x80 | x)
            return bytes(out)
        out.append(x)
        v -= 1


def signed(v):
    return num((abs(v) << 1) | (v < 0))


def same(a, i, b, j):
    """how many bytes match, from a[i] and b[j]"""
    n = min(len(a) - i, len(b) - j)
    done, step = 0, 32
    while done < n:
        k = min(step, n - done)
        d = a[i + done:i + done + k] != b[j + done:j + done + k]
        if d.any():
            return done + int(d.argmax())
        done += k
        step *= 2
    return n


def create(src, dst):
    s, t = np.frombuffer(src, np.uint8), np.frombuffer(dst, np.uint8)
    K = 6
    index = {}
    for i in range(0, len(src) - K):
        p = index.setdefault(src[i:i + K], [])
        if len(p) < 4:
            p.append(i)
    out = bytearray(b'BPS1' + num(len(src)) + num(len(dst)) + num(0))
    lit_from = None
    pos, src_rel, tgt_rel, delta = 0, 0, 0, 0

    def flush(end):
        nonlocal lit_from
        if lit_from is not None:
            out.extend(num(((end - lit_from - 1) << 2) | 1))
            out.extend(dst[lit_from:end])
            lit_from = None

    while pos < len(dst):
        best, kind, at = 0, None, 0
        if pos < len(src):
            n = same(t, pos, s, pos)
            if n >= 4: best, kind = n, 'read'
        for c in {pos - delta, src_rel}:
            if 0 <= c < len(src):
                n = same(t, pos, s, c)
                if n > best and n >= 4: best, kind, at = n, 'copy', c
        if best < 32:
            for c in index.get(dst[pos:pos + K], ()):
                n = same(t, pos, s, c)
                if n > best: best, kind, at = n, 'copy', c
        if pos:
            n = same(t, pos, t, pos - 1)                # (a run of one byte: fill)
            if n >= 8 and n > best: best, kind, at = n, 'fill', pos - 1
        if kind is None:
            if lit_from is None: lit_from = pos
            pos += 1
            continue
        flush(pos)
        out.extend(num(((best - 1) << 2) | {'read': 0, 'copy': 2, 'fill': 3}[kind]))
        if kind == 'copy':
            out.extend(signed(at - src_rel)); src_rel = at + best; delta = pos - at
        elif kind == 'fill':
            out.extend(signed(at - tgt_rel)); tgt_rel = at + best
        pos += best
    flush(pos)
    for d in (src, dst):
        out.extend(zlib.crc32(d).to_bytes(4, 'little'))
    out.extend(zlib.crc32(bytes(out)).to_bytes(4, 'little'))
    return bytes(out)


def apply(src, p):
    assert p[:4] == b'BPS1', 'not a BPS patch'
    assert zlib.crc32(p[:-4]) == int.from_bytes(p[-4:], 'little'), 'the patch is damaged'
    assert zlib.crc32(src) == int.from_bytes(p[-12:-8], 'little'), 'this is not the right ROM'
    i = 4

    def rd():
        nonlocal i
        v, sh = 0, 1
        while True:
            b = p[i]; i += 1
            v += (b & 0x7F) * sh
            if b & 0x80: return v
            sh <<= 7
            v += sh

    def rs():
        v = rd()
        return -(v >> 1) if v & 1 else v >> 1

    assert rd() == len(src)
    size = rd()
    meta = rd(); i += meta
    out = bytearray(size)
    o = sr = tr = 0
    while i < len(p) - 12:
        v = rd(); mode, n = v & 3, (v >> 2) + 1
        if mode == 0: out[o:o + n] = src[o:o + n]
        elif mode == 1: out[o:o + n] = p[i:i + n]; i += n
        elif mode == 2:
            sr += rs(); out[o:o + n] = src[sr:sr + n]; sr += n
        else:
            tr += rs()
            for k in range(n): out[o + k] = out[tr + k]
            tr += n
        o += n
    assert o == size, 'wrong length'
    assert zlib.crc32(out) == int.from_bytes(p[-8:-4], 'little'), 'the result is wrong'
    return bytes(out)


if __name__ == '__main__':
    what, a, b, c = sys.argv[1:5]
    if what == 'create':
        p = create(open(a, 'rb').read(), open(b, 'rb').read())
        open(c, 'wb').write(p); print('%s: %d bytes' % (c, len(p)))
    else:
        open(c, 'wb').write(apply(open(a, 'rb').read(), open(b, 'rb').read())); print('%s: all three checksums match' % c)
