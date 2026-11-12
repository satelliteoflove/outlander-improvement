; Shared definitions.

; ---- SA-1 registers
!SA1_CCNT  = $2200      ; S-CPU: SA-1 control (reset, IRQ, message)
!SA1_SIE   = $2201      ; S-CPU: interrupt enable
!SA1_SIC   = $2202      ; S-CPU: interrupt clear
!SA1_CRV   = $2203      ; SA-1 reset vector
!SA1_CNV   = $2205      ; SA-1 NMI vector
!SA1_CIV   = $2207      ; SA-1 IRQ vector
!SA1_SCNT  = $2209      ; SA-1: S-CPU control
!SA1_CIE   = $220A      ; SA-1: interrupt enable
!SA1_CIC   = $220B      ; SA-1: interrupt clear
!SA1_CXB   = $2220      ; ROM block for banks $00-$1F / $C0-$CF
!SA1_DXB   = $2221      ; $20-$3F / $D0-$DF
!SA1_EXB   = $2222      ; $80-$9F / $E0-$EF
!SA1_FXB   = $2223      ; $A0-$BF / $F0-$FF
!SA1_BMAPS = $2224      ; S-CPU: BW-RAM block seen at $6000-$7FFF
!SA1_BMAP  = $2225      ; SA-1:  same
!SA1_SBWE  = $2226      ; S-CPU: BW-RAM write enable
!SA1_CBWE  = $2227      ; SA-1:  BW-RAM write enable
!SA1_BWPA  = $2228      ; BW-RAM write-protected area
!SA1_SIWP  = $2229      ; S-CPU: I-RAM write protection (1 bit per 256 bytes)
!SA1_CIWP  = $222A      ; SA-1:  same
!SA1_DCNT  = $2230      ; DMA control
!SA1_MCNT  = $2250      ; arithmetic: 0 = multiply, 1 = divide, 2 = cumulative sum
!SA1_MA    = $2251      ; multiplicand / dividend (16 bit)
!SA1_MB    = $2253      ; multiplier / divisor (16 bit); writing the high byte starts it
!SA1_MR    = $2306      ; result (40 bit)

