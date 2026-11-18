-- The on-foot hit tests' numbers, read from the ROM, for tools/footbot.lua and
-- tools/vfootcap.lua (load it before them).  tools/hitbox.lua, which runs alone in Mesen's
-- window, has its own copy of this.
--   FOOT.stand, FOOT.alt, FOOT.crouch  the player's reach by stance ($90:92D9, $92E9, $92F3):
--                                      an enemy is hit in front if 0 <= its x - his < reach
--   FOOT.left, FOOT.back               behind: if left <= his x - its < left + reach + back
--   FOOT.e_right, FOOT.e_left          an enemy's blow ($90:8D8B): hits the player if his x
--                                      is less than e_right to its left or e_left to its right
--   FOOT.blows                         every enemy blow there is: by the address where its test
--                                      starts, the window of q = his x - its x for each side
--                                      it faces, {lo, hi} meaning lo <= q < hi.  The jump table
--                                      at $90:8B87 picks the routine by kind, the flag by +5:
--                                      kind $84 flag $40 -> $8BD1 (from 30 up to 60 on its right,
--                                      from 6 up to 26 on its left: never closer), flag $80 ->
--                                      $8C7B; kind $88 flag $80 -> $8D8B (flag $40 is its shot,
--                                      $8D00: any distance from 28 up, unless he crouches)
-- (Read from the file: at start-up the SA-1 build's banks $80-$9F are not mapped yet; its new
-- code, banks $A0-$BF, is the file's fourth megabyte.)
local function rom16(a)
  local b = a >> 16
  local o = (b >= 0xA0 and 0x300000 + (b - 0xA0) * 0x8000 or (b & 0x7F) * 0x8000) + (a & 0x7FFF)
  return emu.read(o, emu.memType.snesPrgRom) + emu.read(o + 1, emu.memType.snesPrgRom) * 256
end
FOOT = { stand = rom16(0x9092DA), alt = rom16(0x9092EA), crouch = rom16(0x9092F4),
         left = rom16(0x9092BC), back = 0, e_right = rom16(0x908DD4), e_left = rom16(0x908D9A) }
FOOT.blows = {
  [0x908BD1] = { right = {rom16(0x908BE5), rom16(0x908BE0)}, left = {1 - rom16(0x908C23), 1 - rom16(0x908C28)} },
  [0x908C7B] = { right = {1, rom16(0x908C8A)}, left = {1 - rom16(0x908CC3), 1} },
  [0x908D8B] = { right = {1, rom16(0x908D9A)}, left = {1 - rom16(0x908DD4), 1} },
}
-- With src/tweaks.asm, $90:92BB jumps to tw_left, whose SBC # and CMP # operands say where
-- the reach behind starts and how much longer it is than in front.
if rom16(0x9092BB) & 0xFF == 0x5C then
  local t = rom16(0x9092BC) + (rom16(0x9092BE) & 0xFF) * 0x10000
  FOOT.back = 0x10000 - rom16(t + 10)
  FOOT.left = rom16(t + 1) - FOOT.back
end
-- The player's reach in the stance he is in now (as $90:92D9 picks it).
function FOOT.reach_now(r8)
  if r8(0xCB42) & 0x10 ~= 0 then return FOOT.crouch end
  if r8(0xCB41) ~= 0 and r8(0xCB41) ~= 2 and r8(0x047C) == 0 then return FOOT.alt end
  return FOOT.stand
end
