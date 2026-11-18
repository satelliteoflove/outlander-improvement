# Outlander: SA-1 Improvement Patch

This patch adds the SA-1 chip to *Outlander* for the SNES, so the driving scenes run at 30
frames a second instead of about 8. It also speeds up the walking and improves the hit detection
in the on-foot scenes, which makes them somewhat less tedious and time consuming.

For the most part the game is as it always was, just with much smoother driving and faster
walking.

## What's changed

**Driving**

- The picture now runs at 30 frames a second. The busiest moments sometimes hold a frame a
  little longer.
- The driving now runs at a steady pace. In the original, the speed rose and fell with how much
  was on screen, so the first drive plays about 9% slower overall than it used to, though the
  busiest stretches run a little faster.
- There are about 28% fewer roadblocks in the lanes.
- Running into something standing, like a pole, a cactus or a roadblock, does about 30% less
  damage.

**On foot**

- He walks 1.5 times as fast, and his jump goes 1.5 times as far.
- His punch reaches 4 pixels further, about as far as his fist is drawn.
- Facing left, he can now hit an enemy standing right up against him, as he always could facing
  right.
- Two of the three enemy blows now have to come from closer on his left, under 40 pixels rather
  than 60.

## What hasn't changed

I didn't try to rebalance the game or do anything about its lack of variety, its scarce ammo and
supplies, its poisoned food and water, or most of the other complaints people have had about it.
It's still a hard game. The fewer roadblocks, lighter collisions and fairer hit detection do take
a little of the edge off, but that's as far as it goes.

The roads, art, music and story are all as they were. Apart from the changes above, each step of
the driving plays out the same as in the original.

The on-foot scenes already ran at 60 frames a second, so the SA-1 has nothing to do there. The
third enemy blow, a long straight punch, keeps its full range, since its fist really does reach
that far.

Between the game's steps the SA-1 draws three extra frames, which are predictions of where things
are going. If you change the steering partway through a step, the next step puts the picture
right, so there can be a small correction.

## Testing

**This has only been tested in emulators.** It hasn't been tried on a real SNES or a flash cart,
and I don't have anything that can run SA-1 games, so I can't say whether it works on real
hardware.

- Mesen 2 (2.1.1): I played the first drive and the first on-foot stage, and the sound was fine.
  The patch's automated tests also compare it against the original game here.
- bsnes-mercury (accuracy core, libretro) and Snes9x 1.63 (libretro): scripted runs through the
  attract demo, a drive and an on-foot stage. Nobody has played it by hand in these two, and the
  sound wasn't checked there.

## Applying the patch

You'll need your own copy of the US ROM, `Outlander (USA).sfc`, with no copier header. The patch
only applies to this exact file:

| | |
|---|---|
| Size | 1,048,576 bytes |
| CRC32 | `a978b36f` |
| MD5 | `8ae0a302b1312691aee276b91e9714bf` |
| SHA-1 | `4dd01cd2f950b70bd08a6b16115cd647c7147c04` |

Apply `outlander-sa1-improvement.xdelta` with any xdelta3 patcher. On Windows, Delta Patcher works fine. From
a command line:

```sh
xdelta3 -d -s "Outlander (USA).sfc" outlander-sa1-improvement.xdelta "Outlander (SA-1 Improvement).sfc"
```

The patched ROM should come out like this:

| | |
|---|---|
| Size | 4,194,304 bytes |
| CRC32 | `6f701fee` |
| MD5 | `42b8bd519d2fac04a32bfa83297e34dd` |
| SHA-1 | `08fd9e501dfcf5e402345dfcbb9e8d076c3536e0` |

## How this was made

I made this patch with Claude, Anthropic's AI model, working in Claude Code. Claude did the
reverse engineering and wrote the patch's code, its build and test tools, and the comparison
videos' tools. I set the goals, decided which gameplay changes to make and how far to take them,
played it, and pointed out what looked or felt wrong.

## Thanks

Thanks to Vitor Vilela, whose SA-1 conversions of other SNES games showed how this kind of job
can be done.
