# X16MXDRV API — reference for embedding

[日本語](api.ja.md)

X16MXDRV plays MDX files for the X68000's MXDRV, together with their PDX samples, on the
Commander X16 without converting them.
- **FM:** YM2151 (OPM) and YM2164 (OPP).
- **PCM:** PCM8-compatible, output through VERA PCM.
- **Form:** the driver stays in RAM banks and is called through a jump table.

It can be built into games and other programs.

> **Note: small data, heavy driver**
> - The driver interprets the song data (notes, volume, software LFO and so on) as it plays, and mixes up to 8 PCM voices in software for VERA. The data stays small, but the CPU load while playing is high.
> - CPU load at 8 MHz (measured in x16emu, including about 2.5% for the KERNAL's VSYNC handling): about 10-14% for FM-only songs, about 30-50% for songs with PCM. For comparison, the same FM-only songs converted to ZSM and played with ZSMKit take about 4-8%.
> - A PDX is decoded on the X16 while it loads, which takes around 20 seconds for a PCM-heavy song. A P16 pack made on a PC (section 4) loads in a few seconds.
> - The driver uses 4 RAM banks, and PCM needs a machine with more than 512 KB (section 1).
> - If a game needs CPU time, consider fewer PCM voices (`setopt`), or ZSM for FM-only songs.

## 1. Resources

| Resource | What | Notes |
|---|---|---|
| 4 RAM banks | `X16MXDRV.BIN` (25 KB), banks D to D+3 | D is up to you. Load it headerless at `$A000`; KERNAL LOAD goes on into the next banks by itself. All 4 banks are used while playing: keep other data out of them, including the part of D+3 after the end of the file, which is the driver's work area. |
| Zero page | **none of its own** | The driver borrows `$02`-`$1D` (KERNAL r0-r13) only while its core or loader runs. The IRQ worker and the API entry save the host's values and restore them on the way out. The host need not reserve anything. |
| Golden RAM `$0400`-`$07FF` | IRQ entry, bank trampolines, the mixer's inner loops | Written by `init` |
| Low RAM, given by the host | PCM volume tables: 512 bytes × slots (4-16, 8 recommended), aligned to 256 bytes | Only with PCM |
| RAM banks, given by the host | Decoded PCM samples, or the banks a PCM pack was read into | Only with PCM. Needs more than 512 KB |
| RAM banks for the MDX | The MDX file, loaded by the host from bank M at `$A000` on. A file over 8 KB goes on into M+1, M+2, … (64 KB = 8 banks) | Keep them while playing. At most 65535 bytes (setmdx takes a 16-bit size) |
| VIA1 timer 1 | The interrupt: every 2 ms for songs with PCM; for songs without PCM, a period matching the tick (see 7) | Only while playing; restored when stopped |
| IRQ vector (CINV `$0314`) | Replaced while playing; the old handler is chained | VERA interrupts (VSYNC etc.) are handled by the old handler |
| YM2151 | All registers | While playing, the host must not touch the YM |
| VERA PCM (FIFO, AUDIO_CTRL, AUDIO_RATE) | When the song uses PCM | The PSG is not used, so it is free for sound effects |

- **CPU:** 8 MHz recommended. `init` measures the speed.
- **CPU load at 8 MHz:** about 10-14% for FM-only songs, about 30-50% for songs with 4 PCM8
  voices. Heavy ticks at the start of a song or at its loop point are absorbed by the
  look-ahead (below).
- **512 KB machines:** no PCM (`pcmmem` returns C=1). Songs play with FM only.

### Example layout (mdxplay)

| Memory | Use |
|---|---|
| Banks 1-4 | `X16MXDRV.BIN` (D = 1) |
| Banks 5-12 | The MDX (8 banks: files up to 65535 bytes) |
| Banks 13-21 | `KANJI8.BIN` (the player's font) |
| Bank 22 | The song titles of the list (the player) |
| Banks 23 to the last | PCM samples or a PCM pack (`pcmmem 23, last`); 2 MB: banks 23-255 |
| Low RAM, 4 KB aligned to 256 | PCM volume tables, 8 slots |
| Golden RAM `$0400`-`$07FF` | The driver |

## 2. Calling the driver

With bank D selected, the API is called by `jsr` to `$A000` + n. The easiest way is
KERNAL `JSRFAR` (`$FF6E`), which passes A/X/Y/P in and out unchanged.
- **prog8:** `%import x16mxdrv` (`driver/include/x16mxdrv.p8`), then `mxdrv.init()` etc.
- **ca65:** `.include "x16mxdrv.inc"`, then `MXDRV MX_INIT`; the macro expands to JSRFAR.
- **cc65:** `#include "x16mxdrv.h"` and link `x16mxdrv_cc65.s`, then `mxdrv_init()` etc. The
  standard cx16 linker config is fine.
  - Note: older cc65 releases define `RAM_BANK` in `cx16.h` at the early prototypes'
    address (VIA1 port A). On current machines, the RAM bank register is `$0000`. For the
    same reason, the old `waitvsync()` never returns on current ROMs. See
    `demo/cc65demo.c`.

`r0` = `$02`/`$03` (KERNAL virtual registers).

| Address | Name | In → out |
|---|---|---|
| `$A000` | init | → A = YM chip (1 YM2164 / 2 YM2151 / 0 unknown), X = CPU MHz, Y = OPM clock (0 3.58 MHz / 1 4 MHz). Calibration takes about 0.4 s with interrupts off |
| `$A003` | setmdx | A = bank, X/Y = address of the MDX file, r0 = size → C=1 if not an MDX: the title's end `$0D $0A $1A` within the first 1 KB, the PDX name with its 0 and the offset table (34 bytes) must all lie within r0 bytes. Stops the song playing first. While playing, the song writes only inside its body (repeat counters) |
| `$A006` | play | Play from the start |
| `$A009` | stop | Stop; silence the YM and PCM |
| `$A00C` | fadeout | A = speed (the value of MXDRV's `$E7 $01`; 0 means 17). When fully faded, the song is "ended" |
| `$A00F` | status | → A = bit0 playing / bit1 ended (everything up to the last sound is out) / bit2 fading / bit3 PCM on / bit4 sequence ended; X/Y = loop count (`$FFFF` once ended) |
| `$A012` | title | → A = bank, X/Y = address of the title (Shift_JIS, ends with `$0D`) |
| `$A015` | ticks | → X/Y = ticks played |
| `$A018` | setopt | A = item, X = value (table below) |
| `$A01B` | pcmmem | A = first sample bank, X = last sample bank, Y = page of the volume tables, r0L = slots → C=1 if PCM cannot be used |
| `$A01E` | pdxname | → A = bank, X/Y = address of the PDX name in the MDX (0-terminated); C=1 if no PDX |
| `$A021` | pdxbegin | Scan the MDX → A = number of (sample, rate) pairs to load (0 = none); C=1 if PCM is not possible |
| `$A024` | pdxfeed | X/Y = a low RAM buffer with the next part of the PDX, r0 = its length → C=1 once everything needed is in (stop reading then) |
| `$A027` | pdxend | → A = pairs that did not fit, X = pairs loaded, Y = 1 if the song needs more than 96 pairs (pairs after the 96th are not loaded). PCM is on for this song if X>0 |
| `$A02A` | pcmstat | → A = voices sounding, X/Y = FIFO underruns |
| `$A02D` | snapshot | X/Y = a 202-byte buffer ← display state (section 5) |
| `$A030` | pdxprog | → r0 = PDX bytes read / 256, r1 = end of the data needed / 256 (0 until the PDX index has been read) |
| `$A033` | pcmpack | A = bank B holding a PCM pack's (`*.P16`) header bank; r0 + r1L = bytes of the sample part read (version 2 only) → A = pairs registered, X = pairs the song needs that the pack lacks (0-96; `$FE` = the song needs more than 96 pairs, cannot tell; `$FF` = version 1, cannot tell), Y = result (section 4), C=1 on error (PCM is off for this song). Call after setmdx, instead of pdxbegin…pdxend. The include files' `loadpack` reads the file and calls this |

### setopt items

| A | What | Default |
|---|---|---|
| 0 | YM chip (1 YM2164 / 2 YM2151) | detected |
| 1 | Pitch correction (1/64 semitones) | 123 at 3.58 MHz, 0 at 4 MHz |
| 2 | Most ticks processed in one interrupt (K) | 8 |
| 3 | PCM voices (1-8) | 4 |
| 4 | PCM delay L (× 4 samples) | 62 (15.9 ms) |
| 5 | Mute (debugging; 1 FM, 2 PCM) | 0 |
| 6 | Mode: 0 direct / 1 queue (from the next play) | 1 |
| 7 | Queue mode look-ahead A (× 4 samples) | 196 (50 ms) |
| 8 | Songs without PCM: interrupt matched to the tick (1) / always 2 ms (0). From the next play | 1 |
| 9 | Channel mute FM (bit n = FM channel n; below) | 0 |
| 10 | Channel mute PCM (bit n = PCM channel P+n) | 0 |

- **Channel mute (9 / 10):**
  - A muted channel keeps playing inside the driver; only its output to the YM and PCM is
    held back.
  - When it is unmuted, the driver writes that channel's voice, pitch and volume registers
    again, and a held note sounds from there on. PCM sounds again from its next note.
  - The masks stay set across songs (`play` does not clear them).
  - **Delay:** applied when the next tick is processed, so at most 1 tick + A + L (direct
    mode: 1 tick + L).
  - **Not MXDRV's channel mask:** that mask skips the output code, which would let the
    note reservations and the LFO and portamento state drift from those of a sounding
    channel.
- **Queue mode:** ticks are processed A ahead, and FM writes are delayed by L to line up
  with the PCM (within 1 ms). A song starts about A + L after `play`.
- **Direct mode:** FM is written at once, and PCM is L behind. L must be about 40 ms so
  that heavy ticks (song start etc.) do not break the PCM.

## 3. Steps

```
1. Load X16MXDRV.BIN into bank D at $A000; init
2. (PCM) pcmmem: the sample banks and the volume table area (once)
3. Load the MDX into bank M at $A000 (it goes on into the next banks); setmdx with its size.
   Read at most as many bytes as the banks set aside hold: KERNAL LOAD does not stop at
   their end (mdxplay reads at most 8 banks with diskio.f_read and refuses a larger file)
4. (PCM) one of:
   a. read a PCM pack (section 4) with loadpack from the include files; use it if the
      song lacks no pairs                                                    <- fast
   b. pdxname for the PDX name; if the PDX file opens: pdxbegin, then pdxfeed the file
      from the start (stop once C=1), then pdxend
5. play. status for the end and the loop count; fadeout / stop
   - bit1 (ended) is set once the queued FM writes and PCM events, the sounding PCM and
     the FIFO lead L are all out. bit4 is set when the sequence ends (in queue mode up to
     A + L before the output)
   - the loop count goes up when the sequence passes the loop point (queue mode: up to
     A + L before the output)
```
- **Another song:** start again from 3; setmdx stops the song playing.
- **While loading:** do not overwrite the MDX bank or the sample banks while playing.
  Stop before loading another song.

## 4. PCM packs (pre-converted)

A `*.P16` file holds the PDX's ADPCM already decoded to 8 bits, with the same arithmetic
as the driver. It loads much faster than decoding the PDX on the X16. The decoded data is
bit-identical, so the PCM output is the same either way (except for packs made with
`--x68filter`).

Decoding applies the X68000's 183 Hz first-order output high-pass (fixed point, state 0
at the start of each sample).

| A PCM-heavy song (225 KB PDX) | Load time |
|---|---|
| Decoding the PDX (emulator, HostFS) | 18.4 s |
| Decoding the PDX (OtterX hardware, SD card) | 21 s |
| Its pack (460 KB), emulator: HostFS / SD card image | 1.1 s / 5.0 s (about the same as KERNAL LOAD) |
| Its pack (460 KB), OtterX hardware, SD card | 2.8 s |

The hardware times were taken with a stopwatch, from pressing Return until the music
starts (2026-11).

### 4.1 Making packs (`tools/mkpack.py`)

```
mkpack.py DIR [-r]                 scan DIR's *.MDX: one shared pack <PDX name>.P16 per PDX (version 2)
mkpack.py A.MDX B.MDX ...          shared packs for the PDX files of these MDX files
mkpack.py X.PDX [A.MDX ...]        a given PDX (no MDX: every sample of the PDX at rate 4)
mkpack.py SONG.MDX [PDX] [-o OUT]  a pack for one song, <SONG>.P16 (version 1)
```
- **Shared packs (version 2):** the union of the (sample, rate) pairs that the songs using
  the PDX need. For example, 34 songs sharing one PDX (31 of them use PCM) need one
  150 KB shared pack, instead of 31 per-song packs totalling 2.9 MB.
- **Names:** take the PDX name in the MDX, drop the path, upper-case it and add `.PDX` if
  there is no `.`. The pack has the extension `P16` instead (`songs` → `SONGS.PDX` →
  `SONGS.P16`). The PDX is looked for in the MDX's folder.
- **Options:**
  - `--all`: add every sample of the PDX at rate 4. Songs added later need no new pack if
    they use rate 4 only (only pairs the pack has); after adding a song that uses another
    rate, `--check` reports the missing pairs: remake the pack.
  - `-r`: also each subfolder, folder by folder. `-d DIR`: output folder.
  - `--check`: write nothing; check that the packs match the current MDX and PDX files
    (missing pairs, a changed PDX).
  - `--max-banks N`: the most sample banks (default 232, mdxplay on a 2 MB machine).
  - `--prune`: delete per-song packs that a shared pack replaces, only where the song
    loses nothing.
  - `--x68filter`: make the pack with the X68000's analog output filters (see "X68000
    filter" below). Sets bit 2 of the header flags. With `--check`, check filtered packs.
- **`--check` and the samples:** it also compares the samples of the pairs the songs need
  with what the current `mkpack.py` makes. Packs from an older tool (before the 183 Hz
  high-pass) or with the other filter setting must be remade. The order of the pairs and
  extra pairs do not matter.
- **X68000 filter (`--x68filter`, needs numpy):**
  - Source of the figures: the X68000's ADPCM output filters as published by Nano Drive 8
    (Fujix1, https://github.com/Fujix1/NanoDrive8). The high-pass is 183 Hz, first order.
    The low-pass response at 10 frequencies is derived from the X68000 CZ-600CE control
    circuit diagram (about -3 dB at 3.9 kHz, -32 dB at 15.625 kHz).
  - This project's fit: the low-pass as 2nd order (3.8 kHz, Q 0.78) x 1st order (7.3 kHz),
    within 0.1 dB of the 10 published points.
  - How it is applied: per rate, a causal minimum-phase FIR (1024 taps) that follows the
    response up to half of the sample's rate, by linear convolution. Before the start of a
    sample, everything is 0.
  - Limits:
    - Nothing above half of each sample's rate is filtered. Playing a sample back at its
      rate holds each value, which adds images above that. On the X68000 the analog
      low-pass removes them too; in these packs they stay (at every rate, 15.6 kHz too: for
      a 3.125 kHz tone, the image at 12.5 kHz is about 25 dB louder than on the X68000).
    - Each sample keeps its length: the filter's ring after the end is cut off.
    - The sound differs from what the X16 decodes from the PDX: the driver has no X68000
      low-pass.
- **After adding songs:** run it on the folder again. With an old pack, `pcmpack` returns
  the number of missing pairs in X.
- **Format:** section 4.4, also at the top of `tools/mkpack.py`.

### 4.2 Reading a pack (`loadpack`)

A pack is a header bank B (8192 bytes) and a sample part of S bytes from bank B+1.
`loadpack` in the include files reads it like this and then calls `pcmpack`:
1. Read the header bank into B; check the version and the sizes.
2. If B + the number of banks goes past the last bank allowed, refuse without reading.
3. Read **exactly S bytes** of samples (MACPTR, up to 512 bytes per call). If the file
   ends early, refuse. If there is more data after S bytes, refuse.
4. Call `pcmpack(B)` with S, the number of bytes read.

| Language | Call |
|---|---|
| prog8 | `mxdrv.loadpack(name, bank, lastbank)` → `mxdrv.PK_*`. `mxdrv.pk_ver` / `pk_pairs` / `pk_missing`. `mxdrv.pdxnames()` sets `mxdrv.pdxfile` (`SONGS.PDX`) and `mxdrv.packfile` (`SONGS.P16`) |
| cc65 | `mxdrv_loadpack(name, bank, lastbank)` → `MXPK_*`. `mxdrv_pkver` / `mxdrv_pkpairs` / `mxdrv_pkmissing`. Uses logical file 14 (device 8) |
| ca65 | Include `driver/include/mxpkread.inc`, open the file, `mxpk_read` (A = B, X = last bank), put `mxpk_s` into r0 / r1L and call `MX_PCMPACK`. Example: `_mxdrv_loadpack` in `driver/include/x16mxdrv_cc65.s` |

Results (the same numbers as `pcmpack`'s Y; the reader's refusals use them too):

| Value | Name | Meaning |
|---|---|---|
| 0 | OK | Registered. If `pk_missing` is 0, the song has every pair it needs |
| 1 | NOTPACK | Not a pack, or an unknown version |
| 2 | RANGE | Goes past the last bank (also past the real RAM, or past the `pcmmem` range) |
| 3 | NOPCM | PCM cannot be used (`pcmmem`) |
| 4 | LENGTH | The file is shorter or longer than its header says |
| 5 | BAD | The header or a pair's location is broken |
| 6 | NOFILE | Could not be read (no file). Nothing was changed |

- **On an error (except NOFILE):** PCM is off for the song. Banks B to the last bank may
  have been written.
- **Missing pairs** (`pk_missing` 1-96 or `$FE`): the song plays, but those sounds are
  silent. If the PDX is there, decoding it is better.
- **Version 1 packs:** missing pairs cannot be told (`$FF`). A pack named after the song can
  be taken as made for it.
- **Device:** it must support MACPTR (SD card, emulator HostFS).
- **Do not read packs with KERNAL LOAD.** LOAD writes up to the end of the file, so a
  file that is too long overwrites memory past the area set aside. For files you trust,
  LOAD can be used; for version 2, pass the bytes read (S = file size − 8192) in r0 / r1L
  to `pcmpack`.

### 4.3 How mdxplay chooses

For each song, mdxplay decides where the PCM comes from in this order (`load_pcm` in
`player/mdxplay.p8`). A game that knows its pack only needs to look at `loadpack`'s
result.
1. Read the PDX-name pack (`SONGS.P16`), then the song-name pack (`SONG.P16`). Use a
   version 2 pack that lacks no pairs, or a version 1 pack named after the song.
2. If neither fits, decode the PDX.
3. If there is no PDX either, use the first pack read that lacks pairs. If another file
   was read after it, read it again.
4. If there is nothing, play FM only.

The NOW PLAYING line shows where the PCM came from (`(P16 SONGS)`, `(PDX)`). Missing
pairs and the like are shown on the bottom line.

### 4.4 Format

```
version 1 (one song), bank B:
   0  'MXPK'   4  version = 1   5  pairs n (up to 96)   6  sample banks nb   7  0
   8  n pairs × 9 bytes: sample lo, sample hi, rate, bank (relative: 0 = B+1),
      addr lo, addr hi ($A000-$BF7F), length (ADPCM bytes, 24-bit little endian)
version 2 (shared), bank B:
   0  'MXPK'   4  version = 2   5  flags (bit0 shared, bit1 --all, bit2 --x68filter; readers ignore them)   6  sample banks nb (1-255)   7  0
   8  pairs n (16-bit)   10  PDX table entries m (16-bit, up to 4096)
  12  sample part bytes S (24-bit; file size − 8192)   15  0
  16  PDX size (24-bit)   19  0   20  PDX CRC32   24  PDX name (12 bytes, upper case, NUL padded)
  36  entries with data: ceil(m / 8) bytes (bit i = PDX entry i has data)
      then n pairs × 9 bytes as in version 1, in (sample, rate) order
banks B+1.. (both versions): every sample is followed by 64 zero bytes. Each bank holds
8064 bytes of samples and a copy of the first 128 bytes of the next bank (not the last
bank, which ends where its data ends)
```
- **Version 2 header checks:** 36 + ceil(m / 8) + 9n ≤ 8192, and
  (nb − 1) × 8192 < S ≤ (nb − 1) × 8192 + 8064.
- **Every pair must point inside the pack:** relative bank < nb, addr − $A000 < 8064, and
  linear position + 2 × length + 64 ≤ S − (nb − 1) × 128.
- **Sample data:** bit-identical to the driver's own decoding of the PDX. Samples are
  decoded independently, so a pair has the same bytes in any pack.
- **Version 1 has no S.** The reader computes it from the pair table:
  (nb − 1) × 8192 + (linear end of the last pair − (nb − 1) × 8064).

## 5. Snapshot (202 bytes)

12 arrays of 16 channels (0-7 FM, 8-15 PCM P-W), then values for the whole song.

| Offset | What |
|---|---|
| +0 / +16 | Pitch low / high (note × 64 + 5 + detune; `>> 6` gives the note; 0 = o0 C#) |
| +32 | Flags (bit3 = key on) |
| +48 | Volume (bit7 = 0: v0-15; 1: the raw @v attenuation) |
| +64 | Pan (FM: bit6 L, bit7 R / PCM: bits 0-1 with 0 and 3 swapped) |
| +80 | Voice number (FM) |
| +96 | Key-on counter (a change means a key on) |
| +112 / +128 | Detune low / high |
| +144 / +160 | Pitch LFO / volume LFO type (0 = none) |
| +176 | PCM bank |
| +192 | Timer-B |
| +193 | Fade amount |
| +194 | Fading |
| +195 | Ended |
| +196 | Loop count (2 bytes) |
| +198 | Ticks (2 bytes) |
| +200 | Channels in use (2 bytes, bit n = channel n) |

It is also updated during interrupts, so the values are not from one exact moment. It is
meant for display.

## 6. Examples

### prog8

```prog8
%import x16mxdrv
...
cx16.rambank(mxdrv.BANK)
void diskio.load_raw(iso:"X16MXDRV.BIN", $a000)
void mxdrv.init()
uword lut = memory("mxlut", 8 * 512, 256)
bool pcm = not mxdrv.pcmmem(22, lsb(cx16.numbanks() - 1), msb(lut), 8)
cx16.rambank(5)                         ; after the driver (banks 1-4)
uword end = diskio.load_raw(iso:"BGM.MDX", $a000)
void mxdrv.setmdx(5, $a000, lsw(diskio.load_size(5, $a000, end)))
if pcm and mxdrv.loadpack(iso:"BGM.P16", 22, lsb(cx16.numbanks() - 1)) != mxdrv.PK_OK
    void mxdrv.loadpdx(memory("pdxbuf", 512, 0), 512)       ; no pack: the PDX
mxdrv.play()
```
Complete examples: `player/mdxplay.p8` (the player) and `demo/stardemo.p8` (a game with
background music).

### ca65

```asm
MXDRV_BANK = 1                  ; the driver in banks 1-4
MDXBANK    = 5
.include "x16mxdrv.inc"
        MXDRV MX_INIT
        lda #<size
        sta $02
        lda #>size
        sta $03
        lda #MDXBANK
        ldx #$00
        ldy #$A0
        MXDRV MX_SETMDX
        MXDRV MX_PLAY
```
Packs: `driver/include/mxpkread.inc`. Streaming a PDX: step 4b in section 3.

### cc65

Complete example: `demo/cc65demo.c`.
```
cl65 -t cx16 -I driver/include \
     game.c driver/include/x16mxdrv_cc65.s
```
`x16mxdrv_cc65.s` includes `mxpkread.inc` (the pack reader) from the same folder.

## 7. Notes

- **Interrupts while playing:** the driver works inside the T1 interrupt with interrupts
  enabled. VERA interrupts (VSYNC etc.) that come while the driver is working are passed
  to the old handler at the next T1 interrupt: within 2 ms, or within 7.7 ms for songs
  without PCM.
- **Songs without PCM** (no PDX, 512 KB machines, …):
  - The T1 period is 1/k of the tick period (k = 1, 2, 4, …; at most 7.7 ms), so the
    interrupts line up with the ticks.
  - This cuts the interrupts from 500 per second to k times the tick rate (150-200 per
    second for most songs).
  - When the tempo changes, the T1 period is switched from that tick on.
- **Your own IRQ handler:** install it before `play`, and the driver chains to it. If you
  replace CINV after `play`, chain to the old value (the driver).
- **Waiting for a frame:** prog8's `sys.waitvsync()` is `WAI`, which also returns on the
  driver's interrupts. To wait for a frame, wait until the jiffy clock (RDTIM) changes
  (`main.vsync` in `player/mdxplay.p8`).
- **Long playback:** the internal clock is 24-bit and wraps after about 18 minutes, but it
  is compared by differences, so this is fine.
- **Tested on hardware (2026-11):** OtterX (an FPGA with a YM2151-compatible core,
  3.58 MHz). Machines with a YM2164 have not been tested.
