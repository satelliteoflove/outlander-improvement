; In-between frames: the game keeps its own pace, the picture gets 30 frames a second.
;
; The game does everything once per pass of its main loop: reads the pad, moves the car,
; the road and every object, draws.  A pass took about 8 vblanks on the original and takes
; 2 here, so left alone the game runs four times too fast.  Nothing in it knows how long a
; pass took, and its logic and its drawing are interleaved down to the single object, so
; there is no speed to turn down.
;
; So the game's own pass (a "game step") is run once every four shown frames, exactly as
; before, and shows its frame as before.  The three frames in between are drawn from the
; state it leaves, moved on by what the last step moved it (the road, the car's place on it,
; each object): the picture goes on at 30 fps while the game's logic sees what it always
; saw, one step at a time.  tools/play.lua holds the patched game to the original's state
; at every step, and to its picture at every step's frame.
;
; An in-between frame is drawn by the game's own code: the road renderer and the block's
; second part (from $00:8EBA: the gun at the side window, scenery, the object pass), run by
; the SA-1.  That code moves objects, tests collisions, runs the enemies' state machines
; and counts animations on as it draws: logic and drawing cannot be told apart, and a
; first version that tried (the state machines skipped, the collision test off) drew
; whatever it had got wrong for three frames out of four (an enemy blowing up showed whole
; in between).  So nothing is switched off.  Instead the second part is run again *from
; what the step's second part started from*, and so does again all that it did then:
;   * At the split point of a game step ($00:8EBA, sa1_split in src/pipe.asm) the objects'
;     memory and the low RAM are copied aside (pre_save).  An in-between frame's second
;     part gets that copy of the objects' memory (doctor), and of the low RAM what the
;     step changed afterwards (low_diff, low_split), but for what the frame's own first
;     part has set: where the car and the road are now.
;   * What has moved on since the step goes into the drawing only: each object's record
;     is moved at the point where the pass has done with its logic and is about to draw it
;     (sbx_shift).  Moved before the pass, as a second version had it, the enemies decided
;     and collided at places the game never had them in: one threw something in an
;     in-between frame that the next step never saw.  With nothing to move (tools/build.py
;     SUBMOVE=0) the frame is the step's own over again, object for object:
;     tools/subobj.lua, tools/subin.lua and tools/subchk.lua check that.
;   * Before the first in-between frame all the game's memory that such drawing can change,
;     but the frame buffer, is copied aside ("the shadow", $40:8000-$FFFF), and after the
;     third it is copied back.  Whatever an in-between frame does to the game's state is
;     undone, whether anyone has looked at that code or not.
;   * Sound commands queued meanwhile are dropped.
;
; The S-CPU's side of an in-between frame is the loop head's display work (the VRAM page,
; the upload counters) and the hand-over of what the NMI handler shows a frame with; the
; game's loop head itself runs once per game step.  The NMI handler shows every frame the
; same way, except that $2C (which pair of HDMA buffers the road renderer writes next) is
; only switched by a game step's frame: the game must find it switched once per step.

; ================================================================ SA-1 side
; job 2: draw in-between frame !sub_j.  Entered from sa1_idle (8-bit A, 16-bit X/Y).
sa1_sub:
        REP #$30
        LDA #$0000
        TCD
        SEP #$20
        LDA #$01
        STA.l !sbx
        LDA.l !sub_j
        CMP #$01
        BNE +
        JSR world_save          ; the game's state as the step left it
sub_saved:                      ; (marks for tools/subtime.lua, here and below)
        JSR predict
sub_predicted:
        JSR world_p01           ; what that did to it, undone
        BRA ++
+       JSR world_part          ; what the last in-between frame did to it, undone
++
sub_restored:
        ; ---- as the loop head and the flip leave things for a frame
        REP #$20
        LDA #$0000
        STA $DF
        STA $7E
        LDA #$0004
        STA $C6
        LDA #$0008
        STA $DD
        STA $E3
        SEP #$20
        STZ $C5
        STZ $2E
        JSR doctor
sub_doctored:
        ; ---- the first part: the road and its HDMA tables
        PEA $0000
        PLB
        PLB
        SEP #$20
        JSL $21CC3B
