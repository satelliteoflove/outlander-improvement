; The road renderer's main loop ($81:CDE0-$81:CED8), rewritten for the SA-1.
;
; The loop projects the road's 199 segments, far to near: for each it steps a table of
; heights, multiplies a height difference by a reciprocal from a table in the ROM to get a
; screen line, stores that and a horizontal position (a 32-bit accumulator shifted right
; by four), and whenever the line is a new nearest one calls the routines that fill in
; the HDMA tables down to it.  On the SA-1 the game's own code takes 85 instructions and a
; call to the multiply routine per segment, a third of the whole frame.
;
; This does the same work in half the cycles.  Nothing about the results changes:
;   * the rare paths (a segment behind the viewer; the last pass, whose leftovers in the
;     scratch variables the rest of the frame may read) are left to the game's own code,
;     entered with every variable as it would have it;
;   * the paths that are common but not hot (a new nearest line: 30 times a frame) call
;     the game's own subroutines.
; The block tests compare everything the loop leaves behind with the original's.
;
; What is kept in registers and scratch (I-RAM page 0, bytes the game does not use)
; instead of the game's variables while the loop runs:
;   Y        index of the next output word = $56 = 2 * $46 (the pass counter)
;   !r_tp    pointer into the reciprocal table = [$3A] + 8 * $46
;   !r_s     $AC + $54: the two only ever appear added together
;   !r_u     the accumulator ($82:$80) shifted left by 12, so that the 16 bits wanted
;            (bits 4-19) are its high word; !r_du the same of the step ($86:$84)
;   !r_lim   $70E1,[$9D]: the line number last put on the list at $70E5
!r_tp  = $02
!r_s   = $05
!r_t   = $07
!r_ul  = $09
!r_uh  = $0B
!r_dul = $18
!r_duh = $1A
!r_lim = $1C

pushpc
org $21CDE0                             ; the head of the loop: LDA $2596,X / SEC
        JML road_fast
pullpc

; 16-bit A/X/Y, data bank = BW-RAM, direct page 0, as the loop runs.
road_fast:
        LDA $46
        CMP #$00C6
        BCC +
.orig   LDA $2596,x                     ; the last pass (and anything unexpected): the
        SEC                             ; game's own code, from the instruction after
        JML $21CDE4                     ; the two that the jump here replaced
+       TYA                             ; ---- from the game's variables
        CLC
        ADC $3A
        STA !r_tp
        SEP #$20
        LDA $3C
        STA !r_tp+2
        REP #$20
        LDA $AC
        CLC
        ADC $54
        STA !r_s
        LDA $80
        LSR #4
        STA !r_uh
        LDA $82
        AND #$000F
        XBA
        ASL #4
        ORA !r_uh
        STA !r_uh
        LDA $80
        AND #$000F
        XBA
        ASL #4
        STA !r_ul
        LDA $84
        LSR #4
        STA !r_duh
        LDA $86
        AND #$000F
        XBA
        ASL #4
        ORA !r_duh
        STA !r_duh
        LDA $84
        AND #$000F
        XBA
        ASL #4
        STA !r_dul
        PHX
        LDX $9D
        LDA $70E1,x
        STA !r_lim
        PLX
        LDY $56
        BRA .iter
.neg    STA !r_t                        ; a segment behind the viewer: the game's code
        JSR .canon                      ; for the rest of this pass; it comes back to
        LDA !r_t                        ; road_fast for the next
        JML $21CDF4
; a new nearest line: the game's routines fill in the HDMA tables down to it
.lt     STA $6E
        LDA !r_uh
        STA $4C
        PHY
        TYA
        DEC A
        DEC A
        ASL A
        ASL A
        TAY                             ; index into the ROM tables, as the game has it
        JSL $21D09C
        JSL $21CF97
        PLY
        BRA .eq
.iter   LDA $2596,x
        SEC
        SBC $7E
        STA $2596,x
        LDA !r_s
        SEC
        SBC $2726,x
        BMI .neg
        LSR A
        LSR A
        STA.l !SA1_MA
        LDA [!r_tp]
        STA.l !SA1_MB                   ; starts the multiplication (5 cycles)
        LDA !r_tp
        CLC
        ADC #$0008
        STA !r_tp
        LDA.l !SA1_MR+1                 ; product bits 8-23
        LSR #4
        STA !r_t
        LDA.l !SA1_MR+2                 ; bits 16-31
        ASL #4
        ORA !r_t                        ; bits 12-27: what the game's routine leaves in $4F
        CLC
        ADC #$002F
        STA $2F55,y
        INY
        INY
        CMP $6E
        BEQ .eq
        BCC .lt
        LDA $6E                         ; further down the screen than the nearest so far
        CMP !r_lim
        BCC .mark
.eq     LDA $28B6,x
        CMP $93
        BNE .chk
.cont   DEX
        DEX
        BMI .wrap
.w2     LDA !r_uh
        STA $76D1,y
        LDA !r_ul
        CLC
        ADC !r_dul
        STA !r_ul
        LDA !r_uh
        ADC !r_duh
        STA !r_uh
        LDA $80
        CLC
        ADC $84
        STA $80
        LDA $82
        ADC $86
        STA $82
        LDA !r_s
        CLC
        ADC $B5
        STA !r_s
        CPY #$018C                      ; $46 = $C6: the last pass is the game's
        BCS +
        JMP .iter
+       JSR .canon
        JMP .orig
