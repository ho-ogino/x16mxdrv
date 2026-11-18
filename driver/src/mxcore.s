; mxcore.s - MXDRV 2.06+17 compatible MDX sequencer core for the 65C02 (Commander X16)
;
; A clean 6502 re-implementation of MXDRV's playback behaviour, written from the
; 68000 original quoted in thirdparty/portable_mdx/src/mxdrv/mxdrv.cpp. Comments
; name the original routines (Lxxxxxx) and work fields ($xx of MXWORK_CH).
;
; Platform interface (driver/src/platform_*.s):
;   mdx_rd     A = MDX body byte at linear offset ma (zp 16-bit)        (X,Y kept)
;   mdx_wr     store A at linear offset ma                            (A,X,Y kept)
;   pdx_get    t0..t3 = length (32-bit) of PDX entry t4:t5, 0 if none   (X kept)
;   out_ym     YM write, Y = register, A = value (already X16-converted)(X kept)
;   out_tempo  A = Timer-B value, where MXDRV writes OPM register $12   (X kept)
;   out_pcm    A = event kind (mxcore.inc), operands in pe_*            (X kept)
;
; X16 conversion (opm_write):
;   $10/$11/$14 dropped, $12 -> out_tempo, $1B bits 6-7 masked,
;   KF ($30+ch) is held back and emitted together with the next KC ($28+ch) write,
;   with the pitch moved +123/64 semitone (4 MHz -> 3.579545 MHz OPM clock).

.setcpu "65C02"
.include "mxcore.inc"

.export mx_init, mx_play, mx_tick, mx_stop, mx_pofs, mx_fadeen, mx_fadespd
.export mx_end, mx_loops, mx_ticks, mx_tempo, mx_pcm8, mx_noise, mx_pause
.export mx_voicebase, mx_pdx, mx_size, mx_chofs, mx_fadeloop, mx_loopleft
.export c_ntl, c_nth, c_f16, c_v, c_pan, c_vno, c_kcnt, c_detl, c_deth, c_plt, c_vlt, c_bank
.export c_vlast, mx_fade, mx_fadeen, mx_active
.export pe_ch, pe_smp, pe_mode, pe_len
.exportzp ma, t0, t1, t2, t3, t4, t5, t6, t7, seqp, m0, r0

.import mdx_rd, mdx_wr, pdx_get, out_ym, out_tempo, out_pcm

NCH  = 16
STUB = $FF00                        ; sequence pointer value of the "ended" stub

; ===========================================================================
.zeropage
ma:      .res 2                     ; MDX linear address for mdx_rd / mdx_wr
seqp:      .res 2                     ; sequence pointer of the item being processed
chn:     .res 1                     ; current channel (0..15)
t0:      .res 1
t1:      .res 1
t2:      .res 1
t3:      .res 1
t4:      .res 1
t5:      .res 1
t6:      .res 1
t7:      .res 1
m0:      .res 1                     ; multiply operands / result
m1:      .res 1
m2:      .res 1
m3:      .res 1
r0:      .res 1
r1:      .res 1
r2:      .res 1
r3:      .res 1
wreg:    .res 1
wval:    .res 1
dispose: .res 1

; ===========================================================================
.bss
; ---- channel work (MXWORK_CH): one array of NCH bytes per field -------------
chwork_start:
c_ptl:   .res NCH                   ; $00 sequence pointer (linear)
c_pth:   .res NCH
c_vol:   .res NCH                   ; $04 voice data pointer (linear, 0 = none)
c_voh:   .res NCH
c_bank:  .res NCH                   ; $04_b PCM bank
c_bdl:   .res NCH                   ; $08 portamento delta (word; real value = word << 8)
c_bdh:   .res NCH
c_bo0:   .res NCH                   ; $0c portamento offset bits 8..31 (bits 0..7 are 0)
c_bo1:   .res NCH
c_bo2:   .res NCH
c_detl:  .res NCH                   ; $10 detune
c_deth:  .res NCH
c_ntl:   .res NCH                   ; $12 note*64 + 5 + detune
c_nth:   .res NCH
c_lpl:   .res NCH                   ; $14 last pitch
c_lph:   .res NCH
c_f16:   .res NCH                   ; $16 b0 note pending, b1 LFO sync, b2 legato, b3 key on,
                                    ;     b4 key off before key on, b5 pitch LFO, b6 vol LFO, b7 porta
c_f17:   .res NCH                   ; $17 b1 voice pending, b2 pan pending, b3 sync wait, b7 ($E7 6)
c_ch:    .res NCH                   ; $18 OPM channel, or $80 | n for PCM
c_car:   .res NCH                   ; $19 carrier mask
c_len:   .res NCH                   ; $1a
c_gate:  .res NCH                   ; $1b
c_pan:   .res NCH                   ; $1c RL|FB|CON (FM) / rate << 2 | pan (PCM)
c_kon:   .res NCH                   ; $1d key-on slots << 3 | channel
c_q:     .res NCH                   ; $1e
c_kdly:  .res NCH                   ; $1f
c_kdcnt: .res NCH                   ; $20
c_pmsams: .res NCH                  ; $21
c_v:     .res NCH                   ; $22
c_vlast: .res NCH                   ; $23
c_ldly:  .res NCH                   ; $24
c_ldcnt: .res NCH                   ; $25
c_plt:   .res NCH                   ; $26 pitch LFO type 0 (none), 1 saw, 2 square, 3 tri, 4 random
c_pos0:  .res NCH                   ; $2a pitch LFO offset start (32-bit, little endian)
c_pos1:  .res NCH
c_pos2:  .res NCH
c_pos3:  .res NCH
c_pds0:  .res NCH                   ; $2e pitch LFO delta start
c_pds1:  .res NCH
c_pds2:  .res NCH
c_pds3:  .res NCH
c_pd0:   .res NCH                   ; $32 pitch LFO delta
c_pd1:   .res NCH
c_pd2:   .res NCH
c_pd3:   .res NCH
c_po0:   .res NCH                   ; $36 pitch LFO offset
c_po1:   .res NCH
c_po2:   .res NCH
c_po3:   .res NCH
c_plcl:  .res NCH                   ; $3a pitch LFO length (cooked)
c_plch:  .res NCH
c_pll:   .res NCH                   ; $3c pitch LFO length
c_plh:   .res NCH
c_pcl:   .res NCH                   ; $3e pitch LFO counter
c_pch:   .res NCH
c_vlt:   .res NCH                   ; $40 volume LFO type 0..4
c_vdsl:  .res NCH                   ; $44 volume LFO delta start
c_vdsh:  .res NCH
c_vosl:  .res NCH                   ; $46 volume LFO offset start
c_vosh:  .res NCH
c_vdl:   .res NCH                   ; $48 volume LFO delta
c_vdh:   .res NCH
c_vofl:  .res NCH                   ; $4a volume LFO offset
c_vofh:  .res NCH
c_vll:   .res NCH                   ; $4c volume LFO length
c_vlh:   .res NCH
c_vcl:   .res NCH                   ; $4e volume LFO counter
c_vch:   .res NCH
g_sync:  .res NCH                   ; L001df6 sync flags
c_vno:   .res NCH                   ; (display) voice number of the last @
c_kcnt:  .res NCH                   ; (display) key-on counter
kf_raw:  .res 8                     ; KF written by MXDRV (before X16 conversion)
chwork_end:

