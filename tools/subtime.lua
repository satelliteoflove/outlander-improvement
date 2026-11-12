-- Where the time goes with in-between frames (src/sub.asm): how long the SA-1 spends in each
-- part of a game step and of an in-between frame, and how long each kind of frame stays on
-- show.  Times in vblanks.  Needs SYM.  ST_FROM = first vblank (default 1500);
-- ST_LIST = n: list the first n frames that stayed on show for 3 vblanks or more.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local SA, CM = emu.cpuType.sa1, emu.memType.sa1Memory
local B = emu.memType.snesSaveRam
local VB = 357366
local function clk() return emu.getState().masterClock end
local function at(cpu, mt, a, fn) if a then emu.addMemoryCallback(fn, emu.callbackType.exec, a, a, cpu, mt) end end
local acc, order = {}, {}
local function add(name, d)
  local r = acc[name]
  if not r then r = {n = 0, sum = 0, max = 0}; acc[name] = r; order[#order + 1] = name end
  r.n = r.n + 1; r.sum = r.sum + d; if d > r.max then r.max = d end
end
local on = function() return FRAME >= (ST_FROM or 1500) end
-- ---- the SA-1's parts: a chain of marks, each closing the part before it
local t, part
local function mark(next_part) return function()
  local now = clk()
  if t and part and on() then add(part, now - t) end
  t, part = now, next_part
end end
at(SA, CM, SYM.sa1_sub, mark("sub: save / idle"))
at(SA, CM, SYM.sub_saved, mark("sub: predict"))
at(SA, CM, SYM.sub_predicted, mark("sub: restore"))
at(SA, CM, SYM.sub_restored, mark("sub: move objects, step road"))
at(SA, CM, SYM.sub_doctored, mark("sub: road"))
at(SA, CM, SYM.sub_road, mark(nil))                           -- waits for the flip here
at(SA, CM, SYM.sub_drawn, mark("sub: copy sprites"))
at(SA, CM, SYM.sub_done, mark(nil))
at(SA, CM, SYM.sa1_world_back, mark("state back"))
at(SA, CM, SYM.world_done, mark(nil))
at(SA, CM, 0x208D12, mark("step: first part"))
at(SA, CM, SYM.sa1_split, mark(nil))
at(SA, CM, SYM.sa1_blk_exit, mark(nil))
-- parts that start when the SA-1 is let past a wait
local b_t, b_kind
at(SA, CM, SYM.hdma_to_d, function()
  b_t = clk(); b_kind = emu.read(SYM.sbx_addr, B) ~= 0 and "sub: second part" or "step: second part"
end)
at(SA, CM, SYM.sub_drawn, function() if b_t and on() then add(b_kind, clk() - b_t) end; b_t = nil end)
at(SA, CM, SYM.sa1_blk_exit, function() if b_t and on() then add(b_kind, clk() - b_t) end; b_t = nil end)
-- ---- frames on show, by kind
local last, last_kind, hist, slow = nil, nil, {}, {}
at(C, M, 0x0081C5, function()
  local kind = emu.read(SYM.x_show_addr, B) ~= 0 and ("in-between " .. emu.read(SYM.sub_j_addr, B)) or "game step's"
  -- (sub_j has moved on by the time a frame is shown: count them instead)
  if emu.read(SYM.x_show_addr, B) ~= 0 then
    kind = "in-between " .. ((last_kind and last_kind:match("in%-between (%d)") or 0) + 1)
  end
  if last and on() then
    local d = FRAME - last
    hist[kind] = hist[kind] or {}
    hist[kind][d] = (hist[kind][d] or 0) + 1
    if d >= 3 and #slow < (ST_LIST or 0) then slow[#slow + 1] = string.format("  vblank %d: the %s frame came after %d", FRAME, kind, d) end
  end
  last, last_kind = FRAME, kind
end)
local prev = on_end
function on_end()
  if prev then prev() end
  print("subtime: the SA-1's parts, vblanks (mean / longest / times)")
  table.sort(order)
  for _, k in ipairs(order) do
    local r = acc[k]
    print(string.format("  %-32s %5.2f  %5.2f  %5d", k, r.sum / r.n / VB, r.max / VB, r.n))
  end
  print("subtime: vblanks a frame took to follow the one before, by kind")
  local ks = {}
  for k in pairs(hist) do ks[#ks + 1] = k end
  table.sort(ks)
  for _, k in ipairs(ks) do
    local ds, s = {}, {}
    for d in pairs(hist[k]) do ds[#ds + 1] = d end
    table.sort(ds)
    for _, d in ipairs(ds) do s[#s + 1] = string.format("%d: %d", d, hist[k][d]) end
    print(string.format("  %-16s %s", k, table.concat(s, ", ")))
  end
  if #slow > 0 then print(table.concat(slow, "\n")) end
end
