-- On foot: draws where the game's hit tests reach, over the picture.  Works on either ROM,
-- in Mesen's window (Debug > Script Window, open and run it, then play) or under
-- tools/run.py (--lua tools/hitbox.lua --shot ...).
--
-- The tests are distances between x positions and nothing else (no height, no boxes):
--   the player's punch or kick ($90:9249): the nearest enemy in front, if its x is less than
--     26 ahead of the player's x (20 or 24 in some stances) when facing right, or between
--     24 and 50 behind it when facing left (the original's numbers) -> green bar
--   an enemy's blow ($90:8D8B, $90:8C7x): the player's x less than 30 to its left, or less
--     than 60 to its right (the original's)                        -> red bar
--   an enemy's shot ($90:8D00): any distance from 28 up, unless the player crouches.
-- Vertical lines are the x positions themselves (green the player's, red the enemies');
-- the number over an enemy is its health.
local W = emu.memType.snesWorkRam
local function r8(a) return emu.read(a, W) end
local function r16(a) return r8(a) + r8(a + 1) * 256 end
local GREEN, RED, Y = 0x0000FF00, 0x00FF3030, 122
-- the numbers are read from the ROM, so the bars are right with and without src/tweaks.asm
local function rom16(a) return emu.read(a, emu.memType.snesMemory) + emu.read(a + 1, emu.memType.snesMemory) * 256 end
local R_STAND, R_ALT, R_CROUCH, LEFT = rom16(0x9092DA), rom16(0x9092EA), rom16(0x9092F4), rom16(0x9092BC)
local E_RIGHT, E_LEFT = rom16(0x908DD4), rom16(0x908D9A)   -- enemy to the player's right / left
emu.addEventCallback(function()
  if r8(0x0000) == 0 then return end                 -- the driving scene
  local px, pf = r16(0xCB3D), r8(0xCB42)
  local reach = R_STAND
  if r8(0xCB41) ~= 0 and r8(0xCB41) ~= 2 and r8(0x047C) == 0 then reach = R_ALT end
  if pf & 0x10 ~= 0 then reach = R_CROUCH end
  local a, b
  if pf & 0x80 ~= 0 then a, b = 0x7C, 0x7C + reach - 1 else a, b = 0x7C - LEFT - reach + 1, 0x7C - LEFT end
  emu.drawRectangle(a, Y, b - a + 1, 3, GREEN, true, 1, 0)
  emu.drawLine(0x7C, Y - 22, 0x7C, Y + 38, GREEN, 1, 0)
  for i = 3, 12 do
    local e = 0xCB1D + i * 16
    if r8(e + 8) >= 0x80 and r8(e + 10) ~= 0 and r8(e + 4) > 0 and r8(e + 4) < 0x80 then
      local d = r16(e) - px
      if d >= 0x8000 then d = d - 0x10000 end
      local sx = d + 0x7C
      if sx > -70 and sx < 300 then
        emu.drawLine(sx, Y - 22, sx, Y + 38, RED, 1, 0)
        emu.drawRectangle(sx - E_RIGHT + 1, Y + 5, E_RIGHT + E_LEFT - 1, 3, RED, true, 1, 0)
        emu.drawString(sx - 4, Y - 32, tostring(r8(e + 4)), 0x00FFFFFF, 0x40000000, 0, 1, 0)
      end
    end
  end
end, emu.eventType.endFrame)
