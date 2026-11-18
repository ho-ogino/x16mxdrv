/* x16mxdrv.h - cc65 interface to X16MXDRV.BIN (docs/api.md)
 *
 * Link driver/include/x16mxdrv_cc65.s (the standard cx16 target config is fine: the driver has
 * no zero page of its own; it borrows $02-$1D and restores it). Load X16MXDRV.BIN headerless to $A000 of
 * RAM bank mxdrv_bank (default 1; 4 banks) before mxdrv_init(). Golden RAM $0400-$07FF
 * belongs to the driver.
 */
#ifndef X16MXDRV_H
#define X16MXDRV_H

extern unsigned char mxdrv_bank;        /* RAM bank of X16MXDRV.BIN (default 1) */
extern unsigned char mxdrv_mhz;         /* set by mxdrv_init: CPU MHz */
extern unsigned char mxdrv_clock;       /* set by mxdrv_init: 0 = 3.58 MHz, 1 = 4 MHz OPM */

#define MXST_PLAYING 0x01
#define MXST_ENDED   0x02
#define MXST_FADING  0x04
#define MXST_PCM     0x08
#define MXST_SEQEND  0x10   /* sequence ended (MXST_ENDED: and everything played) */

#define MXOPT_CHIP    0
#define MXOPT_PITCH   1
#define MXOPT_K       2
#define MXOPT_VOICES  3
#define MXOPT_LATENCY 4
#define MXOPT_MUTE    5
#define MXOPT_MODE    6
#define MXOPT_AHEAD   7
#define MXOPT_TICKCLK 8   /* songs without PCM: 1 = T1 per tick (default), 0 = 2 ms */
#define MXOPT_FMMASK  9   /* mute: bit n = FM channel n (kept across songs) */
#define MXOPT_PCMMASK 10  /* mute: bit n = PCM channel P+n */

/* -> YM chip: 1 YM2164, 2 YM2151, 0 unknown */
unsigned char __fastcall__ mxdrv_init(void);
/* MDX file loaded at bank:addr ($A000-$BFFF), size bytes. -> 0 ok, 1 not an MDX */
unsigned char __fastcall__ mxdrv_setmdx(unsigned char bank, const void *addr, unsigned size);
void __fastcall__ mxdrv_play(void);
void __fastcall__ mxdrv_stop(void);
void __fastcall__ mxdrv_fadeout(unsigned char speed);
/* -> MXST_* flags; *loops = loop count ($FFFF after the end) */
unsigned char __fastcall__ mxdrv_status(unsigned *loops);
unsigned __fastcall__ mxdrv_ticks(void);
void __fastcall__ mxdrv_setopt(unsigned char option, unsigned char value);
/* PCM memory: sample banks first..last, volume LUTs at page lutpage (slots * 512 bytes,
   256-aligned, slots 4..16). -> 0 ok, 1 PCM not possible (512 KB, bad arguments) */
unsigned char __fastcall__ mxdrv_pcmmem(unsigned char first, unsigned char last,
                                        unsigned char lutpage, unsigned char slots);
/* PCM packs (tools/mkpack.py *.P16, docs/api.md) */
#define MXPK_OK      0
#define MXPK_NOTPACK 1  /* not a pack, or an unknown version */
#define MXPK_RANGE   2  /* does not fit in bank..lastbank */
#define MXPK_NOPCM   3  /* PCM not possible (mxdrv_pcmmem) */
#define MXPK_LENGTH  4  /* the file is shorter or longer than its header says */
#define MXPK_BAD     5  /* the header or an entry is damaged */
#define MXPK_NOFILE  6  /* nothing could be read (no such file): nothing changed */
extern unsigned char mxdrv_pkver;       /* mxdrv_loadpack: version 1 (per song) or 2 (shared)
                                           (0: no header was read) */
extern unsigned char mxdrv_pkpairs;     /* (sample, rate) pairs registered for the song */
extern unsigned char mxdrv_pkmissing;   /* pairs the song needs that the pack does not have:
                                           0-96; 0xFE the song has more than 96 (not known);
                                           0xFF version 1 (not known) */
/* Read the pack NAME into RAM banks bank..lastbank (header in bank, samples from bank + 1;
   exactly the size its header declares: shorter or longer files and packs that do not fit are
   refused) and use it for the song set by mxdrv_setmdx. -> MXPK_*. After an error other than
   MXPK_NOFILE the song has no PCM (banks bank..lastbank may have been written).
   Uses logical file 14 (secondary address 14) on device 8; the device must support MACPTR. */
unsigned char __fastcall__ mxdrv_loadpack(const char *name, unsigned char bank,
                                          unsigned char lastbank);
/* the driver call itself, for a version 1 pack already in RAM at $A000 of bank (version 2
   needs the bytes read: use mxdrv_loadpack). -> pairs, 255 on error */
unsigned char __fastcall__ mxdrv_pcmpack(unsigned char bank);
/* PDX streaming: begin -> pairs needed (0: nothing to load, 255: no PCM);
   feed the file in pieces -> 1 when all needed data was received; end -> pairs loaded,
   *missing = pairs that could not be loaded, mxdrv_pdxover = 1 if the song has more than 96
   pairs (the ones after them are not loaded) */
extern unsigned char mxdrv_pdxover;
unsigned char __fastcall__ mxdrv_pdxbegin(void);
unsigned char __fastcall__ mxdrv_pdxfeed(const void *buf, unsigned len);
unsigned char __fastcall__ mxdrv_pdxend(unsigned char *missing);
/* PDX name in the MDX: -> 1 if present, *bank / *addr set */
unsigned char __fastcall__ mxdrv_pdxname(unsigned char *bank, void **addr);
/* -> active PCM voices; *underruns */
unsigned char __fastcall__ mxdrv_pcmstat(unsigned *underruns);
/* 202-byte display state (layout in docs/api.md) */
void __fastcall__ mxdrv_snapshot(void *buf);

#endif
