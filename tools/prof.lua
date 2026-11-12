-- Time profile, per executed address, of what the SA-1 does while it runs the driving block
-- (or of the S-CPU: set PROF_CPU = "snes" and PROF_WINDOW = {from, to} first).
-- Time is master clocks between one instruction starting and the next, so it includes
-- whatever held the CPU up meanwhile.  Slow (reads the emulator state on every instruction,
-- roughly 25 s per game frame), so it profiles PROF_BLOCKS passes starting at vblank
-- PROF_FROM and then ends the run.  Writes PROF_PATH (default OUT/../prof.txt):
--   address count clocks P       one line per address
-- Report with tools/prof.py.
local sa1 = (PROF_CPU or "sa1") == "sa1"
local C = sa1 and emu.cpuType.sa1 or emu.cpuType.snes
local M = sa1 and emu.memType.sa1Memory or emu.memType.snesMemory
local pre = sa1 and "cart.coprocessor.cpu." or "cpu."
local W = PROF_WINDOW or {0x208D12, SYM and SYM.sa1_blk_exit or 0}
local cnt, clk, pf = {}, {}, {}
local armed, inside, last, last_t, blocks, total = false, false, nil, 0, 0, 0
local want = PROF_BLOCKS or 4
local irq_t, irq_in, irq_t0 = 0, false, 0
local function finish()
  local f = assert(io.open(PROF_PATH or (OUT .. "/../prof.txt"), "w"))
  f:write(string.format("# blocks %d clocks %d scpu_irq_clocks %d\n", blocks, total, irq_t))
  for a, c in pairs(cnt) do f:write(string.format("%06X %d %d %02X\n", a, c, clk[a], pf[a])) end
  f:close()
  print(string.format("profiled %d passes: %.3f vblanks each (%.3f of it while the S-CPU was in an interrupt handler)",
        blocks, total / blocks / 357366, irq_t / blocks / 357366))
end
emu.addMemoryCallback(function(pc)
  if not inside then
    if not (armed and pc == W[1]) then return end
    inside = true; last = nil
  end
  local st = emu.getState()
  local t = st.masterClock
  if last then clk[last] = clk[last] + (t - last_t); total = total + (t - last_t) end
  if pc == W[2] then
    inside = false; blocks = blocks + 1
    if blocks >= want then finish(); emu.stop(0) end
    return
  end
  local c = cnt[pc]
  if c then cnt[pc] = c + 1 else cnt[pc] = 1; clk[pc] = 0; pf[pc] = st[pre .. "ps"] end
  last, last_t = pc, t
end, emu.callbackType.exec, 0x000000, 0xFFFFFF, C, M)
if sa1 then
  -- how much of that time the S-CPU spent in its NMI/IRQ handlers (the SA-1 is held up
  -- whenever both run from ROM)
  local SC, SM = emu.cpuType.snes, emu.memType.snesMemory
  for _, a in ipairs({0x008111, 0x0082CA}) do
    emu.addMemoryCallback(function() if inside and not irq_in then irq_in = true; irq_t0 = emu.getState().masterClock end end,
      emu.callbackType.exec, a, a, SC, SM)
  end
  for _, a in ipairs({0x0082C5, 0x00830B}) do
    emu.addMemoryCallback(function() if irq_in then irq_in = false; irq_t = irq_t + emu.getState().masterClock - irq_t0 end end,
      emu.callbackType.exec, a, a, SC, SM)
  end
end
local prev = on_frame
function on_frame(n) if prev then prev(n) end if n >= (PROF_FROM or 0) then armed = true end end
