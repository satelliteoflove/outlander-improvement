-- Checks the SA-1 multiply replacements (src/fastmath.asm) against a model of what the
-- game's own routines compute with the PPU multiplier.  SYM is filled in by the caller:
--   SYM = { fast_d17b=..., fast_d17b_rtl=..., fast_d09c=..., fast_d09c_rtl=... }
local SM, SC = emu.memType.sa1Memory, emu.cpuType.sa1
local DP = 0x0000   -- the SA-1's direct page: page 0 is in I-RAM (src/defs.asm)
local function r8(a) if a < 0x100 then a = a + DP end return emu.read(a, SM) end
local function r16(a) return r8(a) | (r8(a + 1) << 8) end
local function s16(v) if v >= 0x8000 then return v - 0x10000 end return v end
local function s8(v) if v >= 0x80 then return v - 0x100 end return v end
local function reg(name) return emu.getState()["cart.coprocessor.cpu." .. name] end
local stats = {d17b = 0, d09c = 0, bad = 0, neg = 0}
local inp
local function tbl(ptr)   -- 16-bit value at [dp ptr],Y
  local base = r8(ptr) | (r8(ptr + 1) << 8) | (r8(ptr + 2) << 16)
  local y = reg("y")
  return r8(base + y), r8(base + y + 1)
end
emu.addMemoryCallback(function()
  local t0, t1 = tbl(0x3A)
  inp = {v = r16(0x4C), t0 = t0, t1 = t1}
end, emu.callbackType.exec, SYM.fast_d17b, SYM.fast_d17b, SC, SM)
emu.addMemoryCallback(function()
  stats.d17b = stats.d17b + 1
  local v = s16(inp.v)
  local p1 = (v * inp.t0) & 0xFFFFFF
  local p2 = (v * s8(inp.t1)) & 0xFFFFFF
  local x = (((p1 >> 8) + p2) & 0xFFFFFF) >> 4
  local want = {p1 & 0xFF, x & 0xFF, (x >> 8) & 0xFF, x >> 16}
  for i = 0, 3 do
    if r8(0x4E + i) ~= want[i + 1] then
      stats.bad = stats.bad + 1
      if stats.bad < 10 then print(string.format("d17b mismatch v=%04X t=%02X%02X byte $%02X got %02X want %02X", inp.v, inp.t1, inp.t0, 0x4E + i, r8(0x4E + i), want[i + 1])) end
    end
  end
end, emu.callbackType.exec, SYM.fast_d17b_rtl, SYM.fast_d17b_rtl, SC, SM)
local inp2
emu.addMemoryCallback(function()
  local t0, t1 = tbl(0x3D)
  local x = reg("x")
  local db = reg("dbr") or reg("db") or 0x40
  inp2 = {v = (r16((0x40 << 16) | ((0x2596 + x) & 0xFFFF)) - r16(0x4C)) & 0xFFFF, t0 = t0, t1 = t1}
end, emu.callbackType.exec, SYM.fast_d09c, SYM.fast_d09c, SC, SM)
emu.addMemoryCallback(function()
  stats.d09c = stats.d09c + 1
  local v = s16(inp2.v)
  if v < 0 then stats.neg = stats.neg + 1 end
  local p1 = (v * inp2.t0) & 0xFFFFFF
  local w = ((p1 >> 8) + ((v * s8(inp2.t1)) & 0xFFFFFF)) & 0xFFFF
  local q = (s16(inp2.t0 | (inp2.t1 << 8)) * 25) & 0xFFFFFF
  local e = (q >> 4) & 0xFFFF
  local got = {r16(0x50), r16(0x4C), r16(0x4E)}
  local want = {inp2.v, w, e}
  for i = 1, 3 do
    if got[i] ~= want[i] then
      stats.bad = stats.bad + 1
      if stats.bad < 10 then print(string.format("d09c mismatch v=%04X t=%02X%02X item %d got %04X want %04X", inp2.v, inp2.t1, inp2.t0, i, got[i], want[i])) end
    end
  end
end, emu.callbackType.exec, SYM.fast_d09c_rtl, SYM.fast_d09c_rtl, SC, SM)
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  print(string.format("fastmath: %d d17b calls, %d d09c calls (%d with a negative value), %d mismatches", stats.d17b, stats.d09c, stats.neg, stats.bad))
end
