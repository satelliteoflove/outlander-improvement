-- Replays a take (tools/vrec.lua) under tools/run.py and captures what the comparison video
-- is made from (tools/video.py render).  Needs tools/vstep.lua in front, SYM on the patched
-- ROM, and
--   VC = { mode   = "vblank": the pad as recorded, vblank by vblank (the ROM it was played on)
--                   "sample": by vblank until the driving scene's first sample, then the
--                             recorded samples one by one, as tools/play.lua does: the two
--                             ROMs reach a given step at different times
--          pads    = { [n] = "y left", ... }   the pad from vblank n on (n as in the take)
--          samples = { "y", "y left", ... }    what the game's k-th sample found
--          base    = vblanks of this run before the take's first (the original runs from
--                    power-on; the patched ROM starts from the take's savestate)
--          from    = first frame to capture (run.py's FRAME)
--          s_idle, a_idle = lists of addresses: the wait loops of the S-CPU and the SA-1 }
-- Written to OUT: v%06d.png (every frame), audio.wav (if $MESEN_WAV is set: tools/wavrec.c),
--   stats.txt   FRAME vblank-of-the-take s_busy sa1_busy flips steps
--               (busy: share of the frame's master clocks not spent in a wait loop; -1 = no SA-1)
--   steps.txt   the take's s and x lines as this run produced them
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local patched = VSTEP_PATCHED
local function parse(s)
  local t = {}
  for _, b in ipairs(VSTEP_ORDER) do t[b] = false end
  for b in (s or ""):gmatch("%a+") do t[b] = true end
  return t
end
-- ---- the pad
local polls, cur, samp_pad, k = 0, parse(""), nil, 0
function input_hook()
  polls = polls + 1
  if samp_pad then return samp_pad end
  local s = VC.pads[polls - VC.base]
  if s then cur = parse(s) end
  return cur
end
local steps_f = assert(io.open(OUT .. "/steps.txt", "w"))
local steps = 0
vstep_watch(function(h)
  steps = steps + 1
  steps_f:write(string.format("x %d %08X\n", polls - VC.base, h))
end, function(v)
  k = k + 1
  steps_f:write(string.format("s %d %04X\n", polls - VC.base, v))
  if VC.mode == "sample" then samp_pad = parse(VC.samples[k + 1] or VC.samples[#VC.samples]) end
end)
-- ---- how busy the CPUs are
local function clock() return emu.getState()["masterClock"] end
local function meter(list, lo, hi, cpu, mem)
  local idle = {}
  for _, a in ipairs(list) do idle[a] = true end
  local m = { busy = 0, st = false, t = clock() }
  emu.addMemoryCallback(function(a)
    local i = (idle[a] or (lo ~= nil and a >= lo and a <= hi)) and true or false
    if i ~= m.st then
      local now = clock()
      if not m.st then m.busy = m.busy + (now - m.t) end
      m.t = now; m.st = i
    end
  end, emu.callbackType.exec, 0x000000, 0xFFFFFF, cpu, mem)
  function m.take(now)
    if not m.st then m.busy = m.busy + (now - m.t) end
    m.t = now
    local b = m.busy; m.busy = 0
    return b
  end
  return m
end
-- (the patch's S-CPU waits in work RAM, $7E:1F00, so as not to hold the SA-1 up)
local ms = meter(VC.s_idle, patched and 0x7E1F00 or nil, 0x7E1FFF, C, M)
local ma = patched and meter(VC.a_idle, nil, nil, emu.cpuType.sa1, emu.memType.sa1Memory) or nil
local flips = 0
emu.addMemoryCallback(function() flips = flips + 1 end, emu.callbackType.exec, 0x0081C5, 0x0081C5, C, M)
-- ---- per frame
local stats = assert(io.open(OUT .. "/stats.txt", "w"))
local WAV = os.getenv("MESEN_WAV")
local function signal(what)
  local p = WAV .. "." .. what
  io.open(p, "w"):close()
  local t0 = os.clock()
  while true do
    local f = io.open(p, "r")
    if not f then return end
    f:close()
    if os.clock() - t0 > 10 then print("vcap: the sound recorder does not answer (" .. what .. ")"); EXIT_CODE = 1; return end
  end
end
local t_prev, rec = clock(), false
function on_frame(n)
  local now = clock()
  local len = now - t_prev; t_prev = now
  stats:write(string.format("%d %d %.4f %.4f %d %d\n", n, polls - VC.base, ms.take(now) / len,
    ma and ma.take(now) / len or -1, flips, steps))
  flips = 0
  if n >= VC.from then
    local f = assert(io.open(string.format("%s/v%06d.png", OUT, n), "wb")); f:write(emu.takeScreenshot()); f:close()
  end
  -- (the sound of the frames from VC.from on: their pictures are taken at their ends)
  if WAV and not rec and n >= VC.from - 1 then rec = true; signal("start") end
end
function on_end()
  if rec then signal("stop") end
  stats:close(); steps_f:close()
  print(string.format("vcap: %d frames, %d steps, %d samples", FRAME, steps, k))
end
