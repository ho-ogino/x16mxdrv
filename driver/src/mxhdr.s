; mxhdr.s - X16MXDRV bank +3: MDX header check for api setmdx
;
; x_mdx (X_MDX, through lo_call3; main thread, from api_setmdx):
;   in:  lbase = linear address of the MDX file, zsave_api (the host's r0) = file size S
;   Every byte is read below S:
;   1. the title ends at $0D $0A $1A: the $1A must come within the first 1 KB (not at 0)
;   2. the PDX name after it ends with 0 (empty = no PDX)
;   3. the body after the name must hold the voice offset and 16 channel offsets (34 bytes)
;   out: C = 0: lbase = linear address of the body, mdx_len = body size, pdxn (bank +0) =
;        linear address of the PDX name or 0. C = 1: not an MDX (nothing changed).
; Memory outside bank +3 is read and written through lo_rd / lo_wr.

.setcpu "65C02"
.include "x16.inc"
.include "mx16.inc"

.importzp rp
.import lo_rd, lo_wr, lo_bank, drvbank, lbase, mdx_len, zsave_api, pdxn

.segment "XJMP"                         ; (after mxmute.s: X_MDX = 6)
        .word x_mdx

.segment "XBSS"
ofs:    .res 2                          ; offset in the file
nm:     .res 3                          ; linear address of the PDX name (0 = none)
tb:     .res 1

.segment "XCODE"
bad:    sec                             ; not an MDX
        rts
x_mdx:
        stz ofs
        stz ofs+1
@find:  lda ofs+1                       ; the $1A within the first 1 KB
        cmp #4
        bcs bad
        jsr rd
        bcs bad
        cmp #$1A
        bne :+
        lda ofs                         ; (not at the very start)
        ora ofs+1
        bne @name
:       jsr inc_ofs
        bra @find
@name:  jsr inc_ofs
        stz nm
        stz nm+1
        stz nm+2
        jsr rd
        bcs bad
        tax
        beq @skip                       ; empty: no PDX
        jsr lin                         ; nm = lbase + ofs
        lda rp
        sta nm
        lda tb
        sta nm+1
        lda rp+1
        sta nm+2
@skip:  jsr rd                          ; skip the name and its 0
        bcs bad
        jsr inc_ofs
        cmp #0
        bne @skip
        sec                             ; body size = S - ofs, at least 34
        lda zsave_api
        sbc ofs
        tax
        lda zsave_api+1
        sbc ofs+1
        bne :+
        cpx #34
        bcc bad
:       sta mdx_len+1
        stx mdx_len
        clc                             ; lbase += ofs
        lda lbase
        adc ofs
        sta lbase
        lda lbase+1
        adc ofs+1
        sta lbase+1
        bcc :+
        inc lbase+2
:       lda drvbank                     ; pdxn = nm
        sta lo_bank
        lda #<pdxn
        sta rp
        lda #>pdxn
        sta rp+1
        ldx #0
@wr:    lda nm,x
        jsr lo_wr
        inc rp
        bne :+
        inc rp+1
:       inx
        cpx #3
        bne @wr
        clc
        rts

inc_ofs:
        inc ofs
        bne :+
        inc ofs+1
:       rts

; lin: rp = bits 0..7, tb = bits 8..15, rp+1 = bits 16..23 of lbase + ofs
lin:    clc
        lda lbase
        adc ofs
        sta rp
        lda lbase+1
        adc ofs+1
        sta tb
        lda lbase+2
        adc #0
        sta rp+1
        rts

; rd: A = file byte at ofs, C = 0; C = 1 if ofs >= S (A undefined). X kept.
rd:     lda ofs
        cmp zsave_api
        lda ofs+1
        sbc zsave_api+1
        bcs @r
        jsr lin                         ; bank = linear >> 13, address = $A000 + (linear & $1FFF)
        lda rp+1
        asl a
        asl a
        asl a
        sta lo_bank
        lda tb
        lsr a
        lsr a
        lsr a
        lsr a
        lsr a
        ora lo_bank
        sta lo_bank
        lda tb
        and #$1F
        ora #$A0
        sta rp+1
        jsr lo_rd
        clc
@r:     rts
