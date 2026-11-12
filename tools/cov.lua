-- Coverage + instruction-count profile.  For every executed S-CPU address: count, and the
-- P, D and data bank registers the first time it ran (what the tools need to decode it).
-- Writes OUT/../cov.txt (override with COV_PATH before this file is appended).
-- Set COV_SA1 = true first to profile the SA-1 instead of the S-CPU.
-- Set COV_WINDOW = {from, to, ...} to count only from executing the first S-CPU address to
-- executing any of the others, interrupt handlers excluded (used to learn what a stretch of
-- code reaches through jump tables).
local cnt, pf = {}, {}
local inside, irq, skip = (COV_WINDOW == nil), 0, false
if COV_WINDOW then
  local C, M = emu.cpuType.snes, emu.memType.snesMemory
  emu.addMemoryCallback(function() inside = true; skip = true end, emu.callbackType.exec, COV_WINDOW[1], COV_WINDOW[1], C, M)
  for i = 2, #COV_WINDOW do
    emu.addMemoryCallback(function() inside = false end, emu.callbackType.exec, COV_WINDOW[i], COV_WINDOW[i], C, M)
  end
  for _, a in ipairs({0x008111, 0x0082CA}) do
    emu.addMemoryCallback(function() irq = irq + 1 end, emu.callbackType.exec, a, a, C, M)
  end
  for _, a in ipairs({0x0082C5, 0x00830B}) do
    emu.addMemoryCallback(function() if irq > 0 then irq = irq - 1 end end, emu.callbackType.exec, a, a, C, M)
  end
end
emu.addMemoryCallback(function(addr)
  if not inside or irq > 0 then return end
  if skip then skip = false; return end      -- the call instruction that opens the window
  local c = cnt[addr]
  if c then cnt[addr] = c + 1
  else
    cnt[addr] = 1
    local st = emu.getState()
    local pre = COV_SA1 and "cart.coprocessor.cpu." or "cpu."
    pf[addr] = st[pre .. "ps"] | (st[pre .. "d"] << 8) | (st[pre .. "dbr"] << 24)
  end
end, emu.callbackType.exec, 0x000000, 0xFFFFFF, COV_SA1 and emu.cpuType.sa1 or emu.cpuType.snes,
   COV_SA1 and emu.memType.sa1Memory or emu.memType.snesMemory)
function on_end()
  local f = assert(io.open(COV_PATH or (OUT .. "/../cov.txt"), "w"))
  for a, c in pairs(cnt) do f:write(string.format("%06X %d %02X %04X %02X\n", a, c, pf[a] & 0xFF, (pf[a] >> 8) & 0xFFFF, pf[a] >> 24)) end
  f:close()
end
