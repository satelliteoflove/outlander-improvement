-- In-between frames (src/sub.asm) against the game step's frame they follow, for a build
-- made to draw them without moving anything (tools/build.py SUBMOVE=0).  Compared: frame
-- buffer, sprite table, HDMA tables, display values.
--   * The three in-between frames of a step must be the same as each other: each is drawn
--     from the same state.  A difference means that drawing one changed something that is
--     not put back before the next (SC_FAIL = true fails the run on it).
--   * Each should also be the step's own frame over again.  It is, wherever the drawing
--     code only draws; where it also animates (a thrown object's flight is worked out as
--     it is drawn, $80:AC0B) the in-between frames show the next stage, the one the next
--     step will show.  Those are counted and listed, not failed: on the first drive, where
--     nothing of the kind is on screen, there are none.
-- Needs SYM.  SC_VERBOSE = differing frames listed (8).
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local W, B = emu.memType.snesWorkRam, emu.memType.snesSaveRam
local function rd16(a) return emu.read(a, W) | (emu.read(a + 1, W) << 8) end
local ENDS = { {0x1100, 0x13CA}, {0x13CB, 0x1416}, {0x1420, 0x16EA}, {0x16EB, 0x1736} }
local function tab(p)
  for _, r in ipairs(ENDS) do
    if p >= r[1] and p <= r[2] then
      local t = {}
      for a = p, r[2] do t[#t + 1] = emu.read(a, B) end
      return t
    end
  end
  return {}
end
local LOW = {0x5C, 0x5D, 0x60, 0x61, 0x62, 0x63, 0x66, 0x67, 0xC6, 0xDD, 0xDF, 0xE0, 0xE3, 0x019F, 0x01B0}
local ST_D = 0xBC00      -- !ST_D in src/defs.asm: an in-between frame's sprite table
local function snap(sub)
  local s = { df = rd16(0xDF), fb = {}, st = {}, low = {} }
  for o = 0, s.df - 1 do s.fb[o + 1] = emu.read(0x30E5 + o, B) end
  local st = sub and ST_D or 0x2D36
  local n = emu.read(0xC6, W)                 -- sprites in use: the rest is never sent
  for i = 0, 4 * n - 1 do s.st[#s.st + 1] = emu.read(st + i, B) end
  for i = 0, (n - 1) // 4 do s.st[#s.st + 1] = emu.read(st + 0x200 + i, B) end
  s.t1, s.t2 = tab(rd16(0x2F)), tab(rd16(0x32))
  for i, a in ipairs(LOW) do s.low[i] = emu.read(a, W) end
  return s
end
local function diff(a, b)
  local n, first = 0, nil
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then n = n + 1; first = first or (i - 1) end
  end
  return n, first
end
local step, first, steps, subs, bad, shown, uneven = nil, nil, 0, 0, 0, 0, 0
local kinds = {}
emu.addMemoryCallback(function()
  if emu.read(SYM.own_addr, B) == 0 then step = nil; return end
  if emu.read(SYM.x_show_addr, B) == 0 then step = snap(); first = nil; steps = steps + 1; return end
  if not step then return end
  subs = subs + 1
  local s = snap(true)
  if not first then first = s
  else
    for _, k in ipairs({"fb", "st", "t1", "t2", "low"}) do
      local n, at = diff(s[k], first[k])
      if n > 0 then
        uneven = uneven + 1
        if uneven <= 8 then print(string.format("  in-between frames after step %d (vblank %d) differ from each other: %s %d (first +$%X)", steps, FRAME, k, n, at)) end
        break
      end
    end
  end
  local parts = {}
  for _, k in ipairs({"fb", "st", "t1", "t2", "low"}) do
    local n, first = diff(s[k], step[k])
    if n > 0 then parts[#parts + 1] = string.format("%s %d (first +$%X)", k, n, first); kinds[k] = (kinds[k] or 0) + 1 end
  end
  if #parts > 0 then
    bad = bad + 1
    if shown < (SC_VERBOSE or 8) then
      shown = shown + 1
      print(string.format("  in-between frame after step %d (vblank %d) differs: %s", steps, FRAME, table.concat(parts, ", ")))
    end
  end
end, emu.callbackType.exec, 0x0081C5, 0x0081C5, C, M)
local prev = on_end
function on_end()
  if prev then prev() end
  local t = {}
  for k, n in pairs(kinds) do t[#t + 1] = k .. " " .. n end
  table.sort(t)
  print(string.format("subchk: %d game steps, %d in-between frames: %d unlike another of the same step, %d unlike their step's frame%s", steps, subs, uneven, bad,
    #t > 0 and " (" .. table.concat(t, ", ") .. ")" or ""))
  if SC_FAIL and (uneven > 0 or subs == 0) then EXIT_CODE = 1 end
end
