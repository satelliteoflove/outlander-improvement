-- Which RAM actually has to travel between the S-CPU and the SA-1 around the driving block.
-- Run on the patched ROM (needs SYM).  Watches, for low RAM ($0000-$07FF) and $7E:2000-$7FFF:
--   what the SA-1 reads before writing it during a pass through the block   (block inputs)
--   what the SA-1 writes                                                    (block outputs)
--   what the S-CPU side writes outside the block, after the first pass (code, and DMA into work RAM)
--   what the S-CPU side reads after a pass before writing it itself (code, DMA, HDMA)
--   what the S-CPU side reads and writes while the SA-1 is running (interrupt handlers)
-- The patch's own copying is left out.  Writes FLOW_PATH (default OUT/../flow.txt):
--   address  flags   one line per address, flags = letters:
--     I block input  O block output  w S-CPU write  r S-CPU read needing the block's value
--     x S-CPU write while the SA-1 runs  y S-CPU read while the SA-1 runs
-- Report with tools/flow.py.
local SC, SA = emu.cpuType.snes, emu.cpuType.sa1
local W, B, M = emu.memType.snesWorkRam, emu.memType.snesSaveRam, emu.memType.snesMemory
local F = {}                              -- addr -> set of flags
local function flag(a, f) local t = F[a]; if not t then t = {}; F[a] = t end; t[f] = true end
local running, copying = false, false     -- SA-1 has the block / the patch is copying
local passes = 0
local sa_written, s_written = {}, {}
-- callbacks give CPU addresses: map them to the game's address ($0000-$7FFF of bank $7E)
local function sa1_addr(addr)             -- SA-1: bank $40, or the $6000 window (= $40:0000-$1FFF)
  local bank, lo = addr >> 16, addr & 0xFFFF
  if bank == 0x40 then return lo < 0x8000 and lo or nil end
  if (bank < 0x40 or (bank >= 0x80 and bank < 0xC0)) and lo >= 0x6000 and lo < 0x8000 then return lo - 0x6000 end
  return nil
end
local function scpu_addr(addr)            -- S-CPU: bank $7E, or low RAM in the system banks
  local bank, lo = addr >> 16, addr & 0xFFFF
  if bank == 0x7E then return lo < 0x8000 and lo or nil end
  if (bank < 0x40 or (bank >= 0x80 and bank < 0xC0)) and lo < 0x2000 then return lo end
  return nil
end
local function ok(a) return a and (a < 0x800 or (a >= 0x2000 and a < 0x8000)) end
local SM, CM = emu.memType.snesMemory, emu.memType.sa1Memory
emu.addMemoryCallback(function(addr)
  if not running then return end
  local a = sa1_addr(addr)
  if ok(a) and not sa_written[a] then flag(a, "I") end
end, emu.callbackType.read, 0x000000, 0xFFFFFF, SA, CM)
emu.addMemoryCallback(function(addr)
  if not running then return end
  local a = sa1_addr(addr)
  if ok(a) then sa_written[a] = true; flag(a, "O") end
end, emu.callbackType.write, 0x000000, 0xFFFFFF, SA, CM)
emu.addMemoryCallback(function(addr)
  if copying then return end
  local a = scpu_addr(addr)
  if not ok(a) then return end
  if running then flag(a, "y") elseif not s_written[a] then flag(a, "r") end
end, emu.callbackType.read, 0x000000, 0xFFFFFF, SC, SM)
emu.addMemoryCallback(function(addr)
  if copying then return end
  local a = scpu_addr(addr)
  if not ok(a) then return end
  if running then flag(a, "x") elseif passes > 0 then flag(a, "w") end     -- (scene set-up is not counted)
  s_written[a] = true
end, emu.callbackType.write, 0x000000, 0xFFFFFF, SC, SM)
local function at(addr, fn) emu.addMemoryCallback(fn, emu.callbackType.exec, addr, addr, SC, M) end
at(SYM.blk_offload, function() copying = true end)
at(SYM.blk_run, function() copying = false; running = true; sa_written = {} end)
at(SYM.blk_back, function() running = false; copying = true; s_written = {}; passes = passes + 1 end)
at(SYM.blk_ret, function() copying = false end)
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  local f = assert(io.open(FLOW_PATH or (OUT .. "/../flow.txt"), "w"))
  for a, t in pairs(F) do
    local s = ""
    for _, k in ipairs({"I", "O", "w", "r", "x", "y"}) do if t[k] then s = s .. k end end
    f:write(string.format("%04X %s\n", a, s))
  end
  f:close()
end