sub_road:
        SEP #$20
        LDA #$01
        STA.l !a_done
-       LDA.l !go_b             ; the frame buffer and the sprite table are the last frame's
        BEQ -                   ; until it has been shown
        JSR hdma_to_d
        ; ---- the second part, as $00:8EBA-$00:8ED6
        JSR low_split
sub_second:                     ; (a mark for tools/subobj.lua, tools/subin.lua)
        REP #$30
        PEA $0000
        PLB
        PLB
        JSL $21B7E9
        JSL tr_gun
        REP #$20
        LDA.l $400193
        STA.l $400195
        LDA #$0200
        STA.l $400191
        JSL $20AE1E
        JSL $209DD6
sub_drawn:                      ; (a mark for tools/smooth.lua)
        ; ---- $01B0 names a sprite of this frame for the NMI handler; a routine after the
        ; object pass clears it unless a button is held ($81:AFD0), which is not run here
        REP #$20
        LDA.l $400000+!SH_LOW+$01B0
        BNE +
        STA.l $4001B0
+       ; ---- the sprite table is the game's state too, and put back with the rest: the
        ; NMI handler shows this frame with a copy
        LDX.w #!ST
        LDY.w #!ST_D
        LDA.w #!ST_LEN-1
        db $54,$40,$40
        SEP #$20
        LDA #$01
        STA $C5
        PHK
        PLB
        LDA #$00
        STA.l !sbx
sub_done:
        STA.l !cmd
        JMP sa1_idle

; job 3: the game's state back as the step left it.
sa1_world_back:
        JSR world_back
world_done:
        SEP #$20
        LDA #$00
        STA.l !cmd
        JMP sa1_idle

; Where the car will be a step from now: the next step's first two calls, run ahead of
; time on the state this step left and the buttons held now.  $81:B0E4 steers (the car's
; place across the road, $B9/$BB, and the horizon, $B1) and $81:B28A is the engine (the
; distance for the step, $AE).  If the buttons stay as they are, the next step works out
; exactly this, and the in-between frames lead up to its frame in four equal parts.  What
; the two calls do to the state is undone with the rest (world_part).
; 8-bit A, 16-bit X/Y, direct page 0; the same on return.
predict:
        REP #$20
        LDA.l !x_pad
        STA $36
        PEA $0000
        PLB
        PLB
        SEP #$20
        JSL $21B0E4
        JSL $21B28A
        REP #$30
        LDA $BB
        STA.l !p_bb
        LDA $B1
        STA.l !p_b1
        LDA $B7
        STA.l !p_b7
        LDA $AE
        AND #$00FF
        STA.l !p_ae
        SEP #$20
        PHK
        PLB
        RTS

; Copies between the game's memory and the shadow.  The shadow holds what drawing an
; in-between frame can change:
;   * the low RAM the block can write: pages 0 and 1, and of pages 4 to 7 the two
;     stretches its writes are in (!LOW_A, !LOW_B: tools/build.py checks them against the
;     static analysis of the block);
;   * $40:2000-$30E4.  Of the road's ring buffers ($2596-$2C9D) the two x arrays are
;     kept whole: the road renderer rewrites them as it draws (it moves the road's x
;     values to where the car is, and leaves $7E for the segments still to come).  Of the
;     other four only the entries that stepping the road !RING_N times writes (ring_save);
;   * the objects' memory, $40:70E5-$78BC.
; Not the frame buffer, and not the status display's buffers behind the objects' memory,
; which that drawing does not touch (tools/sa1guard.lua fails the tests if it ever does)
; and which the S-CPU's NMI handler may fill in the meantime.
; 8-bit A, 16-bit X/Y; data bank = this bank on return.
macro mv(src, dst, len, sb, db)
        LDX.w #<src>
        LDY.w #<dst>
        LDA.w #<len>-1
        db $54,<db>,<sb>
endmacro
macro low_back()
        %mv(!SH_LOW, $0000, $0100, $40, $00)
        %mv(!SH_LOW+$0100, $0100, $0100, $40, $40)
        %mv(!SH_LOW+!LOW_A, !LOW_A, !LOW_AL, $40, $40)
        %mv(!SH_LOW+!LOW_B, !LOW_B, !LOW_BL, $40, $40)
