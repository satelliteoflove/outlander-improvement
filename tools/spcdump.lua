-- Saves the sound CPU's state as an .spc file (SPC_OUT, default OUT/dump.spc) at vblank SPC_AT,
-- for tools/vreel.py: played back by libgme (ffmpeg's or through ctypes) it goes on with
-- whatever the game's sound driver was doing, with no new commands from the game, so a song
-- plays on without the sound effects that would have come later.  The I/O registers
-- ($F0-$FF), which RAM does not hold, are rebuilt from Mesen's state.
local AT = SPC_AT or 1190
local pf = on_frame
function on_frame(n)
  if pf then pf(n) end
  if n ~= AT then return end
  local s = emu.getState()
  local f = assert(io.open(SPC_OUT or (OUT .. "/dump.spc"), "wb"))
  local h = "SNES-SPC700 Sound File Data v0.30" .. string.char(26, 26, 27, 30)     -- (27: no ID666 tag)
  h = h .. string.char(s["spc.pc"] & 0xFF, s["spc.pc"] >> 8, s["spc.a"], s["spc.x"], s["spc.y"], s["spc.ps"], s["spc.sp"], 0, 0)
  f:write(h .. string.rep("\0", 0x100 - #h))
  local ram = {}
  for a = 0, 0xFFFF do ram[a + 1] = emu.read(a, emu.memType.spcRam) end
  for a = 0xF0, 0xFF do ram[a + 1] = 0 end
  local function tm(i) return s["spc.timer" .. i .. ".enabled"] and (1 << i) or 0 end
  ram[0xF1 + 1] = tm(0) | tm(1) | tm(2) | (s["spc.romEnabled"] and 0x80 or 0)
  for i = 0, 2 do
    ram[0xFA + i + 1] = s["spc.timer" .. i .. ".target"] & 0xFF
    ram[0xFD + i + 1] = s["spc.timer" .. i .. ".output"] & 0x0F
  end
  for i = 0, 3 do ram[0xF4 + i + 1] = s["spc.cpuRegs[" .. i .. "]"] end
  ram[0xF8 + 1], ram[0xF9 + 1] = s["spc.ramReg[0]"], s["spc.ramReg[1]"]
  ram[0xF2 + 1] = s["spc.dspReg"] or 0
  local parts = {}
  for i = 1, 0x10000, 4096 do parts[#parts + 1] = string.char(table.unpack(ram, i, i + 4095)) end
  f:write(table.concat(parts))
  local d = {}
  for a = 0, 127 do d[a + 1] = emu.read(a, emu.memType.spcDspRegisters) end
  f:write(string.char(table.unpack(d)), string.rep("\0", 64), string.char(table.unpack(ram, 0xFFC1, 0x10000)))
  f:close()
  print("spcdump: " .. (SPC_OUT or (OUT .. "/dump.spc")))
end