pe_ch:   .res 1
pe_smp:  .res 2
pe_mode: .res 3
pe_len:  .res 3

mx_tempo:    .res 1                 ; L001e0c
mx_fade:     .res 1                 ; L001e14
mx_fade15:   .res 1                 ; L001e15
mx_fadeen:   .res 1                 ; L001e17
mx_fadespd:  .res 2                 ; L001e1e
mx_fadecnt:  .res 2                 ; L001e20
mx_pause:    .res 1                 ; L001e12
mx_end:      .res 1                 ; L001e13
mx_pcm8:     .res 1                 ; L001df4
mx_loopmk:   .res 2                 ; L001e1a
mx_active:   .res 2                 ; L001e06
mx_loops:    .res 2                 ; L002246
mx_ticks:    .res 2                 ; L001ba6
mx_noise:    .res 1                 ; L002232
mx_fadeloop: .res 1                 ; L001e18 (fade after mx_loopleft loops)
mx_loopleft: .res 2                 ; L001e22
mx_last1b:   .res 1                 ; last raw $1B value ($09da)
mx_seed:     .res 2                 ; L001190
mx_pofs:     .res 1                 ; KC pitch offset (1/64 semitone): 123 for a 3.579545 MHz OPM
; set by the caller before mx_play
mx_voicebase: .res 2                ; L002228 voice table (linear)
mx_pdx:      .res 1                 ; L002231 PDX present
mx_size:     .res 2                 ; MDX body size (bounds the voice search)
mx_chofs:    .res 2*NCH             ; channel sequence start (linear), lo/hi pairs

; ===========================================================================
.rodata
.include "mxtables.inc"

; ===========================================================================
.code

; ---------------------------------------------------------------------------
; mx_init: clear all driver state (once, before the first mx_play)
mx_init:
        lda #<chwork_start
        sta t0
        lda #>chwork_start
        sta t1
@clr:   lda #0
        sta (t0)
        inc t0
        bne :+
        inc t1
:       lda t0
        cmp #<chwork_end
        bne @clr
        lda t1
        cmp #>chwork_end
        bne @clr
        lda #$34
        sta mx_seed
        lda #$12
        sta mx_seed+1
        stz mx_last1b
        stz mx_pause
        stz mx_pcm8
        stz mx_fadeloop
        lda #123
        sta mx_pofs
        lda #1
        sta mx_end
        rts

; ---------------------------------------------------------------------------
; mx_play: start playback (L_PLAY / L0007c0)
mx_play:
        stz mx_fade
        stz mx_fade15
        stz mx_fadeen
        stz mx_end
        lda mx_pause
        beq :+
        stz pe_ch                       ; L0007ee: PCM8 $0100 -> channel 0 stop
        lda #PCM_S
        jsr out_pcm
:       stz mx_pause
        stz mx_pcm8
        lda #$FF
        sta mx_loopmk
        sta mx_active
        lda #$01
        sta mx_loopmk+1
        sta mx_active+1
        stz mx_loops
        stz mx_loops+1
        stz mx_ticks
        stz mx_ticks+1
        jsr stop_sound                  ; L00063e
        ; channel initialisation (L000866)
        ldx #0
@ch:    txa
        asl a
        tay
        lda mx_chofs,y
        sta c_ptl,x
        lda mx_chofs+1,y
        sta c_pth,x
        stz c_plt,x
        stz c_vlt,x
        lda #$FF
        sta c_lpl,x
        sta c_lph,x
        sta c_vlast,x
        stz c_kon,x
        lda #1
        sta c_len,x
        lda #8
        sta c_v,x
        sta c_q,x
        stz c_po2,x                     ; clr.w $0036: upper word only
        stz c_po3,x
        stz c_vofl,x
        stz c_vofh,x
        stz c_detl,x
        stz c_deth,x
        stz c_ldly,x
        stz c_kdly,x
        stz c_car,x
        stz c_f16,x
        stz c_f17,x
        cpx #8
        bcs @pcm
        txa
        sta c_ch,x
        lda #$C0
        sta c_pan,x
        txa
        clc
        adc #$38
        tay
        lda #0
        jsr opm_write                   ; PMS/AMS = 0
        bra @next
@pcm:   txa
        and #$07
        ora #$80
        sta c_ch,x
        lda #$10
        sta c_pan,x
        stz c_bank,x
@next:  inx
        cpx #NCH
        bne @ch
        ldx #NCH-1
:       stz g_sync,x
        dex
        bpl :-
        stz mx_noise
        lda #0
        ldy #$01
        jsr opm_write
        ldy #$0F
        jsr opm_write
        ldy #$19
        jsr opm_write
        lda #$80
        jsr opm_write
        lda #$C8
        sta mx_tempo
        ldy #$12
        jsr opm_write
        stz mx_end                      ; L00056a
        rts

; stop_sound (L00063e): end flag, mute, PCM stop, release and key off everything
mx_stop:
stop_sound:
        lda #1
        sta mx_end
        jsr mute_all                    ; L0006c4
        stz pe_ch                       ; L000664: PCM8 $0100
        lda #PCM_S
        jsr out_pcm
        stz mx_pcm8
        lda #$0F
        ldy #$E0
:       jsr opm_write
        iny
        bne :-
        ldx #0
:       txa
        ldy #$08
        jsr opm_write
        inx
        cpx #8
        bne :-
        rts

; mute_all (L0006c4): carriers of FM channels 0-7 to TL $7F, PCM8 abort
mute_all:
        ldx #0
@l:     stx chn
        lda #$7F
        jsr vol_write
        ldx chn
        inx
        cpx #8
        bne @l
        lda #PCM_X
        jmp out_pcm

; ---------------------------------------------------------------------------
; mx_tick: one Timer-B period (L_OPMINT)
mx_tick:
        lda mx_pause
        bne @tempo
        lda mx_fadeen
        beq @tempo
        bpl @run
        lda #$7F
        sta mx_fadeen
        lda mx_fadespd
        sta mx_fadecnt
        lda mx_fadespd+1
        sta mx_fadecnt+1
@run:   lda mx_fadecnt+1
        bmi @step
        sec
        lda mx_fadecnt
        sbc #2
        sta mx_fadecnt
        bcs @tempo
        dec mx_fadecnt+1
        bra @tempo
@step:  lda mx_fade
        cmp #$0A                        ; signed >= $0A (fade is 0..$7F here)
        bmi :+
        lda #$FF
        sta mx_fade15
:       lda mx_fade
        cmp #$3E
        bpl @fend
        inc mx_fade
        lda mx_fadespd
        sta mx_fadecnt
        lda mx_fadespd+1
        sta mx_fadecnt+1
        bra @tempo