endmacro
macro low_keep(to)              ; the low RAM the block can write, to a copy laid out like it
        %mv($0000, <to>, $0100, $00, $40)                       ; page 0 (I-RAM)
        %mv($0100, <to>+$0100, $0100, $40, $40)
        %mv(!LOW_A, <to>+!LOW_A, !LOW_AL, $40, $40)
        %mv(!LOW_B, <to>+!LOW_B, !LOW_BL, $40, $40)
endmacro
world_save:
        REP #$30
        %low_keep(!SH_LOW)
        %mv($2000, $2000+!SH_OFS, !RING_X+!RING_XL-$2000, $40, $40)     ; ... and the ring's x array
        %mv(!RING_BX, !RING_BX+!SH_OFS, !RING_BXL, $40, $40)
        %mv(!RING_END, !RING_END+!SH_OFS, !FB-!RING_END, $40, $40)
        %mv(!FB_END, !FB_END+!SH_OFS, !HUD_BUF-!FB_END, $40, $40)
        JSR low_diff
        JSR ring_save
        JMP world_end
world_back:
        REP #$30
        %low_back()
        %mv($2000+!SH_OFS, $2000, !RING_X+!RING_XL-$2000, $40, $40)
        %mv(!RING_BX+!SH_OFS, !RING_BX, !RING_BXL, $40, $40)
        %mv(!RING_END+!SH_OFS, !RING_END, !FB-!RING_END, $40, $40)
        %mv(!FB_END+!SH_OFS, !FB_END, !HUD_BUF-!FB_END, $40, $40)
        JSR ring_back           ; (after low RAM: it goes by $70 and $72)
        JMP world_end
world_part:                     ; what a frame is drawn from, but for the objects' memory,
        REP #$30                ; which doctor brings
        %low_back()
        %mv(!RING_X+!SH_OFS, !RING_X, !RING_XL, $40, $40)
        %mv(!RING_BX+!SH_OFS, !RING_BX, !RING_BXL, $40, $40)
        BRA world_end
world_p01:                      ; pages 0 and 1: all that predict's two calls write
        REP #$30
        %mv(!SH_LOW, $0000, $0100, $40, $00)
        %mv(!SH_LOW+$0100, $0100, $0100, $40, $40)
world_end:
        SEP #$20
        PHK
        PLB
        RTS

; The road is a ring of 200 segments in three arrays ($2596, $2726, $28B6; $70 is where the
; next one goes, and it steps down), with a second, shorter ring behind the car ($2A46,
; $2B0E, $2BD6; $72, stepping up).  A step of the road ($81:CAE5) writes one entry of each.
; These keep and put back the !RING_N entries that are next in line, of the four arrays
; that are not kept whole.  16-bit A/X/Y, direct page 0 with the game step's $70 and $72
; in it; leaves the data bank at $40.
macro ring_e(a, back)
if <back>
        LDA.w !RLOG,y
        STA.w <a>,x
else
        LDA.w <a>,x
        STA.w !RLOG,y
endif
        INY
        INY
endmacro
macro ring(back)
        PEA $4040
        PLB
        PLB
        LDX $70
        LDY #$0000
-       %ring_e($2726, <back>)
        %ring_e($28B6, <back>)
        DEX
        DEX
        BPL +
        LDX #$018E
+       CPY.w #4*!RING_N
        BNE -
        LDX $72
-       INX
        INX
        CPX #$00C8
        BCC +
        LDX #$0000
+       %ring_e($2B0E, <back>)
        %ring_e($2BD6, <back>)
        CPY.w #8*!RING_N
        BNE -
        RTS
endmacro
ring_save: %ring(0)
ring_back: %ring(1)

