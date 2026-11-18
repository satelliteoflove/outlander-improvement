-- The game must play the same, game frame for game frame, however long a frame takes.
-- Records, on the original, a fingerprint of the game's state at every exit of the driving
-- block and of what is put on show at every flip; on the patched ROM, compares.
--
--   exit   all low RAM (but PLAY_MASK: what the interrupt handlers write, whose timing
--          differs) and $7E:2000-$7FFF, where the patch leaves them once the SA-1 is done
--   flip   what the NMI handler shows a frame with: the frame buffer, the sprite tables,
--          the two HDMA tables it points the PPU at (wherever they are), and the low RAM
--          it takes over ($5C, $01B0, $0199).  Also checked at every flip, on either
--          ROM: the tiles in VRAM are the frame buffer's
-- Of the frame buffer, both take what the pass wrote (address and value of every byte
-- written since the loop head ran): the game leaves bytes of the tiles it allocates
-- unwritten, and what those hold is whatever an earlier frame left there.
--
-- The patched ROM shows three in-between frames after every game step's (src/sub.asm).
-- Those are not the original's and are left out here, but for the VRAM check; which VRAM
-- page a frame goes to ($DC) is not compared either, since they take their turns too.
--
-- Input cannot be scripted by vblank for this: the game samples the pad once per game
-- frame, and the two ROMs reach a given game frame at different times.  So the pad is
-- given per game frame: when the game takes its k-th sample (the loop head's LDX $38, or
-- try_early's on the patched ROM), the buttons for sample k+1 are put on the pad, and the
-- vblanks until then all read those.  Until the first sample, run.py's --input applies.
--   PLAY_AUTO = {...}   (record only) hold Y and steer by the car's distance from the middle
--                       of the road ($B9); the buttons chosen are written to PLAY_PATH..".pad"
--   otherwise           the .pad file is replayed if there is one; without one the pad is
--                       left to --input (the attract demo needs none)
-- PLAY_MODE = "record" | "check" | "pad" (replay the .pad file and nothing else), PLAY_PATH,
-- PLAY_MASK = {[addr]=true}; PLAY_MAX = game frames to record (default all).  Needs SYM and build/blk_low.lua for the patched ROM.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local W, B, IR = emu.memType.snesWorkRam, emu.memType.snesSaveRam, emu.memType.sa1InternalRam
local patched = (SYM ~= nil and SYM.blk_back ~= nil)
local rec = (PLAY_MODE == "record")
local P = 4294967291
local function sa1_rd(a)
  local v = a < 0x100 and emu.read(a, IR) or emu.read(a, B)
  if LOW_BANK[a] and (v == 0x40 or v == 0x41) then v = v + 0x3E end
  return v
end
local function own() return patched and emu.read(SYM.own_addr, B) ~= 0 end
local function rd16(a) return emu.read(a, W) | (emu.read(a + 1, W) << 8) end

-- ---- the pad, per game frame
local pad, k, cur_pad = nil, 0, nil
local pad_out
do
  local f = (not PLAY_AUTO) and io.open(PLAY_PATH .. ".pad", "r")
  if f then
    pad = {}
    for l in f:lines() do
      local t = {}
      for b in l:gmatch("%a+") do t[b] = true end
      pad[#pad + 1] = t
    end
    f:close()
  end
  if PLAY_AUTO and rec then pad_out = assert(io.open(PLAY_PATH .. ".pad", "w")) end
end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local function autopilot(n)             -- the buttons for game frame n, from the state now
  local t = {y = true}
  local off = s16(rd16(0xB9))
  local lim = PLAY_AUTO.dead or 24
  if off > lim then t[PLAY_AUTO.pos or "left"] = true elseif off < -lim then t[PLAY_AUTO.neg or "right"] = true end
  local fire = PLAY_AUTO.fire or 0
  if fire > 0 and n % fire < (PLAY_AUTO.fire_len or 3) then t.x = true end
  return t
end
local function sample()
  k = k + 1
  if PLAY_AUTO and rec then
    cur_pad = autopilot(k + 1)
    local names = {}
    for b in pairs(cur_pad) do names[#names + 1] = b end
    table.sort(names)
    pad_out:write(#names > 0 and table.concat(names, " ") or "-", "\n")
  elseif pad then
    cur_pad = pad[k] or {}
  end
end
-- (the loop runs in bank $00 when a game is started from the title screen, in $80 after an
-- on-foot stage; the patched ROM's head_hook carries on in $00)
for _, a in ipairs({0x008C73, 0x808C73}) do emu.addMemoryCallback(sample, emu.callbackType.exec, a, a, C, M) end
if patched and SYM.te_commit then emu.addMemoryCallback(sample, emu.callbackType.exec, SYM.te_commit, SYM.te_commit, C, M) end
function input_hook() return cur_pad end

if PLAY_MODE ~= "pad" then      -- ("pad": only replay the buttons, for other tests)
-- ---- fingerprints
local MASK = PLAY_MASK or {}
MASK[0xDC] = true       -- which VRAM page the next frame goes to: the in-between frames take turns too
-- what the pass has written of the frame buffer
local fbw, fbn = {}, 0
for _, a in ipairs({0x008CA3, 0x808CA3}) do emu.addMemoryCallback(function() fbw = {}; fbn = 0 end, emu.callbackType.exec, a, a, C, M) end
local function fb_wr(a)
  a = a & 0xFFFF
  if not fbw[a] then fbw[a] = true; fbn = fbn + 1 end
end
if patched then
  emu.addMemoryCallback(function(a)
    if SYM.sbx_addr and emu.read(SYM.sbx_addr, B) ~= 0 then return end       -- (an in-between frame)
    fb_wr(a)
  end, emu.callbackType.write, 0x4030E5, 0x4070E4, emu.cpuType.sa1, emu.memType.sa1Memory)
else
  emu.addMemoryCallback(fb_wr, emu.callbackType.write, 0x7E30E5, 0x7E70E4, C, M)
end
local function h_fb(h, mt)
  h = (h * 31 + fbn) % P
  for a = 0x30E5, 0x70E4 do
    if fbw[a] then h = ((h * 31 + a) * 31 + emu.read(a, mt)) % P end
  end
  return h
end
local n_exit = 0
local function h_exit()
  local o = own()
  local h1, h2 = 0, 0
  n_exit = n_exit + 1
  local dump = (PLAY_DUMP_LOW == n_exit) and {} or nil      -- PLAY_DUMP_LOW = k: print the low RAM hashed at exit k
  for a = 0, 0x7FF do
    if not MASK[a] and (a < 0x200 or a >= 0x400) then
      local v
      if patched and LOW_OUT[a] then v = sa1_rd(a) else v = emu.read(a, W) end
      h1 = (h1 * 31 + v) % P
      if dump then dump[#dump + 1] = string.format("%04X=%02X", a, v) end
    end
  end
  if dump then print("LOWDUMP " .. table.concat(dump, " ")) end
  local mt = o and B or W
  for a = 0x2000, 0x30E4 do h2 = (h2 * 31 + emu.read(a, mt)) % P end
  h2 = h_fb(h2, mt)
  for a = 0x70E5, 0x7FFF do h2 = (h2 * 31 + emu.read(a, mt)) % P end
  return h1, h2
end
local ENDS = { {0x2000, 0x22CA}, {0x22CB, 0x2595}, {0x2C9E, 0x2CE9}, {0x2CEA, 0x2D35},       -- the game's HDMA buffers
               {0x1100, 0x13CA}, {0x13CB, 0x1416}, {0x1420, 0x16EA}, {0x16EB, 0x1736} }      -- the patch's display buffers
local function h_table(h, p, mt)
  for _, r in ipairs(ENDS) do
    if p >= r[1] and p <= r[2] then
      h = (h * 31 + (r[2] - p)) % P
      for a = p, r[2] do h = (h * 31 + emu.read(a, mt)) % P end
      return h
    end
  end
  return (h * 31 + 0xBAD) % P
end
local function h_flip()
  local mt = own() and B or W
  local h = h_fb(0, mt)
  for a = 0x2D36, 0x2F54 do h = (h * 31 + emu.read(a, mt)) % P end
  local t = h_table(h_table(0, rd16(0x2F), mt), rd16(0x32), mt)
  local l = 0
  for _, a in ipairs({0x5C, 0x5D, 0x01B0, 0x01B1, 0x0199, 0xDF, 0xE0}) do l = (l * 31 + emu.read(a, W)) % P end
  return h, t, l
end

-- ---- record / check
local vram_bad, vram_shown, subs = 0, 0, 0
local lines, want, nx, nf, bad, shown_bad = {}, {x = {}, f = {}}, 0, 0, 0, 0
if not rec then
  for l in assert(io.open(PLAY_PATH, "r")):lines() do
    local kind = l:sub(1, 1)
    if want[kind] then local t = want[kind]; t[#t + 1] = l end
  end
end
local done = false
local function event(kind, line)
  if done then return end
  if rec then lines[#lines + 1] = line; return end
  local n = (kind == "x") and nx or nf
  local w = want[kind][n]
  if w == nil then return end                 -- past the end of the recording
  if w ~= line then
    bad = bad + 1
    if shown_bad < (PLAY_VERBOSE or 6) then
      shown_bad = shown_bad + 1
      print(string.format("  MISMATCH %s %d (vblank %d): got %s want %s", kind == "x" and "game frame" or "shown frame", n, FRAME, line, w))
    end
  end
end
local function summary()
  if rec then
    local f = assert(io.open(PLAY_PATH, "w")); f:write(table.concat(lines, "\n"), "\n"); f:close()
    if pad_out then pad_out:close() end
    print(string.format("play: recorded %d game frames, %d shown", nx, nf))
    if nx == 0 then EXIT_CODE = 1 end
  else
    local short = nx < #want.x or nf < #want.f
    print(string.format("play: %d game frames and %d shown frames compared with the original's (%d and %d recorded), %d differ",
      math.min(nx, #want.x), math.min(nf, #want.f), #want.x, #want.f, bad))
    print(string.format("play: %d in-between frames; %d frames of either kind were shown with VRAM unlike the frame buffer", subs, vram_bad))
    if bad > 0 or short or vram_bad > 0 then EXIT_CODE = 1 end
  end
end
local function exit_ev(id)
  if done then return end
  nx = nx + 1
  local h1, h2 = h_exit()
  event("x", string.format("x %d %08X %08X", id, h1, h2))
  if rec and PLAY_MAX and nx >= PLAY_MAX then done = true end
end
if patched then
  emu.addMemoryCallback(function() exit_ev(emu.read(SYM.ex_id_addr, B)) end, emu.callbackType.exec, SYM.blk_back, SYM.blk_back, C, M)
else
  for id, a in ipairs({0x008F14, 0x008E41, 0x008D92}) do
    for _, b in ipairs({0, 0x800000}) do
      emu.addMemoryCallback(function() exit_ev(id - 1) end, emu.callbackType.exec, a | b, a | b, C, M)
    end
  end
end
-- What was sent to VRAM, a piece at a time while the frame was being drawn, must be what the
-- frame buffer holds when the frame is shown.
local VR = emu.memType.snesVideoRam
local function vram_check()
  local mt = own() and B or W
  local df = rd16(0xDF)
  local base = (emu.read(0xDC, W) == 0) and 0x8000 or 0xC000
  local n, first = 0, nil
  for o = 0, df - 1 do
    if emu.read(base + o, VR) ~= emu.read(0x30E5 + o, mt) then n = n + 1; first = first or o end
  end
  -- ($DF is where the upper two tiles of the slot allocated last are; the lower halves of the
  --  slots in that $400 are $200 further on: see send_bot in src/offload.asm)
  if df < 0xC0 then df = 0xC0 end       -- (none allocated in this frame: the gauges' needles have four)
  for _, r in ipairs({ {df, df + 0x3F}, {(df & 0xFC00) + 0x200, df + 0x23F} }) do
    for o = r[1], r[2] do
      if emu.read(base + o, VR) ~= emu.read(0x30E5 + o, mt) then n = n + 1; first = first or o end
    end
  end
  -- ... and whatever that says: every tile of every sprite about to be shown
  local st = (patched and SYM.x_show_addr and own() and emu.read(SYM.x_show_addr, B) ~= 0) and 0xBC00 or 0x2D36
  for i = 0, emu.read(0xC6, W) - 1 do
    local tile = emu.read(st + i * 4 + 2, mt) | ((emu.read(st + i * 4 + 3, mt) & 1) << 8)
    local big = (emu.read(st + 0x200 + (i >> 2), mt) >> ((i & 3) * 2)) & 2
    for _, tn in ipairs(big ~= 0 and { tile, tile + 1, tile + 16, tile + 17 } or { tile }) do
      for o = tn * 32, tn * 32 + 31 do
        if o < 0x4000 and emu.read(base + o, VR) ~= emu.read(0x30E5 + o, mt) then n = n + 1; first = first or o end
      end
    end
  end
  if n > 0 then
    vram_bad = vram_bad + 1
    if vram_shown < 6 then
      vram_shown = vram_shown + 1
      print(string.format("  shown frame %d (vblank %d): %d bytes of VRAM are not the frame buffer's (first at $%04X of $%04X)", nf, FRAME, n, first, df))
    end
  end
end
emu.addMemoryCallback(function()
  if done then return end
  if patched and SYM.x_show_addr and own() and emu.read(SYM.x_show_addr, B) ~= 0 then
    subs = subs + 1; vram_check(); return       -- an in-between frame
  end
  nf = nf + 1
  vram_check()
  event("f", string.format("f %08X %08X %08X", h_flip()))
  -- all compared: end the run here (through on_end, for the other scripts' reports)
  if not rec and nx >= #want.x and nf >= #want.f then done = true; on_end(); emu.stop(EXIT_CODE or 0) end
end, emu.callbackType.exec, 0x0081C5, 0x0081C5, C, M)
local prev_end = on_end
local summed = false
function on_end()
  if prev_end then prev_end() end
  if not summed then summed = true; summary() end
end
end
