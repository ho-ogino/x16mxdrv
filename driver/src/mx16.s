; mx16.s - Commander X16 platform for mxcore (bank +0 of X16MXDRV.BIN): API jump table,
;           IRQ worker, YM output, MDX access.
;
; X16MXDRV.BIN is four RAM banks (x16mxdrv.cfg). Load it headerless to $A000 of bank D;
; it then occupies banks D to D+3. Call the API below with bank D selected
; (prog8: extsub @bank, cc65/asm: JSRFAR). The driver uses golden RAM $0400-$07FF
; (mxlow.s). It has no zero page of its own: while the core or the loader runs (IRQ
; worker, API calls) it borrows $02-$1D (KERNAL r0-r13) and puts the host's values back.
;
; API (registers in, registers out; r0 = $02/$03 is the KERNAL virtual register):
;   $A000 init      -> A = YM chip (0 unknown, 1 YM2164/OPP, 2 YM2151/OPM),
;                      X = CPU MHz, Y = OPM clock (0 = 3.579545 MHz, 1 = 4 MHz, $FF = unknown)
;   $A003 setmdx    A = bank, X/Y = address (lo/hi, $A000-$BFFF) of the loaded MDX file,
;                   r0 = file size  -> C = 0 ok, C = 1 not an MDX. Stops the current song.
;                   The header, the PDX name and the offset table must lie within r0 bytes;
;                   the song may write only inside the body (repeat counters).
;   $A006 play
;   $A009 stop
;   $A00C fadeout   A = speed (MXDRV $E7 $01 value; 0 -> 17)
;   $A00F status    -> A = bit0 playing, bit1 song ended, bit2 fading, bit3 PCM on;
;                      X/Y = loop count
;   $A012 title     -> A = bank, X/Y = address of the title (Shift_JIS, ends with $0D $0A)
;   $A015 ticks     -> X/Y = Timer-B ticks played (lo/hi)
;   $A018 setopt    A = option, X = value:  0 = YM chip override (1 OPP, 2 OPM),
;                   1 = pitch offset (0..255, 1/64 semitone), 2 = K (ticks per IRQ run),
;                   3 = PCM voice limit (1..8, default 4), 4 = PCM latency L (X * 4 samples,
;                   default 62 = 15.9 ms), 5 = mute (debug: 1 = no YM writes, 2 = no PCM output),
;                   6 = mode (0 direct, 1 queue: FM delayed by L, default), 7 = lookahead A
;                   in queue mode (X * 4 samples, default 196 = 50 ms)
;   $A01B pcmmem    A = first sample bank, X = last sample bank, Y = page of a 256-aligned
;                   low RAM area of r0L * 512 bytes (r0L = volume LUT slots, 4..16)
;                   -> C = 1 PCM not possible (less than 1 MB RAM, bad arguments)
;   $A01E pdxname   -> A = bank, X/Y = address of the PDX name in the MDX (0-terminated),
;                      C = 1 no PDX
;   $A021 pdxbegin  -> A = (sample, rate) pairs used by the song (0 = nothing to load),
;                      C = 1 PCM not possible
;   $A024 pdxfeed   X/Y = low RAM buffer, r0 = length: the next bytes of the PDX file
;                   -> C = 1 all needed data received (the rest of the file can be skipped)
;   $A027 pdxend    -> A = pairs that could not be loaded (no room / file too short),
;                      X = pairs loaded. Enables PCM for this song if X > 0.
;   $A02A pcmstat   -> A = active voices, X/Y = FIFO underruns
;   $A02D snapshot  X/Y = 202-byte low RAM buffer <- display state (consistent enough for
;                   a screen, not atomic): 12 arrays of 16 channels (0-7 FM, 8-15 PCM):
;                   +0 pitch lo, +16 pitch hi (note * 64 + 5 + detune), +32 flags (bit 3
;                   key on), +48 volume, +64 pan (FM: RL<<6 | FB | CON; PCM: rate<<2 | pan),
;                   +80 voice number, +96 key-on counter, +112/+128 detune lo/hi,
;                   +144 pitch LFO type, +160 volume LFO type, +176 PCM bank;
;                   +192 Timer-B, +193 fade level, +194 fading, +195 ended,
;                   +196 loops (2), +198 ticks (2), +200 active channels (2, bit n = ch n)
;   $A030 pdxprog   -> r0 = PDX bytes read / 256, r1 = end of the data needed / 256
;                      (0 until the PDX table has been read); callable between pdxfeeds
;   $A033 pcmpack   A = RAM bank where a PCM pack (tools/mkpack.py, *.P16) was loaded
;                   (after setmdx, instead of pdxbegin..pdxend) -> A = pairs, C = 1 not a
;                   pack or PCM not possible. The pack's banks hold the samples while playing.

