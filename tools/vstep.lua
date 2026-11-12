-- Shared by tools/vrec.lua and tools/vcap.lua (the comparison video, tools/video.py): the
-- game's steps in the driving scene and its samples of the pad, on either ROM.
--   vstep_watch(on_step, on_sample)
--     on_step(hash)     a pass of the driving block is done; hash is of $7E:2000-$30E4 and
--                       $70E5-$78BC (road, HDMA and sprite tables, objects), which the two
--                       ROMs must leave alike step for step (tools/play.lua is the full test)
--     on_sample(word)   the game has taken the buttons for its next step ($4218/$4219 order)
-- Needs SYM on the patched ROM.
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local W, B = emu.memType.snesWorkRam, emu.memType.snesSaveRam
local patched = (SYM ~= nil and SYM.blk_back ~= nil)
local P = 4294967291
local function own() return patched and emu.read(SYM.own_addr, B) ~= 0 end
local function rd16(a) return emu.read(a, W) | (emu.read(a + 1, W) << 8) end
local function step_hash()
  local mt = own() and B or W
  local h = 0
  for a = 0x2000, 0x30E4 do h = (h * 31 + emu.read(a, mt)) % P end
  for a = 0x70E5, 0x78BC do h = (h * 31 + emu.read(a, mt)) % P end
  return h
end
VSTEP_PATCHED = patched
function vstep_watch(on_step, on_sample)
  local function exit_ev() on_step(step_hash()) end
  if patched then
    emu.addMemoryCallback(exit_ev, emu.callbackType.exec, SYM.blk_back, SYM.blk_back, C, M)
    -- (the pipelined loop head, src/pipe.asm: the buttons have just gone to $36)
    emu.addMemoryCallback(function() on_sample(rd16(0x36)) end, emu.callbackType.exec, SYM.te_commit, SYM.te_commit, C, M)
  else
    for _, a in ipairs({0x008F14, 0x008E41, 0x008D92}) do
      emu.addMemoryCallback(exit_ev, emu.callbackType.exec, a, a, C, M)
    end
  end
  emu.addMemoryCallback(function() on_sample(rd16(0x38)) end, emu.callbackType.exec, 0x008C73, 0x008C73, C, M)
end
VSTEP_ORDER = {"a", "b", "x", "y", "l", "r", "up", "down", "left", "right", "select", "start"}
