; mxmute.s - X16MXDRV bank +3: channel mute (setopt 9 / 10) and the YM
; reset of api_init (moved here from bank +0 for room)
;
; Mute: the song runs on as if heard (sequence, LFO, out_stage, the shadow); only what goes
; out to the chip is held back (bank +0 out_ym: key writes and the channel's registers of a
; muted FM channel; out_pcm: start events of a muted PCM channel). The host sets the wanted
; masks (m_fmreq / m_pcmreq, low RAM); the worker applies them before each tick (x_mute):
;   FM muted:   key off ($08 <- ch), forced (it passes the mask, k_sh keeps the key state)
;   FM unmuted: the channel's 28 registers ($20 + ch .. $F8 + ch) from the shadow, then the
;               key state k_sh[ch] if a slot is on (the held note sounds again), forced
;   PCM muted:  PCM8 voice n stopped (PCM_S); P also stops the MSM6258 voice (PCM_M stop)
;   PCM unmuted: nothing (the next note sounds)
; Forced writes take the normal out_ym path past the mask and the equal-value skip: in queue
; mode they are queued at this tick's time, after the writes already queued. After the end
; of the sequence the worker queues no tick marks; a forced FM write then queues one first.

.setcpu "65C02"
.include "x16.inc"
.include "mx16.inc"
.include "mxcore.inc"

.importzp rp
.import lo_rd, lo_wr, lo_bank, lo_call1, lo_ymf, lo_pcmf
.import drvbank, fmq, sh_pmd, m_fmreq, m_pcmreq, m_fm, m_pcm, m_force, k_sh, bit8
.import shadow, sh_amd, mx_end

.segment "XJMP"                         ; (after mxpack.s: X_MUTE = 2, X_YMRST = 4)
        .word x_mute
        .word x_ymrst

.segment "XBSS"
xm_fd:  .res 1                          ; FM channels whose mask changes
xm_pd:  .res 1                          ; PCM channels whose mask changes
xm_ch:  .res 1
xm_r:   .res 1

.segment "XCODE"
; x_mute (X_MUTE, the worker before each tick, also after the end of the sequence)
x_mute:
        lda m_fmreq
        eor m_fm
        sta xm_fd
        lda m_pcmreq
        eor m_pcm
        sta xm_pd
        ora xm_fd
        bne :+
        rts
:       lda xm_fd
        bne :+
        jmp @pcm
:       bit fmq                         ; queue mode after the end: a tick mark first
        bpl @fm
        lda #<mx_end
        ldy #>mx_end
        jsr x_rd0
        beq @fm
        ldx #P_FMMARK
        jsr lo_call1
@fm:    stz xm_ch
@fl:    ldx xm_ch
        lda bit8,x
        and xm_fd
        beq @fn
        and m_fmreq
        bne @off
        lda bit8,x                      ; unmuted: the registers from the shadow
        eor #$FF
        and m_fm
        sta m_fm
        txa
        clc
        adc #$20
        sta xm_r
@rl:    lda #<shadow
        clc
        adc xm_r
        pha
        lda #>shadow
        adc #0
        tay
        pla
        jsr x_rd0                       ; A = shadow[xm_r]
        ldy xm_r
        jsr lo_ymf
        lda xm_r
        clc
        adc #8
        sta xm_r
        bcc @rl                         ; $20 + ch .. $F8 + ch: 28 registers
        ldx xm_ch
        lda k_sh,x                      ; the key state, if a slot is on
        and #$78
        beq @fn
        lda k_sh,x
        ldy #$08
        jsr lo_ymf
        bra @fn
@off:   lda bit8,x                      ; muted: key off
        ora m_fm
        sta m_fm
        txa
        ldy #$08
        jsr lo_ymf
@fn:    inc xm_ch
        lda xm_ch
        cmp #8
        bne @fl
@pcm:   lda xm_pd
        beq @r
        stz xm_ch
@pl:    ldx xm_ch
        lda bit8,x
        and xm_pd
        beq @pn
        and m_pcmreq
        bne @poff
        lda bit8,x                      ; unmuted: the next note sounds
        eor #$FF
        and m_pcm
        sta m_pcm
        bra @pn
@poff:  lda bit8,x                      ; muted: stop PCM8 voice n
        ora m_pcm
        sta m_pcm
        lda #PCM_S
        jsr lo_pcmf
        lda xm_ch
        bne @pn
        ldx #1                          ; P: the MSM6258 voice too (ADPCMMOD_STOP)
        lda #PCM_M
        jsr lo_pcmf
@pn:    inc xm_ch
        lda xm_ch
        cmp #8
        bne @pl
@r:     rts

; x_rd0: A = byte at A (lo) / Y (hi) of bank +0
x_rd0:  sta rp
        sty rp+1
        lda drvbank
        sta lo_bank
        jmp lo_rd

; x_ymrst (X_YMRST, api_init): known YM state + shadow (keys off, TL max, RR fast, everything
; else 0), no channel muted
x_ymrst:
        ldy #$08
        ldx #7
:       txa
        jsr x_ym
        dex
        bpl :-
        lda drvbank
        sta lo_bank
        ldy #$20
@r:     lda #0
        cpy #$60
        bcc @w
        cpy #$80
        bcs :+
        lda #$7F                        ; TL
        bra @w
:       cpy #$E0
        bcc @w
        lda #$0F                        ; D1L/RR
@w:     jsr x_ym
        jsr x_shwr
        iny
        bne @r
        lda #0
        ldy #$0F
        jsr x_ym
        jsr x_shwr
        ldy #$18
        jsr x_ym
        jsr x_shwr
        ldy #$1B
        jsr x_ym
        jsr x_shwr
        ldy #$19
        jsr x_ym                        ; AMD 0
        lda #<sh_amd
        sta rp
        lda #>sh_amd
        sta rp+1
        lda #0
        jsr lo_wr
        lda #$80                        ; PMD 0
        jsr x_ym
        sta sh_pmd
        stz m_fmreq
        stz m_pcmreq
        stz m_fm
        stz m_pcm
        stz m_force
        ldx #7
:       txa
        sta k_sh,x
        dex
        bpl :-
        rts

; x_shwr: shadow[Y] = A (A, X, Y kept; lo_bank = bank +0)
x_shwr: pha
        tya
        clc
        adc #<shadow
        sta rp
        lda #>shadow
        adc #0
        sta rp+1
        pla
        jmp lo_wr

; x_ym: write A to YM register Y (as bank +0's ym_raw: busy wait, gives up after ~256 polls)
x_ym:   bit YM_DATA
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
