#!/usr/bin/env python3
"""Headless libretro host used to test the ROM (frames -> PNG, audio -> WAV, RAM peeks).
Copied from the snes-shooter project; SNES_CORE picks the core (default: bsnes-mercury accuracy).

  emu.py rom.sfc --frames 600 --shot 60,120,600 --input "100-200:right+b;300-:start" --wav out.wav
"""
import ctypes as C, sys, os, struct, wave, argparse
import numpy as np

CORE = os.environ.get('SNES_CORE', os.path.expanduser('~/.config/retroarch/cores/bsnes_mercury_accuracy_libretro.so'))

BTN = dict(b=0, y=1, select=2, start=3, up=4, down=5, left=6, right=7, a=8, x=9, l=10, r=11)

class GameInfo(C.Structure):
    _fields_ = [('path', C.c_char_p), ('data', C.c_void_p), ('size', C.c_size_t), ('meta', C.c_char_p)]
class Geometry(C.Structure):
    _fields_ = [('base_width', C.c_uint), ('base_height', C.c_uint), ('max_width', C.c_uint),
                ('max_height', C.c_uint), ('aspect', C.c_float)]
class Timing(C.Structure):
    _fields_ = [('fps', C.c_double), ('sample_rate', C.c_double)]
class AVInfo(C.Structure):
    _fields_ = [('geometry', Geometry), ('timing', Timing)]
class MemDesc(C.Structure):
    _fields_ = [('flags', C.c_uint64), ('ptr', C.c_void_p), ('offset', C.c_size_t), ('start', C.c_size_t),
                ('select', C.c_size_t), ('disconnect', C.c_size_t), ('len', C.c_size_t), ('addrspace', C.c_char_p)]
class MemMap(C.Structure):
    _fields_ = [('descriptors', C.POINTER(MemDesc)), ('num', C.c_uint)]
class Variable(C.Structure):
    _fields_ = [('key', C.c_char_p), ('value', C.c_char_p)]

ENV_T = C.CFUNCTYPE(C.c_bool, C.c_uint, C.c_void_p)
VIDEO_T = C.CFUNCTYPE(None, C.c_void_p, C.c_uint, C.c_uint, C.c_size_t)
AUDIO_T = C.CFUNCTYPE(None, C.c_int16, C.c_int16)
AUDIOB_T = C.CFUNCTYPE(C.c_size_t, C.POINTER(C.c_int16), C.c_size_t)
POLL_T = C.CFUNCTYPE(None)
STATE_T = C.CFUNCTYPE(C.c_int16, C.c_uint, C.c_uint, C.c_uint, C.c_uint)
LOG_T = C.CFUNCTYPE(None, C.c_int, C.c_char_p)

