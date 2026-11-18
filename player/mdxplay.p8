; mdxplay.p8 - MDX player for the Commander X16 (M5: MMDSP-like screen)
;
;   up/down: select   left/right: page up/down   return: play / open the folder
;   del: the folder above   space: stop   f: fade out   n/p: next/previous
;   a: auto (next song after the loops)   r: repeat the song   s: shuffle   </>: loops
;   q: quit
;   1-8: mute FM 1-8, SHIFT or CTRL + 1-8: mute PCM P-W, 9: all on, 0: all off, -: flip all
;   (the digit row is read by key number: the same keys on every layout)
;
; Screen (80x60): layer 1 = KERNAL text (ISO charset + custom glyphs $80-$9F),
; layer 0 = 2bpp tiles under it: keyboards, level bars and Shift_JIS text (Misaki 8x8).
; Colors: block "theme". RAM banks: 1-4 X16MXDRV.BIN, 5-12 MDX, 13-21 KANJI8.BIN,
; 22 titles, 23- PCM samples.
; Folders: the list is ".." (not at the top), the folders, the MDX files,
; each in name order (case ignored). The song plays on in other folders; the next song (N / P,
; auto) is taken from the list shown (shuffle: block shuf).

%import textio
%import diskio
%import palette
%import math
%import x16mxdrv
%zeropage basicsafe

; ---------------------------------------------------------------------------
; colors: change here
theme {
    ; layer 1 text: palette entries 1..15 are redefined (12-bit RGB)
    const ubyte TEXT = 1            ; values
    const ubyte LABEL = 2           ; labels
    const ubyte DIM = 3             ; separator lines, inactive
    const ubyte WHITE = 4           ; file names, selection
    const ubyte KEYON = 5           ; key-on marks
    const ubyte WARN = 6            ; errors, warnings
    const ubyte HEAD = 7            ; headings
    const ubyte KNOB = 8            ; panpot knobs
    uword[16] rgb = [$000, $aaf, $77c, $447, $fff, $5e5, $f66, $99f, $ccf,
                     $888, $888, $888, $888, $888, $888, $888]
    ; layer 0: palette offsets; colors for pixel values 1, 2, 3 of each
    const ubyte P_TITLE = 1         ; now playing title
    const ubyte P_SEL = 2           ; selector titles
    const ubyte P_CUR = 3           ; selected entry
    const ubyte P_KB = 4            ; keyboards: white key, black key, pressed key
    const ubyte P_BAR = 5           ; level bars: dark line, lit line, peak line
    uword[15] l0rgb = [$fff, $fff, $fff,
                       $99d, $99d, $99d,
                       $fff, $fff, $fff,
                       $eee, $335, $3e3,
                       $226, $77f, $fff]
}