; ---- memory the two CPUs share
; The SA-1's copy of the game's low RAM ($0000-$07FF) is in two places (tools/mkpatch.py
; patches the SA-1's code to match):
;   I-RAM $0000-$00FF (the S-CPU sees it at $3000)   page 0.  Nearly all the game's direct-
;                   page accesses go here, and I-RAM is the SA-1's fast memory.
;   BW-RAM $40:0100-$07FF   pages 1-7.  Code that runs with the data bank at $7E on the
;                   S-CPU runs with $40 on the SA-1 and finds them here with absolute
;                   addressing; direct-page and bank-0 accesses reach them through the
;                   window at $6000.
; The SA-1's stack is in I-RAM too, below $0800.
; The rest of BW-RAM, bank $40 (64 KB; $40:8000-$FFFF is src/sub.asm's):
;   $40:1000-$10FF  our own variables (below; $7000 through the window, reachable from either
;                   CPU under any data bank with long addressing)
;   $40:1100-$173F  copies of the HDMA tables for the frame on show and the one waiting
;                   to be shown (src/pipe.asm)
;   $40:1800-$18FF  more variables ($7800 through the window)
;   $40:2000-$7FFF  the game's $7E:2000-$7FFF.  While !own is set this is the only current
;                   copy: the driving scene's tables and frame buffer live here.
!cmd        = $007000   ; S-CPU writes a job number, SA-1 clears it when done
!m7_latch   = $007001   ; emulated PPU mode 7 write latch
!fb_sa1     = $007002   ; nonzero: a frame is being drawn or waits to be shown; how far the renderer
                        ; has got ($DF) is to be read from the SA-1's copy (see the nmi hooks)
!snd_n      = $007003   ; bytes used in the sound queue
!ex_id      = $007004   ; which exit the block left by (index into blk_exits)
!ex_p       = $007005   ; SA-1 registers at the exit
!ex_db      = $007006
!own        = $007007   ; nonzero: $7E:2000-$7FFF is in BW-RAM and work RAM's copy is stale
!ex_a       = $007008
!ex_x       = $00700A
!ex_y       = $00700C
!entry_p    = $00700E   ; S-CPU status register when the block was handed over
!snd_q      = $007010   ; sound queue: 3 bytes per command (A, Y low, Y high)
!SND_MAX    = 48        ; 16 commands
!en_a       = $007040   ; S-CPU registers when the block was handed over
!en_x       = $007042
!en_y       = $007044
; the S-CPU's divider, emulated (16-bit addresses: the game reaches them with absolute
; addressing from bank 0, see tools/mkpatch.py)
!div_a      = $7048     ; dividend, as written to $4204/$4205
!div_q      = $704A     ; quotient, as read from $4214/$4215
!div_r      = $704C     ; remainder, as read from $4216/$4217
!clash_snap = $007060   ; values of the blk_low_clash bytes when the block started
!CLASH_MAX  = 48
; pipelining (src/pipe.asm)
!go_b       = $007090   ; nonzero: the block may go past its split point (the last frame has been shown)
!early      = $007091   ; nonzero: the SA-1 was started on the next frame before the last one was shown
!pipe_dis   = $007092   ; nonzero: never start early (set by the block tests)
!no_flip    = $007093   ; nonzero: this vblank must not show the frame (set by nmi_piece)
!vb_since   = $007094   ; vblanks since a frame was last shown (stops at 255)
!d_sel      = $007095   ; which pair of display buffers gets the next frame's HDMA tables: 0 or 2
!d_p1       = $007096   ; where the S-CPU finds the HDMA tables of the frame just drawn
!d_p2       = $007098
!snd_n2     = $00709A   ; the sound queue of the frame just drawn, moved out of the SA-1's way
!a_done     = $00709B   ; the block is at its split point or past it (for the tools)
!d_t        = $00709C   ; scratch
!rx_t       = $00709E
!nmi_t      = $0070FA   ; nmi_piece's scratch
!car_wait   = $0070FC   ; vblanks the car's new picture has been held back (nmi_get_bd)
!rx_id      = $0070F0   ; the SA-1's registers at the exit (!ex_...), as blk_offload found them
!rx_p       = $0070F1
!rx_db      = $0070F2
!rx_a       = $0070F4
!rx_x       = $0070F6
!rx_y       = $0070F8
!g_sav      = $0070A0   ; the gauges' positions ($015B-$015D) at $00:8D1E
!g_run      = $0070A3   ; nonzero: a gauge is to move in this frame
!g_cur      = $0070B0   ; $012B-$0138 at the split point (14 bytes)
!snd_q2     = $0070C0   ; 48 bytes
; display buffers for the HDMA tables, in bank $40 (and mirrored to bank $7E when the scene
; is handed back): two pairs, each laid out like the game's own (table 1: $2CB bytes,
; table 2: $4C)
!D_T1_LEN   = $02CB
!D_T2_LEN   = $004C
!D0_T1      = $1100
!D0_T2      = !D0_T1+!D_T1_LEN
!D1_T1      = $1420
!D1_T2      = !D1_T1+!D_T1_LEN
!D_START    = !D0_T1
!D_LEN      = !D1_T2+!D_T2_LEN-!D_START
; in-between frames (src/sub.asm)
!sub_j      = $007800   ; which in-between frame the SA-1 is to draw: 1 to 3
!sub_on     = $007801   ; nonzero: in-between frames followed the last game step
!x_show     = $007802   ; nonzero: the frame waiting to be shown is an in-between frame
!sbx        = $007803   ; nonzero: the SA-1 is drawing an in-between frame
!cap_n      = $007804   ; game steps whose object table was kept (stops at 255)
!cap_cur    = $007806   ; where the object table is as the last game step drew it (bank $40)
!cap_prev   = $007808   ; ... and the one before
!x_pad      = $00780A   ; the buttons held when the step's frame was handed over (word)
!p_bb       = $00780C   ; the next step as predicted: its $BB,
!p_b1       = $00780E   ; its $B1
!p_ae       = $007810   ; and its $AE (word)
!p_b7       = $007824   ; and its $B7 (word)
!tw_walk    = $007826   ; gameplay changes: bit 0 alternates the walker's step between 1 and 2 pixels (any start will do)
!sbx_adv    = $007812   ; quarters the car has gone on in the in-between frame being drawn (word)
!dl_n       = $007814   ; bytes in !DLIST (word)
!sh_slot    = $007816   ; the object record sbx_shift has moved for drawing ($FFFF: none), and what
!sh_d       = $007818   ; its distance
!sh_l       = $00781A   ; and its place across the road were (words)
; the frame buffer upload (nmi_piece in src/offload.asm; words)
!fb_safe    = $00781C   ; of the frame the SA-1 is drawing: how far its slots are finished (obj_next)
!nmi_bot    = $00781E   ; scratch
!nmi_fit    = $007820   ; scratch
!bot_done   = $007822   ; nonzero: the lower halves of the frame waiting to be shown have been sent
!BOT_OVH    = $00C0     ; what sending them by themselves costs besides their bytes, in bytes' worth of time (send_bot)
; memory of the in-between frames, bank $40 (the second half of BW-RAM)
!SH_LOW   = $8000       ; shadow of the SA-1's low RAM ($0000-$07FF), in bank $40
!LOW_A    = $0400       ; the low RAM above the stack's pages that the block can write: two stretches
!LOW_AL   = $00C0       ; ($0402-$04B6 and $07C0-$07C9; tools/build.py fails if that changes)
!LOW_B    = $07C0
!LOW_BL   = $0010
!SH_OFS   = $8000       ; shadow of $40:2000-$30E4 (but the ring buffers) and $40:70E5-$78BC:
                        ; the same address + $8000
