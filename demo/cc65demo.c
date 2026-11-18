/* cc65demo.c - X16MXDRV from C (cc65): load the driver, TEST.MDX and its PCM pack TEST.P16
 * (mxdrv_loadpack), play until the first loop / the end, print the result. Also the cc65 glue
 * test.
 *
 * cl65 -t cx16 -I driver/include \
 *      demo/cc65demo.c driver/include/x16mxdrv_cc65.s
 */
#include <stdio.h>
#include <cbm.h>
#include <cx16.h>
#include <peekpoke.h>
#include "x16mxdrv.h"

/* RAM bank register. Older cc65 releases define RAM_BANK in cx16.h as VIA1 port A (early
   X16 prototypes; their waitvsync() relies on it too); current hardware has it at $0000. */
#define BANK     (*(volatile unsigned char *)0x00)

#define MDXBANK  5                       /* (the driver: banks 1-4) */
#define PCMBANK  7
#define LUTPAGE  0x80                   /* $8000-$8FFF: 8 volume LUT slots */

static unsigned load(const char *name, unsigned char bank)
{
    /* headerless load (secondary address 2) to $A000 of bank, continuing into the next banks */
    BANK = bank;
    cbm_k_setlfs(1, 8, 2);
    cbm_k_setnam(name);
    return cbm_k_load(0, 0xA000);
}

static void quit(void)
{
    if (PEEK(0x9FBE) == '1')            /* x16emu: exit */
        __asm__("jmp $ffff");
}

int main(void)
{
    unsigned end, size, loops;
    unsigned char chip, st, r;

    if (load("x16mxdrv.bin", 1) == 0xA000) { puts("no driver"); quit(); return 1; }
    mxdrv_bank = 1;
    chip = mxdrv_init();
    printf("cc65 demo: chip %u, %u mhz, clock %u\n", chip, mxdrv_mhz, mxdrv_clock);

    end = load("test.mdx", MDXBANK);
    size = (BANK - MDXBANK) * 8192u + (end - 0xA000);
    if (mxdrv_setmdx(MDXBANK, (void *)0xA000, size)) { puts("not an mdx"); quit(); return 1; }
    if (mxdrv_pcmmem(PCMBANK, 63, LUTPAGE, 8) == 0) {
        /* (tests: GOOD.P16, if there, is registered first; nothing may stay of it
           when TEST.P16 is refused) */
        if ((r = mxdrv_loadpack("good.p16", PCMBANK, 63)) != MXPK_NOFILE)
            printf("cc65 pack r=%u v=%u pairs=%u missing=%u\n", r, mxdrv_pkver, mxdrv_pkpairs,
                   mxdrv_pkmissing);
        r = mxdrv_loadpack("test.p16", PCMBANK, 63);
        printf("cc65 pack r=%u v=%u pairs=%u missing=%u\n", r, mxdrv_pkver, mxdrv_pkpairs,
               mxdrv_pkmissing);
    }
    mxdrv_play();
    do {
        st = mxdrv_status(&loops);
    } while (!(st & MXST_ENDED) && loops == 0);
    mxdrv_stop();
    printf("cc65 ticks=%u status=%u pcm=%u\n", mxdrv_ticks(), st, (st & MXST_PCM) != 0);
    quit();
    return 0;
}
