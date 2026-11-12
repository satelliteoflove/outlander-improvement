-- Where a game frame's time goes with pipelining (src/pipe.asm).  One line per frame shown,
-- times in vblanks since the NMI that showed the frame before:
--   B  when the SA-1 was let past the split point, and how long the second part took
--   A  when it was started on the next frame's first part, and how long that took
--      ("late": only after the frame had been shown, i.e. not early)
--   nmi  for every vblank: bytes of the frame buffer sent / drawn so far, "done" when the
--        block had finished, "car" when the car's tiles were sent, "FLIP", "hud" when the
--        status display's routine ran, and the lines at which the upload was decided and
--        the handler ended
-- Needs SYM.  PL_FROM = first vblank (default 1500), PL_FRAMES = frames to list (default 40),
-- PL_ONLY = n: list only frames that were on show for n vblanks or more; the summary counts all.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local SA, CM = emu.cpuType.sa1, emu.memType.sa1Memory
local B = emu.memType.snesSaveRam
local VB = 357366
local function clk() return emu.getState().masterClock end
local function rd16(a) return emu.read(a, M) | (emu.read(a + 1, M) << 8) end
local from, want = PL_FROM or 1500, PL_FRAMES or 40
local t0, f0, cur, listed, n = nil, nil, nil, 0, 0
local sumA, sumB, cntA, cntB, maxA, maxB, hist = 0, 0, 0, 0, 0, 0, {}
local a_start, b_start, nmi_t, car
local function at(cpu, mt, a, fn) emu.addMemoryCallback(fn, emu.callbackType.exec, a, a, cpu, mt) end
local function rel(t) return (t - t0) / VB end
-- the SA-1 is started (first part)
local function started(early) return function()
  a_start = clk()
  if cur then cur.a = string.format("A %s@%.2f", early and "" or "late ", rel(a_start)) end
end end
at(C, M, SYM.blk_run, started(false))
at(C, M, SYM.te_commit, started(true))
-- the SA-1 reaches the split point
at(SA, CM, SYM.sa1_split, function()
  if not a_start then return end
  local d = clk() - a_start
  sumA = sumA + d; cntA = cntA + 1; if d > maxA then maxA = d end
  if cur and cur.a then cur.a = cur.a .. string.format("+%.2f", d / VB) end
  a_start = nil
end)
-- it is let past (or was never held): the second part starts when both are true
local go_t
at(C, M, SYM.blk_wait, function() go_t = clk() end)
at(SA, CM, SYM.hdma_to_d, function()
  b_start = clk()
  if cur then cur.b = string.format("B @%.2f", rel(b_start)) end
end)
at(C, M, SYM.blk_back, function()
  if not b_start then return end
  local d = clk() - b_start
  sumB = sumB + d; cntB = cntB + 1; if d > maxB then maxB = d end
  if cur and cur.b then cur.b = cur.b .. string.format("+%.2f", d / VB) end
  b_start = nil
end)
at(C, M, 0x8086C2, function() car = true end)
local piece_line, hud_line
at(C, M, 0x008167, function() hud_line = emu.getState()["ppu.scanline"] end)
at(C, M, SYM.nmi_piece, function() piece_line = emu.getState()["ppu.scanline"] end)
at(C, M, 0x008111, function() nmi_t = clk() end)
local flipped = false
at(C, M, 0x0081C5, function() flipped = true end)
at(C, M, 0x0082C5, function()
  if not nmi_t then return end
  if cur then
    local df = emu.read(SYM.fb_sa1_addr + 0x6000, M) ~= 0 and rd16(0x3000 + 0xDF) or rd16(0xDF)
    cur.nmi[#cur.nmi + 1] = string.format("[%04X/%04X%s%s%s%s L%d-%d]", rd16(0xE1), df, emu.read(0xC5, M) ~= 0 and " done" or "",
      car and " car" or "", flipped and " FLIP" or "", hud_line and " hud" or "", piece_line or 0, emu.getState()["ppu.scanline"])
    hud_line = nil
  end
  car = false
  if flipped then
    flipped = false
    if cur and f0 then
      local d = FRAME - f0
      hist[d] = (hist[d] or 0) + 1; n = n + 1
      if listed < want and d >= (PL_ONLY or 0) then
        listed = listed + 1
        print(string.format("vblank %5d  %d vb | %-14s | %-20s | %s", FRAME, d, cur.b or "", cur.a or "", table.concat(cur.nmi, " ")))
      end
    end
    if FRAME >= from then t0 = nmi_t; f0 = FRAME; cur = {nmi = {}} end
  end
  nmi_t = nil
end)
local prev = on_end
function on_end()
  if prev then prev() end
  local keys, t = {}, {}
  for d in pairs(hist) do keys[#keys + 1] = d end
  table.sort(keys)
  for _, d in ipairs(keys) do t[#t + 1] = string.format("%d vblanks: %d", d, hist[d]) end
  print(string.format("%d frames | %s", n, table.concat(t, ", ")))
  if cntA > 0 and cntB > 0 then
    print(string.format("first part: mean %.2f, longest %.2f vblanks; second part: mean %.2f, longest %.2f", sumA / cntA / VB, maxA / VB, sumB / cntB / VB, maxB / VB))
  end
end
