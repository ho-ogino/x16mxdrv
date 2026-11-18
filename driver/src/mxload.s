; mxload.s - X16MXDRV bank +2: loader
;
;   L_INIT   YM chip type, CPU MHz and OPM clock calibration
;   L_BEGIN  scan the MDX PCM channels for the (sample, rate) pairs they can use
;   L_FEED   PDX file, streamed in pieces by the host: parse the table, allocate sample
;            space (most used first), decode the needed entries while the data passes:
;            MSM6258 ADPCM (x68sound compatible) -> the X68000's 183 Hz first-order
;            high-pass (coefficients per source rate) -> 8-bit signed
;   L_END    publish the sample directory to the PCM bank
;
; Sample space: banks pm_first..pm_last, 8064 bytes each ($A000-$BF7F) + a 128-byte
; mirror of the next bank's start ($BF80-$BFFF); every sample is followed by 64 zeros.
; While loading, the host's LUT area (pm_lut, >= 8 pages) holds the filter tables and
; the output buffer. Runs only while the song is stopped (uses the core's zero page).

.setcpu "65C02"
.macpack longbranch
.include "x16.inc"
.include "mx16.inc"

.importzp ma, t0, t1, t2, t3, t4, t5, t6, t7, rp, rq, rv
.importzp seqp, m0, r0
; more scratch for the decoder: the core's (idle while loading) zero page, in pairs
z0      = seqp
z1      = seqp+1
z2      = seqp+2
z3      = m0
z4      = m0+1
z5      = m0+2
z6      = m0+3
z7      = r0
z8      = r0+1
z9      = r0+2
z10     = r0+3
.import tk_n, tk_cur, pq_c, pr_c, t1lat
.import pcmbank, lo_bank, lo_rd, lo_wr, lo_put, lp_src, pcm_ok
.import la0, la1, la2, la3, lbase, mdx_len, cal_chip, cal_mhz, cal_clk, cal_banks
.import pm_first, pm_last, pm_lut, pm_slots
.import d_n, d_slo, d_shi, d_rate, d_bank, d_alo, d_ahi, d_l0, d_l1, d_l2
.export j_n, j_over, j_slo, j_shi, j_rate          ; (bank +3 x_pack reads the job table)

JSRFAR      = $FF6E
MEMTOP      = $FF99
AUDIO_BANK  = $0A
ym_get_chip_type = $C0A5

; job states
J_NEW       = 0                     ; wanted, not (yet) in the PDX table
J_TAB       = 1                     ; found in the table
J_ALLOC     = 2                     ; sample space allocated, decoding
J_DONE      = 3
J_NOROOM    = 4

; decoder zero page (the core is stopped)
d_pcm   = t0                        ; 2: ADPCM value (12-bit signed)
d_scale = t2
d_sidx  = t3                        ; (scale & 31) << 3
d_spg   = t4                        ; scale >> 5
d_s1    = t5                        ; 2: high-pass state (x2)
d_xp    = z1                        ; 2: previous x
d_t     = z3                        ; 2: temp
d_d     = z5                        ; 2: D = S1[n] - S1[n-1]
d_m     = z7                        ; 2: c * S
d_nib   = z9
d_oi    = z10                       ; output index
inptr   = ma

; ===========================================================================
.segment "LJMP"
        .word l_init, l_begin, l_feed, l_end, l_prog, l_tempo

; ===========================================================================
.segment "LRODATA"
; ADPCM magnitude per (scale, 3 nibble bits): (b2 ? d) + (b1 ? d/2) + (b0 ? d/4) + d/8
.include "adpcmtab.inc"
dct:    .byte $FF, $FF, $FF, $FF, 2, 4, 6, 8, $FF, $FF, $FF, $FF, 2, 4, 6, 8
; high-pass coefficients c = round((1 - exp(-2 pi 183 / rate)) * 65536) per rate: the
; X68000's 183 Hz first-order output high-pass (docs/api.md 4)
c1tab:  .word 16711, 12982, 8969, 6849, 4650
; MDX command argument bytes for $E0-$FF ($80 = stop the walk, $40 = special)
cmdlen: .byte $80, $80, $80, $80, $80, $80, $80, $40   ; E0-E7
        .byte 0, 1, $40, $40, $40, 1, 0, 1             ; E8-EF (ED special: 1)
        .byte 1, $80, 2, 2, 2, 2, 2, 0                 ; F0-F7 (F3 special: 2)
        .byte 1, 0, 0, 1, 1, 1, 2, 1                   ; F8-FF (FD special: 1)
e7len:  .byte $80, 1, 6, 1, 2, 1, 1

; ===========================================================================
.segment "LBSS"
tk_m:       .res 1                  ; l_tempo scratch (the core's zero page is in use)
tk_p:       .res 3
tk_v:       .res 4
tk_run:     .res 1
tk_d:       .res 2
tk_mh:      .res 1
cnt:        .res 3                  ; calibration
cyc:        .res 3
via_acr:    .res 1
tmp:        .res 4
; jobs = (sample, rate) pairs
j_n:        .res 1
j_slo:      .res NDIR
j_shi:      .res NDIR
j_rate:     .res NDIR
j_cntl:     .res NDIR               ; uses in the MDX (priority)
j_cnth:     .res NDIR
j_st:       .res NDIR
j_of0:      .res NDIR               ; PDX offset
j_of1:      .res NDIR
j_of2:      .res NDIR
j_ln0:      .res NDIR               ; length (bytes)
j_ln1:      .res NDIR
j_ln2:      .res NDIR
j_nx0:      .res NDIR               ; next file offset to decode
j_nx1:      .res NDIR
j_nx2:      .res NDIR
j_sb:       .res NDIR               ; start in sample space
j_sal:      .res NDIR
j_sah:      .res NDIR
j_ob:       .res NDIR               ; output position
j_oal:      .res NDIR
j_oah:      .res NDIR
j_pl:       .res NDIR               ; decoder state
j_ph:       .res NDIR
j_sc:       .res NDIR
j_s1l:      .res NDIR
j_s1h:      .res NDIR
j_xpl:      .res NDIR
j_xph:      .res NDIR
ord:        .res NDIR               ; allocated jobs by PDX offset
nord:       .res 1
ofirst:     .res 1
j_over:     .res 1                  ; more pairs than NDIR
; scanner
sc_ch:      .res 1
sc_p:       .res 2
sc_pass:    .res 1
sc_banks:   .res 32                 ; bitmap
sc_rates:   .res 1
sc_ndet:    .res 1
sc_det:     .res 4
sc_cnt:     .res 2
sc_note:    .res 1
; PDX parser
phase:      .res 1                  ; 0 table, 1 data, 2 done
fpos:       .res 3
tbl_end:    .res 3
ebyte:      .res 1
eidx:       .res 2
ent:        .res 8
cend:       .res 3
fin_n:      .res 2                  ; feed bytes left
cur_rate:   .res 1
abank:      .res 1                  ; allocation cursor
aaddr:      .res 2
missing:    .res 1
maxend:     .res 3                  ; end of the needed PDX data (progress)
pend:       .res 3
loaded:     .res 1
jj:         .res 1
kk:         .res 1
blk:        .res 1
rem:        .res 3
need:       .res 3
fl_n:       .res 1
fl_src:     .res 2
fl_k:       .res 1
outpage:    .res 1

; ===========================================================================
.segment "LCODE"
TLMAX       = $F000                 ; tick clock: longest T1 period (61440 cycles)

; l_tempo (tick clock): n = tk_n (0-255, from out_tempo), m = 256 - n. The Timer-B period
; is 2048 m cycles at 8 MHz = 1025 m / 256 samples. T1 period = that / k, k = 2^j the
; smallest with 256 m MHz / k <= TLMAX cycles: latch = 256 m MHz / k - 2, samples per
; period pq + pr / 2^19 = 1025 m / (256 k), both exact.
;   Y = 0: before play (T1 stopped): t1lat, pq_c/pr_c
;   Y = 2: tempo changed while playing (worker, after the tick): the T1 period in
;     progress, which started with this tick, gets the new length (counter = new latch -
;     time since its reload; the counter's high byte is read: within 128 cycles), the
;     latch too, so the next ticks fall on T1 interrupts again. Not done (tk_cur stays
;     old, the worker tries again at the next interrupt) if a reload is pending or the
;     tick took longer than the new period.
RTADJ       = 56                    ; cycles from reading T1CH to writing it
l_tempo:
        sty tk_run
        stz tk_mh
        lda tk_n
        eor #$FF
        inc a                           ; m (low byte)
        sta tk_m
        bne :+
        inc tk_mh                       ; n = 0: m = 256
:       stz tk_p                        ; tk_p = m * MHz * 256
        stz tk_p+1
        stz tk_p+2
        ldx cal_mhz
@mul:   clc
        lda tk_p+1
        adc tk_m
        sta tk_p+1
        lda tk_p+2
        adc tk_mh
        sta tk_p+2
        dex
        bne @mul
        lda tk_m                        ; tk_v = 1025 m * 2^11 (1025 m = m + m << 10;
        sta tk_v+1                      ; m = 256: [0, 1, 4] << 8)
        asl a
        asl a
        ora tk_mh
        sta tk_v+2
        lda tk_m
        rol a
        rol a
        rol a
        and #3
        ldx tk_mh
        beq :+
        lda #4
:       sta tk_v+3
        stz tk_v
        ldx #3
:       asl tk_v+1
        rol tk_v+2
        rol tk_v+3
        dex
        bne :-
@half:  lda tk_p+2                      ; halve both until tk_p <= TLMAX (exact)
        bne @h
        lda tk_p+1
        cmp #>TLMAX
        bcc @fit
        bne @h
        lda tk_p
        beq @fit
@h:     lsr tk_p+2
        ror tk_p+1
        ror tk_p
        lsr tk_v+3
        ror tk_v+2
        ror tk_v+1
        ror tk_v
        bra @half
@fit:   lda tk_v+2                      ; pr = tk_v & $7FFFF, pq = tk_v >> 19
        and #7
        sta tk_m
        ldx #3
:       lsr tk_v+3
        ror tk_v+2
        dex
        bne :-
        sec                             ; tk_p = latch
        lda tk_p
        sbc #2
        sta tk_p
        bcs :+
        dec tk_p+1
:       lda tk_run
        bne @rt
@set:   lda tk_p                        ; t1lat, pq_c/pr_c, tk_cur
        sta t1lat
        lda tk_p+1
        sta t1lat+1
        lda tk_v+2
        sta pq_c
        lda tk_v+3
        sta pq_c+1
        lda tk_v
        sta pr_c
        lda tk_v+1
        sta pr_c+1
        lda tk_m
        sta pr_c+2
        lda tk_n
        sta tk_cur
        rts
@rt:    php
        sei
        lda VIA1_IFR                    ; reload pending: later
        and #$40
        bne @rtx
        sec                             ; tk_d = time since the reload ~ t1lat - counter
        lda t1lat
        sbc #128
        sta tk_d
        lda t1lat+1
        sbc VIA1_T1CH
        sta tk_d+1
        bcc @rtx
        sec                             ; counter = new latch - tk_d - RTADJ
        lda tk_p
        sbc tk_d
        tax
        lda tk_p+1
        sbc tk_d+1
        tay
        bcc @rtx                        ; (the tick took longer than the new period)
        txa
        sec
        sbc #RTADJ
        tax
        tya
        sbc #0
        bcc @rtx
        cmp #2                          ; (at least 512 cycles left)
        bcc @rtx
        stx VIA1_T1LL
        sta VIA1_T1CH                   ; counter = A:X, the period in progress goes on
        lda tk_p                        ; latch for the following periods
        sta VIA1_T1LL
        lda tk_p+1
        sta VIA1_T1LH
        jsr @set
@rtx:   plp
        rts

; ---------------------------------------------------------------------------
l_init:                                 ; (LOWA-LOWD: copied by the PCM bank)
        sec
        jsr MEMTOP
        sta cal_banks
        jsr JSRFAR                      ; YM chip type from the KERNAL audio bank
        .word ym_get_chip_type
        .byte AUDIO_BANK
        cmp #3
        bcc :+
        lda #0
:       sta cal_chip
        jsr measure_cpu                 ; -> cal_mhz
        jmp measure_opm                 ; -> cal_clk

; measure_cpu: CPU cycles per VERA frame (59.524 Hz) with VIA1 T1 -> MHz (rounded)
measure_cpu:
        jsr t1_freerun
        lda #1
        sta VERA_ISR
:       lda VERA_ISR                    ; wait for a VSYNC edge
        and #1
        beq :-
        lda #1
        sta VERA_ISR
        jsr t1_restart
        stz cnt
        stz cnt+1
@l:     lda VIA1_IFR
        and #$40
        beq :+
        lda VIA1_T1CL
        inc cnt
:       lda VERA_ISR
        and #1
        beq @l
        jsr t1_cycles                   ; cyc = cnt * 65537 + (65535 - counter)
        ; mhz = round(cycles / 16800)   (1 MHz = 16800 cycles per frame)
        stz cal_mhz
        lda #<8400                      ; + 0.5 for rounding
        clc
        adc cyc
        sta cyc
        lda cyc+1
        adc #>8400
        sta cyc+1
        bcc @div
        inc cyc+2
@div:   sec
        lda cyc
        sbc #<16800
        tax
        lda cyc+1
        sbc #>16800
        tay
        lda cyc+2
        sbc #0
        bcc @dd
        sta cyc+2
        stx cyc
        sty cyc+1
        inc cal_mhz
        bra @div
@dd:    lda cal_mhz
        bne :+
        lda #8                          ; measurement failed: assume 8 MHz
        sta cal_mhz
:       jmp t1_restore

; measure_opm: 4 periods of YM Timer-A (CLKA = 0 -> 65536 / phiM each, same on OPP)
;   3.579545 MHz -> 73.24 ms, 4 MHz -> 65.54 ms. Threshold at 3.79 MHz:
;   cycles(4 periods) at MHz m = 4 * 65536 * m / 3.79 = m * 69166
measure_opm:
        lda #$FF
        sta cal_clk
        jsr t1_freerun
        lda #0
        ldy #$10
        jsr ym_raw
        ldy #$11
        jsr ym_raw
        lda #$15                        ; reset flag A, start timer A (no IRQ)
        ldy #$14
        jsr ym_raw
        jsr t1_restart                  ; wait for the first overflow (timeout ~ 0.5 s)
        stz cnt
@w1:    jsr opm_poll
        bcs @t
        lda YM_DATA
        and #$01
        beq @w1
        lda #$15
        ldy #$14
        jsr ym_raw
        jsr t1_restart
        stz cnt
        stz cnt+1
        lda #4
        sta tmp
@w2:    jsr opm_poll
        bcs @t
        lda YM_DATA
        and #$01
        beq @w2
        lda #$15
        ldy #$14
        jsr ym_raw
        dec tmp
        bne @w2
        jsr t1_cycles
        stz cnt                         ; threshold = mhz * 69166 (24-bit)
        stz cnt+1
        stz cnt+2
        ldx cal_mhz
@m:     clc
        lda cnt
        adc #<69166
        sta cnt
        lda cnt+1
        adc #>69166
        sta cnt+1
        lda cnt+2
        adc #^69166
        sta cnt+2
        dex
        bne @m
        lda cyc                         ; cycles > threshold -> 3.58 MHz
        cmp cnt
        lda cyc+1
        sbc cnt+1
        lda cyc+2
        sbc cnt+2
        lda #0
        bcs :+
        lda #1
:       sta cal_clk
@t:     lda #$30                        ; stop timers, reset flags
        ldy #$14
        jsr ym_raw
        jmp t1_restore

; opm_poll: count T1 wraps; C = 1 after 64 wraps (~0.5 s at 8 MHz) = timeout
opm_poll:
        lda VIA1_IFR
        and #$40
        beq @n
        lda VIA1_T1CL
        inc cnt
        lda cnt
        cmp #64
        bcs @r
@n:     clc
@r:     rts

t1_freerun:
        lda VIA1_ACR
        sta via_acr
        and #$3F
        ora #$40
        sta VIA1_ACR
        lda #$FF
        sta VIA1_T1LL
        sta VIA1_T1LH
        rts
t1_restart:
        lda #$FF
        sta VIA1_T1CL
        sta VIA1_T1CH
        lda VIA1_T1CL                   ; clear flag
        rts
t1_restore:
        lda #$FF
        sta VIA1_T1LL
        sta VIA1_T1LH
        lda via_acr
        sta VIA1_ACR
        rts
; cyc = cnt * 65537 + (65535 - T1 counter)
t1_cycles:
        lda VIA1_T1CH
        sta tmp+1
        lda VIA1_T1CL
        eor #$FF
        sta cyc
        lda tmp+1
        eor #$FF
        sta cyc+1
        clc                             ; + cnt * 65536 + cnt
        lda cyc
        adc cnt
        sta cyc
        lda cyc+1
        adc cnt+1
        sta cyc+1
        lda #0
        adc cnt
        sta cyc+2
        rts

; ym_raw: write A to YM register Y (busy wait with timeout). A, X, Y preserved.
ym_raw: bit YM_DATA
        bpl @go
        phx
        ldx #0
@bw:    bit YM_DATA
        bpl @bx
        dex
        bne @bw
@bx:    plx
@go:    sty YM_ADDR
        nop
        nop
        nop
        nop
        nop
        sta YM_DATA
        rts

; ---------------------------------------------------------------------------
; MDX access: A = byte at body offset sc_p, sc_p += 1
sc_rd:  clc
        lda sc_p
        adc lbase
        sta rp
        lda sc_p+1
        adc lbase+1
        sta rq
        lda #0
        adc lbase+2
        asl rq
        rol a
        asl rq
        rol a
        asl rq
        rol a
        sta lo_bank
        lda rq
        lsr a
        lsr a
        lsr a
        ora #$A0
        sta rp+1
        inc sc_p
        bne :+
        inc sc_p+1
:       jmp lo_rd

; C = 1 when sc_p is outside the MDX body
sc_end: lda sc_p
        cmp mdx_len
        lda sc_p+1
        sbc mdx_len+1
        rts

; ---------------------------------------------------------------------------
; l_begin: scan the MDX, reset the PDX parser -> A = pairs, C = 1 PCM not possible
l_begin:
        lda pcm_ok
        bne :+
        lda #0
        sec
        rts
:       stz j_n
        stz j_over
        lda #8
        sta sc_ch
@ch:    lda sc_ch                       ; channel offset: body[2 + 2 * ch] (big endian)
        asl a
        clc
        adc #2
        sta sc_p
        stz sc_p+1
        jsr sc_rd
        pha
        jsr sc_rd
        sta sc_p
        pla
        sta sc_p+1
        lda sc_p
        pha
        lda sc_p+1
        pha
        ldx #31                         ; pass 1: banks, rates, detunes
:       stz sc_banks,x
        dex
        bpl :-
        lda #1
        sta sc_banks
        lda #$10                        ; rate 4
        sta sc_rates
        lda #1
        sta sc_ndet
        stz sc_det
        stz sc_pass
        jsr walk
        pla                             ; pass 2: notes
        sta sc_p+1
        pla
        sta sc_p
        inc sc_pass
        jsr walk
        inc sc_ch
        lda sc_ch
        cmp #16
        bne @ch
        ; reset the parser
        stz phase
        stz fpos
        stz fpos+1
        stz fpos+2
        lda #$FF
        sta tbl_end
        sta tbl_end+1
        sta tbl_end+2
        sta cur_rate
        stz ebyte
        stz eidx
        stz eidx+1
        stz nord
        stz ofirst
        stz missing
        stz loaded
        stz maxend
        stz maxend+1
        stz maxend+2
        lda pm_first
        sta abank
        stz aaddr
        lda #$A0
        sta aaddr+1
        lda pm_lut                      ; output buffer: 7th page of the LUT area
        clc
        adc #6
        sta outpage
        lda j_n
        bne :+
        lda #2                          ; nothing to load
        sta phase
        lda #0
:       clc
        rts

; walk: one channel from sc_p (pass sc_pass)
walk:   stz sc_cnt
        stz sc_cnt+1
@l:     inc sc_cnt                      ; (bounded)
        bne :+
        inc sc_cnt+1
        jeq @r
:       jsr sc_end
        jcs @r
        jsr sc_rd
        cmp #$80
        bcc @l                          ; rest
        cmp #$E0
        bcs @cmd
        sbc #$7F                        ; note 0..95 (C = 0: -$80)
        sta sc_note
        jsr sc_rd                       ; length
        lda sc_pass
        beq @l
        jsr add_note
        bra @l
@cmd:   tax
        lda cmdlen-$E0,x
        jmi @r                          ; end of the channel
        cmp #$40
        jeq @spec
        cpx #$FD
        beq @bank
        cpx #$ED
        beq @rate
        cpx #$F3
        beq @det
@skip:  tax                             ; skip A bytes
        beq @l
:       jsr sc_rd
        dex
        bne :-
        bra @l
@bank:  jsr sc_rd
        tax
        and #7
        tay
        txa
        lsr a
        lsr a
        lsr a
        tax
        lda sc_banks,x
        ora bitv,y
        sta sc_banks,x
        bra @l
@rate:  jsr sc_rd
        and #7
        tay
        lda sc_rates
        ora bitv,y
        sta sc_rates
        jmp @l
@det:   jsr sc_rd                       ; d = (det + 5) >> 6 (signed)
        sta tmp+1
        jsr sc_rd
        clc
        adc #5
        sta tmp
        bcc :+
        inc tmp+1
:       ldy #6
:       lda tmp+1
        cmp #$80
        ror tmp+1
        ror tmp
        dey
        bne :-
        lda tmp
        ldx sc_ndet                     ; add to the set (max 4)
:       dex
        bmi @dadd
        cmp sc_det,x
        jeq @l
        bra :-
@dadd:  ldx sc_ndet
        cpx #4
        jcs @l
        sta sc_det,x
        inc sc_ndet
        jmp @l
@spec:  cpx #$E7
        beq @e7
        jsr sc_rd                       ; $EA-$EC: type, 4 more unless bit 7
        jmi @l
        lda #4
        jmp @skip
@e7:    jsr sc_rd
        cmp #7
        jcs @l
        tax
        lda e7len,x
        bmi @r
        jmp @skip
@r:     rts

bitv:   .byte 1, 2, 4, 8, 16, 32, 64, 128

; add_note: sc_note with every (detune, bank, rate) of the channel
add_note:
        ldx sc_ndet
@d:     dex
        bmi @r
        phx
        lda sc_note                     ; idx = clamp(note + d, 0, 95)
        clc
        adc sc_det,x
        bpl :+
        lda #0
:       cmp #96
        bcc :+
        lda #95
:       sta tmp+2
        ldy #0                          ; banks
@b:     tya
        and #7
        tax
        lda bitv,x
        sta rq                          ; bit mask
        tya
        lsr a
        lsr a
        lsr a
        tax
        lda sc_banks,x
        and rq
        beq @nb
        ; sample = idx + 96 * bank
        sty tmp+3
        stz tmp+1
        lda tmp+2
        sta tmp
        cpy #0
        beq @rt
:       clc
        lda tmp
        adc #96
        sta tmp
        bcc :+
        inc tmp+1
:       dey
        bne :--
@rt:    ldx #0                          ; rates 0..4
:       lda sc_rates
        and bitv,x
        beq :+
        phx
        jsr add_job
        plx
:       inx
        cpx #5
        bne :--
        ldy tmp+3
@nb:    iny
        bne @b
        plx
        bra @d
@r:     rts

; add_job: sample tmp/tmp+1, rate X: count a use (X, Y clobbered; tmp+3 kept)
add_job:
        stx rv
        ldx j_n
@f:     dex
        bmi @new
        lda j_slo,x
        cmp tmp
        bne @f
        lda j_shi,x
        cmp tmp+1
        bne @f
        lda j_rate,x
        cmp rv
        bne @f
        inc j_cntl,x
        bne @r
        inc j_cnth,x
        bne @r
        dec j_cnth,x                    ; saturate
        dec j_cntl,x
@r:     rts
@new:   ldx j_n
        cpx #NDIR
        bcc :+
        lda #1
        sta j_over
        rts
:       lda tmp
        sta j_slo,x
        lda tmp+1
        sta j_shi,x
        lda rv
        sta j_rate,x
        lda #1
        sta j_cntl,x
        stz j_cnth,x
        stz j_st,x
        inc j_n
        rts

; ---------------------------------------------------------------------------
; l_feed: la0/la1 = buffer, la2/la3 = length -> C = 1 when everything was received
l_feed:
        lda la0
        sta inptr
        lda la1
        sta inptr+1
        lda la2
        sta fin_n
        lda la3
        sta fin_n+1
        lda phase
        bne @data
@tab:   lda fin_n                       ; table phase: byte by byte
        ora fin_n+1
        beq @ret
        lda (inptr)
        jsr in_adv
        ldx ebyte
        sta ent,x
        inx
        stx ebyte
        cpx #8
        bne @tab
        stz ebyte
        jsr tab_entry
        inc eidx
        bne :+
        inc eidx+1
:       lda fpos                        ; end of the table?
        cmp tbl_end
        lda fpos+1
        sbc tbl_end+1
        lda fpos+2
        sbc tbl_end+2
        bcc @tab
        lda #1
        sta phase
        jsr layout                      ; (sets phase 2 if there is nothing to decode)
        lda phase
@data:  cmp #2
        beq @ret
        lda fin_n
        ora fin_n+1
        beq @ret
        jsr data_chunk
@ret:   lda phase                       ; C = 1: done
        cmp #2
        beq :+
        clc
        rts
:       sec
        rts

; in_adv: consume one input byte (A kept)
in_adv: inc inptr
        bne :+
        inc inptr+1
:       inc fpos
        bne :+
        inc fpos+1
        bne :+
        inc fpos+2
:       ldy fin_n
        bne :+
        dec fin_n+1
:       dec fin_n
        rts

; tab_entry: ent = offset (BE32), length (BE32) of entry eidx
tab_entry:
        lda ent                         ; offsets >= 16 MB: ignore
        jne @r
        lda ent+1
        ora ent+2
        ora ent+3
        jeq @r                          ; empty
        lda ent+3                       ; table end = smallest offset
        cmp tbl_end
        lda ent+2
        sbc tbl_end+1
        lda ent+1
        sbc tbl_end+2
        bcs :+
        lda ent+3
        sta tbl_end
        lda ent+2
        sta tbl_end+1
        lda ent+1
        sta tbl_end+2
:       lda ent+4                       ; length < 16 MB, not 0
        bne @r
        lda ent+5
        ora ent+6
        ora ent+7
        beq @r
        ldx j_n
@f:     dex
        bmi @r
        lda j_slo,x
        cmp eidx
        bne @f
        lda j_shi,x
        cmp eidx+1
        bne @f
        lda ent+3
        sta j_of0,x
        sta j_nx0,x
        lda ent+2
        sta j_of1,x
        sta j_nx1,x
        lda ent+1
        sta j_of2,x
        sta j_nx2,x
        lda ent+7
        sta j_ln0,x
        lda ent+6
        sta j_ln1,x
        lda ent+5
        sta j_ln2,x
        lda #J_TAB
        sta j_st,x
        bra @f
@r:     rts

; layout: allocate sample space by use count, order the jobs by PDX offset
layout:
@pick:  ldx j_n                         ; most used J_TAB job
        ldy #$FF
        stz tmp
        stz tmp+1
@f:     dex
        bmi @got
        lda j_st,x
        cmp #J_TAB
        bne @f
        cpy #$FF
        beq @take
        lda j_cntl,x
        cmp tmp
        lda j_cnth,x
        sbc tmp+1
        bcc @f
@take:  txa
        tay
        lda j_cntl,x
        sta tmp
        lda j_cnth,x
        sta tmp+1
        bra @f
@got:   cpy #$FF
        beq @order
        sty jj
        jsr alloc
        bra @pick
@order: ldx #0                          ; ord = J_ALLOC jobs, insertion by offset
@o:     cpx j_n
        bcs @r
        lda j_st,x
        cmp #J_ALLOC
        bne @on
        ldy nord                        ; shift larger offsets up
@ins:   dey
        bmi @put
        phx
        lda ord,y
        tax
        lda j_of0,x                     ; ord[y] offset > new offset ?
        sta tmp
        lda j_of1,x
        sta tmp+1
        lda j_of2,x
        sta tmp+2
        plx
        lda tmp
        cmp j_of0,x
        lda tmp+1
        sbc j_of1,x
        lda tmp+2
        sbc j_of2,x
        bcc @put                        ; ord[y] < new: insert after it
        lda ord,y
        sta ord+1,y
        bra @ins
@put:   iny
        txa
        sta ord,y
        inc nord
@on:    inx
        bra @o
@r:     lda nord
        bne :+
        lda #2                          ; nothing to decode
        sta phase
:       rts

; alloc: job jj -> J_ALLOC at the cursor, or J_NOROOM
alloc:  ldx jj
        lda j_ln0,x                     ; need = 2 * length + SPAD
        asl a
        sta need
        lda j_ln1,x
        rol a
        sta need+1
        lda j_ln2,x
        rol a
        sta need+2
        clc
        lda need
        adc #SPAD
        sta need
        bcc :+
        inc need+1
        bne :+
        inc need+2
:       ; rem = (pm_last - abank) * 8064 + ($BF80 - aaddr)
        sec
        lda #$80
        sbc aaddr
        sta rem
        lda #$BF
        sbc aaddr+1
        sta rem+1
        stz rem+2
        lda pm_last
        sec
        sbc abank
        tay
        beq @cmp
:       clc
        lda rem
        adc #<SBANK_DATA
        sta rem
        lda rem+1
        adc #>SBANK_DATA
        sta rem+1
        bcc :+
        inc rem+2
:       dey
        bne :--
@cmp:   lda rem
        cmp need
        lda rem+1
        sbc need+1
        lda rem+2
        sbc need+2
        bcs @fit
        lda #J_NOROOM
        sta j_st,x
        inc missing
        rts
@fit:   lda #J_ALLOC
        sta j_st,x
        clc                             ; maxend = max(maxend, offset + length)
        lda j_of0,x
        adc j_ln0,x
        sta pend
        lda j_of1,x
        adc j_ln1,x
        sta pend+1
        lda j_of2,x
        adc j_ln2,x
        sta pend+2
        lda maxend
        cmp pend
        lda maxend+1
        sbc pend+1
        lda maxend+2
        sbc pend+2
        bcs :+
        lda pend
        sta maxend
        lda pend+1
        sta maxend+1
        lda pend+2
        sta maxend+2
:
        lda abank
        sta j_sb,x
        sta j_ob,x
        lda aaddr
        sta j_sal,x
        sta j_oal,x
        lda aaddr+1
        sta j_sah,x
        sta j_oah,x
        stz j_pl,x                      ; decoder state
        stz j_ph,x
        stz j_sc,x
        stz j_s1l,x
        stz j_s1h,x
        stz j_xpl,x
        stz j_xph,x
        ; cursor += need (8064 per bank)
        clc
        lda aaddr
        adc need
        sta aaddr
        lda aaddr+1
        adc need+1
        sta aaddr+1
        lda need+2
        adc #0
        sta rem+2                       ; (bits 16.. of the new address)
@norm:  lda aaddr                       ; while aaddr >= $BF80: -= 8064, bank++
        cmp #$80
        lda aaddr+1
        sbc #$BF
        lda rem+2
        sbc #0
        bcc @r
        sec
        lda aaddr
        sbc #<SBANK_DATA
        sta aaddr
        lda aaddr+1
        sbc #>SBANK_DATA
        sta aaddr+1
        lda rem+2
        sbc #0
        sta rem+2
        inc abank
        bra @norm
@r:     rts

; ---------------------------------------------------------------------------
; data_chunk: fin_n bytes at inptr = file positions fpos .. cend
data_chunk:
        clc
        lda fpos
        adc fin_n
        sta cend
        lda fpos+1
        adc fin_n+1
        sta cend+1
        lda fpos+2
        adc #0
        sta cend+2
        lda ofirst
        sta kk
@k:     ldx kk
        cpx nord
        bcs @end
        lda ord,x
        sta jj
        tax
        lda j_of0,x                     ; job starts at or after cend: stop
        cmp cend
        lda j_of1,x
        sbc cend+1
        lda j_of2,x
        sbc cend+2
        bcs @end
        lda j_st,x
        cmp #J_DONE
        beq @kn
        jsr job_run
@kn:    inc kk
        bra @k
@end:   ldx ofirst                      ; skip finished jobs
:       cpx nord
        bcs :+
        ldy ord,x
        lda j_st,y
        cmp #J_DONE
        bne :+
        inx
        bra :-
:       stx ofirst
        cpx nord
        bcc :+
        lda #2
        sta phase
:       lda cend                        ; consumed
        sta fpos
        lda cend+1
        sta fpos+1
        lda cend+2
        sta fpos+2
        rts

; job_run: decode job jj's bytes inside this chunk
;   from s = j_nx (>= fpos) to e = min(j_of + j_ln, cend)
job_run:
        ldx jj
        lda j_rate,x                    ; filter tables for this rate (uses rem/need)
        cmp cur_rate
        beq :+
        jsr build_hpf
        ldx jj
:       clc                             ; rem = end of the job
        lda j_of0,x
        adc j_ln0,x
        sta rem
        lda j_of1,x
        adc j_ln1,x
        sta rem+1
        lda j_of2,x
        adc j_ln2,x
        sta rem+2
        lda rem                         ; e = min(rem, cend) -> need
        cmp cend
        lda rem+1
        sbc cend+1
        lda rem+2
        sbc cend+2
        bcc :+
        lda cend
        sta need
        lda cend+1
        sta need+1
        lda cend+2
        sta need+2
        bra :++
:       lda rem
        sta need
        lda rem+1
        sta need+1
        lda rem+2
        sta need+2
:       ; input pointer = la0/la1 + (j_nx - chunk start), chunk start = cend - la2/la3
        sec
        lda cend
        sbc la2
        sta tmp
        lda cend+1
        sbc la3
        sta tmp+1                       ; (low 16 bits are enough for the difference)
        sec
        lda j_nx0,x
        sbc tmp
        sta tmp
        lda j_nx1,x
        sbc tmp+1
        sta tmp+1
        clc
        lda la0
        adc tmp
        sta inptr
        lda la1
        adc tmp+1
        sta inptr+1
        jsr st_load
@blk:   ldx jj                          ; bytes left in this chunk: need - j_nx
        sec
        lda need
        sbc j_nx0,x
        sta tmp
        lda need+1
        sbc j_nx1,x
        sta tmp+1
        lda need+2
        sbc j_nx2,x
        ora tmp+1
        bne @b120
        lda tmp
        beq @stop
        cmp #120
        bcc @bset
@b120:  lda #120
@bset:  sta blk
        jsr dec_block                   ; blk bytes -> 2 * blk output
        ldx jj
        clc
        lda j_nx0,x
        adc blk
        sta j_nx0,x
        bcc :+
        inc j_nx1,x
        bne :+
        inc j_nx2,x
:       lda blk
        asl a
        sta fl_n
        jsr flush
        bra @blk
@stop:  jsr st_save
        ldx jj                          ; finished?
        lda j_nx0,x
        cmp rem
        bne @r
        lda j_nx1,x
        cmp rem+1
        bne @r
        lda j_nx2,x
        cmp rem+2
        bne @r
        ldy #SPAD-1                     ; trailing zeros
        lda #0
        sta fl_src
:       jsr out_put0
        dey
        bpl :-
        lda #SPAD
        sta fl_n
        jsr flush
        ldx jj
        lda #J_DONE
        sta j_st,x
@r:     rts

; out_put0: zero byte to the output buffer at index Y
out_put0:
        lda outpage
        sta op0+2
        lda #0
op0:    sta $FF00,y
        rts

st_load:
        ldx jj
        lda j_pl,x
        sta d_pcm
        lda j_ph,x
        sta d_pcm+1
        lda j_sc,x
        jsr set_scale
        lda j_s1l,x
        sta d_s1
        lda j_s1h,x
        sta d_s1+1
        lda j_xpl,x
        sta d_xp
        lda j_xph,x
        sta d_xp+1
        rts

st_save:
        ldx jj
        lda d_pcm
        sta j_pl,x
        lda d_pcm+1
        sta j_ph,x
        lda d_scale
        sta j_sc,x
        lda d_s1
        sta j_s1l,x
        lda d_s1+1
        sta j_s1h,x
        lda d_xp
        sta j_xpl,x
        lda d_xp+1
        sta j_xph,x
        rts

; set_scale: A = scale -> d_scale, d_sidx, d_spg (X kept)
set_scale:
        sta d_scale
        asl a
        asl a
        asl a
        sta d_sidx
        lda d_scale
        cmp #32
        lda #0
        rol a
        sta d_spg
        rts

; flush: fl_n bytes (1..255) of the output buffer to job jj's output position,
; split at bank ends, mirrored into the previous bank's last 128 bytes
flush:  stz fl_src
@l:     lda fl_n
        jeq @r
        ldx jj                          ; k = min(n, $BF80 - addr)
        sec
        lda #$80
        sbc j_oal,x
        sta tmp
        lda #$BF
        sbc j_oah,x
        bne @kn                         ; >= 256
        lda tmp
        cmp fl_n
        bcc @kk
@kn:    lda fl_n
@kk:    sta fl_k
        lda j_ob,x
        sta lo_bank
        lda j_oal,x
        sta rp
        lda j_oah,x
        sta rp+1
        lda fl_src
        sta lp_src
        lda outpage
        sta lp_src+1
        ldx fl_k
        jsr lo_put
        ldx jj                          ; mirror: offset < 128 and not the first bank
        lda j_oah,x
        cmp #$A0
        bne @nm
        lda j_oal,x
        bmi @nm
        lda j_ob,x
        cmp pm_first
        beq @nm
        dec a
        sta lo_bank
        lda j_oal,x                     ; mk = min(k, 128 - offset)
        ora #$80
        sta rp
        lda #$BF
        sta rp+1
        sec
        lda #128
        sbc j_oal,x
        cmp fl_k
        bcc :+
        lda fl_k
:       tax
        lda fl_src
        sta lp_src
        jsr lo_put
@nm:    ldx jj                          ; addr += k; wrap to the next bank
        clc
        lda j_oal,x
        adc fl_k
        sta j_oal,x
        bcc :+
        inc j_oah,x
:       lda j_oah,x
        cmp #$BF
        bne :+
        lda j_oal,x
        cmp #$80
        bne :+
        stz j_oal,x
        lda #$A0
        sta j_oah,x
        inc j_ob,x
:       clc
        lda fl_src
        adc fl_k
        sta fl_src
        sec
        lda fl_n
        sbc fl_k
        sta fl_n
        jmp @l
@r:     rts

; ---------------------------------------------------------------------------
; build_hpf: c * b tables for rate j_rate[jj] in the LUT area
;   pages +0/+1 Th lo/hi, +2 Tl (+3..+5 unused, +6 the output buffer)
;   Th[b] = round(c * b * 256) for b = -128..127 (signed), Tl[b] = round(c * b), b = 0..255
build_hpf:
        ldx jj
        lda j_rate,x
        sta cur_rate
        asl a
        tay
        lda c1tab,y
        sta tmp
        lda c1tab+1,y
        sta tmp+1
        lda pm_lut
        ; fall through
; hpf_tab: tmp = c (x 65536), A = first page (Th lo, Th hi, Tl)
hpf_tab:
        sta ht_hl1+2
        sta ht_hl2+2
        inc a
        sta ht_hh1+2
        sta ht_hh2+2
        inc a
        sta ht_l+2
        stz rem                         ; acc = b * c (24-bit)
        stz rem+1
        stz rem+2
        ldx #0
ht_lp:  lda rem+1                       ; Tl[b] = (acc + $8000) >> 16
        cmp #$80
        lda rem+2
        adc #0
ht_l:   sta $FF00,x
        cpx #129                        ; Th for b = 0..128
        bcs ht_nx
        lda rem                         ; v = (acc + 128) >> 8
        cmp #$80
        lda rem+1
        adc #0
        sta need
        lda rem+2
        adc #0
        sta need+1
        cpx #128
        bcs :+
        lda need
ht_hl1: sta $FF00,x
        lda need+1
ht_hh1: sta $FF00,x
:       txa                             ; Th[-b] = -v
        beq ht_nx
        eor #$FF
        inc a
        tay
        sec
        lda #0
        sbc need
ht_hl2: sta $FF00,y
        lda #0
        sbc need+1
ht_hh2: sta $FF00,y
ht_nx:  clc
        lda rem
        adc tmp
        sta rem
        lda rem+1
        adc tmp+1
        sta rem+1
        bcc :+
        inc rem+2
:       inx
        bne ht_lp
        ; patch the decoder's table operands
        lda pm_lut
        sta dh_1l+2
        inc a
        sta dh_1h+2
        inc a
        sta dh_1s+2
        clc
        adc #4
        sta dh_out+2
        rts

; ---------------------------------------------------------------------------
; dec_block: blk input bytes at inptr -> 2 * blk samples at the output buffer [0..)
dec_block:
        stz d_oi
        ldy #0
@b:     lda (inptr),y
        phy
        pha
        and #$0F
        jsr dec_nib
        pla
        lsr a
        lsr a
        lsr a
        lsr a
        jsr dec_nib
        ply
        iny
        cpy blk
        bne @b
        clc
        tya
        adc inptr
        sta inptr
        bcc :+
        inc inptr+1
:       rts

; dec_nib: A = ADPCM nibble -> one output sample
dec_nib:
        sta d_nib
        and #$07
        ora d_sidx
        tax
        lda d_spg
        bne @p1
        lda mag0l,x
        sta d_t
        lda mag0h,x
        sta d_t+1
        bra @g
@p1:    lda mag1l,x
        sta d_t
        lda mag1h,x
        sta d_t+1
@g:     lda d_nib
        and #$08
        bne @neg
        clc                             ; pcm += v, clamp 2047
        lda d_pcm
        adc d_t
        sta d_pcm
        lda d_pcm+1
        adc d_t+1
        bmi @st
        cmp #$08
        bcc @st
        lda #$FF
        sta d_pcm
        lda #$07
        bra @st
@neg:   sec                             ; pcm -= v, clamp -2047
        lda d_pcm
        sbc d_t
        sta d_pcm
        lda d_pcm+1
        sbc d_t+1
        bpl @st
        cmp #$F8
        bcc @cl
        bne @st
        ldx d_pcm                       ; $F8xx: only $F800 is below -2047
        bne @st
@cl:    lda #$01
        sta d_pcm
        lda #$F8
@st:    sta d_pcm+1
        ldx d_nib                       ; scale += dct[nib], clamp 0..48
        lda d_scale
        clc
        adc dct,x
        bpl :+
        lda #0
:       cmp #49
        bcc :+
        lda #48
:       jsr set_scale
        ; ---- high-pass (x2 fixed point), x = pcm & ~3
        lda d_pcm                       ; D = 2 * (x - xp) - c1 * S1; xp = x
        and #$FC
        tax
        sec
        sbc d_xp
        sta d_d
        lda d_pcm+1
        tay
        sbc d_xp+1
        sta d_d+1
        stx d_xp
        sty d_xp+1
        asl d_d
        rol d_d+1
        ldx d_s1+1                      ; m = c1 * S1
dh_1l:  lda $FF00,x
        sta d_m
dh_1h:  lda $FF00,x
        sta d_m+1
        ldx d_s1
        clc
dh_1s:  lda $FF00,x
        adc d_m
        sta d_m
        bcc :+
        inc d_m+1
:       sec
        lda d_d
        sbc d_m
        sta d_d
        lda d_d+1
        sbc d_m+1
        sta d_d+1
        clc                             ; S1 = sat(S1 + D)
        lda d_s1
        adc d_d
        sta d_s1
        lda d_s1+1
        adc d_d+1
        bvc @s1ok
        lda d_d+1
        bmi :+
        lda #$FF
        sta d_s1
        lda #$7F
        bra @s1ok
:       stz d_s1
        lda #$80
@s1ok:  sta d_s1+1
        ; out = clip8((S1 + 16) >> 5)
        clc
        lda d_s1
        adc #16
        sta d_t
        lda d_s1+1
        adc #0
        bvs @pos
        sta d_t+1
        clc
        adc #$10
        and #$E0
        bne @sat
        lda d_t+1
        asl a
        asl a
        asl a
        sta d_t+1
        lda d_t
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        ora d_t+1
        bra @out
@sat:   lda d_t+1
        bmi @negs
@pos:   lda #$7F
        bra @out
@negs:  lda #$80
@out:   ldx d_oi
dh_out: sta $FF00,x
        inc d_oi
        rts

; ---------------------------------------------------------------------------
; l_prog: progress of the PDX load -> la0/la1 = bytes read >> 8, la2/la3 = end of the
; needed data >> 8 (0 while the table is being read); equal when everything was received
l_prog: lda fpos+1
        sta la0
        lda fpos+2
        sta la1
        lda maxend+1
        sta la2
        lda maxend+2
        sta la3
        lda phase
        cmp #2
        bne :+
        lda la2
        sta la0
        lda la3
        sta la1
:       rts

; ---------------------------------------------------------------------------
; l_end: publish loaded entries to the PCM bank -> A = missing, la0 = loaded, la1 = banks
l_end:  ldx #0
        stz loaded
@j:     cpx j_n
        bcs @pub
        lda j_st,x
        cmp #J_ALLOC                    ; file ended before the data
        bne :+
        inc missing
:       inx
        bra @j
@pub:   lda pcmbank
        sta lo_bank
        ldx #0
@p:     cpx j_n
        bcs @fin
        lda j_st,x
        cmp #J_DONE
        bne @pn
        stx z0
        lda loaded
        sta z1
        ldy #8                          ; 9 fields
@fl:    lda srctab_l,y
        sta @src+1
        lda srctab_h,y
        sta @src+2
@src:   lda $FFFF,x
        pha
        clc
        lda dsttab_l,y
        adc z1
        sta rp
        lda dsttab_h,y
        adc #0
        sta rp+1
        pla
        jsr lo_wr
        dey
        bpl @fl
        inc loaded
@pn:    inx
        bra @p
@fin:   lda #<d_n
        sta rp
        lda #>d_n
        sta rp+1
        lda loaded
        jsr lo_wr
        sta la0
        lda abank
        sec
        sbc pm_first
        inc a
        sta la1
        lda j_over                      ; the scan found more than NDIR pairs
        sta la2
        lda missing
        rts

srctab_l: .byte <j_slo, <j_shi, <j_rate, <j_sb, <j_sal, <j_sah, <j_ln0, <j_ln1, <j_ln2
srctab_h: .byte >j_slo, >j_shi, >j_rate, >j_sb, >j_sal, >j_sah, >j_ln0, >j_ln1, >j_ln2
dsttab_l: .byte <d_slo, <d_shi, <d_rate, <d_bank, <d_alo, <d_ahi, <d_l0, <d_l1, <d_l2
dsttab_h: .byte >d_slo, >d_shi, >d_rate, >d_bank, >d_alo, >d_ahi, >d_l0, >d_l1, >d_l2
