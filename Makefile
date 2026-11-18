# x16mxdrv - X16MXDRV (MDX driver) and mdxplay (MDX player) for the Commander X16
#
#   make            driver + player (+ font)          -> build/
#   make driver     build/driver/X16MXDRV.BIN          (ca65 / cl65)
#   make player     build/player/MDXPLAY.PRG, KANJI8.BIN   (prog8 + Python 3)
#   make demo       build/demo/STARDEMO.PRG           (prog8: the driver in a small game)
#   make cc65demo   build/demo/CC65DEMO.PRG           (cc65: the driver from C)
#   make dist       build/dist/: X16MXDRV.BIN, MDXPLAY.PRG, KANJI8.BIN (copy to the SD card),
#                   README.TXT, LICENSE.TXT, MISAKI.TXT
#   make tables     regenerate driver/src/mxtables.inc and adpcmtab.inc (tools/gentables.py)
#   make clean
#
# Needs cc65 (cl65, ca65) 2.19+, prog8 (prog8c) 12+ and Python 3 on the PATH.

PYTHON  ?= python3
PROG8C  ?= prog8c
CL65    ?= cl65

DRVSRC  := driver/src/mx16.s driver/src/mxlow.s driver/src/mxpcm.s driver/src/mxload.s driver/src/mxcore.s \
           driver/src/mxpack.s driver/src/mxmute.s driver/src/mxhdr.s
DRVDEPS := $(DRVSRC) $(wildcard driver/src/*.inc) driver/x16mxdrv.cfg
INCDEPS := $(wildcard driver/include/*)

.PHONY: all driver player demo cc65demo dist tables clean

all: driver player

driver: build/driver/X16MXDRV.BIN
player: build/player/MDXPLAY.PRG build/player/KANJI8.BIN
demo: build/demo/STARDEMO.PRG
cc65demo: build/demo/CC65DEMO.PRG

build/driver/X16MXDRV.BIN: $(DRVDEPS)
	@mkdir -p build/driver
	$(CL65) -t none --cpu 65C02 --asm-include-dir driver/src -C driver/x16mxdrv.cfg \
	  -o $@ -m build/driver/x16mxdrv.map $(DRVSRC)

build/player/MDXPLAY.PRG: player/mdxplay.p8 $(INCDEPS)
	@mkdir -p build/player
	cd build/player && $(PROG8C) -target cx16 -srcdirs ../../driver/include ../../player/mdxplay.p8 > prog8c.log
	mv build/player/mdxplay.prg $@

build/player/KANJI8.BIN: tools/mkfont.py thirdparty/misaki/misaki_gothic_2nd.bdf
	@mkdir -p build/player
	$(PYTHON) tools/mkfont.py thirdparty/misaki/misaki_gothic_2nd.bdf $@

build/demo/STARDEMO.PRG: demo/stardemo.p8 $(INCDEPS)
	@mkdir -p build/demo
	cd build/demo && $(PROG8C) -target cx16 -srcdirs ../../driver/include ../../demo/stardemo.p8 > prog8c.log
	mv build/demo/stardemo.prg $@

build/demo/CC65DEMO.PRG: demo/cc65demo.c $(INCDEPS)
	@mkdir -p build/demo
	$(CL65) -t cx16 -O -I driver/include -o $@ demo/cc65demo.c driver/include/x16mxdrv_cc65.s

dist: driver player
	@rm -rf build/dist
	@mkdir -p build/dist
	cp build/driver/X16MXDRV.BIN build/player/MDXPLAY.PRG build/player/KANJI8.BIN \
	  dist/README.TXT build/dist/
	cp LICENSE build/dist/LICENSE.TXT
	cp thirdparty/misaki/misaki.txt build/dist/MISAKI.TXT

tables:
	$(PYTHON) tools/gentables.py

clean:
	rm -rf build
