-- How late the S-CPU's interrupt handlers start, in master clocks after the timer or
-- vblank that raised them.  The driving scene splits the screen with five timed IRQs a
-- frame whose handlers wait for the next horizontal blank and then write PPU registers:
-- an IRQ that starts a few hundred clocks late changes mode a line late, and one that
-- starts many lines late garbles the picture below it.  Anything that stops the S-CPU for
-- long (a DMA transfer above all) shows up here.
-- LAT_FROM = first vblank counted (default 1320).  Prints the worst and a histogram; with
-- LAT_MAX_IRQ / LAT_MAX_NMI set, ends the run with status 1 if the worst is above them.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local from = LAT_FROM or 1320
local function new() return {n = 0, max = 0, at = 0, h = {0, 0, 0, 0, 0}} end
local irq, nmi = new(), new()
local function add(r, d)
  r.n = r.n + 1
  if d > r.max then r.max = d; r.at = FRAME end
  local b = (d < 100 and 1) or (d < 200 and 2) or (d < 400 and 3) or (d < 1364 and 4) or 5
  r.h[b] = r.h[b] + 1
end
emu.addMemoryCallback(function()
  if FRAME < from then return end
  local s = emu.getState()
  local d = (s["ppu.scanline"] - s["internalRegisters.verticalTimer"]) * 1364 + s["memoryManager.hClock"]
  if s["internalRegisters.enableHorizontalIrq"] then d = d - 4 * s["internalRegisters.horizontalTimer"] end
  if d < 0 then d = d + 262 * 1364 end
  add(irq, d)
end, emu.callbackType.exec, 0x0082CA, 0x0082CA, C, M)
emu.addMemoryCallback(function()
  if FRAME < from then return end
  local s = emu.getState()
  local d = (s["ppu.scanline"] - 225) * 1364 + s["memoryManager.hClock"]
  if d < 0 then d = d + 262 * 1364 end
  add(nmi, d)
end, emu.callbackType.exec, 0x008111, 0x008111, C, M)
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  local bad = false
  for _, t in ipairs({{"IRQ", irq, LAT_MAX_IRQ}, {"NMI", nmi, LAT_MAX_NMI}}) do
    local r = t[2]
    print(string.format("%s latency: worst %d clocks (vblank %d); of %d: <100: %d  <200: %d  <400: %d  <1 line: %d  more: %d",
          t[1], r.max, r.at, r.n, r.h[1], r.h[2], r.h[3], r.h[4], r.h[5]))
    if t[3] and r.max > t[3] then bad = true; print(string.format("  LATENCY above the limit of %d", t[3])) end
  end
  if bad then EXIT_CODE = 1 end
end