.wrap   TXA
        CLC
        ADC #$0190
        TAX
        BRA .w2
; the nearest line so far is above the last one on the list at $70E5: add it
.mark   PHX
        LDX $9D
        STA $70E5,x
        TYA
        DEC A
        DEC A
        LSR A                           ; $46
        STA $70E7,x
        INX #4
        STX $9D
        INC $9B
        PLX
        LDA $6E
        STA !r_lim
        BRA .eq
; the segment's colour ($28B6,X) differs from the last
.chk    STA !r_t
        LDA $95
        SEC
        SBC $6E
        BEQ .cont
        BMI .cont
        PHY
        LDY !r_t
        STY $93
        LDY $4A
        SEP #$20
        DEY
        DEY
        STA ($43),y
        STY $4A
        INY
        LDA $93
        STA ($43),y
        REP #$20
        LDA $6E
        STA $95
        PLY
        JMP .cont
; the game's variables as they stand before a pass
.canon  STY $56
        TYA
        LSR A
        STA $46
        ASL A
        ASL A
        ASL A
        TAY
        LDA !r_s
        SEC
        SBC $AC
        STA $54
        RTS

; ---------------------------------------------------------------- the second pass
; $81:D2AA-$81:D389: the same loop over the 99 segments of what is drawn above the horizon
; line, with other tables, no horizontal positions to store, and segments "behind the
; viewer" as an ordinary case (their line is $18 minus the product instead of plus).  Done
; the same way; see road_fast.
pushpc
org $21D2AA                             ; LDA $2A46,X / SEC
        JML road2_fast
pullpc

road2_fast:
        LDA $46
        CMP #$0062
        BCC +
.orig   LDA $2A46,x
        SEC
        JML $21D2AE
+       TYA
        CLC
        ADC $3A
        STA !r_tp
        SEP #$20
        LDA $3C
        STA !r_tp+2
        REP #$20
        LDA $AC
        CLC
        ADC $68
        STA !r_s
        PHX
        LDX $A1
        LDA $743D,x
        STA !r_lim
        PLX
        LDY $56
        BRA .iter
.neg    STA !r_ul                       ; (as it was: the game's code may want it)
        EOR #$FFFF
        INC A
        LSR A
        LSR A
        STA.l !SA1_MA
        LDA [!r_tp]
        STA.l !SA1_MB
        LDA !r_tp
        CLC
        ADC #$0008
        STA !r_tp
        LDA.l !SA1_MR+1
        LSR #4
        STA !r_t
        LDA.l !SA1_MR+2
        ASL #4
        ORA !r_t
        STA !r_t
        LDA #$0018
        SEC
        SBC !r_t
        BPL .store
        JSR .canon                      ; off the top: the game's code ends the loop here,
        LDA !r_ul                       ; and what its multiply leaves behind stays
        JML $21D2BE
.lt     STA $6E
        LDA $80
        STA $4C
        LDA $82
        LSR A
        ROR $4C
        LSR A
        ROR $4C
        LSR A
        ROR $4C
        LSR A
        ROR $4C
        PHY
        TYA
        DEC A
        DEC A
        ASL A
        ASL A
        TAY
        JSL $21D494
        JSL $21D442
        PLY
        BRA .eq
.iter   LDA $2A46,x
        SEC
        SBC $7E
        STA $2A46,x
        LDA !r_s
        SEC
        SBC $2B0E,x
        BMI .neg
        LSR A
        LSR A
        STA.l !SA1_MA
        LDA [!r_tp]
        STA.l !SA1_MB
        LDA !r_tp
        CLC
        ADC #$0008
        STA !r_tp
        LDA.l !SA1_MR+1
        LSR #4
        STA !r_t
        LDA.l !SA1_MR+2
        ASL #4
        ORA !r_t
        CLC
        ADC #$0018
.store  STA $7469,y
        INY
        INY
        CMP $6E
        BEQ .eq
        BCC .lt
        LDA $6E
        CMP !r_lim
        BCC .mark
.eq     LDA $2BD6,x
        CMP $93
        BNE .chk
.cont   DEX
        DEX
        BMI .wrap
.w2     LDA $80
        CLC
        ADC $84
        STA $80
        LDA $82
        ADC $86
        STA $82
        LDA !r_s
        SEC
        SBC $B5
        STA !r_s
        CPY #$00C4                      ; $46 = $62: the last pass is the game's
        BCS +
        JMP .iter
+       JSR .canon
        JMP .orig
.wrap   TXA
        CLC
        ADC #$00C8
        TAX
        BRA .w2
.mark   PHX
        LDX $A1
        STA $7441,x
        TYA
        DEC A
        DEC A
        LSR A
        STA $7443,x
        INX #4
        STX $A1
        INC $9F
        PLX
        LDA $6E
        STA !r_lim
        BRA .eq
.chk    STA !r_t
        LDA $95
        SEC
        SBC $6E
        BEQ .cont
        BMI .cont
        PHY
        LDY !r_t
        STY $93
        LDY $4A
        SEP #$20
        DEY
        DEY
        STA ($43),y
        STY $4A
        INY
        LDA $93
        STA ($43),y
        REP #$20
        LDA $6E
        STA $95
        PLY
        JMP .cont
.canon  STY $56
        TYA
        LSR A
        STA $46
        ASL A
        ASL A
        ASL A
        TAY
        LDA !r_s
        SEC
        SBC $AC
        STA $68
        RTS
