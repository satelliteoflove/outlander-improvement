-- Captures an on-foot stage for the comparison video (tools/vfoot.py): every frame from
-- VF_FROM to VF_TO, or to VF_TAIL (default 120) vblanks after the stage has ended, as
-- v%06d.png, the sound (audio.wav, through tools/wavrec.c, if $MESEN_WAV is set), and per
-- vblank in stats.txt:
--   FRAME scene($00) player-x landed taken health down
-- landed = blows that took health off an enemy so far (one per enemy per drop), taken = the
-- blows and shots that hurt the player so far (calls of $90:9033, the damage routine, but
-- those from punching a crate, $90:932B), health = $0404 (the car's and his: the game shares them),
-- down = enemies whose health has gone to 0.  For the hit tests drawn over the picture, also
-- params.txt (tools/footrom.lua's numbers, which must be loaded first) and per vblank on foot
-- in chars.txt:
--   FRAME player-x player-flags reach  then per record on screen (3 to 31, sprite slot set):
--   index:x:kind:health:flags
-- and in events.txt, per test run (the vblank's):
--   FRAME P              the player's punch is tested ($90:9249)
--   FRAME E i lo hi      enemy i's blow is tested: it hits if lo <= his x - its x < hi
--                        (the side it faces, FOOT.blows)
--   FRAME H              he is hurt (not by a crate)
local W = emu.memType.snesWorkRam
local function r8(a) return emu.read(a, W) end
local function r16(a) return r8(a) + r8(a + 1) * 256 end
local stats = assert(io.open(OUT .. "/stats.txt", "w"))
local chars = assert(io.open(OUT .. "/chars.txt", "w"))
assert(FOOT, "vfootcap.lua: load tools/footrom.lua first")
do
  local f = assert(io.open(OUT .. "/params.txt", "w"))
  for _, k in ipairs({"stand", "alt", "crouch", "left", "back", "e_right", "e_left"}) do f:write(k, " ", FOOT[k], "\n") end
  f:close()
end
local events = assert(io.open(OUT .. "/events.txt", "w"))
local C, M = emu.cpuType.snes, emu.memType.snesMemory
emu.addMemoryCallback(function() events:write(FRAME, " P\n") end, emu.callbackType.exec, 0x909249, 0x909249, C, M)
for a, w in pairs(FOOT.blows) do
  emu.addMemoryCallback(function()
    local y = emu.getState()["cpu.y"]
    local s = (r8(0xCB22 + y) & 0x10 ~= 0) and w.right or w.left
    events:write(string.format("%d E %d %d %d\n", FRAME, y // 16, s[1], s[2]))
  end, emu.callbackType.exec, a, a, C, M)
end
local hurt = 0
emu.addMemoryCallback(function()
  local sp = emu.getState()["cpu.sp"]
  if emu.read(sp + 1, M) + emu.read(sp + 2, M) * 256 ~= 0x932B then hurt = hurt + 1; events:write(FRAME, " H\n") end
end, emu.callbackType.exec, 0x909033, 0x909033, C, M)
local WAV = os.getenv("MESEN_WAV")
local function signal(what)
  local p = WAV .. "." .. what
  io.open(p, "w"):close()
  local t0 = os.clock()
  while true do
    local f = io.open(p, "r")
    if not f then return end
    f:close()
    if os.clock() - t0 > 10 then print("vfootcap: the sound recorder does not answer (" .. what .. ")"); EXIT_CODE = 1; return end
  end
end
local landed, down, prev_e, rec = 0, 0, {}, false
local seen_foot, left_at = false, nil
local pf = on_frame
function on_frame(n)
  if pf then pf(n) end
  local scene = r8(0x0000)
  if scene == 1 then seen_foot = true elseif seen_foot and not left_at then left_at = n end
  if scene == 1 then
    for i = 3, 31 do
      local e = 0xCB1D + i * 16
      local h = (r8(e + 8) >= 0x80) and r8(e + 4) or nil
      if h and prev_e[i] and h < prev_e[i] and prev_e[i] < 0x80 then
        if (r8(e + 15) >> 2) ~= 0x2B then              -- (a crate is not an enemy)
          landed = landed + 1
          if h == 0 then down = down + 1 end
        end
      end
      prev_e[i] = h
    end
  end
  stats:write(string.format("%d %d %d %d %d %d %d\n", n, scene, r16(0xCB3D), landed, hurt, r16(0x0404), down))
  if scene == 1 then
    local t = {string.format("%d %d %d %d", n, r16(0xCB3D), r8(0xCB42), FOOT.reach_now(r8))}
    for i = 3, 31 do
      local e = 0xCB1D + i * 16
      if r8(e + 8) >= 0x80 and r8(e + 10) ~= 0 then
        t[#t + 1] = string.format("%d:%d:%d:%d:%d", i, r16(e), r8(e + 15), r8(e + 4), r8(e + 5))
      end
    end
    chars:write(table.concat(t, " "), "\n")
  end
  if n >= VF_FROM and n <= VF_TO and not (left_at and n > left_at + (VF_TAIL or 120)) then
    local f = assert(io.open(string.format("%s/v%06d.png", OUT, n), "wb")); f:write(emu.takeScreenshot()); f:close()
  end
  if WAV and not rec and n >= VF_FROM - 1 then rec = true; signal("start") end
end
local pe = on_end
function on_end()
  if pe then pe() end
  if rec then signal("stop") end
  stats:close(); chars:close(); events:close()
  print(string.format("vfootcap: landed %d, taken %d, down %d", landed, hurt, down))
end
