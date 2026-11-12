#!/usr/bin/env python3
"""Run a ROM headless in Mesen 2 with scripted input; save screenshots and savestates.

  tools/run.py Outlander.sfc --frames 2000 --input "300-304:start;900-:b+right" --every 120
  tools/run.py Outlander.sfc --load build/drive.mss --frames 600 --lua tools/probe.lua

--input   "A-B:btn+btn;..."  frames are counted from the start of this run (after --load);
          an open end ("900-") holds to the end of the run.
--shot    comma list of frames to screenshot; --every N screenshots every N frames.
          PNGs go to --out (default build/shots) and a contact sheet is written beside them.
--save    "FRAME:path" writes a savestate at that frame (repeatable).
--load    savestate to load on the first frame.
--lua     extra Lua file appended to the script.  It can use FRAME (frames since start),
          OUT (output directory) and define on_frame(n) / on_end() hooks, and input_hook(),
          which returns a table of pressed buttons to use instead of --input (or nil).
          on_end() may set EXIT_CODE; run.py exits with status 1 if Mesen's is not 0.
Everything the script prints goes to stdout.
"""
import argparse, os, re, subprocess, sys, tempfile

BTN = 'a b x y l r up down left right select start'.split()

LUA = r'''
-- Mesen drops errors raised inside callbacks without a word: report them and end the run.
do
  local function guard(fn)
    return function(...)
      local ok, err = xpcall(fn, debug.traceback, ...)
      if not ok then print("LUA ERROR: " .. tostring(err)); emu.stop(3) end
    end
  end
  local amc, aec = emu.addMemoryCallback, emu.addEventCallback
  emu.addMemoryCallback = function(fn, ...) return amc(guard(fn), ...) end
  emu.addEventCallback = function(fn, ...) return aec(guard(fn), ...) end
end
FRAME = 0
OUT = %(out)r
local sched = %(sched)s
local shots = %(shots)s
local every = %(every)d
local saves = %(saves)s
local load_path = %(load)s
local total = %(frames)d
local loaded = (load_path == nil)

local function wr(path, data)
  local f = assert(io.open(path, "wb")); f:write(data); f:close()
end

emu.addEventCallback(function()
  if not loaded then return end
  if input_hook then                    -- a --lua file may take over the controller
    local t = input_hook()
    if t then emu.setInput(t, 0); return end
  end
  local inp = {}
  local any = false
  for _, s in ipairs(sched) do
    if FRAME >= s[1] and FRAME <= s[2] then
      for _, b in ipairs(s[3]) do inp[b] = true; any = true end
    end
  end
  emu.setInput(inp, 0)
end, emu.eventType.inputPolled)

-- savestates can only be loaded/saved from inside an exec callback
local pending_save = nil
local ref
local dirtied = %(clean)s
ref = emu.addMemoryCallback(function()
  if not dirtied then
    -- Before the first instruction: battery-backed RAM (the SA-1's BW-RAM) holds whatever the
    -- last session left, on a console and in Mesen (which keeps a .srm).  Fill it with
    -- garbage, the same every run: a variable the patch forgets to set must not get by on a
    -- lucky leftover, and a run must not depend on the one before.
    dirtied = true
    local n = emu.getMemorySize(emu.memType.snesSaveRam)
    local v = %(seed)d
    for a = 0, n - 1 do
      v = (v * 1103515245 + 12345) %% 2147483648
      emu.write(a, (v >> 16) & 0xFF, emu.memType.snesSaveRam)
    end
  end
  if not loaded then
    local f = assert(io.open(load_path, "rb")); local d = f:read("a"); f:close()
    emu.loadSavestate(d); loaded = true
  end
  if pending_save then
    wr(pending_save, emu.createSavestate()); pending_save = nil
  end
end, emu.callbackType.exec, 0x000000, 0xFFFFFF, emu.cpuType.snes, emu.memType.snesMemory)

emu.addEventCallback(function()
  if not loaded then return end
  FRAME = FRAME + 1
  if shots[FRAME] or (every > 0 and FRAME %% every == 0) then
    wr(string.format("%%s/f%%06d.png", OUT, FRAME), emu.takeScreenshot())
  end
  if saves[FRAME] then pending_save = saves[FRAME] end
  if on_frame then on_frame(FRAME) end
  if FRAME >= total and not pending_save then
    if on_end then on_end() end
    emu.stop(EXIT_CODE or 0)          -- an on_end hook may set EXIT_CODE to fail the run
  end
end, emu.eventType.endFrame)
'''