!FB       = $30E5       ; the frame buffer
!RING     = $2596       ; the road's ring buffers
!RING_X   = $2596       ; ... of which the road renderer rewrites the x array ($190 bytes)
!RING_XL  = $0190
!RING_BX  = $2A46       ; ... and that of the ring behind the car ($C8 bytes)
!RING_BXL = $00C8
!RING_END = $2C9E
!RING_N   = 14          ; ring entries kept in the shadow
!RLOG     = $BF00       ; ... here (8 bytes each)
!FB_END   = $70E5
!OBJ      = $7121       ; the object table: 56 records of 12 bytes (distance, type, x, ...)
!OBJ_LEN  = $02A0
!OBJ_AREA = $0310       ; the table and the drawing order list behind it ($73C1)
!CAP0     = $B100       ; the object table as the last two game steps drew it (bank $40)
!CAP1     = $B500
!PRE      = $9000       ; the objects' memory ($70E5-$78BC) as a game step's second part found it
!PRE_LOW  = $8800       ; ... and the low RAM, laid out as !SH_LOW
!DLIST    = $9800       ; the words of low RAM that the step changed after that (offsets; low_diff)
!DL_MAX   = 512
!SHIFT    = $9C00       ; per object record (same offsets as the table): what it moves by itself in the
                        ; in-between frame being drawn, along the road and across (two words; doctor)
!ENE      = $75B1       ; the enemies' records: 5 of $3A bytes
!ENE_LEN  = $0122
!HUD_BUF  = $78BD       ; the status display's buffers: from here on nothing of the objects'
!ST       = $2D36       ; the sprite table (4 bytes a sprite, then the size and high x bits)
!ST_LEN   = $0221
!ST_D     = $BC00       ; an in-between frame's sprite table, for the NMI handler (bank $40)

!SA1_STACK  = $07FF     ; top of I-RAM
!SA1_BOOT   = $003100   ; I-RAM: the SA-1's reset vector points here, at a jump written by boot
!P0         = $3000     ; where the S-CPU sees the SA-1's page 0
!P17        = $6000     ; where either CPU sees the SA-1's pages 1-7 from bank 0 (+ address)
!HI         = $2000     ; the part of bank $7E the block uses besides low RAM:
!HI_LEN     = $6000     ; $7E:2000-$7FFF

; the SA-1, wherever the object pass has done with an object ($20:9F1A; 16-bit A, direct
; page 0): every slot allocated so far is finished, and the S-CPU may send that far
; (send_bot in src/offload.asm)
macro fb_mark()
        LDA $DF
        CMP #$00C0
        BCS ?ok
        LDA #$00C0
?ok     CLC
        ADC #$0040
        STA.l !fb_safe
endmacro

; the S-CPU: A = where a complete frame's last slot is (16-bit A, direct page 0)
macro df_done()
        LDA $DF
        CMP #$00C0
        BCS ?ok
        LDA #$00C0
?ok
endmacro
