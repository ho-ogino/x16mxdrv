; mxcore.inc - shared constants for the MXDRV-compatible core

; out_pcm event kinds (operands in pe_ch, pe_smp, pe_mode, pe_len)
PCM_P   = 1     ; PCM8 channel start: pe_ch, pe_smp, pe_mode (vol<<16|rate<<8|pan), pe_len
PCM_S   = 2     ; PCM8 channel stop:  pe_ch
PCM_X   = 3     ; PCM8 stop all
PCM_A   = 4     ; MSM6258 (non-PCM8) start: pe_smp, pe_mode (rate<<8|pan), pe_len (<= $FF00)
PCM_M   = 5     ; MSM6258 mode: pe_ch = 0 (end) / 1 (stop)
