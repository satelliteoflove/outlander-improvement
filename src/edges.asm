; The road's edges ($81:CF97 and its twin $81:D442), rewritten for the SA-1.
;
; Whenever the road loop finds a new nearest screen line it calls this to fill in the HDMA
; tables for the lines between the last one and it: the two edges of the road are stepped
; down the screen a line at a time (two Bresenham lines; $81:D028) and two words written
; per line.  The game's stepper moves an edge one pixel per pass of a loop that switches
; register width twice; a line takes seven passes on average, and with the calls around it
; this was a sixth of the frame.
;
; Here the two inner loops only count, in 8-bit mode, and the edge positions are moved by
; the count afterwards.  The set-up ($81:CFED) is the game's own, as is the stepper for the
; rare shapes (an edge steeper than 45 degrees), where it has an oddity that is not worth
; copying: it is called for that line instead.
!e_n   = $1E            ; scratch in page 0 (see road.asm)
!e_lim = $20            ; lines at or below this one get no table entry
!e_c   = $22            ; what is subtracted from the right edge
!e_t   = $24

pushpc
org $21CFAA                             ; PHY / JSL $81CFED: past the first-call case
        JML edges_cf97
org $21D455                             ; the same place in the second pass's copy
        JML edges_d442
pullpc

; 16-bit A/X/Y; X = $EA (the line the edges have got to); the caller's X is on the stack.
edges_cf97:
        LDA #$007F
        STA !e_lim
        LDA #$0032
        BRA +
edges_d442:
        LDA #$0032
        STA !e_lim
        LDA #$0001
+       STA !e_c
        PHY
        JSL $21CFED
        LDY $48
        SEP #$20
        BRA .line
.slow   REP #$20
        JSL $21D028
        JMP .out
.line   LDA $F0
        CMP $F4
        BCS .slow
        CMP $F6
        BCS .slow
        STZ !e_n                        ; ---- left edge: $EE, error term $F3
        LDA $F3
-       INC !e_n
        SEC
        SBC $F0
        BPL -
        CLC
        ADC $F4
        STA $F3
        LDA $F2                         ; direction ($F1 is 1 or -1)
        BMI +
        LDA !e_n
        CLC
        ADC $EE
        STA $EE
        BCC ++
        INC $EF
        BRA ++
+       LDA $EE
        SEC
        SBC !e_n
        STA $EE
        BCS ++
        DEC $EF
++      STZ !e_n                        ; ---- right edge: $EC, always leftwards, error term $F5
        LDA $F5
-       INC !e_n
        SEC
        SBC $F0
        BPL -
        CLC
        ADC $F6
        STA $F5
        LDA $EC
        SEC
        SBC !e_n
        STA $EC
        BCS +
        DEC $ED
+       REP #$20
.out    CPX !e_lim
        BCS +
        STX !e_t
        LDA $EC
        SEC
        SBC !e_c
        SEC
        SBC !e_t
        DEY
        DEY
        STA ($40),y
        LDA $EE
        SEC
        SBC $EC
        CLC
        ADC #$0080
        EOR #$FFFF
        DEY
        DEY
        STA ($40),y
+       DEX
        CPX $6E
        SEP #$20
        BNE .line
        REP #$20
        STX $EA
        LDX $4C
        STX $EE
        LDX $4E
        STX $EC
        STY $48
        PLY
        PLX
        RTL