.setcpu "65C02"
.macpack longbranch
.include "mxcore.inc"
.include "x16.inc"
.include "mx16.inc"

.import mx_init, mx_play, mx_tick, mx_stop, mx_end, mx_loops, mx_ticks, mx_pause
.import mx_fadeen, mx_fadespd, mx_voicebase, mx_pdx, mx_size, mx_chofs, mx_pofs
.import pe_ch, pe_smp, pe_mode, pe_len
.import c_ntl, c_nth, c_f16, c_v, c_pan, c_vno, c_kcnt, c_detl, c_deth, c_plt, c_vlt, c_bank
.import mx_tempo, mx_fade, mx_active
.importzp ma, t0, t1, t2, t3, rp, rq, rv
.import x_low
.import drvbank, pcmbank, ldrbank, xbank, lo_zsv, lo_zrs, lo_call3, lo_bank, elapsed, busy1, busy2, saved_ien, old_cinv
.import lo_irq, lo_call1, lo_call2, lo_rd, lo_wr
.import m_fm, m_pcm, m_force, k_sh, bit8, lo_setm, lo_mplay
.import s_now, s_next, gpos, s_cur, s_end, pcm_on, fm_mute, fmq, qmode, fq_reg, fq_val
.import tmode, topt, tk_n, tk_cur, t1lat, pq_c, pr_c
.import pev_kind, pev_ch, pev_smp, pev_mode, pev_len
.import la0, la1, la2, la3, la4, lbase, mdx_len, cal_chip, cal_mhz, cal_clk
.import pm_first, pm_last, pm_lut, pm_slots
.ifdef YMLOG
.import lg_w, lg_m, lg_end, lg_pcm
.endif
.ifdef TKLOG
.import tk_log
.endif
.export mdx_rd, mdx_wr, pdx_get, out_ym, out_ymw, out_tempo, out_pcm, worker, shadow, sh_amd, sh_pmd
.export zsave_api, pdxn

R0          = $02

; ===========================================================================
.segment "JMPTBL"
        jmp api_init                ; $A000
        jmp api_setmdx              ; $A003
        jmp api_play                ; $A006
        jmp api_stop                ; $A009
        jmp api_fadeout             ; $A00C
        jmp api_status              ; $A00F
        jmp api_title               ; $A012
        jmp api_ticks               ; $A015
        jmp api_setopt              ; $A018
        jmp api_pcmmem              ; $A01B
        jmp api_pdxname             ; $A01E
        jmp api_pdxbegin            ; $A021
        jmp api_pdxfeed             ; $A024
        jmp api_pdxend              ; $A027
        jmp api_pcmstat             ; $A02A
        jmp api_snap                ; $A02D
        jmp api_pdxprog             ; $A030
        jmp api_pcmpack             ; $A033

; ===========================================================================
.bss
chip:       .res 1                  ; 0 unknown, 1 OPP, 2 OPM
kmax:       .res 1
playing:    .res 1
title_bank: .res 1
title_addr: .res 2
pdxn:       .res 3                  ; linear address of the PDX name (0 = none)
ahead:      .res 2                  ; level 1 lookahead A (samples) in queue mode
sfrac:      .res 3
tq:         .res 2
tr:         .res 3
ticks_left: .res 1
via_acr:    .res 1
shadow:     .res 256                ; YM register shadow
wk_saved:   .res 1
mc_hi:      .res 1                  ; mdx_rd page cache
mc_bank:    .res 1
mc_ah:      .res 1
wk0:        .res 1
wk1:        .res 1
sh_amd:     .res 1                  ; $19 is two registers (AMD / PMD)

