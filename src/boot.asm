; S-CPU: bring up the SA-1, then continue with the game's own reset code.
; Entered from $00:8000 straight out of reset: emulation mode, nothing set up.
boot:
        SEI
        CLC
        XCE
        SEP #$30
        LDA #$20
        STA.l !SA1_CCNT         ; hold the SA-1 in reset
        LDA #$00
        STA.l !SA1_SIE          ; no interrupts from the SA-1
        LDA #$FF
        STA.l !SA1_SIC
        ; ROM banking.  Bit 7 set = use the block number given; clear = power-on default.
        LDA #$80                ; $00-$1F: block 0, the original game
        STA.l !SA1_CXB
        LDA #$81                ; $20-$3F: block 1, the copy the SA-1 executes
        STA.l !SA1_DXB
        LDA #$80                ; $80-$9F: block 0 again (the game runs here, FastROM)
        STA.l !SA1_EXB
        LDA #$83                ; $A0-$BF: block 3, this code
        STA.l !SA1_FXB
        LDA #$00
        STA.l !SA1_BMAPS        ; $6000-$7FFF = $40:0000
        LDA #$80
        STA.l !SA1_SBWE         ; S-CPU may write BW-RAM
        LDA #$00
        STA.l !SA1_BWPA         ; no write-protected area
        LDA #$FF
        STA.l !SA1_SIWP         ; S-CPU may write all of I-RAM
        ; Our flags are in BW-RAM, which has a battery: what a previous session left there
        ; must not be taken for a job to run or for a scene in progress.
        LDA #$00
        STA.l !cmd
        STA.l !own
        STA.l !fb_sa1
        STA.l !snd_n
        STA.l !m7_latch
        STA.l !early
        STA.l !pipe_dis
        STA.l !go_b
        STA.l !no_flip
        STA.l !d_sel
        STA.l !a_done
        STA.l !car_wait
        STA.l !bot_done
        STA.l !bot_done+1
        STA.l !sub_j
        STA.l !sub_on
        STA.l !x_show
        STA.l !sbx
        STA.l !cap_n
        ; The SA-1 starts in bank $00, where the game leaves no room, so it starts in
        ; I-RAM on a JML into block 3.  (Not at the bottom of I-RAM, which is the SA-1's
        ; copy of the game's page 0.)
        LDA #$5C
        STA.l !SA1_BOOT
        LDA.b #sa1_reset
        STA.l !SA1_BOOT+1
        LDA.b #sa1_reset>>8
        STA.l !SA1_BOOT+2
        LDA.b #sa1_reset>>16
        STA.l !SA1_BOOT+3
        REP #$20
        LDA.w #!SA1_BOOT
        STA.l !SA1_CRV
        STA.l !SA1_CNV
        STA.l !SA1_CIV
        SEP #$20
        LDA #$00
        STA.l !SA1_CCNT         ; release the SA-1
        ; what the hook at $00:8000 replaced: CLC / XCE / REP #$10
        SEP #$30
        SEC
        XCE                     ; back to emulation mode, as after reset
        CLC
        XCE
        REP #$10
        JML reset_continue