; What an in-between frame is drawn from.  The objects' memory is put as the step's
; second part found it (pre_save) and left at that: the frame's own second part then
; moves, collides and animates every object exactly as the step's did, from the same
; places and so to the same ends.  What has moved on since goes into the drawing only:
;   * the car, by what the next step will move it if the buttons stay as they are
;     (predict): along the road by its $AE, in quarters of a road segment (the road is
;     stepped as $00:8DD3 does; !sbx_adv), across it by its $BB, and the horizon to its $B1;
;   * an object that moves by itself, by what it moved along the road in this step: its
;     distance as the step drew it (sbx_capture) less its distance as the step before
;     drew it, plus $AE, and likewise across (!SHIFT, per object).  Only the kinds that do
;     move, and only if the record is the same one all along: the game uses a record
;     again as soon as it is free, and scenery of one kind after another of the same kind
;     looked like a thing that had moved (a post in the middle of the road).
; sbx_shift puts both into an object's record at the point where the pass has done with
; its logic and is about to draw it; the record is thrown away with the rest afterwards.
; Fractions are cut towards zero everywhere, so that what stands by the road stays on it.
; Nothing moves while the car rolls backwards ($017A), which the road is not stepped for.
; 8-bit A, 16-bit X/Y, direct page 0, data bank 0; the same on return.
!dc_cur  = $02          ; scratch in page 0 (see road.asm)
!dc_prev = $05
!dc_t    = $07
!dc_j    = $09
!dc_adv  = $0B
!dc_ae   = $18
!dc_s    = $1A
doctor:
        PHB
        REP #$30
        LDA.l !cap_prev
        STA !dc_prev
        LDA.l !cap_cur
        STA !dc_cur
        %mv(!PRE, !FB_END, !HUD_BUF-!FB_END, $40, $40)  ; (the data bank is $40 from here)
        ; ---- how far
        LDA.l !sub_j
        AND #$00FF
if !SUBMOVE == 0
        LDA #$0000
endif
        STA !dc_j
        LDA.w $017A
        AND #$00FF
        BEQ +
        STZ !dc_j
+       LDA $AE
        AND #$00FF
        STA !dc_ae              ; (what the objects' last step along the road is measured against)
        LDA.l !p_ae
        JSR frac
        STA !dc_adv
        STA.l !sbx_adv          ; (every object is drawn that much closer: sbx_shift)
        LDA #$FFFF
        STA.l !sh_slot
        ; ---- the objects: what each has been moving by itself
        LDX.w #!OBJ_LEN-12
-       STZ.w !SHIFT,x
        STZ.w !SHIFT+2,x
        TXA
        SEC
        SBC #$000C
        TAX
        BPL -
        LDA.l !cap_n
        AND #$00FF
        CMP #$0002
        BCC .car                ; no step before this one to compare with
        LDX #$0000
.loop   LDA.w !OBJ+2,x
        CMP #$0004              ; the kinds that move by themselves: an enemy vehicle,
        BEQ +
        CMP #$000A              ; type $0A (a step of its own in the pass, $80:9EB2),
        BEQ +
        CMP #$000B              ; a thrown object
        BNE .next
+       TXY
        INY
        INY
        CMP (!dc_prev),y
        BNE .next               ; the record held something else a step ago,
        CMP (!dc_cur),y
        BNE .next               ; or does now,
        INY #4
        LDA.w !OBJ+6,x          ; or another of its kind (the record's own data is elsewhere,
        CMP (!dc_prev),y        ; and this says where)
        BNE .next
        CMP (!dc_cur),y
        BNE .next
        TXY
        LDA (!dc_cur),y
        SEC
        SBC (!dc_prev),y
        CLC
        ADC !dc_ae
        JSR frac_s
        STA.w !SHIFT,x
        TXY
        INY #4
        LDA (!dc_cur),y
        SEC
        SBC (!dc_prev),y
        JSR frac_s
        STA.w !SHIFT+2,x
.next   TXA
        CLC
        ADC #$000C
        TAX
        CPX.w #!OBJ_LEN
        BNE .loop
.car    ; ---- the car across the road, and the horizon
        LDA.l !p_bb
        JSR frac_s
        CLC
        ADC $B9
        BMI +
        CMP #$0108
        BCC ++
        LDA #$0108
        BRA ++
+       CMP #$FEF8
        BCS ++
        LDA #$FEF8
++      STA $B9
        LDA.l !p_b1
        SEC
        SBC $B1
        JSR frac_s
        CLC
        ADC $B1
        STA $B1
        AND #$01FF
        STA $64
        ; ---- the road: as $00:8DD3 steps it
        PEA $0000
        PLB
        PLB
        SEP #$20
        LDA !dc_adv
        CLC
        ADC $B0
        PHA
        AND #$03
        STA $B0
        PLA
        LSR A
        LSR A
        BEQ .done
        CMP.b #!RING_N-1        ; (never at any speed the game has: 12 segments in three
        BCC +                   ; quarters of a step; the shadow keeps !RING_N entries)
        LDA.b #!RING_N-2
