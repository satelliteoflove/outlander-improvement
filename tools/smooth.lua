-- How evenly the picture moves from shown frame to shown frame.  After every run of the
-- object pass ($80:9DD6 in the SA-1's copy: once per frame drawn, game step or in-between)
-- this notes where the car is along the road ($70 and $B0, in quarters of a segment) and
-- across it ($B9), the horizon ($B1), and every object's distance and x; at the end it
-- reports the steps between consecutive frames.  On a perfectly even drive every frame
-- moves the same; "jerk" is the change of the step from one frame to the next.
-- Needs SYM.  SM_FROM / SM_TO = vblanks (default 1300 / the end); SM_LIST = n: list n frames.
local SA, CM = emu.cpuType.sa1, emu.memType.sa1Memory
local B, IR = emu.memType.snesSaveRam, emu.memType.sa1InternalRam
local function p0(a) return emu.read(a, IR) | (emu.read(a + 1, IR) << 8) end
local function bw(a) return emu.read(a, B) | (emu.read(a + 1, B) << 8) end
local function s16(v) return v >= 0x8000 and v - 0x10000 or v end
local fr = {}
local function drawn(sub)
  return function()
  if FRAME < (SM_FROM or 1300) or (SM_TO and FRAME > SM_TO) then return end
  if (emu.read(SYM.sbx_addr, B) ~= 0) ~= sub then return end
  local f = { vb = FRAME, sub = emu.read(SYM.sbx_addr, B) ~= 0 and emu.read(SYM.sub_j_addr, B) or 0,
              pos = ((0x190 - p0(0x70)) // 2) * 4 + emu.read(0xB0, IR), b9 = s16(p0(0xB9)), b1 = s16(p0(0xB1)), obj = {} }
  for x = 0, 0x29F, 12 do
    local ty = bw(0x7121 + x + 2)
    if ty < 0x8000 then f.obj[x] = { ty = ty, z = s16(bw(0x7121 + x)), x = s16(bw(0x7121 + x + 4)) } end
  end
  fr[#fr + 1] = f
  end
end
emu.addMemoryCallback(drawn(false), emu.callbackType.exec, 0x208ED7, 0x208ED7, SA, CM)
emu.addMemoryCallback(drawn(true), emu.callbackType.exec, SYM.sub_drawn, SYM.sub_drawn, SA, CM)
local function stats(name, d)           -- d: list of per-frame steps
  local n, jerk, big = 0, 0, 0
  for i = 2, #d do
    local j = math.abs(d[i] - d[i - 1]); n = n + 1; jerk = jerk + j; if j > big then big = j end
  end
  local sum, mx = 0, 0
  for i = 1, #d do sum = sum + math.abs(d[i]); if math.abs(d[i]) > mx then mx = math.abs(d[i]) end end
  print(string.format("  %-22s mean step %6.2f, largest %4d;  jerk mean %5.2f, largest %4d  (%d frames)", name, #d > 0 and sum / #d or 0, mx, n > 0 and jerk / n or 0, big, #d))
end
local prev = on_end
function on_end()
  if prev then prev() end
  local dpos, db9, db1, dz, dx = {}, {}, {}, {}, {}
  for i = 2, #fr do
    local a, b = fr[i - 1], fr[i]
    dpos[#dpos + 1] = (b.pos - a.pos + 400) % 800 - 400
    db9[#db9 + 1] = b.b9 - a.b9
    db1[#db1 + 1] = b.b1 - a.b1
  end
  -- objects: steps of each record while it holds the same thing, relative to the road's
  local oj, on, obig, ojx, obigx = 0, 0, 0, 0, 0
  for i = 3, #fr do
    local a, b, c = fr[i - 2], fr[i - 1], fr[i]
    for x, o in pairs(c.obj) do
      local p, q = b.obj[x], a.obj[x]
      if p and q and p.ty == o.ty and q.ty == o.ty then
        local d1, d2 = (o.z - p.z) - (q and (p.z - q.z) or 0), (o.x - p.x) - (p.x - q.x)
        if math.abs(d1) < 200 then
          on = on + 1; oj = oj + math.abs(d1); ojx = ojx + math.abs(d2)
          if math.abs(d1) > obig then obig = math.abs(d1) end
          if math.abs(d2) > obigx then obigx = math.abs(d2) end
        end
      end
    end
  end
  local subs = 0
  for _, f in ipairs(fr) do if f.sub > 0 then subs = subs + 1 end end
  print(string.format("smooth: %d frames drawn, %d of them in-between frames", #fr, subs))
  stats("along the road", dpos); stats("across ($B9)", db9); stats("horizon ($B1)", db1)
  print(string.format("  objects: jerk of distance mean %.2f, largest %d; of x mean %.2f, largest %d  (%d object-frames)",
    on > 0 and oj / on or 0, obig, on > 0 and ojx / on or 0, obigx, on))
  for i = 1, math.min(SM_LIST or 0, #fr) do
    local f = fr[i]
    print(string.format("  vb %d %s pos %d b9 %d b1 %d", f.vb, f.sub > 0 and ("+" .. f.sub) or "step", f.pos, f.b9, f.b1))
  end
end
