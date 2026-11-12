-- Video memory can only be written while the picture is not being drawn: in vertical blank
-- (lines 225-261) or with the screen switched off.  A write at any other time is lost or
-- lands in the wrong place on real hardware, which no RAM comparison shows.  This reports
-- every write to VRAM, OAM or CGRAM ($2104, $2118/9, $2122; by the CPU or by DMA) outside
-- those times, and how close each vblank's last write comes to the end (line 262 = 0).
-- VB_FAIL = true fails the run on a late write; VB_MARGIN = lines that must be left (default 0).
-- VB_ALLOW = {[pc] = true}: late writes the original game makes too, which are reported but
-- do not fail the run.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local LINE = 1364
local blank = true                    -- screen off ($2100 bit 7); the game starts that way
local late, nlate, worst, worst_at, hist = {}, 0, 0, 0, {}
emu.addMemoryCallback(function(addr, value) blank = (value & 0x80) ~= 0 end, emu.callbackType.write, 0x002100, 0x002100, C, M)
local function check(what, bytes)
  if blank then return end
  local s = emu.getState()
  local line, h = s["ppu.scanline"], s["memoryManager.hClock"] or 0
  local pos = (line >= 225 and (line - 225) or (line + 37)) * LINE + h + bytes * 8    -- clocks into vblank, at the end
  if line >= 225 and pos <= 37 * LINE then
    if pos > worst then worst = pos; worst_at = FRAME end
    return
  end
  if line >= 225 then line = (line + (h + bytes * 8) // LINE) - 262 end      -- a transfer that runs past the end
  local pc = (s["cpu.k"] << 16) | s["cpu.pc"]
  local k = string.format("%s by %06X", what, pc)
  if VB_ALLOW and VB_ALLOW[pc] then k = k .. " (as on the original)" else nlate = nlate + 1 end
  local r = late[k]
  if not r then r = {n = 0, first = FRAME, lo = line, hi = line}; late[k] = r end
  r.n = r.n + 1
  if line < r.lo then r.lo = line end
  if line > r.hi then r.hi = line end
end
-- A DMA transfer stops the CPU, and its bytes arrive 8 clocks apart: looked at once, when
-- it is started, and its writes are then skipped (asking the emulator where the beam is for
-- every byte would take hours).
local NAME = {[0x04] = "OAM", [0x18] = "VRAM", [0x19] = "VRAM", [0x22] = "CGRAM"}
local dma_left = 0
emu.addMemoryCallback(function(addr, value)
  for ch = 0, 7 do
    if value & (1 << ch) ~= 0 then
      local b = 0x4300 + ch * 16
      local reg = emu.read(b + 1, M)
      if NAME[reg] and emu.read(b, M) & 0x80 == 0 then
        local size = emu.read(b + 5, M) | (emu.read(b + 6, M) << 8)
        if size == 0 then size = 0x10000 end
        dma_left = dma_left + size
        check(NAME[reg] .. " DMA", size)
      end
    end
  end
end, emu.callbackType.write, 0x00420B, 0x00420B, C, M)
local function cpu_write(what)
  return function()
    if dma_left > 0 then dma_left = dma_left - 1; return end
    check(what .. " write", 0)
  end
end
emu.addMemoryCallback(cpu_write("OAM"), emu.callbackType.write, 0x002104, 0x002104, C, M)
emu.addMemoryCallback(cpu_write("VRAM"), emu.callbackType.write, 0x002118, 0x002119, C, M)
emu.addMemoryCallback(cpu_write("CGRAM"), emu.callbackType.write, 0x002122, 0x002122, C, M)
local prev = on_end
function on_end()
  if prev then prev() end
  local left = (37 * LINE - worst) / LINE
  print(string.format("video memory: the latest write in a vblank came %.1f lines before its end (vblank %d)", left, worst_at))
  local t = {}
  for k, r in pairs(late) do t[#t + 1] = string.format("  %s  lines %d-%d  x%d  (first at vblank %d)", k, r.lo, r.hi, r.n, r.first) end
  table.sort(t)
  if #t > 0 then print("video memory written while the picture was being drawn:"); print(table.concat(t, "\n")) end
  if VB_FAIL and (nlate > 0 or left < (VB_MARGIN or 0)) then EXIT_CODE = 1 end
end