@fend:  lda #$7F                        ; L000a26 (no "next song" support)
        sta mx_fade
        stz mx_fadeen
        lda #1
        sta mx_end
        lda #$FF
        sta mx_pause
        jsr mute_all                    ; L_PAUSE (emits PCM8 abort)
        stz pe_ch                       ; L000a50: PCM8 $0100 -> channel 0 stop
        lda #PCM_S
        jsr out_pcm
        stz mx_pcm8
@tempo: lda mx_pause
        ora mx_end
        beq @play
        lda #0
        ldy #$12
        jmp opm_write
@play:  lda mx_tempo
        ldy #$12
        jsr opm_write
        inc mx_ticks
        bne :+
        inc mx_ticks+1
:       ldx #0
@ch:    stx chn                         ; FM channels 0-7
        jsr lfo_update                  ; L001050
        ldx chn
        jsr seq_tick                    ; L0011b4
        ldx chn
        jsr out_stage                   ; L000c66
        ldx chn
        inx
        cpx #8
        bne @ch
@pch:   stx chn                         ; PCM channels (c_ch = $80 | n): lfo_update returns at
        jsr seq_tick                    ; once, out_stage too unless a key on is pending (bit 0)
        ldx chn
        lda c_f16,x
        lsr a
        bcc :+
        jsr out_stage
        ldx chn
:       inx
        cpx #9
        bne :+
        lda mx_pcm8
        beq @done
:       cpx #NCH
        bne @pch
@done:  rts

; ===========================================================================
; output filter: Y = OPM register, A = value (X preserved)
opm_write:
        sta wval
        sty wreg
        cpy #$12
        beq @tempo
        cpy #$00                        ; (no register; the FM queue marks ticks with 0)
        beq @drop
        cpy #$10
        beq @drop
        cpy #$11
        beq @drop
        cpy #$14
        beq @drop
        cpy #$1B
        bne :+
        sta mx_last1b
        and #$3F
        jmp out_ym
:       cpy #$28
        bcc @out
        cpy #$38
        bcs @out
        cpy #$30
        bcs @kf
        jmp kc_write
@kf:    tya
        and #$07
        tay
        lda wval
        sta kf_raw,y
@drop:  rts
@tempo: jmp out_tempo
@out:   jmp out_ym

; kc_write: MXDRV wrote KC wval to register wreg ($28+ch) itself ($FE; pitch_out writes
; straight). Recover MXDRV's pitch from KC and the held KF, then as pitch_out (po_emit).
kc_write:
        phx
        lda wreg
        and #$07
        tay                             ; channel
        lda wval
        and #$7F
        tax
        lda kcidx,x                     ; note index
        stz t1
        ldx #6
:       asl a                           ; pitch = index << 6 | KF >> 2
        rol t1
        dex
        bne :-
        sta t0
        lda kf_raw,y
        lsr a
        lsr a
        ora t0
        sta t0
        jsr po_emit
        plx
        rts

; ===========================================================================
; L001050: portamento and LFO update (X = channel)
lfo_update:
        lda c_ch,x
        bmi @r
        lda c_f16,x
        bpl @nop
        lda c_kdcnt,x
        bne @nop
        lda c_bdh,x                     ; S000c += S0008 (bits 8..31)
        and #$80
        beq :+
        lda #$FF
:       sta t0
        clc
        lda c_bo0,x
        adc c_bdl,x
        sta c_bo0,x
        lda c_bo1,x
        adc c_bdh,x
        sta c_bo1,x
        lda c_bo2,x
        adc t0
        sta c_bo2,x
@nop:   lda c_ldly,x
        beq @lfo
        lda c_kdcnt,x
        bne @r
        lda c_ldcnt,x
        beq @lfo
        jmp lfo_delay
@lfo:   lda c_f16,x
        and #$20
        beq @v
        jsr plfo_step
        ldx chn
@v:     lda c_f16,x
        and #$40
        beq @r
        jmp vlfo_step
@r:     rts

; L001094: LFO delay countdown
lfo_delay:
        dec c_ldcnt,x
        bne @r
        lda c_f16,x
        and #$20
        beq @v
        jsr plfo_reset
@v:     lda c_f16,x
        and #$40
        beq @r
        jmp vlfo_reset
@r:     rts

; L001562: pitch LFO restart
plfo_reset:
        lda c_plcl,x
        sta c_pcl,x
        lda c_plch,x
        sta c_pch,x
        lda c_pds0,x
        sta c_pd0,x
        lda c_pds1,x
        sta c_pd1,x
        lda c_pds2,x
        sta c_pd2,x
        lda c_pds3,x
        sta c_pd3,x
        lda c_pos0,x
        sta c_po0,x
        lda c_pos1,x
        sta c_po1,x
        lda c_pos2,x
        sta c_po2,x
        lda c_pos3,x
        sta c_po3,x
        rts

; L0015d0: volume LFO restart
vlfo_reset:
        lda c_vll,x
        sta c_vcl,x
        lda c_vlh,x
        sta c_vch,x
        lda c_vdsl,x
        sta c_vdl,x
        lda c_vdsh,x
        sta c_vdh,x
        lda c_vosl,x
        sta c_vofl,x
        lda c_vosh,x
        sta c_vofh,x
        rts

; dec 16-bit counter, Z = 1 when it reached zero
.macro DEC16 lo, hi
        lda lo,x
        bne :+
        dec hi,x
:       dec lo,x
        lda lo,x
        ora hi,x
.endmacro

; L0010b4: pitch LFO step
plfo_step:
        lda c_plt,x
        cmp #1
        beq @saw
        cmp #2
        beq @sq
        cmp #3
        beq @tri
        cmp #4
        bne @r
        jmp @rnd
@saw:   jsr po_add_pd                   ; L0010be
        DEC16 c_pcl, c_pch
        bne @r
        jsr pcnt_reload
        ; po = -po
        sec
        lda #0
        sbc c_po0,x
        sta c_po0,x
        lda #0
        sbc c_po1,x
        sta c_po1,x
        lda #0
        sbc c_po2,x
        sta c_po2,x
        lda #0
        sbc c_po3,x
        sta c_po3,x
@r:     rts
@sq:    lda c_pd0,x                     ; L0010d4: po = pd
        sta c_po0,x
        lda c_pd1,x
        sta c_po1,x
        lda c_pd2,x
        sta c_po2,x
        lda c_pd3,x
        sta c_po3,x
        bra @flip
@tri:   jsr po_add_pd                   ; L0010ea
@flip:  DEC16 c_pcl, c_pch
        bne @r
        jsr pcnt_reload
        sec                             ; pd = -pd
        lda #0
        sbc c_pd0,x
        sta c_pd0,x
        lda #0
        sbc c_pd1,x
        sta c_pd1,x
        lda #0
        sbc c_pd2,x
        sta c_pd2,x
        lda #0
        sbc c_pd3,x
        sta c_pd3,x
        rts
