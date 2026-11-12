; Native SA-1 replacements for the road renderer's multiply routines.  The originals build
; a 16x16 multiply out of three or four uses of the PPU's 16x8 multiplier; the SA-1 has a
; 16x16 signed multiplier of its own.  Each replacement leaves exactly what the original
; left in the direct page ($4C-$51, $FF).  The originals stay in place in the copy for the
; cases the replacements decline.

; ---- $81D17B:  $4F:$50:$51 = (($4C) * [$3A],Y) >> 12,  $4E = low byte of the product
; In: A 16 bit.  Out: A 16 bit.  X, Y kept.
pushpc
org $21D17B
        JML fast_d17b                   ; over SEP #$20 / STZ $FF
d17b_original:                          ; = $21D17F
org $21D09C
        JML fast_d09c
org $21D494                             ; the same routine for the second road pass: its
        JML fast_d494                   ; table is at $2A46 instead of $2596
pullpc

fast_d17b:
        LDA $4C
        BMI fast_d17b_slow                       ; the original mishandles a negative value in its
        STA.l !SA1_MA                   ; own way; let it
        LDA [$3A],y
        STA.l !SA1_MB                   ; starts the multiply; 5 cycles
        SEP #$20
        STZ $FF
        LDA.l !SA1_MR
        STA $4E
        REP #$20
        LDA.l !SA1_MR+1                 ; product bits 8-23
        LSR #4
        STA $4F
        SEP #$20
        LDA.l !SA1_MR+3                 ; product bits 24-31
        ASL #4
        ORA $50
        STA $50
        LDA.l !SA1_MR+3
        LSR #4
        STA $51
        LDA #$00
        REP #$20
fast_d17b_rtl:
        RTL
fast_d17b_slow:
        SEP #$20
        STZ $FF
        JML d17b_original

; ---- $81D09C (and $81D494, with $2A46):  $50 = [$2596,X] - ($4C);  $4C = ($50 * [$3D],Y) >> 8;  $4E = ([$3D],Y * 25) >> 4
; In: A 16 bit, data bank = BW-RAM.  Out: A 16 bit.  X, Y kept.
fast_d494:
        LDA $2A46,x
        BRA +
fast_d09c:
        LDA $2596,x
+       SEC
        SBC $4C
        STA $50
        STA.l !SA1_MA
        LDA [$3D],y
        STA.l !SA1_MB
        PHA
        NOP
        LDA.l !SA1_MR+1                 ; product bits 8-23
        STA $4C
        PLA
        STA.l !SA1_MA
        LDA #$0019
        STA.l !SA1_MB
        SEP #$20
        STZ $FF
        REP #$20
        LDA.l !SA1_MR                   ; product bits 0-15
        LSR #4
        STA $4E
        SEP #$20
        LDA.l !SA1_MR+2                 ; bits 16-23
        ASL #4
        ORA $4F
        STA $4F
        LDA #$00
        REP #$20
fast_d09c_rtl:
        RTL
