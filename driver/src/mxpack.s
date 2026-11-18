; mxpack.s - X16MXDRV bank +3: PCM pack reader for api pcmpack (format: docs/api.md)
;
; x_pack (X_PACK, through lo_call3; main thread, the song stopped by setmdx):
;   in:  la0 = bank B holding the pack's header (samples from B+1),
;        la1-la3 = sample part bytes the host read (version 2; version 1 ignores them)
;   1. the loader scans the song (L_BEGIN): its job table j_* = the (sample, rate) pairs the
;      song can play, at most NDIR of them (j_over: the scan found more)
;   2. the pack: header and every entry reference are checked (they must stay in the pack)
;   3. the directory (bank +1 d_*) = the pack's entries the song needs (at most NDIR)
;   out: A = entries in the directory; X = the song's pairs the pack lacks (version 2: pairs
;        of PDX entries that have data), $FE = the scan went over NDIR pairs (cannot tell),
;        $FF = version 1 pack (cannot tell); C = 1 error, la4 = PK_* (mx16.inc).
;        pcm_on = 1 if the directory has entries. On an error: directory empty, pcm_on = 0.
; Memory outside bank +3 is read and written through lo_rd / lo_wr (loading time only).

.setcpu "65C02"
.include "x16.inc"
.include "mx16.inc"

.importzp rp
.import lo_rd, lo_wr, lo_bank, lo_call2, la0, la1, la2, la3, la4
.import pcmbank, ldrbank, pcm_ok, pcm_on, pm_last, cal_banks
.import d_n, d_slo, d_shi, d_rate, d_bank, d_alo, d_ahi, d_l0, d_l1, d_l2
.import j_n, j_over, j_slo, j_shi, j_rate

V2_HEAD = 36                            ; version 2: fixed header bytes before the bitmap

.segment "XJMP"                         ; bank +3 entry table (X_PACK = 0)
        .word x_pack

.segment "XBSS"
xj_n:   .res 1                          ; the song's job table (copied from bank +2)
xj_ov:  .res 1
xj_slo: .res NDIR
xj_shi: .res NDIR
xj_rt:  .res NDIR
xj_hit: .res NDIR                       ; 1 = found in the pack
xd:     .res 9 * NDIR                   ; directory being built: field f of entry k at xd + f * NDIR + k
xe:     .res 9                          ; entry being read
ver:    .res 1
nb:     .res 1                          ; sample banks
cnt:    .res 2                          ; entries left to read
mtab:   .res 2                          ; version 2: PDX table entries (bitmap bits)
ssz:    .res 3                          ; version 2: sample part bytes S
used:   .res 3                          ; linear sample bytes an entry may reach
k:      .res 1                          ; directory entries
miss:   .res 1
tmp:    .res 3
tt:     .res 3
mt:     .res 1
mlo:    .res 1

.segment "XCODE"
x_pack:
        stz k
        lda pcm_ok
        bne :+
        lda #PK_NOPCM
        jmp fail
:       ldx #L_BEGIN                    ; scan the song: the loader's job table
        jsr lo_call2
        bcc :+
        lda #PK_NOPCM
        jmp fail
:       lda ldrbank                     ; copy the job table
        sta lo_bank
        lda #<j_n
        ldx #>j_n
        jsr setrp
        jsr lo_rd
        sta xj_n
        lda #<j_over
        ldx #>j_over
        jsr setrp
        jsr lo_rd
        sta xj_ov
.macro COPYJOBS src, dst
        lda #<src
        ldx #>src
        jsr setrp
        ldx #0
:       cpx xj_n
        beq :+
        jsr rdinc
        sta dst,x
        inx
        bra :-
:
.endmacro
        COPYJOBS j_slo, xj_slo
        COPYJOBS j_shi, xj_shi
        COPYJOBS j_rate, xj_rt
        ldx #NDIR-1
:       stz xj_hit,x
        dex
        bpl :-

        lda la0                         ; the header
        sta lo_bank
        lda #<$A000
        ldx #>$A000
        jsr setrp
        ldx #0