.segment "LOWBSS"                   ; (golden RAM, no load image)
zsave_api:  .res ZPN                ; host's $02-$1D during an API call
sh_pmd:     .res 1

; ===========================================================================
.code

; ---------------------------------------------------------------------------
api_init:
        jsr zp_enter
        php
        sei
        lda RAM_BANK                    ; LOWA-LOWD (images in bank +3) to low RAM:
        clc                             ; JSRFAR x_low
        adc #3
        sta @bk
        jsr $FF6E
        .word x_low
@bk:    .byte 0
        lda RAM_BANK
        sta drvbank
        inc a
        sta pcmbank
        inc a
        sta ldrbank
        inc a
        sta xbank
        stz busy1
        stz busy2
        stz playing
        lda #8
        sta kmax
        lda #<784                       ; A = 50 ms
        sta ahead
        lda #>784
        sta ahead+1
        ldx #L_INIT                     ; chip type, CPU MHz, OPM clock
        jsr lo_call2
        jsr mx_init
        lda cal_chip
        sta chip
        lda #123
        ldx cal_clk
        cpx #1
        bne :+
        lda #0
:       sta mx_pofs
        ldx #P_INIT
        jsr lo_call1
        ldx #X_YMRST                    ; known YM state + shadow, no channel muted (bank +3)
        jsr lo_call3
        plp
        lda chip
        ldx cal_mhz
        ldy cal_clk
        jmp zp_leave

; ym_raw: write A to YM register Y (busy wait, gives up after ~256 polls like the
; KERNAL ym_write, so a missing chip cannot hang the driver). A, X, Y preserved.
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
; stop playback (any context with I = 1)
stop_all:
        jsr irq_off
        lda playing
        beq @r
        stz playing
        ldx #P_FMDRAIN                  ; queue mode: the queued YM writes are in the
        jsr lo_call1                    ; shadow already, they must reach the chip
        stz fmq                         ; YM writes go straight to the chip again
        jsr mx_stop
        lda pcm_on
        beq @r
        ldx #P_STOP
        jsr lo_call1
@r:     rts

api_setmdx:
        jsr zp_enter
        php
        sei
        pha
        phx
        phy
        jsr stop_all                    ; a new song: stop the current one first
        stz pcm_on
        stz mx_pdx
        ldx #P_CLEARDIR
        jsr lo_call1
        ply
        plx
        pla
        sta title_bank
        stx title_addr
        sty title_addr+1
        ldx #$FF                        ; (mdx_rd page cache: invalid)
        stx mc_hi
        ldx title_addr
        ; lbase = bank * 8192 + (addr - $A000)
        stz lbase+2
        asl a
        rol lbase+2
        asl a
        rol lbase+2
        asl a
        rol lbase+2
        asl a
        rol lbase+2
        asl a
        rol lbase+2
        sta lbase+1
        stx lbase
        tya
        sec
        sbc #$A0
        clc
        adc lbase+1
        sta lbase+1
        bcc :+
        inc lbase+2
:       ldx #X_MDX                      ; header, PDX name and body size (bank +3, mxhdr.s):
        jsr lo_call3                    ; lbase = body, mdx_len = its size, pdxn
        bcc :+
        plp
        sec
        jmp zp_leave
:       lda mdx_len
        sta mx_size
        lda mdx_len+1
        sta mx_size+1
        ; voice table offset and 16 channel offsets (big endian words)
        stz ma
        stz ma+1
        jsr rd16
        stx mx_voicebase
        sty mx_voicebase+1
        ldx #0
@ch:    phx
        jsr rd16
        txa
        plx
        sta mx_chofs,x
        tya
        sta mx_chofs+1,x
        inx
        inx
        cpx #32
        bne @ch
        plp
        clc
        jmp zp_leave

inc_ma: inc ma
        bne :+
        inc ma+1
:       rts

