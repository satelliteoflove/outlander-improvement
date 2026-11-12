"""The picture side of tools/video.py: lays the two captured runs out side by side, each
over a panel with its frame rate, how busy its CPUs are and their last ten seconds, and
pipes the frames to ffmpeg.

Layout, 1920x1080: two columns of 896 (the game's 256x224 at 3.5 x 3: its pixels are 8:7 on
a television), a title band above and a 240-line panel below each.  Colours are the dark
set of the dataviz palette (blue and orange, checked for colour-blind separation on this
surface); text is never in a series colour.

The video is 60 frames a second, one per vblank of the console, whose own rate is 60.0988:
the sound is slowed by that 0.16% to match, so that no frame is dropped or doubled.
"""
import os, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1920, 1080
FPS = 60.0988
SURFACE, PANEL, TRACK, GRID = (18, 18, 17), (26, 26, 25), (44, 44, 41), (56, 56, 53)
INK, INK2, INK3 = (240, 239, 236), (195, 194, 183), (133, 132, 125)
C_S, C_A = (57, 135, 229), (217, 89, 38)            # S-CPU, SA-1
COL_X, COL_W, GAME_Y, GAME_H = (48, 976), 896, 132, 672
PANEL_Y, PANEL_H = 820, 232
WINDOW = 600                                        # vblanks of history in the chart
FONT_DIR = '/usr/share/fonts/truetype/'


FONTS = {'regular': ('noto/NotoSans-Medium.ttf', 'dejavu/DejaVuSans.ttf'),            # (Noto's figures are
         'bold': ('noto/NotoSans-SemiBold.ttf', 'dejavu/DejaVuSans-Bold.ttf'),          #  all one width)
         'heavy': ('noto/NotoSansDisplay-ExtraBold.ttf', 'noto/NotoSans-ExtraBold.ttf', 'dejavu/DejaVuSans-Bold.ttf')}

def font(weight, size):
    for p in FONTS[weight]:
        if os.path.exists(FONT_DIR + p): return ImageFont.truetype(FONT_DIR + p, size)
    return ImageFont.load_default()


class Clip:
    """One ROM's capture: frames, and per-vblank figures smoothed for display."""
    def __init__(self, d, has_sa1):
        self.d, self.has_sa1 = d, has_sa1
        rows = np.loadtxt(os.path.join(d, 'stats.txt'))
        self.first = int(rows[0, 0])
        self.s, self.a, self.flips = rows[:, 2], rows[:, 3], rows[:, 4]
        self.n = len(rows)
        fl = np.nonzero(self.flips)[0]
        if not len(fl): sys.exit(d + ': the driving scene was never shown')
        self.f0 = int(fl[0])                        # (index into the rows) first frame of the scene
        self.f1 = int(fl[-1])                       # and its last
        self.s_line, self.a_line = self.trail(self.s, 16), self.trail(self.a, 16)
        self.s_bar, self.a_bar = self.trail(self.s, 30), self.trail(self.a, 30)
        self.fps = self.trail(self.flips, 60) * 60
        names = sorted(n for n in os.listdir(d) if n.startswith('v') and n.endswith('.png'))
        self.png0 = int(names[0][1:-4]); self.png1 = int(names[-1][1:-4])
        self.cache = (None, None)

    @staticmethod
    def trail(v, k):
        c = np.concatenate(([0.0], np.cumsum(np.clip(v, 0, None))))
        i = np.arange(1, len(v) + 1)
        lo = np.maximum(i - k, 0)
        return (c[i] - c[lo]) / (i - lo)

    def picture(self, i):
        """The game's picture at row i, scaled to 896x672 (None before the capture began)."""
        f = self.first + i
        if f < self.png0: return None
        f = min(f, self.png1)
        if self.cache[0] != f:
            im = np.asarray(Image.open(os.path.join(self.d, 'v%06d.png' % f)).convert('RGB'))[:224]
            x = np.repeat(im, 7, axis=1).reshape(im.shape[0], 896, 2, 3).mean(axis=2)
            self.cache = (f, np.repeat(x, 3, axis=0).astype(np.uint8))
        return self.cache[1]


