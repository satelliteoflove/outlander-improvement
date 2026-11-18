#!/usr/bin/env python3
"""A before-and-after video of an on-foot stage: the original and the patched game side by
side, the same player script on both, with the hit tests drawn over the picture and, under
it, a few lines on how the game tests a hit and what the patch changes.  The companion of tools/video.py (the driving), for one
showcase: on foot the patch changes nothing of the frame rate (the original already runs
those scenes at 60 frames a second) but the walking and the hit tests (src/tweaks.asm).

  tools/vfoot.py render --stage play_l12     # capture both ROMs, then compose
  tools/vfoot.py compose --seconds 40        # again from the captures (--start, --audio, --still)

render   types the stage's password in at the title screen (tools/password.py; the stages
         are tools/test.py's PASSWORDS) and lets tools/footbot.lua play the stage on each
         ROM: walk right, fight every enemy that comes near until it is down (from
         either side, standing and crouching), break the crates and pick up what is in
         them, and jump twice; the same rules on both.  The two reach the stage on the same
         vblank.  Captured per ROM into build/video/foot/{orig,sa1}: every frame, the
         sound, per-vblank figures and the vblanks each hit test ran (tools/vfootcap.lua).  Needs the default build (with the gameplay changes).
compose  build/video/outlander-foot.mp4, 1920x1080, laid out as the driving video.  Both
         sides start at the stage's first frame and run in real time; a side whose player
         has reached the end of the stage says how long it took.  Default: until three
         seconds after the patched player has (--until both: until both have).
"""
import argparse, os, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = os.path.join(ROOT, 'tools')
sys.path.insert(0, T)
import vcompose as vc
from vcompose import W, H, FPS, SURFACE, INK, INK2, INK3, COL_X, COL_W, GAME_Y, GAME_H, font

V = os.path.join(ROOT, 'build/video/foot')
ORIG = os.path.join(ROOT, 'Outlander.sfc')
SA1 = os.path.join(ROOT, 'build/outlander-sa1.sfc')
TEXT_Y = 826


def capture(which, stage, a):
    import test, password
    pw = test.PASSWORDS[stage][0]
    s, done = password.script(pw)
    rom = SA1 if which == 'sa1' else ORIG
    out = os.path.join(V, which); os.makedirs(out, exist_ok=True)
    for n in os.listdir(out):
        if n.startswith('v') and n.endswith('.png') or n.startswith('audio.wav') or n in ('stats.txt', 'chars.txt', 'params.txt', 'events.txt'):
            os.remove(os.path.join(out, n))
    cfg = os.path.join(V, which + '_cfg.lua')
    open(cfg, 'w').write('FOOTBOT_FROM = %d\nVF_FROM = %d\nVF_TO = %d\n' % (done + 250, done + 250, a.frames))
    so = os.path.join(ROOT, 'build/wavrec.so')
    src = os.path.join(T, 'wavrec.c')
    if not os.path.exists(so) or os.path.getmtime(so) < os.path.getmtime(src):
        subprocess.run(['gcc', '-shared', '-fPIC', '-O1', '-o', so, src, '-ldl', '-lpthread'], check=True)
    env = dict(os.environ, MESEN_PRELOAD=so, MESEN_WAV=os.path.join(out, 'audio.wav'),
               MESEN_CORE=os.path.expanduser('~/.config/Mesen2/MesenCore.so'))
    cmd = [sys.executable, os.path.join(T, 'run.py'), rom, '--frames', str(a.frames), '--input', s, '--out', out,
           '--timeout', '3600', '--lua', cfg, '--lua', os.path.join(T, 'footrom.lua'), '--lua', os.path.join(T, 'footbot.lua'), '--lua', os.path.join(T, 'vfootcap.lua')]
    print('%s: %d vblanks ...' % (which, a.frames), flush=True)
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    line = [l for l in p.stdout.splitlines() if l.startswith('vfootcap')]
    if p.returncode or not line: sys.exit(p.stdout[-3000:] + '\nrun.py failed for ' + rom)
    print('  ' + line[-1])


