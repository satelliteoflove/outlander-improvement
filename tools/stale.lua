-- While the SA-1 owns $7E:2000-$7FFF (!own set) a byte it has written there exists only in
-- BW-RAM; the copy in work RAM is stale.  This reports every S-CPU-side read of such a
-- byte from work RAM (by code, DMA or HDMA: transfers show up under the instruction that
-- was running), and every S-CPU write to the range while it is owned, other than the
-- patch's own copying back (sync_out).  Needs SYM.  STALE_FAIL = true fails the run.
local SC, SM, B = emu.cpuType.snes, emu.memType.snesMemory, emu.memType.snesSaveRam
local SA, CM = emu.cpuType.sa1, emu.memType.sa1Memory
local dirty, owned, seen = {}, false, {}
local function own() 
  local o = emu.read(SYM.own_addr, B) ~= 0
  if o ~= owned then owned = o; dirty = {} end       -- handed over either way: both copies agree
  return o
end
emu.addMemoryCallback(function(addr) dirty[addr & 0xFFFF] = true end, emu.callbackType.write, 0x402000, 0x407FFF, SA, CM)
local function cb(kind, is_write)
  return function(addr)
    if not own() then return end
    local a = addr & 0xFFFF
    if not is_write and not dirty[a] then return end
    local s = emu.getState()
    local pc = (s["cpu.k"] << 16) | s["cpu.pc"]
    if is_write and pc >= SYM.sync_out and pc <= SYM.sync_out_end then return end
    local k = string.format("%s %06X", kind, pc)
    local r = seen[k]
    if not r then r = {lo = a, hi = a, n = 0, first = FRAME}; seen[k] = r end
    r.n = r.n + 1
    if a < r.lo then r.lo = a end
    if a > r.hi then r.hi = a end
  end
end
emu.addMemoryCallback(cb("stale read at", false), emu.callbackType.read, 0x7E2000, 0x7E7FFF, SC, SM)
emu.addMemoryCallback(cb("write at", true), emu.callbackType.write, 0x7E2000, 0x7E7FFF, SC, SM)
-- The same for low RAM.  The SA-1 has its own copy of what the block uses, and per frame
-- only the bytes that the S-CPU's side is known to use are carried across (LOW_IN, and
-- everything the block writes except LOW_PRIV: see low_tables() in tools/build.py).  That
-- knowledge comes from static analysis; this checks it against what the S-CPU does:
--   * a read from work RAM of a LOW_PRIV byte that the SA-1 has written since the scene
--     began is a stale read;
--   * a write to a byte the block uses that is not in LOW_IN never reaches the SA-1.
-- (LOW_SHOWN: bytes of which the S-CPU is given values of its own, src/pipe.asm.)
-- The patch's own code in bank $A0 (the copies) is not counted.
do
  local ldirty, lseen = {}, {}
  local function sa1_wrote(addr)
    local a = addr & 0xFFFF
    if a >= 0x6000 then a = a - 0x6000 end
    if a < 0x800 and LOW_PRIV[a] then ldirty[a] = true end
  end
  for bank = 0x00, 0x3F do          -- page 0 is in I-RAM, at $0000 of every system bank
    emu.addMemoryCallback(sa1_wrote, emu.callbackType.write, bank << 16, (bank << 16) | 0xFF, SA, CM)
    emu.addMemoryCallback(sa1_wrote, emu.callbackType.write, (bank << 16) | 0x6100, (bank << 16) | 0x67FF, SA, CM)
  end
  emu.addMemoryCallback(sa1_wrote, emu.callbackType.write, 0x400100, 0x4007FF, SA, CM)
  local was = false
  local function lcb(kind, is_write)
    return function(addr)
      local o = own()
      if o ~= was then was = o; ldirty = {} end
      if not o then return end
      local a = addr & 0xFFFF
      if a >= 0x800 then return end
      if is_write then
        if not LOW_BLK[a] or LOW_IN[a] then return end
      elseif not ldirty[a] or (LOW_SHOWN and LOW_SHOWN[a]) then return end
      local s = emu.getState()
      if s["cpu.k"] == 0xA0 then return end
      local k = string.format("%s %06X", kind, (s["cpu.k"] << 16) | s["cpu.pc"])
      local r = lseen[k]
      if not r then r = {lo = a, hi = a, n = 0, first = FRAME}; lseen[k] = r end
      r.n = r.n + 1
      if a < r.lo then r.lo = a end
      if a > r.hi then r.hi = a end
    end
  end
  for _, base in ipairs({0x000000, 0x7E0000, 0x800000}) do
    emu.addMemoryCallback(lcb("stale read at", false), emu.callbackType.read, base, base + 0x7FF, SC, SM)
    emu.addMemoryCallback(lcb("lost write at", true), emu.callbackType.write, base, base + 0x7FF, SC, SM)
  end
  local prev = on_end
  function on_end()
    if prev then prev() end
    local t = {}
    for k, r in pairs(lseen) do t[#t + 1] = string.format("  %s  $%04X-%04X  x%d  (first at vblank %d)", k, r.lo, r.hi, r.n, r.first) end
    table.sort(t)
    if #t == 0 then print("stale: the S-CPU never used low RAM that only the SA-1 had up to date")
    else
      print("stale: S-CPU accesses to low RAM that is not carried across:"); print(table.concat(t, "\n"))
      if STALE_FAIL then EXIT_CODE = 1 end
    end
  end
end
-- When the patch gives everything back to the S-CPU (the scene ends, pauses or is left
-- for the title screen), work RAM must end up with all the SA-1 had: checked at the end
-- of sync_out, byte for byte.
do
  local IR, W = emu.memType.sa1InternalRam, emu.memType.snesWorkRam
  local given, wrong = 0, 0
  emu.addMemoryCallback(function()
    given = given + 1
    local n, first = 0, nil
    for a in pairs(LOW_OUT) do
      local v = a < 0x100 and emu.read(a, IR) or emu.read(a, B)
      if LOW_BANK[a] and (v == 0x40 or v == 0x41) then v = v + 0x3E end
      if v ~= emu.read(a, W) then n = n + 1; first = first or a end
    end
    for a = 0x2000, 0x7FFF do
      if emu.read(a, B) ~= emu.read(a, W) then n = n + 1; first = first or a end
    end
    if n > 0 then
      wrong = wrong + 1
      print(string.format("give back at vblank %d: %d bytes of work RAM differ from the SA-1's (first $%04X)", FRAME, n, first))
    end
  end, emu.callbackType.exec, SYM.sync_out_end, SYM.sync_out_end, SC, SM)
  local prev = on_end
  function on_end()
    if prev then prev() end
    print(string.format("give back: %d times, %d wrong", given, wrong))
    if wrong > 0 and STALE_FAIL then EXIT_CODE = 1 end
  end
end
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  local t = {}
  for k, r in pairs(seen) do t[#t + 1] = string.format("  %s  $7E:%04X-%04X  x%d  (first at vblank %d)", k, r.lo, r.hi, r.n, r.first) end
  table.sort(t)
  if #t == 0 then print("stale: the S-CPU never used work RAM that the SA-1 owned")
  else
    print("stale: S-CPU accesses to work RAM that the SA-1 owned:"); print(table.concat(t, "\n"))
    if STALE_FAIL then EXIT_CODE = 1 end
  end
end
