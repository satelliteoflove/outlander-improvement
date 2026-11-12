-- Which objects do the in-between frames (src/sub.asm) draw unlike their game step, and
-- does their logic end where the step's did?  Needs SYM.
--
-- 1. Per frame and per object the object pass handles ($80:9DD6), what the SA-1 wrote of
--    the frame buffer and of the sprite table while it had that object in hand; and the
--    same for what is drawn before the pass (from $00:8EBA: scenery, the gun at the side
--    window).  Written to OUT/subobj.txt for tools/subobj.py, which compares a step's
--    lists with its in-between frames'.  On a SUBMOVE=0 build (in-between frames that
--    move nothing) the two must be the same; on any build the same objects must be there.
--      F vblank STEP|sub<j>
--      O slot type  fb-bytes fb-hash  sprite-bytes sprite-hash(x and y only)  record(12 bytes)
--    (slot "pre" = before the pass; hashes are of the values in the order written: tile
--     numbers depend on the order the objects are drawn in)
-- 2. Any build: an in-between frame's pass must leave every object where its step's pass
--    left it (distance, kind and place across the road of each record).  Its logic is the
--    step's over again, and what it moves for the drawing it puts back (sbx_shift,
--    sbx_next).  Not compared: the rest of the objects' memory, where the drawing keeps
--    notes of its own (a flag in each record, tables behind them) that go by where things
--    were drawn.  Fails the run (EXIT_CODE) if one does not.
local S, SM = emu.cpuType.sa1, emu.memType.sa1Memory
local B, IR = emu.memType.snesSaveRam, emu.memType.sa1InternalRam
local f = assert(io.open(OUT .. "/subobj.txt", "w"))
local P = 4294967291
local cur, kind = nil, nil
local function flush()
  if cur then f:write(string.format("O %s %02X %d %08X %d %08X %s\n", cur.slot, cur.ty, cur.nfb, cur.hfb, cur.nst, cur.hst, cur.rec)); cur = nil end
end
local function begin(slot, ty, rec) flush(); cur = { slot = slot, ty = ty, rec = rec, nfb = 0, hfb = 0, nst = 0, hst = 0 } end
local function frame_start(k)
  flush()
  kind = k
  f:write(string.format("F %d %s\n", FRAME, k))
  begin("pre", 0, "-")
end
-- (a step: behind the split point's hook, src/pipe.asm, which draws the gauges' needles)
emu.addMemoryCallback(function() frame_start("STEP") end, emu.callbackType.exec, 0x208EBE, 0x208EBE, S, SM)
emu.addMemoryCallback(function() frame_start("sub" .. emu.read(SYM.sub_j_addr, B)) end,
  emu.callbackType.exec, SYM.sub_second, SYM.sub_second, S, SM)
emu.addMemoryCallback(function()
  local x = emu.read(0xA7, IR) | (emu.read(0xA8, IR) << 8)
  local t = {}
  for i = 0, 11 do t[#t + 1] = string.format("%02X", emu.read(0x7121 + x + i, B)) end
  begin(string.format("%03X", x), emu.read(0x7123 + x, B), table.concat(t))
end, emu.callbackType.exec, 0x209E91, 0x209E91, S, SM)
emu.addMemoryCallback(function(a, v)
  if cur then cur.nfb = cur.nfb + 1; cur.hfb = (cur.hfb * 31 + (v & 0xFF)) % P end
end, emu.callbackType.write, 0x4030E5, 0x4070E4, S, SM)
emu.addMemoryCallback(function(a, v)
  if cur then
    cur.nst = cur.nst + 1
    if a < 0x402F36 and ((a - 0x402D36) & 3) < 2 then cur.hst = (cur.hst * 31 + (v & 0xFF)) % P end
  end
end, emu.callbackType.write, 0x402D36, 0x402F55, S, SM)
-- ---- the end of the pass
local step_tab, tab_bad, tab_n, tab_shown = nil, 0, 0, 0
local function tab()
  local t = {}
  for r = 0x7121, 0x7121 + 0x2A0 - 12, 12 do
    for _, o in ipairs({0, 1, 2, 4, 5}) do t[#t + 1] = emu.read(r + o, B) end
  end
  return t
end
emu.addMemoryCallback(function()
  flush()
  if kind == "STEP" then step_tab = tab(); return end
  if not step_tab or not kind then return end
  tab_n = tab_n + 1
  local m, n, first = tab(), 0, nil
  for i = 1, #m do if m[i] ~= step_tab[i] then n = n + 1; first = first or ((i - 1) // 5) * 12 end end
  if n > 0 then
    tab_bad = tab_bad + 1
    if tab_shown < (SO_VERBOSE or 12) then
      tab_shown = tab_shown + 1
      print(string.format("  %s at vblank %d leaves %d bytes of the object table unlike its step (first in record $%03X)", kind, FRAME, n, first))
    end
  end
end, emu.callbackType.exec, 0x209F28, 0x209F28, S, SM)
local prev = on_end
function on_end()
  if prev then prev() end
  flush(); f:close()
  print(string.format("subobj: %d in-between frames, %d left an object elsewhere than their step's pass did", tab_n, tab_bad))
  if tab_bad > 0 then EXIT_CODE = 1 end
end
