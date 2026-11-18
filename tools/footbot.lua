-- A player for an on-foot stage, the same on any ROM, for the comparison video of the walking
-- (tools/vfoot.py).  It plays the way a person might:
--   * walks right;
--   * jumps twice: early in the stage, and again further on (FOOTBOT_JUMP2 pixels past where he
--     started), each time when nothing is near;
--   * fights every enemy that comes within FOOTBOT_ENGAGE pixels, ahead or behind, until it is
--     down: turns to it, steps to where his punch lands, and punches, standing and crouching
--     by turns (two of each);
--   * breaks the crates he comes to (crouching punches: standing ones do not touch them, and
--     each costs him a little health, as on the original) and picks up what falls out, or
--     what a beaten enemy leaves (crouch on it).
-- The rules are the same on both ROMs.  He knows where his punch lands as a player learns it:
-- the window is read from the ROM's own hit test ($90:9249), so each ROM's player stands where
-- that ROM's punch reaches, and with the patch that is further off and on either side of him.
--   FOOTBOT_FROM = vblank from which it plays (before that run.py's --input has the pad)
-- Records (see CLAUDE.md, On foot): 16 bytes from $7E:CB1D, the player the third; +0 x,
-- +3 y (160 on the ground), +4 health, +5 flags (the player's bit 7 facing right, bit 4
-- crouching), +8 bit 7 in use, +$A sprite slot, +$F kind.  Kinds as the hit test sees them
-- (kind / 4): $20-$31 can be punched, but $26 and $29 not at all and $2B (crates, $AC) only
-- crouching; $2D ($B4) is the car the stage starts beside.  Kinds under $80 on the ground are
-- things to pick up (a crate's lies hidden, y 1, until the crate breaks).
local W = emu.memType.snesWorkRam
local function r8(a) return emu.read(a, W) end
local function r16(a) return r8(a) + r8(a + 1) * 256 end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
assert(FOOT, "footbot.lua: load tools/footrom.lua first")
local R_STAND, R_ALT, R_CROUCH, LEFT, BACK = FOOT.stand, FOOT.alt, FOOT.crouch, FOOT.left, FOOT.back
local R_UP = math.min(R_STAND, R_ALT)
local FROM = FOOTBOT_FROM or 0
local ENGAGE = FOOTBOT_ENGAGE or 90
local JUMP1, JUMP2 = FOOTBOT_JUMP1 or 40, FOOTBOT_JUMP2 or 900   -- vblanks into play; pixels on
local P = 0xCB3D

local function rec(i)
  local e = 0xCB1D + i * 16
  return { i = i, x = s16(r16(e)), y = r8(e + 3), h = r8(e + 4), used = r8(e + 8) >= 0x80,
           slot = r8(e + 10), kind = r8(e + 15) }
end
local function enemy(r)
  local q = r.kind >> 2
  return r.used and r.slot ~= 0 and r.h > 0 and r.h < 0x80 and q >= 0x20 and q < 0x32
         and q ~= 0x26 and q ~= 0x29 and q ~= 0x2B and q ~= 0x2D
end
local function crate(r) return r.used and r.slot ~= 0 and r.h > 0 and r.h < 0x80 and (r.kind >> 2) == 0x2B and r.y == 160 end
local function item(r) return r.used and r.kind ~= 0 and r.kind < 0x80 and r.y == 160 end

-- Where his punch lands, by stance: an enemy at d (its x less his) in front if 0 <= d < reach,
-- behind if LEFT <= -d < LEFT + reach + BACK.  He punches inside that, a little in from its ends, and
-- otherwise steps towards its middle (backwards means turning round for a step).
local function reach(crouch) return crouch and R_CROUCH or R_UP end
local function aim(d, crouch)          -- -> how far to step (> 0 forward), whether in front
  local r = reach(crouch)
  if d >= -8 then
    if d >= 0 and d < r - 2 then return 0, true end
    return d - math.floor(r / 2), true
  end
  r = r + BACK
  if -d >= LEFT + 2 and -d < LEFT + r - 2 then return 0, false end
  return -d - LEFT - math.floor(r / 2), false
end

local swing, punches = 0, 0            -- vblanks into a punch (A 10, let go 8); punches at this foe
local foe, foe_h, foe_t, crouch = nil, nil, 0, false
local ignore = {}                      -- record -> vblank until which he leaves it alone
local jump_t, jumps, start_x, quiet, pick_t = nil, 0, nil, 0, 0

local function punch()                 -- one vblank of the punch cycle
  swing = swing + 1
  if swing > 18 then swing = 1 end
  if swing == 1 then punches = punches + 1 end
  local t = (swing <= 10) and {a = true} or {}
  if crouch then t.down = true end
  return t
end
local function step(off, ahead)        -- towards the window; facing the target unless backing off
  local fwd = (off > 0) == ahead       -- the way to go is right
  return fwd and {right = true} or {left = true}
end

local decide
local prev_hook = input_hook
function input_hook()
  local t = decide()
  if FOOTBOT_DEBUG and FRAME >= FROM and FRAME % 4 == 0 and r8(0) == 1 then
    local b = {}
    for k in pairs(t or {}) do b[#b + 1] = k end
    table.sort(b)
    print(string.format("BOT %d px %d pf %02X foe %s swing %d jumps %d -> %s %s", FRAME, r16(P), r8(0xCB42),
      tostring(foe), swing, jumps, table.concat(b, "+"), DBG or ""))
  end
  return t
end
function decide()
  if FRAME < FROM then return prev_hook and prev_hook() end
  if r8(0x0000) ~= 1 then swing, foe, jump_t = 0, nil, nil; return {} end
  local px, pf = r16(P), r8(0xCB42)
  local right = pf & 0x80 ~= 0
  start_x = start_x or px
  if jump_t then                       -- a jump under way: hold right through it
    jump_t = jump_t + 1
    if jump_t > 52 then jump_t = nil end
    return (jump_t and jump_t <= 6) and {right = true, y = true} or {right = true}
  end
  -- what is about
  local cand, box, xd, thing, td, near = nil, nil, nil, nil, nil, false
  for i = 3, 31 do
    local r = rec(i)
    local d = r.x - px
    if (ignore[i] or 0) < FRAME then
      if enemy(r) then
        if math.abs(d) < 160 then near = true end
        local lim = (i == foe) and ENGAGE + 40 or ENGAGE
        if math.abs(d) <= lim and (not cand or i == foe or (cand ~= foe and math.abs(d) < math.abs(cand.d))) then
          cand = {i = i, d = d, h = r.h}
        end
      elseif crate(r) and d >= -60 and d <= 70 then
        near = true
        if not xd or math.abs(d) < math.abs(xd) then box, xd = i, d end
      elseif item(r) and d >= -40 and d <= 60 then
        near = true
        if not td or math.abs(d) < math.abs(td) then thing, td = i, d end
      end
    end
  end
  DBG = string.format("cand %s box %s/%s item %s/%s", cand and (cand.i .. "@" .. cand.d) or "-", tostring(box), tostring(xd), tostring(thing), tostring(td))
  -- the jumps, where nothing is near
  quiet = (not near and swing == 0) and quiet + 1 or 0
  if jumps < 2 and quiet > 20 and ((jumps == 0 and FRAME >= FROM + JUMP1) or (jumps == 1 and px >= start_x + JUMP2)) then
    jumps, jump_t = jumps + 1, 1
    return {right = true, y = true}
  end
  if swing > 0 and swing < 18 and (cand or box) then return punch() end   -- finish a punch
  swing = 0
  if cand then                         -- an enemy: fight it until it is down
    if foe ~= cand.i then foe, foe_h, foe_t, punches = cand.i, cand.h, 0, 0 end
    if cand.h ~= foe_h then foe_h, foe_t = cand.h, 0 end
    foe_t = foe_t + 1
    if foe_t > 600 then ignore[foe] = FRAME + 900; foe = nil; return {right = true} end
    crouch = (math.floor(punches / 2) % 2) == 1
    local off, ahead = aim(cand.d, crouch)
    if off == 0 then
      if ahead ~= right then return ahead and {right = true} or {left = true} end
      return punch()
    end
    return step(off, ahead)
  end
  foe = nil
  if box then                          -- a crate: crouch and punch it open
    crouch = true
    local off, ahead = aim(xd, true)
    if off == 0 then
      if ahead ~= right then return ahead and {right = true} or {left = true} end
      return punch()
    end
    return step(off, ahead)
  end
  if thing then                        -- something on the ground: stand on it and crouch
    local off = td - 4
    if math.abs(off) > 3 and pick_t == 0 then return off > 0 and {right = true} or {left = true} end
    pick_t = pick_t + 1
    if pick_t > 60 then pick_t = 0; ignore[thing] = FRAME + 600 end
    return {down = true}
  end
  pick_t = 0
  return {right = true}
end
