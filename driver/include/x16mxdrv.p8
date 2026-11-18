; x16mxdrv.p8 - prog8 interface to X16MXDRV.BIN (driver/src/mx16.s)
; Leave golden RAM $0400-$07FF to the driver. No zero page needs to be reserved: the driver
; borrows $02-$1D (cx16.r0-r13) while it runs and puts the values back. Load X16MXDRV.BIN headerless to $A000 of
; RAM bank mxdrv.BANK (it occupies banks BANK..BANK+3) before calling init().

%import diskio

mxdrv {
    const ubyte BANK = 1

    ; -> YM chip (0 unknown, 1 YM2164, 2 YM2151), CPU MHz, OPM clock (0 3.58 MHz, 1 4 MHz, $ff unknown)
    extsub @bank BANK $A000 = init() -> ubyte @A, ubyte @X, ubyte @Y
    ; MDX file loaded at bank:addr ($A000-$BFFF), size in bytes. Returns true on error.
    extsub @bank BANK $A003 = setmdx(ubyte bank @A, uword addr @XY, uword size @R0) clobbers(A, X, Y) -> bool @Pc
    extsub @bank BANK $A006 = play() clobbers(A, X, Y)
    extsub @bank BANK $A009 = stop() clobbers(A, X, Y)
    extsub @bank BANK $A00C = fadeout(ubyte speed @A) clobbers(A, X, Y)
    ; -> flags (bit0 playing, bit1 ended, bit2 fading, bit3 PCM on), loop count
    extsub @bank BANK $A00F = status() -> ubyte @A, uword @XY
    ; -> bank and address of the title (Shift_JIS, ends with $0d)
    extsub @bank BANK $A012 = title() -> ubyte @A, uword @XY
    extsub @bank BANK $A015 = ticks() -> uword @XY
    ; option 0: YM chip override, 1: pitch offset, 2: ticks per IRQ run, 3: PCM voices (1-8),
    ; 4: latency L (x4 samples), 5: mute (1 FM, 2 PCM), 6: mode (0 direct, 1 queue), 7: lookahead (x4 samples),
    ; 8: tick clock, 9: channel mute mask FM (bit n = FM n), 10: channel mute mask PCM (bit n = P+n)
    extsub @bank BANK $A018 = setopt(ubyte option @A, ubyte value @X) clobbers(A, X, Y)
    ; sample banks first..last, volume LUT area: page of slots*512 bytes (256-aligned, slots 4..16)
    ; Returns true if PCM is not possible (512 KB machine, bad arguments).
    extsub @bank BANK $A01B = pcmmem(ubyte first @A, ubyte last @X, ubyte lutpage @Y, uword slots @R0) clobbers(A, X, Y) -> bool @Pc
    ; -> bank and address of the PDX name in the MDX (0-terminated), true if none
    extsub @bank BANK $A01E = pdxname() -> ubyte @A, uword @XY, bool @Pc
    ; -> (sample, rate) pairs to load (0 = none)
    extsub @bank BANK $A021 = pdxbegin() clobbers(X, Y) -> ubyte @A
    ; the next bytes of the PDX file -> true when everything needed has been received
    extsub @bank BANK $A024 = pdxfeed(uword buf @XY, uword size @R0) clobbers(A, X, Y) -> bool @Pc
    ; -> pairs that could not be loaded, pairs loaded, 1 if the song has more than 96 pairs
    extsub @bank BANK $A027 = pdxend() -> ubyte @A, ubyte @X, ubyte @Y
    ; -> active voices, FIFO underruns
    extsub @bank BANK $A02A = pcmstat() -> ubyte @A, uword @XY
    ; copy the display state (202 bytes, layout in driver/src/mx16.s) to buf
    extsub @bank BANK $A02D = snapshot(uword buf @XY) clobbers(A, X, Y)
    ; PDX load progress: cx16.r0 = bytes read / 256, cx16.r1 = needed end / 256 (0 = unknown)
    extsub @bank BANK $A030 = pdxprog() clobbers(A, X, Y)
    ; PCM pack at $A000 of bank (header; samples from bank+1), r0 + r1L = the sample bytes read
    ; (version 2) -> pairs registered, pairs missing (0-96; $fe/$ff: not known), PK_* result,
    ; true on error. Use loadpack(): it reads the file safely and passes the size.
    extsub @bank BANK $A033 = pcmpack(ubyte bank @A, uword sizelo @R0, uword sizehi @R1) -> ubyte @A, ubyte @X, ubyte @Y, bool @Pc

    ubyte[64] pdxfile               ; pdxnames: "SONGS.PDX"
    ubyte[64] packfile              ; pdxnames: "SONGS.P16"

    ; pdxnames: the PDX of the current song (after setmdx): pdxfile = its name in the MDX
    ;   without a path, upper case, with .PDX added if it has no '.'; packfile = the same name
    ;   with the extension P16 (tools/mkpack.py names shared packs so). false: no PDX.
    sub pdxnames() -> bool {
        pdxfile[0] = 0
        packfile[0] = 0
        ubyte bank
        uword addr
        bool none
        bank, addr, none = pdxname()
        if none
            return false
        ubyte oldbank = cx16.getrambank()
        cx16.rambank(bank)
        ubyte n = 0
        ubyte dot = 255
        ubyte i
        for i in 0 to 254 {
            ubyte c = @(addr + i)
            if c == 0
                break
            if c == $5c or c == $3a or c == $2f {   ; '\', ':', '/': drop the path
                n = 0
                dot = 255
            } else if n < 59 {
                if c == $2e
                    dot = n
                if c >= $61 and c <= $7a
                    c -= $20
                pdxfile[n] = c
                n++
            }
        }
        cx16.rambank(oldbank)
        if n == 0
            return false
        if dot == 255 {
            dot = n
            pdxfile[n] = $2e                ; ".PDX"
            pdxfile[n + 1] = $50
            pdxfile[n + 2] = $44
            pdxfile[n + 3] = $58
            n += 4
        }
        pdxfile[n] = 0
        n = 0
        while n < dot {
            packfile[n] = pdxfile[n]
            n++
        }
        packfile[n] = $2e                   ; ".P16"
        packfile[n + 1] = $50
        packfile[n + 2] = $31
        packfile[n + 3] = $36
        packfile[n + 4] = 0
        return true
    }

    ; ---- loadpdx: stream the PDX named in the current MDX into the sample banks.
    ;   buf: low RAM read buffer of bufsize bytes. Returns the number of pairs loaded (0: no PCM).
    ;   missing = pairs that did not fit / were not in the file; 255: the PDX could not be opened
    ;   (the song's PCM is left as it was). over = 1: the song has more than 96 pairs.
    ubyte missing
    ubyte over
    uword progress = 0              ; optional: subroutine called after every piece of the PDX

    ; percentage of the needed PDX data received so far (0..100, 255 = not known yet)
    sub pdxpercent() -> ubyte {
        pdxprog()
        if cx16.r1 == 0
            return 255
        if cx16.r0 >= cx16.r1
            return 100
        return lsb(((cx16.r0 as long) * 100) / cx16.r1)
    }

    sub loadpdx(uword buf, uword bufsize) -> ubyte {
        missing = 0
        over = 0
        if not pdxnames()
            return 0
        if not diskio.f_open(&pdxfile) {
            missing = 255
            return 0
        }
        if pdxbegin() == 0 {
            diskio.f_close()
            return 0
        }
        repeat {
            uword n = diskio.f_read(buf, bufsize)
            if n == 0
                break
            if pdxfeed(buf, n)
                break
            if progress != 0
                void call(progress)
        }
        diskio.f_close()
        ubyte loaded
        missing, loaded, over = pdxend()
        return loaded
    }

    ; ---- PCM packs (*.P16, tools/mkpack.py; docs/api.md)
    const ubyte PK_OK = 0
    const ubyte PK_NOTPACK = 1      ; not a pack, or an unknown version
    const ubyte PK_RANGE = 2        ; does not fit in bank..lastbank
    const ubyte PK_NOPCM = 3        ; PCM not possible (pcmmem)
    const ubyte PK_LENGTH = 4       ; the file is shorter or longer than its header says
    const ubyte PK_BAD = 5          ; the header or an entry is damaged
    const ubyte PK_NOFILE = 6       ; nothing could be read (no such file): nothing changed

    ubyte pk_ver                    ; loadpack: version 1 (per song) or 2 (shared)
    ubyte pk_pairs                  ; loadpack: (sample, rate) pairs registered for the song
    ubyte pk_missing                ; loadpack: pairs the song needs that the pack does not have:
                                    ;   0-96; $fe: the song has more than 96 (not known);
                                    ;   $ff: version 1 (not known)
    ubyte pk_long                   ; loadpack PK_LENGTH: 1 if the file is longer than declared
    long pk_size                    ; loadpack: sample bytes (S)
    ubyte pk_one

    ; loadpack: read the pack file name into RAM banks bank..lastbank (header in bank, samples
    ;   from bank+1) and use it for the current song (after setmdx). Only the size its header
    ;   declares is read: a shorter or longer file, or one that does not fit in lastbank, is
    ;   refused. -> PK_OK, or an error: then the song has no PCM (banks bank..lastbank may have
    ;   been written), except PK_NOFILE (nothing was read, nothing changed).
    ;   The device must support MACPTR (SD card, HostFS).
    sub loadpack(str name, ubyte bank, ubyte lastbank) -> ubyte {
        pk_ver = 0
        pk_pairs = 0
        pk_missing = 0
        pk_long = 0
        pk_size = 0
        ubyte oldbank = cx16.getrambank()
        if not diskio.f_open(name)
            return PK_NOFILE
        diskio.reset_read_channel()
        ubyte r = pk_read(bank, lastbank)
        diskio.f_close()
        if r == PK_OK {
            ubyte a
            ubyte x
            ubyte y
            bool err
            a, x, y, err = pcmpack(bank, lsw(pk_size), msw(pk_size))
            if err {
                r = y
                if r == PK_OK
                    r = PK_NOTPACK          ; (an older driver)
            } else {
                pk_pairs = a
                pk_missing = x
            }
        } else if r != PK_NOFILE {
            ; refused after writing: no PCM for the song (pcmpack fails on a header that is not
            ; a pack, and clears)
            cx16.rambank(bank)
            @($a000) = 0
            void pcmpack(bank, 0, 0)
        }
        cx16.rambank(oldbank)
        return r
    }

    sub pk_read(ubyte bank, ubyte lastbank) -> ubyte {
        cx16.rambank(bank)
        long left = pk_get(8192)
        if left != 0 {
            if left == 8192
                return PK_NOFILE
            return PK_LENGTH
        }
        cx16.rambank(bank)
        if @($a000) != $4d or @($a001) != $58 or @($a002) != $50 or @($a003) != $4b
            return PK_NOTPACK
        pk_ver = @($a004)
        if pk_ver != 1 and pk_ver != 2
            return PK_NOTPACK
        ubyte nb = @($a006)
        if nb == 0
            return PK_BAD
        if pk_ver == 2 {
            pk_size = mkword(@($a00d), @($a00c)) as long + (@($a00e) as long) * 65536
        } else {
            ; version 1: (nb - 1) * 128 + the largest linear end of an entry (no entries: 0)
            ubyte n = @($a005)
            if n > 96
                return PK_BAD
            uword e = $a008
            repeat n {
                long t = (@(e + 3) as long) * 8064 + (mkword(@(e + 5), @(e + 4)) - $a000) as long
                t += (mkword(@(e + 7), @(e + 6)) as long + (@(e + 8) as long) * 65536) * 2 + 64
                if t > pk_size
                    pk_size = t
                e += 9
            }
            if pk_size != 0
                pk_size += ((nb - 1) as long) * 128
        }
        if pk_ver == 2 or pk_size != 0 {
            ; (nb - 1) * 8192 < S <= (nb - 1) * 8192 + 8064
            long d = pk_size - ((nb - 1) as long) * 8192
            if d < 1 or d > 8064
                return PK_BAD
        }
        if (bank as uword) + nb > lastbank
            return PK_RANGE
        cx16.rambank(bank + 1)
        if pk_get(pk_size) != 0
            return PK_LENGTH
        if cbm.READST() & $40 == 0 {
            ; not at the end of the file: one more byte means a longer file
            bool unsup
            uword got
            unsup, got = cx16.MACPTR(1, &pk_one, false)
            if not unsup and got != 0 {
                pk_long = 1
                return PK_LENGTH
            }
        }
        return PK_OK
    }

    ; pk_get: read n bytes to $a000 of the selected bank and on -> bytes not read (0: all)
    sub pk_get(long n) -> long {
        uword addr = $a000
        while n > 0 {
            ubyte c = 0                     ; up to 512 bytes, the KERNAL decides
            if n < 512 {
                c = 255
                if n < 255
                    c = lsb(lsw(n))
            }
            bool unsup
            uword got
            unsup, got = cx16.MACPTR(c, addr, false)
            if unsup or got == 0
                break
            n -= got
            addr += got
            if addr >= $c000
                addr -= $2000               ; MACPTR went on in the next bank
            if n > 0 and cbm.READST() & $40 != 0
                break
        }
        return n
    }
}
