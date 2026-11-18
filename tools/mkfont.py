#!/usr/bin/env python3
"""mkfont: Misaki 8x8 BDF (Unicode) -> KANJI8.BIN for the X16 player.

KANJI8.BIN (load headerless to $A000 of a RAM bank; it spans 9 banks):
  0..511    single-byte table: 256 little-endian glyph indices for Shift_JIS single-byte
            codes (ASCII and half-width katakana mapped to their full-width glyphs),
            $FFFF = none
  512..     94 x 94 glyphs (JIS X 0208 rows/cells, cp932 incl. NEC row 13), 8 bytes each,
            index = (row - 1) * 94 + (cell - 1); bit 7 = left pixel, empty glyph if missing

usage: mkfont.py [bdf] [out]   (default thirdparty/misaki/misaki_gothic_2nd.bdf -> build/player/KANJI8.BIN)
"""
import os
import sys
import unicodedata


def load_bdf(path):
    glyphs = {}
    asc = 6
    with open(path, encoding='latin-1') as f:
        lines = iter(f.read().split('\n'))
    for line in lines:
        if line.startswith('FONT_ASCENT'):
            asc = int(line.split()[1])
        if line.startswith('STARTCHAR'):
            enc, bbx, rows = None, None, []
            for line in lines:
                if line.startswith('ENCODING'):
                    enc = int(line.split()[1])
                elif line.startswith('BBX'):
                    bbx = [int(v) for v in line.split()[1:]]
                elif line.startswith('BITMAP'):
                    for line in lines:
                        if line.startswith('ENDCHAR'):
                            break
                        rows.append(int(line, 16) >> (len(line) * 4 - 8))
                    break
            w, h, xo, yo = bbx
            cell = [0] * 8
            top = asc - (yo + h)
            for i, r in enumerate(rows):
                y = top + i
                if 0 <= y < 8:
                    cell[y] = (r >> xo) & 0xFF
            glyphs[enc] = bytes(cell)
    return glyphs


def main():
    bdf = sys.argv[1] if len(sys.argv) > 1 else 'thirdparty/misaki/misaki_gothic_2nd.bdf'
    out = sys.argv[2] if len(sys.argv) > 2 else 'build/player/KANJI8.BIN'
    g = load_bdf(bdf)
    table = bytearray()
    found = {}
    cells = bytearray(94 * 94 * 8)
    for r in range(94):
        for c in range(94):
            j1, j2 = r + 0x21, c + 0x21
            s1 = (j1 + 1) // 2 + (0x70 if j1 <= 0x5E else 0xB0)
            s2 = j2 + (0x1F if j1 & 1 else 0x7E)
            if s2 >= 0x7F and j1 & 1:
                s2 += 1
            try:
                ch = bytes([s1, s2]).decode('cp932')
            except UnicodeDecodeError:
                continue
            u = ord(ch)
            if u in g:
                cells[(r * 94 + c) * 8:(r * 94 + c) * 8 + 8] = g[u]
                found.setdefault(u, r * 94 + c)
    for b in range(256):
        idx = 0xFFFF
        try:
            ch = bytes([b]).decode('cp932')
        except UnicodeDecodeError:
            ch = None
        if ch is not None and b >= 0x20 and b != 0x7F:
            if b == 0x20:
                fw = '　'
            elif b < 0x80:
                fw = chr(ord(ch) + 0xFEE0)          # full-width ASCII
            else:
                fw = unicodedata.normalize('NFKC', ch)[:1]   # half-width katakana
            if b == 0x5C:
                fw = '＼'                        # backslash (not yen)
            idx = found.get(ord(fw), 0xFFFF)
        table += idx.to_bytes(2, 'little')
    os.makedirs(os.path.dirname(out) or '.', exist_ok=True)
    with open(out, 'wb') as f:
        f.write(table + cells)
    n = sum(1 for i in range(94 * 94) if any(cells[i * 8:i * 8 + 8]))
    print('%s: %d glyphs (%d bytes)' % (out, n, len(table) + len(cells)))


if __name__ == '__main__':
    main()
