-- Replay recordings made by tools/golden_rec.lua on a patched ROM and compare everything the
-- block leaves behind.  For each recorded pass: go back to a savestate taken at the block's
-- entry, put the recorded RAM in place (low RAM both in work RAM and in the SA-1's copy,
-- $7E:2000-$7FFF in BW-RAM, where the patched driving scene keeps it), let the patched game
-- run the block, and compare RAM and registers at the exit with what the original produced.
-- Low RAM is read where the patch leaves it: bytes the block writes that are not copied
-- back per frame (LOW_PRIV) from the SA-1's copy, the rest from work RAM; after an exit
-- that leaves the scene, all of it from work RAM.  Also fails if the SA-1 ever touches
-- memory it does not have (work RAM, PPU and CPU registers): a patch that was missed.
-- Needs: GC_FILES = {path, ...}, GC_MASK = {[lowRamAddr] = true, ...} (bytes not compared),
-- SYM, build/blk_low.lua.  GC_FROM = vblank after which the savestate is taken (default
-- 1400; the run must be in the driving scene by then).  GC_VERBOSE = mismatches to list per
-- file (default 12).
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local W, B, IR = emu.memType.snesWorkRam, emu.memType.snesSaveRam, emu.memType.sa1InternalRam
-- the SA-1's copy of a low RAM byte: page 0 in I-RAM, the rest in BW-RAM
local function sa1_wr(a, v) if a < 0x100 then emu.write(a, v, IR) else emu.write(a, v, B) end end
local function sa1_rd(a)
  local v = a < 0x100 and emu.read(a, IR) or emu.read(a, B)
  if LOW_BANK[a] and (v == 0x40 or v == 0x41) then v = v + 0x3E end      -- pointer bank bytes: as the S-CPU has them
  return v
end
local REC = 20 + 2 * (0x800 + 0x6000)
local recs = {}
for _, p in ipairs(GC_FILES) do
  local f = assert(io.open(p, "rb")); local d = f:read("a"); f:close()
  for o = 1, #d - REC + 1, REC do recs[#recs + 1] = {file = p, o = o, d = d} end
end
local state, idx, cur, bad_recs, bad_bytes, shown = nil, 0, nil, 0, 0, {}
local by_addr = {}
local function inject(r)
  local d, o = r.d, r.o + 20
  for a = 0, 0x7FF do
    if a < 0x200 or a >= 0x400 then emu.write(a, d:byte(o + a), W); sa1_wr(a, d:byte(o + a)) end   -- not the stack pages
  end
  o = o + 0x800
  for a = 0x2000, 0x7FFF do emu.write(a, d:byte(o + a - 0x2000), B) end
  local _, a, x, y, p = string.unpack("<I4I2I2I2B", d, r.o)
  emu.setState({["cpu.a"] = a, ["cpu.x"] = x, ["cpu.y"] = y, ["cpu.ps"] = p})
end
local function note(r, what, addr, got, want)
  bad_bytes = bad_bytes + 1
  if addr then by_addr[addr] = (by_addr[addr] or 0) + 1 end
  shown[r.file] = (shown[r.file] or 0) + 1
  if shown[r.file] <= (GC_VERBOSE or 12) then
    local vb = string.unpack("<I4", r.d, r.o)
    print(string.format("  MISMATCH %s vblank %d: %s got %s want %s", r.file:match("[^/]+$"), vb, what, got, want))
  end
end
local function compare(r, id)
  local d = r.d
  local eid, a, x, y, p, db = string.unpack("<BI2I2I2BB", d, r.o + 11)
  local s = emu.getState()
  local before = bad_bytes
  if id ~= eid then note(r, "exit", nil, id, eid) end
  local m8 = (p & 0x20) ~= 0
  local function reg(name, got, want) if got ~= want then note(r, name, nil, string.format("%04X", got), string.format("%04X", want)) end end
  reg("A", s["cpu.a"], a)
  reg("X", s["cpu.x"], x); reg("Y", s["cpu.y"], y); reg("P", s["cpu.ps"] & 0xFB, p & 0xFB); reg("DB", s["cpu.dbr"], db)
  local o = r.o + 20 + 0x800 + 0x6000
  for ad = 0, 0x7FF do
    if not GC_MASK[ad] and (ad < 0x200 or ad >= 0x400) then
      local g, w = (id == 0 and LOW_PRIV[ad]) and sa1_rd(ad) or emu.read(ad, W), d:byte(o + ad)
      if g ~= w then note(r, string.format("$%04X", ad), ad, string.format("%02X", g), string.format("%02X", w)) end
    end
  end
  o = o + 0x800
  for ad = 0x2000, 0x7FFF do
    local g = emu.read(ad, B)
    local w = d:byte(o + ad - 0x2000)
    if g ~= w then note(r, string.format("$7E%04X", ad), ad, string.format("%02X", g), string.format("%02X", w)) end
  end
  if bad_bytes ~= before then bad_recs = bad_recs + 1 end
end
local function finish()
  local t = {}
  for a, n in pairs(by_addr) do t[#t + 1] = {a, n} end
  table.sort(t, function(p, q) return p[1] < q[1] end)
  if #t > 0 then
    local s, i = {}, 1
    while i <= #t do
      local j = i
      while j < #t and t[j + 1][1] == t[j][1] + 1 do j = j + 1 end
      s[#s + 1] = (i == j) and string.format("%04X", t[i][1]) or string.format("%04X-%04X", t[i][1], t[j][1])
      i = j + 1
    end
    print("  addresses that differed: " .. table.concat(s, " "))
  end
  print(string.format("golden: %d passes checked, %d differ (%d values)", idx - 1, bad_recs, bad_bytes))
  emu.stop(bad_recs == 0 and 0 or 1)
end
local function next_rec()
  idx = idx + 1
  if idx > #recs then finish(); return end
  cur = recs[idx]; inject(cur)
end
emu.addMemoryCallback(function()
  -- one pass = one piece from one state: no early start of the next frame (src/pipe.asm)
  if SYM.pipe_dis_addr then emu.write(SYM.pipe_dis_addr, 1, B) end
  if state == nil then
    if FRAME < (GC_FROM or 1400) then return end
    if SYM.early_addr and emu.read(SYM.early_addr, B) ~= 0 then return end
    state = emu.createSavestate()
    next_rec()
  end
end, emu.callbackType.exec, 0x008D12, 0x008D12, C, M)
local function exit_cb(id)
  return function()
    if not cur then return end
    compare(cur, id); cur = nil
    emu.loadSavestate(state)
    next_rec()
  end
end
for id, a in ipairs({0x008F14, 0x008E41, 0x008D92}) do
  emu.addMemoryCallback(exit_cb(id - 1), emu.callbackType.exec, a, a, C, M)
end
SA1_GUARD_FAIL = function(msg) bad_recs = bad_recs + 1; print("  " .. msg) end
local prev_end = on_end
function on_end() if prev_end then prev_end() end; print("golden: run ended before all passes were checked (" .. (idx - 1) .. " of " .. #recs .. ")"); EXIT_CODE = 1 end