+       REP #$20
        AND #$00FF
        TAX
-       PHX
        SEP #$20
        JSL $21CA0B
        JSL $21CAE5
        REP #$30
        PLX
        DEX
        BNE -
.done   SEP #$20
        REP #$10
        PLB
        RTS

; A (16 bit, signed) * !dc_j / 4, cut towards zero.  frac_s answers 0 for anything of 128
; or more either way: not a movement, but a record or a counter that started afresh.
frac_s: CLC
        ADC #$0080
        CMP #$0100
        BCC +
        LDA #$0000
        RTS
+       SEC
        SBC #$0080
frac:   STA !dc_s
        BPL +
        EOR #$FFFF
        INC A
+       STA !dc_t
        LDA !dc_j
        BNE +
        RTS                     ; (A = 0)
+       DEC A
        BEQ .x1
        DEC A
        BEQ .x2
        LDA !dc_t
        ASL A
        CLC
        ADC !dc_t               ; x 3
        BRA ++
.x2     LDA !dc_t
        ASL A
        BRA ++
.x1     LDA !dc_t
++      LSR A
        LSR A
        BIT !dc_s
        BPL +
        EOR #$FFFF
        INC A
+       RTS

; ---- hooks in the SA-1's copy of the block
; From sa1_split (src/pipe.asm), a game step at $00:8EBA: the objects' memory as the step's
; second part is about to find it.  The in-between frames run that part from the same.
; 16-bit A/X/Y; changes the data bank.
pre_save:
        LDA #$FFFF              ; no record is moved for drawing (sbx_shift, sbx_next).  Not left
        STA.l !sh_slot          ; to the last in-between frame: this is battery-backed memory,
                                ; and a scene can end in the middle of an object pass
        %mv(!FB_END, !PRE, !HUD_BUF-!FB_END, $40, $40)
        %low_keep(!PRE_LOW)
        RTS

; The low RAM that the step's second part and what follows it changed (world_save has
; just put the step's low RAM in the shadow): a list of the words that are not as pre_save
; found them.  16-bit A/X/Y, data bank $40.
low_diff:
        LDY #$0000
        LDX #$01FE
-       LDA.w !SH_LOW,x
        CMP.w !PRE_LOW,x
        BEQ +
        JSR .add
+       DEX
        DEX
        BPL -
        LDX.w #!LOW_A+!LOW_AL-2
-       LDA.w !SH_LOW,x
        CMP.w !PRE_LOW,x
        BEQ +
        JSR .add
+       DEX
        DEX
        CPX.w #!LOW_A-2
        BNE -
        LDX.w #!LOW_B+!LOW_BL-2
-       LDA.w !SH_LOW,x
        CMP.w !PRE_LOW,x
        BEQ +
        JSR .add
+       DEX
        DEX
        CPX.w #!LOW_B-2
        BNE -
        TYA
        STA.l !dl_n
        RTS
.add    CPY.w #!DL_MAX*2
        BCS +
        TXA
        STA.w !DLIST,y
        INY
        INY
+       RTS

