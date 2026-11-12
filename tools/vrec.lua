-- Records a playthrough in Mesen's window, for tools/video.py to replay on both ROMs.
-- Loaded by "tools/video.py play", which puts SYM, VREC = {state = path, out = path} and
-- tools/vstep.lua in front.  The game is put at the title screen (a savestate made by the
-- same build), and from there the take file gets, by vblank counted from that state:
--   p N buttons   the pad changed ("-" = nothing held)
--   s N word      the game sampled the pad for a step of the driving scene
--   x N hash      a step of the driving scene is done (vstep.lua)
--   t N           (now and then) the take has got this far
-- It is written as the game runs, so closing Mesen ends the take.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local out = assert(io.open(VREC.out, "w"))
out:write("take 1\n")
local loaded, n, last, steps, first = false, 0, nil, 0, nil
-- (savestates can only be loaded from an exec callback: the NMI handler's first instruction)
emu.addMemoryCallback(function()
  if loaded then return end
  local f = assert(io.open(VREC.state, "rb")); local d = f:read("a"); f:close()
  emu.loadSavestate(d); loaded = true; VREC.loaded = true
end, emu.callbackType.exec, 0x008111, 0x008111, C, M)
emu.addEventCallback(function()
  if not loaded then return end
  n = n + 1; VREC.n = n
  local t = emu.getInput(0)
  local names = {}
  for _, b in ipairs(VSTEP_ORDER) do if t[b] then names[#names + 1] = b end end
  local s = #names > 0 and table.concat(names, " ") or "-"
  if s ~= last then out:write("p ", n, " ", s, "\n"); last = s end
end, emu.eventType.inputPolled)
vstep_watch(function(h)
  steps = steps + 1; first = first or n
  out:write(string.format("x %d %08X\n", n, h))
end, function(v) out:write(string.format("s %d %04X\n", n, v)) end)
emu.addEventCallback(function()
  if not loaded then return end
  if n > 0 and n % 30 == 0 then out:write("t ", n, "\n"); out:flush() end
  local msg = first and string.format("REC  %d s of driving", (n - first) // 60)
              or "REC  press Start and drive; close Mesen when done"
  pcall(emu.drawString, 6, 212, msg, 0xFFFFFF, 0x60000000)
end, emu.eventType.endFrame)
