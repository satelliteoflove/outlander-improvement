-- Timeline of driving-scene game frames on the patched ROM: when each stage of the main
-- loop starts, and what each NMI uploads.  Needs SYM (tools/symlua.py).  Times are in
-- vblanks since the loop head ($00:8C64, after the wait for the previous frame's flip).
-- TL_FROM = first vblank to log (default 1900), TL_FRAMES = game frames to log (default 12).
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local VB = 357366
local function clk() return emu.getState().masterClock end
local from, want = TL_FROM or 1900, TL_FRAMES or 12
local on, t0, n, cur, sum, cnt = false, nil, 0, nil, {}, 0
local marks = { {"logic", 0x008C64}, {"copy-in", SYM.blk_offload}, {"sa1", SYM.blk_run}, {"copy-out", SYM.blk_back},
                {"rest", SYM.blk_ret}, {"wait", 0x008C54} }
local order = {"logic", "copy-in", "sa1", "copy-out", "rest", "wait"}
local function rd16(a) return emu.read(a, emu.memType.snesMemory) | (emu.read(a + 1, emu.memType.snesMemory) << 8) end
local function flush()
  if not cur then return end
  local s = string.format("frame %3d  total %5.2f |", n, cur.total / VB)
  for _, k in ipairs(order) do
    local d = cur.dur[k] or 0
    s = s .. string.format(" %s %.2f", k, d / VB); sum[k] = (sum[k] or 0) + d
  end
  sum.total = (sum.total or 0) + cur.total; cnt = cnt + 1
  print(s .. " | nmi:" .. table.concat(cur.nmi, " "))
end
local stage, stage_t
local function mark(name)
  return function()
    if not on then return end
    local t = clk()
    if name == "logic" then
      if cur then cur.dur[stage] = (cur.dur[stage] or 0) + (t - stage_t); cur.total = t - t0; flush() end
      if n >= want then
        local s = string.format("mean of %d  total %5.2f |", cnt, sum.total / cnt / VB)
        for _, k in ipairs(order) do s = s .. string.format(" %s %.2f", k, (sum[k] or 0) / cnt / VB) end
        print(s); emu.stop(0); return
      end
      n = n + 1; t0 = t; cur = {dur = {}, nmi = {}}; stage = "logic"; stage_t = t; return
    end
    if not cur or stage == name then return end       -- (the wait loop passes its head many times)
    cur.dur[stage] = (cur.dur[stage] or 0) + (t - stage_t); stage = name; stage_t = t
  end
end
for _, m in ipairs(marks) do emu.addMemoryCallback(mark(m[1]), emu.callbackType.exec, m[2], m[2], C, M) end
-- NMI: time it starts, and how far the upload ($E1) and the renderer ($DF) have got when it ends
local nmi_t
emu.addMemoryCallback(function() if cur then nmi_t = clk() end end, emu.callbackType.exec, 0x008111, 0x008111, C, M)
emu.addMemoryCallback(function()
  if not (cur and nmi_t) then return end
  local t = clk()
  local df = emu.read(SYM.fb_sa1_addr or 0x007002, emu.memType.snesMemory) ~= 0 and rd16(0x3000 + 0xDF) or rd16(0xDF)
  cur.nmi[#cur.nmi + 1] = string.format("[@%.2f %.2fvb up=%04X/%04X%s]", (nmi_t - t0) / VB, (t - nmi_t) / VB, rd16(0xE1), df,
      emu.read(0xC5, emu.memType.snesMemory) ~= 0 and " done" or "")
  nmi_t = nil
end, emu.callbackType.exec, 0x0082C5, 0x0082C5, C, M)
local prev = on_frame
function on_frame(f) if prev then prev(f) end if f >= from then on = true end end
