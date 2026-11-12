-- Time spans between two executed addresses, in vblanks (357366 master clocks).
-- Define SPANS before this file is appended:  SPANS = { {"name", startAddr, endAddr, "snes"|"sa1"}, ... }
local res = {}
local function clk() return emu.getState()["masterClock"] end
for _, s in ipairs(SPANS) do
  local r = {name = s[1], tot = 0, n = 0, max = 0}
  res[#res + 1] = r
  local cpu = (s[4] == "sa1") and emu.cpuType.sa1 or emu.cpuType.snes
  local mt = (s[4] == "sa1") and emu.memType.sa1Memory or emu.memType.snesMemory
  emu.addMemoryCallback(function() r.t0 = clk() end, emu.callbackType.exec, s[2], s[2], cpu, mt)
  emu.addMemoryCallback(function()
    if r.t0 then local d = clk() - r.t0; r.tot = r.tot + d; r.n = r.n + 1; if d > r.max then r.max = d end; r.t0 = nil end
  end, emu.callbackType.exec, s[3], s[3], cpu, mt)
end
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  for _, r in ipairs(res) do
    print(string.format("%-22s n=%5d  mean %6.3f  max %6.3f vblanks", r.name, r.n, r.n > 0 and r.tot / r.n / 357366 or 0, r.max / 357366))
  end
end