; rd16: X/Y = big-endian word at ma (lo/hi), ma += 2
rd16:   jsr mdx_rd
        tay
        jsr inc_ma
        jsr mdx_rd
        tax
        jmp inc_ma

; ---------------------------------------------------------------------------
; mdx_rd / mdx_wr: linear MDX body offset ma -> bank/address through low RAM.
map_ma:
        clc
        lda ma
        adc lbase
        sta rp
        lda ma+1
        adc lbase+1
        sta rq                          ; bits 8..15
        lda #0
        adc lbase+2                     ; bits 16..23
lin_map:                                ; A:rq:rp = linear address -> lo_bank, rp
        asl rq                          ; bank = bits 13..20
        rol a
        asl rq
        rol a
        asl rq
        rol a
        sta lo_bank
        lda rq                          ; rq now holds bits 8..12 << 3
        lsr a
        lsr a
        lsr a
        ora #$A0
        sta rp+1
        rts

; mdx_rd: A = MDX body byte at ma (X, Y kept). Fast path: the bank and address of
; the 256-byte page (ma & $FF00) are cached (mc_hi, mc_bank, mc_ah).
mdx_rd: lda ma+1
        cmp mc_hi
        bne @fill
        clc
        lda ma
        adc lbase
        sta rp
        lda mc_ah
        adc #0
        cmp #$C0
        bcs @slow                       ; (crosses into the next bank)
        sta rp+1
        lda mc_bank
        sta lo_bank
        jmp lo_rd
@fill:  phx                             ; cache the page, then retry
        sta mc_hi
        clc
        adc lbase+1
        sta rq
        lda #0
        adc lbase+2
        stz rp
        jsr lin_map
        lda lo_bank
        sta mc_bank
        lda rp+1
        sta mc_ah
        plx
        bra mdx_rd
@slow:  phx
        jsr map_ma
        plx
        jmp lo_rd