main {
    const ubyte MDXBANK = 5
    const ubyte PCMFIRST = 23
    const ubyte LUTSLOTS = 8
    const bool AUTOTEST = false     ; tests: play the first song once, print ticks, exit x16emu
    const uword AUTOFRAMES = 0      ; (AUTOTEST) stop after this many frames, 0 = at the end
                                    ;   (looping songs: 10 frames after the first loop)
    const ubyte AUTOPROG = 0        ; (tests) exit x16emu at this PDX progress call, 0 = never
    const bool AUTOKEYS = false     ; (AUTOTEST) feed the mute keys to the key handler first
    const ubyte AUTONAV = 0         ; (AUTOTEST) the keys of script AUTONAV instead of playing

    bool playing = false            ; a song is playing (maybe from another folder)
    ubyte playing_idx = 255         ; its entry in the list shown (255: not in it)
    ubyte[64] playname              ; its file name and folder
    ubyte[81] playdir
    bool pcm = false
    ubyte lastbank                  ; last RAM bank (PCM: PCMFIRST..lastbank)
    uword mdxsize
    uword pdxbuf
    bool auto_next = true
    bool repeat_song = false
    bool shuffle = false
    ubyte plays                     ; songs started (AUTOTEST: nav waits for the next one)
    ubyte loops_max = 2
    bool fading = false
    uword start_jiffy
    ubyte chip
    ubyte mhz
    ubyte clk

    sub start() {
        txt.iso()
        txt.color2(1, 0)
        txt.clear_screen()
        cbm.SETMSG(0)                   ; no KERNAL "LOADING FROM ..." messages
        theme_init()
        scr.print(0, 0, iso:"X16MXDRV loading...", theme.HEAD)
        cx16.rambank(mxdrv.BANK)
        if diskio.load_raw(iso:"X16MXDRV.BIN", $a000) == 0 {
            scr.print(0, 1, iso:"cannot load X16MXDRV.BIN", theme.WARN)
            return
        }
        cx16.rambank(kanji.FONTBANK)
        bool font = diskio.load_raw(iso:"KANJI8.BIN", $a000) != 0
        chip, mhz, clk = mxdrv.init()
        uword banks = cx16.numbanks()
        uword lut = memory("mxlut", LUTSLOTS as uword * 512, 256)
        pdxbuf = memory("pdxbuf", 512, 0)
        lastbank = lsb(banks - 1)
        if banks > PCMFIRST + 8
            pcm = not mxdrv.pcmmem(PCMFIRST, lastbank, msb(lut), LUTSLOTS)
        mxdrv.progress = &ui.pdx_progress

        ui.init(font)
        sel.scan(0)
        keys.install()
        if AUTOTEST and AUTONAV == 0 {
            if AUTOKEYS
                keys.selftest()
            if sel.first == sel.count {
                txt.print(iso:"NO MDX")
                %asm {{
                    jmp $ffff
                }}
            }
            play_song(sel.first)
            uword frames = 0
            ubyte tail = 0
            repeat {
                frames++
                if AUTOFRAMES != 0 and frames == AUTOFRAMES
                    break
                vsync()
                ui.frame()
                ubyte ast
                uword aloops
                ast, aloops = mxdrv.status()
                if ast & 2 != 0
                    break                   ; played to the end
                ; looped (the sequence ends with the loop count $ffff: wait for the end then)
                if ast & $10 == 0 and aloops != 0 {
                    tail++
                    if tail == 10
                        break
                }
            }
            ubyte pst
            uword ploops
            pst, ploops = mxdrv.status()
            mxdrv.stop()
            txt.color2(1, 0)
            txt.plot(0, 59)
            if pst & 8 != 0
                txt.print(iso:"PCM ON")
            else
                txt.print(iso:"PCM OFF")
            if pst & 2 != 0
                txt.print(iso:" END=01")
            else
                txt.print(iso:" END=00")
            ubyte avoices
            uword aunder
            avoices, aunder = mxdrv.pcmstat()
            txt.print(iso:" UNDERRUNS=")
            txt.print_uw(aunder)
            txt.print(iso:" AUTOTEST TICKS ")
            txt.print_uw(mxdrv.ticks())
            %asm {{
                jmp $ffff
            }}
        }
        repeat {
            vsync()
            ui.frame()
            ubyte key
            if AUTOTEST
                key = nav.key()
            else
                key = cbm.GETIN2()
            when key {
                $91 -> sel.move(-1)
                $11 -> sel.move(1)
                $9d -> sel.move(-(sel.ROWS as byte))
                $1d -> sel.move(sel.ROWS as byte)
                $0d -> sel.enter()
                $14 -> sel.up()
                ' ' -> stop_song()
                iso:'f', iso:'F' -> {
                    mxdrv.fadeout(0)
                    fading = true
                }
                iso:'n', iso:'N' -> next_song(1)
                iso:'p', iso:'P' -> next_song(-1)
                iso:'a', iso:'A' -> {
                    auto_next = not auto_next
                    ui.modes()
                }
                iso:'r', iso:'R' -> {
                    repeat_song = not repeat_song
                    ui.modes()
                }
                iso:'s', iso:'S' -> {
                    shuffle = not shuffle
                    if shuffle {
                        math.rndseed(cbm.RDTIM16(), mxdrv.ticks())
                        shuf.build()
                    }
                    ui.modes()
                }
                '>' -> {
                    if loops_max < 9
                        loops_max++
                    ui.modes()
                }
                '<' -> {
                    if loops_max > 1
                        loops_max--
                    ui.modes()
                }
                iso:'q', iso:'Q' -> {
                    mxdrv.stop()
                    keys.uninstall()
                    ui.done()
                    return
                }
            }
            while keys.qr != keys.qw
                mute_key(keys.take())
            if playing {
                ubyte st
                uword loops
                st, loops = mxdrv.status()
                if st & 2 != 0 {
                    if repeat_song
                        restart_song()
                    else if auto_next and sel.first < sel.count
                        next_song(1)
                    else
                        stop_song()
                } else if not repeat_song and auto_next and not fading and loops >= loops_max and loops != $ffff {
                    mxdrv.fadeout(0)
                    fading = true
                }
            }
        }
    }

    ; channel mute (setopt 9 / 10; the driver keeps the masks across songs)
    ubyte mute_fm                   ; bit n: FM n+1 muted
    ubyte mute_pcm                  ; bit n: PCM P+n muted

    ; a digit-row key from keys: key number | $80 with SHIFT or CTRL
    sub mute_key(ubyte k) {
        ubyte code = k & $7f
        when code {
            $0a -> {                    ; 9: all on
                mute_fm = 0
                mute_pcm = 0
            }
            $0b -> {                    ; 0: all off
                mute_fm = $ff
                mute_pcm = $ff
            }
            $0c -> {                    ; -: flip all
                mute_fm ^= $ff
                mute_pcm ^= $ff
            }
            else -> {                   ; 1-8
                ubyte b = 1 << (code - 2)
                if k & $80 != 0
                    mute_pcm ^= b
                else
                    mute_fm ^= b
            }
        }
        sys.irqsafe_set_irqd()          ; both masks for the same tick (the worker runs in the IRQ)
        mxdrv.setopt(9, mute_fm)
        mxdrv.setopt(10, mute_pcm)
        sys.irqsafe_clear_irqd()
        ui.mutelabels()
    }

    sub muted(ubyte i) -> bool {
        if i < 8
            return mute_fm & (1 << i) != 0
        return mute_pcm & (1 << (i - 8)) != 0
    }

    sub theme_init() {
        ubyte i
        for i in 1 to 15
            palette.set_color(i, theme.rgb[i])
        for i in 0 to 4 {
            palette.set_color((i + 1) * 16 + 1, theme.l0rgb[i * 3])
            palette.set_color((i + 1) * 16 + 2, theme.l0rgb[i * 3 + 1])
            palette.set_color((i + 1) * 16 + 3, theme.l0rgb[i * 3 + 2])
        }
    }

    ; wait for the next jiffy (VSYNC). sys.waitvsync() is just WAI, which also returns on
    ; the driver's 2 ms timer interrupts.
    sub vsync() {
        ubyte j = lsb(cbm.RDTIM16())
        while lsb(cbm.RDTIM16()) == j
            sys.waitirq()
    }

    ; N / P / auto: the next / previous MDX of the list shown (the one at the cursor, or the
    ; first, if the song playing is not in it; shuffle: the table's); nothing if the list has none
    sub next_song(byte dir) {
        if sel.first >= sel.count
            return
        if shuffle {
            ubyte k
            if dir > 0
                k = shuf.next()
            else
                k = shuf.prev()
            if k != 255 {
                sel.select(k)
                play_song(k)
            }
            return
        }
        ubyte i = playing_idx
        if i == 255 {
            i = sel.cur
            if i < sel.first
                i = sel.first
        } else if dir > 0 {
            i++
            if i >= sel.count
                i = sel.first
        } else {
            if i == sel.first
                i = sel.count - 1
            else
                i--
        }
        sel.select(i)
        play_song(i)
    }

    ; repeat: the song again from the start (loaded: it may be from another folder)
    sub restart_song() {
        mxdrv.stop()
        fading = false
        mxdrv.play()
        start_jiffy = cbm.RDTIM16()
    }

    ubyte[64] pack
    ; pack = MDX file name with the extension P16 (the song's own pack)
    sub packname(str mdx) {
        ubyte i = 0
        ubyte dot = 255
        while mdx[i] != 0 and i < 59 {
            pack[i] = mdx[i]
            if mdx[i] == '.'
                dot = i
            i++
        }
        if dot == 255 {
            dot = i
            pack[dot] = '.'
        }
        pack[dot + 1] = iso:'P'
        pack[dot + 2] = '1'
        pack[dot + 3] = '6'
        pack[dot + 4] = 0
    }

    ; load_mdx: the file into banks MDXBANK.. (8 banks, at most 65535 bytes) -> 0 ok (mdxsize),
    ; 1 cannot read, 2 too large (refused while reading: nothing past the 8 banks is written)
    sub load_mdx(uword name) -> ubyte {
        if not diskio.f_open(name)
            return 1
        cx16.rambank(MDXBANK)
        mdxsize = diskio.f_read($a000, 65535)
        ubyte[2] extra                  ; (2: a block read, which counts the bytes really read;
        ubyte more = 0                  ; reading 1 byte reports 1 at the end of the file too)
        if mdxsize == 65535
            more = lsb(diskio.f_read(&extra, 2))
        diskio.f_close()
        if more != 0
            return 2
        if mdxsize == 0
            return 1
        return 0
    }

    sub stop_song() {
        mxdrv.stop()
        playing = false
        playing_idx = 255
        fading = false
        sel.draw()
    }

    sub play_song(ubyte idx) {
        mxdrv.stop()
        playing = false
        playing_idx = 255
        fading = false
        ui.clear_song()                 ; the screen goes back to its idle state first
        ui.status(iso:"loading MDX...", theme.HEAD)
        ubyte lr = load_mdx(sel.nameptrs[idx])
        if lr == 0 {
            if mxdrv.setmdx(MDXBANK, $a000, mdxsize)
                lr = 3
        }
        if lr != 0 {
            if AUTOTEST {
                txt.print(iso:"MDXLOAD ")
                txt.print_ub(lr)
                txt.nl()
            }
            when lr {
                1 -> ui.status(iso:"load error", theme.WARN)
                2 -> ui.status(iso:"MDX too large (64 KB max)", theme.WARN)
                else -> ui.status(iso:"not an MDX file", theme.WARN)
            }
            return
        }
        ui.nowplaying_name(idx)
        ubyte loaded = 0
        src = SRC_NONE
        warn = W_NONE
        bool haspdx = mxdrv.pdxnames()
        if pcm and haspdx {
            ui.status(iso:"loading PCM", theme.HEAD)
            loaded = load_pcm(idx)
        }
        if AUTOTEST {
            txt.print(iso:"PCMSRC ")
            when src {
                SRC_PACK -> txt.print(&srcname)
                SRC_PDX -> txt.print(iso:"PDX")
                else -> txt.print(iso:"NONE")
            }
            txt.print(iso:" V=")
            txt.print_ub(src_ver)
            txt.print(iso:" A=")
            txt.print_ub(loaded)
            txt.print(iso:" X=")
            txt.print_ub(src_missing)
            txt.print(iso:" W=")
            txt.print_ub(warn)
            txt.nl()
        }
        ui.nowplaying_pcm(loaded, haspdx)
        ui.pcm_warning()
        mxdrv.play()
        start_jiffy = cbm.RDTIM16()
        playing = true
        playing_idx = idx
        plays++
        copy(sel.nameptrs[idx], &playname)
        sys.memcopy(&sel.path, &playdir, len(playdir))   ; (up to 80 characters; copy() stops at 63)
        sel.draw()
    }
}

; ---------------------------------------------------------------------------
; the song's PCM
;  1. candidates: the PDX-name pack P (SONGS.P16, packfile), then the song-name pack S (NAME.P16;
;     only once if both have the same name). Used at once: a shared pack (version 2) the song
;     lacks nothing in, or a per-song pack (version 1) named after the song.
;  2. none of them: stream the PDX
;  3. no PDX either: the first pack that was read but lacks pairs (version 2 with pairs missing,
;     or version 1 of another song), read again if anything was read after it. It must give the
;     same result as the first time; else FM only
main {
    %option merge
    const ubyte SRC_NONE = 0
    const ubyte SRC_PACK = 1
    const ubyte SRC_PDX = 2
    const ubyte W_NONE = 0
    const ubyte W_MISSING = 1       ; the pack lacks src_missing pairs of the song
    const ubyte W_OVER = 2          ; the song has more than 96 pairs: not checked
    const ubyte W_OTHER = 3         ; version 1 pack named after the PDX: another song's
    const ubyte W_CHANGED = 4       ; the pack read again differs: FM only
    const ubyte W_PDXMISS = 5       ; PDX: src_missing pairs not loaded
    const ubyte W_PDXOVER = 6       ; PDX: the song has more than 96 pairs

    ubyte src
    ubyte warn
    ubyte[64] srcname               ; the pack used
    ubyte src_ver
    ubyte src_missing
    ubyte[64] part                  ; the first pack that lacks pairs
    bool part_ok
    ubyte part_ver
    ubyte part_pairs
    ubyte part_missing
    ubyte part_warn
    bool dirty                      ; banks or the driver changed since part was registered

    sub load_pcm(ubyte idx) -> ubyte {
        part_ok = false
        dirty = false
        src_ver = 0
        src_missing = 0
        packname(sel.nameptrs[idx])
        bool same = same_name(&mxdrv.packfile, &pack)
        if try_pack(&mxdrv.packfile, same)
            return mxdrv.pk_pairs
        if not same and try_pack(&pack, true)
            return mxdrv.pk_pairs
        ui.status(iso:"loading PDX", theme.HEAD)
        ubyte loaded = mxdrv.loadpdx(pdxbuf, 512)
        if mxdrv.missing != 255 {
            ; the PDX was there (the song's PCM is what it loaded)
            src = SRC_PDX
            src_missing = mxdrv.missing
            if mxdrv.over != 0
                warn = W_PDXOVER
            else if mxdrv.missing != 0
                warn = W_PDXMISS
            return loaded
        }
        if not part_ok
            return 0                        ; (nothing registered: no PCM)
        if dirty {
            ui.status(iso:"loading PCM", theme.HEAD)
            ubyte r = mxdrv.loadpack(&part, PCMFIRST, lastbank)
            if AUTOTEST
                autotry(&part, r)
            if r != mxdrv.PK_OK or mxdrv.pk_ver != part_ver or mxdrv.pk_pairs != part_pairs or mxdrv.pk_missing != part_missing {
                ; PCM off: a pack that registered differently, or the one read after part
                ; (PK_NOFILE changes nothing) must not stay
                void mxdrv.setmdx(MDXBANK, $a000, mdxsize)
                copy(&part, &srcname)
                warn = W_CHANGED
                return 0
            }
        }
        src = SRC_PACK
        copy(&part, &srcname)
        src_ver = part_ver
        src_missing = part_missing
        warn = part_warn
        return part_pairs
    }

    ; try_pack: read a candidate -> true if it is used (main.src etc. set)
    sub try_pack(uword name, bool songpack) -> bool {
        ubyte r = mxdrv.loadpack(name, PCMFIRST, lastbank)
        if AUTOTEST
            autotry(name, r)
        if r == mxdrv.PK_NOFILE
            return false                    ; (nothing changed)
        dirty = true
        if r != mxdrv.PK_OK
            return false
        if (mxdrv.pk_ver == 2 and mxdrv.pk_missing == 0) or (mxdrv.pk_ver == 1 and songpack) {
            src = SRC_PACK
            copy(name, &srcname)
            src_ver = mxdrv.pk_ver
            src_missing = mxdrv.pk_missing
            return true
        }
        if not part_ok {
            part_ok = true
            dirty = false                   ; (registered now)
            copy(name, &part)
            part_ver = mxdrv.pk_ver
            part_pairs = mxdrv.pk_pairs
            part_missing = mxdrv.pk_missing
            if part_ver == 1
                part_warn = W_OTHER
            else if part_missing == $fe
                part_warn = W_OVER
            else
                part_warn = W_MISSING
        }
        return false
    }

    sub autotry(uword name, ubyte r) {
        txt.print(iso:"PCMTRY ")
        txt.print(name)
        txt.print(iso:" R=")
        txt.print_ub(r)
        txt.print(iso:" V=")
        txt.print_ub(mxdrv.pk_ver)
        txt.print(iso:" A=")
        txt.print_ub(mxdrv.pk_pairs)
        txt.print(iso:" X=")
        txt.print_ub(mxdrv.pk_missing)
        txt.nl()
    }

    ; file names equal, ignoring case
    sub same_name(uword a, uword b) -> bool {
        ubyte i = 0
        repeat {
            ubyte c = @(a + i)
            ubyte d = @(b + i)
            if c >= $61 and c <= $7a
                c -= $20
            if d >= $61 and d <= $7a
                d -= $20
            if c != d
                return false
            if c == 0
                return true
            i++
        }
    }

    ; names equal (as is, or case ignored)
    sub same(uword a, uword b, bool nocase) -> bool {
        return cmpname(a, b, nocase) == 0
    }

    ; compare names: -1 / 0 / 1 (as is, or case ignored: a-z as A-Z)
    sub cmpname(uword a, uword b, bool nocase) -> byte {
        ubyte i = 0
        repeat {
            ubyte c = @(a + i)
            ubyte d = @(b + i)
            if nocase {
                if c >= $61 and c <= $7a
                    c -= $20
                if d >= $61 and d <= $7a
                    d -= $20
            }
            if c != d {
                if c < d
                    return -1
                return 1
            }
            if c == 0
                return 0
            i++
        }
    }

    sub copy(uword name, uword dest) {
        ubyte i = 0
        while i < 63 and @(name + i) != 0 {
            @(dest + i) = @(name + i)
            i++
        }
        @(dest + i) = 0
    }
}

; ---------------------------------------------------------------------------
; text screen helpers (layer 1, map at VRAM $1B000, 2 bytes per cell, 128 cells per row)
scr {
    sub at(ubyte col, ubyte row) {
        cx16.vaddr(1, $b000 + mkword(row, col * 2), 0, 1)
    }
    sub print(ubyte col, ubyte row, str s, ubyte color) {
        at(col, row)
        ubyte i = 0
        while s[i] != 0 {
            cx16.VERA_DATA0 = s[i]
            cx16.VERA_DATA0 = color
            i++
        }
    }
    ; at most max characters of s; a longer one ends with '~'. Returns the number printed
    sub printn(ubyte col, ubyte row, uword s, ubyte most, ubyte color) -> ubyte {
        at(col, row)
        ubyte i = 0
        while @(s + i) != 0 and i < most {
            ubyte c = @(s + i)
            if i == most - 1 and @(s + i + 1) != 0
                c = iso:'~'
            cx16.VERA_DATA0 = c
            cx16.VERA_DATA0 = color
            i++
        }
        return i
    }
    sub ch(ubyte col, ubyte row, ubyte c, ubyte color) {
        at(col, row)
        cx16.VERA_DATA0 = c
        cx16.VERA_DATA0 = color
    }
    sub fill(ubyte col, ubyte row, ubyte n, ubyte c, ubyte color) {
        at(col, row)
        repeat n {
            cx16.VERA_DATA0 = c
            cx16.VERA_DATA0 = color
        }
    }
    ; unsigned decimal, right aligned in w digits (w <= 5), lead = '0' or ' '
    ubyte[5] digits
    sub num(ubyte col, ubyte row, uword v, ubyte w, ubyte lead, ubyte color) {
        byte i
        for i in 4 downto 0 {
            digits[i as ubyte] = (v % 10) as ubyte + '0'
            v /= 10
        }
        ubyte first = 5 - w
        ubyte k = first
        while k < 4 and digits[k] == '0' {
            digits[k] = lead
            k++
        }
        at(col, row)
        for k in first to 4 {
            cx16.VERA_DATA0 = digits[k]
            cx16.VERA_DATA0 = color
        }
    }
    ; glyph data for a custom character (VRAM charset at $1F000)
    sub glyph(ubyte code, uword data) {
        cx16.vaddr(1, $f000 + (code as uword) * 8, 0, 1)
        ubyte i
        for i in 0 to 7
            cx16.VERA_DATA0 = @(data + i)
    }
}

; ---------------------------------------------------------------------------
; layer 0: 2bpp tiles (map $00000, tiles $04000)
;   0 empty, 1..16 keyboard tops, 17/18 keyboard bottoms, 32..56 level bar cells,
;   64.. now playing title (160), 224.. selector titles (10 x 64)
kanji {
    const ubyte FONTBANK = 13
    const uword KB_TOP = 1
    const uword KB_BOT = 17
    const uword BAR = 32
    const uword T_NOW = 64
    const uword T_SEL = 224
    bool have_font

    ubyte[16] expand = [$00, $01, $04, $05, $10, $11, $14, $15, $40, $41, $44, $45, $50, $51, $54, $55]
    ubyte[8] gbuf
    ubyte[8] trow

    sub init(bool font) {
        have_font = font
        cx16.VERA_CTRL = 0
        cx16.VERA_L0_CONFIG = %01100001         ; map 128x64, 2bpp tiles
        cx16.VERA_L0_MAPBASE = 0                ; $00000
        cx16.VERA_L0_TILEBASE = ($4000 >> 11) << 2     ; $04000, 8x8
        cx16.VERA_L0_HSCROLL_L = 0
        cx16.VERA_L0_HSCROLL_H = 0
        cx16.VERA_L0_VSCROLL_L = 0
        cx16.VERA_L0_VSCROLL_H = 0
        cx16.vaddr(0, 0, 0, 1)                  ; empty map, tile 0 empty
        repeat 16384
            cx16.VERA_DATA0 = 0
        cx16.vaddr(0, $4000, 0, 1)
        repeat 16
            cx16.VERA_DATA0 = 0
        ; keyboard tops: (lb, rb) = black key at the left / right edge, state
        ;   st 0 none, 1 white key pressed, 2 left black key pressed, 3 right black key pressed
        ;   pixel values: 1 white key, 2 black key, 3 pressed, 0 gap
        ubyte lb
        ubyte rb
        ubyte st
        ubyte r
        ubyte c
        for lb in 0 to 1 {
            for rb in 0 to 1 {
                for st in 0 to 3 {
                    for r in 0 to 7 {
                        ubyte w = 1
                        if st == 1
                            w = 3
                        for c in 0 to 7 {
                            ubyte v = w
                            if c == 7
                                v = 0
                            if r < 6 {
                                if c <= 1 and lb != 0 {
                                    v = 2
                                    if st == 2
                                        v = 3
                                }
                                if c >= 5 and rb != 0 {
                                    v = 2
                                    if st == 3
                                        v = 3
                                }
                            }
                            trow[c] = v
                        }
                        gbuf[r] = 0                 ; (unused)
                        rowtile(KB_TOP + (lb * 2 + rb) * 4 + st, r)
                    }
                }
            }
        }
        ; keyboard bottoms: none / pressed
        for st in 0 to 1 {
            for r in 0 to 7 {
                for c in 0 to 7 {
                    ubyte v2 = 1 + st * 2
                    if c == 7 or r == 7
                        v2 = 0
                    trow[c] = v2
                }
                rowtile(KB_BOT + st, r)
            }
        }
        ; level bar cells: 4 lines (pixel rows 7, 5, 3, 1 from the bottom), fill 0..4 lines,
        ; peak line 0..3 or none: tile BAR + fill * 5 + peak + 1
        ubyte fl
        ubyte pk
        for fl in 0 to 4 {
            for pk in 0 to 4 {
                for r in 0 to 7 {
                    ubyte v3 = 0
                    if r & 1 != 0 {
                        ubyte line = (7 - r) >> 1
                        v3 = 1
                        if line < fl
                            v3 = 2
                        if pk != 0 and line == pk - 1
                            v3 = 3
                    }
                    for c in 0 to 7
                        trow[c] = v3
                    rowtile(BAR + fl * 5 + pk, r)
                }
            }
        }
        cx16.VERA_DC_VIDEO |= %00010000         ; layer 0 on
    }

    ; write row r of tile t from trow[0..7] (pixel values)
    sub rowtile(uword t, ubyte r) {
        cx16.vaddr(0, $4000 + t * 16 + r * 2, 0, 1)
        cx16.VERA_DATA0 = (trow[0] << 6) | (trow[1] << 4) | (trow[2] << 2) | trow[3]
        cx16.VERA_DATA0 = (trow[4] << 6) | (trow[5] << 4) | (trow[6] << 2) | trow[7]
    }

    sub off() {
        cx16.VERA_CTRL = 0
        cx16.VERA_DC_VIDEO &= %11101111
    }

    ; map entry (col, row) = tile, palette offset
    sub put(ubyte col, ubyte row, uword tile, ubyte pal) {
        cx16.vaddr(0, mkword(row, col * 2), 0, 1)
        cx16.VERA_DATA0 = lsb(tile)
        cx16.VERA_DATA0 = (pal << 4) | msb(tile)
    }

    sub clear(ubyte col, ubyte row, ubyte n) {
        cx16.vaddr(0, mkword(row, col * 2), 0, 1)
        repeat n {
            cx16.VERA_DATA0 = 0
            cx16.VERA_DATA0 = 0
        }
    }

    ; Shift_JIS -> glyph index (row-1)*94 + (cell-1), $ffff = none
    sub sjis(ubyte s1, ubyte s2) -> uword {
        ubyte j1
        ubyte j2
        if s1 <= $9f
            j1 = (s1 - $70) << 1
        else
            j1 = (s1 - $b0) << 1
        if s2 < $9f {
            j1--
            if s2 >= $80
                j2 = s2 - $20
            else
                j2 = s2 - $1f
        } else
            j2 = s2 - $7e
        if j1 < $21 or j1 > $7e or j2 < $21 or j2 > $7e
            return $ffff
        return ((j1 - $21) as uword) * 94 + (j2 - $21)
    }

    ; glyph gi -> tile (2bpp, pixel value 1)
    sub glyph(uword gi, uword tile) {
        uword g = gi + 64                       ; (512-byte table in front)
        ubyte b = FONTBANK + (msb(g) >> 2)
        uword a = $a000 + (g & $03ff) * 8
        ubyte ob = cx16.getrambank()
        cx16.rambank(b)
        ubyte i
        for i in 0 to 7
            gbuf[i] = @(a + i)
        cx16.rambank(ob)
        cx16.vaddr(0, $4000 + tile * 16, 0, 1)
        for i in 0 to 7 {
            cx16.VERA_DATA0 = expand[gbuf[i] >> 4]
            cx16.VERA_DATA0 = expand[gbuf[i] & 15]
        }
    }

    ; draw a Shift_JIS line (ends at $0d/$0a/$1a/0) from bank:addr into ncells cells at
    ; (col,row) with tiles tile.., palette pal. Returns the address after the drawn part.
    sub text(ubyte col, ubyte row, ubyte ncells, uword tile, ubyte pal, ubyte bank, uword addr) -> uword {
        ubyte i = 0
        ubyte ob = cx16.getrambank()
        while i < ncells and have_font {
            cx16.rambank(bank)
            ubyte c = @(addr)
            if c == $0d or c == $0a or c == $1a or c == 0
                break
            uword gi
            if (c >= $81 and c <= $9f) or (c >= $e0 and c <= $ef) {
                ubyte c2 = @(addr + 1)
                if c2 == 0
                    break
                addr += 2
                gi = sjis(c, c2)
            } else {
                addr++
                cx16.rambank(FONTBANK)
                gi = peekw($a000 + (c as uword) * 2)
            }
            cx16.rambank(ob)
            if gi != $ffff {
                glyph(gi, tile + i)
                put(col + i, row, tile + i, pal)
            } else
                put(col + i, row, 0, 0)
            i++
        }
        cx16.rambank(ob)
        if i < ncells
            clear(col + i, row, ncells - i)
        return addr
    }

    ; ---- keyboards: 56 white keys (C0..B7), 2 rows from (0, row)
    ubyte[12] natural = [0, 255, 1, 255, 2, 3, 255, 4, 255, 5, 255, 6]
    ubyte[12] sharpleft = [255, 0, 255, 1, 255, 255, 3, 255, 4, 255, 5, 255]
    ubyte[7] haslb = [0, 1, 1, 0, 1, 1, 1]
    ubyte[7] hasrb = [1, 1, 0, 1, 1, 1, 0]

    sub keycell(ubyte row, ubyte cell, ubyte st, ubyte bottom) {
        ubyte w = cell % 7
        put(cell, row, KB_TOP + (haslb[w] * 2 + hasrb[w]) * 4 + st, theme.P_KB)
        put(cell, row + 1, KB_BOT + bottom, theme.P_KB)
    }

    sub keyboard_init(ubyte row) {
        ubyte c
        for c in 0 to 55
            keycell(row, c, 0, 0)
    }

    ; key position pos (0 = C0 .. 95 = B7) pressed (on = true) or released
    sub key(ubyte row, ubyte pos, bool on) {
        ubyte o = pos / 12
        ubyte s = pos % 12
        ubyte base = o * 7
        if natural[s] != 255 {
            if on
                keycell(row, base + natural[s], 1, 1)
            else
                keycell(row, base + natural[s], 0, 0)
        } else {
            ubyte l = base + sharpleft[s]
            if on {
                keycell(row, l, 3, 0)
                keycell(row, l + 1, 2, 0)
            } else {
                keycell(row, l, 0, 0)
                keycell(row, l + 1, 0, 0)
            }
        }
    }
}

; ---------------------------------------------------------------------------
ui {
    ; snapshot layout (driver/src/mx16.s)
    const ubyte S_PL = 0
    const ubyte S_PH = 16
    const ubyte S_FL = 32
    const ubyte S_V = 48
    const ubyte S_PAN = 64
    const ubyte S_VNO = 80
    const ubyte S_KC = 96
    const ubyte S_DL = 112
    const ubyte S_DH = 128
    const ubyte S_PLT = 144
    const ubyte S_VLT = 160
    const ubyte S_BANK = 176
    const ubyte S_TB = 192
    const ubyte S_FADING = 194
    const ubyte S_LOOPS = 196
    const ubyte S_TICKS = 198
    const ubyte S_ACTIVE = 200

    const ubyte RIGHT = 58          ; right panel column
    const ubyte NOWROW = 27
    const ubyte SELROW = 31
    const ubyte BARTOP = 42         ; level bars: rows 42..53, 4 lines per row
    const ubyte BARROWS = 12
    const ubyte BARCOL = 8          ; channel i at BARCOL + 4 * i (3 columns)
    const ubyte PANROW = 54         ; knobs: 3 x 2 cells
    const ubyte PROGROW = 56
    const ubyte KEYROW = 57
    const ubyte STATROW = 59

    ; custom characters
    const ubyte G_LINE = $80
    const ubyte G_KNOB = $81        ; 24x16 knobs, 6 characters each: +0 no line, +6 L, +12 center, +18 R

    ubyte[202] snap
    ubyte[8] o_pos                  ; FM: last shown values (255 = unknown)
    ubyte[8] o_note
    ubyte[8] o_v
    ubyte[8] o_vno
    ubyte[8] o_pan
    ubyte[8] o_lfo
    uword[8] o_det
    ubyte[16] o_kc                  ; all: key-on counter
    ubyte[16] o_knob
    ubyte[16] o_prog
    ubyte[16] o_kcode
    ubyte[16] level                 ; level bars, in lines (0..48)
    ubyte[16] peak                  ; peak line + 1 (0 = none)
    ubyte[16] hold
    ubyte[16] o_level
    ubyte[16] o_peak
    ubyte framecnt
    ubyte spin
    str chnames = iso:"12345678PQRSTUVW"
    str notenames = iso:"C#D D#E F F#G G#A A#B C "
    str spinner = iso:"-\\|/"
    ubyte[8] g

    ubyte[8] linegl = [$00, $00, $00, $ff, $00, $00, $00, $00]
    ; panpot knobs (24x16: 3 columns x 2 rows of 8x8): circle, L, center, R (tools: knobs.txt)
    ubyte[192] knobgl = [
        $00, $00, $00, $01, $02, $04, $04, $04, $00, $7e, $81, $00, $00, $00, $00, $00,
        $00, $00, $00, $80, $40, $20, $20, $20, $04, $04, $04, $02, $01, $00, $00, $00,
        $00, $00, $00, $00, $00, $81, $7e, $00, $20, $20, $20, $40, $80, $00, $00, $00,
        $00, $00, $00, $01, $02, $05, $04, $04, $00, $7e, $81, $00, $00, $c0, $60, $38,
        $00, $00, $00, $80, $40, $20, $20, $20, $04, $04, $04, $02, $01, $00, $00, $00,
        $18, $00, $00, $00, $00, $81, $7e, $00, $20, $20, $20, $40, $80, $00, $00, $00,
        $00, $00, $00, $01, $02, $04, $04, $04, $00, $7e, $81, $18, $18, $18, $18, $18,
        $00, $00, $00, $80, $40, $20, $20, $20, $04, $04, $04, $02, $01, $00, $00, $00,
        $18, $00, $00, $00, $00, $81, $7e, $00, $20, $20, $20, $40, $80, $00, $00, $00,
        $00, $00, $00, $01, $02, $04, $04, $04, $00, $7e, $81, $00, $00, $03, $06, $1c,
        $00, $00, $00, $80, $40, $a0, $20, $20, $04, $04, $04, $02, $01, $00, $00, $00,
        $18, $00, $00, $00, $00, $81, $7e, $00, $20, $20, $20, $40, $80, $00, $00, $00 ]

    sub init(bool font) {
        ubyte n
        scr.glyph(G_LINE, &linegl)
        for n in 0 to 23
            scr.glyph(G_KNOB + n, &knobgl + n * 8)
        kanji.init(font)
        layout()
    }

    sub done() {
        kanji.off()
        palette.set_default16()
        txt.iso_off()
        txt.clear_screen()
    }

    sub layout() {
        txt.clear_screen()
        scr.print(0, 0, iso:"X16MXDRV  MDX PLAYER for Commander X16", theme.HEAD)
        scr.fill(0, 1, 80, G_LINE, theme.DIM)
        ubyte i
        for i in 0 to 7 {
            scr.ch(0, 2 + i * 3, chnames[i], theme.HEAD)
            kanji.keyboard_init(3 + i * 3)
        }
        scr.fill(0, 26, 80, G_LINE, theme.DIM)
        scr.print(0, NOWROW, iso:"NOW PLAYING", theme.HEAD)
        scr.fill(0, 30, 80, G_LINE, theme.DIM)
        ; level bars, panpot, program, keycode
        scr.print(0, BARTOP - 1, iso:"VELOCITY", theme.HEAD)
        scr.print(0, PANROW, iso:"PANPOT", theme.LABEL)
        scr.print(0, PANROW + 1, iso:"ON/OFF", theme.LABEL)
        scr.print(0, PROGROW, iso:"PROGRAM", theme.LABEL)
        scr.print(0, KEYROW, iso:"KEYCODE", theme.LABEL)
        for i in 0 to 15
            scr.ch(BARCOL + 4 * i + 1, BARTOP - 1, chnames[i], theme.HEAD)
        scr.fill(0, 58, 80, G_LINE, theme.DIM)
        ; right panel
        when main.chip {
            1 -> scr.print(RIGHT, 2, iso:"YM2164", theme.TEXT)
            2 -> scr.print(RIGHT, 2, iso:"YM2151", theme.TEXT)
            else -> scr.print(RIGHT, 2, iso:"YM ?", theme.TEXT)
        }
        if main.clk == 1
            scr.print(RIGHT + 8, 2, iso:"4MHz", theme.TEXT)
        else
            scr.print(RIGHT + 8, 2, iso:"3.58MHz", theme.TEXT)
        scr.print(RIGHT, 3, iso:"CPU", theme.LABEL)
        scr.num(RIGHT + 4, 3, main.mhz, 2, ' ', theme.TEXT)
        scr.print(RIGHT + 6, 3, iso:"MHz", theme.TEXT)
        scr.print(RIGHT + 11, 3, iso:"PCM8", theme.LABEL)
        if main.pcm
            scr.print(RIGHT + 16, 3, iso:"yes", theme.TEXT)
        else
            scr.print(RIGHT + 16, 3, iso:"no", theme.WARN)
        scr.print(RIGHT, 5, iso:"TIMER-B", theme.LABEL)
        scr.print(RIGHT, 6, iso:"TIME", theme.LABEL)
        scr.print(RIGHT, 7, iso:"LOOP", theme.LABEL)
        scr.print(RIGHT, 8, iso:"TICKS", theme.LABEL)
        scr.print(RIGHT, 9, iso:"VOICES", theme.LABEL)
        scr.print(RIGHT, 10, iso:"UNDERRUN", theme.LABEL)
        scr.print(RIGHT, 14, iso:"RET   play / folder", theme.LABEL)
        scr.print(RIGHT, 15, iso:"DEL   parent folder", theme.LABEL)
        scr.print(RIGHT, 16, iso:"<-/-> page up/down", theme.LABEL)
        scr.print(RIGHT, 17, iso:"SPC/F stop / fade out", theme.LABEL)
        scr.print(RIGHT, 18, iso:"N/P   next / prev", theme.LABEL)
        scr.print(RIGHT, 19, iso:"A/R   auto / repeat", theme.LABEL)
        scr.print(RIGHT, 20, iso:"S     shuffle", theme.LABEL)
        scr.print(RIGHT, 21, iso:"</>   loops", theme.LABEL)
        scr.print(RIGHT, 22, iso:"1-8   mute FM", theme.LABEL)
        scr.print(RIGHT, 23, iso:"SH+1-8 mute PCM", theme.LABEL)
        scr.print(RIGHT, 24, iso:"9/0/- all on/off/flip", theme.LABEL)
        scr.print(RIGHT, 25, iso:"Q     quit", theme.LABEL)
        modes()
        mutelabels()
        clear_song()
    }

    ; channel names: muted ones dim (FM rows, VELOCITY header)
    sub mutelabels() {
        ubyte i
        for i in 0 to 15 {
            ubyte c = theme.HEAD
            if main.muted(i)
                c = theme.DIM
            if i < 8
                scr.ch(0, 2 + i * 3, chnames[i], c)
            scr.ch(BARCOL + 4 * i + 1, BARTOP - 1, chnames[i], c)
        }
    }

    sub modes() {
        scr.print(RIGHT, 12, iso:"AUTO", theme.LABEL)
        if main.auto_next
            scr.print(RIGHT + 5, 12, iso:"on ", theme.WHITE)
        else
            scr.print(RIGHT + 5, 12, iso:"off", theme.DIM)
        scr.print(RIGHT + 9, 12, iso:"REPEAT", theme.LABEL)
        if main.repeat_song
            scr.print(RIGHT + 17, 12, iso:"on ", theme.WHITE)
        else
            scr.print(RIGHT + 17, 12, iso:"off", theme.DIM)
        scr.print(RIGHT, 13, iso:"LOOPS", theme.LABEL)
        scr.num(RIGHT + 6, 13, main.loops_max, 1, ' ', theme.TEXT)
        scr.print(RIGHT + 9, 13, iso:"SHUFFLE", theme.LABEL)
        if main.shuffle
            scr.print(RIGHT + 17, 13, iso:"on ", theme.WHITE)
        else
            scr.print(RIGHT + 17, 13, iso:"off", theme.DIM)
    }

    ; the folder on the line above the selector (the end of a long path)
    sub folder() {
        scr.fill(0, SELROW - 1, 80, G_LINE, theme.DIM)
        ubyte n = lsb(strings.length(&sel.path))
        uword p = &sel.path
        if n > 70 {
            p += n - 70
            n = 70
        }
        scr.ch(1, SELROW - 1, ' ', theme.TEXT)
        scr.print(2, SELROW - 1, p, theme.WHITE)
        scr.ch(2 + n, SELROW - 1, ' ', theme.TEXT)
    }

    sub status(str msg, ubyte color) {
        scr.fill(0, STATROW, 80, ' ', theme.TEXT)
        scr.print(0, STATROW, msg, color)
    }

    ; PDX load progress (called by mxdrv.loadpdx after every piece)
    ubyte progcalls
    sub pdx_progress() {
        progcalls++
        if main.AUTOPROG != 0 and progcalls == main.AUTOPROG {
            %asm {{
                jmp $ffff
            }}
        }
        spin = (spin + 1) & 3
        scr.ch(12, STATROW, spinner[spin], theme.WHITE)
        ubyte p = mxdrv.pdxpercent()
        if p != 255 {
            scr.num(14, STATROW, p, 3, ' ', theme.WHITE)
            scr.ch(17, STATROW, '%', theme.TEXT)
        }
    }

    ; idle screen: no song (before loading one)
    sub clear_song() {
        ubyte i
        for i in 0 to 7 {
            ubyte row = 2 + i * 3
            scr.fill(2, row, 30, ' ', theme.TEXT)
            if o_pos[i] != 255
                kanji.key(row + 1, o_pos[i], false)
            o_pos[i] = 255
            o_note[i] = 255
            o_v[i] = 255
            o_vno[i] = 255
            o_pan[i] = 255
            o_lfo[i] = 255
            o_det[i] = $ffff
        }
        for i in 0 to 15 {
            o_kc[i] = 0
            level[i] = 0
            peak[i] = 0
            hold[i] = 0
            o_level[i] = 255
            o_peak[i] = 255
            o_knob[i] = 255
            o_prog[i] = 255
            o_kcode[i] = 255
            bar(i)
            scr.fill(BARCOL + 4 * i, PANROW, 4, ' ', theme.TEXT)
            scr.fill(BARCOL + 4 * i, PANROW + 1, 4, ' ', theme.TEXT)
            scr.fill(BARCOL + 4 * i, PROGROW, 4, ' ', theme.TEXT)
            scr.fill(BARCOL + 4 * i, KEYROW, 4, ' ', theme.TEXT)
        }
        scr.fill(RIGHT + 9, 5, 13, ' ', theme.TEXT)
        for i in 6 to 10
            scr.fill(RIGHT + 9, i, 13, ' ', theme.TEXT)
        p_tb = 255
        p_secs = $ffff
        p_loops = $ffff
        p_ticks = $ffff
        p_act = 255
        p_under = $ffff
        p_fade = 255
        scr.fill(12, NOWROW, 68, ' ', theme.TEXT)
        kanji.clear(0, NOWROW + 1, 80)
        kanji.clear(0, NOWROW + 2, 80)
    }

    sub nowplaying_name(ubyte idx) {
        void scr.printn(13, NOWROW, sel.nameptrs[idx], 22, theme.WHITE)
        ubyte bank
        uword addr
        bank, addr = mxdrv.title()
        addr = kanji.text(0, NOWROW + 1, 80, kanji.T_NOW, theme.P_TITLE, bank, addr)
        void kanji.text(0, NOWROW + 2, 80, kanji.T_NOW + 80, theme.P_TITLE, bank, addr)
    }

    ; "PDX SONGS.PDX 15 samples (P16 SONGS)": where the PCM came from
    sub nowplaying_pcm(ubyte loaded, bool haspdx) {
        if not haspdx
            return
        scr.print(36, NOWROW, iso:"PDX", theme.LABEL)
        scr.print(40, NOWROW, &mxdrv.pdxfile, theme.TEXT)
        if not main.pcm
            return
        when main.src {
            main.SRC_NONE -> {
                if main.warn != main.W_CHANGED
                    scr.print(54, NOWROW, iso:"not found", theme.WARN)
            }
            main.SRC_PDX -> {
                scr.num(54, NOWROW, loaded, 3, ' ', theme.TEXT)
                scr.print(58, NOWROW, iso:"samples", theme.LABEL)
                scr.print(66, NOWROW, iso:"(PDX)", theme.LABEL)
            }
            main.SRC_PACK -> {
                scr.num(54, NOWROW, loaded, 3, ' ', theme.TEXT)
                scr.print(58, NOWROW, iso:"samples", theme.LABEL)
                scr.print(66, NOWROW, iso:"(P16 ", theme.LABEL)
                ubyte i = 0
                while i < 8 and main.srcname[i] != 0 and main.srcname[i] != $2e {
                    scr.ch(71 + i, NOWROW, main.srcname[i], theme.LABEL)
                    i++
                }
                scr.ch(71 + i, NOWROW, ')', theme.LABEL)
            }
        }
    }

    ; the status line after loading: what is wrong with the song's PCM, if anything
    sub pcm_warning() {
        status(iso:"", theme.TEXT)
        ubyte col
        when main.warn {
            main.W_MISSING -> {
                col = pcmmsg(&main.srcname)
                scr.num(col, STATROW, main.src_missing, 2, ' ', theme.WARN)
                scr.print(col + 3, STATROW, iso:"samples of this song missing (no PDX found)", theme.WARN)
            }
            main.W_OVER -> {
                col = pcmmsg(&main.srcname)
                scr.print(col, STATROW, iso:"not checked: the song uses over 96 samples", theme.WARN)
            }
            main.W_OTHER -> {
                col = pcmmsg(&main.srcname)
                scr.print(col, STATROW, iso:"not checked: a pack for another song", theme.WARN)
            }
            main.W_CHANGED -> {
                col = pcmmsg(&main.srcname)
                scr.print(col, STATROW, iso:"changed while loading, PCM off", theme.WARN)
            }
            main.W_PDXMISS -> {
                scr.print(0, STATROW, iso:"PCM:", theme.WARN)
                scr.num(5, STATROW, main.src_missing, 3, ' ', theme.WARN)
                scr.print(9, STATROW, iso:"samples not loaded (RAM full / not in the PDX)", theme.WARN)
            }
            main.W_PDXOVER -> scr.print(0, STATROW, iso:"PCM: the song uses over 96 samples, the rest is not loaded", theme.WARN)
        }
    }

    ; "PCM: NAME " -> the next column (the name: 20 characters at most)
    sub pcmmsg(uword name) -> ubyte {
        scr.print(0, STATROW, iso:"PCM:", theme.WARN)
        ubyte i = 0
        while i < 20 and @(name + i) != 0 {
            scr.ch(5 + i, STATROW, @(name + i), theme.WARN)
            i++
        }
        return 6 + i
    }

    ; once per frame
    sub frame() {
        mxdrv.snapshot(&snap)
        framecnt++
        bool playing = main.playing
        ubyte i
        for i in 0 to 15 {
            ; key-on: bar level from the volume
            if playing and snap[S_KC + i] != o_kc[i] and main.muted(i)
                o_kc[i] = snap[S_KC + i]                ; (muted: no bar)
            if playing and snap[S_KC + i] != o_kc[i] {
                o_kc[i] = snap[S_KC + i]
                ubyte v = snap[S_V + i]
                ubyte l
                if v & $80 != 0 {
                    v &= $7f
                    if v > 64
                        l = 0
                    else
                        l = 64 - v
                } else
                    l = 16 + (v & 15) * 3
                level[i] = l - (l >> 2)         ; 64 -> 48 lines
            } else if level[i] != 0
                level[i]--
            ; peak: follows up, holds, then falls
            if level[i] != 0 and level[i] >= peak[i] {
                peak[i] = level[i]
                hold[i] = 40
            } else if hold[i] != 0
                hold[i]--
            else if peak[i] != 0 and framecnt & 1 == 0
                peak[i]--
            bar(i)
            if not playing
                continue
            if i < 8
                fm_row(i)
            bottom(i)
        }
        if playing
            panel()
    }

    ; level bar of channel i: only the rows whose cells change
    sub bar(ubyte i) {
        ubyte l = level[i]
        ubyte p = peak[i]
        ubyte ol = o_level[i]
        ubyte op = o_peak[i]
        if l == ol and p == op
            return
        o_level[i] = l
        o_peak[i] = p
        if ol == 255 {                          ; redraw all
            ubyte r
            for r in 0 to BARROWS - 1
                barrow(i, r)
            return
        }
        if l != ol {
            ubyte r0 = l >> 2
            ubyte r1 = ol >> 2
            if r1 < r0 {
                r0 = r1
                r1 = l >> 2
            }
            if r1 >= BARROWS
                r1 = BARROWS - 1
            for r in r0 to r1
                barrow(i, r)
        }
        if p != op {
            if op != 0
                barrow(i, (op - 1) >> 2)
            if p != 0
                barrow(i, (p - 1) >> 2)
        }
    }

    ; one row (r = 0 bottom) of channel i's bar: 3 cells
    sub barrow(ubyte i, ubyte r) {
        if r >= BARROWS
            return
        ubyte f = 0
        ubyte base = r * 4
        if level[i] > base {
            f = level[i] - base
            if f > 4
                f = 4
        }
        ubyte pk = 0
        if peak[i] > base and peak[i] <= base + 4
            pk = peak[i] - base
        uword t = kanji.BAR + f * 5 + pk
        ubyte col = BARCOL + 4 * i
        ubyte row = BARTOP + BARROWS - 1 - r
        kanji.put(col, row, t, theme.P_BAR)
        kanji.put(col + 1, row, t, theme.P_BAR)
        kanji.put(col + 2, row, t, theme.P_BAR)
    }

    ; FM channel i: information row and keyboard
    sub fm_row(ubyte i) {
        ubyte row = 2 + i * 3
        ubyte keyon = snap[S_FL + i] & 8
        uword pitch = mkword(snap[S_PH + i], snap[S_PL + i])
        ubyte nn = lsb(pitch >> 6)
        ubyte kp = 255
        if keyon != 0 {
            kp = nn + 1                         ; keyboard starts at C (note 0 = C#)
            if kp > 95
                kp = 95
        }
        if kp != o_pos[i] {
            if o_pos[i] != 255
                kanji.key(row + 1, o_pos[i], false)
            if kp != 255
                kanji.key(row + 1, kp, true)
            o_pos[i] = kp
        }
        if nn != o_note[i] {
            o_note[i] = nn
            ubyte s = nn % 12                   ; 0 = C# ... 10 = B, 11 = C (next octave)
            ubyte o = nn / 12
            if s == 11
                o++
            scr.ch(12, row, iso:'o', theme.LABEL)
            scr.ch(13, row, '0' + o, theme.TEXT)
            scr.ch(14, row, notenames[s * 2], theme.TEXT)
            scr.ch(15, row, notenames[s * 2 + 1], theme.TEXT)
        }
        if snap[S_VNO + i] != o_vno[i] {
            o_vno[i] = snap[S_VNO + i]
            scr.ch(2, row, '@', theme.LABEL)
            scr.num(3, row, o_vno[i], 3, '0', theme.TEXT)
        }
        if snap[S_V + i] != o_v[i] {
            o_v[i] = snap[S_V + i]
            if o_v[i] & $80 != 0 {
                scr.ch(7, row, iso:'a', theme.LABEL)
                scr.num(8, row, o_v[i] & $7f, 3, '0', theme.TEXT)
            } else {
                scr.ch(7, row, iso:'v', theme.LABEL)
                scr.num(8, row, o_v[i], 2, '0', theme.TEXT)
                scr.ch(10, row, ' ', theme.TEXT)
            }
        }
        uword det = mkword(snap[S_DH + i], snap[S_DL + i])
        if det != o_det[i] {
            o_det[i] = det
            if det == 0
                scr.fill(17, row, 6, ' ', theme.TEXT)
            else {
                scr.ch(17, row, iso:'D', theme.LABEL)
                if det & $8000 != 0 {
                    scr.ch(18, row, '-', theme.TEXT)
                    det = (det ^ $ffff) + 1
                } else
                    scr.ch(18, row, '+', theme.TEXT)
                scr.num(19, row, det, 4, '0', theme.TEXT)
            }
        }
        ubyte pan = snap[S_PAN + i] >> 6        ; RL: bit 6 L, bit 7 R
        if pan != o_pan[i] {
            o_pan[i] = pan
            scr.ch(24, row, '-', theme.DIM)
            scr.ch(25, row, '-', theme.DIM)
            if pan & 1 != 0
                scr.ch(24, row, iso:'L', theme.TEXT)
            if pan & 2 != 0
                scr.ch(25, row, iso:'R', theme.TEXT)
        }
        ubyte lfo = 0
        if snap[S_PLT + i] != 0
            lfo |= 1
        if snap[S_VLT + i] != 0
            lfo |= 2
        if lfo != o_lfo[i] {
            o_lfo[i] = lfo
            if lfo & 1 != 0
                scr.ch(27, row, iso:'P', theme.TEXT)
            else
                scr.ch(27, row, ' ', theme.TEXT)
            if lfo & 2 != 0
                scr.ch(28, row, iso:'A', theme.TEXT)
            else
                scr.ch(28, row, ' ', theme.TEXT)
        }
    }

    ; panpot, program, keycode under the bars (all 16 channels)
    sub bottom(ubyte i) {
        ubyte col = BARCOL + 4 * i
        ubyte pan
        if i < 8
            pan = snap[S_PAN + i] >> 6
        else {
            pan = snap[S_PAN + i] & 3           ; (0 and 3 are swapped in the core)
            if pan == 0 or pan == 3
                pan ^= 3
        }
        ; knob: track off (not active) or muted -> dim circle; on -> line for L / center / R
        ubyte knob = 0
        when pan {
            1 -> knob = 6                       ; L
            2 -> knob = 18                      ; R
            3 -> knob = 12                      ; center
        }
        ubyte color = theme.KNOB
        ubyte act = snap[S_ACTIVE]
        if i >= 8
            act = snap[S_ACTIVE + 1]
        if act & (1 << (i & 7)) == 0 or main.muted(i) {
            knob = 0
            color = theme.DIM
        }
        if knob | color != o_knob[i] {
            o_knob[i] = knob | color
            scr.ch(col, PANROW, G_KNOB + knob, color)
            scr.ch(col + 1, PANROW, G_KNOB + knob + 1, color)
            scr.ch(col + 2, PANROW, G_KNOB + knob + 2, color)
            scr.ch(col, PANROW + 1, G_KNOB + knob + 3, color)
            scr.ch(col + 1, PANROW + 1, G_KNOB + knob + 4, color)
            scr.ch(col + 2, PANROW + 1, G_KNOB + knob + 5, color)
        }
        ubyte prog = snap[S_VNO + i]
        if i >= 8
            prog = snap[S_BANK + i]
        if prog != o_prog[i] {
            o_prog[i] = prog
            scr.num(col, PROGROW, prog, 3, '0', theme.TEXT)
        }
        ubyte kc = lsb(mkword(snap[S_PH + i], snap[S_PL + i]) >> 6)
        if kc != o_kcode[i] {
            o_kcode[i] = kc
            scr.num(col, KEYROW, kc, 3, '0', theme.TEXT)
        }
    }

    ; right panel: numbers only when they change
    ubyte p_tb = 255
    uword p_secs = $ffff
    uword p_loops = $ffff
    uword p_ticks = $ffff
    ubyte p_act = 255
    uword p_under = $ffff
    ubyte p_fade = 255

    sub panel() {
        if snap[S_TB] != p_tb {
            p_tb = snap[S_TB]
            scr.num(RIGHT + 10, 5, p_tb, 3, ' ', theme.TEXT)
        }
        uword secs = (cbm.RDTIM16() - main.start_jiffy) / 60
        if secs != p_secs {
            p_secs = secs
            scr.num(RIGHT + 9, 6, secs / 60, 2, ' ', theme.TEXT)
            scr.ch(RIGHT + 11, 6, ':', theme.TEXT)
            scr.num(RIGHT + 12, 6, secs % 60, 2, '0', theme.TEXT)
        }
        uword v = peekw(&snap + S_LOOPS)
        if v != p_loops {
            p_loops = v
            if v == $ffff
                scr.print(RIGHT + 10, 7, iso:"end", theme.TEXT)    ; (song ended)
            else
                scr.num(RIGHT + 10, 7, v, 3, ' ', theme.TEXT)
        }
        v = peekw(&snap + S_TICKS)
        if v != p_ticks {
            p_ticks = v
            scr.num(RIGHT + 8, 8, v, 5, ' ', theme.TEXT)
        }
        ubyte act
        uword under
        act, under = mxdrv.pcmstat()
        if act != p_act {
            p_act = act
            scr.num(RIGHT + 12, 9, act, 1, ' ', theme.TEXT)
        }
        if under != p_under {
            p_under = under
            scr.num(RIGHT + 8, 10, under, 5, ' ', theme.TEXT)
        }
        if snap[S_FADING] != p_fade {
            p_fade = snap[S_FADING]
            if p_fade != 0
                scr.print(RIGHT + 15, 7, iso:"FADE", theme.WARN)
            else
                scr.print(RIGHT + 15, 7, iso:"    ", theme.TEXT)
        }
    }
}

; ---------------------------------------------------------------------------
; file selector with titles (cached in bank TITLEBANK, 128 bytes per file)
sel {
    ; the selector: the folder's entries in name order (case ignored): ".." (not at the top),
    ; folders, MDX files. Titles of the MDX files in bank TITLEBANK, 64 bytes per entry.
    const ubyte TITLEBANK = 22
    const ubyte ROWS = 10
    const ubyte MAXENT = 128
    const uword NAMESIZE = 4096
    const ubyte K_UP = 0
    const ubyte K_DIR = 1
    const ubyte K_MDX = 2
    uword[MAXENT] nameptrs
    ubyte[MAXENT] kind
    ubyte count
    ubyte first                     ; the first MDX entry (count: none)
    ubyte cur
    ubyte top
    bool full                       ; entries left out (MAXENT or NAMESIZE full)
    uword names
    ubyte[81] path                  ; the folder ("/A/B"), "" if unknown
    ubyte[64] leaf                  ; its last part ("B"; "" at the top)
    ubyte[64] back                  ; (up) the folder left: the cursor goes there
    ubyte[64] buf
    ubyte[68] cmd

    ; read the current folder; the cursor on folder backname (0: on the first MDX)
    sub scan(uword backname) {
        if names == 0
            names = memory("names", NAMESIZE, 0)
        ui.status(iso:"reading folder...", theme.HEAD)
        readpath()
        count = 0
        full = false
        uword p = names
        if dir_open(false) {
            void dir_next()                         ; (the disk name line)
            while dir_next() {
                ubyte k = K_MDX
                if dtype == $44 {                   ; "DIR"
                    if dname[0] == '.' and dname[1] == 0
                        continue
                    k = K_DIR
                    if dname[0] == '.' and dname[1] == '.' and dname[2] == 0
                        k = K_UP
                } else if not is_mdx()
                    continue
                if dlen > 63
                    continue                        ; (too long to load: left out)
                if count == MAXENT or p + dlen + 1 > names + NAMESIZE {
                    full = true
                    continue
                }
                sys.memcopy(&dname, p, dlen + 1)
                nameptrs[count] = p
                kind[count] = k
                count++
                p += dlen + 1
            }
            dir_close()
        }
        sort()
        first = 0
        while first < count and kind[first] != K_MDX
            first++
        titles()
        cur = 0
        if first < count
            cur = first
        else if count > 1 and kind[0] == K_UP
            cur = 1
        ubyte i
        if backname != 0 and count != 0 {
            for i in 0 to count - 1 {
                if kind[i] == K_DIR and main.same(nameptrs[i], backname, false)
                    cur = i
            }
        }
        top = 0
        main.playing_idx = 255
        if main.playing and path[0] != 0 and main.same(&path, &main.playdir, false) and first < count {
            for i in first to count - 1 {
                if main.same(nameptrs[i], &main.playname, false)
                    main.playing_idx = i
            }
        }
        if main.shuffle
            shuf.build()                    ; (a new table for the list shown)
        ui.folder()
        if full
            ui.status(iso:"too many entries: not all shown", theme.WARN)
        else if first == count
            ui.status(iso:"no .MDX files in this folder", theme.WARN)
        else if main.playing
            ui.pcm_warning()                ; (the song's, as when it started)
        else
            ui.status(iso:"", theme.TEXT)
        draw()
    }

    ; RETURN: play the MDX, open the folder
    sub enter() {
        if cur >= count
            return
        when kind[cur] {
            K_MDX -> {
                main.play_song(cur)
                if main.shuffle and main.playing
                    shuf.put(cur)           ; (played in this round)
            }
            K_UP -> up()
            K_DIR -> {
                cd(nameptrs[cur])
                scan(0)
            }
        }
    }

    ; DEL: the folder above (the cursor on the one left)
    sub up() {
        if count == 0 or kind[0] != K_UP
            return
        main.copy(&leaf, &back)
        cd(iso:"..")
        scan(&back)
    }

    sub cd(uword name) {
        cmd[0] = 'c'                    ; (PETSCII: "CD:", as diskio.chdir)
        cmd[1] = 'd'
        cmd[2] = ':'
        main.copy(name, &cmd + 3)
        diskio.send_command(&cmd)
    }

    ; insertion sort: kind, then the name (case ignored, then as is)
    sub sort() {
        if count < 2
            return
        ubyte i
        for i in 1 to count - 1 {
            uword pn = nameptrs[i]
            ubyte pk = kind[i]
            ubyte j = i
            while j != 0 and before(pk, pn, kind[j - 1], nameptrs[j - 1]) {
                nameptrs[j] = nameptrs[j - 1]
                kind[j] = kind[j - 1]
                j--
            }
            nameptrs[j] = pn
            kind[j] = pk
        }
    }

    sub before(ubyte ka, uword a, ubyte kb, uword b) -> bool {
        if ka != kb
            return ka < kb
        byte c = main.cmpname(a, b, true)
        if c == 0
            c = main.cmpname(a, b, false)
        return c < 0
    }

    ; the titles: up to 63 bytes, not cutting a Shift_JIS character, always ended by $0d
    sub titles() {
        if first >= count
            return
        ui.status(iso:"reading titles...", theme.HEAD)
        ubyte i
        for i in first to count - 1 {
            sys.memset(&buf, 64, 0)
            if diskio.f_open(nameptrs[i]) {
                void diskio.f_read(&buf, 64)
                diskio.f_close()
            }
            buf[cut()] = $0d
            ubyte ob = cx16.getrambank()
            cx16.rambank(TITLEBANK)
            sys.memcopy(&buf, $a000 + (i as uword) * 64, 64)
            cx16.rambank(ob)
        }
    }

    ; length of the title in buf (<= 63)
    sub cut() -> ubyte {
        ubyte n = 0
        while n < 63 {
            ubyte c = buf[n]
            if c == $0d or c == $0a or c == $1a or c == 0
                break
            if (c >= $81 and c <= $9f) or (c >= $e0 and c <= $fc) {
                if n == 62 or buf[n + 1] == 0
                    break
                n += 2
            } else
                n++
        }
        return n
    }

    ; *.MDX (case ignored)
    sub is_mdx() -> bool {
        if dlen < 5 or dlen > 64
            return false
        return dname[dlen - 4] == '.' and (dname[dlen - 3] | $20) == $6d and (dname[dlen - 2] | $20) == $64 and (dname[dlen - 1] | $20) == $78
    }

    ; ---- the directory listing, read here (the names bounded: diskio's buffer is 50 bytes)
    ubyte[65] dname                 ; name (64 bytes kept)
    ubyte dlen                      ; its full length (255: longer)
    ubyte dtype                     ; first letter of the type ($44 "DIR")

    ; "$" (the entries) or "$=c" (the path: this folder, its parent, .., "/")
    sub dir_open(bool pathlist) -> bool {
        if pathlist
            cbm.SETNAM(3, "$=c")
        else
            cbm.SETNAM(1, "$")
        cbm.SETLFS(diskio.READ_IO_CHANNEL, diskio.drivenumber, 0)
        void cbm.OPEN()
        if_cs {
            cbm.CLOSE(diskio.READ_IO_CHANNEL)
            return false
        }
        diskio.reset_read_channel()
        repeat 4
            void cbm.CHRIN()                        ; (load address, link)
        if cbm.READST() == 0
            return true
        dir_close()
        return false
    }

    sub dir_close() {
        cbm.CLRCHN()
        cbm.CLOSE(diskio.READ_IO_CHANNEL)
    }

    sub dir_next() -> bool {
        void cbm.CHRIN()                            ; (blocks)
        void cbm.CHRIN()
        if cbm.READST() != 0
            return false
        while cbm.CHRIN() != '"' {
            if cbm.READST() != 0
                return false
        }
        dlen = 0
        repeat {
            ubyte c = cbm.CHRIN()
            if c == 0 or c == '"'
                break
            if dlen < 64
                dname[dlen] = c
            if dlen != 255
                dlen++
        }
        if dlen < 64
            dname[dlen] = 0
        else
            dname[64] = 0
        do {
            dtype = cbm.CHRIN()
        } until dtype != ' '
        while cbm.CHRIN() != 0 {
        }
        void cbm.CHRIN()                            ; (link)
        void cbm.CHRIN()
        return true
    }

    ; path and leaf of the current folder ("" if not known)
    ubyte[81] pbuf
    sub readpath() {
        path[0] = 0
        leaf[0] = 0
        ubyte pos = 80
        pbuf[80] = 0
        bool ok = false
        bool firstpart = true
        if dir_open(true) {
            ok = true
            void dir_next()                         ; (the disk name line)
            while dir_next() {
                if dname[0] == '/' and dname[1] == 0
                    continue
                if dlen > 63 or dlen + 1 > pos {
                    ok = false
                    continue
                }
                if firstpart
                    main.copy(&dname, &leaf)
                firstpart = false
                pos -= dlen
                sys.memcopy(&dname, &pbuf + pos, dlen)
                pos--
                pbuf[pos] = '/'
            }
            dir_close()
        }
        if not ok
            return
        if pos == 80 {
            path[0] = '/'
            path[1] = 0
        } else
            sys.memcopy(&pbuf + pos, &path, 81 - pos)
    }

    sub move(byte d) {
        if count == 0
            return
        word n = (cur as word) + d
        if n < 0
            n = 0
        if n >= (count as word)
            n = (count as word) - 1
        select(lsb(n))
    }

    sub select(ubyte i) {
        cur = i
        draw()
    }

    sub draw() {
        if cur < top
            top = cur
        if cur >= top + ROWS
            top = cur - ROWS + 1
        ubyte r
        for r in 0 to ROWS - 1 {
            ubyte row = ui.SELROW + r
            ubyte i = top + r
            uword tile = kanji.T_SEL + (r as uword) * 64
            scr.fill(0, row, 26, ' ', theme.TEXT)
            if i < count {
                ubyte color = theme.TEXT
                ubyte pal = theme.P_SEL
                if i == cur {
                    color = theme.WHITE
                    pal = theme.P_CUR
                    scr.ch(0, row, '>', theme.WHITE)
                }
                if i == main.playing_idx
                    scr.ch(1, row, '*', theme.KEYON)
                when kind[i] {
                    K_MDX -> {
                        void scr.printn(2, row, nameptrs[i], 13, color)
                        void kanji.text(16, row, 64, tile, pal, TITLEBANK, $a000 + (i as uword) * 64)
                    }
                    else -> {
                        ubyte n = scr.printn(2, row, nameptrs[i], 12, color)
                        if kind[i] == K_DIR
                            scr.ch(2 + n, row, '/', color)
                        kanji.clear(16, row, 64)
                        if kind[i] == K_UP
                            scr.print(16, row, iso:"<PARENT>", theme.LABEL)
                        else
                            scr.print(16, row, iso:"<DIR>", theme.LABEL)
                    }
                }
            } else
                kanji.clear(16, row, 64)
        }
    }
}

; ---------------------------------------------------------------------------
; shuffle (S): the MDX files of the list shown in a random order.
; order[0 .. done-1] were played in this round; N / auto play order[done], P goes back one.
; When all were played, a new round (a new order) whose first is not the song just played
; (unless there is only one). The table is made again for each list read (sel.scan).
shuf {
    ubyte[128] order                ; list indices (sel.MAXENT)
    ubyte n                         ; MDX files in the table (0: N / P do nothing)
    ubyte done

    ; the table for the list shown; the song playing, if in it, counts as played
    sub build() {
        n = sel.count - sel.first
        done = 0
        if n == 0
            return
        ubyte i
        for i in 0 to n - 1
            order[i] = sel.first + i
        mix()
        if main.playing_idx != 255
            put(main.playing_idx)
    }

    ; Fisher-Yates
    sub mix() {
        ubyte i = n - 1
        while i != 0 {
            ubyte j = math.randrange(i + 1)
            ubyte t = order[i]
            order[i] = order[j]
            order[j] = t
            i--
        }
    }

    ; entry idx played from the list (RETURN): played in this round, unless it already was
    sub put(ubyte idx) {
        if done >= n
            return
        ubyte i
        for i in done to n - 1 {
            if order[i] == idx {
                order[i] = order[done]
                order[done] = idx
                done++
                return
            }
        }
    }

    ; N / auto: the entry to play (255: none)
    sub next() -> ubyte {
        if n == 0
            return 255
        if done >= n {
            ubyte last = main.playing_idx
            if last == 255
                last = order[n - 1]
            mix()
            done = 0
            if n > 1 and order[0] == last {
                ubyte j = 1 + math.randrange(n - 1)
                order[0] = order[j]
                order[j] = last
            }
        }
        done++
        return order[done - 1]
    }

    ; P: the one before in this round (the first again at its start)
    sub prev() -> ubyte {
        if n == 0
            return 255
        if done >= 2
            done--
        else
            done = 1
        return order[done - 1]
    }
}

; ---------------------------------------------------------------------------
; (AUTOTEST) the keys from script AUTONAV instead of the keyboard (the test scripts), with
; test codes: $f0 print the list, $f1 wait 30 frames, $f2 wait for the song's end (at most
; 6000 frames), $f3 print the song playing, $f4 print the titles' lengths, $f9 print a sum of
; the font bank, $ff print the PCM state and exit x16emu
nav {
    ubyte pos
    uword wait
    bool waitend
    ; 1: the folders of the test root (alpha/, Zeta/, MDX files with odd titles)
    ubyte[] s1 = [$f0, $f4,
                  $9d, $f0, $1d, $f0,               ; page up, page down
                  $9d, $0d, $f0,                    ; into alpha/
                  $0d, $f1, $f3,                    ; play its MDX
                  $14, $f0, $f3,                    ; up: the cursor on alpha/, the song plays on
                  $0d, $f0,                         ; alpha/ again: the song marked
                  $14, $11, $0d, $f0,               ; into Zeta/ (no MDX)
                  $6e, $f3,                         ; N: nothing
                  $f2, $f3,                         ; the song ends: no next (no MDX here)
                  $14, $f0, $ff]
    ; 2: a song with heavy PCM playing while the list is read again and again
    ubyte[] s2 = [$0d, $0d, $f1, $f3,
                  $14, $f1, $0d, $f1, $14, $f1, $0d, $f1, $14, $f1, $0d, $f1, $14, $f1, $0d, $f1,
                  $14, $f1, $0d, $f1, $14, $f1, $0d, $f1, $14, $f1, $0d, $f1, $14, $f1, $0d, $f1,
                  $f0, $f3, $ff]
    ; 3: the list only (a long name, too many entries), play the first MDX
    ubyte[] s3 = [$f0, $0d, $f1, $f3, $ff]
    ; 4: a folder with a path of 64 to 80 characters: the song marked after up and in, N / P
    ubyte[] s4 = [$0d, $0d, $0d, $f1, $f3,          ; down two folders, play the first MDX
                  $14, $0d, $f0,                    ; up and in again: the song marked
                  $6e, $f1, $f3, $70, $f1, $f3,     ; N: the next MDX, P: back
                  $ff]
    ; 5: shuffle (root: five/ with 5 MDX files, none/ without, one/ with 1)
    ubyte[] s5 = [$0d, $f0,                         ; into five/
                  $73, $f7, $f5,                    ; S: on; round boundaries 200 times; table
                  $6e, $f1, $f3, $6e, $f1, $f3, $6e, $f1, $f3, $6e, $f1, $f3, $6e, $f1, $f3,
                  $f5,                              ; N 5 times: the round
                  $6e, $f1, $f3, $f5,               ; N: a new round
                  $70, $f1, $f3,                    ; P at its start: its first again
                  $9d, $11, $0d, $f1, $f3, $f5,     ; RETURN on the first MDX: played in the round
                  $f8, $f5,                         ; N to the round's end
                  $f6, $f3, $f5,                    ; the song ends: auto next, a new round
                  $14, $11, $11, $0d, $f0,          ; up, into one/
                  $6e, $f1, $f3, $6e, $f1, $f3, $f5, ; N, N: the only song again
                  $14, $91, $0d, $f0,               ; up, into none/
                  $6e, $f1, $f3, $f5,               ; N: nothing
                  $73, $f5, $ff]                    ; S: off
    ; 6: big.mdx (70000 bytes) is refused and the font bank right after the MDX banks stays
    ;    as it was; max.mdx (65535) plays; noterm.mdx (PDX name without its 0), short.mdx
    ;    (body of 33 bytes) and tiny.mdx (0D 0A 1A 00) are not MDX files
    ubyte[] s6 = [$f9, $f0,
                  $0d, $f1, $f3, $f9,               ; big.mdx
                  $11, $0d, $f1, $f3, $f9,          ; max.mdx
                  $11, $0d, $f1, $f3,               ; noterm.mdx
                  $11, $0d, $f1, $f3,               ; short.mdx
                  $11, $0d, $f1, $f3, $f9, $ff]     ; tiny.mdx
    ubyte waitplays
    bool waitnext

    sub key() -> ubyte {
        if wait != 0 {
            wait--
            if waitend and not main.playing
                wait = 0
            if waitnext and main.plays != waitplays
                wait = 0
            return 0
        }
        waitend = false
        waitnext = false
        ubyte k
        when main.AUTONAV {
            1 -> k = s1[pos]
            2 -> k = s2[pos]
            3 -> k = s3[pos]
            4 -> k = s4[pos]
            5 -> k = s5[pos]
            else -> k = s6[pos]
        }
        pos++
        when k {
            $f0 -> list()
            $f1 -> wait = 30
            $f2 -> {
                wait = 6000
                waitend = true
            }
            $f3 -> song()
            $f4 -> titles()
            $f5 -> table()
            $f6 -> {
                wait = 6000
                waitplays = main.plays
                waitnext = true
            }
            $f7 -> shuftest()
            $f8 -> {
                while shuf.done < shuf.n {
                    main.next_song(1)
                    song()
                }
            }
            $f9 -> font()
            $ff -> finish()
            else -> return k
        }
        return 0
    }

    sub list() {
        txt.print(iso:"LIST ")
        txt.print(&sel.path)
        txt.print(iso:" C=")
        txt.print_ub(sel.cur)
        txt.print(iso:" P=")
        txt.print_ub(main.playing_idx)
        txt.print(iso:":")
        ubyte i
        if sel.count != 0 {
            for i in 0 to sel.count - 1 {
                txt.spc()
                txt.print(sel.nameptrs[i])
                if sel.kind[i] != sel.K_MDX
                    txt.chrout('/')
            }
        }
        txt.nl()
    }

    sub font() {                        ; a sum of the first font bank (right after the MDX's)
        uword sum = 0
        uword a
        cx16.rambank(kanji.FONTBANK)
        for a in $a000 to $bfff
            sum += @(a)
        txt.print(iso:"FONT ")
        txt.print_uw(sum)
        txt.nl()
    }

    sub song() {
        txt.print(iso:"SONG ")
        txt.print(&main.playname)
        txt.print(iso:" P=")
        txt.print_ub(main.playing_idx)
        txt.print(iso:" ON=")
        txt.print_ub(main.playing as ubyte)
        txt.nl()
    }

    sub titles() {
        txt.print(iso:"TITLES")
        ubyte i
        if sel.first < sel.count {
            for i in sel.first to sel.count - 1 {
                ubyte n = 0
                cx16.rambank(sel.TITLEBANK)
                while n < 64 and @($a000 + (i as uword) * 64 + n) != $0d
                    n++
                txt.spc()
                txt.print(sel.nameptrs[i])
                txt.chrout('=')
                txt.print_ub(n)
            }
        }
        txt.nl()
    }

    sub table() {
        if not main.shuffle {
            txt.print(iso:"SHUF OFF")
            txt.nl()
            return
        }
        txt.print(iso:"SHUF ON N=")
        txt.print_ub(shuf.n)
        txt.print(iso:" D=")
        txt.print_ub(shuf.done)
        txt.print(iso:":")
        ubyte i
        if shuf.n != 0 {
            for i in 0 to shuf.n - 1 {
                txt.spc()
                txt.print(sel.nameptrs[shuf.order[i]])
            }
        }
        txt.nl()
    }

    ; 200 rounds of N (each song started at once): each round has every MDX once, and its
    ; first is not the last of the round before (unless only one)
    ubyte[128] seen
    sub shuftest() {
        ubyte saved = main.playing_idx
        uword bad = 0
        ubyte prev = 255
        ubyte r
        ubyte i
        ubyte x
        shuf.done = shuf.n
        for r in 1 to 200 {
            sys.memset(&seen, 128, 0)
            for i in 1 to shuf.n {
                x = shuf.next()
                main.playing_idx = x
                if i == 1 and shuf.n > 1 and x == prev
                    bad++
                seen[x]++
            }
            prev = x
            for i in sel.first to sel.count - 1 {
                if seen[i] != 1
                    bad++
            }
        }
        main.playing_idx = saved
        shuf.build()
        txt.print(iso:"SHUFTEST ROUNDS=200 BAD=")
        txt.print_uw(bad)
        txt.nl()
    }

    sub finish() {
        ubyte voices
        uword under
        voices, under = mxdrv.pcmstat()
        ubyte st
        uword loops
        st, loops = mxdrv.status()
        mxdrv.stop()
        txt.print(iso:"NAVEND UNDERRUNS=")
        txt.print_uw(under)
        if st & 8 != 0
            txt.print(iso:" PCM ON")
        else
            txt.print(iso:" PCM OFF")
        txt.nl()
        %asm {{
            jmp $ffff
        }}
    }
}

; ---------------------------------------------------------------------------
; the digit row (1-9, 0, -) for the channel mute, by key number through the KERNAL's key
; handler hook (KEYHDL $032E, R43+): the same keys on every keyboard layout, SHIFT / CTRL
; seen as keys too. Those keys are taken (not passed on to GETIN); the others pass.
keys {
    const ubyte K_LSHIFT = $2c
    const ubyte K_RSHIFT = $39
    const ubyte K_LCTRL = $3a
    const ubyte K_RCTRL = $40
    ubyte[8] q                      ; key number | $80 with SHIFT / CTRL held
    ubyte qw
    ubyte qr
    ubyte mods                      ; bit 0 L shift, 1 R shift, 2 L ctrl, 3 R ctrl
    uword oldhdl
    ubyte[4] modbits = [1, 2, 4, 8]

    sub install() {
        qw = 0
        qr = 0
        mods = 0
        sys.set_irqd()
        oldhdl = cx16.KEYHDL
        cx16.KEYHDL = &handler
        sys.clear_irqd()
    }

    sub uninstall() {
        sys.set_irqd()
        cx16.KEYHDL = oldhdl
        sys.clear_irqd()
    }

    sub take() -> ubyte {
        ubyte k = q[qr]
        qr = (qr + 1) & 7
        return k
    }

    ; A = key number (bit 7: released) -> A = the event to pass on (0: taken)
    asmsub handler(ubyte code @A) -> ubyte @A {
        %asm {{
            phx
            pha
            and  #$7f
            ldx  #0
            cmp  #p8c_K_LSHIFT
            beq  _mod
            inx
            cmp  #p8c_K_RSHIFT
            beq  _mod
            inx
            cmp  #p8c_K_LCTRL
            beq  _mod
            inx
            cmp  #p8c_K_RCTRL
            beq  _mod
            cmp  #$02                   ; 1 .. 0, -
            bcc  _pass
            cmp  #$0d
            bcs  _pass
            tax
            pla
            bmi  _take                  ; (released: taken too)
            lda  p8v_mods
            beq  +
            txa
            ora  #$80
            tax
+           txa
            ldx  p8v_qw
            sta  p8v_q,x
            inx
            txa
            and  #7
            cmp  p8v_qr                 ; (full: dropped)
            beq  _take
            sta  p8v_qw
_take       plx
            lda  #0
            rts
_mod        lda  p8v_modbits,x          ; modifier: remember, pass on
            tax
            pla
            pha
            bmi  _up
            txa
            ora  p8v_mods
            bra  _set
_up         txa
            eor  #$ff
            and  p8v_mods
_set        sta  p8v_mods
_pass       pla
            plx
            rts
        }}
    }

    ; (AUTOTEST + AUTOKEYS) key events through the handler -> the masks after each group, and
    ; what the handler passed on for a few keys: "KEYS fm:pcm ... RET=.."
    ubyte[30] script = [$02, $82,                           ; 1
                        $2c, $03, $83, $ac,                 ; L shift + 2
                        $40, $09, $89, $c0,                 ; R ctrl + 8
                        $04, $84,                           ; 3
                        $0c, $8c,                           ; -
                        $0b, $8b,                           ; 0
                        $0a, $8a,                           ; 9
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    ubyte[7] ends = [2, 6, 10, 12, 14, 16, 18]
    sub selftest() {
        ubyte i = 0
        ubyte g
        txt.print(iso:"KEYS")
        for g in 0 to 6 {
            while i < ends[g] {
                void feed(script[i])
                i++
            }
            while qr != qw
                main.mute_key(take())
            txt.spc()
            txt.print_ubhex(main.mute_fm, false)
            txt.chrout(':')
            txt.print_ubhex(main.mute_pcm, false)
        }
        txt.print(iso:" RET=")
        txt.print_ubhex(feed($1f), false)                  ; a: passed
        txt.chrout(',')
        txt.print_ubhex(feed($2c), false)                  ; L shift: passed
        txt.chrout(',')
        txt.print_ubhex(feed($05), false)                  ; 4 with L shift: taken
        void feed($ac)
        txt.chrout(',')
        txt.print_ubhex(feed($85), false)                  ; (released: taken)
        while qr != qw
            void take()
        txt.nl()
    }

    sub feed(ubyte code) -> ubyte {
        cx16.r0L = code
        %asm {{
            php
            sei
            lda  cx16.r0L
            jsr  p8b_keys.p8s_handler
            sta  cx16.r0L
            plp
        }}
        return cx16.r0L
    }
}
