; SA-1 side: start-up, the job loop, and stand-ins for hardware the SA-1 cannot reach.

sa1_reset:
        SEI
        CLC
        XCE
        REP #$38
        LDA #$0000
        TCD                     ; direct page 0 = the copy of the game's page 0, in I-RAM
        LDA #!SA1_STACK
        TCS
        SEP #$20
        PHK
        PLB
        LDA #$00
        STA !SA1_BMAP           ; $6000-$7FFF = $40:0000
        LDA #$80
        STA !SA1_CBWE           ; SA-1 may write BW-RAM
        LDA #$FF
        STA !SA1_CIWP           ; and all of I-RAM
        STZ !SA1_CIE            ; no interrupts
        LDA #$F0
        STA !SA1_CIC
        STZ !SA1_DCNT
        STZ !SA1_MCNT           ; arithmetic unit: signed multiply
sa1_idle:
        SEP #$20
        LDA.l !cmd
        BEQ sa1_idle
if !SUB
        CMP #$02
        BNE +
        JMP sa1_sub             ; job 2: an in-between frame (src/sub.asm)
+       CMP #$03
        BNE +
        JMP sa1_world_back      ; job 3: the game's state back after them
+
endif
        ; job 1: run the driving block.  Register state as the S-CPU had it
        ; at $00:8D12.  It leaves through sa1_blk_exit.
        LDA #$00
        PHA
        PLB
        REP #$30
        LDA #$0000
        TCD
        LDA.l !en_y
        TAY
        LDA.l !en_x
        TAX
        SEP #$20
        LDA.l !entry_p
        ORA #$04                ; (interrupts stay off on the SA-1)
        PHA
        REP #$20
        LDA.l !en_a
        PLP
        JML $208D12

; The copy's ways out of the block jump here (patched at the end of this file).  Save the
; registers for the S-CPU, which carries on in the original code at the same place.
macro blk_exit(id)
        PHP
        SEP #$20
        PHA
        LDA.b #<id>
        JMP sa1_blk_exit
endmacro
sa1_blk_exit0: %blk_exit(0)
sa1_blk_exit1: %blk_exit(1)
sa1_blk_exit2: %blk_exit(2)
sa1_blk_exit:
        STA.l !ex_id
        PLA
        REP #$30
        STA.l !ex_a             ; (the high byte is whatever B was: also preserved)
        TXA
        STA.l !ex_x
        TYA
        STA.l !ex_y
        SEP #$20
        PLA
        STA.l !ex_p
        PHB
        PLA
        STA.l !ex_db
        REP #$30
        LDX #!SA1_STACK
        TXS
        SEP #$20
        PHK
        PLB
if !PIPE
        LDA.l !ex_id
        BEQ +
        JSR exit_g              ; (the block left the scene before its split point)
+
endif
        LDA #$00
        STA.l !cmd
        JMP sa1_idle

; ---- the PPU's mode 7 multiplier ($211B x $211C -> $2134-$2136), done on the SA-1's own.
; The game writes M7A low then high, then M7B, then reads the 24-bit signed product.  Reads
; are patched to read the SA-1's product register directly; writes come here.
; Called with JSL in place of a 4-byte STA long (or through the trampolines below for a
; 3-byte STA absolute): 8-bit A, any data bank; A and the flags are left alone.
sa1_wr_m7a:
        PHP
        PHA
        LDA.l !m7_latch
        STA.l !SA1_MA           ; new M7A = (written << 8) | previous write
        PLA
        STA.l !SA1_MA+1
        STA.l !m7_latch
        PLP
        RTL

sa1_wr_m7b:
        PHP
        PHA
        STA.l !m7_latch
        STA.l !SA1_MB
        BPL +
        LDA #$FF
        BRA ++
+       LDA #$00
++      STA.l !SA1_MB+1         ; sign-extended; this write starts the multiplication
        PLA
        PLP
        RTL

