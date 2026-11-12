-- Record what the driving block ($00:8D12 up to $00:8F14, $00:8E41 or $00:8D92) reads and produces on
-- the ORIGINAL game: RAM and registers at its entry and at its exit, for every GOLD_EVERY-th
-- pass from vblank GOLD_FROM on, at most GOLD_MAX of them.  Writes GOLD_PATH.
-- Record layout (little endian), 20 + 4 * ... bytes:
--   u32 vblank; u16 A, X, Y; u8 P; u8 exit (0 = $8F14, 1 = $8E41, 2 = $8D92); u16 A, X, Y; u8 P; u8 DB
--   low RAM $0000-$07FF at entry, $7E:2000-$7FFF at entry, the same two at exit
-- Replayed against a patched ROM by tools/golden_chk.lua (see tools/golden.py).
local C, M, W = emu.cpuType.snes, emu.memType.snesMemory, emu.memType.snesWorkRam
local every, max, from = GOLD_EVERY or 5, GOLD_MAX or 200, GOLD_FROM or 0
local f = assert(io.open(GOLD_PATH, "wb"))
local pass, taken, cur = 0, 0, nil
local function grab(lo, hi)
  local t, n = {}, 0
  for a = lo, hi do n = n + 1; t[n] = emu.read(a, W) end
  local parts = {}
  for i = 1, n, 4096 do parts[#parts + 1] = string.char(table.unpack(t, i, math.min(i + 4095, n))) end
  return table.concat(parts)
end
emu.addMemoryCallback(function()
  pass = pass + 1
  if FRAME < from or taken >= max or pass % every ~= 0 then return end
  local s = emu.getState()
  cur = { hdr = string.pack("<I4I2I2I2B", FRAME, s["cpu.a"], s["cpu.x"], s["cpu.y"], s["cpu.ps"]),
          lo = grab(0x0000, 0x07FF), hi = grab(0x2000, 0x7FFF) }
end, emu.callbackType.exec, 0x008D12, 0x008D12, C, M)
local function exit_cb(id)
  return function()
    if not cur then return end
    local s = emu.getState()
    f:write(cur.hdr, string.pack("<BI2I2I2BB", id, s["cpu.a"], s["cpu.x"], s["cpu.y"], s["cpu.ps"], s["cpu.dbr"]),
            cur.lo, cur.hi, grab(0x0000, 0x07FF), grab(0x2000, 0x7FFF))
    cur = nil; taken = taken + 1
  end
end
for id, a in ipairs({0x008F14, 0x008E41, 0x008D92}) do
  emu.addMemoryCallback(exit_cb(id - 1), emu.callbackType.exec, a, a, C, M)
end
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  f:close(); print(string.format("recorded %d of %d passes -> %s", taken, pass, GOLD_PATH))
end
