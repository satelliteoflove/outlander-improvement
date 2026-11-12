; Pipelining: the SA-1 starts on the next frame while the last one waits to be shown.
;
; A frame cannot be shown before its frame buffer has been sent to VRAM, which only the
; vertical blank has time for: about $F40 bytes in the vblank that shows it, $1400 in one
; that does not.  The block draws into the frame buffer in its last third only.  Run as one
; piece after the previous frame was shown, it has nothing to send in the first vblank and
; everything in the second, and whenever that is too much the frame takes a third.
;
; So the block is split at $00:8EBA.  Before that point it works out the frame (the car,
; the road and its HDMA tables, the status display): 60% of its time, and nothing there
; touches the frame buffer or the sprite tables.  That part is started as soon as the
; frame before is drawn, without waiting for it to be shown.  The rest (objects, scaled
; sprites) waits for the S-CPU's word (!go_b) that the frame buffer is free again.  The
; frame buffer is then complete well before the first vblank after, and two vblanks carry
; any frame.
;
; What that takes:
;   * The loop head's part of the frame is done early as well: try_early, at the end of
;     blk_offload, samples the pad (or the demonstration's script) as $00:8C73 does and
;     gives the SA-1 the low RAM it would find after the frame that waits has been shown
;     ($2C, $2E, $C5, $019B: what the NMI handler changes when it shows a frame).  The head
;     itself (head_hook) then only waits for that frame and does the rest of its work.
;     Nothing is started early when Start is down or a fade is running: the head's ways out
;     to the map and to the title screen work as before.
;   * The NMI handler shows a frame with the block's HDMA tables, of which the game keeps
;     two pairs and alternates.  The first part of the next frame would overwrite the pair
;     still on show, so the S-CPU is given copies (sa1_split; two pairs of display buffers
;     at $40:1100) and their addresses in place of the block's $2F/$30 and $32/$33.  The
;     block itself works exactly as before, on the same memory.
;   * $80:9132, the fourth call of the block, moves the gauges' needles: it draws into the
;     head of the frame buffer and writes two sprites.  What it draws is drawn at the split
;     point instead (sa1_g_dry, g_deferred).  It reads only what the three calls before it
;     leave ($015E-$0160) and its own state ($015B-$015D), and nothing before the split
;     point reads what it draws.
;   * While the first part runs, the S-CPU has the finished frame's values of everything
;     (its own copy of low RAM: low_out), and how far the renderer has got and which picture
;     of the car is wanted are read from its own copy, not the SA-1's (!fb_sa1 is zero).
;
; The block tests (tools/test.py: block scenarios, xcheck) run with !pipe_dis set: each
; pass is then one piece from one state, as before.  The split point, the display buffers
; and the deferred call are in use there all the same.

; ---------------------------------------------------------------- SA-1 side
; at $20:8D1E, in place of JSL $209132.  The call is not simply left for later: the routine
; shares its scratch bytes ($012B-$0138) with the code that follows, which must find them
; as it always did.  So it runs here all the same, but from a second copy in which every
; store into $7E:2000-$7FFF goes nowhere (bank $A1, made by tools/build.py: "dry").  The
; real one, at the split point, is then given the same gauge positions to start from.
sa1_g_dry:
        PHP
        SEP #$20
        LDA.l $40015B
        STA.l !g_sav
        LDA.l $40015C
        STA.l !g_sav+1
        LDA.l $40015D
        STA.l !g_sav+2
        LDA.l $40015E           ; the routine draws nothing unless a gauge is to move
        CMP.l !g_sav
        BNE +
        LDA.l $40015F
        CMP.l !g_sav+1
        BNE +
        LDA.l $400160
        CMP.l !g_sav+2
        BNE +
        LDA #$00
        BRA ++
+       LDA #$01
++      STA.l !g_run
        PLP
        JML $A19132             ; (returns to $20:8D22)

; at $20:8EBA, in place of JSL $21B7E9
sa1_split:
        PHP
        REP #$30
        PHA
        PHX
        PHY
        PHB
        SEP #$20
        LDA #$01
        STA.l !a_done
-       LDA.l !go_b             ; the frame buffer and the sprite tables are the last frame's
        BEQ -                   ; until it has been shown
        JSR hdma_to_d
        JSR g_deferred
if !SUB
        REP #$30
        JSR pre_save            ; (src/sub.asm: what the in-between frames' second part starts from)
endif
        PLB
        REP #$30
        PLY
        PLX
        PLA
        PLP
        JML $21B7E9             ; (returns to $20:8EBE)

; Copy the two HDMA tables the road renderer has just built, from where they start ($2F,
; $32; they are built from the end of their buffers backwards) to the end, to the same
; place in a pair of display buffers.  Changes the data bank.
hdma_to_d:
        REP #$30
        LDA.l !d_sel
        AND #$0002
        TAX
        LDA $2F
        CMP #$22CB              ; the game's buffers: $2000 or $22CB
        BCC +
        SBC #$02CB
+       SEC
        SBC #$2000              ; how far into its buffer the table starts
        STA.l !d_t
        CLC
        ADC.l .t1,x
        STA.l !d_p1
        TAY
        LDA.w #!D_T1_LEN-1
        SEC
        SBC.l !d_t
        LDX $2F
        db $54,$40,$40          ; MVN $40 -> $40
        LDA.l !d_sel
        AND #$0002
        TAX
        LDA $32
        CMP #$2CEA              ; $2C9E or $2CEA
        BCC +
        SBC #$004C
+       SEC
        SBC #$2C9E
        STA.l !d_t
        CLC
        ADC.l .t2,x
        STA.l !d_p2
        TAY
        LDA.w #!D_T2_LEN-1
        SEC
        SBC.l !d_t
        LDX $32
        db $54,$40,$40
        SEP #$20
        LDA.l !d_sel
        EOR #$02
        STA.l !d_sel
        RTS
.t1     dw !D0_T1, !D1_T1
.t2     dw !D0_T2, !D1_T2

; The call of $80:9132 that was at $00:8D1E, for what it draws.
g_deferred:
        SEP #$20
        LDA.l !g_run
        BNE +
        RTS
+       REP #$30
        LDX #$000C
-       LDA.l $40012B,x         ; the scratch bytes as they are now
        STA.l !g_cur,x
        DEX
        DEX
        BPL -
        SEP #$20
        LDA.l !g_sav            ; the gauges as they were at $00:8D1E
        STA.l $40015B
        LDA.l !g_sav+1
        STA.l $40015C
        LDA.l !g_sav+2
        STA.l $40015D
        PEA $0000
        PLB
        PLB                     ; data bank 0, direct page 0 (as at $00:8D1E)
        JSL $209132
        REP #$30
        LDX #$000C
-       LDA.l !g_cur,x
        STA.l $40012B,x
        DEX
        DEX
        BPL -
        RTS

; The block is leaving the scene, which it only does before the split point: what the call
; of $80:9132 would have drawn is still owed, and may only be drawn when the last frame
; has been shown.  A 8 bit, X/Y 16 bit; the same on return, data bank = this bank.
exit_g:
-       LDA.l !go_b
        BEQ -
        REP #$20
        LDA #$0000
        TCD
        JSR g_deferred
        SEP #$20
        REP #$10
        PHK
        PLB
        RTS

pushpc
org $208D1E
        JSL sa1_g_dry
org $208EBA
        JSL sa1_split
pullpc

; ---------------------------------------------------------------- S-CPU side
; Called at the end of blk_offload when the block left by its normal exit: start the SA-1
; on the next frame's first part if nothing stands in the way.  A 8 bit, X/Y 16 bit, data
; bank = this bank; the same on return.
try_early:
        LDA.l !pipe_dis
        BNE .no
        LDA.l $000185           ; a fade to come, a fade running, the map or the title
        ORA.l $000183           ; screen on its way: the loop head has more to do than wait
        ORA.l $000186
        ORA.l $000187
        BEQ +
.no     RTS
.start  REP #$30                ; Start is down: the head decides what that means
        PLD
        PHK
        PLB
        SEP #$20
        RTS
+       REP #$30
        PHD
        LDA #$0000
        TCD
        PEA $0000
        PLB
        PLB                     ; direct page 0, data bank 0
        ; ---- what the loop head would put in $36 ($00:8C73)
        LDX $38
        SEP #$20
        LDA $047C
        REP #$20
        BEQ .pad
        PEA $0100               ; the demonstration: the next word of its script
        PLD
        LDA [$FD]
        PEA $0000
        PLD
        CPX #$0000
        BEQ +
        ORA #$1000
+       BIT #$1000
        BNE .start
        STA $36
        LDA $01FD
        CMP #$0368
        BEQ te_commit
        INC A
        INC A
        STA $01FD
        BRA te_commit
.pad    TXA
        BIT #$1000
        BNE .start
        STA $36
te_commit:
        ; ---- low RAM for the SA-1: as low_in, and then as the head and the NMI handler
        ; will have left it by the time the block would have started
        JSR low_in
        LDA #$0000
        STA.w !P0+$7E
        STA.w !P0+$DF
        LDA #$0004
        STA.w !P0+$C6
        LDA #$0008
        STA.w !P0+$DD
        STA.w !P0+$E3
        SEP #$20
        LDA #$00
        STA.w !P0+$2E
        STA.w !P0+$C5
        STA.w !clash_c5
.again
if !SUB
        LDA.l !sub_on           ; the frame that waits is an in-between frame: the step's
        BNE .shown              ; own was shown long ago, and no other switches $2C
endif
        LDA $C5                 ; has the frame that was just drawn been shown yet?
        BEQ .shown
        LDA $2C                 ; no: showing it will switch $2C and take over $0199
        EOR #$04
        STA.w !P0+$2C
        LDA $0199
        STA.w !P17+$019B
        LDA $C5                 ; (unless it was shown just now)
        BNE .ok
.shown  LDA $2C
        STA.w !P0+$2C
        LDA $019B
        STA.w !P17+$019B
.ok     REP #$30
        PLD
        PHK
        PLB
        JSR bank_bytes_to_sa1
        SEP #$20
        LDA #$00
        STA.l !fb_sa1           ; the frame that waits is complete: the S-CPU's $DF and $BD count
        STA.l !go_b
        STA.l !a_done
        LDA #$01
        STA.l !early
        STA.l !cmd
        RTS

; at $00:8C54, over LDA $2B / CMP #$02 / BCC $8C54: the main loop's head.  8-bit A, 16-bit
; X/Y, direct page 0, data bank 0.
head_hook:
        LDA.l !early
        BNE .early
-       LDA $2B
        CMP #$02
        BCC -
        JML $008C5A
.early  ; The SA-1 is at work on the next frame, and try_early has done the head's sampling
        ; of the pad.  Wait for the last frame to be shown as the head does, but in work RAM
        ; (see wait_sa1), then do the rest of the head.
        REP #$30
        LDX.w #.code
        LDY.w #!wram_head
        LDA.w #.end-.code-1
        db $54,$7E,$A0          ; MVN: bank $A0 -> bank $7E
        PEA $0000
        PLB
        PLB
        SEP #$20
        JSL !wram_head
        JML $008CA3
.code
-       LDA $2B
        CMP #$02
        BCC -
        STZ $2B
-       LDA $2E
        BNE -
-       LDA $C5
        BNE -
        RTL
.end

; The map or the title screen is about to take over although a frame was started early.
; That cannot happen (try_early starts nothing unless the head is bound for the block);
; if it ever does, let the SA-1 finish before its memory is taken away.
finish_early:
        LDA.l !early
        BEQ +
        LDA #$00
        STA.l !early
        LDA #$01
        STA.l !go_b
        JSR wait_sa1
        SEP #$20
+       RTS
