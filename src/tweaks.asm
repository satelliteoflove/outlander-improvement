; Changes to how the game plays (TWEAKS=0 builds without, and only such a build can be held
; to the original by tools/test.py).  Everything here is a number to tune; see CLAUDE.md,
; "Gameplay changes".

pushpc
; ---------------------------------------------------------------- the build says so
; tools/test.py reads this and refuses to compare a build with gameplay changes.
org $BFFFE0
        db "TWEAKS"

; ---------------------------------------------------------------- fewer roadblocks
; $80:9A18 spawns the roadside and the roadblocks: one round every 232 quarter segments,
; three objects at most.  The striped barrier across a lane (type $0D, at x = 0 or +-100)
; goes by the counter at $0157: 3 rounds without, 5 with one each, 1 to start over, so
; 5 rounds in 9.  Now 5 without, 4 with, 1: 4 in 10, 28% fewer, in shorter runs with
; longer gaps.  (In the SA-1's copy, which is what runs, and in the original beside it.)
!TW_BLOCK_RUN = 4               ; rounds with a roadblock in each run (5)
!TW_BLOCK_GAP = 5               ; rounds without, less one (3)
macro tw_blocks(bank)
org <bank>+$9D77
        assert read2(<bank>+$9D77) == $FAC9             ; CMP #$FA
        CMP.b #$FF-!TW_BLOCK_RUN
org <bank>+$9D7B
        assert read2(<bank>+$9D7B) == $03A9             ; LDA #$03
        LDA.b #!TW_BLOCK_GAP
endmacro
%tw_blocks($800000)
%tw_blocks($200000)

; ---------------------------------------------------------------- less damage from running into things
; $80:B845 tests an object against the car and calls the type's handler, which adds to $C0,
; the damage of this pass ($00:8E19 takes it off the car's 511 at $0404).  At top speed
; (41) a pole, a cactus or a rock costs (speed - 6) x 8 = 272 and a roadblock speed + 1.
; The hook takes 5/16 off whatever one such call adds: 187 for the pole.  What an enemy
; throws (type $0B, 12 a hit) is left alone, and so is everything that is not a collision
; with something standing: ramming and gunfire add to $C0 elsewhere.
org $209EE5
        assert read4($209EE5) == $80B84522              ; JSL $80B845 (as the copy has it before blk_patch.asm)
        JSL tw_coll
; ---------------------------------------------------------------- walking half as fast again
; On foot everything moves by its animation script: opcode 17 ($90:98D4) gives the figure
; a number of pixels to go (operand - $80, into $CB2A,Y; bit 8 of the operand = at the
; double) and $90:99F6 pays them out, 1 a frame or 2.  Walking is 6 pixels every 5.9
; frames.  For the player (Y = $20) both are taken by half as much again: the script's
; pixels x 1.5, paid out 1 and 2 in turn (3 at the double), never more than are left (the
; game's own payer overshoots an odd number by 2 a frame and comes back, for ever).  The
; animation keeps its pace; everything the player's scripts move sideways goes 1.5 times
; as far (the jump too).  The camera is the player's x ($90:83A8) and takes it as it comes.
org $9099F6
        assert read4($9099F6) == $2AB920E2              ; SEP #$20 / LDA $CB2A,Y
        JML tw_move
        NOP
org $9098D4
        assert read4($9098D4) == $E9384BA5              ; LDA $4B / SEC / SBC #$80 / STA $CB2A,Y
        JML tw_setmove
        NOP #4
; ---------------------------------------------------------------- hit tests on foot
; They are distances between x positions (CLAUDE.md, "Gameplay changes"), and an enemy's
; reached further than the player's on both sides.  The player's blow: the nearest enemy
; whose x is less than the reach (26, 20 and 24 by stance) ahead of his facing right, or
; between 24 and 24 + the reach behind it facing left; one number for both sides.  Measured
; on the sprites, his fist ends 36 pixels ahead of his x standing (33 crouching) and 30 behind
; it (24), and an enemy's body starts about 7 past its x and ends about 26 past it.  So in
; front a reach of more than about 30 hits an enemy the fist does not touch (the standing
; blow is tested before the arm is out, but the fist gets there four frames later), while
; behind, the fist reaches everything the test can.  In front the reach is now 4 longer; behind
; 10 longer, and it starts 10 behind his x, not 24, so an enemy standing in him on the left
; can be hit as one on the right can.  An enemy on his left hits from under 40, not 60.
!TW_REACH = 4                   ; pixels added to the player's reach in front (26, 20 and 24 by stance)
!TW_REACH_BACK = 10             ; and behind him
!TW_LEFT  = $0A                 ; facing left the reach starts this far behind the player's x ($18)
!TW_ENEMY = $28                 ; an enemy on the left hits from under this far ($3C)
!TW_BACK = (!TW_REACH_BACK-!TW_REACH)
assert !TW_BACK > 0, "tw_left assumes the reach behind is the longer"
org $9092BB
        assert read4($9092BB) == $380018E9              ; SBC #$0018 / SEC
        JML tw_left                     ; (up to $9092C4: SEC / SBC $CB4D,Y / BMI $92CC)
org $9092D9
        assert read3($9092D9) == $001AA2                ; LDX #$001A
        LDX.w #$001A+!TW_REACH
org $9092E9
        assert read3($9092E9) == $0014A2                ; LDX #$0014
        LDX.w #$0014+!TW_REACH
org $9092F3
        assert read3($9092F3) == $0018A2                ; LDX #$0018
        LDX.w #$0018+!TW_REACH
org $908C89
        assert read3($908C89) == $003CC9                ; CMP #$003C
        CMP.w #!TW_ENEMY
org $908D99
        assert read3($908D99) == $003CC9                ; CMP #$003C
        CMP.w #!TW_ENEMY
pullpc
tw_coll:
        PEI ($C0)
        JSL $20B845
        PHP                             ; 1,S = P, 2,S = $C0 before
        REP #$30
        LDA $C0
        SEC
        SBC 2,S
        BEQ .out
        BCC .out
        TAX                             ; (the caller saved X; the routine itself loads Y)
        LDY $A5
        LDA $73C1,y
        TAY
        LDA $7123,y
        CMP #$000B
        BEQ .out
        TXA
        LSR A
        LSR A
        STA $C0                         ; d/4 for a moment
        LSR A
        LSR A
        CLC
        ADC $C0                         ; 5d/16
        EOR #$FFFF
        SEC
        ADC 2,S
        STA 2,S                         ; old - 5d/16
        TXA
        CLC
        ADC 2,S
        STA $C0                         ; old + d - 5d/16
.out    SEP #$20
        PLA                             ; P
        STA 2,S                         ; over the saved word's high byte
        PLA
        PLP
        RTL

; (S-CPU, bank $90's on-foot code: direct page $0400, data bank $7E, 16-bit index)
; The player's blow, facing left ($90:92BB, A = his x, carry set, 16 bits): the distance of
; the enemy at Y behind the start of his reach, which the game compares with the one reach of
; both sides.  It is taken !TW_BACK further back, and the first !TW_BACK pixels count as 0,
; so behind him the reach is !TW_BACK longer than in front.  tools/hitbox.lua and
; tools/footbot.lua read the two operands below (SBC #, CMP #) to know where it reaches.
tw_left:
        SBC.w #!TW_LEFT+!TW_BACK
        SEC
        SBC $CB4D,y
        BPL .in
        CMP.w #-!TW_BACK
        BCC .out                        ; nearer than his reach behind starts: not this way
        LDA.w #0
.in     JML $9092C4                     ; CMP $4B: the nearest so far?
.out    JML $9092CC

tw_move:
        CPY #$0020
        BEQ .player
        SEP #$20
        LDA $CB2A,y
        JML $9099FB
.player SEP #$20
        LDA $CB2A,y
        BNE +
        JML $909A34
+       LDA.l !tw_walk
        EOR #$01
        STA.l !tw_walk
        AND #$01
        INC A
        STA $43                         ; 1 or 2
        STZ $44
        LDA $CB29,y
        BIT #$01
        BEQ +
        LDA #$03
        STA $43
+       LDA $CB2A,y
        BPL +
        EOR #$FF
        INC A
+       CMP $43
        BCS +
        STA $43                         ; no further than is left
+       LDA $CB2A,y
        BMI .neg
        SEC
        SBC $43
        STA $CB2A,y
        REP #$20
        LDA $CB1D,y
        CLC
        ADC $43
        STA $CB1D,y
        JML $909A34
.neg    CLC
        ADC $43
        STA $CB2A,y
        REP #$20
        LDA $CB1D,y
        SEC
        SBC $43
        STA $CB1D,y
        JML $909A34

tw_setmove:
        LDA $4B
        SEC
        SBC #$80
        CPY #$0020
        BNE .store
        CMP #$00
        BMI .neg
        PHA
        LSR A
        CLC
        ADC 1,S
        STA 1,S
        PLA
        BPL .store
        LDA #$7F
        BRA .store
.neg    EOR #$FF
        INC A
        PHA
        LSR A
        CLC
        ADC 1,S
        STA 1,S
        PLA
        BPL +
        LDA #$7F
+       EOR #$FF
        INC A
.store  STA $CB2A,y
        JML $9098DC