def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'


def parse_input(spec, frames):
    out = []
    for part in filter(None, (p.strip() for p in spec.split(';'))):
        rng, btns = part.split(':')
        a, _, b = rng.partition('-')
        a = int(a); b = int(b) if b else (frames if '-' in rng else a)
        bl = [x.strip().lower() for x in btns.split('+')]
        for x in bl:
            assert x in BTN, 'unknown button ' + x
        out.append('{%d,%d,{%s}}' % (a, b, ','.join(lua_str(x) for x in bl)))
    return '{' + ','.join(out) + '}'


def contact_sheet(out, names, cols=6):
    from PIL import Image, ImageDraw
    ims = [(n, Image.open(os.path.join(out, n)).convert('RGB')) for n in names]
    if not ims: return
    w, h = ims[0][1].size
    rows = (len(ims) + cols - 1) // cols
    sheet = Image.new('RGB', (cols * w, rows * (h + 12)), (32, 32, 32))
    d = ImageDraw.Draw(sheet)
    for i, (n, im) in enumerate(ims):
        x, y = (i % cols) * w, (i // cols) * (h + 12)
        sheet.paste(im, (x, y + 12)); d.text((x + 2, y), n[1:-4].lstrip('0') or '0', fill=(255, 255, 0))
    p = os.path.join(out, 'sheet.png'); sheet.save(p); return p


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('rom'); ap.add_argument('--frames', type=int, default=600)
    ap.add_argument('--input', default=''); ap.add_argument('--shot', default='')
    ap.add_argument('--every', type=int, default=0); ap.add_argument('--out', default='build/shots')
    ap.add_argument('--save', action='append', default=[]); ap.add_argument('--load')
    ap.add_argument('--lua', action='append', default=[]); ap.add_argument('--keep', action='store_true',
                    help='keep old PNGs in --out')
    ap.add_argument('--timeout', type=int, default=900)
    ap.add_argument('--bw-seed', type=int, default=1, help='seed of the garbage battery-backed RAM starts with')
    ap.add_argument('--bw-keep', action='store_true', help='leave battery-backed RAM as Mesen loaded it')
    a = ap.parse_args()
    out = os.path.abspath(a.out); os.makedirs(out, exist_ok=True)
    if not a.keep:
        for n in os.listdir(out):
            if re.fullmatch(r'f\d+\.png|sheet\.png', n): os.remove(os.path.join(out, n))
    saves = []
    for s in a.save:
        f, p = s.split(':', 1); saves.append('[%d]=%s' % (int(f), lua_str(os.path.abspath(p))))
    script = LUA % dict(
        out=out, sched=parse_input(a.input, a.frames),
        shots='{' + ','.join('[%d]=true' % int(x) for x in a.shot.split(',') if x) + '}',
        every=a.every, saves='{' + ','.join(saves) + '}',
        load=lua_str(os.path.abspath(a.load)) if a.load else 'nil', frames=a.frames,
        clean='true' if (a.bw_keep or a.load) else 'false', seed=a.bw_seed)
    script = script.replace("OUT = '%s'" % out, 'OUT = ' + lua_str(out))
    for l in a.lua:
        script += '\n' + open(l).read()
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as f:
        f.write(script); path = f.name
    try:
        p = subprocess.run(['mesen2', '--testRunner', '--timeout=%d' % a.timeout, os.path.abspath(a.rom), path],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=a.timeout)
    finally:
        os.unlink(path)
    for line in p.stdout.splitlines():
        if 'Uninitialized memory read' not in line: print(line)
    names = sorted(n for n in os.listdir(out) if re.fullmatch(r'f\d+\.png', n))
    if names:
        print('sheet:', contact_sheet(out, names))
    if p.returncode: sys.exit('mesen exit %d' % p.returncode)


if __name__ == '__main__':
    main()
