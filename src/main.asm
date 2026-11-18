; Outlander SA-1 improvement patch.  Applied by tools/build.py to a 4 MB image:
;   block 0 = original game (S-CPU runs this),  block 1 = copy for the SA-1 (banks $20-$3F),
;   block 3 = this file's code (banks $A0-$BF).
asar 1.90
sa1rom 0,1,0,3

!FASTMATH ?= 1          ; 0 = the SA-1 runs the game's own multiply routines (for comparison)
!FASTSORT ?= 1          ; 0 = the SA-1 runs the game's own sort of the object list
!FASTROAD ?= 1          ; 0 = the SA-1 runs the game's own road loop
!FASTFLIP ?= 1          ; 0 = the game's own rule for when a finished frame may be shown
!BOTHALF ?= 1           ; 0 = leave the last slots' lower halves out of the upload (send_bot): tools/play.lua must fail
!OFFLOAD ?= 1           ; 0 = SA-1 enabled but idle (the game runs exactly as the original)
!PIPE ?= 1              ; 0 = the SA-1 only starts on a frame when the last one is on show
!SUB ?= 1               ; 0 = no in-between frames: every shown frame is a pass of the game's loop (4 times too fast)
!SUBMOVE ?= 1           ; 0 = in-between frames repeat the game step's frame (to test how they are drawn)
!TWEAKS ?= 1            ; 0 = the game plays as the original does (src/tweaks.asm); the tests need this
!NMIFIX ?= 1            ; 0 = the on-foot scene turns NMIs on whenever its set-up is done, as the game does

if !PIPE == 0
!SUB = 0                ; (in-between frames are built on pipelining's split of the block)
endif

incsrc "defs.asm"

; ---------------------------------------------------------------- header
org $00FFD5 : db $23            ; map mode: SA-1
org $00FFD6 : db $35            ; ROM + SA-1 + RAM + battery (what flash carts expect)
org $00FFD7 : db $0C            ; 4 MB
org $00FFD8 : db $06            ; 64 KB BW-RAM

; ---------------------------------------------------------------- reset hook
; The original reset code starts CLC / XCE / REP #$10 at $00:8000.  Hardware shows block 3 at
; bank $A0 from power-on (FXB defaults to 3), but Snes9x maps $80-$BF like $00-$3F until FXB
; is written, so FXB is set first, from the free space in block 0 (bank $02 is that block on
; both).  The registers are as reset leaves them: emulation mode, data bank 0.
org $008000
        assert read4($008000) == $10C2FB18
        JML set_fxb
reset_continue = $008004
org $02CD00
        assert read4($02CD00) == $FFFFFFFF
set_fxb:
        LDA.b #$83
        STA.l !SA1_FXB
        JML boot

; ---------------------------------------------------------------- hooks in the game (block 0)
if !OFFLOAD
org $008D12
        assert read4($008D12) == $81B0E422      ; JSL $81B0E4  (first call of the loop body)
        JSL blk_offload
org $008CDC
        assert read4($008CDC) == $81BD2F22      ; JSL $81BD2F  (pause)
        JSL pause_hook
org $008CD3
        assert read4($008CD3) == $008D80A9      ; LDA #$80 / STA $2100  (leaving the demonstration)
        JSL quit_hook
        NOP
org $0081D9
        assert read4($0081D9) == $048D7EA9      ; LDA #$7E / STA $4304
        JSL nmi_hdma0
        NOP
org $0081E8
        assert read4($0081E8) == $148D7EA9      ; LDA #$7E / STA $4314
        JSL nmi_hdma1
        NOP
org $008200
        assert read4($008200) == $BF0000A0      ; LDY #$0000 / LDA $7E2D36,X ...
        JSL nmi_copy_2d36
        db $80,$008211-$008206                  ; BRA $8211
org $0085B1
        assert read4($0085B1) == $748D7EA9      ; LDA #$7E / STA $4374
        JSL nmi_oam_bank
        NOP
org $00860D
        assert read4($00860D) == $BF0000A2      ; LDX #$0000 / LDA $7E2F36,X ...
        JSL nmi_oam_hi
        db $80,$00861B-$008613                  ; BRA $861B
org $008167
        assert read4($008167) == $90B33722      ; JSL $90B337
        JSL nmi_hud
org $008196
        assert read4($008196) == $BEC5BDA5      ; LDA $BD / CMP $BE
        JSL nmi_get_bd
if !FASTFLIP
org $008515
        assert read4($008515) == $DFA520C2      ; REP #$20 / LDA $DF
        JML nmi_piece
org $00850E
        assert read4($00850E) == $00A020C2      ; REP #$20 / LDY #$0400
        JSL nmi_last
        NOP
org $0081A0
        assert read4($0081A0) == $2082344C      ; JMP $8234 after the car's tiles were sent:
        JMP $81A3                               ; go on to a piece of the frame buffer if there is time
org $0081A6
        assert read4($0081A6) == $04C959A5      ; LDA $59 / CMP #$04
        JSL nmi_flipq
else
org $008515
        assert read4($008515) == $DFA520C2      ; REP #$20 / LDA $DF
        JSL nmi_get_df
endif
org $008575
        assert read4($008575) == $748D7EA9      ; LDA #$7E / STA $4374
        JSL nmi_fb_bank
        NOP
org $0081C5
        assert read4($0081C5) == $2E64C564      ; STZ $C5 / STZ $2E
        JSL nmi_flip
org $008C4E
        assert read4($008C4E) == $008DA1A9      ; LDA #$A1 / STA $4200
        JSL drive_init
        NOP
if !PIPE
org $008C54
        assert read4($008C54) == $02C92BA5      ; LDA $2B / CMP #$02 / BCC $8C54
        JML head_hook
        NOP #2
endif
endif

if !NMIFIX
org $908228
        assert read4($908228) == $8D0081A9      ; LDA #$0081 / STA $4200
        JSL foot_nmi_on
        NOP #2
endif

; ---------------------------------------------------------------- patches to the SA-1 copy (block 1)
incsrc "../build/blk_patch.asm"
incsrc "../build/hud_patch.asm"

; ---------------------------------------------------------------- new code (block 3)
org $A08000
incsrc "boot.asm"
incsrc "sa1.asm"
incsrc "offload.asm"
if !NMIFIX
; at $90:8228, over LDA #$0081 / STA $4200 (16-bit A): the on-foot scene's set-up, which ran
; with NMIs off for some 42 vblanks (it loads the scene and talks to the sound CPU, so
; how long it takes varies), turns them on again.  If that happens to be during the
; vertical blank, the NMI that was missed is taken on the spot, late: the handler turns the
; screen on and its first uploads to VRAM and OAM run on into the picture (seen at line 261,
; uploads on lines 1 to 12), where hardware ignores them.  The original has this too; when
; it happens depends on where in the frame the scene was left, which the patch changes.
; So: wait for the vertical blank to end and forget the NMI that was missed.
foot_nmi_on:
        PHP
        SEP #$20
-       LDA.l $004212
        BMI -
        LDA.l $004210
        PLP
        LDA #$0081
        STA.l $004200
        RTL
endif
if !PIPE
incsrc "pipe.asm"
if !SUB
incsrc "sub.asm"
endif
endif
if !FASTMATH
incsrc "fastmath.asm"
endif
if !FASTROAD
incsrc "road.asm"
incsrc "edges.asm"
endif
if !FASTSORT
incsrc "sort.asm"
endif
if !TWEAKS
incsrc "tweaks.asm"
endif

print "block 3 used up to $", pc