def base_frame(title, note):
    im = Image.new('RGB', (W, H), SURFACE)
    d = ImageDraw.Draw(im)
    d.text((COL_X[0], 26), title, font=font('bold', 38), fill=INK)
    f = font('regular', 20)
    d.text((COL_X[1] + COL_W - d.textlength(note, font=f), 44), note, font=f, fill=INK3)
    for x, name, sub in ((COL_X[0], 'ORIGINAL', 'S-CPU alone'), (COL_X[1], 'WITH SA-1', 'the same cartridge with an SA-1 chip added')):
        fb = font('bold', 22)
        d.text((x, 92), name, font=fb, fill=INK)
        d.text((x + d.textlength(name, font=fb) + 14, 95), sub, font=font('regular', 18), fill=INK3)
        d.rectangle((x, GAME_Y, x + COL_W - 1, GAME_Y + GAME_H - 1), fill=(0, 0, 0))
        d.rounded_rectangle((x, PANEL_Y, x + COL_W - 1, PANEL_Y + PANEL_H - 1), radius=8, fill=PANEL)
        # frame rate
        d.text((x + 28, PANEL_Y + 168), 'frames per second', font=font('regular', 18), fill=INK2)
        # the chart's frame: hairlines at 0, 50 and 100%
        cx, cy, cw, ch = chart_box(x)
        ft = font('regular', 15)
        d.text((cx, PANEL_Y + 18), 'CPU ACTIVITY', font=font('bold', 15), fill=INK2)
        for frac, lab in ((0, '0'), (0.5, '50'), (1, '100%')):
            y = cy + ch - round(frac * ch)
            d.line((cx, y, cx + cw, y), fill=GRID, width=1)
            d.text((cx + cw + 8, y - 10), lab, font=ft, fill=INK3)
        d.text((cx, cy + ch + 8), '10 seconds ago', font=ft, fill=INK3)
        d.text((cx + cw - d.textlength('now', font=ft), cy + ch + 8), 'now', font=ft, fill=INK3)
    return im


def chart_box(x):
    return x + 548, PANEL_Y + 50, 286, 140


def bar_rows(x):
    return x + 216, (PANEL_Y + 30, PANEL_Y + 124), 290


