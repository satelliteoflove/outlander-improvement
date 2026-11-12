-- RAM / register access map for spans of the driving main loop (default: the two render calls).
-- Override with RAMIO_SPANS = {{name=, a=start, b=end}, ...} and RAMIO_PATH.
-- For each: which addresses are read before being written (inputs), written (outputs),
-- and which hardware registers are touched.  Interrupt handlers are excluded.
local SP = RAMIO_SPANS or {{name="R1_81CC3B", a=0x008E11, b=0x008E15}, {name="R2_809DD6", a=0x008ED3, b=0x008ED7}}
local cur, irq = nil, 0
local M = emu.memType.snesMemory
local C = emu.cpuType.snes
-- all span ends are registered before any span start, so a span may begin where another ends
for _, s in ipairs(SP) do
  s.rd, s.wr, s.inp, s.reg = {}, {}, {}, {}
  emu.addMemoryCallback(function() if cur == s then cur = nil end end, emu.callbackType.exec, s.b, s.b, C, M)
end
for _, s in ipairs(SP) do
  emu.addMemoryCallback(function() cur = s; s.seen = {} end, emu.callbackType.exec, s.a, s.a, C, M)
end
-- accesses made by the interrupt handlers go to a span of their own
local INT = {name = "INT", rd = {}, wr = {}, inp = {}, reg = {}, seen = {}}
SP[#SP + 1] = INT
for _, a in ipairs({0x008111, 0x0082CA}) do
  emu.addMemoryCallback(function() irq = irq + 1 end, emu.callbackType.exec, a, a, C, M)
end
for _, a in ipairs({0x0082C5, 0x00830B}) do
  emu.addMemoryCallback(function() if irq > 0 then irq = irq - 1 end end, emu.callbackType.exec, a, a, C, M)
end
local function norm(addr)
  local b, lo = addr >> 16, addr & 0xFFFF
  if b >= 0x7E and b <= 0x7F then return addr end
  if (b < 0x40 or (b >= 0x80 and b < 0xC0)) then
    if lo < 0x2000 then return 0x7E0000 | lo end
    if lo < 0x8000 then return 0x1000000 | lo end   -- hardware register
  end
  return nil
end
local function on_rd(addr)
  local cur = cur
  if irq > 0 then cur = INT end
  if not cur then return end
  local n = norm(addr); if not n then return end
  if n >= 0x1000000 then cur.reg[n] = (cur.reg[n] or 0) | 1; return end
  cur.rd[n] = (cur.rd[n] or 0) + 1
  if not cur.seen[n] then cur.inp[n] = true end
end
local function on_wr(addr)
  local cur = cur
  if irq > 0 then cur = INT end
  if not cur then return end
  local n = norm(addr); if not n then return end
  if n >= 0x1000000 then cur.reg[n] = (cur.reg[n] or 0) | 2; return end
  cur.wr[n] = (cur.wr[n] or 0) + 1
  cur.seen[n] = true
end
emu.addMemoryCallback(on_rd, emu.callbackType.read, 0x000000, 0xFFFFFF, C, M)
emu.addMemoryCallback(on_wr, emu.callbackType.write, 0x000000, 0xFFFFFF, C, M)
function on_end()
  local f = assert(io.open(RAMIO_PATH or (OUT .. "/../ramio.txt"), "w"))
  for _, s in ipairs(SP) do
    local all = {}
    for a in pairs(s.rd) do all[a] = true end
    for a in pairs(s.wr) do all[a] = true end
    for a in pairs(all) do
      f:write(string.format("%s %06X r=%d w=%d in=%d\n", s.name, a, s.rd[a] or 0, s.wr[a] or 0, s.inp[a] and 1 or 0))
    end
    for a, v in pairs(s.reg) do f:write(string.format("%s REG %04X %s\n", s.name, a & 0xFFFF, ({"R","W","RW"})[v])) end
  end
  f:close()
end