class Emu:
    def __init__(self, rom_path, core=CORE, verbose=False):
        self.core = C.CDLL(core)
        self.pixfmt = 0
        self.frame = None
        self.audio = []
        self.buttons = 0
        self.buttons2 = 0
        self.memmap = []
        self.vars = {}
        self.var_override = {}
        self.verbose = verbose
        self.sysdir = C.c_char_p(b'/tmp')
        self._cbs = (ENV_T(self._env), VIDEO_T(self._video), AUDIO_T(self._audio),
                     AUDIOB_T(self._audio_batch), POLL_T(lambda: None), STATE_T(self._state))
        c = self.core
        c.retro_set_environment(self._cbs[0])
        c.retro_set_video_refresh(self._cbs[1])
        c.retro_set_audio_sample(self._cbs[2])
        c.retro_set_audio_sample_batch(self._cbs[3])
        c.retro_set_input_poll(self._cbs[4])
        c.retro_set_input_state(self._cbs[5])
        c.retro_init()
        self.romdata = open(rom_path, 'rb').read()
        gi = GameInfo(rom_path.encode(), C.cast(C.c_char_p(self.romdata), C.c_void_p), len(self.romdata), None)
        c.retro_load_game.argtypes = [C.POINTER(GameInfo)]
        c.retro_load_game.restype = C.c_bool
        if not c.retro_load_game(C.byref(gi)):
            raise RuntimeError('core refused ROM')
        av = AVInfo(); c.retro_get_system_av_info(C.byref(av))
        self.fps = av.timing.fps; self.rate = av.timing.sample_rate
        c.retro_get_memory_data.restype = C.c_void_p
        c.retro_get_memory_data.argtypes = [C.c_uint]
        c.retro_get_memory_size.restype = C.c_size_t
        c.retro_get_memory_size.argtypes = [C.c_uint]
        self.nframes = 0

    # ---- callbacks
    def _env(self, cmd, data):
        cmd &= 0xFFFF
        if cmd == 10:   # SET_PIXEL_FORMAT
            self.pixfmt = C.cast(data, C.POINTER(C.c_int))[0]; return True
        if cmd == 9:    # GET_SYSTEM_DIRECTORY
            C.cast(data, C.POINTER(C.c_char_p))[0] = self.sysdir; return True
        if cmd == 31:   # GET_SAVE_DIRECTORY
            C.cast(data, C.POINTER(C.c_char_p))[0] = self.sysdir; return True
        if cmd == 16:   # SET_VARIABLES: remember each option's default (first choice)
            v = C.cast(data, C.POINTER(Variable)); i = 0
            while v[i].key:
                desc = v[i].value or b''
                default = desc.partition(b'; ')[2].split(b'|')[0]
                self.vars[v[i].key] = C.create_string_buffer(self.var_override.get(v[i].key, default))
                i += 1
            return True
        if cmd == 15:   # GET_VARIABLE
            v = C.cast(data, C.POINTER(Variable))[0]
            buf = self.vars.get(v.key)
            if buf is None:
                v.value = None; return False
            v.value = C.cast(buf, C.c_char_p); return True
        if cmd == 17:   # GET_VARIABLE_UPDATE
            C.cast(data, C.POINTER(C.c_bool))[0] = False; return True
        if cmd == 36:   # SET_MEMORY_MAPS
            mm = C.cast(data, C.POINTER(MemMap))[0]
            for i in range(mm.num):
                d = mm.descriptors[i]
                self.memmap.append((d.start, d.select, d.len, d.ptr, d.offset, d.disconnect))
            return True
        if cmd == 3:    # GET_CAN_DUPE
            C.cast(data, C.POINTER(C.c_bool))[0] = True; return True
        return False

    def _video(self, data, w, h, pitch):
        if not data: return
        if self.pixfmt == 2:   # RGB565
            buf = np.frombuffer(C.string_at(data, pitch*h), dtype=np.uint16).reshape(h, pitch//2)[:, :w]
            r = ((buf >> 11) & 31).astype(np.uint8); g = ((buf >> 5) & 63).astype(np.uint8); b = (buf & 31).astype(np.uint8)
            self.frame = np.dstack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)])
        elif self.pixfmt == 1: # XRGB8888
            buf = np.frombuffer(C.string_at(data, pitch*h), dtype=np.uint8).reshape(h, pitch//4, 4)[:, :w]
            self.frame = buf[:, :, [2, 1, 0]].copy()
        else:                  # 0RGB1555
            buf = np.frombuffer(C.string_at(data, pitch*h), dtype=np.uint16).reshape(h, pitch//2)[:, :w]
            r = ((buf >> 10) & 31).astype(np.uint8); g = ((buf >> 5) & 31).astype(np.uint8); b = (buf & 31).astype(np.uint8)
            self.frame = np.dstack([r << 3, g << 3, b << 3])

    def _audio(self, l, r):
        self.audio.append(struct.pack('<hh', l, r))

    def _audio_batch(self, data, frames):
        self.audio.append(C.string_at(data, frames*4)); return frames

    def _state(self, port, device, index, id):
        if device != 1: return 0
        b = self.buttons if port == 0 else self.buttons2 if port == 1 else 0
        return (b >> id) & 1

    # ---- api
    def run(self, n=1, buttons=0):
        if isinstance(buttons, str): buttons = parse_buttons(buttons)
        self.buttons = buttons
        for _ in range(n):
            self.core.retro_run(); self.nframes += 1

    def save_state(self):
        """The whole machine, to give back to load_state (tools/demo.py rewinds with these)."""
        c = self.core
        c.retro_serialize_size.restype = C.c_size_t
        c.retro_serialize.argtypes = [C.c_void_p, C.c_size_t]; c.retro_serialize.restype = C.c_bool
        n = c.retro_serialize_size(); buf = C.create_string_buffer(n)
        if not c.retro_serialize(buf, n): raise RuntimeError('the core would not save its state')
        return buf

    def load_state(self, buf):
        c = self.core
        c.retro_unserialize.argtypes = [C.c_void_p, C.c_size_t]; c.retro_unserialize.restype = C.c_bool
        if not c.retro_unserialize(buf, len(buf)): raise RuntimeError('the core would not load the state')

    def screenshot(self, path, scale=1):
        from PIL import Image
        im = Image.fromarray(self.frame)
        if scale != 1: im = im.resize((im.width*scale, im.height*scale), Image.NEAREST)
        im.save(path)

    def wram(self):
        p = self.core.retro_get_memory_data(2); n = self.core.retro_get_memory_size(2)
        return C.string_at(p, n)

    def bwram(self):
        p = self.core.retro_get_memory_data(0); n = self.core.retro_get_memory_size(0)
        return C.string_at(p, n) if p else b''

    def peek(self, addr, n=1):
        """Read bytes at a SNES bus address using the core's memory map."""
        if 0x7E0000 <= addr < 0x800000:
            return self.wram()[addr-0x7E0000:addr-0x7E0000+n]
        if 0x400000 <= addr < 0x500000:
            return self.bwram()[addr-0x400000:addr-0x400000+n]
        if (addr & 0xFFFF) >= 0x6000 and (addr & 0xFFFF) < 0x8000 and (addr >> 16) < 0x40:
            return self.bwram()[(addr & 0xFFFF)-0x6000:(addr & 0xFFFF)-0x6000+n]
        if addr < 0x100: addr += 0x3000          # SA-1 direct page symbol
        if 0x3000 <= addr < 0x3800:
            for start, select, ln, ptr, offset, disc in self.memmap:
                if start == 0x3000 and ptr:
                    # bsnes maps exactly the 2K of I-RAM; Snes9x hands out a pointer biased by the bus address
                    return C.string_at(ptr + (addr - 0x3000 if ln == 0x800 else addr), n)
        raise KeyError('unmapped address %06X' % addr)

    def peek16(self, addr):
        b = self.peek(addr, 2); return b[0] | (b[1] << 8)

    def save_wav(self, path):
        data = b''.join(self.audio)
        w = wave.open(path, 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(int(round(self.rate)))
        w.writeframes(data); w.close()

    def audio_array(self):
        return np.frombuffer(b''.join(self.audio), dtype=np.int16).reshape(-1, 2)

def parse_buttons(s):
    v = 0
    for t in s.replace(' ', '').split('+'):
        if t: v |= 1 << BTN[t.lower()]
    return v

def parse_input(spec):
    """"100-200:right+b;300-:start" -> list of (start,end,mask)"""
    out = []
    if not spec: return out
    for part in spec.split(';'):
        if not part.strip(): continue
        rng, btn = part.split(':')
        a, _, b = rng.partition('-')
        a = int(a); b = int(b) if b else (10**9 if '-' in rng else a)
        out.append((a, b, parse_buttons(btn)))
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rom'); ap.add_argument('--frames', type=int, default=120)
    ap.add_argument('--shot', default=''); ap.add_argument('--input', default='')
    ap.add_argument('--out', default='build/shots'); ap.add_argument('--wav')
    ap.add_argument('--scale', type=int, default=2)
    ap.add_argument('--peek', default='', help='comma list of hex addr[:len] printed at end')
    ap.add_argument('--sym'); ap.add_argument('--strip', type=int, default=0, help='make a contact strip every N frames')
    a = ap.parse_args()
    e = Emu(a.rom)
    sys.stdout.flush()
    shots = set(int(x) for x in a.shot.split(',') if x)
    inp = parse_input(a.input)
    os.makedirs(a.out, exist_ok=True)
    strip = []
    for f in range(1, a.frames+1):
        m = 0
        for s, t, b in inp:
            if s <= f <= t: m |= b
        e.run(1, m)
        if f in shots: e.screenshot('%s/f%05d.png' % (a.out, f), a.scale)
        if a.strip and f % a.strip == 0: strip.append(e.frame.copy())
    if strip:
        from PIL import Image
        cols = min(len(strip), 6); rows = (len(strip)+cols-1)//cols
        h, w = strip[0].shape[:2]
        sheet = Image.new('RGB', (cols*w, rows*h))
        for i, fr in enumerate(strip): sheet.paste(Image.fromarray(fr), ((i % cols)*w, (i//cols)*h))
        sheet.save('%s/strip.png' % a.out)
    if a.wav: e.save_wav(a.wav)
    sym = {}
    if a.sym:
        import json; sym = json.load(open(a.sym))
    for p in a.peek.split(','):
        if not p: continue
        ad, _, ln = p.partition(':')
        addr = sym[ad] if ad in sym else int(ad, 16)
        d = e.peek(addr, int(ln or 1))
        print('%s(%06X): %s' % (ad, addr, d.hex(' ')))

if __name__ == '__main__':
    main()
