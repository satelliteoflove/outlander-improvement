#!/bin/sh
# Record the coverage traces the build needs, from the original ROM:
#   build/cov.txt      everything the S-CPU executed (attract demo + two scripted drives)
#   build/cov_blk.txt  what executed inside the driving block ($00:8D12 to $00:8F14, or to its
#                      other exits $00:8E41 and $00:8D92)
# Takes a few minutes; the six emulator runs go in parallel.
set -e
cd "$(dirname "$0")/.."
P="$(pwd)/build/cov"; mkdir -p "$P"
DRIVE1="1000-1005:start;1310-:y"
DRIVE2="1000-1005:start;1310-:y;1320-7000:x;2440-2470:left;2600-2640:left;2700-2730:right;3000-3040:left;3300-3330:right;3600-3640:left;4000-4030:right"
run() {  # name frames input window
    echo "COV_PATH = \"$P/$1.txt\"; $4" > "$P/$1.lua"
    python3 tools/run.py Outlander.sfc --frames "$2" --input "$3" --lua "$P/$1.lua" --lua tools/cov.lua --out "$P/shots_$1" >/dev/null
}
W='COV_WINDOW = {0x008D12, 0x008F14, 0x008E41, 0x008D92}'
run demo 9000 "" "" &
run drive1 3000 "$DRIVE1" "" &
run drive2 7000 "$DRIVE2" "" &
run blk_demo 9000 "" "$W" &
run blk_drive1 3000 "$DRIVE1" "$W" &
run blk_drive2 7000 "$DRIVE2" "$W" &
wait
python3 tools/covmerge.py build/cov.txt "$P/demo.txt" "$P/drive1.txt" "$P/drive2.txt"
python3 tools/covmerge.py build/cov_blk.txt "$P/blk_demo.txt" "$P/blk_drive1.txt" "$P/blk_drive2.txt"