@rnd:   DEC16 c_pcl, c_pch              ; L001100
        bne @r
        jsr rand                        ; m0:m1 = random (int16)
        ldx chn
        lda c_pd0,x
        sta m2
        lda c_pd1,x
        sta m3
        jsr smul16                      ; r0..r3 = m0:m1 * m2:m3 (signed)
        ldx chn
        lda r0
        sta c_po0,x
        lda r1
        sta c_po1,x
        lda r2
        sta c_po2,x
        lda r3
        sta c_po3,x
        jmp pcnt_reload

po_add_pd:
        clc
        lda c_po0,x
        adc c_pd0,x
        sta c_po0,x
        lda c_po1,x
        adc c_pd1,x
        sta c_po1,x
        lda c_po2,x
        adc c_pd2,x
        sta c_po2,x
        lda c_po3,x
        adc c_pd3,x
        sta c_po3,x
        rts

pcnt_reload:
        lda c_pll,x
        sta c_pcl,x
        lda c_plh,x
        sta c_pch,x
        rts

; L001116: volume LFO step
vlfo_step:
        lda c_vlt,x
        cmp #1
        beq @saw
        cmp #2
        beq @sq
        cmp #3
        beq @tri
        cmp #4
        beq @rnd
        rts
@saw:   jsr vo_add_vd                   ; L001120
        DEC16 c_vcl, c_vch
        bne @r
        jsr vcnt_reload
        lda c_vosl,x
        sta c_vofl,x
        lda c_vosh,x
        sta c_vofh,x
@r:     rts
@sq:    DEC16 c_vcl, c_vch              ; L001138
        bne @r
        jsr vcnt_reload
        jsr vo_add_vd
        bra @neg
@tri:   jsr vo_add_vd                   ; L00114e
        DEC16 c_vcl, c_vch
        bne @r
        jsr vcnt_reload
@neg:   sec
        lda #0
        sbc c_vdl,x
        sta c_vdl,x
        lda #0
        sbc c_vdh,x
        sta c_vdh,x
        rts
@rnd:   DEC16 c_vcl, c_vch              ; L001164
        bne @r
        jsr rand
        ldx chn
        lda c_vdl,x
        sta m2
        lda c_vdh,x
        sta m3
        jsr smul16
        ldx chn
        jsr vcnt_reload
        lda r0
        sta c_vofl,x
        lda r1
        sta c_vofh,x
        rts

vo_add_vd:
        clc
        lda c_vofl,x
        adc c_vdl,x
        sta c_vofl,x
        lda c_vofh,x
        adc c_vdh,x
        sta c_vofh,x
        rts

vcnt_reload:
        lda c_vll,x
        sta c_vcl,x
        lda c_vlh,x
        sta c_vch,x
        rts

; L00117a: seed = seed * $C549 + 12 (16-bit); returns m0:m1 = bits 8..23 of that sum
rand:
        lda mx_seed
        sta m0
        lda mx_seed+1
        sta m1
        lda #$49
        sta m2
        lda #$C5
        sta m3
        jsr umul16
        clc
        lda r0
        adc #12
        sta mx_seed
        sta r0
        lda r1
        adc #0
        sta mx_seed+1
        sta m0
        lda r2
        adc #0
        sta m1
        rts

; umul16: r0..r3 = m0:m1 * m2:m3 (unsigned). m0..m3 preserved, Y clobbered.
umul16:
        stz r2
        stz r3
        lda m0
        sta r0
        lda m1
        sta r1
        ldy #16
        lsr r1                          ; first multiplier bit -> C
        ror r0
@l:     bcc :+
        clc
        lda r2
        adc m2
        sta r2
        lda r3
        adc m3
        sta r3
:       ror r3                          ; product >> 1, next multiplier bit -> C
        ror r2
        ror r1
        ror r0
        dey
        bne @l
        rts

; smul16: r0..r3 = m0:m1 * m2:m3 (signed 16 x 16 -> 32)
smul16:
        jsr umul16
        lda m1
        bpl :+
        sec
        lda r2
        sbc m2
        sta r2
        lda r3
        sbc m3
        sta r3
:       lda m3
        bpl :+
        sec
        lda r2
        sbc m0
        sta r2
        lda r3
        sbc m1
        sta r3
:       rts

; ===========================================================================
; L0011b4: sequence step for one tick (X = channel)
seq_tick:
        lda c_f17,x
        and #$08
        beq @nowait
        lda g_sync,x                    ; L001192: sync wait
        bne :+
        rts
:       stz g_sync,x
        lda c_f17,x
        and #$F7
        sta c_f17,x
        jmp fetch
@nowait:
        lda c_f16,x
        and #$04
        bne @len
        dec c_gate,x
        bne @len
        jsr keyoff_gate                 ; L000fe6
        ldx chn
@len:   dec c_len,x
        beq fetch
        rts

; L0011d4: read items until a note or rest
fetch:
        lda c_ptl,x
        sta seqp
        lda c_pth,x
        sta seqp+1
        lda c_f16,x
        and #$7B
        sta c_f16,x
        stz dispose
@l:     jsr item
        bcs @r
        lda dispose
        bne @r
        ldx chn
        bra @l
@r:     rts

; item: process one sequence item for channel chn. C = 1 after a note/rest.
item:
        jsr seq_get
        cmp #$80
        bcs :+
        sta t0                          ; rest: gate = len = n + 1
        sta t1
        jmp set_len
:       cmp #$E0
        bcc @note
        eor #$FF                        ; command $FF..$E0 -> 0..31
        cmp #25
        bcc :+
        ldx chn                         ; $E6..$E0: L001442 (channel end)
        jsr cmd_end
        clc
        rts
:       asl a
        tay
        jsr @disp
        clc
        rts
@disp:  lda cmdtab+1,y
        pha
        lda cmdtab,y
        pha
        ldx chn
        rts
@note:  and #$7F                        ; pitch = n << 6 + 5 + detune
        ldx chn
        stz t1
        asl a
        rol t1
        asl a
        rol t1
        asl a
        rol t1
        asl a
        rol t1
        asl a
        rol t1
        asl a
        rol t1
        clc
        adc #5
        bcc :+
        inc t1
:       clc
        adc c_detl,x
        sta c_ntl,x
        lda t1
        adc c_deth,x
        sta c_nth,x
        lda c_f16,x
        ora #$01
        sta c_f16,x
        lda c_kdly,x
        sta c_kdcnt,x
        jsr seq_get                     ; length
        sta t0
        ldx chn
        lda c_q,x
        bmi @qneg
        sta m0                          ; gate = ((q * len) & $FFFF) >> 3
        stz m1
        lda t0
        sta m2
        stz m3
        jsr umul16
        lda r1
        lsr a
        ror r0
        lsr a
        ror r0
        lsr a
        ror r0
        lda r0
        sta t1
        bra set_len
@qneg:  clc                             ; L001226: gate = q + len if it carries, else 0
        adc t0
        bcs :+
        lda #0
:       sta t1
; t1 = gate - 1, t0 = len - 1
set_len:
        ldx chn
        lda t1
        inc a
        sta c_gate,x
        lda t0
        inc a
        sta c_len,x
        lda seqp
        sta c_ptl,x
        lda seqp+1
        sta c_pth,x
        sec
        rts

