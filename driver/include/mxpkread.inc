; mxpkread.inc - bounded reader for X16MXDRV PCM packs (*.P16, docs/api.md), ca65 / 65C02.
;
; .include it in a code segment, after defining MXPK_PTR (a free zero-page word). It adds its
; code to the current segment and its variables to BSS. Used by driver/include/x16mxdrv_cc65.s
; (mxdrv_loadpack) and the ca65 test player.
;
; mxpk_read: the pack file is open as the current input channel (OPEN, CHKIN)
;   A = bank B for the header, X = the last bank that may be written
;   Reads the header bank (8192 bytes) into B and checks it, then reads exactly S sample bytes
;   into B+1.. (S: from the header in version 2, from the entries in version 1) and makes sure
;   that nothing follows them. Writes nothing after bank B + nb (<= X).
;   -> C = 0: mxpk_s (3 bytes) = S (pcmpack's r0 / r1L), mxpk_ver, mxpk_nb
;      C = 1: A = MXPK_NOFILE   nothing could be read (no such file, empty): nothing written
;                 MXPK_LENGTH   the file ends early, or is longer than declared (mxpk_long = 1)
;                 MXPK_NOTPACK  not a pack, or an unknown version
;                 MXPK_BAD      the header does not add up
;                 MXPK_RANGE    B + nb > X (nothing read after the header)
;   RAM_BANK is changed (the caller restores it). The device must support MACPTR (SD card,
;   HostFS); MACPTR reads up to 512 bytes per call and goes on in the next bank by itself.

.ifndef MXPK_OK
MXPK_OK         = 0
MXPK_NOTPACK    = 1
MXPK_RANGE      = 2
MXPK_NOPCM      = 3
MXPK_LENGTH     = 4
MXPK_BAD        = 5
MXPK_NOFILE     = 6
.endif

.pushseg
.bss
mxpk_s:         .res 3
mxpk_ver:       .res 1
mxpk_nb:        .res 1
mxpk_long:      .res 1
mxpk_b:         .res 1
mxpk_last:      .res 1
mxpk_ptr:       .res 2
mxpk_left:      .res 3
mxpk_got:       .res 2
mxpk_cnt:       .res 1
mxpk_t:         .res 3
mxpk_u:         .res 3
mxpk_one:       .res 1
.rodata
mxpk_magic:     .byte $4D, $58, $50, $4B        ; "MXPK" (ASCII)
.popseg

mxpk_read:
        sta mxpk_b
        stx mxpk_last
        stz mxpk_long
        stz mxpk_ver
        stz mxpk_nb
        sta $00                         ; RAM_BANK
        stz mxpk_left                   ; the header: 8192 bytes
        lda #>8192
        sta mxpk_left+1
        stz mxpk_left+2
        jsr mxpk_get
        bcc @head
        lda mxpk_left                   ; nothing read at all?
        bne @short
        lda mxpk_left+1
        cmp #>8192
        bne @short
        lda #MXPK_NOFILE
        sec
        rts
@head:  lda mxpk_b
        sta $00
        jsr mxpk_head                   ; mxpk_ver, mxpk_nb, mxpk_s; C = 1: A = error
        bcs @ret
        lda mxpk_b                      ; B + nb <= the last bank
        clc
        adc mxpk_nb
        bcs @range
        cmp mxpk_last
        beq :+
        bcs @range
:       lda mxpk_b
        inc a
        sta $00
        lda mxpk_s
        sta mxpk_left
        lda mxpk_s+1
        sta mxpk_left+1
        lda mxpk_s+2
        sta mxpk_left+2
        jsr mxpk_get
        bcs @short
        jsr $FFB7                       ; READST: at the end of the file?
        and #$40
        bne @ok
        lda #1                          ; no: one more byte means a longer file
        ldx #<mxpk_one
        ldy #>mxpk_one
        clc
        jsr $FF44                       ; MACPTR
        bcs @ok
        txa
        beq @ok
        inc mxpk_long
@short: lda #MXPK_LENGTH
        sec
@ret:   rts
@range: lda #MXPK_RANGE
        sec
        rts
@ok:    clc
        rts

; mxpk_get: mxpk_left (24 bit) bytes to $A000 of the selected bank (and the next ones)
;   -> C = 1 if the file ended first (mxpk_left = bytes not read)
mxpk_get:
        stz mxpk_ptr
        lda #$A0
        sta mxpk_ptr+1
@l:     lda mxpk_left
        ora mxpk_left+1
        ora mxpk_left+2
        beq @done
        lda mxpk_left+2                 ; A = 0 (up to 512, the KERNAL decides) if left >= 512,
        bne @big                        ; else min(left, 255)
        lda mxpk_left+1
        cmp #2
        bcs @big
        tax
        lda #255
        cpx #0
        bne @n
        lda mxpk_left
        bra @n
@big:   lda #0
@n:     ldx mxpk_ptr
        ldy mxpk_ptr+1
        clc
        jsr $FF44                       ; MACPTR
        bcs @fail                       ; (not supported)
        stx mxpk_got
        sty mxpk_got+1
        txa
        ora mxpk_got+1
        beq @fail                       ; nothing: the end of the file
        clc                             ; ptr += got: past $C000, MACPTR went on in the next bank
        lda mxpk_ptr
        adc mxpk_got
        sta mxpk_ptr
        lda mxpk_ptr+1
        adc mxpk_got+1
        cmp #$C0
        bcc :+
        sbc #$20                        ; (C = 1)
:       sta mxpk_ptr+1
        sec                             ; left -= got
        lda mxpk_left
        sbc mxpk_got
        sta mxpk_left
        lda mxpk_left+1
        sbc mxpk_got+1
        sta mxpk_left+1
        lda mxpk_left+2
        sbc #0
        sta mxpk_left+2
        ora mxpk_left+1
        ora mxpk_left
        beq @done
        jsr $FFB7                       ; READST: the file ended before?
        and #$40
        beq @l
@fail:  sec
        rts
@done:  clc
        rts

; mxpk_head: the header at $A000 of the selected bank -> mxpk_ver, mxpk_nb, mxpk_s = S;
;   C = 1: A = MXPK_NOTPACK / MXPK_BAD. S must match the banks:
;   (nb - 1) * 8192 < S <= (nb - 1) * 8192 + 8064
;   version 1 has no S: (nb - 1) * 128 + the largest linear end of an entry (as mkpack.py;
;   no entries: S = 0)
mxpk_head:
        ldx #3
:       lda $A000,x
        cmp mxpk_magic,x
        bne @notp
        dex
        bpl :-
        lda $A004
        sta mxpk_ver
        cmp #1
        beq :+
        cmp #2
        bne @notp
:       lda $A006
        sta mxpk_nb
        beq @bad
        lda mxpk_ver
        cmp #2
        bne @v1
        lda $A00C
        sta mxpk_s
        lda $A00D
        sta mxpk_s+1
        lda $A00E
        sta mxpk_s+2
        jmp @chk
@notp:  lda #MXPK_NOTPACK
        sec
        rts
@bad:   lda #MXPK_BAD
        sec
        rts
@v1:    stz mxpk_s                      ; version 1: the largest end of an entry
        stz mxpk_s+1
        stz mxpk_s+2
        lda $A005
        cmp #97
        bcs @bad
        sta mxpk_cnt
        lda #<$A008
        sta MXPK_PTR
        lda #>$A008
        sta MXPK_PTR+1
@e:     lda mxpk_cnt
        bne :+
        jmp @v1end
:       dec mxpk_cnt
        ldy #3                          ; end = bank * 8064 + addr - $A000 + 2 * len + 64
        lda (MXPK_PTR),y
        jsr mxpk_mul
        ldy #4
        clc
        lda (MXPK_PTR),y
        adc mxpk_t
        sta mxpk_t
        iny
        lda (MXPK_PTR),y
        adc mxpk_t+1
        sta mxpk_t+1
        bcc :+
        inc mxpk_t+2
:       sec
        lda mxpk_t+1
        sbc #>$A000
        sta mxpk_t+1
        lda mxpk_t+2
        sbc #0
        sta mxpk_t+2
        ldy #6
        lda (MXPK_PTR),y
        asl a
        sta mxpk_u
        iny
        lda (MXPK_PTR),y
        rol a
        sta mxpk_u+1
        iny
        lda (MXPK_PTR),y
        rol a
        sta mxpk_u+2
        clc
        lda mxpk_u
        adc #64
        sta mxpk_u
        bcc :+
        inc mxpk_u+1
        bne :+
        inc mxpk_u+2
:       clc
        lda mxpk_t
        adc mxpk_u
        sta mxpk_t
        lda mxpk_t+1
        adc mxpk_u+1
        sta mxpk_t+1
        lda mxpk_t+2
        adc mxpk_u+2
        sta mxpk_t+2
        sec                             ; mxpk_s = max(mxpk_s, end)
        lda mxpk_s
        sbc mxpk_t
        lda mxpk_s+1
        sbc mxpk_t+1
        lda mxpk_s+2
        sbc mxpk_t+2
        bcs :+
        lda mxpk_t
        sta mxpk_s
        lda mxpk_t+1
        sta mxpk_s+1
        lda mxpk_t+2
        sta mxpk_s+2
:       clc
        lda MXPK_PTR
        adc #9
        sta MXPK_PTR
        bcc :+
        inc MXPK_PTR+1
:       jmp @e
@v1end: lda mxpk_s                      ; S = (nb - 1) * 128 + end (no entries: 0)
        ora mxpk_s+1
        ora mxpk_s+2
        beq @ok
        lda mxpk_nb
        dec a
        lsr a
        sta mxpk_u+1
        lda #0
        ror a
        clc
        adc mxpk_s
        sta mxpk_s
        lda mxpk_u+1
        adc mxpk_s+1
        sta mxpk_s+1
        bcc @chk
        inc mxpk_s+2
@chk:   lda mxpk_nb                     ; D = S - (nb - 1) * 8192 in 1 .. 8064
        dec a
        pha
        lsr a
        lsr a
        lsr a
        sta mxpk_u+2
        pla
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        sta mxpk_u+1
        sec
        lda mxpk_s+1
        sbc mxpk_u+1
        sta mxpk_u+1
        lda mxpk_s+2
        sbc mxpk_u+2
        bcc @bad2
        bne @bad2
        lda mxpk_s
        ora mxpk_u+1
        beq @bad2
        lda mxpk_u+1
        cmp #>8064
        bcc @ok
        bne @bad2
        lda mxpk_s
        cmp #<8064 + 1
        bcs @bad2
@ok:    clc
        rts
@bad2:  lda #MXPK_BAD
        sec
        rts

; mxpk_t (24 bit) = A * 8064 = A * 8192 - A * 128
mxpk_mul:
        sta mxpk_u
        lsr a
        lsr a
        lsr a
        sta mxpk_t+2
        lda mxpk_u
        and #7
        asl a
        asl a
        asl a
        asl a
        asl a
        sta mxpk_t+1
        stz mxpk_t
        lda mxpk_u
        lsr a
        sta mxpk_u
        lda #0
        ror a
        sta mxpk_u+1
        sec
        lda mxpk_t
        sbc mxpk_u+1
        sta mxpk_t
        lda mxpk_t+1
        sbc mxpk_u
        sta mxpk_t+1
        lda mxpk_t+2
        sbc #0
        sta mxpk_t+2
        rts