; ---- sound.  $81DB9E sends a command to the sound CPU through the APU ports, which the
; SA-1 cannot reach.  The copy's version queues the command (A = command, Y = data) and
; the S-CPU sends the queue when the block is done.  Registers and flags preserved.
sa1_snd:
        PHP
        SEP #$20
        REP #$10
        PHX
        PHA
        LDA.l !snd_n
        CMP.b #!SND_MAX
        BCS +
        REP #$20
        AND #$00FF
        TAX
        SEP #$20
        LDA 1,s
        STA.l !snd_q,x
        REP #$20
        TYA
        STA.l !snd_q+1,x
        SEP #$20
        TXA
        CLC
        ADC #$03
        STA.l !snd_n
+       PLA
        PLX
        PLP
        RTL

; ---- the S-CPU's divider ($4204/5 dividend, $4206 divisor -> $4214/5 quotient, $4216/7
; remainder; unsigned 16 by 8), done on the SA-1's arithmetic unit.  The generator points
; the dividend writes and result reads at !div_a / !div_q / !div_r; the write of the divisor,
; which starts the division, comes here through a trampoline.  Nothing else is changed.
sa1_div_a:                      ; in place of STA $4206 (8-bit A)
        PHP
        REP #$20
        PHA
        AND #$00FF
        JSR div_core
        PLA
        PLP
        RTL
sa1_div_x:                      ; in place of STX $4206
        PHP
        REP #$20
        PHA
        TXA
        AND #$00FF
        JSR div_core
        PLA
        PLP
        RTL
; A (16 bit) = divisor.  The SA-1 divides a signed 16-bit number by an unsigned one, so a
; dividend of $8000 or more is halved first and the result put right afterwards.
div_core:
        BEQ .zero
        PHA
        SEP #$20
        LDA #$01
        STA.l !SA1_MCNT         ; divide
        REP #$20
        LDA.l $000000+!div_a
        BMI .big
        STA.l !SA1_MA
        LDA 1,s
        STA.l !SA1_MB           ; starts it; 5 cycles
        NOP
        LDA.l !SA1_MR
        STA.l $000000+!div_q
        LDA.l !SA1_MR+2
        STA.l $000000+!div_r
        BRA .done
.big    LSR A                   ; carry = bit 0 (nothing below changes it until the ROL)
        STA.l !SA1_MA
        LDA 1,s
        STA.l !SA1_MB
        NOP
        LDA.l !SA1_MR+2
        ROL A                   ; remainder * 2 + bit 0: less than twice the divisor
        CMP 1,s
        BCC +
        SBC 1,s
        STA.l $000000+!div_r
        LDA.l !SA1_MR
        ASL A
        INC A
        BRA ++
+       STA.l $000000+!div_r
        LDA.l !SA1_MR
        ASL A
++      STA.l $000000+!div_q
.done   SEP #$20
        LDA #$00
        STA.l !SA1_MCNT         ; back to multiplying, which the rest of the patch assumes
        REP #$20
        PLA
        RTS
.zero   LDA #$FFFF              ; as the S-CPU's divider answers a division by zero
        STA.l $000000+!div_q
        LDA.l $000000+!div_a
        STA.l $000000+!div_r
        RTS

; ---- $90:BD66 fills $7E:7ABD-$7B1C with the byte at $90:BD97, by DMA through the work RAM
; port.  Same thing by hand; leaves the registers as the original does.
sa1_fill_7abd:
        SEP #$20
        LDA.l $30BD97
        LDX #$005F
-       STA.l $407ABD,x
        DEX
        BPL -
        REP #$20
        LDA #$7A04
        LDX #$0060
        LDY #$BD97
        JML $30BD96             ; the original's RTS

; ---- patches to the copy that are written by hand
pushpc
org $208F14                     ; end of the main loop body (JMP $8C54 in the original)
        JMP blk_exit0_far
org $208E41                     ; leaving the scene (JML $81BC8B in the original)
        JML sa1_blk_exit1
org $208D92                     ; leaving the scene (JML $81BB5A in the original)
        JML sa1_blk_exit2
org $21DB9E
        JML sa1_snd
org $30BD66
        JML sa1_fill_7abd
; The copy's reset code, which the SA-1 never runs, is used for trampolines: the
; generator's from $20:8004 (tools/build.py), this one after them.
org $2080C0
blk_exit0_far:
        JML sa1_blk_exit0
pullpc
