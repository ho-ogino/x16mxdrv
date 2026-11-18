; mxlow.s - X16MXDRV low RAM part ($0400-$07FF, golden RAM) and shared zero page.
;
; The load images of LOWA-LOWD are in bank +3; api_init has x_low copy them (JSRFAR)
; before anything else. Everything here can be reached from all driver banks.
; Bank +3 also holds the worker's unrolled zero page save / restore (x_zsave / x_zrest).
;
;   LOWA $0400-$04BF  shared bank numbers, IRQ entry, far-call trampolines
;   LOWB $0500-$05BF  bank memory access helpers, mixer: first voice, one voice
;   LOWC $0600-$06BF  mixer: add voice, resampler; worker's bank +3 calls (lo_zsv / lo_zrs)
;   LOWD $0700-$07FF  shared variables (+ YMLOG debug logger)
;   mix buffers $04C0, $05C0, $06C0 (64 bytes each)

.setcpu "65C02"
.include "x16.inc"
.include "mx16.inc"

.import worker
.import __LOWA_LOAD__, __LOWA_RUN__, __LOWA_SIZE__
.import __LOWB_LOAD__, __LOWB_RUN__, __LOWB_SIZE__
.import __LOWC_LOAD__, __LOWC_RUN__, __LOWC_SIZE__
.import __LOWD_LOAD__, __LOWD_RUN__, __LOWD_SIZE__
.export x_low

.exportzp rp, rq, rv
.export rs_frac
.export drvbank, pcmbank, ldrbank, xbank, lo_zsv, lo_zrs, lo_call3, lo_bank, lo_ret, elapsed, busy1, busy2, saved_ien, old_cinv
.export lo_irq, lo_call1, lo_call2, lo_call_old, lo_rd, lo_wr, lo_put, lp_src
.export mix_first_voice, mix_add_voice, mix_resample, mix_solo
.export mix_src, mix_vol, mix_ystart, mix_bank, rs_step
.export s_now, s_next, gpos, s_cur, s_end, pcm_on, fm_mute, pcm_ok, fmq, qmode
.export tmode, topt, tk_n, tk_cur, pq_c, pr_c, t1lat
.export pev_kind, pev_ch, pev_smp, pev_mode, pev_len, fq_reg, fq_val
.export la0, la1, la2, la3, la4, la5
.export lbase, mdx_len, cal_chip, cal_mhz, cal_clk, cal_banks
.export pm_first, pm_last, pm_lut, pm_slots
.export m_fmreq, m_pcmreq, m_fm, m_pcm, m_force, k_sh, bit8, lo_setm, lo_ymf, lo_pcmf, lo_mplay
.import out_ymw, out_pcm, pe_ch
.ifdef YMLOG
.export lo_log, lg_w, lg_m, lg_end, lg_pcm
.endif
.ifdef TKLOG
.export tk_log
.endif

; ===========================================================================
; Zero page: no dedicated bytes. rp/rq/rv (here) and the core's 24 bytes live in the
; KERNAL virtual registers r0-r13 ($02-$1D), borrowed while the core or the loader runs:
; the IRQ worker and the API entry points save the host's values and put them back
; (mx16.s zp_enter / zp_leave; the worker: lo_zsv / lo_zrs). The IRQ level 2 and the mixer use no zero page.
.zeropage
rp:     .res 2                      ; bank memory pointer (lo_rd / lo_wr / lo_put)
rq:     .res 1
rv:     .res 1