def draw_panel(im, d, x, clip, i, fonts):
    big, name_f, mhz_f, pct_f, small = fonts
    live = i >= clip.f0
    # ---- frame rate: the headline
    txt = '%d' % round(clip.fps[i]) if live else '–'
    d.text((x + 26, PANEL_Y + 18), txt, font=big, fill=INK)
    # ---- bars, which are the chart's legend too
    bx, ys, bw = bar_rows(x)
    for y, name, mhz, col, series, present in (
            (ys[0], 'S-CPU', '3.58 MHz', C_S, clip.s_bar, True),
            (ys[1], 'SA-1', '10.74 MHz', C_A, clip.a_bar, clip.has_sa1)):
        d.rounded_rectangle((bx, y + 6, bx + 13, y + 19), radius=3, fill=col if present else TRACK)
        d.text((bx + 24, y - 3), name, font=name_f, fill=INK if present else INK3)
        d.text((bx + 24 + d.textlength(name, font=name_f) + 10, y + 3), mhz if present else 'not fitted',
               font=mhz_f, fill=INK3)
        d.rounded_rectangle((bx, y + 38, bx + bw, y + 50), radius=4, fill=TRACK)
        if present:
            v = float(series[i - i % 6])            # (the figure changes ten times a second)
            p = '%d%%' % round(100 * v)
            d.text((bx + bw - d.textlength(p, font=pct_f), y - 3), p, font=pct_f, fill=INK)
            w = round(v * bw)
            if w >= 8: d.rounded_rectangle((bx, y + 38, bx + w, y + 50), radius=4, fill=col)
    # ---- the last ten seconds, drawn at twice the size and scaled down
    cx, cy, cw, ch = chart_box(x)
    S = 2
    pad = 4
    g = Image.new('RGBA', (cw * S, (ch + 2 * pad) * S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(g)
    lo = max(clip.f0, i - WINDOW + 1)
    if live and i > lo:
        xs = (cw - (i - np.arange(lo, i + 1)) * (cw / (WINDOW - 1))) * S
        for series, col, present in ((clip.s_line, C_S, True), (clip.a_line, C_A, clip.has_sa1)):
            if not present: continue
            ysr = (pad + ch - series[lo:i + 1] * ch) * S
            pts = list(zip(xs.tolist(), ysr.tolist()))
            gd.line(pts, fill=col + (255,), width=2 * S, joint='curve')
            ex, ey = pts[-1]
            gd.ellipse((ex - 5 * S, ey - 5 * S, ex + 5 * S, ey + 5 * S), fill=PANEL + (255,))
            gd.ellipse((ex - 3.5 * S, ey - 3.5 * S, ex + 3.5 * S, ey + 3.5 * S), fill=col + (255,))
    g = g.resize((cw, ch + 2 * pad), Image.LANCZOS)
    im.paste(g, (cx, cy - pad), g)


def compose(V, a):
    orig, sa1 = Clip(os.path.join(V, 'orig'), False), Clip(os.path.join(V, 'sa1'), True)
    start = round(a.start * FPS)
    drive = min(orig.f1 - orig.f0, sa1.f1 - sa1.f0)        # (the original gets through the take sooner or later)
    count = min(round(a.seconds * FPS), drive - start)
    if count <= 0: sys.exit('nothing to show from %.1f s on: the capture has %.1f s of driving' % (a.start, drive / FPS))
    title = getattr(a, 'title', None) or 'Outlander (SNES) with the SA-1'
    base = base_frame(title, getattr(a, 'note', None) or 'One playthrough, replayed on both in Mesen 2')
    fonts = (font('heavy', 104), font('bold', 22), font('regular', 16),
             font('bold', 22), font('regular', 15))
    still = getattr(a, 'still', None)
    if still is not None:
        im = frame(base, orig, sa1, start + round(still * FPS), fonts)
        p = os.path.splitext(a.out)[0] + '.png'; im.save(p); print(p); return
    # ---- sound
    ins, filt, amap = [], [], []
    sec = count / 60.0
    tempo = 60.0 / FPS
    def track(clip, k):
        t = (clip.first + clip.f0 + start - clip.png0) / FPS       # where the clip begins in its recording
        ins.extend(['-i', os.path.join(clip.d, 'audio.wav')])
        return '[%d:a]atrim=start=%.4f,asetpts=PTS-STARTPTS,atempo=%.6f' % (k, max(t, 0), tempo) + \
               (',adelay=%d:all=1' % round(-t * 1000 / tempo) if t < 0 else '')
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
        ff.stdin.write(frame(base, orig, sa1, start + j, fonts).tobytes())
        if j % 300 == 0: print('  frame %d of %d' % (j, count), flush=True)
    ff.stdin.close()
    if ff.wait(): sys.exit('ffmpeg failed')
    print('%s: %.1f s' % (a.out, sec))
    print('  frames per second, mean over this part: original %.1f, with SA-1 %.1f' % (
        mean_fps(orig, start, count), mean_fps(sa1, start, count)))
    print('  the driving scene: original %.1f s, with SA-1 %.1f s' % ((orig.f1 - orig.f0) / FPS, (sa1.f1 - sa1.f0) / FPS))


def mean_fps(clip, start, count):
    lo = max(clip.f0 + start, clip.f0); hi = clip.f0 + start + count
    return clip.flips[lo:hi].sum() * 60.0 / max(hi - lo, 1)


def frame(base, orig, sa1, t, fonts):
    """The picture t vblanks after each clip's first frame of the driving scene."""
    im = base.copy()
    d = ImageDraw.Draw(im)
    for x, clip in ((COL_X[0], orig), (COL_X[1], sa1)):
        i = min(max(clip.f0 + t, 0), clip.n - 1)
        pic = clip.picture(i)
        if pic is not None: im.paste(Image.fromarray(pic), (x, GAME_Y))
        draw_panel(im, d, x, clip, i, fonts)
    return im