:       jsr rdinc
        cmp magic,x
        bne notpack
        inx
        cpx #4
        bne :-
        jsr rdinc
        sta ver
        cmp #1
        beq v1
        cmp #2
        beq v2
notpack:
        lda #PK_NOTPACK
        jmp fail
bad:    lda #PK_BAD
        jmp fail

v1:     jsr rdinc                       ; 5: entries (<= NDIR)
        sta cnt
        stz cnt+1
        cmp #NDIR+1
        bcs bad
        jsr rdinc                       ; 6: sample banks
        sta nb
        beq bad
        jsr mul8064                     ; an entry may reach nb * 8064 (the file's length is
        lda tmp                         ; the host's check)
        sta used
        lda tmp+1
        sta used+1
        lda tmp+2
        sta used+2
        lda #<($A000 + 8)
        ldx #>($A000 + 8)
        jsr setrp
        jmp range

v2:     jsr rdinc                       ; 5: flags
        jsr rdinc                       ; 6: sample banks
        sta nb
        beq bad
        jsr rdinc                       ; 7
        jsr rdinc                       ; 8: entries (16 bit)
        sta cnt
        jsr rdinc
        sta cnt+1
        jsr rdinc                       ; 10: PDX table entries (16 bit, <= 4096)
        sta mtab
        jsr rdinc
        sta mtab+1
        ldx #0                          ; 12: S (24 bit)
:       jsr rdinc
        sta ssz,x
        inx
        cpx #3
        bne :-
        lda mtab+1                      ; m <= $1000
        cmp #$10
        bcc :+
        bne bad
        lda mtab
        bne bad
:       clc                             ; tt = ceil(m / 8)
        lda mtab
        adc #7
        sta tt
        lda mtab+1
        adc #0
        sta tt+1
        ldx #3
:       lsr tt+1
        ror tt
        dex
        bne :-
        lda cnt+1                       ; n <= 910 (9n fits the header bank)
        cmp #>910
        bcc :+
        bne vbad
        lda cnt
        cmp #<910 + 1
        bcc :+
vbad:   jmp bad
:       lda cnt                         ; tmp = 9n + ceil(m / 8) + 36 <= 8192
        sta tmp
        lda cnt+1
        sta tmp+1
        ldx #3
:       asl tmp
        rol tmp+1
        dex
        bne :-
        clc
        lda tmp
        adc cnt
        sta tmp
        lda tmp+1
        adc cnt+1
        sta tmp+1
        clc
        lda tmp
        adc tt
        sta tmp
        lda tmp+1
        adc tt+1
        sta tmp+1
        clc
        lda tmp
        adc #V2_HEAD
        sta tmp
        lda tmp+1
        adc #0
        cmp #>8192                      ; <= $2000
        bcc :+
        bne vbad
        lda tmp
        bne vbad
:       lda nb                          ; D = S - (nb - 1) * 8192 in 1 .. 8064
        dec a
        sta mt
        lsr a
        lsr a
        lsr a
        sta tmp+2
        lda mt
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        sta tmp+1
        sec
        lda ssz+1
        sbc tmp+1
        sta tmp+1
        lda ssz+2
        sbc tmp+2
        bcc bad2                        ; S < (nb - 1) * 8192
        bne bad2                        ; D >= 65536
        lda ssz                         ; D = tmp+1 : ssz
        ora tmp+1
        beq bad2                        ; D = 0
        lda tmp+1
        cmp #>8064
        bcc :+
        bne bad2
        lda ssz
        cmp #<8064 + 1
        bcs bad2
:       lda ssz                         ; the bytes read = S
        cmp la1
        bne badlen
        lda ssz+1
        cmp la2
        bne badlen
        lda ssz+2
        cmp la3
        bne badlen
        lda mt                          ; used = S - (nb - 1) * 128 (no copy after the last bank)
        lsr a
        sta tmp+1                       ; (nb - 1) >> 1
        lda #0
        ror a                           ; ((nb - 1) & 1) << 7
        sta tmp
        sec
        lda ssz
        sbc tmp
        sta used
        lda ssz+1
        sbc tmp+1
        sta used+1
        lda ssz+2
        sbc #0
        sta used+2
        clc                             ; entries at $A000 + 36 + ceil(m / 8)
        lda tt
        adc #<($A000 + V2_HEAD)
        sta rp
        lda tt+1
        adc #>($A000 + V2_HEAD)
        sta rp+1
        bra range
bad2:   jmp bad
badlen: lda #PK_LENGTH
        jmp fail

range:  lda la0                         ; B + nb <= pm_last, inside the RAM
        clc
        adc nb
        bcs badrange
        cmp pm_last
        beq :+
        bcs badrange
:       ldx cal_banks
        beq ents                        ; (0 = 256 banks)
        cmp cal_banks
        bcc ents
badrange:
        lda #PK_RANGE
        jmp fail

; every entry: checked; the ones the song needs go to xd
ents:   lda cnt
        ora cnt+1
        bne :+
        jmp found
:       ldx #0
:       jsr rdinc
        sta xe,x
        inx
        cpx #9
        bne :-
        lda cnt
        bne :+
        dec cnt+1
:       dec cnt
        lda xe+3                        ; bank < nb
        cmp nb
        bcs bad2
        lda xe+5                        ; $A000 <= address < $A000 + 8064
        cmp #>$A000
        bcc bad2
        cmp #>($A000 + 8064)
        bcc :+
        bne bad2
        lda xe+4
        cmp #<($A000 + 8064)
        bcs bad2
:       lda xe+8                        ; length < 2^20 (more is beyond any pack)
        cmp #$10
        bcs bad2
        lda xe+3                        ; end = bank * 8064 + address - $A000 + 2 * length + 64
        jsr mul8064
        clc
        lda tmp
        adc xe+4
        sta tmp
        lda tmp+1
        adc xe+5
        sta tmp+1
        lda tmp+2
        adc #0
        sta tmp+2
        sec
        lda tmp+1
        sbc #>$A000
        sta tmp+1
        lda tmp+2
        sbc #0
        sta tmp+2
        lda xe+6
        asl a
        sta tt
        lda xe+7
        rol a
        sta tt+1
        lda xe+8
        rol a
        sta tt+2
        clc
        lda tt
        adc #SPAD
        sta tt
        bcc :+
        inc tt+1
        bne :+
        inc tt+2
:       clc
        lda tmp
        adc tt
        sta tmp
        lda tmp+1
        adc tt+1
        sta tmp+1
        lda tmp+2
        adc tt+2
        sta tmp+2
        sec                             ; end <= used
        lda used
        sbc tmp
        lda used+1
        sbc tmp+1
        lda used+2
        sbc tmp+2
        bcs :+
        jmp bad
:       ldx xj_n                        ; a pair the song needs (not found yet)?
@m:     dex
        bmi @next
        lda xj_hit,x
        bne @m
        lda xj_slo,x
        cmp xe
        bne @m
        lda xj_shi,x
        cmp xe+1
        bne @m
        lda xj_rt,x
        cmp xe+2
        bne @m
        inc xj_hit,x
        ldy k
        lda xe
        sta xd + 0 * NDIR,y
        lda xe+1
        sta xd + 1 * NDIR,y
        lda xe+2
        sta xd + 2 * NDIR,y
        lda xe+3                        ; bank: B + 1 + relative
        sec
        adc la0
        sta xd + 3 * NDIR,y
        lda xe+4
        sta xd + 4 * NDIR,y
        lda xe+5
        sta xd + 5 * NDIR,y
        lda xe+6
        sta xd + 6 * NDIR,y
        lda xe+7
        sta xd + 7 * NDIR,y
        lda xe+8
        sta xd + 8 * NDIR,y
        inc k
@next:  jmp ents

; the pairs the song needs and the pack lacks
found:  ldx #$FE                        ; the scan went over NDIR pairs: cannot tell
        lda xj_ov
        bne publish
        ldx #$FF                        ; version 1: no bitmap, cannot tell
        lda ver
        cmp #1
        beq publish
        stz miss
        ldx xj_n
@j:     dex
        bmi @end
        lda xj_hit,x
        bne @j
        lda xj_shi,x                    ; sample < m ?
        cmp mtab+1
        bcc :+
        bne @j
        lda xj_slo,x
        cmp mtab
        bcs @j
:       lda xj_slo,x                    ; bitmap bit: $A000 + 36 + s / 8, bit s & 7
        and #7
        tay
        lda xj_shi,x
        sta tt+1
        lda xj_slo,x
        sta tt
        lsr tt+1
        ror tt
        lsr tt+1
        ror tt
        lsr tt+1
        ror tt
        clc
        lda tt
        adc #<($A000 + V2_HEAD)
        sta rp
        lda tt+1
        adc #>($A000 + V2_HEAD)
        sta rp+1
        jsr lo_rd                       ; (lo_bank = la0)
        and bitv,y
        beq @j
        inc miss
        bra @j
@end:   ldx miss

; directory: d_n = 0, the entries, d_n = k
publish:
        phx
        lda pcmbank
        sta lo_bank
        jsr dn_zero
        ldy #0                          ; field
@f:     lda dtab_l,y
        sta rp
        lda dtab_h,y
        sta rp+1
        lda xtab_l,y
        sta @src+1
        lda xtab_h,y
        sta @src+2
        ldx #0
@e:     cpx k
        beq @fn
@src:   lda $FFFF,x
        jsr lo_wr
        inc rp
        bne :+
        inc rp+1
:       inx
        bra @e
@fn:    iny
        cpy #9
        bne @f
        lda #<d_n
        ldx #>d_n
        jsr setrp
        lda k
        jsr lo_wr
        lda k                           ; pcm_on = (k > 0)
        beq :+
        lda #1
:       sta pcm_on
        stz la4
        plx
        lda k
        clc
        rts

; fail: A = PK_* -> directory empty, PCM off, A = X = 0, C = 1
fail:   sta la4
        lda pcmbank
        sta lo_bank
        jsr dn_zero
        stz pcm_on
        lda #0
        ldx #0
        sec
        rts

dn_zero:
        lda #<d_n
        ldx #>d_n
        jsr setrp
        lda #0
        jmp lo_wr

; rp = X:A
setrp:  sta rp
        stx rp+1
        rts

; A = byte at (rp) in lo_bank (N, Z set), rp + 1 (X, Y kept)
rdinc:  jsr lo_rd
        inc rp
        bne :+
        inc rp+1
:       ora #0                          ; (N, Z of the byte)
        rts

; tmp (24 bit) = A * 8064 = A << 13 - A << 7 (X, Y kept)
mul8064:
        sta mt
        lsr a
        lsr a
        lsr a
        sta tmp+2
        lda mt
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        sta tmp+1
        stz tmp
        lda mt
        lsr a                           ; A << 7 = (A >> 1) : (A & 1) << 7
        sta mt
        lda #0
        ror a
        sta mlo
        sec
        lda tmp
        sbc mlo
        sta tmp
        lda tmp+1
        sbc mt
        sta tmp+1
        lda tmp+2
        sbc #0
        sta tmp+2
        rts

magic:  .byte "MXPK"
bitv:   .byte 1, 2, 4, 8, 16, 32, 64, 128
dtab_l: .byte <d_slo, <d_shi, <d_rate, <d_bank, <d_alo, <d_ahi, <d_l0, <d_l1, <d_l2
dtab_h: .byte >d_slo, >d_shi, >d_rate, >d_bank, >d_alo, >d_ahi, >d_l0, >d_l1, >d_l2
xtab_l: .repeat 9, i
        .byte <(xd + i * NDIR)
        .endrepeat
xtab_h: .repeat 9, i
        .byte >(xd + i * NDIR)
        .endrepeat
