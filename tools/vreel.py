#!/usr/bin/env python3
"""The showcase reel: a title card, the driving comparison (tools/video.py), the on-foot
comparison (tools/vfoot.py) and an end card, one after the other, to the music of the first
driving stage.

  tools/vreel.py                      # build/video/outlander-reel.mp4 (and the cards as PNGs)
  tools/vreel.py --cards              # only the two cards, to look at

The music is the game's own: the original is started (Start at vblank 1000), and once the
first drive's song has begun (its command reaches the sound CPU at vblank 1185) the sound
CPU's state is saved as an .spc file (tools/spcdump.lua) and played on by libgme with no
further commands, so the sound effects that would follow never come.  The engine is voice 0
(it sounds all the time, its pitch following the car's speed) and is muted.  The song loops
(about 55 s) for as long as the reel needs.
"""
import argparse, ctypes, os, subprocess, sys, wave
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T = os.path.join(ROOT, 'tools')
sys.path.insert(0, T)
from vcompose import W, H, SURFACE, INK, INK2, INK3, font

V = os.path.join(ROOT, 'build/video')
ORIG = os.path.join(ROOT, 'Outlander.sfc')
DRIVE, FOOT = os.path.join(V, 'outlander-sa1.mp4'), os.path.join(V, 'outlander-foot.mp4')
SPC, MUSIC = os.path.join(V, 'drive1.spc'), os.path.join(V, 'drive1.wav')
RATE = 32000
INTRO_S, OUTRO_S, FADE = 7.0, 14.0, 0.6

INTRO = ('Outlander', 'SA-1 Improvement Patch for the SNES',
         ['Driving at 30 frames a second, up from about 8, at a steady pace',
          'On foot: faster walking and fairer hit tests'],
         'The original and the patched game side by side, in Mesen 2')
OUTRO = ('Outlander: SA-1 Improvement Patch',
         ['A patch for the ROM of the US release.',
          'The SA-1 draws the driving scenes, four frames to every step of the game,',
          'for much smoother driving at a steady pace.',
          'On foot he walks 1.5 times as fast, and his punch lands where his fist does.',
          'Fewer roadblocks and lighter collisions take a little of the edge off.'],
         ['With thanks to Vitor Vilela, whose SA-1 conversions showed the way.',
          'Music: the first driving stage, from the game.'])


