; S-CPU side of handing the driving scene's main loop body to the SA-1.
;
; "The block" is $00:8D12 to $00:8F14: everything the loop does for a frame after its head
; (which waits for the last frame to be shown and handles pausing).  The S-CPU copies the
; low RAM the two sides share to the SA-1, starts it, waits (interrupts stay on, so the
; game's NMI and IRQ handlers keep running), copies the shared low RAM back, sends the
; sound commands the block queued, and carries on in the original code where the SA-1 left
; the block.
;
; Low RAM: the SA-1 has its own copy of what the block uses.  All of it goes across when
; the scene starts and comes back when it ends or pauses (low_full_in, give_back); per
; frame only the bytes that the S-CPU's side of the scene (loop head, interrupt handlers)
; also uses are moved (low_in, low_out).  See low_tables() in tools/build.py.
;
; The rest of what the block uses, $7E:2000-$7FFF (road and object tables, HDMA tables,
; frame buffer), is not copied per frame at all: while the driving scene runs it lives in
; BW-RAM (!own), and the few things the interrupt handlers want from it they read there
; (nmi_* hooks below).  It is brought across when the scene is set up (drive_init) and
; taken back whenever the S-CPU is about to run anything else (sync_out).
;
; Nothing here may hold the S-CPU up for long.  The driving scene splits the screen with
; timed IRQs whose handlers must start within about 150 master clocks of the timer, so the
; per-frame copies are block moves (interruptible after every byte), never DMA (which stops
; the CPU until it is done).  tools/irqlat.lua measures this.
;
; What each side reads and writes in low RAM comes from static analysis (tools/mkpatch.py);
; the tables and the per-frame copy code are generated from it (build/blk_low.asm).

; DMA from work RAM (through the $2180 port on the B bus) to BW-RAM on the A bus.  Only for
; use with the screen off.  A 8 bit, X 16 bit, data bank with registers visible.
macro wram_to_bw(addr, len)
        LDX.w #<addr>
        STX $2181
        STZ $2183
        STX $4352
        LDA #$80                ; B bus -> A bus
        STA $4350
        LDX.w #<len>
        STX $4355
        LDA #$80
        STA $4351               ; B bus address: $2180
        LDA #$40
        STA $4354               ; A bus bank: BW-RAM
        LDA #$20
        STA $420B               ; channel 5: the game uses 0, 1, 2 and 7
endmacro

; Wait for the SA-1 to finish.  Whenever both CPUs use the ROM at the same moment the SA-1
; is held up, so the S-CPU must not wait in ROM: it runs a few bytes of code placed in WRAM
; ($7E:1F00; the game never touches $7E:0800-$1FFF) and polls only now and then.
; The loop is rewritten before every use in case anything ever clears that memory.
; A 8 bit, X/Y 16 bit.  Leaves the data bank at this bank.
!wram_wait = $7E1F00
!wram_head = $7E1F40            ; (head_hook, src/pipe.asm)
wait_sa1:
        REP #$20
        LDX.w #.code
        LDY.w #!wram_wait
        LDA.w #.end-.code-1
        db $54,$7E,$A0          ; MVN: bank $A0 -> bank $7E
        PHK
        PLB
        SEP #$20
        JSL !wram_wait
        RTS
.code
-       NOP #6
        LDA.l !cmd
        BNE -
        RTL
.end

; Copy low-RAM ranges between work RAM and the SA-1's copy: page 0 at $3000 (I-RAM), pages
; 1-7 at $40:0100.  X = table (this bank): dw start, length-1 ... ending with dw $FFFF.
; A/X/Y 16 bit, data bank = this bank.
macro copy_loop(src, dst, bias_x, bias_y)
-       LDA.w $0000,x
        CMP #$FFFF
        BEQ +
        PHX
        PHA
        CLC
        ADC.w #<bias_y>
        TAY
        LDA.w $0002,x           ; length-1
        PLX
        db $54,<dst>,<src>      ; MVN src -> dst
        PHK
        PLB
        PLX
        INX #4
        BRA -
+       RTS
endmacro
copy_p0_to_sa1:   %copy_loop($00, $00, 0, !P0)
copy_p17_to_sa1:  %copy_loop($00, $40, 0, 0)
copy_p17_from_sa1: %copy_loop($40, $00, 0, 0)
copy_p0_from_sa1:               ; (the source is the one with the offset here)
-       LDA.w $0000,x
        CMP #$FFFF
        BEQ +
        PHX
        TAY
        CLC
        ADC.w #!P0
        PHA
        LDA.w $0002,x
        PLX
        db $54,$00,$00
        PHK
        PLB
        PLX
        INX #4
        BRA -
+       RTS

; Give $7E:2000-$7FFF back to work RAM: about three frames of block move.  Changes the data
; bank; A 8 bit, X/Y 16 bit on return.  (The exits of the block that end the scene use this
; directly; the interrupt handlers' hooks go by !own from then on.)
sync_out:
        REP #$30
        LDX.w #!HI
        TXY
        LDA.w #!HI_LEN-1
        db $54,$7E,$40          ; MVN $40 -> $7E
if !PIPE
        LDX.w #!D_START         ; the HDMA tables on show are in the display buffers: the
        TXY                     ; PPU goes on reading them at the same addresses in work
        LDA.w #!D_LEN-1         ; RAM (which the game does not use there)
        db $54,$7E,$40
endif
        SEP #$20
        LDA #$00
        STA.l !own
        STA.l !fb_sa1
sync_out_end:
        RTS

incsrc "../build/blk_low.asm"

; All the block's low RAM to the SA-1.  A/X/Y 16 bit, data bank = this bank.
low_full_in:
        LDX.w #blk_low_in0
        JSR copy_p0_to_sa1
        LDX.w #blk_low_in
        JSR copy_p17_to_sa1
        RTS

; All the low RAM the block writes back to the S-CPU.  The same.
low_full_out:
        LDX.w #blk_low_out0
        JSR copy_p0_from_sa1
        LDX.w #blk_low_out
        JSR copy_p17_from_sa1
        RTS

; Pointers into $7E that the block uses: the SA-1's code wants bank byte $40/$41 in them,
; the S-CPU's $7E/$7F.  A/X/Y 16 bit, data bank = this bank.
bank_bytes_to_sa1:
        LDX #$0000
-       LDA.w blk_low_bank,x
        CMP #$FFFF
        BEQ ++
        PHX
        TAX
        SEP #$20
        LDA.l $400000,x
        AND #$FE
        CMP #$7E
        BNE +
        LDA.l $400000,x
        SEC
        SBC #$3E
        STA.l $400000,x
+       REP #$20
        PLX
        INX #2
        BRA -
++      RTS
bank_bytes_back:
        LDX #$0000
-       LDA.w blk_low_bank,x
        CMP #$FFFF
        BEQ ++
        PHX
        TAX
        SEP #$20
        LDA.l $000000,x
        AND #$FE
        CMP #$40
        BNE +
        LDA.l $000000,x
        CLC
        ADC #$3E
        STA.l $000000,x
+       REP #$20
        PLX
        INX #2
        BRA -
++      RTS

; The S-CPU is about to run something other than the scene's loop head: give it back all
; the SA-1 has, low RAM and $7E:2000-$7FFF.  Any register sizes; leaves A 8 bit, X/Y 16
; bit and changes the data bank.
give_back:
        REP #$30
        PHK
        PLB
        JSR low_full_out
        JSR bank_bytes_back
        JSR sync_out
        LDA #$7E                ; the HDMA tables on show: from work RAM again
        STA.l $004304
        STA.l $004314
        RTS


; ---------------------------------------------------------------- the block
; Replaces JSL $81B0E4 at $00:8D12.  Does not return there: it returns to wherever the
; SA-1 left the block, with the SA-1's registers.
blk_offload:
        PHP
        REP #$30
        STA.l !en_a
        TXA
        STA.l !en_x
        TYA
        STA.l !en_y
        SEP #$20
        PLA
        STA.l !entry_p
        PHB
        PHK
        PLB
        SEP #$20
if !PIPE
        LDA.l !early
        BEQ +
        LDA #$00                ; the SA-1 has had this frame's first part since the last
        STA.l !early            ; one was drawn (try_early); now that one has been shown
        STA.l !fb_safe
        STA.l !fb_safe+1
        LDA #$01
        STA.l !fb_sa1
        STA.l !go_b
        JMP blk_wait
+
endif
        LDA.l !own
        BNE +
        REP #$30                ; the first frame of the scene, or after a pause: everything
        JSR low_full_in
        LDX.w #!HI              ; (this part is normally done by drive_init)
        TXY
        LDA.w #!HI_LEN-1
        db $54,$40,$7E          ; MVN $7E -> $40
        SEP #$20
        LDA #$01
        STA.l !own
        LDA #$40                ; the HDMA tables on show: from the copy (as in drive_init)
        STA.l $004304
        STA.l $004314
+       REP #$30
        PHD
        LDA #$0000
        TCD
        PEA $0000
        PLB
        PLB                     ; data bank 0
        JSR low_in
        PLD
        PHK
        PLB
        JSR bank_bytes_to_sa1
        SEP #$20
        LDA #$00
        STA.l !snd_n
        STA.l !a_done
        STA.l !fb_safe
        STA.l !fb_safe+1
        LDA #$01
        STA.l !fb_sa1
        STA.l !go_b
blk_run:                        ; (labels here and below are marks for tools/timeline.lua)
        STA.l !cmd
blk_wait:
        JSR wait_sa1
blk_back:
        REP #$30
        LDA.l !ex_id            ; what the SA-1 left: kept apart, because the SA-1 may be
        STA.l !rx_id            ; started again before the end of this routine
        LDA.l !ex_db
        STA.l !rx_db
        LDA.l !ex_a
        STA.l !rx_a
        LDA.l !ex_x
        STA.l !rx_x
        LDA.l !ex_y
        STA.l !rx_y
if !PIPE
        LDA.l !rx_id
        AND #$00FF
        BNE +
        LDA.l !d_p1             ; the HDMA tables of this frame: the copies (sa1_split).
        STA.l $00002F           ; Before low_out, which sets $C5: from then on the NMI
        LDA.l !d_p2             ; handler may show the frame
        STA.l $000032
+
endif
if !SUB
        SEP #$20
        LDA #$00                ; (a game step's frame: the flip switches $2C, nmi_flip)
        STA.l !x_show
        REP #$20
endif
        PHD
        LDA #$0000
        TCD
        PEA $0000
        PLB
        PLB
        JSR low_out
        PLD
        PHK
        PLB
        SEP #$20
        LDA #$00                ; the S-CPU's $DF is the finished frame's now, and the SA-1's
        STA.l !fb_sa1           ; may be the next frame's any moment (try_early)
        LDA.l !rx_id
        REP #$20
        BEQ +
        JSR low_full_out        ; the block left the scene: the S-CPU needs everything back
+       JSR bank_bytes_back
        ; ---- sound commands the block queued: out of the SA-1's way first
        SEP #$20
        LDX #$0000
-       TXA
        CMP.l !snd_n
        BCS +
        LDA.l !snd_q,x
        STA.l !snd_q2,x
        INX
        BRA -
+       LDA.l !snd_n
        STA.l !snd_n2
        LDA #$00
        STA.l !snd_n
if !PIPE
        LDA.l !rx_id
        BNE +
if !SUB
        JSR sub_frames          ; three in-between frames (src/sub.asm)
endif
        JSR try_early           ; the SA-1 can start on the next frame
+
endif
        JSR snd_replay
        ; ---- the block left the scene: the S-CPU needs everything back
        LDA.l !rx_id
        BEQ +
        JSR sync_out
+       ; ---- carry on where the SA-1 stopped
        PLB                     ; (balance the PHB above; replaced just below)
        REP #$30
        LDA.l !rx_id
        AND #$00FF
        ASL
        TAX
        LDA.l blk_exits,x
        STA 1,s                 ; return address (the bank on the stack is already $00)
        LDA.l !rx_y
        TAY
        LDA.l !rx_x
        TAX
        SEP #$20
        LDA.l !rx_db            ; the SA-1's data bank, as the S-CPU would have it
        CMP #$20
        BCC ++                  ; $00-$1F: the same
        CMP #$40
        BCC +
        CLC
        ADC #$3E                ; $40/$41 (BW-RAM) -> $7E/$7F
        BRA ++
+       CLC
        ADC #$60                ; $20-$3F (the copy) -> $80-$9F
++      PHA
        PLB
        LDA.l !entry_p          ; status: the SA-1's, but with the S-CPU's interrupt mask
        AND #$04
        STA.l !rx_t
        LDA.l !rx_p
        AND #$FB
        ORA.l !rx_t
        PHA
        REP #$20
        LDA.l !rx_a
        PLP
blk_ret:
        RTL
blk_exits:
        dw $8F14-1, $8E41-1, $8D92-1

; Send the sound commands the block queued (once: the queue is emptied).  8-bit A, 16-bit
; X/Y, data bank = this bank.
snd_replay:
        LDX #$0000
-       TXA
        CMP.l !snd_n2
        BCS +
        PHX
        REP #$20
        LDA.l !snd_q2+1,x
        TAY
        SEP #$20
        LDA.l !snd_q2,x
        JSL $81DB9E
        SEP #$20
        REP #$10
        PLX
        INX #3
        BRA -
+       LDA #$00
        STA.l !snd_n2
        RTS

; at $00:8CDC, over JSL $81BD2F: the main loop's head is about to run the pause code
pause_hook:
        PHP
        REP #$30
        PHA
        PHX
        PHY
        PHB
        SEP #$20
        LDA.l !own
        BEQ +
if !PIPE
        JSR finish_early
endif
        JSR give_back
+       REP #$30
        PLB
        PLY
        PLX
        PLA
        PLP
        JML $81BD2F

; at $00:8CD3, over LDA #$80 / STA $2100: Start was pressed during the demonstration and
; the loop head is about to jump to the title screen's code (8-bit A, 16-bit X/Y)
quit_hook:
        LDA #$80
        STA.l $002100
        PHX
        PHY
        PHB
        LDA.l !own
        BEQ +
if !PIPE
        PHK
        PLB
        JSR finish_early
endif
        JSR give_back
+       REP #$10
        SEP #$20
        PLB
        PLY
        PLX
        LDA #$80
        RTL

; ---------------------------------------------------------------- NMI handler hooks
; The game sends the frame buffer to VRAM a piece at a time from its NMI handler, starting
; while the renderer is still drawing: $DF is how far the renderer has got, $E1 how far the
; upload has.  With the renderer on the SA-1, both $DF and the pixels are in BW-RAM.

; at $00:81D9 and $00:81E8, over LDA #$7E / STA $4304 (and $4314): the bank of the two HDMA
; tables the road renderer built, set when a new frame is shown
nmi_hdma0:
        LDA.l !own
        BEQ +
        LDA #$40
        BRA ++
+       LDA #$7E
++      STA.w $4304
        RTL
nmi_hdma1:
        LDA.l !own
        BEQ +
        LDA #$40
        BRA ++
+       LDA #$7E
++      STA.w $4314
        RTL

; at $00:8200, in place of a loop that copies 8 bytes from $7E:2D36,X (a table the block
; fills in) to $01B6.  8-bit A, 16-bit X/Y; X = offset into the table.
nmi_copy_2d36:
        LDY #$0000
        LDA.l !own
        BEQ .wram
if !SUB
        LDA.l !x_show           ; an in-between frame's sprite table is a copy (src/sub.asm)
        BEQ +
-       LDA.l $400000+!ST_D,x
        STA $01B6,y
        INX
        INY
        CPY #$0008
        BNE -
        RTL
+
endif
-       LDA.l $402D36,x
        STA $01B6,y
        INX
        INY
        CPY #$0008
        BNE -
        RTL
.wram
-       LDA.l $7E2D36,x
        STA $01B6,y
        INX
        INY
        CPY #$0008
        BNE -
        RTL

; at $00:85B1, over LDA #$7E / STA $4374: source bank of the sprite table upload at flip
nmi_oam_bank:
        LDA.l !own
        BEQ +
if !SUB
        LDA.l !x_show           ; an in-between frame's sprite table is a copy (src/sub.asm)
        BEQ .game
        LDA.b #!ST_D
        STA.w $4372
        LDA.b #!ST_D>>8
        STA.w $4373
.game
endif
        LDA #$40
        BRA ++
+       LDA #$7E
++      STA.w $4374
        RTL

; at $00:860D, in place of the loop that sends the sprites' size and high-X bits from
; $7E:2F36 to OAM a byte at a time (three scanlines of the vertical blank for 33 bytes).
; Sent by DMA instead, on the channel the routine has just used for the rest of the sprite
; table.  8-bit A, 16-bit X/Y; Y = bytes - 1.  Leaves X and Y as the loop did.
nmi_oam_hi:
        INY
        STY.w $4375
        LDX #$2F36
if !SUB
        LDA.l !own
        BEQ +
        LDA.l !x_show
        BEQ +
        LDX.w #!ST_D+$0200
+
endif
        STX.w $4372
        LDA.l !own
        BEQ +
        LDA #$40
        BRA ++
+       LDA #$7E
++      STA.w $4374
        STZ.w $4370             ; one register, source address counting up
        LDA #$04
        STA.w $4371
        LDA #$80
        STA.w $420B
        TYX
        LDY #$FFFF
        RTL

; at $00:8167, over JSL $90B337: the status display's part of the NMI handler.  It uploads
; (and in one case fills) buffers at $7E:78BD-$7B1C, which in the driving scene are the
; block's and live in BW-RAM.  The routine is shared with the on-foot scenes, so it is not
; touched: here the S-CPU runs the copy of it in banks $30/$38 instead, in which the bank
; bytes of its pointers are BW-RAM's (build/hud_patch.asm) and the fill is done by hand
; (sa1_fill_7abd, which suits either CPU).  16-bit A, which the routine reloads at once.
nmi_hud:
        PHP
        SEP #$20
        LDA.l !own
        BEQ +
        PLP
        JML $30B337
+       PLP
        JML $90B337

; at $00:8515, over REP #$20 / LDA $DF
nmi_get_df:
        REP #$20
        LDA.l !fb_sa1
        AND #$00FF
        BEQ +
        LDA.l !fb_safe          ; of the frame being drawn: what is finished (obj_next)
        RTL
+       LDA $DF
        RTL

; at $00:8196, over LDA $BD / CMP $BE (8-bit A; the handler sends the car's tiles if they
; differ).  $BD is the picture of the car the block wants shown; a new one is $600-$6C0
; bytes of tiles from the ROM, ten lines of the vertical blank.  On the original they are
; sent as soon as the block has written $BD, *instead of* that vblank's piece of the frame
; buffer.  Here a piece follows if there is time (the JMP at $00:81A0 is patched), and
; nmi_piece budgets by the beam, so the tiles can never make an upload late; but they can
; make a frame miss the vblank it would have been shown in.  So:
;   * $BD is read from the SA-1's copy, which has it a frame before the S-CPU's;
;   * the tiles are only sent in a vblank that has room for them and for what there is of
;     the frame buffer to send; otherwise they wait, four vblanks at most (!car_wait).
nmi_get_bd:
        LDA.l !own
        BNE +
        LDA $BD
        CMP $BE
        RTL
+
        LDA.w !P0+$BD
        CMP $BE
        BEQ .none
        REP #$20
        LDA.l !fb_sa1           ; what is waiting to be sent: of the frame being drawn...
        AND #$00FF
        BEQ +
        LDA.l !fb_safe
        BRA ++
+       LDA $DF                 ; ...or of the complete one
++      SEC
        SBC $E1
        TAX
        SEP #$20
        LDA $C5
        BEQ .draw               ; no complete frame: room for $1480 in this vblank
        REP #$20
        TXA                     ; a complete one: the last slot too, and the last slots'
        CLC                     ; lower halves (send_bot)
        ADC #$0040
        TAX
        LDA.l !bot_done
        BNE +
        LDA $DF
        AND #$03FF
        CLC
        ADC.w #$0040+!BOT_OVH
        STA.l !nmi_bot
        TXA
        CLC
        ADC.l !nmi_bot
        TAX
+       SEP #$20
        LDA.l !vb_since
        BEQ .draw               ; one that cannot be shown yet: the same
        CPX #$0801              ; one that can: room for $F40
        BCS .wait
        BRA .send
.draw   CPX #$0DC1
        BCC .send
.wait   LDA.l !car_wait         ; not now, unless it has waited four vblanks already
        INC A
        STA.l !car_wait
        CMP #$05
        BCS .send
        LDA #$00
        XBA
        LDA #$00                ; equal
        RTL
.send   LDA #$00
        STA.l !car_wait
        XBA                     ; (the handler counts on a zero in the high byte of A)
        LDA.w !P0+$BD
        CMP $BE                 ; not equal, and A = the picture wanted
        RTL
.none   LDA #$00
        STA.l !car_wait
        RTL                     ; (A = 0 and equal)

; at $00:8575, over LDA #$7E / STA $4374 (source bank of the upload)
nmi_fb_bank:
        LDA.l !own
        BEQ +
        LDA #$40
        BRA ++
+       LDA #$7E
++      STA $4374
        RTL

; at $00:81C5, over STZ $C5 / STZ $2E (the frame is complete and has been shown)
nmi_flip:
        STZ $C5
        STZ $2E
if !SUB
        LDA.l !x_show           ; an in-between frame (src/sub.asm): the game must not find
        BEQ +                   ; $2C switched for it, which the handler does next
        LDA $2C
        EOR #$04
        STA $2C
+
endif
        LDA #$00
        STA.l !fb_sa1
        STA.l !vb_since
        RTL

; at $00:81A6, over LDA $59 / CMP #$04 (the BCC that follows goes on to show the frame if
; it is complete): not if nmi_piece said no
nmi_flipq:
        LDA.l !no_flip
        BNE +
        LDA $59
        CMP #$04
        RTL
+       SEC
        RTL

; ---- how much of the frame buffer to send in this vblank, and whether to flip
; The game's rule ($00:8515): send what has been drawn, in whole $400s, at most $C00 a
; vblank; flip only in a vblank that had under $400 left to send when it began (the rest
; goes as a fixed $400 "last piece").  That is safe at any speed but slow: a finished frame
; of $1000 bytes takes two more vblanks to appear, and a new picture of the car, sent in
; place of a piece, another.  With the block on the SA-1 these waits are a third of the
; frame time.
;
; Video memory can only be written until the vertical blank ends (line 261), and what else
; the handler has to do there is known (measured on the original; tools/vbudget.lua checks
; the result):
;   from the flip decision to $00:8234:  the last piece, then up to 8.1 lines (sprites);
;                    5.5 here, where nmi_oam_hi sends the last 33 bytes by DMA
;   after $00:8234:  up to 9.6 lines of gauge animation (seen in tools/test.py play_drive;
;                    6.1 in the demo), but only in a vblank that leaves $59 at zero, which
;                    the game does when it sent no piece
; The sums below are in bytes at 170 a line and take code for free, which it is not: this
; routine takes 1.5 lines to decide and every transfer's set-up most of one, so what is
; estimated to end at line 251 ends near 255, and the sprites take 6 lines more.  The limits
; allow for that (the worst seen in the tests leaves 1.1 lines; by these sums no case leaves
; under 1).
; So ask the PPU where the beam is and send what fits:
;   frame complete, and all of it fits before line 240:  send it and flip
;   ... fits before line 251:  the same, and put the gauge animation off to the next vblank
;       ($59 = 1: under 4 for the flip test at $00:81A6, not zero for the test at $00:8277)
;   otherwise:  what has been drawn, as far as it ends before line 258 (not in whole $400s
;       as the game does: everything below $DF is final, or the game's own upload would
;       not work either; tools/play.lua compares VRAM with the frame buffer at every
;       flip), no flip (!no_flip, which
;       nmi_flipq puts in front of the game's test at $00:81A6); the gauge animation may run
;       if the piece ends before line 244
; A frame is never shown one vblank after the last (!vb_since).  The loop head's wait for
; two NMIs saw to that while the block could only start when the last frame was on show;
; with pipelining (src/pipe.asm) a small frame can be complete and sent a vblank later.
; (A byte takes 8 master clocks of a line's 1364: 170 bytes a line.  The latch may be up
; to a line behind the beam.  The game does not use the latch itself.)
;
; at $00:8515 (JML): replaces the head of the routine; goes back into it at $00:852B with
; A = bytes to send, or to its exit.
nmi_piece:
        REP #$20
        LDA.l !fb_sa1
        AND #$00FF
        BEQ +
        LDA.l !fb_safe          ; how far the renderer has got: what it has finished (obj_next)
        BRA ++
+       LDA $DF
++      SEC
        SBC $E1
        BCS +                   ; (the loop head clears $DF and then $E1: between the two,
        LDA #$0000              ; nothing is waiting)
+       STA $5A                 ; drawn and not yet sent ($5A: scratch here)
        SEP #$20
        LDA $C5
        BEQ +
        REP #$20                ; a complete frame: up to the end of its last slot
        %df_done()              ; (send_bot, below)
        CLC
        ADC #$0040
        SEC
        SBC $E1
        BCS ++
        LDA #$0000
++      STA $5A
        SEP #$20
+       LDA.l !vb_since         ; vblanks since a frame was shown, counting this one
        INC A
        BNE +
        DEC A
+       STA.l !vb_since
        LDA #$01
        STA.l !no_flip
        LDA.w $2137             ; latch the beam position
        LDA.w $213F             ; (resets the low/high byte toggle of the latch)
        LDA.w $213D
        XBA
        LDA.w $213D
        AND #$01
        XBA
        REP #$20                ; A = line
        CMP.w #225
        BCS +
        LDA.w #262              ; not in the vertical blank at all: nothing fits
+       STA $58
        LDA.w #251-1
        SEC
        SBC $58
        BCS +
        LDA #$0000
        STA.l !nmi_t
        BRA .noflip
+       JSR .x170
        STA.l !nmi_t            ; what can be sent before line 252
        SEP #$20
        LDA $C5
        BEQ .noflip8            ; the frame is not complete
        LDA.l !vb_since
        CMP #$02
        BCC .noflip8            ; the last one has been on show for a single vblank
        REP #$20
        LDA.l !bot_done         ; the last slots' lower halves (send_bot, below) have to go too
        BEQ +
        LDA #$0000
        BRA ++
+       %df_done()
        AND #$03FF
        CLC
        ADC.w #$0040+!BOT_OVH   ; (in bytes' worth of time)
++      CLC
        ADC $5A
        STA.l !nmi_fit          ; all that has to go before the frame can be shown
        LDA.l !nmi_t
        CMP.l !nmi_fit
        BCC .noflip             ; does not all fit
        LDY #$0000              ; fits: is there room for the gauge animation too?
        SBC.w #12*170           ; (carry is set)
        BCC +
        CMP.l !nmi_fit
        BCS ++
+       LDY #$0100
++      STY $58                 ; $59 = 0 or 1
        SEP #$20
        LDA #$00
        STA.l !no_flip
        REP #$20
        LDA $5A
        AND #$FC00              ; (the rest is sent as the last piece, nmi_last)
        BNE +
        JML $00858D
+       JML $00852B
.noflip8
        REP #$20
.noflip LDA.w #258-1
        SEC
        SBC $58
        BCS +
        LDA #$0000
+       JSR .x170
        STA.l !nmi_fit
        AND #$FFC0
        TAY                     ; what fits
        LDA $5A
        AND #$FFC0              ; (whole tiles, as the renderer counts)
        STA $5A
        CPY $5A
        BCS +
        TYA
+       TAY                     ; A = Y = the piece
        CPY $5A                 ; a complete frame of which this piece is the rest: its last
        BNE .nobot              ; slots' lower halves as well, if they fit, and the vblank
        LDA $C5                 ; that shows the frame has them off its hands
        AND #$00FF
        BEQ .nobot
        LDA.l !bot_done
        BNE .nobot
        %df_done()
        AND #$03FF
        CLC
        ADC.w #$0040+!BOT_OVH
        STA.l !nmi_bot
        TYA
        CLC
        ADC.l !nmi_bot
        CMP.l !nmi_fit
        BEQ +
        BCS .nobot
+       PHY
        JSR send_bot
        PLY
        LDA #$0001
        STA.l !bot_done
        TYA
        CLC
        ADC.l !nmi_bot
        BRA +
.nobot  TYA
+       CLC                     ; room for the gauge animation after it?
        ADC.w #8*170
        BCS .busy
        CMP.l !nmi_t
        BEQ .calm
        BCS .busy
.calm   LDA #$0000
        BRA +
.busy   LDA #$FF00
+       STA $58                 ; $59 = 0: the animation may run; $FF: not in this vblank
        TYA
        BEQ .out
        JML $00852B
.out    JML $00858D
.x170   PHX                     ; A = lines (37 at most) -> bytes that can be sent in them
        ASL A                   ; (from a table: this code runs at the head of the vertical
        TAX                     ; blank, where a multiplication costs a third of a line)
        LDA.l .bytes,x
        PLX
        RTS
.bytes  dw 0,170,340,510,680,850,1020,1190,1360,1530,1700,1870,2040,2210,2380,2550,2720,2890,3060
        dw 3230,3400,3570,3740,3910,4080,4250,4420,4590,4760,4930,5100,5270,5440,5610,5780,5950,6120,6290

; The frame's last slot, and the lower halves of its last slots.  The renderer draws into
; slots of 16 x 16 pixels, eight to a $400 of the frame buffer: a slot's upper two tiles,
; $40 bytes, and its lower two $200 further on.  $DF is where the upper tiles of the slot
; allocated *last* are (the table at $80:DE02, by $DD - 2; with none allocated in this
; frame $DF is 0 and the last slot in use is the fourth, at $C0: the gauges' needles).
;   * While a frame is drawn, a slot below $DF is not final either: an object of several
;     slots allocates them all and then draws.  So the SA-1 says how far it has finished
;     whenever the object pass has done with an object (obj_next -> !fb_safe), and the
;     pieces go that far, not to its live $DF.  (Seen once in the demo's 1,740 frames
;     before that: two slots of a tall object sent half-drawn, and shown.)
;   * Of a complete frame the $400 that $DF stands in, at R = $DF & $FC00, holds upper
;     halves up to $DF + $40 and lower halves from R + $200 up to $DF + $240, and sending
;     "up to $DF" leaves the last slot and all those lower halves out.  The game's last
;     piece is a whole $400 and takes them along.  Here the last pieces go up to $DF + $40,
;     and the lower halves are sent by themselves, once per frame (!bot_done): with the
;     piece that completes the frame if it cannot be shown yet (nmi_piece), or else before
;     the flip (nmi_last).  Left out, the last sprite drawn and the lower halves of up to
;     seven before it showed what the frame before last had there.
; tools/play.lua compares every tile of every sprite shown with the frame buffer.
; A transfer by itself costs about a line besides its bytes (this routine and the set-up of
; the game's own at $00:852C are slow code): !BOT_OVH, in bytes at 170 a line, is added
; wherever nmi_piece and nmi_get_bd ask whether the lower halves fit.
; Only of a complete frame ($C5 set: then $DF is the S-CPU's own again).  16-bit A; changes A.
send_bot:
if !BOTHALF == 0
        RTS
endif
        %df_done()
        AND #$03FF
        CLC
        ADC #$0040
        STA.w $4375             ; how much
        %df_done()
        AND #$FC00
        ORA #$0200
        PHA
        CLC
        ADC.w #!FB
        STA.w $4372             ; from where
        PLA
        LSR A
        ORA #$4000              ; to which word of video memory: the page not on show,
        PHA                     ; as at $00:8533
        SEP #$20
        LDA $DC
        BEQ +
        LDA 2,s
        ORA #$20
        STA 2,s
+       REP #$20
        PLA
        STA.w $2116
        SEP #$20
        STZ.w $420B
        LDA #$01
        STA.w $4370
        LDA #$18
        STA.w $4371
        LDA.l !own
        BEQ +
        LDA #$40
        BRA ++
+       LDA #$7E
++      STA.w $4374
        LDA #$80
        STA.w $420B
        REP #$20
        RTS

; at $00:850E, over REP #$20 / LDY #$0400: the last piece, sent just before the flip.  The
; game always sends $400 bytes; send what is left (six scanlines saved at most), and the
; last slots' lower halves if they have not gone yet.
nmi_last:
        REP #$20
        LDA.l !bot_done
        BNE +
        JSR send_bot
+       LDA #$0000
        STA.l !bot_done
        %df_done()
        CLC
        ADC #$0040              ; (the slot at $DF is the frame's last)
        SEC
        SBC $E1
        BEQ +                   ; (nothing left: a transfer cannot be empty)
        BCS ++
+       LDA #$0040
++      CMP #$0401
        BCC +
        LDA #$0400
+       TAY
        RTL

; ---------------------------------------------------------------- scene set-up hook
; at $00:8C4E, over LDA #$A1 / STA $4200: the last step of setting up the driving scene
; before its main loop.  Everything in $7E:2000-$7FFF was just prepared in work RAM and
; the screen is still off, so this is the place (and the only one) for a DMA copy.  From
; here until the scene ends or pauses the SA-1's copies are the ones that count.
drive_init:
        PHP
        PHB
        PHK
        PLB
        SEP #$20
        REP #$10
        PHX
        PHY
        %wram_to_bw(!HI, !HI_LEN)
        REP #$20
        JSR low_full_in         ; and all the low RAM the block uses
        SEP #$20
        PLY
        PLX
        LDA #$40                ; the HDMA tables set up for the first frame: read them
        STA $4304               ; from the copy too, since the block updates one in place
        STA $4314
        LDA #$01
        STA.l !own
        LDA #$00
        STA.l !fb_sa1
        STA.l !early
        STA.l !bot_done
        STA.l !bot_done+1
        LDA #$FF
        STA.l !sh_slot          ; (src/sub.asm: no record is moved for drawing)
        STA.l !sh_slot+1
        LDA #$00
if !SUB
        STA.l !sub_on
        STA.l !x_show
        STA.l !cap_n
endif
        PLB
        PLP
        LDA #$A1
        STA.l $004200
        RTL

; at $20:9F1A, over LDA $A5 / CLC / ADC #$0002: the object pass goes on to the next object
; (with in-between frames src/sub.asm has the hook, sbx_next, and marks there)
if !PIPE*!SUB == 0
obj_next:
        %fb_mark()
        LDA $A5
        CLC
        ADC #$0002
        RTL
pushpc
org $209F1A
        assert read4($209F1A) == $6918A5A5
        JSL obj_next
        NOP
        NOP
pullpc
endif
