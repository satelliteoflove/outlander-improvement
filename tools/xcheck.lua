-- Differential test while the patched ROM plays: every pass through the driving block is
-- run twice from the same state, once the patched way (SA-1) and once by the original code
-- on the S-CPU, and everything the two leave behind is compared.  Unlike the recordings of
-- tools/golden_rec.lua this follows the patched game's own play, for as long as it runs.
--
-- How: at the block's entry take a savestate, put the original JSL back over the hook (ROM
-- is patched in place from here), copy $7E:2000-$7FFF from BW-RAM, where the patched scene
-- keeps it, to work RAM, where the original code expects it (and likewise the low RAM that
-- only the SA-1's copy has up to date, LOW_PRIV), clear the patch's flags so
-- the interrupt handlers behave as in the original, and let the original code run.  At its
-- exit capture RAM and registers, go back to the savestate, restore the hook and let the
-- patched game run the block its own way.  At that exit compare; the game carries on from
-- there untouched.  (Mesen cannot take a savestate and load another in the same callback,
-- hence this order.)
--
-- Needs GC_MASK = {[lowRamAddr] = true} (bytes not compared), SYM and build/blk_low.lua.  Optional:
-- XC_FROM = first vblank checked; XC_EVERY = check every n-th pass (default 1);
-- XC_VERBOSE = differences listed per pass (default 8); XC_SAVE = path: write the failing
-- passes as recordings that tools/golden_chk.lua can replay (XC_SAVE_ALL = true: every pass).
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local W, B, R = emu.memType.snesWorkRam, emu.memType.snesSaveRam, emu.memType.snesPrgRom
local IR = emu.memType.sa1InternalRam
local function sa1_rd(a)        -- the SA-1's copy of a low RAM byte, as the S-CPU would have it
  local v = a < 0x100 and emu.read(a, IR) or emu.read(a, B)
  if LOW_BANK[a] and (v == 0x40 or v == 0x41) then v = v + 0x3E end
  return v
end
local HOOK = 0x0D12                                   -- file offset of $00:8D12
local ORIG = {0x22, 0xE4, 0xB0, 0x81}                 -- JSL $81B0E4
local hook_bytes = {}
for i = 0, 3 do hook_bytes[i + 1] = emu.read(HOOK + i, R) end
local mode, s0, b_out, entry = "idle", nil, nil, nil
local pass, checked, bad, bad_vals, by_addr = 0, 0, 0, 0, {}
local dp_notes
local save = XC_SAVE and assert(io.open(XC_SAVE, "wb")) or nil
local function grab(lo, hi, mt)
  local t, n = {}, 0
  for a = lo, hi do n = n + 1; t[n] = emu.read(a, mt) end
  return t
end
local function str(t)
  local parts = {}
  for i = 1, #t, 4096 do parts[#parts + 1] = string.char(table.unpack(t, i, math.min(i + 4095, #t))) end
  return table.concat(parts)
end
local function capture(sa1, id)
  local s = emu.getState()
  local hi = grab(0x2000, 0x7FFF, sa1 and B or W)
  local lo = grab(0, 0x7FF, W)
  if sa1 and id == 0 then               -- (after the other exits everything is back in work RAM)
    for a in pairs(LOW_PRIV) do lo[a + 1] = sa1_rd(a) end
  end
  return { lo = lo, hi = hi, a = s["cpu.a"], x = s["cpu.x"], y = s["cpu.y"], p = s["cpu.ps"], db = s["cpu.dbr"] }
end
local function compare(a, b, vb)
  local n, lines = 0, {}
  local function note(what, got, want, addr)
    n = n + 1
    if addr then by_addr[addr] = (by_addr[addr] or 0) + 1 end
    if n <= (XC_VERBOSE or 8) then lines[#lines + 1] = string.format("%s %s/%s", what, got, want) end
  end
  if a.id ~= b.id then note("exit", a.id, b.id) end
  for _, r in ipairs({"a", "x", "y", "db"}) do
    if a[r] ~= b[r] then
      -- The game sets the direct page with LDX #$0100 / PHX / PLD; the SA-1's copy loads
      -- $6100 there (tools/mkpatch.py), and X keeps it.  Seen at the exit to $81:BC8B, which
      -- reloads X before using it.  Reported, not counted.
      if (r == "x" or r == "y") and a[r] == b[r] + 0x6000 and b[r] >= 0x100 and b[r] <= 0x700 and b[r] % 0x100 == 0 then
        dp_notes = (dp_notes or 0) + 1
      else
        note(r, string.format("%04X", a[r]), string.format("%04X", b[r]))
      end
    end
  end
  if (a.p & 0xFB) ~= (b.p & 0xFB) then note("p", string.format("%02X", a.p), string.format("%02X", b.p)) end
  for ad = 0, 0x7FF do
    if a.lo[ad + 1] ~= b.lo[ad + 1] and not GC_MASK[ad] and (ad < 0x200 or ad >= 0x400) then
      note(string.format("$%04X", ad), string.format("%02X", a.lo[ad + 1]), string.format("%02X", b.lo[ad + 1]), ad)
    end
  end
  for i = 1, 0x6000 do
    if a.hi[i] ~= b.hi[i] then note(string.format("$7E%04X", i + 0x1FFF), string.format("%02X", a.hi[i]), string.format("%02X", b.hi[i]), i + 0x1FFF) end
  end
  if n > 0 then
    bad = bad + 1; bad_vals = bad_vals + n
    print(string.format("  MISMATCH pass %d (vblank %d): %d values, sa1/original: %s", pass, vb, n, table.concat(lines, ", ")))
  end
  return n
end
local function exit_cb(id)
  return function()
    if mode == "orig" then
      b_out = capture(false, id); b_out.id = id
      emu.loadSavestate(s0); s0 = nil
      for i = 0, 3 do emu.write(HOOK + i, hook_bytes[i + 1], R) end
      mode = "sa1"
    elseif mode == "sa1" then
      local a_out = capture(true, id); a_out.id = id
      checked = checked + 1
      local n = compare(a_out, b_out, entry.vb)
      if save and (n > 0 or XC_SAVE_ALL) then
        save:write(string.pack("<I4I2I2I2B", entry.vb, entry.a, entry.x, entry.y, entry.p),
                   string.pack("<BI2I2I2BB", b_out.id, b_out.a, b_out.x, b_out.y, b_out.p, b_out.db),
                   entry.lo, entry.hi, str(b_out.lo), str(b_out.hi))
      end
      mode = "idle"; b_out = nil
    end
  end
end
emu.addMemoryCallback(function()
  -- one pass = one piece from one state: no early start of the next frame (src/pipe.asm)
  if SYM.pipe_dis_addr then emu.write(SYM.pipe_dis_addr, 1, B) end
  if mode ~= "idle" then return end
  pass = pass + 1
  if SYM.early_addr and emu.read(SYM.early_addr, B) ~= 0 then return end
  if FRAME < (XC_FROM or 0) or pass % (XC_EVERY or 1) ~= 0 then return end
  s0 = emu.createSavestate()
  local s = emu.getState()
  entry = { vb = FRAME, a = s["cpu.a"], x = s["cpu.x"], y = s["cpu.y"], p = s["cpu.ps"] }
  -- first the original code, on the S-CPU, with everything in work RAM
  if emu.read(SYM.own_addr, B) ~= 0 then       -- (after a pause work RAM already has it all)
    for a = 0x2000, 0x7FFF do emu.write(a, emu.read(a, B), W) end
    for a in pairs(LOW_PRIV) do emu.write(a, sa1_rd(a), W) end
  end
  if save then entry.lo = str(grab(0, 0x7FF, W)); entry.hi = str(grab(0x2000, 0x7FFF, B)) end
  emu.write(SYM.own_addr, 0, B); emu.write(SYM.fb_sa1_addr, 0, B)
  for i = 0, 3 do emu.write(HOOK + i, ORIG[i + 1], R) end
  mode = "orig"
end, emu.callbackType.exec, 0x008D12, 0x008D12, C, M)
for id, a in ipairs({0x008F14, 0x008E41, 0x008D92}) do
  emu.addMemoryCallback(exit_cb(id - 1), emu.callbackType.exec, a, a, C, M)
end
SA1_GUARD_FAIL = function(msg) bad = bad + 1; print("  " .. msg) end
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  if save then save:close() end
  local t = {}
  for a in pairs(by_addr) do t[#t + 1] = a end
  table.sort(t)
  if #t > 0 then
    local s, i = {}, 1
    while i <= #t do
      local j = i
      while j < #t and t[j + 1] == t[j] + 1 do j = j + 1 end
      s[#s + 1] = (i == j) and string.format("%04X", t[i]) or string.format("%04X-%04X", t[i], t[j])
      i = j + 1
    end
    print("  addresses that differed: " .. table.concat(s, " "))
  end
  if dp_notes then print(string.format("  note: %d times an index register held a direct page value at the exit ($6x00 for $0x00)", dp_notes)) end
  print(string.format("xcheck: %d passes checked, %d differ (%d values)", checked, bad, bad_vals))
  if bad > 0 or checked == 0 then EXIT_CODE = 1 end
end
