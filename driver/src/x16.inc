; x16.inc - Commander X16 hardware / KERNAL constants (from thirdparty/x16-docs)

RAM_BANK    = $00
ROM_BANK    = $01

; VIA #1 ($9F00) - IRQ wired to the CPU IRQ line
VIA1_T1CL   = $9F04
VIA1_T1CH   = $9F05
VIA1_T1LL   = $9F06
VIA1_T1LH   = $9F07
VIA1_ACR    = $9F0B
VIA1_IFR    = $9F0D
VIA1_IER    = $9F0E

; VERA
VERA_IEN    = $9F26
VERA_ISR    = $9F27
AUDIO_CTRL  = $9F3B
AUDIO_RATE  = $9F3C
AUDIO_DATA  = $9F3D

; YM2151 / YM2164
YM_ADDR     = $9F40
YM_DATA     = $9F41

; x16-emulator debug registers
EMU_CLK0    = $9FB8          ; read: latch cpu clock counter, bits 0-7
EMU_CLK1    = $9FB9
EMU_CLK2    = $9FBA
EMU_CLK3    = $9FBB          ; read: bits 24-31 / write: character to host stdout
EMU_ID1     = $9FBE          ; reads '1'
EMU_ID2     = $9FBF          ; reads '6'

; KERNAL
CINV        = $0314
SETLFS      = $FFBA
SETNAM      = $FFBD
LOAD        = $FFD5
CHROUT      = $FFD2
RDTIM       = $FFDE
OPEN        = $FFC0
CLOSE       = $FFC3
CHKIN       = $FFC6
CLRCHN      = $FFCC
CHRIN       = $FFCF
READST      = $FFB7
MACPTR      = $FF44
