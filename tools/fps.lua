-- Game frames completed in the driving main loop, reported per 300 vblanks.
-- A game frame = one pass through the loop head ($00:8CA3).
local n, hist, last = 0, {}, 0
emu.addMemoryCallback(function() n = n + 1 end, emu.callbackType.exec, 0x008CA3, 0x008CA3, emu.cpuType.snes, emu.memType.snesMemory)
local prev = on_frame
function on_frame(f)
  if prev then prev(f) end
  if f % 300 == 0 then
    print(string.format("vblank %5d: %3d game frames in the last 300 (%.1f fps)", f, n - last, (n - last) / 5.0))
    last = n
  end
end