mdx_wr: pha                             ; (only inside the body: a broken repeat offset
        lda ma                          ; must not reach the host's memory after it)
        cmp mdx_len
        lda ma+1
        sbc mdx_len+1
        bcs @no
        phx
        jsr map_ma
        plx
        pla
        jmp lo_wr
@no:    pla
        rts

; pdx_get: t0..t3 = length of PDX entry t4:t5 if it was loaded (any rate), else 0
pdx_get:
        phx
        phy
        ldx #P_GETLEN
        jsr lo_call1
        ply
        plx
        rts

; out_pcm: A = event kind, operands in pe_*  (X kept). Mute: the start events of a muted
; channel do not go out (PCM8 start: voice pe_ch; MSM6258 start: P); stops always do.
out_pcm:
        cmp #PCM_P
        beq op_p
        cmp #PCM_A
        bne op_go
        pha
        lda m_pcm
        and #$01
        bra op_t
op_p:   pha
        phx
        ldx pe_ch
        lda bit8,x
        plx
        and m_pcm
op_t:   beq op_ok
        pla
        rts
op_ok:  pla
op_go:
.ifdef YMLOG
        jsr lg_pcm                      ; (the event in the YM log: as register $10)
.endif
        phy
        ldy pcm_on
        beq @r0
        phx
        sta pev_kind
        ldx #8
:       lda pe_ch,x                     ; pe_ch, pe_smp(2), pe_mode(3), pe_len(3)
        sta pev_ch,x
        dex
        bpl :-
        ldx #P_EVPUSH                   ; applied by level 2 when G reaches s_cur
        bit playing
        bmi :+
        ldx #P_EVENT                    ; (not playing: apply now)
:       jsr lo_call1
        plx
@r0:    ply
        rts

; ---------------------------------------------------------------------------
; out_ym: Y = register, A = value (X preserved). Skips writes that would not change
; the chip, except key on/off ($08) and LFO reset ($01); $19 holds AMD and PMD.
; Mute (setopt 9 / 10): a key write ($08) or a channel register ($20-$FF) of a muted FM
; channel updates the shadow but does not go out; k_sh keeps each channel's key state.
; out_ymw: the write itself (bank +3 x_mute's forced writes come here through lo_ymf).
out_ym: cpy #$08
        beq out_ymw
        cpy #$01
        beq oy_lfo
        cpy #$19
        beq oy_d19
        cmp shadow,y
        beq oy_r
        sta shadow,y
out_ymw:
        bit m_force
        bmi oy_go
        cpy #$08
        beq oy_key
        cpy #$20
        bcc oy_go
        phx                             ; a channel register: muted?
        pha
        tya
        and #$07
        tax
        bra oy_m
oy_key: phx                             ; key: remember the channel's state; muted?
        pha
        and #$07
        tax
        pla
        sta k_sh,x
        pha
oy_m:   lda bit8,x
        and m_fm
        bne oy_hold
        pla
        plx
oy_go:  bit fmq
        bmi oy_q
.ifdef YMLOG
        jsr lg_w                        ; (direct write; queued ones: mxpcm.s ym_q)
.endif
        bit fm_mute
        bmi oy_r
        jmp ym_raw
oy_hold:
        pla
        plx
        rts
oy_q:   sta fq_val                      ; queue mode: level 2 writes it at s_cur + L
        sty fq_reg
        phx                             ; (A, X, Y preserved like ym_raw: the core relies on it)
        phy
        ldx #P_FMPUSH
        jsr lo_call1
        ply
        plx
        lda fq_val
        rts
oy_lfo: ldy chip
        cpy #1
        beq :+
        ldy #$01
        bra oy_go
:       ldy #$09                        ; YM2164: LFO reset/test register is $09
        bra oy_go
oy_d19: cmp #$80
        bcs oy_pmd
        cmp sh_amd
        beq oy_r
        sta sh_amd
        bra oy_go
oy_pmd: cmp sh_pmd
        beq oy_r
        sta sh_pmd
        bra oy_go
oy_r:   rts

; out_tempo: A = Timer-B value n (0-255; 0 = the slowest: m = 256, 65.536 ms per tick.
; MXDRV also writes 0 when the song ends)
out_tempo:
        sta tk_n                        ; (tick clock: level 2 changes the T1 period)
        phx
        eor #$FF                        ; m = 256 - n: tq = 4m (+1 if m = 256), tr = (m & 255) << 11
        clc
        adc #1
        sta rq
        bne :+
        lda #<1025
        sta tq
        lda #>1025
        sta tq+1
        stz tr
        stz tr+1
        stz tr+2
        plx
        rts
:       stz tq+1
        asl a
        rol tq+1
        asl a
        rol tq+1
        sta tq
        lda rq
        stz tr
        stz tr+2
        asl a
        rol tr+2
        asl a
        rol tr+2
        asl a
        rol tr+2
        sta tr+1
        plx
@r:     rts

; ---------------------------------------------------------------------------
api_play:
        jsr zp_enter
        php
        sei
        jsr stop_all
        jsr lo_mplay                    ; the wanted mute masks hold from the start
        jsr mx_play
        ldx #2
:       stz s_now,x
        stz s_next,x
        stz sfrac,x
        stz s_end,x
        stz gpos,x
        dex
        bpl :-
        stz fmq
        stz tmode                       ; (the first ticks: no tick clock yet)
        lda pcm_on
        beq :+
        lda qmode
        beq :+
        lda #$80
        sta fmq
:       lda pcm_on
        beq :+
        ldx #P_START                    ; FIFO reset, L samples of silence, queues empty
        jsr lo_call1
:       lda #$80                        ; (playing: PCM events go to the queue)
        sta playing
        lda #1                          ; the first tick (time 0) before the clock starts;
        jsr wk_k                        ; the next ones from the interrupt, A ahead
        jsr tk_init                     ; T1 period: per tick (no PCM) or 2 ms
        jsr irq_on
        lda pcm_on                      ; start the FIFO together with the real clock
        beq :+
        lda #PCM_RATE
        sta AUDIO_RATE
:       plp
        jmp zp_leave

api_stop:
        jsr zp_enter
        php
        sei
.ifdef YMLOG
        jsr lg_m                        ; (closes the last tick: the stop's own writes follow)
.endif
        jsr stop_all
.ifdef YMLOG
        jsr lg_end                      ; end marker: $00 $FF
.endif
        plp
        jmp zp_leave

api_fadeout:
        cmp #0
        bne :+
        lda #17
:       sta mx_fadespd
        stz mx_fadespd+1
        lda #$FF
        sta mx_fadeen
        rts

api_status:
        lda playing
        beq :+
        lda #1
        ldx mx_end
        beq :+
        ora #$10                        ; sequence ended
        ldx pcm_on                      ; (no PCM: FM was written at the tick)
        beq @e
        pha
        ldx #P_DONE                     ; queued FM, PCM events and voices, FIFO played?
        jsr lo_call1
        pla
        bcc :+
@e:     ora #2                          ; played to the end
:       ldx mx_fadeen
        beq :+
        ora #4
:       ldx pcm_on
        beq :+
        ora #8
:       ldx mx_loops
        ldy mx_loops+1
        rts

api_title:
        lda title_bank
        ldx title_addr
        ldy title_addr+1
        rts

api_ticks:
        ldx mx_ticks
        ldy mx_ticks+1
        rts

api_setopt:
        cmp #9                          ; 9 / 10: mute masks (low RAM)
        bcc :+
        jmp lo_setm
:       cmp #0
        bne :+
        stx chip
        rts
:       cmp #1
        bne :+
        stx mx_pofs
        rts
:       cmp #2
        bne :+
        stx kmax
        rts
:       cmp #3
        bne :+
        stx la0
        ldx #P_SETNV
        jmp lo_call1
:       cmp #6
        bne :+
        stx qmode                       ; 0 direct, 1 queue (next play)
        rts
:       cmp #8
        bne :+
        stx topt                        ; 0: 2 ms clock even without PCM (next play)
        rts
:       cmp #7
        bne :+
        stz ahead+1                     ; A = X * 4 samples
        txa
        asl a
        rol ahead+1
        asl a
        rol ahead+1
        sta ahead
        rts
:       cmp #4
        bne :+
        stz la1                         ; L = X * 4
        txa
        asl a
        rol la1
        asl a
        rol la1
        sta la0
        ldx #P_SETL
        jmp lo_call1
:       cmp #5
        bne :+
        txa                             ; bit 0 -> $80 (FM mute), bit 1 -> $40 (PCM mute)
        and #3
        tax
        lda mutetab,x
        sta fm_mute
:       rts

mutetab: .byte 0, $80, $40, $C0

api_pcmmem:
        sta pm_first
        stx pm_last
        sty pm_lut
        lda R0
        sta pm_slots
        ldx #P_SETUP
        jmp lo_call1

api_pdxname:
        lda pdxn
        ora pdxn+1
        ora pdxn+2
        bne :+
        sec
        rts
:       jsr zp_enter
        lda pdxn
        sta rp
        lda pdxn+1
        sta rq
        lda pdxn+2
        jsr lin_map
        lda lo_bank
        ldx rp
        ldy rp+1
        clc
        jmp zp_leave

api_pdxbegin:
        jsr zp_enter
        php
        sei
        jsr stop_all
        stz pcm_on
        stz mx_pdx
        plp
        ldx #L_BEGIN
        jsr lo_call2
        jmp zp_leave

api_pdxfeed:
        stx la0
        sty la1
        lda R0
        sta la2
        lda R0+1
        sta la3
        jsr zp_enter
        ldx #L_FEED
        jsr lo_call2
        jmp zp_leave

api_pdxend:
        jsr zp_enter
        ldx #L_END
        jsr lo_call2
        ldx la0                         ; pairs loaded
        beq :+
        ldy #1
        sty pcm_on
        sty mx_pdx
:       ldy la2                         ; 1: the song has more than 96 pairs (some not loaded)
        jmp zp_leave

; api_pcmpack: A = bank B of a PCM pack (header in B, samples from B+1), r0 + r1L = sample
; part bytes read (version 2) -> A = entries the song uses, X = pairs it lacks ($FE: cannot
; tell, over 96 pairs; $FF: version 1), Y = PK_* (mx16.inc), C = 1 error (PCM off)
api_pcmpack:
        jsr zp_enter
        sta la0
        lda R0
        sta la1
        lda R0+1
        sta la2
        lda R0+2
        sta la3
        ldx #X_PACK
        jsr lo_call3
        php
        ldy pcm_on
        sty mx_pdx
        ldy la4
        plp
        jmp zp_leave

api_pdxprog:
        ldx #L_PROG
        jsr lo_call2
        ldx #3
:       lda la0,x                       ; -> r0, r1
        sta R0,x
        dex
        bpl :-
        rts

api_pcmstat:
        ldx #P_STAT
        jsr lo_call1
        lda la0
        ldx la2
        ldy la3
        rts

; api_snap: X/Y = destination (see the API list)
api_snap:
        stx @dst+1
        sty @dst+2
        ldy #0
@f:     lda snap_l,y
        sta @src+1
        lda snap_h,y
        sta @src+2
        ldx #0
@src:   lda $FFFF,x
@dst:   sta $FFFF
        inc @dst+1
        bne :+
        inc @dst+2
:       inx
        txa
        cmp snap_n,y
        bne @src
        iny
        cpy #snap_cnt
        bne @f
        rts
.define SNAPSRC c_ntl, c_nth, c_f16, c_v, c_pan, c_vno, c_kcnt, c_detl, c_deth, c_plt, c_vlt, c_bank, mx_tempo, mx_fade, mx_fadeen, mx_end, mx_loops, mx_ticks, mx_active
snap_l: .lobytes SNAPSRC
snap_h: .hibytes SNAPSRC
snap_n: .byte 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 16, 1, 1, 1, 1, 2, 2, 2
snap_cnt = * - snap_n

; tk_init: T1 period before play (I = 1, after the first ticks, T1 stopped)
;   sample clock (songs with PCM, or option 8 = 0): every 2 ms
;   tick clock (no PCM): the Timer-B period / k (k = 1, 2, 4, ..), so the ticks fall on
;   T1 interrupts: k per tick instead of one every 2 ms (mxload.s l_tempo)
; The real clock s_now advances by pq_c + pr_c / 2^19 samples per T1 period (mxpcm.s).
P_US        = 2000                  ; sample clock: T1 period in microseconds
SQ          = 31                    ; its samples: 16000 * 1025 / 2^19 = 31 + SR / 2^19
SR          = 147072
tk_init:
        lda pcm_on
        bne @smp
        lda topt
        beq @smp
        lda #$80
        sta tmode
        ldx #L_TEMPO
        ldy #0                          ; (before play)
        jmp lo_call2
@smp:   lda #SQ
        sta pq_c
        stz pq_c+1
        lda #<SR
        sta pr_c
        lda #>SR
        sta pr_c+1
        lda #^SR
        sta pr_c+2
        lda #<($10000 - 2)              ; latch = P_US * MHz - 2
        sta t1lat
        lda #>($10000 - 2)
        sta t1lat+1
        ldx cal_mhz
:       clc
        lda t1lat
        adc #<P_US
        sta t1lat
        lda t1lat+1
        adc #>P_US
        sta t1lat+1
        dex
        bne :-
        rts

; irq_on / irq_off (called with I = 1)
irq_on: lda CINV
        sta old_cinv
        lda CINV+1
        sta old_cinv+1
        lda #<lo_irq
        sta CINV
        lda #>lo_irq
        sta CINV+1
        stz elapsed
        stz elapsed+1
        stz busy1
        stz busy2
        lda VIA1_ACR
        sta via_acr
        and #$3F
        ora #$40
        sta VIA1_ACR
        lda t1lat                       ; T1 period (mxload.s l_tkinit)
        sta VIA1_T1LL
        lda t1lat+1
        sta VIA1_T1LH
        lda VIA1_T1CL
        lda #$C0
        sta VIA1_IER
        lda VIA1_T1LL
        sta VIA1_T1CL
        lda VIA1_T1LH
        sta VIA1_T1CH
        rts

irq_off:
        lda playing
        beq @r
        lda #$40
        sta VIA1_IER
        lda VIA1_T1CL
        lda #$FF
        sta VIA1_T1LL
        sta VIA1_T1LH
        lda via_acr
        sta VIA1_ACR
        lda old_cinv
        sta CINV
        lda old_cinv+1
        sta CINV+1
@r:     rts

; ---------------------------------------------------------------------------
; worker = IRQ level 1 (from lo_irq, I = 0, busy1 = 1, driver bank selected; also
; called once by api_play before the clock starts): run due ticks, at most kmax.
;   due: s_next <= s_now + A (queue mode) or s_next <= s_now (direct mode)
; Events of a tick carry its time s_cur; s_end tells level 2 how far they are known.
worker:
        lda kmax
wk_k:   sta ticks_left
        stz wk_saved
@loop:  bit tmode                       ; tick clock and the tempo changed: T1 period
        bpl :+
        lda tk_n
        cmp tk_cur
        beq :+
        ldy #2
        ldx #L_TEMPO
        jsr lo_call2
:       sei                             ; t = s_next - s_now (24-bit signed)
        sec
        lda s_next
        sbc s_now
        sta wk0
        lda s_next+1
        sbc s_now+1
        sta wk1
        lda s_next+2
        sbc s_now+2
        cli
        bmi @due                        ; already late
        bit fmq
        bpl @dir
        tax                             ; queue mode: due if t - A <= 0
        sec
        lda wk0
        sbc ahead
        sta wk0
        lda wk1
        sbc ahead+1
        sta wk1
        txa
        sbc #0
        bmi @due
        ora wk0
        ora wk1
        jne @done
        bra @due
@dir:   ora wk0
        ora wk1
        jne @done                       ; direct: due if t <= 0
@due:   lda wk_saved                    ; borrow $02-$1D for the core (once per run)
        bne :+
        inc wk_saved
        jsr lo_zsv                      ; (unrolled copy in bank +3)
:       lda ticks_left
        jeq @done
        dec ticks_left
        lda s_next
        sta s_cur
        lda s_next+1
        sta s_cur+1
        lda s_next+2
        sta s_cur+2
        bit fmq
        bpl :+
        lda mx_end                      ; (after the end no marks: the queue can run empty,
        bne :+                          ; and the status can tell that all was played)
        ldx #P_FMMARK
        jsr lo_call1
:
.ifdef TKLOG
        jsr tk_log
.endif
        ldx #X_MUTE                     ; mute masks changed: apply (bank +3; before mx_tick's
        jsr lo_call3                    ; return at the end / pause)
        jsr mx_tick
.ifdef YMLOG
        bit fmq                         ; tick marker: register $00 (queue mode: level 2
        bmi :+                          ; logs it when the next tick's mark is flushed)
        jsr lg_m
:
.endif
        clc                             ; s_next += tq + tr / 2^19
        lda sfrac
        adc tr
        sta sfrac
        lda sfrac+1
        adc tr+1
        sta sfrac+1
        lda sfrac+2
        adc tr+2
        cmp #$08
        bcc :+
        sbc #$08
:       sta sfrac+2
        lda s_next
        adc tq
        sta s_next
        lda s_next+1
        adc tq+1
        sta s_next+1
        bcc :+
        inc s_next+2
:       sei                             ; events up to s_next are known
        lda s_next
        sta s_end
        lda s_next+1
        sta s_end+1
        lda s_next+2
        sta s_end+2
        cli
        jmp @loop
@done:  lda wk_saved                    ; give the host's zero page back
        beq :+
        jmp lo_zrs
:       rts

; zp_enter / zp_leave: API calls that run the core or the loader borrow $02-$1D
; (A, X, Y and P kept by both)
zp_enter:
        php
        pha
        phx
        ldx #ZPN-1
:       lda ZPS,x
        sta zsave_api,x
        dex
        bpl :-
        plx
        pla
        plp
        rts
zp_leave:
        php
        pha
        phx
        ldx #ZPN-1
:       lda zsave_api,x
        sta ZPS,x
        dex
        bpl :-
        plx
        pla
        plp
        rts
