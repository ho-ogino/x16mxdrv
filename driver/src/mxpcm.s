; mxpcm.s - X16MXDRV bank +1: PCM runtime
;
; PCM8 channels 0-7 and the MSM6258 channel (8) become up to p_nv mixer voices
; (oldest voice stolen). Samples are 8-bit signed at their source rate in the sample
; banks (decoded by the loader, bank +2); rate 4 (15625 Hz) is played 1:1, the others
; through the 8.8 resampler. Mixing: 16-bit accumulate through per-volume LUTs
; (slots in the host's low RAM area, filled on demand), one clip, 8-bit mono output
; to the VERA FIFO. Direct mode: the FIFO runs L samples behind the real clock.

.setcpu "65C02"
.macpack longbranch
.include "x16.inc"
.include "mx16.inc"
.include "mxcore.inc"

.importzp t0, t1, t2, t3, t4, t5            ; (pdx_get contract with the core)
.import rs_frac
.ifdef YMLOG
.import lg_w, lg_m
.endif
.import pcmbank, saved_ien, lo_call_old, elapsed, busy1, lo_bank, lo_rd
.importzp rp
.import mix_first_voice, mix_add_voice, mix_resample, mix_solo
.import mix_src, mix_vol, mix_ystart, mix_bank, rs_step
.import s_now, s_next, gpos, s_cur, s_end, pcm_ok, pcm_on, fmq, fm_mute, fq_reg, fq_val
.import pev_kind, pev_ch, pev_smp, pev_mode, pev_len
.import la0, la1, la2, la3, la4, la5, cal_banks
.import pq_c, pr_c
.import pm_first, pm_last, pm_lut, pm_slots
.export d_n, d_slo, d_shi, d_rate, d_bank, d_alo, d_ahi, d_l0, d_l1, d_l2

; ===========================================================================
.segment "PJMP"
        .word p_init, p_setup, p_start, p_stop, p_begin, p_gen, p_fin, p_event
        .word p_getlen, p_setnv, p_stat, p_setl, p_cleardir, p_level2, p_fmpush, p_fmmark
        .word p_evpush, p_none, p_done, p_fmdrain

; ===========================================================================
.segment "PRODATA"
; mix_output tables (page aligned)
; lo2tab[lo] = lo >> 2
lo2tab:
.repeat 256, i
        .byte i >> 2
.endrepeat
; hi6tab[hi]: in range (hi = $FE,$FF,$00,$01) -> (hi & 3) << 6
;             hi in $02..$7F (positive overflow) -> $7F
;             hi in $80..$FD (negative overflow) -> $80
hi6tab:
.repeat 256, i
  .if i = $FE || i = $FF || i = $00 || i = $01
        .byte (i & 3) << 6
  .elseif i < $80
        .byte $7F
  .else
        .byte $80
  .endif
.endrepeat
; himask[hi]: $80 for negative overflow (forces exactly $80), else $FF
himask:
.repeat 256, i
  .if i >= $80 && i <= $FD
        .byte $80
  .else
        .byte $FF
  .endif
.endrepeat
; PCM8 volume (x/16) per volume index
pcm8vol: .byte 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64, 80
; resampler step (8.8) per ADPCM rate: 3906.25, 5208.33, 7812.5, 10416.67 Hz; 0 = 1:1
ratestep: .byte 64, 85, 128, 171, 0

; ===========================================================================
.segment "PBSS"
; queues from level 1 to level 2 (single producer / single consumer)
FMQ_PAGES   = 6                   ; (1.5 KB: the lookahead A + L needs far less; full: the worker waits)
.align 256
fmring:     .res 256 * FMQ_PAGES    ; YM writes (reg, value); reg 0 = tick mark + time (3)
fm_w:       .res 2                  ; write pointer (published after a whole entry)
fm_r:       .res 2                  ; read pointer
ev_w:       .res 1                  ; slot index
ev_r:       .res 1
racc:       .res 3                  ; fraction of s_now (19 bits)
z0:         .res 1                  ; scratch (no zero page: level 2 runs inside any host code)
z1:         .res 1
z2:         .res 1
z3:         .res 1
z4:         .res 1
z5:         .res 1
z6:         .res 1
z7:         .res 1
z8:         .res 1
z9:         .res 1
z10:        .res 1
.ifdef L2DEBUG
l2_t:       .res 3
l2_last:    .res 3
l2_d:       .res 3
l2_gmax:    .res 3
l2_gat:     .res 3
l2_dmax:    .res 3
l2_dat:     .res 3
.endif
fm_wp:      .res 2                  ; private write pointer (level 1)
fd_on:      .res 1                  ; fm_flush: the head is a tick mark due at fd_t (not yet)
fd_t:       .res 3
.ifdef PROF
vc_n:       .res 1                  ; (scratch: number of active voices)
vc_hist:    .res 3 * (NVMAX + 1)    ; output samples per number of active voices
.endif
dn_on:      .res 1                  ; p_done: everything sent, waiting until dn_t
dn_t:       .res 3
.ifdef YMLOG
lg_mark:    .res 1                  ; tick marks seen by the flush (YMLOG)
.endif
ev_t0:      .res 64                 ; PCM event queue (64 slots, one array per field)
ev_t1:      .res 64
ev_t2:      .res 64
ev_kind:    .res 64
ev_ch:      .res 64
ev_s0:      .res 64
ev_s1:      .res 64
ev_m0:      .res 64
ev_m1:      .res 64
ev_m2:      .res 64
ev_l0:      .res 64
ev_l1:      .res 64
ev_l2:      .res 64
ae_kind:    .res 1                  ; event being applied (same layout as pev_*)
ae_ch:      .res 1
ae_smp:     .res 2
ae_mode:    .res 3
ae_len:     .res 3
p_nv:       .res 1
p_l:        .res 2                  ; latency L (samples)
p_b:        .res 1                  ; batching: generate when s_now - G >= p_b (0: every run)
p_m:        .res 2                  ; sample budget per worker run
budget:     .res 2
recovering: .res 1
nchunk:     .res 1
first:      .res 1
vi:         .res 1
age:        .res 2
sl_next:    .res 1
tmpch:      .res 1
tmpd:       .res 1
tmpv:       .res 1
tmplen:     .res 3
st_under:   .res 2
st_steal:   .res 2
st_maxv:    .res 1
st_ulog:    .res 64
; voices
v_active:   .res NVMAX
v_ch:       .res NVMAX
v_bank:     .res NVMAX
v_plo:      .res NVMAX
v_phi:      .res NVMAX
v_r0:       .res NVMAX              ; remaining samples (24-bit)
v_r1:       .res NVMAX
v_r2:       .res NVMAX
v_step:     .res NVMAX              ; 0 = 1:1, else 8.8 step
v_frac:     .res NVMAX
v_slot:     .res NVMAX
v_agelo:    .res NVMAX
v_agehi:    .res NVMAX
ch_voice:   .res NPCH               ; voice of a channel ($FF none)
ch_vol:     .res NPCH               ; PCM8 volume index of a channel
; volume LUT slots
sl_vol:     .res 16                 ; volume index held ($FF empty)
sl_ref:     .res 16                 ; voices using the slot
sl_n:       .res 1                  ; slots for volume LUTs (pm_slots, - 1 while so_on)
v_cnt:      .res 1                  ; active voices
; solo table (one voice: mix_solo). The last LUT slot, reserved at p_start when there are
; more slots than voices (then sl_n >= voices that can sound at once), given back by so_off
so_on:      .res 1                  ; reserved
so_pg:      .res 1                  ; its page
so_vol:     .res 1                  ; volume of the complete table ($FF none)
so_bv:      .res 1                  ; volume being built
so_bi:      .res 1                  ; next entry to build (0, 64, 128, 192)
so_did:     .res 1                  ; a part was built in this level-2 run
; sample directory (written by the loader)
d_n:        .res 1
d_slo:      .res NDIR               ; sample number
d_shi:      .res NDIR
d_rate:     .res NDIR
d_bank:     .res NDIR               ; first byte
d_alo:      .res NDIR
d_ahi:      .res NDIR
d_l0:       .res NDIR               ; length in ADPCM bytes (samples = 2 * length)
d_l1:       .res NDIR
d_l2:       .res NDIR

; Batching (queue mode): level 2 generates PCM only when s_now - G >= B (fewer, longer
; chunks). The FIFO's lead L must stay above the generation delay: up to B - 1 samples not
; yet generated + 31 (s_now moves per T1 period) + the longest gap between level-2 runs
; (L2_GMAX: the largest measured is 130.7 samples, a song with heavy PCM at its loop
; point with a PCM pack; 125.1 with the PDX decoded; the L2DEBUG build) + a margin L2_M.
; B = min(B_MAX, L - 31 - L2_GMAX - L2_M), no batching if that is below B_MIN (set_b).
; s_now moves ~31.3 samples per run: any B in 33..62 generates every second run.
; (default L = 248: B = min(48, 49) = 48; batching from L = 215 up)
L2_GMAX = 136
L2_M    = 32
B_MAX   = 48
B_MIN   = 16

; ===========================================================================
.segment "PCODE"

p_init:
        lda #4
        sta p_nv
        lda #248                        ; L = 15.9 ms
        sta p_l
        stz p_l+1
        lda #<512
        sta p_m
        lda #>512
        sta p_m+1
        stz pcm_ok
p_cleardir:
        stz d_n
        rts

; pm_first, pm_last, pm_lut, pm_slots -> pcm_ok, C = 1 if PCM is not possible
p_setup:
        stz pcm_ok
        stz so_on                       ; (reserved again at the next p_start)
        lda pm_slots
        sta sl_n
        lda cal_banks                   ; at least 1 MB (0 = 256 banks)
        beq :+
        cmp #128
        bcc @no
:       lda pm_slots
        cmp #4
        bcc @no
        cmp #17
        bcs @no
        lda pm_first
        beq @no
        cmp pm_last
        beq :+
        bcs @no
:       lda #1
        sta pcm_ok
        jsr clamp_nv
        clc
        rts
@no:    sec
        rts

; clamp_nv: voices <= LUT slots (each playing voice may need its own volume)
clamp_nv:
        lda p_nv
        cmp pm_slots
        bcc :+
        lda pm_slots
        sta p_nv
:       rts

; p_setnv: voice limit (main thread; I = 1 here, level 2 must see p_nv and sl_n agree).
; Fewer voices: voices above the limit may still sound, the reservation stays (a new one
; only at p_start). As many voices as slots: the solo table's slot goes back (so_off).
p_setnv:
        php
        sei
        lda la0
        beq @r
        cmp #NVMAX+1
        bcs @r
        sta p_nv
        lda pcm_ok
        beq @r
        jsr clamp_nv
        lda p_nv
        cmp pm_slots
        bcc @r
        jsr so_off
@r:     plp
        rts

; so_off: no solo table; its slot holds no volume LUT and is used for volumes again
so_off: lda so_on
        beq @r
        stz so_on
        lda #$FF
        sta so_vol
        sta so_bv
        ldx sl_n
        sta sl_vol,x
        inc sl_n
@r:     rts

p_setl:
        php                             ; (level 2: L, the cached due time and B agree)
        sei
        lda la0
        sta p_l
        lda la1
        sta p_l+1
        stz fd_on
        jsr set_b
        plp
        rts

; set_b: batching threshold p_b for L (queue mode only: in direct mode generation also
; waits for the ticks, which the bound above does not cover)
set_b:  stz p_b
        bit fmq
        bpl @r
        sec
        lda p_l
        sbc #<(31 + L2_GMAX + L2_M)
        tax
        lda p_l+1
        sbc #>(31 + L2_GMAX + L2_M)
        bcc @r                          ; L too small
        bne @max
        cpx #B_MIN
        bcc @r
        cpx #B_MAX
        bcc :+
@max:   ldx #B_MAX
:       stx p_b
@r:     rts

p_stat:
        lda v_cnt
        sta la0
        lda st_maxv
        sta la1
        lda st_under
        sta la2
        lda st_under+1
        sta la3
        lda st_steal
        sta la4
        lda st_steal+1
        sta la5
        rts

; ---------------------------------------------------------------------------
; p_start: before play (I = 1). FIFO reset, L samples of silence, empty voices.
p_start:
        stz AUDIO_RATE
        lda #AUDIO_CTRL_INIT
        sta AUDIO_CTRL
        jsr free_all
        ldx #15
:       lda #$FF
        sta sl_vol,x
        stz sl_ref,x
        dex
        bpl :-
        sta so_vol
        sta so_bv
        lda pm_slots                    ; more slots than voices: the last one holds
        sta sl_n                        ; the solo table
        stz so_on
        lda p_nv
        cmp pm_slots
        bcs :+
        dec sl_n
        inc so_on
        lda sl_n
        asl a
        adc pm_lut                      ; (C = 0)
        sta so_pg
:       ldx #NPCH-1
        lda #8                          ; x1
:       sta ch_vol,x
        dex
        bpl :-
        stz sl_next
        stz recovering
        stz st_under
        stz st_under+1
        stz st_steal
        stz st_steal+1
        stz st_maxv
        stz age
        stz age+1
        stz racc
        stz racc+1
        stz racc+2
        stz ev_w
        stz ev_r
        stz dn_on
        stz fd_on
.ifdef YMLOG
        stz lg_mark
.endif
        lda #<fmring
        sta fm_w
        sta fm_r
        sta fm_wp
        lda #>fmring
        sta fm_w+1
        sta fm_r+1
        sta fm_wp+1
        jsr set_b
        jmp write_l_silence

p_stop:
        stz AUDIO_RATE
        lda #AUDIO_CTRL_INIT
        sta AUDIO_CTRL
free_all:
        stz v_cnt
        ldx #NVMAX-1
:       stz v_active,x
        dex
        bpl :-
        ldx #15                         ; no voice uses a LUT slot now
:       stz sl_ref,x
        dex
        bpl :-
        ldx #NPCH-1
        lda #$FF
:       sta ch_voice,x
        dex
        bpl :-
        rts

write_l_silence:
        ldx p_l
        ldy p_l+1
        iny
        lda #0
@l:     cpx #0
        beq @h
:       sta AUDIO_DATA
        dex
        bne :-
@h:     dey
        bne :-
        rts

; ---------------------------------------------------------------------------
; IRQ level 2 (from lo_irq: I = 0, busy2 = 1, this bank selected). Runs every T1
; period, also while level 1 (ticks) is busy:
;   real clock, FM queue (writes due at s_cur + L), PCM events due at G, generation
;   up to min(s_now, s_end), VERA interrupt service if level 1 was interrupted.
; Uses only z0..z8 / rs_frac (level 1 may be inside the core, which owns t0..t7).

p_level2:
.ifdef L2DEBUG
        ldx #0                          ; gap since the last entry, entry time
:       lda EMU_CLK0,x
        sta l2_t,x
        inx
        cpx #3
        bne :-
        sec
        lda l2_t
        sbc l2_last
        sta l2_d
        lda l2_t+1
        sbc l2_last+1
        sta l2_d+1
        lda l2_t+2
        sbc l2_last+2
        sta l2_d+2
        ldx #2
:       lda l2_t,x
        sta l2_last,x
        dex
        bpl :-
        lda l2_d                        ; max gap (ignore the first)
        cmp l2_gmax
        lda l2_d+1
        sbc l2_gmax+1
        lda l2_d+2
        sbc l2_gmax+2
        bcc :+
        lda l2_d+2
        cmp #2                          ; (> 128K cycles: the first entry, skip)
        bcs :+
        ldx #2
@g:     lda l2_d,x
        sta l2_gmax,x
        lda s_now,x
        sta l2_gat,x
        dex
        bpl @g
:       jsr @body
        sec                             ; duration -> max
        lda EMU_CLK0
        sbc l2_t
        sta l2_d
        lda EMU_CLK1
        sbc l2_t+1
        sta l2_d+1
        lda EMU_CLK2
        sbc l2_t+2
        sta l2_d+2
        lda l2_d
        cmp l2_dmax
        lda l2_d+1
        sbc l2_dmax+1
        lda l2_d+2
        sbc l2_dmax+2
        bcc :+
        ldx #2
@m:     lda l2_d,x
        sta l2_dmax,x
        lda s_now,x
        sta l2_dat,x
        dex
        bpl @m
:       rts
@body:
.endif
        sei
        ldx elapsed
        ldy elapsed+1
        stz elapsed
        stz elapsed+1
        cli
@adv:   cpx #0                          ; real clock += pq_c + pr_c / 2^19 per T1 period
        bne @dec                        ; (2 ms or tick clock: mx16.s tk_init)
        cpy #0
        beq @advd
        dey
@dec:   dex
        clc
        lda s_now
        adc pq_c
        sta s_now
        lda s_now+1
        adc pq_c+1
        sta s_now+1
        bcc :+
        inc s_now+2
:       clc
        lda racc
        adc pr_c
        sta racc
        lda racc+1
        adc pr_c+1
        sta racc+1
        lda racc+2
        adc pr_c+2
        cmp #$08
        bcc @nc
        sbc #$08
        inc s_now
        bne @nc
        inc s_now+1
        bne @nc
        inc s_now+2
@nc:    sta racc+2
        bra @adv
@advd:  lda pcm_on
        beq @vera
        jsr p_begin                     ; PCM first: the FIFO must not wait for a long
        lda p_b                         ; burst of YM writes
        beq @gen                        ; batching: wait until s_now - G >= B
        lda recovering
        bne @gen
        sec
        lda s_now
        sbc gpos
        tax
        lda s_now+1
        sbc gpos+1
        bne @gen
        lda s_now+2
        sbc gpos+2
        bne @gen
        cpx p_b
        bcc @fm
@gen:   jsr p_gen
        bcs @fm                         ; out of budget: continue next time
        jsr p_fin
@fm:    bit fmq
        bpl @vera
        jsr fm_flush
@vera:  lda busy1                       ; level 1 interrupted: serve VERA now
        beq @r
        lda VERA_ISR
        and saved_ien
        and #$0F
        beq @r
        sei
        jsr lo_call_old
        cli
@r:     rts

; p_begin: underrun check, sample budget
p_begin:
        stz so_did
        lda p_m
        sta budget
        lda p_m+1
        sta budget+1
        lda recovering
        bne @r
        lda AUDIO_CTRL                  ; FIFO empty -> recover
        and #$40
        beq @r
        lda st_under                    ; (diagnostics: s_now and G of the first 8)
        cmp #8
        bcs :+
        asl a
        asl a
        asl a
        tax
        ldy #0
@lg:    lda s_now,y
        sta st_ulog,x
        lda gpos,y
        sta st_ulog+3,x
        inx
        iny
        cpy #3
        bne @lg
:       inc st_under
        bne :+
        inc st_under+1
:       stz AUDIO_RATE
        lda #AUDIO_CTRL_INIT
        sta AUDIO_CTRL
        lda #1
        sta recovering
@r:     rts

; p_fin: a recovery ends when G caught up with the real clock
p_fin:  lda recovering
        beq @r
        lda gpos
        cmp s_now
        bne @r
        lda gpos+1
        cmp s_now+1
        bne @r
        lda gpos+2
        cmp s_now+2
        bne @r
        jsr write_l_silence
        lda #PCM_RATE
        sta AUDIO_RATE
        stz recovering
@r:     rts

; p_gen: apply due PCM events and generate (or skip, while recovering) up to
;   min(s_now, s_end, next event) -> C = 1 if the sample budget ran out first
p_gen:
@gen:   jsr ev_apply                    ; C = 1: next event at ev_t*[X]
        lda s_now                       ; target z0..z2 = s_now
        sta z0
        lda s_now+1
        sta z1
        lda s_now+2
        sta z2
        php
        sec                             ; s_end < target ?
        lda s_end
        sbc z0
        lda s_end+1
        sbc z1
        lda s_end+2
        sbc z2
        bpl :+
        lda s_end
        sta z0
        lda s_end+1
        sta z1
        lda s_end+2
        sta z2
:       plp
        bcc :+
        sec                             ; next event < target ?
        lda ev_t0,x
        sbc z0
        lda ev_t1,x
        sbc z1
        lda ev_t2,x
        sbc z2
        bpl :+
        lda ev_t0,x
        sta z0
        lda ev_t1,x
        sta z1
        lda ev_t2,x
        sta z2
:       sec                             ; d = target - G
        lda z0
        sbc gpos
        sta z5
        lda z1
        sbc gpos+1
        sta z6
        lda z2
        sbc gpos+2
        bmi @done                       ; (G past the target: cannot happen)
        ora z6
        bne @n64
        lda z5
        beq @done
        cmp #CHUNK
        bcc @nset
@n64:   lda #CHUNK
@nset:  sta nchunk
        lda recovering
        bne @skip
        lda budget+1
        bne @bok
        lda budget
        bne :+
        sec                             ; out of budget
        rts
:       cmp nchunk
        bcs @bok
        sta nchunk
@bok:   sec
        lda budget
        sbc nchunk
        sta budget
        bcs :+
        dec budget+1
:       jsr gen_chunk
        bra @adv
@skip:  jsr skip_chunk
@adv:   clc
        lda gpos
        adc nchunk
        sta gpos
        bcc :+
        inc gpos+1
        bne :+
        inc gpos+2
:       jmp @gen
@done:  clc
        rts

; ev_apply: apply queued PCM events with time <= G
;   -> C = 0 queue empty, C = 1 next event pending at ev_t*[X]
ev_apply:
@l:     ldx ev_r
        cpx ev_w
        beq @none
        sec
        lda ev_t0,x
        sbc gpos
        sta z5
        lda ev_t1,x
        sbc gpos+1
        sta z6
        lda ev_t2,x
        sbc gpos+2
        bmi @due
        ora z5
        ora z6
        bne @pend
@due:   jsr ev_take
        bra @l
@pend:  sec
        rts
@none:  clc
        rts

; ev_take: apply the event in slot X (= ev_r) and remove it
ev_take:
        lda ev_kind,x
        sta ae_kind
        lda ev_ch,x
        sta ae_ch
        lda ev_s0,x
        sta ae_smp
        lda ev_s1,x
        sta ae_smp+1
        lda ev_m0,x
        sta ae_mode
        lda ev_m1,x
        sta ae_mode+1
        lda ev_m2,x
        sta ae_mode+2
        lda ev_l0,x
        sta ae_len
        lda ev_l1,x
        sta ae_len+1
        lda ev_l2,x
        sta ae_len+2
        txa
        inc a
        and #63
        sta ev_r
        jmp ev_do

; ---------------------------------------------------------------------------
; level 1 side (ticks): queue producers. Use only z9/z10.

; p_evpush: PCM event pev_* at time s_cur
p_evpush:
        lda ev_w
        inc a
        and #63
        sta z9                          ; next slot
        cmp ev_r                        ; full: wait for level 2
        bne @ok
        bit VIA1_IER
        bvs p_evpush                    ; (the clock runs: level 2 empties it)
        ldx ev_r                        ; before play (the first tick: its time is 0):
        jsr ev_take                     ; apply the oldest event now
        bra p_evpush
@ok:    ldx ev_w
        lda s_cur
        sta ev_t0,x
        lda s_cur+1
        sta ev_t1,x
        lda s_cur+2
        sta ev_t2,x
        lda pev_kind
        sta ev_kind,x
        lda pev_ch
        sta ev_ch,x
        lda pev_smp
        sta ev_s0,x
        lda pev_smp+1
        sta ev_s1,x
        lda pev_mode
        sta ev_m0,x
        lda pev_mode+1
        sta ev_m1,x
        lda pev_mode+2
        sta ev_m2,x
        lda pev_len
        sta ev_l0,x
        lda pev_len+1
        sta ev_l1,x
        lda pev_len+2
        sta ev_l2,x
        lda z9
        sta ev_w                        ; publish
        rts

; p_fmmark: tick mark (0, s_cur) ; p_fmpush: YM write fq_reg, fq_val
p_fmmark:
        lda #0
        jsr fq_put
        lda s_cur
        jsr fq_put
        lda s_cur+1
        jsr fq_put
        lda s_cur+2
        bra fq_last
p_fmpush:
        lda fq_reg
        jsr fq_put
        lda fq_val
fq_last:
        jsr fq_put
        sei                             ; publish the whole entry
        lda fm_wp
        sta fm_w
        lda fm_wp+1
        sta fm_w+1
        cli
        rts

; fq_put: A -> ring at fm_wp (waits while the ring is full)
fq_put: pha
        lda fm_wp                       ; z9/z10 = next(fm_wp)
        clc
        adc #1
        sta z9
        lda fm_wp+1
        adc #0
        cmp #>(fmring + 256 * FMQ_PAGES)
        bne :+
        lda #>fmring
:       sta z10
@full:  sei                             ; next == fm_r: full
        lda fm_r
        cmp z9
        bne @ok
        lda fm_r+1
        cmp z10
        bne @ok
        cli
        bit VIA1_IER
        bvs @full                       ; (the clock runs: level 2 empties it)
        jsr fq_drain                    ; before play (the first tick): write the oldest now
        bra @full
@ok:    cli
        lda fm_wp
        sta @st+1
        lda fm_wp+1
        sta @st+2
        pla
@st:    sta $FFFF
        lda z9
        sta fm_wp
        lda z10
        sta fm_wp+1
        rts

; fm_flush (level 2): YM writes of ticks whose time s_cur + L has come, at most
; FQ_MAX per level 2 run (the rest waits for the next run, 2 ms later)
FQ_MAX  = 64
fm_flush:
        lda fd_on                       ; head mark known: return until it is due
        beq @go
        sec
        lda s_now
        sbc fd_t
        lda s_now+1
        sbc fd_t+1
        lda s_now+2
        sbc fd_t+2
        bpl :+
        rts
:       stz fd_on
@go:    lda #FQ_MAX
        sta z7
@l:     lda fm_r
        cmp fm_w
        bne :+
        lda fm_r+1
        cmp fm_w+1
        beq @r                          ; empty
:       lda fm_r
        sta z5
        lda fm_r+1
        sta z6
        sta fq_rd+2
        jsr fq_get
        bne @wr
        jsr fq_get                      ; mark: due if s_now - (t + L) >= 0
        sta z0
        jsr fq_get
        sta z1
        jsr fq_get
        sta z2
        clc
        lda z0
        adc p_l
        sta z0
        lda z1
        adc p_l+1
        sta z1
        bcc :+
        inc z2
:       sec
        lda s_now
        sbc z0
        lda s_now+1
        sbc z1
        lda s_now+2
        sbc z2
        bmi @nyet                       ; not yet
.ifdef YMLOG
        jsr lg_tick
.endif
        bra @commit
@wr:    dec z7
        bmi @r                          ; (enough for this run)
        tay                             ; register
        jsr fq_get
        jsr ym_q
@commit:
        lda z5
        sta fm_r
        lda z6
        sta fm_r+1
        jmp @l
@r:     rts
@nyet:  lda z0                          ; (the head stays this mark until it is due:
        sta fd_t                        ; only fm_flush takes it; p_start, fq_drain and
        lda z1                          ; p_setl forget it)
        sta fd_t+1
        lda z2
        sta fd_t+2
        inc fd_on
        rts

; ym_q: queued YM write A -> register Y (fm_mute; YMLOG: logged as it reaches the chip)
ym_q:   bit fm_mute
        bmi @r
.ifdef YMLOG
        jsr lg_w
.endif
        jmp ym_raw
@r:     rts
.ifdef YMLOG
; lg_tick: a tick mark reached the chip side: end of the previous tick in the log
lg_tick:
        lda lg_mark                     ; (the first mark only starts tick 0)
        bne :+
        inc lg_mark
        rts
:       jmp lg_m
.endif

; fq_drain: before play, the ring is full during the first tick (nobody empties it
; yet): write its oldest YM write now (tick marks skipped). Level-2 scratch z5/z6 is free.
fq_drain:
        stz fd_on
        lda fm_r
        sta z5
        lda fm_r+1
        sta z6
        sta fq_rd+2
        jsr fq_get
        bne @wr
        jsr fq_get
        jsr fq_get
        jsr fq_get
.ifdef YMLOG
        jsr lg_tick
.endif
        bra @c
@wr:    tay
        jsr fq_get
        jsr ym_q
@c:     lda z5
        sta fm_r
        lda z6
        sta fm_r+1
        rts

; p_fmdrain: stop (I = 1, T1 off): every queued YM write goes to the chip now, except key
; on/off ($08; the stop keys everything off right after) and tick marks. out_ym's shadow
; took each value when it was queued: dropping them would leave the chip behind the
; shadow, and the next song's writes of the same values would be skipped.
p_fmdrain:
        bit fmq                         ; (not queue mode: nothing queued)
        bpl @r
@l:     lda fm_r
        cmp fm_w
        bne :+
        lda fm_r+1
        cmp fm_w+1
        beq @r                          ; empty
:       lda fm_r
        sta z5
        lda fm_r+1
        sta z6
        sta fq_rd+2
        jsr fq_get
        bne @wr
        jsr fq_get                      ; mark: time skipped
        jsr fq_get
        jsr fq_get
        bra @c
@wr:    tay                             ; register
        jsr fq_get
        cpy #$08
        beq @c
        jsr ym_q
@c:     lda z5
        sta fm_r
        lda z6
        sta fm_r+1
        bra @l
@r:     rts

; p_done (api_status, after the sequence ended): C = 1 when everything has been played:
; FM queue and PCM event queue empty, no voice sounding, and the FIFO's lead L played
; out (L samples after this was first seen)
p_done: php
        sei
        lda fm_r
        cmp fm_w
        bne @busy
        lda fm_r+1
        cmp fm_w+1
        bne @busy
        lda ev_r
        cmp ev_w
        bne @busy
        ldx #NVMAX-1
:       lda v_active,x
        bne @busy
        dex
        bpl :-
        lda dn_on
        bne @chk
        inc dn_on
        clc
        lda s_now
        adc p_l
        sta dn_t
        lda s_now+1
        adc p_l+1
        sta dn_t+1
        lda s_now+2
        adc #0
        sta dn_t+2
@chk:   sec
        lda s_now
        sbc dn_t
        lda s_now+1
        sbc dn_t+1
        lda s_now+2
        sbc dn_t+2
        bmi @wait
        plp
        sec
        rts
@busy:  stz dn_on
@wait:  plp
        clc
        rts

; fq_get: A = byte at z6:z5 (fq_rd+2 = z6), advance with wrap (flags from the byte)
fq_get: ldx z5
fq_rd:  lda $FF00,x
        pha
        inx
        stx z5
        bne :+
        lda z6                          ; next page
        inc a
        cmp #>(fmring + 256 * FMQ_PAGES)
        bne @np
        lda #>fmring
@np:    sta z6
        sta fq_rd+2
:       pla
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

; gen_chunk: mix nchunk samples of all active voices into the FIFO
gen_chunk:
        sec
        lda #0
        sbc nchunk
        sta mix_ystart
        bit fm_mute                     ; bit 6: debug PCM mute (voices still advance)
        bvc :+
        jsr mix_silence
        jmp skip_chunk
:
        lda #1
        sta first
        stz vi
.ifdef PROF
        ldx #NVMAX-1                    ; (profiling: samples per number of voices)
        ldy #0
:       lda v_active,x
        beq :+
        iny
:       dex
        bpl :--
        tya
        sta vc_n
        asl a
        clc                             ; (Y * 3)
        adc vc_n
        tax
        clc
        lda vc_hist,x
        adc nchunk
        sta vc_hist,x
        bcc :+
        inc vc_hist+1,x
        bne :+
        inc vc_hist+2,x
:
.endif
        lda v_cnt                       ; one voice, solo table reserved: its volume's
        dec a                           ; table, straight to the FIFO (mix_solo)
        bne @v
        ora so_on
        beq @v
        ldx #$FF
:       inx
        lda v_active,x
        beq :-
        stx vi                          ; (the loop starts at that voice)
        ldy v_slot,x
        lda sl_vol,y
        cmp so_vol
        bne :+
        lda #$80                        ; first = $80: solo
        sta first
        bra @v
@solo:  lda so_pg                       ; (from the loop: the one voice, X = vi)
        sta mix_vol
        jsr mix_solo
        ldx vi
        lda z7
        jmp advance_voice
:       jsr so_step                     ; not ready: build a part, mix as usual
@v:     ldx vi
        lda v_active,x
        beq @next
        lda v_bank,x
        sta mix_bank
        lda v_plo,x
        sta mix_src
        lda v_phi,x
        sta mix_src+1
        lda v_step,x
        beq @direct
        sta rs_step
        lda v_frac,x
        sta rs_frac
        jsr mix_resample
        stx z7                          ; source samples consumed
        ldx vi
        lda rs_frac
        sta v_frac,x
        lda mix_ystart                  ; mix from RSBUF
        sta mix_src
        lda #>RSBUF
        sta mix_src+1
        bra @mix
@direct:
        lda nchunk
        sta z7
@mix:   bit first                       ; (X = vi on both paths)
        bmi @solo
        lda v_slot,x                    ; LUT page = pm_lut + slot * 2
        asl a
        adc pm_lut                      ; (C = 0: slot < 16)
        sta mix_vol
        lda first
        beq @add
        stz first
        jsr mix_first_voice
        bra @adv
@add:   jsr mix_add_voice
@adv:   ldx vi
        lda z7
        jsr advance_voice
@next:  inc vi
        lda vi
        cmp #NVMAX
        bne @v
        lda first
        bne mix_silence
; mix_output: clip [-512,511], >>2, write 8-bit samples to the FIFO
mix_output:
        ldy mix_ystart
mo_lp:  ldx MIXLO,y          ; 4
        lda lo2tab,x         ; 4
        ldx MIXHI,y          ; 4
        ora hi6tab,x         ; 4
        and himask,x         ; 4
        sta AUDIO_DATA       ; 4
        iny                  ; 2
        bne mo_lp            ; 3   = 29
        rts
; mix_silence: no active voice -> n zero samples (n = -mix_ystart, 1..64). Blocks of 8
; stores (4.6 cycles a sample, the loop took 9); the first block is entered past (-n) & 7.
mix_silence:
        sec
        lda #7
        sbc mix_ystart                  ; n + 7
        lsr
        lsr
        lsr
        tay                             ; blocks
        lda mix_ystart
        and #7
        asl
        tax
        lda #0
        jmp (@ent,x)
@b:
.repeat 8
        sta AUDIO_DATA
.endrep
        dey
        bne @b
        rts
@ent:   .word @b, @b+3, @b+6, @b+9, @b+12, @b+15, @b+18, @b+21

; skip_chunk: advance all active voices by nchunk output samples without output
skip_chunk:
        ldx #NVMAX-1
@v:     lda v_active,x
        beq @n
        lda v_step,x
        bne @rs
        lda nchunk
        bra @a
@rs:    sta z8                          ; consumed = (frac + n * step) >> 8
        lda nchunk
        sta z5
        stz z6
        lda v_frac,x
:       clc
        adc z8
        bcc :+
        inc z6
:       dec z5
        bne :--
        sta v_frac,x
        lda z6
@a:     phx
        jsr advance_voice
        plx
@n:     dex
        bpl @v
        rts

; so_step: A = volume, Y = its LUT slot -> the next 64 entries of the solo table:
; solo[s] = the byte mix_output makes of LUT[s]. At most once per level-2 run.
so_step:
        ldx so_did
        bne sb_r
        inc so_did
        cmp so_bv
        beq :+
        sta so_bv                       ; another volume: start again
        stz so_bi
        ldx #$FF
        stx so_vol
:       tya
        asl a
        adc pm_lut                      ; (C = 0)
        sta sb_lo+2
        inc a
        sta sb_hi+2
        lda so_pg
        sta sb_st+2
        ldy so_bi
sb_lo:  ldx $FF00,y
        lda lo2tab,x
sb_hi:  ldx $FF00,y
        ora hi6tab,x
        and himask,x
sb_st:  sta $FF00,y
        iny
        tya
        and #63
        bne sb_lo
        sty so_bi
        tya
        bne sb_r
        lda so_bv                       ; all 256 entries
        sta so_vol
sb_r:   rts

; advance_voice: X = voice, A = source samples; pointer += A (bank wrap at $BF80),
; remaining -= A; free the voice at the end
advance_voice:
        sta z7
        clc
        adc v_plo,x
        sta v_plo,x
        lda v_phi,x
        adc #0
        sta v_phi,x
        cmp #$BF
        bcc @ok
        bne @wrap
        lda v_plo,x
        cmp #$80
        bcc @ok
@wrap:  sec                             ; ptr -= 8064, next bank
        lda v_plo,x
        sbc #<SBANK_DATA
        sta v_plo,x
        lda v_phi,x
        sbc #>SBANK_DATA
        sta v_phi,x
        inc v_bank,x
@ok:    sec
        lda v_r0,x
        sbc z7
        sta v_r0,x
        lda v_r1,x
        sbc #0
        sta v_r1,x
        lda v_r2,x
        sbc #0
        sta v_r2,x
        bcc @end                        ; went negative
        ora v_r1,x
        ora v_r0,x
        bne @r
@end:   jmp free_voice
@r:     rts

; ---------------------------------------------------------------------------
; events from the core (ae_*), see mxcore.inc
p_event:                                ; direct call (not playing): copy pev_*
        ldx #9
:       lda pev_kind,x
        sta ae_kind,x
        dex
        bpl :-
ev_do:  lda ae_kind
        cmp #PCM_P
        beq ev_p
        cmp #PCM_S
        beq ev_s
        cmp #PCM_X
        beq ev_x
        cmp #PCM_A
        beq ev_a
        cmp #PCM_M
        beq ev_m
        rts
ev_s:   ldx ae_ch
        jmp stop_ch
ev_m:   ldx #8
        jmp stop_ch
ev_x:   jmp free_all

; PCM8 start: channel ae_ch, sample ae_smp, mode = vol << 16 | rate << 8 | pan
ev_p:   ldx ae_ch
        stx tmpch
        lda ae_mode+2
        cmp #$FF                        ; $FF: keep the channel's volume
        beq :+
        and #$0F
        sta ch_vol,x
:       lda ch_vol,x
        sta tmpv
        bra ev_start

; MSM6258 start: channel 8, volume x1
ev_a:   ldx #8
        stx tmpch
        lda #8
        sta tmpv
ev_start:
        jsr stop_ch                     ; X = channel
        lda ae_mode                    ; pan 0: no output
        and #$03
        beq @r
        lda ae_mode+1
        and #$07
        cmp #5
        bcs @r                          ; 16-bit / 8-bit PCM: not supported
        jsr find_dir                    ; X = entry
        bcs @r
        stx tmpd
        lda ae_len                     ; length = min(ae_len, entry) bytes
        sta tmplen
        lda ae_len+1
        sta tmplen+1
        lda ae_len+2
        sta tmplen+2
        lda d_l0,x
        cmp tmplen
        lda d_l1,x
        sbc tmplen+1
        lda d_l2,x
        sbc tmplen+2
        bcs :+
        lda d_l0,x
        sta tmplen
        lda d_l1,x
        sta tmplen+1
        lda d_l2,x
        sta tmplen+2
:       lda tmplen
        ora tmplen+1
        ora tmplen+2
        beq @r
        asl tmplen                      ; samples
        rol tmplen+1
        rol tmplen+2
        jmp start_voice
@r:     rts

; find_dir: ae_smp + rate (ae_mode+1) -> X = directory entry, C = 1 not found
find_dir:
        lda ae_mode+1
        and #$07
        sta z8
        ldx d_n
@l:     dex
        cpx #$FF
        beq @nf
        lda d_slo,x
        cmp ae_smp
        bne @l
        lda d_shi,x
        cmp ae_smp+1
        bne @l
        lda d_rate,x
        cmp z8
        bne @l
        clc
        rts
@nf:    sec
        rts

; p_none: unused entry (P_PACK: packs are read by bank +3 x_pack)
p_none: sec
        rts

; p_getlen (pdx_get): t4:t5 = sample -> t0..t3 = length in bytes (any rate), 0 = none
p_getlen:
        stz t0
        stz t1
        stz t2
        stz t3
        ldx d_n
@l:     dex
        cpx #$FF
        beq @r
        lda d_slo,x
        cmp t4
        bne @l
        lda d_shi,x
        cmp t5
        bne @l
        lda d_l0,x
        sta t0
        lda d_l1,x
        sta t1
        lda d_l2,x
        sta t2
@r:     rts

; start_voice: tmpch, tmpd (directory entry), tmpv (volume index), tmplen (samples)
start_voice:
        ldx #0                          ; free voice?
:       lda v_active,x
        beq @got
        inx
        cpx p_nv
        bne :-
        ldx #0                          ; steal the oldest voice
        ldy #1
@old:   cpy p_nv
        bcs @steal
        lda v_agelo,y
        cmp v_agelo,x
        lda v_agehi,y
        sbc v_agehi,x
        bcs :+
        tya
        tax
:       iny
        bra @old
@steal: jsr free_voice
        inc st_steal
        bne @got
        inc st_steal+1
@got:   stx vi
        jsr get_slot                    ; A = slot for tmpv
        ldx vi
        sta v_slot,x
        lda #1
        sta v_active,x
        inc v_cnt
        lda tmpch
        sta v_ch,x
        tay
        txa
        sta ch_voice,y
        lda age
        sta v_agelo,x
        lda age+1
        sta v_agehi,x
        inc age
        bne :+
        inc age+1
:       ldy tmpd
        lda d_bank,y
        sta v_bank,x
        lda d_alo,y
        sta v_plo,x
        lda d_ahi,y
        sta v_phi,x
        lda d_rate,y
        tay
        lda ratestep,y
        sta v_step,x
        stz v_frac,x
        lda tmplen
        sta v_r0,x
        lda tmplen+1
        sta v_r1,x
        lda tmplen+2
        sta v_r2,x
        lda v_cnt                       ; active voices -> max
        cmp st_maxv
        bcc :+
        sta st_maxv
:       rts

; stop_ch: X = channel (0-8)
stop_ch:
        lda ch_voice,x
        bmi @r
        tax
        jmp free_voice
@r:     rts

; free_voice: X = voice (X preserved)
free_voice:
        lda v_active,x
        beq @r
        stz v_active,x
        dec v_cnt
        ldy v_ch,x
        lda #$FF
        sta ch_voice,y
        ldy v_slot,x
        lda sl_ref,y
        beq @r
        dec a
        sta sl_ref,y
@r:     rts

; get_slot: volume index tmpv -> A = LUT slot (filled if needed), reference taken
get_slot:
        ldx sl_n                        ; slot with this volume?
@f:     dex
        bmi @new
        lda sl_vol,x
        cmp tmpv
        bne @f
        inc sl_ref,x
        txa
        rts
@new:   ldy sl_n                        ; unreferenced slot, round robin from sl_next
        ldx sl_next
@n:     inx
        cpx sl_n
        bcc :+
        ldx #0
:       lda sl_ref,x
        beq @use
        dey
        bne @n
        ldx #0                          ; (cannot happen: slots >= voices + ... )
@use:   stx sl_next
        lda #1
        sta sl_ref,x
        lda tmpv
        sta sl_vol,x
        phx
        jsr fill_lut
        pla
        rts

; fill_lut: X = slot, tmpv = volume index. LUT[q] = trunc(q8 * V / 4), q8 = signed q
fill_lut:
        txa
        asl a
        clc
        adc pm_lut
        sta fl_lo1+2
        sta fl_lo2+2
        inc a
        sta fl_hi1+2
        sta fl_hi2+2
        ldy tmpv
        lda pcm8vol,y
        sta z0                          ; V
        stz z1                          ; acc = i * V
        stz z2
        ldx #0                          ; i = 0..128
fl_l:   lda z2                          ; t = acc >> 2
        sta z4
        lda z1
        lsr z4
        ror a
        lsr z4
        ror a
        sta z3
        cpx #128
        bcs :+
fl_lo1: sta $FF00,x                     ; [i] = t   (i < 128)
        lda z4
fl_hi1: sta $FF00,x
:       txa                             ; [256 - i] = -t   (i >= 1)
        beq fl_nx
        eor #$FF
        inc a
        tay
        sec
        lda #0
        sbc z3
fl_lo2: sta $FF00,y
        lda #0
        sbc z4
fl_hi2: sta $FF00,y
fl_nx:  clc
        lda z1
        adc z0
        sta z1
        bcc :+
        inc z2
:       inx
        cpx #129
        bne fl_l
        rts
