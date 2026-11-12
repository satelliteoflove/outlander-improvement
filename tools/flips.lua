-- How long each frame of the driving scene stays on show: vblanks from flip to flip.
-- FL_FROM = first vblank counted (default 1300), FL_TO = last (default: the end of the run).
local C, M = emu.cpuType.snes, emu.memType.snesMemory
local last, hist, n, tot = nil, {}, 0, 0
emu.addMemoryCallback(function()
  if FRAME < (FL_FROM or 1300) or (FL_TO and FRAME > FL_TO) then last = nil; return end
  if last then
    local d = FRAME - last
    hist[d] = (hist[d] or 0) + 1; n = n + 1; tot = tot + d
  end
  last = FRAME
end, emu.callbackType.exec, 0x0081C5, 0x0081C5, C, M)
local prev = on_end
function on_end()
  if prev then prev() end
  local keys = {}
  for d in pairs(hist) do keys[#keys + 1] = d end
  table.sort(keys)
  local t = {}
  for _, d in ipairs(keys) do t[#t + 1] = string.format("%d vblanks: %d", d, hist[d]) end
  print(string.format("frames shown: %d, mean %.2f vblanks (%.1f fps) | %s", n, n > 0 and tot / n or 0, n > 0 and 60 * n / tot or 0, table.concat(t, ", ")))
end