; seq_get: A = byte at seqp, seqp++, N/Z from A (X, Y preserved)
seq_get:
        lda seqp+1
        cmp #>STUB
        beq @stub
        lda seqp
        sta ma
        lda seqp+1
        sta ma+1
        jsr mdx_rd
        inc seqp
        bne :+
        inc seqp+1
:       cmp #0                          ; N/Z reflect the byte read
        rts
@stub:  phy
        ldy seqp
        lda stubtab,y
        inc seqp
        ply
        cmp #0
        rts

; seq_get16: t1 = high byte, t0 = low byte (big-endian word)
seq_get16:
        jsr seq_get
        sta t1
        jsr seq_get
        sta t0
        rts

; seqp += t0:t1
sp_add:
        clc
        lda seqp
        adc t0
        sta seqp
        lda seqp+1
        adc t1
        sta seqp+1
        rts

cmdtab:
        .word cmd_tempo-1, cmd_y-1, cmd_voice-1, cmd_pan-1         ; $FF $FE $FD $FC
        .word cmd_vol-1, cmd_voldn-1, cmd_volup-1, cmd_q-1          ; $FB $FA $F9 $F8
        .word cmd_legato-1, cmd_rep_start-1, cmd_rep_end-1, cmd_rep_esc-1 ; $F7 $F6 $F5 $F4
        .word cmd_detune-1, cmd_porta-1, cmd_loop-1, cmd_kdelay-1   ; $F3 $F2 $F1 $F0
        .word cmd_sync_send-1, cmd_sync_wait-1, cmd_noise-1, cmd_plfo-1 ; $EF $EE $ED $EC
        .word cmd_vlfo-1, cmd_opmlfo-1, cmd_ldelay-1, cmd_pcm8-1    ; $EB $EA $E9 $E8
        .word cmd_ext-1                                             ; $E7

; ---- commands (X = channel) ------------------------------------------------
cmd_tempo:                              ; $FF L001292
        jsr seq_get
        sta mx_tempo
        ldy #$12
        jmp opm_write

cmd_y:                                  ; $FE L0012a6
        jsr seq_get
        sta t2
        jsr seq_get
        ldy t2
        cpy #$12
        bne :+
        sta mx_tempo
:       jmp opm_write

cmd_voice:                              ; $FD L0012be
        jsr seq_get
        ldy c_ch,x
        bpl :+
        sta c_bank,x
        rts
:       sta t2                          ; voice number
        lda mx_voicebase
        sta ma
        lda mx_voicebase+1
        sta ma+1
@find:  lda ma+1                        ; bounds: stop at the end of the MDX body
        cmp mx_size+1
        bcc :+
        bne @nf
        lda ma
        cmp mx_size
        bcs @nf
:       jsr mdx_rd
        inc ma
        bne :+
        inc ma+1
:       cmp t2
        beq @found
        clc
        lda ma
        adc #26
        sta ma
        bcc @find
        inc ma+1
        bra @find
@found: lda t2                          ; (display only)
        sta c_vno,x
        lda ma
        sta c_vol,x
        lda ma+1
        sta c_voh,x
        lda c_f17,x
        ora #$02
        sta c_f17,x
@nf:    rts

cmd_pan:                                ; $FC L0012e6
        jsr seq_get
        ldy c_ch,x
        bmi @pcm
        and #$03
        lsr a                           ; (n & 3) << 6
        ror a
        ror a
        sta t2
        lda c_pan,x
        and #$3F
        ora t2
        sta c_pan,x
        lda c_f17,x
        ora #$04
        sta c_f17,x
        rts
@pcm:   cmp #0
        beq :+
        cmp #3
        bne :++
:       eor #$03
:       sta t2
        lda c_pan,x
        and #$FC
        ora t2
        sta c_pan,x
        rts

cmd_vol:                                ; $FB L00131c
        jsr seq_get
        sta c_v,x
        bra vol_flag

cmd_voldn:                              ; $FA L001328
        lda c_v,x
        bmi :+
        beq @r
        dec c_v,x
        bra vol_flag
:       cmp #$FF
        beq @r
        inc c_v,x
        bra vol_flag
@r:     rts

cmd_volup:                              ; $F9 L001344
        lda c_v,x
        bmi :+
        cmp #$0F
        beq @r
        inc c_v,x
        bra vol_flag
:       cmp #$80
        beq @r
        dec c_v,x
        bra vol_flag
@r:     rts
vol_flag:
        lda c_f17,x
        ora #$01
        sta c_f17,x
        rts

cmd_q:                                  ; $F8 L001364
        jsr seq_get
        sta c_q,x
        rts

cmd_legato:                             ; $F7 L00136a
        lda c_f16,x
        ora #$04
        sta c_f16,x
        rts

cmd_rep_start:                          ; $F6 L001372: copy the count into the counter byte
        jsr seq_get
        pha
        lda seqp
        sta ma
        lda seqp+1
        sta ma+1
        pla
        jsr mdx_wr
        inc seqp
        bne :+
        inc seqp+1
:       rts

cmd_rep_end:                            ; $F5 L001376
        jsr seq_get16                   ; t0:t1 = offset (backwards)
        clc                             ; counter at seqp + offset - 1
        lda seqp
        adc t0
        sta ma
        lda seqp+1
        adc t1
        sta ma+1
        lda ma
        bne :+
        dec ma+1
:       dec ma
        jsr mdx_rd
        dec a
        jsr mdx_wr
        cmp #0
        beq :+
        jmp sp_add
:       rts

cmd_rep_esc:                            ; $F4 L00139a
        jsr seq_get16
        clc                             ; A0 = seqp + offset
        lda seqp
        adc t0
        sta t2
        lda seqp+1
        adc t1
        sta t3
        lda t2                          ; w2 = word at A0
        sta ma
        lda t3
        sta ma+1
        jsr mdx_rd
        sta t5
        inc ma
        bne :+
        inc ma+1
:       jsr mdx_rd
        sta t4
        clc                             ; A0 += 2
        lda t2
        adc #2
        sta t2
        bcc :+
        inc t3
:       clc                             ; counter at A0 + w2 - 1
        lda t2
        adc t4
        sta ma
        lda t3
        adc t5
        sta ma+1
        lda ma
        bne :+
        dec ma+1
:       dec ma
        jsr mdx_rd
        cmp #1
        bne :+
        lda t2
        sta seqp
        lda t3
        sta seqp+1
:       rts

cmd_detune:                             ; $F3 L0013ba
        jsr seq_get16
        lda t0
        sta c_detl,x
        lda t1
        sta c_deth,x
        rts

cmd_porta:                              ; $F2 L0013c6
        jsr seq_get16
        lda t0
        sta c_bdl,x
        lda t1
        sta c_bdh,x
        lda c_f16,x
        ora #$80
        sta c_f16,x
        rts

cmd_loop:                               ; $F1 L0013dc
        jsr seq_get
        cmp #0
        bne :+
        jmp cmd_end
