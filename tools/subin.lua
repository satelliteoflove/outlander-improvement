-- What does an in-between frame's second part (src/sub.asm: from $00:8EBA to the end of the
-- object pass) find that its game step's did not?  For a SUBMOVE=0 build, where the two
-- should be the same run.  Per frame, the value of every byte of the game's memory at its
-- first use, if that was a read; a step's are compared with its first in-between frame's.
-- Needs SYM.  Prints every byte found unlike, with how often and where first.
local S, SM = emu.cpuType.sa1, emu.memType.sa1Memory
local B, IR = emu.memType.snesSaveRam, emu.memType.sa1InternalRam
local on, seen, first = false, {}, {}
local step_first, kind = nil, nil
local tally, where, steps = {}, {}, 0
local function rd(base) return function(a, v)
  if not on then return end
  a = a + base
  if not seen[a] then seen[a] = true; first[a] = v & 0xFF end
end end
local function wr(base) return function(a)
  if on then seen[a + base] = true end
end end
-- (by the memory itself, wherever the SA-1 has it mapped; BW-RAM is numbered from $10000)
emu.addMemoryCallback(rd(0), emu.callbackType.read, 0x0000, 0x00FF, S, IR)
emu.addMemoryCallback(wr(0), emu.callbackType.write, 0x0000, 0x00FF, S, IR)
for _, r in ipairs({ {0x0100, 0x07FF}, {0x2000, 0x30E4}, {0x70E5, 0x78BC} }) do
  emu.addMemoryCallback(rd(0x10000), emu.callbackType.read, r[1], r[2], S, B)
  emu.addMemoryCallback(wr(0x10000), emu.callbackType.write, r[1], r[2], S, B)
end
local function start(k) on, seen, first, kind = true, {}, {}, k end
emu.addMemoryCallback(function() start("STEP") end, emu.callbackType.exec, 0x208EBE, 0x208EBE, S, SM)
emu.addMemoryCallback(function()
  if emu.read(SYM.sub_j_addr, B) == 1 then start("sub") end
end, emu.callbackType.exec, SYM.sub_second, SYM.sub_second, S, SM)
emu.addMemoryCallback(function()
  if not on then return end
  on = false
  if kind == "STEP" then step_first = first; steps = steps + 1; return end
  if not step_first then return end
  for a, v in pairs(first) do
    local w = step_first[a]
    if w ~= nil and w ~= v then
      tally[a] = (tally[a] or 0) + 1
      where[a] = where[a] or string.format("vblank %d: step %02X, in between %02X", FRAME, w, v)
    end
  end
end, emu.callbackType.exec, 0x209F28, 0x209F28, S, SM)
local prev = on_end
function on_end()
  if prev then prev() end
  local t = {}
  for a in pairs(tally) do t[#t + 1] = a end
  table.sort(t)
  print(string.format("subin: %d game steps; bytes an in-between frame's second part found unlike its step's:", steps))
  for _, a in ipairs(t) do
    print(string.format("  %s$%04X  %4d times  (first at %s)", a >= 0x10000 and "$40:" or "page 0 ", a & 0xFFFF, tally[a], where[a]))
  end
end