; Before an in-between frame's second part: the low RAM of low_diff's list as the step's
; second part found it, so that the same code does the same again (timers, the gun, what
; the object pass keeps count of: all a step further on by now).  Not a byte that this
; frame's first part has changed since: those are the view's (where the car is across the
; road, the horizon, the road's own), and scratch.  Any M/X; 8-bit A, 16-bit X/Y and the
; data bank of this bank on return.
low_split:
        PHP
        PHB
        REP #$30
        PEA $4040
        PLB
        PLB
        LDA.l !dl_n
        BEQ .done
        TAY
.loop   DEY
        DEY
        LDX.w !DLIST,y
        SEP #$20
        CPX #$0100
        BCS .bw
        LDA.l $000000,x         ; (page 0 is in I-RAM)
        CMP.w !SH_LOW,x
        BNE +
        LDA.w !PRE_LOW,x
        STA.l $000000,x
+       LDA.l $000001,x
        CMP.w !SH_LOW+1,x
        BNE .next
        LDA.w !PRE_LOW+1,x
        STA.l $000001,x
        BRA .next
.bw     LDA.w $0000,x
        CMP.w !SH_LOW,x
        BNE +
        LDA.w !PRE_LOW,x
        STA.w $0000,x
+       LDA.w $0001,x
        CMP.w !SH_LOW+1,x
        BNE .next
        LDA.w !PRE_LOW+1,x
        STA.w $0001,x
.next   REP #$20
        CPY #$0000
        BNE .loop
.done   ; The car's place across the road and its steering ($B7-$BC): the second part only
        ; compares them with the objects' (collisions, the enemies' steering), which are
        ; where the step had them.  The road has been drawn from the new ones by now.
        REP #$20
        LDA.w !PRE_LOW+$B7
        STA.l $0000B7
        LDA.w !PRE_LOW+$B9
        STA.l $0000B9
        LDA.w !PRE_LOW+$BB
        STA.l $0000BB
        PLB
        PLP
        RTS

; at $20:8EDB, in place of JSL $80C309 (the first call after the object pass): keep the
; object table as it was drawn, for what each object moved in this step (doctor).  8-bit A.
sbx_capture:
        PHP
        REP #$30
        PHA
        PHX
        PHY
        PHB
        LDA.l !cap_cur
        STA.l !cap_prev
        CMP.w #!CAP0
        BEQ +
        LDA.w #!CAP0
        BRA ++
+       LDA.w #!CAP1
++      STA.l !cap_cur
        TAY
        LDX.w #!OBJ
        LDA.w #!OBJ_LEN-1
        db $54,$40,$40
        SEP #$20
        LDA.l !cap_n
        INC A
        BEQ +
        STA.l !cap_n
+       REP #$30
        PLB
        PLY
        PLX
        PLA
        PLP
        JML $20C309

; Where an object is about to be drawn, in an in-between frame: its record moved on by
; what the car has gone on since the step and by what the object does by itself (doctor).
; Not the two kinds the pass does not move either: the flash at the gun ($0F, whose
; distance comes from a table) and $11.  16-bit A/X/Y, X = the record, data bank $40; A is
; lost.
sbx_shift:
        SEP #$20
        LDA.l !sbx
        REP #$20
        BEQ +
        LDA.w !OBJ+2,x
        CMP #$000F
        BEQ +
        CMP #$0011
        BEQ +
        TXA
        STA.l !sh_slot          ; (sbx_next puts the record back)
        LDA.w !OBJ,x
        STA.l !sh_d
        SEC
        SBC.l !sbx_adv
        CLC
        ADC.w !SHIFT,x
        STA.w !OBJ,x
        LDA.w !OBJ+4,x
        STA.l !sh_l
        CLC
        ADC.w !SHIFT+2,x
        STA.w !OBJ+4,x
+       RTS
; at $21:D414, in place of LDA $B7 / ASL A / ASL A / ASL A: the road renderer works out where
; the background (mountains, clouds) is scrolled to, $60 = -$64 / 2 - 8 x $B7.  $64 is the
; heading, which doctor moves on; $B7 is the steering rate, which $81:B0E4 changes once a
; step, and a change of 1 moved the background 8 pixels in the step's frame and none in
; the frames between.  An in-between frame takes the j quarters of the change that the
; next step is predicted to make (predict).  16-bit A; A = 8 x $B7.
sbx_b7:
if !SUBMOVE
        SEP #$20
        LDA.l !sbx
        REP #$20
        BEQ .plain
        LDA.l !p_b7
        SEC
        SBC $B7
        ASL A
        PHA                     ; 2 x the change: a quarter of 8 x
        LDA.l !sub_j
        AND #$0003
        DEC A
        BEQ .have
        DEC A
        BEQ +
        LDA 1,s
        ASL A
        CLC
        ADC 1,s
        BRA ++
