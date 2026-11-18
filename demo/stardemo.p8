; stardemo.p8 - X16MXDRV embedding sample: a small game with MDX background music.
;
;   left / right (cursor keys, or joystick 1): move   space: restart after game over
;   f: fade out the music   q: quit
;
; Files next to the program: X16MXDRV.BIN, BGM.MDX and BGM.P16 (PCM pack, tools/mkpack.py)
; or the PDX named in BGM.MDX. Sound effects use the VERA PSG (the driver does not).
; Driver resources: RAM banks 1-4, golden RAM $0400-$07FF (no zero page of its own).

%import textio
%import diskio
%import math
%import x16mxdrv
%zeropage basicsafe

main {
    const ubyte MDXBANK = 5
    const ubyte PCMBANK = 12
    const ubyte LUTSLOTS = 8
    const ubyte W = 40              ; playfield columns 20..59
    const ubyte LEFT = 20
    const ubyte TOP = 6
    const ubyte SHIPROW = 54
    const ubyte NSTARS = 8
    const uword AUTOFRAMES = 0      ; tests: exit x16emu after this many frames

    ubyte shipx = 20
    uword score
    ubyte misses
    bool over
    ubyte[NSTARS] sx
    ubyte[NSTARS] sy
    ubyte[NSTARS] sspeed
    ubyte[NSTARS] stimer
    ubyte sfx_vol
    ubyte frame

    sub start() {
        txt.iso()
        txt.color2(1, 0)
        txt.clear_screen()
        cbm.SETMSG(0)
        txt.plot(0, 0)
        txt.print(iso:"loading...")
        ; --- X16MXDRV setup
        cx16.rambank(mxdrv.BANK)
        if diskio.load_raw(iso:"X16MXDRV.BIN", $a000) == 0 {
            txt.print(iso:" X16MXDRV.BIN not found")
            return
        }
        void mxdrv.init()
        uword lut = memory("mxlut", LUTSLOTS as uword * 512, 256)
        bool pcm = false
        if cx16.numbanks() > PCMBANK + 8
            pcm = not mxdrv.pcmmem(PCMBANK, lsb(cx16.numbanks() - 1), msb(lut), LUTSLOTS)
        cx16.rambank(MDXBANK)
        uword endaddr = diskio.load_raw(iso:"BGM.MDX", $a000)
        if endaddr != 0 and not mxdrv.setmdx(MDXBANK, $a000, lsw(diskio.load_size(MDXBANK, $a000, endaddr))) {
            if pcm {
                ; the PCM pack (tools/mkpack.py), else the PDX
                if mxdrv.loadpack(iso:"BGM.P16", PCMBANK, lsb(cx16.numbanks() - 1)) != mxdrv.PK_OK
                    void mxdrv.loadpdx(memory("pdxbuf", 512, 0), 512)
            }
            mxdrv.play()
        }
        ; --- game
        txt.clear_screen()
        new_game()
        uword frames = 0
        repeat {
            vsync()
            frame++
            frames++
            if AUTOFRAMES != 0 and frames == AUTOFRAMES {
                mxdrv.stop()
                %asm {{
                    jmp $ffff
                }}
            }
            sfx_update()
            ubyte key = cbm.GETIN2()
            when key {
                iso:'f', iso:'F' -> mxdrv.fadeout(0)
                iso:'q', iso:'Q' -> {
                    mxdrv.stop()
                    psg_off()
                    txt.iso_off()
                    txt.clear_screen()
                    return
                }
                ' ' -> {
                    if over
                        new_game()
                }
            }
            if not over {
                move_ship()
                stars()
            } else if AUTOFRAMES != 0
                new_game()
            status()
        }
    }

    ; wait for the next jiffy (sys.waitvsync() also returns on the driver's 2 ms IRQ)
    sub vsync() {
        ubyte j = lsb(cbm.RDTIM16())
        while lsb(cbm.RDTIM16()) == j
            sys.waitirq()
    }

    sub new_game() {
        txt.clear_screen()
        txt.color2(7, 0)
        txt.plot(LEFT, 1)
        txt.print(iso:"STAR CATCH  -  X16MXDRV BGM demo")
        txt.color2(15, 0)
        txt.plot(LEFT, 2)
        txt.print(iso:"cursor keys: move   F: fade BGM   Q: quit")
        ubyte r
        for r in TOP - 1 to SHIPROW + 1 {
            txt.setcc(LEFT - 1, r, iso:'|', 11)
            txt.setcc(LEFT + W, r, iso:'|', 11)
        }
        ubyte c
        for c in LEFT - 1 to LEFT + W
            txt.setcc(c, SHIPROW + 2, iso:'-', 11)
        score = 0
        misses = 0
        over = false
        shipx = LEFT + W / 2 - 1
        ubyte i
        for i in 0 to NSTARS - 1
            new_star(i)
        draw_ship()
    }

    sub new_star(ubyte i) {
        sx[i] = LEFT + math.rnd() % W
        sy[i] = TOP + math.rnd() % 20
        sspeed[i] = 2 + math.rnd() % 4          ; frames per row
        stimer[i] = sspeed[i]
    }

    sub draw_ship() {
        txt.setcc(shipx - 1, SHIPROW, ' ', 1)
        txt.setcc(shipx, SHIPROW, iso:'<', 13)
        txt.setcc(shipx + 1, SHIPROW, iso:'=', 13)
        txt.setcc(shipx + 2, SHIPROW, iso:'>', 13)
        txt.setcc(shipx + 3, SHIPROW, ' ', 1)
    }

    sub move_ship() {
        uword joy
        bool present
        joy, present = cx16.joystick_get(0)     ; keyboard joystick: cursor keys (active low)
        bool left = (joy & %0000_0010) == 0
        bool right = (joy & %0000_0001) == 0
        if AUTOFRAMES != 0 {                    ; (tests: wander)
            left = frame & 64 != 0
            right = not left
        }
        if left and shipx > LEFT {
            shipx--
            draw_ship()
        } else if right and shipx < LEFT + W - 3 {
            shipx++
            draw_ship()
        }
    }

    sub stars() {
        ubyte i
        for i in 0 to NSTARS - 1 {
            stimer[i]--
            if stimer[i] != 0
                continue
            stimer[i] = sspeed[i]
            if sy[i] >= TOP
                txt.setcc(sx[i], sy[i], ' ', 1)
            sy[i]++
            if sy[i] == SHIPROW {
                if sx[i] >= shipx and sx[i] <= shipx + 2 {
                    score += 10
                    sfx(800)
                    new_star(i)
                    sy[i] = TOP - 1
                    draw_ship()
                    continue
                }
            }
            if sy[i] > SHIPROW + 1 {
                misses++
                sfx(150)
                new_star(i)
                sy[i] = TOP - 1
                if misses >= 10
                    game_over()
                continue
            }
            if sy[i] >= TOP
                txt.setcc(sx[i], sy[i], iso:'*', 7)
        }
    }

    sub game_over() {
        over = true
        txt.color2(2, 0)
        txt.plot(LEFT + 13, 30)
        txt.print(iso:"G A M E  O V E R")
        txt.color2(1, 0)
        txt.plot(LEFT + 10, 32)
        txt.print(iso:"press SPACE to play again")
    }

    sub status() {
        txt.color2(1, 0)
        txt.plot(LEFT, 4)
        txt.print(iso:"SCORE ")
        txt.print_uw0(score)
        txt.print(iso:"   MISS ")
        txt.print_ub(misses)
        txt.print(iso:"/10   BGM ")
        ubyte st
        uword loops
        st, loops = mxdrv.status()
        if st & 1 == 0
            txt.print(iso:"off ")
        else if st & 4 != 0
            txt.print(iso:"fade")
        else
            txt.print(iso:"on  ")
    }

    ; --- sound effects on PSG voice 15 (VERA PSG at VRAM $1F9C0)
    sub sfx(uword freq) {
        uword f = freq * 3 - freq / 4           ; Hz -> PSG units (~2.68 per Hz)
        cx16.vpoke(1, $f9c0 + 15 * 4, lsb(f))
        cx16.vpoke(1, $f9c0 + 15 * 4 + 1, msb(f))
        cx16.vpoke(1, $f9c0 + 15 * 4 + 3, %10_111111)     ; triangle
        sfx_vol = 63
    }
    sub sfx_update() {
        if sfx_vol != 0 {
            sfx_vol -= 3
            if sfx_vol > 63
                sfx_vol = 0
        }
        cx16.vpoke(1, $f9c0 + 15 * 4 + 2, %11000000 | sfx_vol)
    }
    sub psg_off() {
        cx16.vpoke(1, $f9c0 + 15 * 4 + 2, 0)
    }
}