def cmd_render(a):
    with open(SA1, 'rb') as f:
        f.seek(0x3FFFE0)
        if f.read(6) != b'TWEAKS':
            sys.exit('%s is a TWEAKS=0 build: the video is of the gameplay changes, build with  python3 tools/build.py' % SA1)
    for w in ('orig', 'sa1'): capture(w, a.stage, a)
    cmd_compose(a)


class Clip:
    def __init__(self, d):
        self.d = d
        r = np.loadtxt(os.path.join(d, 'stats.txt'), dtype=np.int64)
        self.first = int(r[0, 0])
        self.scene, self.x, self.landed, self.taken = r[:, 1], r[:, 2], r[:, 3], r[:, 4]
        foot = np.nonzero(self.scene == 1)[0]
        if not len(foot): sys.exit(d + ': no on-foot stage')
        self.f0 = int(foot[0])                              # (rows) the stage's first frame
        after = np.nonzero(self.scene[self.f0:] != 1)[0]
        self.f1 = self.f0 + int(after[0]) if len(after) else None   # its end, if it was reached
        self.n = len(r)
        self.par = {k: int(v) for k, v in (l.split() for l in open(os.path.join(d, 'params.txt')))}
        self.chars = {}                                     # vblank -> (x, flags, reach, [(i, x, kind, health, flags)])
        for l in open(os.path.join(d, 'chars.txt')):
            f = l.split()
            self.chars[int(f[0])] = (int(f[1]), int(f[2]), int(f[3]),
                                     [tuple(int(v) for v in c.split(':')) for c in f[4:]])
        self.punch, self.blows, self.hurt = [], [], []        # vblanks of tests and hurts (events.txt)
        for l in open(os.path.join(d, 'events.txt')):
            f = l.split()
            if f[1] == 'P': self.punch.append(int(f[0]))
            elif f[1] == 'H': self.hurt.append(int(f[0]))
            elif f[1] == 'E': self.blows.append(tuple(int(v) for v in (f[0],) + tuple(f[2:])))
        self.drops = {}                                     # enemy -> vblanks its health dropped
        prev = {}
        for k in sorted(self.chars):
            now = {c[0]: c[3] for c in self.chars[k][3]}
            for i, h in now.items():
                if i in prev and h < prev[i] < 0x80: self.drops.setdefault(i, []).append(k)
            prev = now
        names = sorted(n for n in os.listdir(d) if n.startswith('v') and n.endswith('.png'))
        self.png0, self.png1 = int(names[0][1:-4]), int(names[-1][1:-4])
        self.cache = (None, None)

    def punches_near(self, n):
        return [t for t in self.punch if t - BEFORE <= n <= t + AFTER]

    def blows_near(self, n):
        return [b for b in self.blows if b[0] - BEFORE <= n <= b[0] + AFTER]

    def hit_age(self, i, n):
        ages = [n - k for k in self.drops.get(i, ()) if 0 <= n - k < FLASH]
        return min(ages) if ages else None

    def hurt_age(self, n):
        ages = [n - k for k in self.hurt if 0 <= n - k < FLASH]
        return min(ages) if ages else None

    def picture(self, i):
        f = min(max(self.first + i, self.png0), self.png1)
        if self.cache[0] != f:
            im = np.asarray(Image.open(os.path.join(self.d, 'v%06d.png' % f)).convert('RGB'))[:224]
            x = np.repeat(im, 7, axis=1).reshape(im.shape[0], 896, 2, 3).mean(axis=2)
            self.cache = (f, np.repeat(x, 3, axis=0).astype(np.uint8))
        return self.cache[1]


# The hit tests, drawn over the picture (scaled 3.5 x 3).  The game tests one point of each
# figure, its x (near the left edge whichever way it faces), against how far the other's blow
# reaches from its own x.  Drawn in body terms instead: a box is where the near edge of the
# other's body has to be for the blow to land (the reach moved by where each body starts and
# ends, measured on sprites-only screenshots: the player's from 4 to 19 past his x, an enemy's
# from 7 to 26).  So the end of the green box is how far his punch really reaches.  A box shows
# only around the frame its test runs (events.txt: the player's punch test, an enemy's blow),
# and a figure flashes when it is hit.  Crates are taken as enemies.
G_SX, G_SY = 3.5, 3
C_P, C_E = (92, 224, 112), (240, 84, 72)
P_BODY, E_BODY = (4, 19), (7, 26)
BEFORE, AFTER, FLASH = 5, 12, 12                             # vblanks a box shows around its test; a flash lasts