+       LDA 1,s
        ASL A
++      STA 1,s
.have   LDA $B7
        ASL A
        ASL A
        ASL A
        CLC
        ADC 1,s
        STA 1,s
        PLA
        RTL
endif
.plain  LDA $B7
        ASL A
        ASL A
        ASL A
        RTL

; at $20:9F1A, in place of LDA $A5 / CLC / ADC #$0002: the pass goes on to the next
; object.  The record sbx_shift moved goes back to where the logic had it: objects look
; at one another (a shot at what it may hit), and those still to come must find this one
; where the step's did.  16-bit A/X/Y, any data bank.
sbx_next:
        %fb_mark()
        LDA.l !sh_slot
        BMI +
        PHX
        TAX
        LDA.l !sh_d
        STA.l $400000+!OBJ,x
        LDA.l !sh_l
        STA.l $400000+!OBJ+4,x
        LDA #$FFFF
        STA.l !sh_slot
        PLX
+       LDA $A5
        CLC
        ADC #$0002
        RTL
; at $20:9EEF, in place of LDA $7121,X / CMP #$0028: an object ahead, behind the
; collision test.  The game has decided by the sign of the distance which of its two ways
; the object goes, ahead (here) or behind (sbx_behind), and each way compares without sign
; from there on.  Moved for the drawing, an object can be on the other side of that line:
; one the car passes between two steps came here with a distance below zero, which this
; way takes for too far to draw, and was gone from the picture for a frame or two before
; the next step drew it in the mirror.  So the sign is looked at again: below zero goes
; where anything under $28 does, to the mirror's routine ($9F3B), which is where the game
; draws it from the next step on.
sbx_far:
        JSR sbx_shift
        LDA.w !OBJ,x
        BMI +
        CMP #$0028
        RTL
+       CLC                     ; (the BCC at $9EF5 goes to $9F3B)
        RTL
; at $20:9F2E, in place of CMP #$FEE8 / BCS $9F3B: an object behind the car.  (And one
; that what it moves by itself has brought level with the car again: as the game's way
; ahead has it, by the mirror's routine under $28, else from $9EF7.)
sbx_behind:
        JSR sbx_shift
        LDA.w !OBJ,x
        BMI +
        CMP #$0028
        BCC ++
        JML $209EF7
+       CMP #$FEE8
        BCS ++
        JML $209F33
++      JML $209F3B
; at $20:C730, in place of REP #$20 / LDA $7125,X: an enemy, behind its state machine.
sbx_ene:
        REP #$20
        JSR sbx_shift
        LDA.w !OBJ+4,x
        RTL
; at $20:CF35, in place of LDX $A7 / LDA $7E7125,X: an enemy blowing up, which its state
; machine draws itself.
sbx_boom:
        LDX $A7
        PHB                     ; (the data bank is 0 here, for the tables of the explosion)
        PEA $4040
        PLB
        PLB
        JSR sbx_shift
        PLB
        LDA.l $400000+!OBJ+4,x
        RTL

pushpc
org $208EDB
        assert read4($208EDB) == $80C30922      ; JSL $80C309 (the generated patch makes it $20C309)
        JSL sbx_capture
org $209EEF
        assert read4($209EEF) == $C97121BD      ; LDA $7121,X / CMP #$0028
        JSL sbx_far
        NOP
        NOP
org $209F1A
        assert read4($209F1A) == $6918A5A5      ; LDA $A5 / CLC / ADC #$0002
        JSL sbx_next
        NOP
        NOP
org $21D414
        assert read4($21D414) == $0A0AB7A5      ; LDA $B7 / ASL A / ASL A / ASL A
        JSL sbx_b7
        NOP
org $209F2E
        assert read4($209F2E) == $B0FEE8C9      ; CMP #$FEE8 / BCS $9F3B
        JML sbx_behind
        NOP
