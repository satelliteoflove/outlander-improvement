-- Keeps the player alive on foot: while an on-foot scene runs ($00 = 1), the health at
-- $0404 is put back to 511 every vblank.  For the play scenarios that start from a
-- password (tools/test.py): the game puts the player down on foot by the road, and he
-- has to walk to the end of the stage (holding right) to get back into the car, which
-- with some passwords' health (16 at level 8) he would not live to do.  The on-foot scenes
-- run none of the patch's code, so both ROMs get the same; the drive then starts with
-- the car's health at 511 on both.
local W = emu.memType.snesWorkRam
local prev_frame = on_frame
function on_frame(n)
  if prev_frame then prev_frame(n) end
  if n >= (FOOTHOLD_FROM or 2000) and emu.read(0x0000, W) == 1 then   -- (not before boot has set $00)
    emu.write(0x0404, 0xFF, W); emu.write(0x0405, 0x01, W)
  end
end
