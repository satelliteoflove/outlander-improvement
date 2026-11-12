-- Report any access by the SA-1 to memory it does not have: work RAM (banks $7E/$7F and
-- $0000-$1FFF... which for the SA-1 is I-RAM up to $07FF, nothing above), the PPU/APU
-- registers ($2100-$21FF) and the S-CPU's own ($4000-$5FFF).  Such an access means a patch
-- to the SA-1's copy of the game was missed.  So does an access to the first page of BW-RAM:
-- the copy of the game's page 0 is in I-RAM, and nothing is at $40:0000-$00FF.  Each offending program counter is reported
-- once, through SA1_GUARD_FAIL(msg) if defined.
do
  local SA, CM = emu.cpuType.sa1, emu.memType.sa1Memory
  local seen = {}
  local function hit(kind)
    return function(addr)
      local s = emu.getState()
      local pc = (s["cart.coprocessor.cpu.k"] << 16) | s["cart.coprocessor.cpu.pc"]
      if seen[pc] then return end
      seen[pc] = true
      local msg = string.format("SA-1 at %06X %s %06X, which it cannot reach", pc, kind, addr)
      if SA1_GUARD_FAIL then SA1_GUARD_FAIL(msg) else print(msg) end
    end
  end
  for _, r in ipairs({{0x7E0000, 0x7FFFFF}, {0x002100, 0x0021FF}, {0x004000, 0x005FFF}, {0x000800, 0x001FFF},
                       {0x400000, 0x4000FF}, {0x006000, 0x0060FF}}) do
    emu.addMemoryCallback(hit("reads"), emu.callbackType.read, r[1], r[2], SA, CM)
    emu.addMemoryCallback(hit("writes"), emu.callbackType.write, r[1], r[2], SA, CM)
  end
end
-- Drawing an in-between frame (src/sub.asm, !sbx set) may change the game's state only
-- where it is put back afterwards.  Not put back: the stack's pages of the SA-1's low RAM
-- and what the block does not write of pages 4 to 7 (!LOW_A, !LOW_B in src/defs.asm),
-- $40:0800-$0FFF, and the status display's buffers and what follows them ($40:78BD-$7FFF).
if SYM and SYM.sbx_addr then
  local SA, CM, B = emu.cpuType.sa1, emu.memType.sa1Memory, emu.memType.snesSaveRam
  local seen = {}
  local function hit(addr)
    if emu.read(SYM.sbx_addr, B) == 0 then return end
    local s = emu.getState()
    local pc = (s["cart.coprocessor.cpu.k"] << 16) | s["cart.coprocessor.cpu.pc"]
    if seen[pc] then return end
    seen[pc] = true
    local msg = string.format("SA-1 at %06X writes %06X while drawing an in-between frame: that is not put back", pc, addr)
    if SA1_GUARD_FAIL then SA1_GUARD_FAIL(msg) else print(msg) end
  end
  for _, r in ipairs({{0x400200, 0x4003FF}, {0x4004C0, 0x4007BF}, {0x4007D0, 0x400FFF}, {0x4078BD, 0x407FFF},
                       {0x006200, 0x0063FF}, {0x0064C0, 0x0067BF}, {0x0067D0, 0x006FFF}}) do
    emu.addMemoryCallback(hit, emu.callbackType.write, r[1], r[2], SA, CM)
  end
end