:       sta t1
        jsr seq_get
        sta t0
        jsr sp_add
        ; L0013e6: loop accounting
        lda bitlo,x
        eor #$FF
        and mx_loopmk
        sta mx_loopmk
        lda bithi,x
        eor #$FF
        and mx_loopmk+1
        sta mx_loopmk+1
        lda mx_loopmk
        and mx_active
        sta t2
        lda mx_loopmk+1
        and mx_active+1
        ora t2
        bne @r
        lda mx_fadeloop
        bne @fl
        jsr reset_loopmk
        inc mx_loops
        bne @r
        inc mx_loops+1
@r:     rts
@fl:    lda mx_fadeen
        bne @r
        jsr reset_loopmk
        lda mx_loopleft
        bne :+
        dec mx_loopleft+1
:       dec mx_loopleft
        lda mx_loopleft
        ora mx_loopleft+1
        bne @r
        lda #$11
        sta mx_fadespd
        stz mx_fadespd+1
        lda #$FF
        sta mx_fadeen
        rts

reset_loopmk:
        lda #$FF
        sta mx_loopmk
        lda #$01
        sta mx_loopmk+1
        lda mx_pcm8
        beq :+
        lda #$FF
        sta mx_loopmk+1
:       rts

; L001442: channel end
cmd_end:
        lda #<STUB
        sta seqp
        lda #>STUB
        sta seqp+1
        lda bitlo,x
        eor #$FF
        and mx_loopmk
        sta mx_loopmk
        lda bithi,x
        eor #$FF
        and mx_loopmk+1
        sta mx_loopmk+1
        lda bitlo,x
        eor #$FF
        and mx_active
        sta mx_active
        lda bithi,x
        eor #$FF
        and mx_active+1
        sta mx_active+1
        ora mx_active
        bne @r
        lda #1
        sta mx_end
        stz mx_pcm8
        lda mx_fadeloop
        bne :+
        lda #$FF
        sta mx_loops
        sta mx_loops+1
        rts
:       lda #$FF
        sta mx_fadespd
        sta mx_fadespd+1
        sta mx_fadeen
        stz mx_fade
        lda #$37
        sta mx_fade15
@r:     rts

cmd_kdelay:                             ; $F0 L001492
        jsr seq_get
        sta c_kdly,x
        rts

cmd_sync_send:                          ; $EF L001498
        jsr seq_get
        and #$0F
        tay
        lda #$FF
        sta g_sync,y
        rts

cmd_sync_wait:                          ; $EE L0014b0
        lda g_sync,x
        beq :+
        stz g_sync,x
        lda c_f17,x
        and #$F7
        sta c_f17,x
        rts
:       lda c_f17,x
        ora #$08
        sta c_f17,x
        lda seqp
        sta c_ptl,x
        lda seqp+1
        sta c_pth,x
        lda #1
        sta dispose
        rts

cmd_noise:                              ; $ED L0014dc
        jsr seq_get
        ldy c_ch,x
        bmi @pcm
        sta mx_noise
        ldy #$0F
        jmp opm_write
@pcm:   asl a
        asl a
        sta t2
        lda c_pan,x
        and #$03
        ora t2
        sta c_pan,x
        rts

cmd_plfo:                               ; $EC L0014fc
        lda c_f16,x
        ora #$20
        sta c_f16,x
        jsr seq_get
        sta t6                          ; raw type byte
        bpl :+
        and #$01                        ; L001576
        beq @off
        jmp plfo_reset
@off:   lda c_f16,x
        and #$DF
        sta c_f16,x
        stz c_po0,x
        stz c_po1,x
        stz c_po2,x
        stz c_po3,x
        rts
:       and #$03
        sta t7                          ; type 0..3
        inc a
        sta c_plt,x
        jsr seq_get16                   ; length
        lda t0
        sta c_pll,x
        lda t1
        sta c_plh,x
        lda t7
        cmp #1                          ; square: cooked = length
        beq @ck
        lsr t1                          ; others: length / 2, random: 1
        ror t0
        lda t7
        cmp #3
        bne @ck
        lda #1
        sta t0
        stz t1
@ck:    lda t0
        sta c_plcl,x
        lda t1
        sta c_plch,x
        jsr seq_get16                   ; amplitude -> value = sext(amp) << 8 [<< 8]
        stz t3
        lda t1
        bpl :+
        dec t3
:       lda t1                          ; bytes: 0, amp_lo, amp_hi, sign
        sta t2
        lda t0
        sta t1
        stz t0
        lda t6
        cmp #4
        bcc @set
        lda t2                          ; << 8 more: 0, 0, amp_lo, amp_hi
        sta t3
        lda t1
        sta t2
        lda t0
        sta t1
        lda t6
        and #$03
        sta t7
@set:   lda t0
        sta c_pds0,x
        lda t1
        sta c_pds1,x
        lda t2
        sta c_pds2,x
        lda t3
        sta c_pds3,x
        lda t7
        cmp #2                          ; triangle starts at +amplitude, others at 0
        beq :+
        stz t0
        stz t1
        stz t2
        stz t3
:       lda t0
        sta c_pos0,x
        lda t1
        sta c_pos1,x
        lda t2
        sta c_pos2,x
        lda t3
        sta c_pos3,x
        jmp plfo_reset

cmd_vlfo:                               ; $EB L001590
        lda c_f16,x
        ora #$40
        sta c_f16,x
        jsr seq_get
        sta t6
        bpl :+
        and #$01                        ; L0015e4
        beq @off
        jmp vlfo_reset
@off:   lda c_f16,x
        and #$BF
        sta c_f16,x
        stz c_vofl,x
        stz c_vofh,x
        rts
:       and #$03
        inc a
        sta c_vlt,x
        jsr seq_get16                   ; length
        lda t0
        sta c_vll,x
        sta m2
        lda t1
        sta c_vlh,x
        sta m3
        jsr seq_get16                   ; amplitude
        lda t0
        sta c_vdsl,x
        sta m0
        lda t1
        sta c_vdsh,x
        sta m1
        lda t6                          ; (type*2) & 2 in the original = type bit 0:
        and #$01                        ; square / random use the amplitude as is
        bne @noml
        jsr smul16                      ; low word of amp * length
        ldx chn
        lda r0
        sta m0
        lda r1
        sta m1
@noml:  sec                             ; offset start = -d, or 0 if that is negative
        lda #0
        sbc m0
        sta t0
        lda #0
        sbc m1
        bpl :+
        lda #0
        sta t0
:       sta c_vosh,x
        lda t0
        sta c_vosl,x
        jmp vlfo_reset

cmd_opmlfo:                             ; $EA L0015fe
        jsr seq_get
        bmi @ctl
        sta t2
        lda c_f16,x
        and #$FD
        sta c_f16,x
        lda t2
        and #$40
        beq :+
        lda c_f16,x
        ora #$02
        sta c_f16,x
        lda t2
        and #$BF
        sta t2
:       lda mx_last1b
        and #$C0
        ora t2
        ldy #$1B
        jsr opm_write
        jsr seq_get
        ldy #$18
        jsr opm_write
        jsr seq_get
        ldy #$19
        jsr opm_write
        jsr seq_get
        ldy #$19
        jsr opm_write
        jsr seq_get
        sta c_pmsams,x
        bra @pms
