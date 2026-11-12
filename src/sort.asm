; The object list's sort ($80:9DE2-$80:9E4D), rewritten for the SA-1.
;
; The game keeps a list of 56 object records ($73C1, offsets into the records at $7121)
; in drawing order, and before drawing bubble-sorts it by each record's first word:
; whole passes over the list until one makes no swap, at least two a frame, 24 in the
; attract demo: 970 comparisons of 24 instructions, a quarter of the frame.
;
; A bubble sort only ever swaps neighbours that are strictly out of order, so its result
; is the one stable ordering of the list, and any stable sort gives the same list.  This
; is an insertion sort: the list is nearly in order from the frame before, so it costs one
; comparison per entry and one move per swap the bubble sort would have made.
;
; The order (from the game's three-way comparison): keys of $0028 and up first, ascending;
; then keys $0000-$0027, descending; then negative keys, descending as unsigned numbers.
; One 16-bit sort key gives that order when ascending:
;       k >= $28:  k - $28        0 <= k < $28:  $7FFF - k        k < 0:  k eor $7FFF
;
; The game's loop leaves its counters in $46, $4C, $4E, $50 and the registers.  What it
; would leave follows from the largest distance any entry moved: a bubble sort needs that
; many passes with swaps, plus one without (the block tests compare all of it).
!s_key  = $000200       ; I-RAM: 56 sort keys
!s_ke   = $02           ; scratch in page 0 (see road.asm): key and entry being inserted
!s_ve   = $05
!s_i    = $07           ; where it came from
!s_max  = $09           ; twice the largest distance moved

pushpc
org $209DE2                             ; LDA #$0036 / STA $4C: the head of the sort
        JML sort_fast
pullpc

; 16-bit A/X/Y, data bank = BW-RAM, direct page 0.  Ends at the game's code after the sort.
sort_fast:
        LDY #$006E                      ; ---- the sort keys
-       LDA $73C1,y
        TAX
        LDA $7121,x
        BMI ++
        CMP #$0028
        BCC ++
        SBC #$0028
        BRA +
++      EOR #$7FFF
+       TYX
        STA.l !s_key,x
        DEY
        DEY
        BPL -
        STZ !s_max
        LDX #$0002                      ; ---- insert each entry among those before it
.outer  LDA.l !s_key,x
        CMP.l !s_key-2,x
        BCS .next                       ; already in place
        STA !s_ke
        LDA $73C1,x
        STA !s_ve
        STX !s_i
.shift  LDA.l !s_key-2,x
        STA.l !s_key,x
        LDA $73BF,x
        STA $73C1,x
        DEX
        DEX
        BEQ .place
        LDA !s_ke
        CMP.l !s_key-2,x
        BCC .shift
.place  LDA !s_ke
        STA.l !s_key,x
        LDA !s_ve
        STA $73C1,x
        STX !s_ke                       ; (free now)
        LDA !s_i
        SEC
        SBC !s_ke
        CMP !s_max
        BCC +
        STA !s_max
+       LDX !s_i
.next   INX
        INX
        CPX #$0070
        BCC .outer
        ; ---- what the game's loop would have left behind
        LDA #$FFFF
        STA $4E
        LDA #$006C
        SEC
        SBC !s_max
        BCC .all                        ; an entry moved from one end to the other
        STA $50                         ; the last pass, without swaps, was this long
        LSR A
        STA $4C
        STZ $46
        LDX $50
        LDY $73C1,x
        INX
        INX
        JML $209E4E
.all    LDA #$FFFF                      ; every pass swapped, the last one a single pair
        STA $4C
        STZ $50
        LDA #$0001
        STA $46
        LDY $73C3
        LDX #$0002
        JML $209E4E