def music(seconds):
    """the first drive's song, `seconds` long, as RATE Hz stereo int16"""
    if not os.path.exists(SPC):
        cfg = os.path.join(V, 'spcdump_cfg.lua')
        open(cfg, 'w').write('SPC_AT = 1190\nSPC_OUT = "%s"\n' % SPC)
        p = subprocess.run([sys.executable, os.path.join(T, 'run.py'), ORIG, '--frames', '1192', '--input', '1000-1005:start',
                            '--out', os.path.join(V, 'tmp'), '--lua', cfg, '--lua', os.path.join(T, 'spcdump.lua')],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if not os.path.exists(SPC): sys.exit(p.stdout[-2000:] + '\nno .spc saved')
    g = ctypes.CDLL('libgme.so.0')
    for f in ('gme_open_file', 'gme_start_track', 'gme_play'): getattr(g, f).restype = ctypes.c_char_p
    emu = ctypes.c_void_p()
    if g.gme_open_file(SPC.encode(), ctypes.byref(emu), RATE): sys.exit('libgme cannot open ' + SPC)
    g.gme_ignore_silence(emu, 1)
    g.gme_start_track(emu, 0)
    g.gme_mute_voices(emu, 1)                               # voice 0: the engine
    n = int((seconds + 3) * RATE) * 2
    buf = (ctypes.c_short * n)()
    step = RATE * 2
    for i in range(0, n - step + 1, step):
        if g.gme_play(emu, step, ctypes.byref(buf, i * 2)): sys.exit('libgme failed')
    g.gme_delete(emu)
    a = np.frombuffer(buf, np.int16).reshape(-1, 2)
    first = int(np.argmax(np.abs(a).max(axis=1) > 64))     # (the song starts after a moment of silence)
    return a[first:first + int(seconds * RATE)]


def backdrop(path, dim=0.28, blur=6):
    """a game frame, filling the screen, blurred and darkened"""
    im = Image.open(path).convert('RGB').crop((0, 0, 256, 224)).resize((W, W * 3 // 4), Image.LANCZOS)   # (4:3)
    top = (im.height - H) // 3
    im = im.crop((0, top, W, top + H))
    im = im.filter(ImageFilter.GaussianBlur(blur))
    return Image.blend(Image.new('RGB', (W, H), SURFACE), im, dim)


def centred(d, y, text, f, fill):
    d.text(((W - d.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)


def intro_card(bg):
    im = backdrop(bg)
    d = ImageDraw.Draw(im)
    title, sub, lines, note = INTRO
    centred(d, 250, title.upper(), font('heavy', 150), INK)
    centred(d, 440, sub, font('regular', 44), INK2)
    y = 590
    for l in lines:
        centred(d, y, l, font('bold', 46), INK); y += 72
    centred(d, 900, note, font('regular', 32), INK3)
    return im


def outro_card(bg):
    im = backdrop(bg, dim=0.2)
    d = ImageDraw.Draw(im)
    title, lines, small = OUTRO
    centred(d, 190, title, font('heavy', 88), INK)
    y = 380
    for l in lines:
        centred(d, y, l, font('regular', 42), INK); y += 64
    y += 90
    for l in small:
        centred(d, y, l, font('regular', 32), INK2); y += 52
    return im


def cards():
    frames = sorted(n for n in os.listdir(os.path.join(V, 'sa1')) if n.endswith('.png'))
    pics = (intro_card(os.path.join(V, 'sa1', frames[len(frames) * 2 // 3])),
            outro_card(os.path.join(V, 'foot/sa1', sorted(n for n in os.listdir(os.path.join(V, 'foot/sa1')) if n.endswith('.png'))[1500])))
    paths = []
    for name, im in zip(('intro', 'outro'), pics):
        p = os.path.join(V, 'reel-%s.png' % name); im.save(p); paths.append(p)
    return paths


def length(p):
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', p],
                                stdout=subprocess.PIPE, text=True, check=True).stdout)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--cards', action='store_true', help='only the cards, as PNGs')
    ap.add_argument('--out', default=os.path.join(V, 'outlander-reel.mp4'))
    a = ap.parse_args()
    intro, outro = cards()
    if a.cards: print(intro); print(outro); return
    for p in (DRIVE, FOOT):
        if not os.path.exists(p): sys.exit(p + ' is missing: tools/video.py render, tools/vfoot.py render')
    total = INTRO_S + length(DRIVE) + length(FOOT) + OUTRO_S
    m = music(total)
    with wave.open(MUSIC, 'wb') as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(RATE); w.writeframes(m.tobytes())
    card = 'fps=60,format=yuv420p,setsar=1,fade=t=in:d=%.2f,fade=t=out:st=%.3f:d=%.2f'
    fc = ['[0:v]' + card % (FADE, INTRO_S - FADE, FADE) + '[i]',
          '[1:v]fps=60,format=yuv420p,setsar=1[d]',
          '[2:v]fps=60,format=yuv420p,setsar=1[f]',
          '[3:v]' + card % (FADE, OUTRO_S - 1.5, 1.5) + '[o]',
          '[i][d][f][o]concat=n=4:v=1:a=0[v]',
          '[4:a]aresample=48000,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000,afade=t=in:d=0.5,'
          'afade=t=out:st=%.3f:d=3[a]' % (total - 3)]
    cmd = ['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y',
           '-loop', '1', '-framerate', '60', '-t', '%.3f' % INTRO_S, '-i', intro,
           '-i', DRIVE, '-i', FOOT,
           '-loop', '1', '-framerate', '60', '-t', '%.3f' % OUTRO_S, '-i', outro,
           '-i', MUSIC, '-filter_complex', ';'.join(fc), '-map', '[v]', '-map', '[a]',
           '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-c:a', 'aac', '-b:a', '256k',
           '-t', '%.3f' % total, '-movflags', '+faststart', a.out]
    subprocess.run(cmd, check=True)
    print('%s: %.1f s' % (a.out, total))


if __name__ == '__main__':
    main()