@ctl:   and #$01
        beq @pms
        lda c_pmsams,x
@pms:   pha
        lda c_ch,x
        clc
        adc #$38
        tay
        pla
        jmp opm_write

cmd_ldelay:                             ; $E9 L001656
        jsr seq_get
        sta c_ldly,x
        rts

cmd_pcm8:                               ; $E8 L00165c (PCM8 is always available)
        lda #$FF
        sta mx_pcm8
        sta mx_loopmk+1
        sta mx_active+1
        rts

cmd_ext:                                ; $E7 L001694
        jsr seq_get
        cmp #7
        bcc :+
        jmp cmd_end
:       asl a
        tay
        lda exttab+1,y
        pha
        lda exttab,y
        pha
        rts
exttab: .word cmd_end-1, ext_fade-1, ext_pcm8cmd-1, ext_koff-1
        .word ext_single-1, ext_tie-1, ext_f17-1

ext_fade:                               ; $E7 $01 L0016b8
        jsr seq_get
        sta mx_fadespd
        stz mx_fadespd+1
        lda #$FF
        sta mx_fadeen
        rts

ext_pcm8cmd:                            ; $E7 $02 L0016c6 (direct PCM8 call: skipped)
        clc
        lda seqp
        adc #6
        sta seqp
        bcc :+
        inc seqp+1
:       rts

ext_koff:                               ; $E7 $03 L0016fa
        jsr seq_get
        cmp #0
        beq :+
        lda c_f16,x
        ora #$10
        sta c_f16,x
        rts
:       lda c_f16,x
        and #$EF
        sta c_f16,x
        rts

ext_f17:                                ; $E7 $06 L0017a0
        jsr seq_get
        cmp #0
        beq :+
        lda c_f17,x
        ora #$80
        sta c_f17,x
        rts
:       lda c_f17,x
        and #$7F
        sta c_f17,x
        rts

ext_single:                             ; $E7 $04 L00170e: one item for another channel
        jsr seq_get
        and #$0F
        tay
        lda chn
        pha
        sty chn
        lda c_ptl,y                     ; keep that channel's own pointer
        pha
        lda c_pth,y
        pha
        tya
        tax
        lda c_f16,x
        and #$7B
        sta c_f16,x
        jsr item
        ldx chn
        pla
        sta c_pth,x
        pla
        sta c_ptl,x
        pla
        sta chn
        tax
        rts

ext_tie:                                ; $E7 $05 L00178a: wait n+1 with key on now
        jsr seq_get
        sta t0
        sta t1
        jsr set_len
        ldx chn
        lda c_f16,x
        and #$FE
        sta c_f16,x
        jsr keyon
        lda #1
        sta dispose
        rts

; ===========================================================================
; L000c66: per-tick output (X = channel)
out_stage:
        lda c_f16,x
        and #$01
        beq @upd
        lda c_kdcnt,x
        beq @kon
        dec c_kdcnt,x
@upd:   lda c_ch,x                      ; L000cce
        bmi @r
        jmp pitch_out                   ; (+ vol_out)
@kon:   lda c_ch,x
        bmi @keyon
        jsr voice_load
        ldx chn
        jsr pan_out
        ldx chn
        lda c_f16,x
        and #$08
        bne @nors
        lda c_ldly,x
        sta c_ldcnt,x
        beq @sync
        stz c_po0,x
        stz c_po1,x
        stz c_po2,x
        stz c_po3,x
        stz c_vofl,x
        stz c_vofh,x
        jsr lfo_delay
        ldx chn
@sync:  lda c_f16,x
        and #$02
        beq @nors
        lda #$02
        ldy #$01
        jsr opm_write
        lda #$00
        jsr opm_write
@nors:  stz c_bo0,x                     ; L000cb4
        stz c_bo1,x
        stz c_bo2,x
        jsr pitch_out                   ; (+ vol_out)
        ldx chn
@keyon: jsr keyon                       ; L000cbe
        ldx chn
        lda c_f16,x
        and #$FE
        sta c_f16,x
@r:     rts

; L000e28: A = attenuation; write TL of the carrier operators. Only the carriers' TL bytes
; are read (MXDRV read all four), and the writes go straight to out_ym (opm_write passes
; $60-$7F on unchanged). X kept.
vol_write:
        sta c_vlast,x
        sta t2
        lda c_car,x                     ; carrier mask, bit 0 = op 1
        beq @r
        sta t3
        lda c_ch,x
        clc
        adc #$60
        sta t4                          ; register of op 1
        lda c_vol,x                     ; TL bytes at voice + 6 (none: TL 0)
        ora c_voh,x
        sta t5
        clc
        lda c_vol,x
        adc #6
        sta ma
        lda c_voh,x
        adc #0
        sta ma+1
@op:    lsr t3
        bcc @next
        lda #0
        ldy t5
        beq :+
        jsr mdx_rd
:       clc
        adc t2
        bpl :+
        lda #$7F
:       ldy t4
        jsr out_ym
@next:  lda t3                          ; no more carriers
        beq @r
        inc ma
        bne :+
        inc ma+1
:       lda t4
        clc
        adc #8
        sta t4
        bra @op
@r:     rts

; L000dfe: volume -> carrier TL (if changed). X = channel (kept)
vol_out:
        lda c_v,x
        bmi @raw
        tay
        lda voltab,y
        bra :+
@raw:   and #$7F
:       clc
        adc mx_fade
        bcs @mute
        bpl :+
@mute:  lda #$7F
:       clc
        adc c_vofh,x
        bcs @mute2
        bpl :+
@mute2: lda #$7F
:       cmp c_vlast,x
        bne vol_write
        rts

; L000cdc: pitch = $12 + porta.hi + lfo.hi; write KF/KC if changed. Then vol_out (MXDRV
; always runs L000dfe right after it). X = channel.
pitch_out:
        clc
        lda c_ntl,x
        adc c_bo1,x
        tay
        lda c_nth,x
        adc c_bo2,x
        sta t1
        tya
        clc
        adc c_po2,x
        sta t0
        lda t1
        adc c_po3,x
        sta t1
        cmp c_lph,x
        bne :+
        lda t0
        cmp c_lpl,x
        beq vol_out                     ; unchanged
:       lda t0
        sta c_lpl,x
        lda t1
        sta c_lph,x
        cmp #$18                        ; > $17FF ?
        bcc @ok
        lda t1
        bpl @max
        stz t0                          ; negative -> 0
        stz t1
        bra @ok
@max:   lda #$FF
        sta t0
        lda #$17
        sta t1
; Straight to out_ym (MXDRV wrote KF/KC through opm_write, and kc_write recovered the pitch
; from KC + KF to add the clock correction: since kcidx[keycode[i]] = i, that equals the
; clamped pitch + mx_pofs, clamped to $17FF). Same writes: KF, then KC.
@ok:    ldy c_ch,x                      ; OPM channel 0..7
        lda t0                          ; MXDRV's KF = pitch << 2 (low byte), for kc_write
        asl a                           ; (a later $FE write of KC alone)
        asl a
        sta kf_raw,y
        jsr po_emit
        ldx chn
        jmp vol_out