def strength(n, t):
    """how strongly a box tested at vblank t shows at n (0 to 1)"""
    if n < t - BEFORE or n > t + AFTER: return 0.0
    if n <= t + 3: return 1.0 if n >= t - 1 else 0.55
    return 1.0 - (n - t - 3) / (AFTER - 2)


def draw_hits(pic, clip, n):
    row = clip.chars.get(n)
    if not row: return pic
    px, pf, reach, chars = row
    P = clip.par
    def sx(x): return (0x7C + x - px) * G_SX
    def sy(y): return y * G_SY
    lay = Image.new('RGBA', pic.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    def edge(x, y0, y1, col, k):                        # the front of the body being tested
        if k > 0: d.rectangle((sx(x) - 3, sy(y0), sx(x) + 2, sy(y1)), fill=col + (int(255 * k),))
    def box(x0, x1, y0, y1, col, k, fill=60):
        if k <= 0 or x1 <= x0: return
        d.rectangle((sx(x0), sy(y0), sx(x1) - 1, sy(y1) - 1), fill=col + (int(fill * k),), outline=col + (int(255 * k),), width=4)
    crouch = pf & 0x10
    figs = {i: (x - 0x10000 if x >= 0x8000 else x, kind, h) for i, x, kind, h, f in chars}
    # an enemy's blow: it hits if lo <= his x - its x < hi (on the side it faces), so the
    # near edge of his body has to be within [x + lo + 4, x + hi + 4) on its right, within
    # [x + lo + 19, x + hi + 19) on its left
    for t, i, lo, hi in clip.blows_near(n):
        if i not in figs: continue
        x = figs[i][0]
        k = strength(n, t)
        e = P_BODY[0] if lo > 0 else P_BODY[1]
        box(x + lo + e, x + hi + e, 102, 130, C_E, k)
        edge(px + e, 116 if crouch else 98, 161, C_E, k)
    # his punch: an enemy's x in [px, px + reach) facing right, so its body's left edge in
    # [px + 7, px + reach + 7); facing left its x in [px - left - back - reach + 1, px - left],
    # its right edge in [px - left - back - reach + 27, px - left + 27)
    for t in clip.punches_near(n):
        k = strength(n, t)
        r = clip.chars.get(t, row)[2]
        y0, y1 = (118, 142) if crouch else (102, 128)
        if pf & 0x80: box(px + E_BODY[0], px + r + E_BODY[0], y0, y1, C_P, k)
        else: box(px - P['left'] - P['back'] - r + 1 + E_BODY[1], px - P['left'] + 1 + E_BODY[1], y0, y1, C_P, k)
        # the nearest figure the way he faces (crates only to a crouching punch)
        ahead = [x for x, kind, h in figs.values() if 0 < h < 0x80 and 0x20 <= kind >> 2 < 0x32
                 and kind >> 2 not in (0x26, 0x29, 0x2D) and (crouch or kind >> 2 != 0x2B)
                 and (x - px >= -8 if pf & 0x80 else x - px < 8) and abs(x - px) < 90]
        if ahead:
            x = min(ahead, key=lambda v: abs(v - px))
            edge(x + (E_BODY[0] if pf & 0x80 else E_BODY[1]), 98, 161, C_P, k)
    # who was hit: the body, in the colour of the blow
    for i, (x, kind, h) in figs.items():
        age = clip.hit_age(i, n)
        if age is not None:
            box(x + E_BODY[0], x + E_BODY[1], 98, 161, C_P, 1 - age / FLASH, fill=170)
    age = clip.hurt_age(n)
    if age is not None:
        box(px + P_BODY[0], px + P_BODY[1], 116 if crouch else 98, 161, C_E, 1 - age / FLASH, fill=170)
    return Image.alpha_composite(pic.convert('RGBA'), lay).convert('RGB')


TEXT = (("How the game tests a hit",
         "It never checks whether the sprites touch, only how far apart two figures are. When one "
         "swings, the box shows what counts: the blow lands if the front of the other's body, "
         "marked, is inside it. Green is his punch, red an enemy's."),
        ("What the patch changes",
         "His punch reaches 4 pixels further, about as far as his fist does. Facing left he can now "
         "hit an enemy standing right up against him, as he always could facing right. And he walks "
         "1.5 times as fast."))


def wrap(d, text, f, width):
    lines, cur = [], ''
    for w in text.split():
        t = (cur + ' ' + w).strip()
        if d.textlength(t, font=f) > width and cur: lines.append(cur); cur = w
        else: cur = t
    return lines + [cur]


def base_frame(title, note):
    im = Image.new('RGB', (W, H), SURFACE)
    d = ImageDraw.Draw(im)
    d.text((COL_X[0], 26), title, font=font('bold', 38), fill=INK)
    f = font('regular', 20)
    d.text((COL_X[1] + COL_W - d.textlength(note, font=f), 44), note, font=f, fill=INK3)
    for x, name, sub in ((COL_X[0], 'ORIGINAL', 'as released'),
                         (COL_X[1], 'WITH THE PATCH', 'faster walking, fairer hit tests')):
        fb = font('bold', 22)
        d.text((x, 92), name, font=fb, fill=INK)
        d.text((x + d.textlength(name, font=fb) + 14, 95), sub, font=font('regular', 18), fill=INK3)
        d.rectangle((x, GAME_Y, x + COL_W - 1, GAME_Y + GAME_H - 1), fill=(0, 0, 0))
    # how the game tests a hit, and what the patch changes, big enough to read on a phone
    fh, fb = font('bold', 34), font('regular', 29)
    for x, (head, body) in zip(COL_X, TEXT):
        y = TEXT_Y
        d.text((x, y), head, font=fh, fill=INK); y += 52
        for l in wrap(d, body, fb, COL_W - 8):
            d.text((x, y), l, font=fb, fill=INK2); y += 41
    return im


def mmss(v):
    s = v / FPS
    return '%d:%04.1f' % (s // 60, s % 60)


def draw_time(d, x, clip, t):
    """how long he has been on foot, at the right of the column's heading"""
    i = min(clip.f0 + t, clip.n - 1)
    if clip.f1 is not None and i >= clip.f1:
        txt, f, col = 'stage cleared in %s' % mmss(clip.f1 - clip.f0), font('bold', 24), INK
    else:
        txt, f, col = '%s on foot' % mmss(i - clip.f0), font('regular', 24), INK2
    d.text((x + COL_W - d.textlength(txt, font=f), 90), txt, font=f, fill=col)


def compose(a):
    orig, sa1 = Clip(os.path.join(V, 'orig')), Clip(os.path.join(V, 'sa1'))
    ends = [c.f1 - c.f0 for c in (orig, sa1) if c.f1 is not None]
    start = round(a.start * FPS)
    if a.until == 'both' and len(ends) == 2: total = max(ends) + round(1.5 * FPS)
    elif sa1.f1 is not None: total = sa1.f1 - sa1.f0 + round(3 * FPS)
    else: total = min(orig.n - orig.f0, sa1.n - sa1.f0)
    count = min(round(a.seconds * FPS), total - start) if a.seconds else total - start
    if count <= 0: sys.exit('nothing to show from %.1f s on' % a.start)
    base = base_frame(a.title or 'Outlander (SNES): on foot', 'The same player script on both, in Mesen 2')
    def frame(t):
        im = base.copy()
        d = ImageDraw.Draw(im)
        for x, clip in ((COL_X[0], orig), (COL_X[1], sa1)):
            i = min(clip.f0 + t, clip.n - 1)
            pic = draw_hits(Image.fromarray(clip.picture(i)), clip, clip.first + i)
            if clip.f1 is not None and i >= clip.f1 + 30:     # the stage is behind him: dim what follows
                pic = Image.blend(pic, Image.new('RGB', pic.size, (0, 0, 0)), 0.6)
            im.paste(pic, (x, GAME_Y))
            draw_time(d, x, clip, t)
        return im
    if a.still is not None:
        p = os.path.splitext(a.out)[0] + '.png'; frame(start + round(a.still * FPS)).save(p); print(p); return
    sec = count / 60.0
    tempo = 60.0 / FPS
    ins, filt = [], []
    def track(clip, k):
        t = (clip.first + clip.f0 + start - clip.png0) / FPS        # (as tools/vcompose.py has it)
        ins.extend(['-i', os.path.join(clip.d, 'audio.wav')])
        return '[%d:a]atrim=start=%.4f,asetpts=PTS-STARTPTS,atempo=%.6f' % (k, max(t, 0), tempo)
    fade = ',afade=t=in:d=0.4,afade=t=out:st=%.3f:d=0.6[a]' % (sec - 0.6)
    if a.audio == 'sa1': filt = [track(sa1, 1) + fade]
    elif a.audio == 'orig': filt = [track(orig, 1) + fade]
    elif a.audio == 'both':
        filt = [track(orig, 1) + ',pan=mono|c0=0.5*c0+0.5*c1[l]', track(sa1, 2) + ',pan=mono|c0=0.5*c0+0.5*c1[r]',
                '[l][r]join=inputs=2:channel_layout=stereo' + fade]
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24',
           '-s', '%dx%d' % (W, H), '-framerate', '60', '-i', '-'] + ins
    vf = 'fade=t=in:d=0.4,fade=t=out:st=%.3f:d=0.6,format=yuv420p[v]' % (sec - 0.6)
    cmd += ['-filter_complex', ';'.join(['[0:v]' + vf] + filt), '-map', '[v]']
    if filt: cmd += ['-map', '[a]', '-c:a', 'aac', '-b:a', '256k']
    cmd += ['-c:v', 'libx264', '-preset', 'slow', '-crf', '15', '-t', '%.3f' % sec, '-movflags', '+faststart', a.out]
    ff = subprocess.Popen(cmd, stdin=subprocess.PIPE)
    for j in range(count):
        ff.stdin.write(frame(start + j).tobytes())
        if j % 600 == 0: print('  frame %d of %d' % (j, count), flush=True)
    ff.stdin.close()
    if ff.wait(): sys.exit('ffmpeg failed')
    print('%s: %.1f s' % (a.out, sec))
    for n, c in (('original', orig), ('with the patch', sa1)):
        k = (c.f1 - 1) if c.f1 is not None else c.n - 1
        print('  %s: %s, %d hits taken' % (
            n, 'stage cleared in %s' % mmss(c.f1 - c.f0) if c.f1 is not None else 'stage not cleared', c.taken[k]))


def cmd_compose(a):
    compose(a)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('render', 'compose'):
        p = sub.add_parser(name)
        if name == 'render':
            p.add_argument('--stage', default='play_l12', help="a password scenario of tools/test.py (default play_l12)")
            p.add_argument('--frames', type=int, default=9000, help='vblanks to run each ROM for')
        p.add_argument('--start', type=float, default=0.0, help='seconds from the stage\'s first frame')
        p.add_argument('--seconds', type=float, default=0.0, help='0: as --until says')
        p.add_argument('--until', choices=['sa1', 'both'], default='sa1',
                       help='end 3 s after the patched player has cleared the stage (default), or 1.5 s after both have')
        p.add_argument('--audio', choices=['sa1', 'orig', 'both', 'none'], default='sa1')
        p.add_argument('--out', default=os.path.join(ROOT, 'build/video/outlander-foot.mp4'))
        p.add_argument('--title')
        p.add_argument('--still', type=float, metavar='S', help='only one picture, S seconds in, as a PNG beside --out')
    a = ap.parse_args()
    {'render': cmd_render, 'compose': cmd_compose}[a.cmd](a)


if __name__ == '__main__':
    main()
