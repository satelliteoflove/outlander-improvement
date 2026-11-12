-- Regression test for the on-foot (walking / fighting) scenes: the patched ROM must behave
-- exactly as the original there.
--
-- FOOT_MODE = "record" (on the original) or "check" (on a patched ROM); FOOT_PATH = data file;
-- FOOT_FRAMES = game frames to cover; FOOT_INPUT = { {from, to, {"right", ...}}, ... } with
-- times in vblanks counted from the anchor.
--
-- The anchor is the first pass through the on-foot main loop head ($90:824A) of the run.
-- record: saves all of work RAM at the anchor, then at every later pass every byte that
--         changed since the pass before.
-- check:  at its own anchor, replaces work RAM with the recorded one (the patched game gets
--         there at a different moment, because its driving scenes run faster), then compares
--         all of it at every pass and lists what differs.  Gives up after FOOT_MAX_BAD
--         differing passes (default 5).
-- Not compared: FOOT_MASK = {[addr] = true} (work RAM offsets).
-- FOOT_TIMING = {[addr] = true}: bytes that only say where in the frame the main loop was
-- when it was sampled.  The original game differs from its own recording in these, for a
-- frame or two at a time, when it merely reaches the scene at another moment (the length of
-- its waits on the sound CPU differs).  A pass that differs in nothing else is noted and
-- allowed, up to FOOT_TIMING_MAX passes (default 8), and none in the last 60.
local C, M, W = emu.cpuType.snes, emu.memType.snesMemory, emu.memType.snesWorkRam
local HEAD = 0x90824A
local SIZE = 0x20000
local mode, want = FOOT_MODE, FOOT_FRAMES or 1200
local mask = FOOT_MASK or {}
local anchored, vb0, n = false, 0, 0
local finished = false
function input_hook()
  if not anchored then return nil end
  local v, t = FRAME - vb0, {}
  for _, s in ipairs(FOOT_INPUT) do
    if v >= s[1] and v <= s[2] then for _, b in ipairs(s[3]) do t[b] = true end end
  end
  return t
end
local function regs()
  local s = emu.getState()
  return string.pack("<I2I2BB", s["cpu.sp"], s["cpu.d"], s["cpu.dbr"], s["cpu.ps"])
end
if mode == "record" then
  local f = assert(io.open(FOOT_PATH, "wb"))
  local cur = {}
  emu.addMemoryCallback(function()
    if finished then return end
    if not anchored then
      anchored = true; vb0 = FRAME
      local parts = {}
      for base = 0, SIZE - 1, 4096 do
        local t = {}
        for i = 0, 4095 do local b = emu.read(base + i, W); t[i + 1] = b; cur[base + i] = b end
        parts[#parts + 1] = string.char(table.unpack(t))
      end
      f:write(string.pack("<I4", want), regs(), table.concat(parts))
      print("on-foot scene reached at vblank " .. FRAME); return
    end
    n = n + 1
    local ch = {}
    for a = 0, SIZE - 1 do
      local b = emu.read(a, W)
      if b ~= cur[a] then cur[a] = b; ch[#ch + 1] = string.pack("<I4", (a << 8) | b) end
    end
    f:write(string.pack("<I4", #ch), table.concat(ch))
    if n == want then
      f:close(); finished = true
      print(string.format("recorded %d on-foot frames (%d vblanks) -> %s", n, FRAME - vb0, FOOT_PATH))
      emu.stop(0)
    end
  end, emu.callbackType.exec, HEAD, HEAD, C, M)
else
  local f = assert(io.open(FOOT_PATH, "rb")); local d = f:read("a"); f:close()
  local total = string.unpack("<I4", d)
  local pos = 5 + 6
  local exp = {}
  local bad, soft, last_soft = 0, 0, 0
  local timing = FOOT_TIMING or {}
  emu.addMemoryCallback(function()
    if finished then return end
    if not anchored then
      anchored = true; vb0 = FRAME
      if regs() ~= d:sub(5, 10) then print("  warning: registers at the anchor differ from the recording") end
      for a = 0, SIZE - 1 do local b = d:byte(pos + a); exp[a] = b; emu.write(a, b, W) end
      pos = pos + SIZE
      print("on-foot scene reached at vblank " .. FRAME .. "; recorded state put in place"); return
    end
    n = n + 1
    local cnt = string.unpack("<I4", d, pos); pos = pos + 4
    for i = 1, cnt do
      local v = string.unpack("<I4", d, pos); pos = pos + 4
      exp[v >> 8] = v & 0xFF
    end
    local list, k, hard = {}, 0, false
    for a = 0, SIZE - 1 do
      if emu.read(a, W) ~= exp[a] and not mask[a] then
        k = k + 1
        if not timing[a] then hard = true end
        if #list < 24 then list[#list + 1] = string.format("%05X %02X/%02X", a, emu.read(a, W), exp[a]) end
      end
    end
    if k > 0 and hard then
      bad = bad + 1
      print(string.format("  MISMATCH at on-foot frame %d: %d bytes, got/want: %s", n, k, table.concat(list, ", ")))
    elseif k > 0 then
      soft = soft + 1; last_soft = n
      print(string.format("  note: on-foot frame %d sampled at another point of the frame (%s)", n, table.concat(list, ", ")))
    end
    if n >= total or bad >= (FOOT_MAX_BAD or 5) then
      finished = true
      if soft > (FOOT_TIMING_MAX or 8) then bad = bad + 1; print("  too many passes with timing differences: " .. soft) end
      if soft > 0 and last_soft > total - 60 then bad = bad + 1; print("  timing difference near the end: did it recover?") end
      if bad > 0 then print("foot: FAILED"); EXIT_CODE = 1; emu.stop(1)
      else print(string.format("foot: %d on-foot frames identical to the original%s", n,
                 soft > 0 and string.format(" (%d with timing-only differences)", soft) or "")); emu.stop(0) end
    end
  end, emu.callbackType.exec, HEAD, HEAD, C, M)
end
local prev_end = on_end
function on_end()
  if prev_end then prev_end() end
  if not finished then print("foot: the run ended early (" .. n .. " frames)"); EXIT_CODE = 1 end
end