; po_emit: t1:t0 = pitch (0..$17FF), Y = OPM channel: add the clock correction, clamp,
; write KF and KC (pitch_out, kc_write). X not kept.
po_emit:
        clc                             ; clock correction: 123 (3.579545 MHz OPM) or 0 (4 MHz)
        lda t0
        adc mx_pofs
        sta t0
        bcc :+
        inc t1
:       lda t1
        cmp #$18                        ; > $17FF ?
        bcc :+
        lda #$FF
        sta t0
        lda #$17
        sta t1
:       lda t0                          ; KF = (pitch & 63) << 2
        asl a
        rol t1
        asl a
        rol t1
        pha
        tya
        ora #$30
        tay
        pla
        jsr out_ym                      ; (A, X, Y kept)
        tya
        eor #$18                        ; $30 + ch -> $28 + ch
        tay
        ldx t1                          ; KC = keycode[pitch >> 6]
        lda keycode,x
        jmp out_ym

; L000d84: load the voice (if pending)
voice_load:
        lda c_f17,x
        and #$02
        bne :+
        rts
:       lda c_f17,x
        and #$FD
        sta c_f17,x
        lda c_vol,x
        sta ma
        lda c_voh,x
        sta ma+1
        jsr vrd                         ; FL/CON
        sta t2
        lda c_pan,x
        and #$C0
        ora t2
        sta c_pan,x
        lda t2
        and #$07
        tay
        lda carrier,y
        sta c_car,x
        sta t3
        jsr vrd                         ; slot mask
        asl a
        asl a
        asl a
        ora c_ch,x
        sta c_kon,x
        lda c_ch,x
        clc
        adc #$40
        sta t4
        lda #4                          ; DT1/MUL
        sta t5
:       jsr vrd
        ldy t4
        jsr opm_write
        jsr reg_next
        dec t5
        bne :-
        lda #4                          ; TL (carriers muted)
        sta t5
:       jsr vrd
        lsr t3
        bcc :+
        lda #$7F
:       ldy t4
        jsr opm_write
        jsr reg_next
        dec t5
        bne :--
        lda #16                         ; KS/AR .. D1L/RR
        sta t5
:       jsr vrd
        ldy t4
        jsr opm_write
        jsr reg_next
        dec t5
        bne :-
        lda #$FF
        sta c_vlast,x
        lda c_f17,x
        ora #$64
        sta c_f17,x
        rts
vrd:    jsr mdx_rd
        inc ma
        bne :+
        inc ma+1
:       rts
reg_next:
        lda t4
        clc
        adc #8
        sta t4
        rts

; L000e66: pan / FB / CON (if pending)
pan_out:
        lda c_f17,x
        and #$04
        beq @r
        lda c_f17,x
        and #$FB
        sta c_f17,x
        lda c_ch,x
        clc
        adc #$20
        tay
        lda c_pan,x
        jmp opm_write
@r:     rts

; ===========================================================================
; L000e7e: key on
keyon:
        lda c_f16,x
        and #$08
        beq :+
        rts
:       inc c_kcnt,x                    ; (display only)
        lda c_f16,x
        ora #$08
        sta c_f16,x
        and #$10
        beq :+
        jsr keyoff_now
        ldx chn
:       lda c_ch,x
        bmi keyon_pcm
        lda c_kon,x
        ldy #$08
        jmp opm_write

; L000eb2: PCM key on
keyon_pcm:
        lda mx_pdx
        bne :+
        rts
:       lda c_nth,x                     ; t4:t5 = note index = $12 >> 6
        sta t5
        lda c_ntl,x
        ldy #6
:       lsr t5
        ror a
        dey
        bne :-
        sta t4
        lda c_pan,x                     ; mode = (rate << 8) | pan'
        and #$03
        beq :+
        cmp #3
        bne :++
:       eor #$03
:       sta t6                          ; pan'
        lda c_pan,x
        and #$1C
        lsr a
        lsr a
        sta t7                          ; rate
        lda mx_pcm8
        bne @pcm8
        lda mx_fade15                   ; MSM6258 path
        beq :+
        lda t6
        and #$FC
        sta t6
:       jsr pdx_get                     ; uses the low word of the length
        ldx chn
        lda t0
        ora t1
        bne :+
        rts
:       lda t1                          ; cap at $FF00
        cmp #$FF
        bne :+
        lda t0
        beq :+
        stz t0
:       lda #0                          ; ADPCMMOD_END
        sta pe_ch
        lda #PCM_M
        jsr out_pcm
        lda t4
        sta pe_smp
        lda t5
        sta pe_smp+1
        lda t6
        sta pe_mode
        lda t7
        sta pe_mode+1
        stz pe_mode+2
        lda t0
        sta pe_len
        lda t1
        sta pe_len+1
        stz pe_len+2
        lda #PCM_A
        jmp out_pcm
@pcm8:  lda c_bank,x                    ; index = note + bank * 96
        sta m0
        stz m1
        lda #96
        sta m2
        stz m3
        jsr umul16
        ldx chn
        clc
        lda t4
        adc r0
        sta t4
        lda t5
        adc r1
        sta t5
        jsr pdx_get
        ldx chn
        lda t0
        ora t1
        ora t2
        ora t3
        bne :+
        rts
:       lda c_v,x                       ; PCM8 volume
        bmi @raw
        tay
        lda voltab,y
        bra :+
@raw:   and #$7F
:       clc
        adc mx_fade
        bmi @silent
        cmp #$2B
        bcs @silent
        tay
        lda pcmvol,y
        bra @mode
@silent:
        stz t6                          ; pan 0
        lda #0
@mode:  sta pe_mode+2
        lda t6
        sta pe_mode
        lda t7
        sta pe_mode+1
        lda c_ch,x
        and #$07
        sta pe_ch
        lda #PCM_S                      ; first call: length 0
        jsr out_pcm
        lda t4
        sta pe_smp
        lda t5
        sta pe_smp+1
        lda t0
        sta pe_len
        lda t1
        sta pe_len+1
        lda t2
        sta pe_len+2
        lda #PCM_P
        jmp out_pcm

; L000fe6: key off at the end of the gate time
keyoff_gate:
        lda c_f16,x
        and #$08
        bne :+
        rts
:       lda c_f16,x
        and #$F7
        sta c_f16,x
        and #$10
        beq keyoff_now
        rts

; L000ff6: key off now
keyoff_now:
        lda c_ch,x
        bmi @pcm
        ldy #$08
        jmp opm_write
@pcm:   lda mx_pdx
        beq @r
        lda mx_pcm8
        beq @adpcm
        lda c_ch,x
        and #$07
        sta pe_ch
        lda #PCM_S
        jmp out_pcm
@adpcm: lda c_f17,x
        bne :+
        lda #1                          ; ADPCMMOD_STOP
        sta pe_ch
        lda #PCM_M
        jsr out_pcm
:       stz pe_ch                       ; ADPCMMOD_END
        lda #PCM_M
        jmp out_pcm
@r:     rts
