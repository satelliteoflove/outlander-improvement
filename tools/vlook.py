#!/usr/bin/env python3
"""Look at the frames of the comparison video's captures (tools/video.py render leaves every
vblank's picture in build/video/orig and build/video/sa1, with stats.txt beside them).

  tools/vlook.py sheet sa1 3396 32            # 32 consecutive frames from capture vblank 3396,
                                              # every 2nd vblank, as one picture
  tools/vlook.py sheet sa1 3396 32 --mirror   # the same of the rear-view mirror, enlarged
  tools/vlook.py sheet orig 4190 16 --every 8
  tools/vlook.py steps                        # every game step's frame on the patched ROM against
                                              # the original's frame of that step; a sheet of the
                                              # worst, differences in red

Pictures go to build/video/look/ and can be read as images.  The tests compare memory; this
is for what is on the screen.  A sheet shows garbage that lasts a frame or two, which a
video at speed only lets one suspect.

steps: the patched ROM shows four frames per game step, of which the first is the step's own
and must be the original's.  The two captures are paired by counting flips (stats.txt), and
since a picture can lag its flip by a vblank the best match within the frame's time on show
is taken.  Compared are the mirror's and the view's sprites and the road; the car (its
tiles are sent when there is time) and the background layer (it moves every frame on the
patched ROM, and on the original changes while a frame is on show) are left out by
comparing the road band of the mirror and the view below the horizon, besides the whole.
"""
import argparse, os, sys
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V = os.path.join(ROOT, 'build', 'video')
OUT = os.path.join(V, 'look')
MIRROR = (44, 12, 212, 58)


def load(which, n):
    return np.asarray(Image.open(os.path.join(V, which, 'v%06d.png' % n)).convert('RGB'))


def flips(which):
    r = np.loadtxt(os.path.join(V, which, 'stats.txt'))
    return r[r[:, 4] > 0][:, 0].astype(int)


def sheet(a):
    box, scale, cols = (MIRROR, 3, 4) if a.mirror else ((0, 0, 256, 170), 2, 4)
    w, h = (box[2] - box[0]) * scale, (box[3] - box[1]) * scale
    rows = (a.count + cols - 1) // cols
    im = Image.new('RGB', (w * cols, (h + 14) * rows), (20, 20, 20))
    dr = ImageDraw.Draw(im)
    for i in range(a.count):
        n = a.start + i * a.every
        p = Image.fromarray(load(a.which, n)).crop(box).resize((w, h), Image.NEAREST)
        x, y = (i % cols) * w, (i // cols) * (h + 14)
        im.paste(p, (x, y + 14))
        dr.text((x + 3, y + 1), str(n), fill=(255, 255, 0))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'sheet_%s_%d%s.png' % (a.which, a.start, '_mirror' if a.mirror else ''))
    im.save(path)
    print(path)


def steps(a):
    fo, fs = flips('orig'), flips('sa1')
    n = min(len(fo) - 1, (len(fs) - 1) // 4)
    res = []
    for j in range(a.skip, n):
        best = None
        for o in range(fo[j], fo[j + 1] + 1):
            po = load('orig', o)
            for s in range(fs[4 * j] - 1, fs[4 * j + 1] + 2):
                df = (po != load('sa1', s)).any(axis=2)
                road = int(df[34:58, 44:170].sum())                             # the mirror's road
                view = int(df[108:165].sum() - df[108:140, 95:160].sum())       # below the horizon, less the car
                whole = int(df[12:58, 44:170].sum() + df[62:165].sum() - df[100:140, 95:160].sum())
                t = (road + view, whole, road, view, o, s)
                if best is None or t < best: best = t
        res.append((best, j))
    same = sum(1 for b, j in res if b[0] == 0)
    print('%d game steps: %d show the original\'s sprites and road, %d the original\'s picture whole'
          % (len(res), same, sum(1 for b, j in res if b[1] == 0)))
    bad = sorted([r for r in res if r[0][0]], reverse=True)
    for b, j in bad[:a.list]:
        print('  step %3d: %5d pixels differ (mirror road %d, view %d); original vblank %d, patched %d' % (j, b[0], b[2], b[3], b[4], b[5]))
    worst = bad[:3] or sorted(res, key=lambda r: -r[0][1])[:3]
    scale = 3
    im = Image.new('RGB', (256 * scale * 3, (170 * scale + 16) * len(worst)), (20, 20, 20))
    dr = ImageDraw.Draw(im)
    for r, (b, j) in enumerate(worst):
        po, ps = load('orig', b[4])[:170], load('sa1', b[5])[:170]
        df = (po != ps).any(axis=2)
        mk = (ps * 0.3).astype(np.uint8); mk[df] = (255, 60, 60)
        for c, (p, lab) in enumerate(((po, 'original %d (step %d)' % (b[4], j)), (ps, 'patched %d' % b[5]), (mk, 'differ'))):
            im.paste(Image.fromarray(p).resize((256 * scale, 170 * scale), Image.NEAREST), (c * 256 * scale, r * (170 * scale + 16) + 16))
            dr.text((c * 256 * scale + 4, r * (170 * scale + 16) + 2), lab, fill=(255, 255, 0))
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, 'steps.png')
    im.save(path)
    print(path)
    return 0 if same == len(res) else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('sheet')
    p.add_argument('which', choices=('orig', 'sa1'))
    p.add_argument('start', type=int)
    p.add_argument('count', type=int)
    p.add_argument('--every', type=int, default=2)
    p.add_argument('--mirror', action='store_true')
    p.set_defaults(fn=sheet)
    p = sub.add_parser('steps')
    p.add_argument('--skip', type=int, default=4, help='steps to leave out at the start (the fade-in)')
    p.add_argument('--list', type=int, default=12)
    p.set_defaults(fn=steps)
    a = ap.parse_args()
    sys.exit(a.fn(a) or 0)


if __name__ == '__main__':
    main()