; ===========================================================================
; bank +3, $A000: x_low copies LOWA-LOWD to low RAM (api_init, through the KERNAL's JSRFAR)
.segment "XCODE"
x_low:  ldx #0
:       lda __LOWA_LOAD__,x
        sta __LOWA_RUN__,x
        inx
        cpx #<__LOWA_SIZE__
        bne :-
        ldx #0
:       lda __LOWB_LOAD__,x
        sta __LOWB_RUN__,x
        inx
        cpx #<__LOWB_SIZE__
        bne :-
        ldx #0
:       lda __LOWC_LOAD__,x
        sta __LOWC_RUN__,x
        inx
        cpx #<__LOWC_SIZE__
        bne :-
        ldx #0
:       lda __LOWD_LOAD__,x
        sta __LOWD_RUN__,x
        inx
        cpx #<__LOWD_SIZE__
        bne :-
        rts
.assert __LOWA_SIZE__ < 256 && __LOWB_SIZE__ < 256 && __LOWC_SIZE__ < 256 && __LOWD_SIZE__ < 256, error, "low RAM image >= 256 bytes"

; The worker's zero page save / restore (lo_zsv / lo_zrs jump here with bank +3 selected):
; unrolled, 7 cycles a byte (the loop in bank +0 took 14). Back through lo_zbk.
x_zsave:
.repeat ZPN, i
        lda ZPS+i
        sta xz_save+i
.endrep
        jmp lo_zbk
x_zrest:
.repeat ZPN, i
        lda xz_save+i
        sta ZPS+i
.endrep
        jmp lo_zbk

.segment "XBSS"
xz_save:    .res ZPN                ; host's $02-$1D during the IRQ worker's ticks

; ===========================================================================
.segment "LOWA"
drvbank:    .byte 0                 ; bank +0 (core)
pcmbank:    .byte 0                 ; bank +1 (PCM runtime)
ldrbank:    .byte 0                 ; bank +2 (loader)
xbank:      .byte 0                 ; bank +3 (low RAM images, worker's zero page copies)
elapsed:    .word 0                 ; T1 periods not yet consumed by level 2
busy1:      .byte 0                 ; level 1 (ticks) running
busy2:      .byte 0                 ; level 2 (clock, PCM, FM queue) running
saved_ien:  .byte 0
old_cinv:   .word 0

; IRQ entry (CINV). KERNAL __irq has pushed the RTI frame and A, X, Y.
;   T1 (every 2 ms): level 2 = PCM bank P_LEVEL2 (short), then, unless already running,
;   level 1 = worker (ticks; may be long, interruptible by level 2). VERA interrupt
;   sources are masked while a level runs; level 2 services them through the previous
;   handler when it interrupts level 1, the outermost level chains to it at the end.
lo_irq: lda VIA1_IFR
        and VIA1_IER
        and #$40
        beq @not_t1
        lda VIA1_T1CL                   ; ack T1 (IFR writes do not clear T1 on x16emu <= R48)
        inc elapsed
        bne :+
        inc elapsed+1
:       lda busy2
        bne @exit                       ; level 2 running: only count time
        lda RAM_BANK
        pha
        lda busy1
        bne :+
        lda VERA_IEN                    ; outermost: mask VERA sources
        sta saved_ien
        and #$80
        sta VERA_IEN
:       inc busy2
        lda pcmbank
        sta RAM_BANK
        cli
        ldx #P_LEVEL2
        jsr lo_disp
        sei
        stz busy2
        lda busy1
        bne @ret                        ; back into level 1
        inc busy1
        lda drvbank
        sta RAM_BANK
        cli
        jsr worker
        sei
        stz busy1
        lda saved_ien
        sta VERA_IEN
        pla
        sta RAM_BANK
        lda VERA_ISR
        and saved_ien
        and #$0F
        bne @chain
        bra @exit
@ret:   pla
        sta RAM_BANK
@exit:  ply
        plx
        pla
        rti
@not_t1:
        lda busy1
        ora busy2
        bne @exit
@chain: jmp (old_cinv)

; Far calls into bank +1 / +2: X = entry offset in that bank's word table at $A000.
; Arguments in memory (la*, pev_*, zero page). Returns A and C; Y and X clobbered.
; The caller's RAM bank is kept on the stack (re-entrant).
lo_call1:
        lda RAM_BANK
        pha
        lda pcmbank
lo_cgo: sta RAM_BANK
        jsr lo_disp
        tay
        pla
        sta RAM_BANK
        tya
        rts
lo_call2:
        lda RAM_BANK
        pha
        lda ldrbank
        bra lo_cgo
lo_disp:
        jmp ($A000,x)

; Call the previous IRQ handler with a synthetic KERNAL IRQ frame (safe point).
; Called with I = 1; returns with I = 1 and the caller's RAM bank.
lo_call_old:
        lda RAM_BANK
        pha
        lda #>(@cont)
        pha
        lda #<(@cont)
        pha
        php
        pha
        phx
        phy
        jmp (old_cinv)
@cont:  pla
        sta RAM_BANK
        rts

; ===========================================================================
.segment "LOWB"
lo_bank:    .byte 0                 ; bank for lo_rd / lo_wr / lo_put
lo_ret:     .byte 0                 ; caller's bank (not re-entrant: main thread only
                                    ; while the worker is stopped, or the worker itself)

; A = byte at (rp) in bank lo_bank. X, Y preserved.
lo_rd:  lda RAM_BANK
        sta lo_ret
        lda lo_bank
        sta RAM_BANK
        lda (rp)
        pha
        lda lo_ret
        sta RAM_BANK
        pla
        rts

; store A at (rp) in bank lo_bank. A, X, Y preserved.
lo_wr:  pha
        lda RAM_BANK
        sta lo_ret
        lda lo_bank
        sta RAM_BANK
        pla
        sta (rp)
        pha
        lda lo_ret
        sta RAM_BANK
        pla
        rts

; copy X bytes (0 = 256) from low RAM lp_src to (rp) in bank lo_bank
lo_put: lda RAM_BANK
        sta lo_ret
        lda lo_bank
        sta RAM_BANK
        ldy #0
lp_src = * + 1
@l:     lda $FFFF,y
        sta (rp),y
        iny
        dex
        bne @l
        lda lo_ret
        sta RAM_BANK
        rts

; ---------------------------------------------------------------------------
; Mixer inner loops (a16 scheme). One chunk = n samples,
; Y = mix_ystart (256-n) .. 255. mix_src = first sample of the chunk (bank mix_bank),
; mix_vol = volume LUT lo page (hi page = +1). Return to pcmbank.

; mixlo/mixhi[y] = LUT[sample]
mix_first_voice:
        sec
        lda mix_src
        sbc mix_ystart
        sta fv_src+1
        lda mix_src+1
        sbc #0
        sta fv_src+2
        lda mix_vol
        sta fv_vlo+2
        inc a
        sta fv_vhi+2
        lda mix_bank
        sta RAM_BANK
        ldy mix_ystart
fv_src: lda $FFFF,y          ; 4(+1)
        tax                  ; 2
fv_vlo: lda $FF00,x          ; 4
        sta MIXLO,y          ; 5
fv_vhi: lda $FF00,x          ; 4
        sta MIXHI,y          ; 5
        iny                  ; 2
        bne fv_src           ; 3   = 29 (+1)
        lda pcmbank
        sta RAM_BANK
        rts

; one voice: the FIFO gets solo[sample] (page mix_vol: the 8-bit table of mxpcm.s so_step,
; solo[s] = the byte mix_output makes of LUT[s]: the same output as mix_first_voice +
; mix_output). Also reads RSBUF (mix_src = RSBUF page + mix_ystart, any bank).
mix_solo:
        sec
        lda mix_src
        sbc mix_ystart
        sta ms_src+1
        lda mix_src+1
        sbc #0
        sta ms_src+2
        lda mix_vol
        sta ms_tab+2
        lda mix_bank
        sta RAM_BANK
        ldy mix_ystart
ms_src: lda $FFFF,y          ; 4(+1)
        tax                  ; 2
ms_tab: lda $FF00,x          ; 4
        sta AUDIO_DATA       ; 4
        iny                  ; 2
        bne ms_src           ; 3   = 19 (+1)
        lda pcmbank
        sta RAM_BANK
        rts

; ===========================================================================
.segment "LOWC"
; Worker (bank +0 selected, I = 0): borrow / give back the host's $02-$1D. A clobbered.
; (level 2 may interrupt while bank +3 is selected: lo_irq keeps the bank)
; Far call into bank +3 (X = entry offset in its word table at $A000), as lo_call1/2
lo_call3:
        lda RAM_BANK
        pha
        lda xbank
        jmp lo_cgo

lo_zsv: lda xbank
        sta RAM_BANK
        jmp x_zsave
lo_zrs: lda xbank
        sta RAM_BANK
        jmp x_zrest
lo_zbk: lda drvbank
        sta RAM_BANK
        rts

; setopt 9 / 10 (mx16.s api_setopt, A >= 9): the wanted mute masks (applied by the worker,
; bank +3 x_mute)
lo_setm:
        cmp #9
        bne :+
        stx m_fmreq
        rts
:       cmp #10
        bne :+
        stx m_pcmreq
:       rts
bit8:   .byte $01, $02, $04, $08, $10, $20, $40, $80
; api_play: the wanted masks hold from the first write of the song (no key off needed: the
; keys are off after the stop)
lo_mplay:
        lda m_fmreq
        sta m_fm
        lda m_pcmreq
        sta m_pcm
        rts

; mix[y] += LUT[sample]
mix_add_voice:
        sec
        lda mix_src
        sbc mix_ystart
        sta av_src+1
        lda mix_src+1
        sbc #0
        sta av_src+2
        lda mix_vol
        sta av_vlo+2
        inc a
        sta av_vhi+2
        lda mix_bank
        sta RAM_BANK
        ldy mix_ystart
av_src: lda $FFFF,y          ; 4(+1)
        tax                  ; 2
        clc                  ; 2
av_vlo: lda $FF00,x          ; 4
        adc MIXLO,y          ; 4
        sta MIXLO,y          ; 5
av_vhi: lda $FF00,x          ; 4
        adc MIXHI,y          ; 4
        sta MIXHI,y          ; 5
        iny                  ; 2
        bne av_src           ; 3   = 39 (+1)
        lda pcmbank
        sta RAM_BANK
        rts

; Resample one chunk (sample and hold, 8.8 phase, step < 1) into RSBUF[y]:
;   in: mix_src = source position, mix_bank, rs_step, rs_frac
;   out: X = source samples consumed, rs_frac updated
mix_resample:
        lda mix_src
        sta rs_rd+1
        lda mix_src+1
        sta rs_rd+2
        lda rs_step
        sta rs_add+1
        lda mix_bank
        sta RAM_BANK
        ldx #0
        ldy mix_ystart
rs_rd:  lda $FFFF,x          ; 4(+1)
        sta RSBUF,y          ; 5
        lda rs_frac          ; 3
        clc                  ; 2
rs_add: adc #$00             ; 2
        sta rs_frac          ; 3
        bcc :+               ; 2/3
        inx                  ; 2
:       iny                  ; 2
        bne rs_rd            ; 3   = 28
        lda pcmbank
        sta RAM_BANK
        rts

; ===========================================================================
.segment "LOWD"
rs_frac:    .byte 0                 ; resampler phase
mix_src:    .word 0
mix_vol:    .byte 0
mix_ystart: .byte 0
mix_bank:   .byte 0
rs_step:    .byte 0
; worker state shared by bank +0 and bank +1 (sample positions, 24-bit, compared
; as signed differences so they may wrap)
s_now:      .res 3                  ; real clock
s_next:     .res 3                  ; sample position of the next tick
gpos:       .res 3                  ; G: samples generated
s_cur:      .res 3                  ; time stamp of the tick being processed (level 1)
s_end:      .res 3                  ; E: end of the last completed tick (events known)
pcm_on:     .byte 0                 ; PCM output active for this song
qmode:      .byte 1                 ; option: 1 = queue mode (FM delayed by L, ticks ahead)
fmq:        .byte 0                 ; queue mode active for this song (qmode and pcm_on)
pcm_ok:     .byte 0                 ; PCM possible (pcmmem accepted)
tmode:      .byte 0                 ; $80: tick clock for this song (mx16.s tk_init)
topt:       .byte 1                 ; option 8: tick clock allowed
tk_n:       .byte 200               ; last Timer-B value (out_tempo)
fm_mute:    .byte 0                 ; debug: no YM writes
; out_pcm event (copied from the core's pe_*)
pev_kind:   .byte 0
pev_ch:     .byte 0
pev_smp:    .word 0
pev_mode:   .res 3
pev_len:    .res 3
fq_reg:     .byte 0                 ; queued YM write (level 1)
fq_val:     .byte 0
; far-call arguments / results (main thread only)
la0:        .byte 0
la1:        .byte 0
la2:        .byte 0
la3:        .byte 0
la4:        .byte 0
la5:        .byte 0
; MDX location (linear address of the body = bank * 8192 + offset) and body size
lbase:      .res 3
mdx_len:    .word 0
; calibration results (loader)
cal_chip:   .byte 0
cal_mhz:    .byte 0
cal_clk:    .byte 0
cal_banks:  .byte 0                 ; RAM banks (0 = 256)
; PCM memory given by the host
pm_first:   .byte 0                 ; first sample bank
pm_last:    .byte 0                 ; last sample bank
pm_lut:     .byte 0                 ; page of the volume LUT area (low RAM)
pm_slots:   .byte 0                 ; LUT slots (512 bytes each)

; bank +3 x_mute -> bank +0 (worker): lo_ymf = forced YM write A -> register Y (past the mute
; mask and the equal-value skip; k_sh untouched), lo_pcmf = PCM event A with pe_ch = X
lo_ymf: pha
        lda drvbank
        sta RAM_BANK
        lda #$80
        sta m_force
        pla
        jsr out_ymw
        stz m_force
        bra lo_b3
lo_pcmf:
        pha
        lda drvbank
        sta RAM_BANK
        stx pe_ch
        pla
        jsr out_pcm
lo_b3:  lda xbank
        sta RAM_BANK
        rts

.ifdef TKLOG
; debug: the start time of every tick (EMU_CLK, 4 bytes) in banks TKBANK.. from $A000
TKBANK = 128
tkbank:     .byte TKBANK
tk_log: php
        sei
        lda RAM_BANK
        pha
        lda tkbank
        sta RAM_BANK
        ldx #0
tk_lb:  lda EMU_CLK0,x                  ; (CLK0 first: it latches the others)
tk_lst: sta $A000
        inc tk_lst+1
        bne :+
        inc tk_lst+2
        lda tk_lst+2
        cmp #$C0
        bne :+
        lda #$A0
        sta tk_lst+2
        inc tkbank
        lda tkbank
        sta RAM_BANK
:       inx
        cpx #4
        bne tk_lb
        pla
        sta RAM_BANK
        plp
        rts
.endif
.ifdef YMLOG
; debug: append A to the YM write log (banks LOGBANK.., starting at $A000)
LOGBANK = 64
logbank:    .byte LOGBANK
lo_log: pha
        lda RAM_BANK
        sta lg_ret
        lda logbank
        sta RAM_BANK
        pla
lo_logst:
        sta $A000
        inc lo_logst+1
        bne :+
        inc lo_logst+2
        pha
        lda lo_logst+2
        cmp #$C0
        bne @nb
        lda #$A0
        sta lo_logst+2
        inc logbank
@nb:    pla
:       pha
        lda lg_ret
        sta RAM_BANK
        pla
        rts
lg_ret: .byte 0
; lg_w: log the YM write A -> register Y (A, X, Y kept)
lg_w:   pha
        tya
        jsr lo_log
        pla
        jmp lo_log
; lg_pcm: a PCM event A (out_pcm, bank +0; pe_ch) as a write of kind << 4 | pe_ch to
; register $10 (Timer A: the core never writes it, opm_write drops it), through out_ymw:
; queued with the tick's FM writes in queue mode, so it is logged in the tick it is heard.
; (The chip gets it too: the unused Timer A's value.) A, X, Y kept.
lg_pcm: pha
        phx
        phy
        asl a
        asl a
        asl a
        asl a
        ora pe_ch
        ldy #$10
        jsr out_ymw
        ply
        plx
        pla
        rts
; lg_m: log a tick marker ($00 $00); lg_end: the stop marker ($00 $FF)
lg_m:   lda #0
        jsr lo_log
        jmp lo_log
lg_end: lda #0
        jsr lo_log
        lda #$FF
        jmp lo_log
.endif

; T1 period and the real clock's step (mx16.s tk_init, mxload.s l_tempo, mxpcm.s p_level2)
.segment "LOWBSS"
; channel mute: wanted masks (setopt 9 / 10), applied masks (bank +3
; x_mute; bank +0 out_ym / out_pcm hold back what goes out), the key state of each FM channel
; as the song wrote it ($08 value, kept while muted), forced write in progress
m_fmreq:    .res 1
m_pcmreq:   .res 1
m_fm:       .res 1
m_pcm:      .res 1
m_force:    .res 1
k_sh:       .res 8
t1lat:      .res 2                  ; T1 latch for irq_on
tk_cur:     .res 1                  ; Timer-B value of the T1 period (tick clock)
pq_c:       .res 2                  ; samples per T1 period: pq_c + pr_c / 2^19
pr_c:       .res 3
