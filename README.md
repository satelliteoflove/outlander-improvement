# Outlander: SA-1 Improvement Patch

This patch adds the SA-1 chip to *Outlander* for the SNES, so the driving scenes run at 30
frames a second instead of about 8. It also speeds up the walking and improves the hit detection
in the on-foot scenes, which makes them somewhat less tedious and time consuming.

For the most part the game is as it always was, just with much smoother driving and faster
walking.

The idea came from SNES drunk's video *Is Outlander [SNES] Worth Playing Today?*
(https://www.youtube.com/watch?v=FHvH8xn5w-w), which lamented the game's poor framerate and
repetitive play, and noted that there wasn't an SA-1 improvement patch for it.

There's a video of the original and the patched game side by side on YouTube:
https://youtu.be/7QsA8cDBJ38

## What's changed

**Driving**

- The picture now runs at 30 frames a second. The busiest moments sometimes hold a frame a
  little longer.
- The driving now runs at a steady pace, which makes the first drive about 9% slower on average
  than it used to be. The next section explains why.
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

## Why the driving is a little slower on average

In the original, the game moves forward one step each time it finishes drawing a frame, and the
car covers the same ground per step however long that took. So the game's speed depended on the
frame rate. A frame took anywhere from 6 to 11 vblanks to draw (a vblank is a 60th of a second),
which is between 10 and about 5.5 frames a second. Quiet stretches of road ran faster, and busy
ones slowed down.

With the SA-1 drawing the frames, that link had to be cut, or the game would have run about four
times too fast. The patch shows 30 frames a second and moves the game forward once every four of
them, which is one step every 8 vblanks, all the time.

| Time per step | Steps a second | Patched game compared to that |
|---|---|---|
| 6 vblanks (the original's quietest) | 10 | 25% slower |
| 7.3 vblanks (the original's average on the first drive) | about 8.2 | about 9% slower |
| 8 vblanks (the patch) | 7.5 | |
| 11 vblanks (the original's busiest) | about 5.5 | about 38% faster |

So the 9% is an average over the first drive, which is mostly quiet road. Busier driving comes out
much closer: the attract demo, which is full of enemies and explosions, is only about 2% slower.
Apart from the gameplay changes listed above, each step still does what it did before, and only
the time between steps has changed.

### Why 8

The game shows a new frame at most every 2 vblanks, and there's only so much that can be sent to
the SNES's video memory in each one. So at 30 frames a second, a step has to last a whole number
of frames, which means 6, 8 or 10 vblanks.

| Time per step | Frames per step | First drive | Attract demo |
|---|---|---|---|
| 6 vblanks | 3 | about 22% faster | about 33% faster |
| **8 vblanks** | **4** | **about 9% slower** | **about 2% slower** |
| 10 vblanks | 5 | about 27% slower | about 20% slower |

8 is the closest of the three to how the original plays. At 6 the game would run much faster than
it was ever meant to, which would make it harder, and at 10 it would drag.

7 is possible only by alternating steps of 3 and 4 frames. It would land closer on the first drive,
at about 4% faster, but the car's speed on screen would keep shifting from one step to the next,
and busy scenes would run about 14% faster than they used to, with little processing time to spare.
A steady 8 keeps the motion even and stays closer to the original in the busiest driving.

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

Apply `outlander-sa1-improvement.bps` with a patcher that handles BPS, like Floating IPS (Flips)
or the web-based Rom Patcher JS. Lunar IPS won't do, since it only handles IPS. From a command
line:

```sh
flips --apply outlander-sa1-improvement.bps "Outlander (USA).sfc" "Outlander (SA-1 Improvement).sfc"
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

Thanks to Vitor Vilela, whose SA-1 conversions of other SNES games
([SA1-Root](https://github.com/VitorVilela7/SA1-Root)) showed how this kind of job can be done.
