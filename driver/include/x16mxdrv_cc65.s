; x16mxdrv_cc65.s - cc65 glue for X16MXDRV.BIN (see x16mxdrv.h)
; Calls switch the RAM bank to mxdrv_bank and back (the caller's bank is kept).
; mxdrv_loadpack uses the pack reader in mxpkread.inc (next to this file).

.setcpu "65C02"
.include "zeropage.inc"
.import popa, popax
.export _mxdrv_bank, _mxdrv_mhz, _mxdrv_clock
.export _mxdrv_init, _mxdrv_setmdx, _mxdrv_play, _mxdrv_stop, _mxdrv_fadeout
.export _mxdrv_status, _mxdrv_ticks, _mxdrv_setopt, _mxdrv_pcmmem, _mxdrv_pcmpack
.export _mxdrv_pdxbegin, _mxdrv_pdxfeed, _mxdrv_pdxend, _mxdrv_pdxname
.export _mxdrv_pcmstat, _mxdrv_snapshot
.export _mxdrv_loadpack, _mxdrv_pkver, _mxdrv_pkpairs, _mxdrv_pkmissing, _mxdrv_pdxover

RAM_BANK = $00
R0       = $02
PKLFN    = 14                           ; mxdrv_loadpack: logical file / secondary address

.data
_mxdrv_bank:  .byte 1

.bss
_mxdrv_mhz:   .res 1
_mxdrv_clock: .res 1
target:       .res 2
savebank:     .res 1
tmp:          .res 2
_mxdrv_pkver:     .res 1
_mxdrv_pkpairs:   .res 1
_mxdrv_pkmissing: .res 1
_mxdrv_pdxover:   .res 1
lp_bank:      .res 1
lp_save:      .res 1

.code
; call: API address at the jsr's inline word; A, X, Y, C in and out
.macro CALL api
        pha
        lda #<api
        sta target
        lda #>api
        sta target+1
        pla
        jsr far
.endmacro

far:    pha
        lda RAM_BANK
        sta savebank
        lda _mxdrv_bank
        sta RAM_BANK
        pla
        jsr @go
        php
        pha
        lda savebank
        sta RAM_BANK
        pla
        plp
        rts
@go:    jmp (target)

; unsigned char mxdrv_init(void)
_mxdrv_init:
        CALL $A000
        stx _mxdrv_mhz
        sty _mxdrv_clock
        ldx #0
        rts

; unsigned char mxdrv_setmdx(unsigned char bank, const void *addr, unsigned size)
_mxdrv_setmdx:
        sta R0
        stx R0+1
        jsr popax
        sta tmp
        stx tmp+1
        jsr popa
        ldx tmp
        ldy tmp+1
        CALL $A003
retc:   lda #0                          ; C -> 0 / 1
        tax
        rol a
        rts

_mxdrv_play:
        CALL $A006
        rts

_mxdrv_stop:
        CALL $A009
        rts

; void mxdrv_fadeout(unsigned char speed)
_mxdrv_fadeout:
        CALL $A00C
        rts

; unsigned char mxdrv_status(unsigned *loops)
_mxdrv_status:
        sta ptr1
        stx ptr1+1
        CALL $A00F
        pha
        txa
        sta (ptr1)
        tya
        ldy #1
        sta (ptr1),y
        pla
        ldx #0
        rts

; unsigned mxdrv_ticks(void)
_mxdrv_ticks:
        CALL $A015
        txa
        phy
        plx
        rts

; void mxdrv_setopt(unsigned char option, unsigned char value)
_mxdrv_setopt:
        sta tmp
        jsr popa
        ldx tmp
        CALL $A018
        rts

; unsigned char mxdrv_pcmmem(unsigned char first, unsigned char last,
;                            unsigned char lutpage, unsigned char slots)
_mxdrv_pcmmem:
        sta R0
        stz R0+1
        jsr popa
        sta tmp                         ; lutpage
        jsr popa
        sta tmp+1                       ; last
        jsr popa                        ; first
        ldx tmp+1
        ldy tmp
        CALL $A01B
        jmp retc

; unsigned char mxdrv_pcmpack(unsigned char bank)
_mxdrv_pcmpack:
        CALL $A033
ret255: ldx #0                          ; C = 1 -> 255
        bcc :+
        lda #255
:       rts

; unsigned char mxdrv_pdxbegin(void)
_mxdrv_pdxbegin:
        CALL $A021
        jmp ret255

; unsigned char mxdrv_pdxfeed(const void *buf, unsigned len)
_mxdrv_pdxfeed:
        sta R0
        stx R0+1
        jsr popax
        tay
        txa
        pha
        tya
        tax
        ply
        CALL $A024
        jmp retc

; unsigned char mxdrv_pdxend(unsigned char *missing)
_mxdrv_pdxend:
        sta ptr1
        stx ptr1+1
        CALL $A027
        sty _mxdrv_pdxover
        sta (ptr1)
        txa
        ldx #0
        rts

; unsigned char mxdrv_pdxname(unsigned char *bank, void **addr)
_mxdrv_pdxname:
        sta ptr2
        stx ptr2+1
        jsr popax
        sta ptr1
        stx ptr1+1
        CALL $A01E
        bcs @none
        sta (ptr1)
        txa
        sta (ptr2)
        tya
        ldy #1
        sta (ptr2),y
        lda #1
        ldx #0
        rts
@none:  lda #0
        tax
        rts

; unsigned char mxdrv_pcmstat(unsigned *underruns)
_mxdrv_pcmstat:
        sta ptr1
        stx ptr1+1
        CALL $A02A
        pha
        txa
        sta (ptr1)
        tya
        ldy #1
        sta (ptr1),y
        pla
        ldx #0
        rts

; void mxdrv_snapshot(void *buf)
_mxdrv_snapshot:
        pha
        txa
        tay
        plx
        CALL $A02D
        rts

; unsigned char mxdrv_loadpack(const char *name, unsigned char bank, unsigned char lastbank)
;   read the pack with mxpk_read (only what its header declares), then pcmpack -> MXPK_*
_mxdrv_loadpack:
        sta tmp+1                       ; lastbank
        jsr popa
        sta lp_bank
        jsr popax
        sta ptr1
        stx ptr1+1
        stz _mxdrv_pkver
        stz _mxdrv_pkpairs
        stz _mxdrv_pkmissing
        lda RAM_BANK
        sta lp_save
        ldy #0                          ; SETNAM: length, X/Y = name
:       lda (ptr1),y
        beq :+
        iny
        bne :-
:       tya
        ldx ptr1
        ldy ptr1+1
        jsr $FFBD                       ; SETNAM
        lda #PKLFN
        ldx #8
        ldy #PKLFN
        jsr $FFBA                       ; SETLFS
        jsr $FFC0                       ; OPEN
        bcs @nofile
        ldx #PKLFN
        jsr $FFC6                       ; CHKIN
        bcs @nofile
        lda lp_bank
        ldx tmp+1
        jsr mxpk_read
        php
        pha
        lda mxpk_ver                    ; (0 if no header was read)
        sta _mxdrv_pkver
        jsr @close
        pla
        plp
        bcs @rerr
        lda mxpk_s                      ; r0 + r1L = the sample bytes read
        sta R0
        lda mxpk_s+1
        sta R0+1
        lda mxpk_s+2
        sta R0+2
        lda lp_bank
        CALL $A033                      ; -> A pairs, X missing, Y result, C
        bcs @derr
        sta _mxdrv_pkpairs
        stx _mxdrv_pkmissing
        lda #MXPK_OK
        bra @ret
@derr:  tya                             ; the driver refused (an old driver: Y = ?)
        bne @ret
        lda #MXPK_NOTPACK
        bra @ret
@nofile:
        jsr @close
        lda #MXPK_NOFILE
        bra @ret
@rerr:  cmp #MXPK_NOFILE
        beq @ret
        pha                             ; refused after writing: no PCM for the song (pcmpack
        lda lp_bank                     ; on a header that is not a pack fails and clears)
        sta RAM_BANK
        stz $A000
        CALL $A033
        pla
@ret:   ldx lp_save
        stx RAM_BANK
        ldx #0
        rts
@close: jsr $FFCC                       ; CLRCHN
        lda #PKLFN
        jmp $FFC3                       ; CLOSE

MXPK_PTR = ptr2
.include "mxpkread.inc"
