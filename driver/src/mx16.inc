; mx16.inc - shared definitions of the three X16MXDRV banks and the low RAM part (mxlow.s)

ZPS         = $02                   ; borrowed zero page (KERNAL r0-r13): $02 .. $02 + ZPN - 1
ZPN         = 28
NVMAX       = 8                     ; PCM voices (runtime limit p_nv <= NVMAX)
NPCH        = 9                     ; PCM channels: PCM8 0-7, MSM6258 = 8
NDIR        = 96                    ; sample directory entries ((sample, rate) pairs)
SBANK_DATA  = 8064                  ; unique sample bytes per bank ($A000-$BF7F)
SPAD        = 64                    ; zero bytes after each sample
CHUNK       = 64                    ; max samples per mixer chunk

; mix buffers: 64 bytes each at $xxC0, used as BASE+Y with Y = 256-n .. 255
MIXLO       = $0400                 ; -> $04C0
MIXHI       = $0500                 ; -> $05C0
RSBUF       = $0600                 ; -> $06C0

AUDIO_CTRL_INIT = $8F               ; FIFO reset, 8-bit mono, volume 15
PCM_RATE    = 41                    ; 15640.2588 Hz

; PCM bank (bank +1) entry points: X = offset for lo_call1
P_INIT      = 0                     ; power-on defaults
P_SETUP     = 2                     ; pm_* set -> C = 1 if PCM is not possible
P_START     = 4                     ; before play (I = 1): FIFO reset + L silence
P_STOP      = 6                     ; stop output, free voices
P_BEGIN     = 8                     ; worker: underrun check, budgets
P_GEN       = 10                    ; worker: generate up to the target -> C = 1 out of budget
P_FIN       = 12                    ; worker: end of run (recovery restart)
P_EVENT     = 14                    ; out_pcm event in pev_*
P_GETLEN    = 16                    ; pdx_get: t4:t5 sample -> t0..t3 length in bytes
P_SETNV     = 18                    ; la0 = voice limit
P_STAT      = 20                    ; -> la0 active, la1 max, la2/la3 underruns, la4/la5 steals
P_SETL      = 22                    ; la0/la1 = latency L in samples
P_CLEARDIR  = 24                    ; empty sample directory
P_LEVEL2    = 26                    ; IRQ level 2: clock, FM queue, PCM generation
P_FMPUSH    = 28                    ; queue YM write fq_reg / fq_val (level 1)
P_FMMARK    = 30                    ; queue tick marker s_cur (level 1)
P_EVPUSH    = 32                    ; queue PCM event pev_* at s_cur (level 1)
P_PACK      = 34                    ; (unused: packs are read by bank +3 X_PACK)
P_DONE      = 36                    ; -> C = 1: all queued output played (queues, voices, FIFO)
P_FMDRAIN   = 38                    ; stop (I = 1): queue mode: queued YM writes to the chip now (no key on/off)


; bank +3 entry points: X = offset for lo_call3
X_PACK      = 0                     ; la0 = pack bank, la1-la3 = sample bytes read -> A, X, C, la4
X_MUTE      = 2                     ; worker, before a tick: apply changed mute masks (mxmute.s)
X_YMRST     = 4                     ; api_init: YM reset + shadow, no channel muted
X_MDX       = 6                     ; api_setmdx: header check (mxhdr.s) -> C, lbase, mdx_len, pdxn

; pcmpack results (Y)
PK_OK       = 0
PK_NOTPACK  = 1                     ; not a pack, or another version
PK_RANGE    = 2                     ; sample banks beyond pm_last / the RAM
PK_NOPCM    = 3                     ; PCM not set up (pcmmem)
PK_LENGTH   = 4                     ; version 2: bytes read <> the header's S
PK_BAD      = 5                     ; header or an entry reference out of the pack

; loader bank (bank +2) entry points: X = offset for lo_call2
L_INIT      = 0                     ; chip detection, calibration -> cal_*
L_BEGIN     = 2                     ; scan MDX for samples, reset PDX parser -> A = entries, C = 1 no PCM
L_FEED      = 4                     ; la0/la1 = buffer, la2/la3 = length -> C = 1 all data received
L_END       = 6                     ; -> A = missing, la0 = loaded entries, la1 = banks used
L_PROG      = 8                     ; -> r0 = PDX bytes read >> 8, r1 = end of needed data >> 8
L_TEMPO     = 10                    ; tick clock: T1 period for tk_n (Y = 0 before play, 2 playing)
