; x16mxdrv.inc - ca65 interface to X16MXDRV.BIN (docs/api.md)
;
; Load X16MXDRV.BIN headerless to $A000 of RAM bank MXDRV_BANK (it occupies 4 banks), keep
; golden RAM $0400-$07FF free (no zero page is needed: the driver borrows $02-$1D while it
; runs and restores it), then call the API with MXDRV:
;
;       MXDRV_BANK = 1
;       .include "x16mxdrv.inc"
;       MXDRV MX_INIT               ; A/X/Y in and out as documented, flags (C) too
;
; MXDRV uses the KERNAL's JSRFAR, which switches the RAM bank and keeps A, X, Y and P.

.ifndef MXDRV_BANK
MXDRV_BANK      = 1
.endif

MX_INIT         = $A000     ; -> A chip (1 YM2164, 2 YM2151), X CPU MHz, Y OPM clock (0 3.58, 1 4 MHz)
MX_SETMDX       = $A003     ; A bank, X/Y address of the MDX file, r0 size -> C=1 not an MDX
MX_PLAY         = $A006
MX_STOP         = $A009
MX_FADEOUT      = $A00C     ; A speed (0 = 17)
MX_STATUS       = $A00F     ; -> A flags (1 playing, 2 ended, 4 fading, 8 PCM), X/Y loops
MX_TITLE        = $A012     ; -> A bank, X/Y address of the title (Shift_JIS, ends with $0D)
MX_TICKS        = $A015     ; -> X/Y ticks
MX_SETOPT       = $A018     ; A option, X value (see MXOPT_*)
MX_PCMMEM       = $A01B     ; A first, X last sample bank, Y LUT page, r0L slots -> C=1 no PCM
MX_PDXNAME      = $A01E     ; -> A bank, X/Y address of the PDX name, C=1 none
MX_PDXBEGIN     = $A021     ; -> A pairs needed (0 = nothing), C=1 no PCM
MX_PDXFEED      = $A024     ; X/Y buffer, r0 length -> C=1 all needed data received
MX_PDXEND       = $A027     ; -> A pairs missing, X pairs loaded
MX_PCMSTAT      = $A02A     ; -> A active voices, X/Y underruns
MX_SNAPSHOT     = $A02D     ; X/Y 202-byte buffer <- display state
MX_PDXPROG      = $A030     ; -> r0 bytes read / 256, r1 needed end / 256
MX_PCMPACK      = $A033     ; A bank of a loaded .P16 pack -> A pairs, C=1 error

MXOPT_CHIP      = 0         ; YM chip override (1 YM2164, 2 YM2151)
MXOPT_PITCH     = 1         ; pitch offset (1/64 semitone; 123 for 3.58 MHz, 0 for 4 MHz)
MXOPT_K         = 2         ; ticks per IRQ run (8)
MXOPT_VOICES    = 3         ; PCM voices 1..8 (4)
MXOPT_LATENCY   = 4         ; PCM latency L, x 4 samples (62 = 15.9 ms)
MXOPT_MUTE      = 5         ; 1 FM, 2 PCM (debug)
MXOPT_MODE      = 6         ; 0 direct, 1 queue (default: FM delayed to match PCM)
MXOPT_AHEAD     = 7         ; queue mode lookahead, x 4 samples (196 = 50 ms)
MXOPT_TICKCLK   = 8         ; songs without PCM: 1 T1 per tick (default), 0 always 2 ms
MXOPT_FMMASK    = 9         ; mute: bit n = FM channel n (kept across songs)
MXOPT_PCMMASK   = 10        ; mute: bit n = PCM channel P+n

MXST_PLAYING    = $01
MXST_ENDED      = $02
MXST_FADING     = $04
MXST_PCM        = $08
MXST_SEQEND     = $10         ; sequence ended (MXST_ENDED: and everything played)

.macro MXDRV api
        jsr $FF6E               ; JSRFAR
        .word api
        .byte MXDRV_BANK
.endmacro