org $20C730
        assert read4($20C730) == $25BD20C2      ; REP #$20 / LDA $7125,X
        JSL sbx_ene
        NOP
org $20CF35
        assert read4($20CF35) == $25BFA7A6      ; LDX $A7 / LDA $7E7125,X
        JSL sbx_boom
        NOP
        NOP
; A trampoline in bank $20, where the copy has the NMI handler, which the SA-1 never runs.
org $208120
tr_gun:                         ; $00:9751, the gun at the side window (as at $00:8EBE)
        JSR $9751
        RTL
assert pc() <= $208190
pullpc

; ================================================================ S-CPU side
; Called by blk_offload when a game step has left its frame to be shown: three in-between
; frames, then the game's state back.  8-bit A, 16-bit X/Y, data bank = this bank; the same
; on return.
!wram_flip = $7E1F60
sub_frames:
        LDA #$00
        STA.l !sub_on
        LDA.l !pipe_dis
        BEQ +
        RTS
+       LDA #$01
        STA.l !sub_on
        ; ---- the buttons the next step would find now, as $00:8C73 reads them (predict)
        REP #$20
        LDA.l $000038
        TAX
        SEP #$20
        LDA.l $00047C
        REP #$20
        BEQ +
        PHD                     ; the demonstration: the next word of its script
        PEA $0100
        PLD
        LDA [$FD]
        PLD
        CPX #$0000
        BEQ ++
        ORA #$1000
        BRA ++
+       TXA
++      STA.l !x_pad
        SEP #$20
        LDX #$0001
.loop   TXA
        STA.l !sub_j
        LDA #$00
        STA.l !a_done
        STA.l !go_b
        LDA #$02
        STA.l !cmd              ; the SA-1 starts on the frame's first part
        PHX
        CPX #$0001
        BNE +
        JSR snd_replay          ; (the step's sound commands, while it does)
+       ; ---- wait for the frame before to be shown, in work RAM (see wait_sa1)
        REP #$30
        LDX.w #.code
        LDY.w #!wram_flip
        LDA.w #.end-.code-1
        db $54,$7E,$A0
        PEA $0000
        PLB
        PLB                     ; data bank 0
        PHD
        LDA #$0000
        TCD
        SEP #$20
        JSL !wram_flip
        ; ---- what the loop head does for a frame ($00:8CA3)
        LDA $DC
        EOR #$02
        STA $DC
        LDX #$0000
        STX $DF
        STX $E1
        LDA #$00
        STA.l !fb_safe
        STA.l !fb_safe+1
        LDA #$01
        STA.l !fb_sa1
        STA.l !go_b
        PLD
        JSR wait_sa1            ; (leaves the data bank here)
        ; ---- the frame is drawn: what the NMI handler shows it with
        REP #$30
        PHD
        LDA #$0000
        TCD
        PEA $0000
        PLB
        PLB
        LDA.l !d_p1
        STA $2F
        LDA.l !d_p2
        STA $32
        LDA.w !P0+$5C
        STA $5C
        LDA.w !P0+$60
        STA $60
        LDA.w !P0+$62
        STA $62
        LDA.w !P0+$64
        STA $64
        LDA.w !P0+$66
        STA $66
        LDA.w !P0+$C6
        STA $C6
        LDA.w !P0+$DD
        STA $DD
        LDA.w !P0+$DF
        STA $DF
        LDA.w !P0+$E3
        STA $E3
        LDA.w !P17+$019F
        STA $019F
        LDA.w !P17+$01B0
        STA $01B0
        SEP #$20
        LDA.w !P0+$2E
        STA $2E
        LDA #$01
        STA.l !x_show
        LDA.w !P0+$C5
        STA $C5                 ; from here on the NMI handler may show it
        LDA #$00
        STA.l !fb_sa1
        STA.l !snd_n
        PLD
        PHK
        PLB
        PLX
        INX
        CPX #$0004
        BEQ +
        JMP .loop
+       LDA #$03
        STA.l !cmd              ; the game's own state back
        JSR wait_sa1
        LDA #$00
        STA.l !sub_j
        RTS
.code
-       LDA $C5
        BNE -
        LDA $2E
        BNE -
        RTL
.end
