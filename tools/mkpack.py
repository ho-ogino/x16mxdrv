#!/usr/bin/env python3
"""mkpack: pre-convert the PCM of MDX songs for X16MXDRV (fast loading; shared packs:
docs/api.md).

Does on the Mac what the driver's loader does on the X16 (driver/src/mxload.s): scan the
MDX PCM channels for (sample, rate) pairs, decode those PDX entries with the same
fixed-point ADPCM + 183 Hz first-order high-pass (the X68000's output high-pass), and lay
them out as RAM bank images. The result is bit-identical to what the X16 decodes itself.

--x68filter (needs numpy) decodes with the X68000's analog output filters instead, as far
as they can be applied before playback: the 183 Hz high-pass and the 3rd-order low-pass
(about -3 dB at 3.9 kHz). The figures (183 Hz first order; the low-pass response at 10
frequencies, derived from the X68000 CZ-600CE control circuit diagram) are those published
by Nano Drive 8 (Fujix1, https://github.com/Fujix1/NanoDrive8); the fit below (2nd order
3.8 kHz Q 0.78 x 1st order 7.3 kHz, within 0.1 dB of those points) and the filter are this
project's. The filter is a causal minimum-phase FIR (1024 taps per rate) that follows the
response up to half the sample's rate. Limits (docs/api.md 4.1):
  - above half the sample's rate nothing is filtered: the images of the playback's sample
    hold, which the X68000's low-pass removes, stay (at every rate, 15.6 kHz too)
  - each sample keeps its length: the filter's ring after the last sample is cut off
Such packs carry flag bit 2; they are not what the X16 decodes from the PDX.

usage:
  mkpack.py DIR [-r]                 every PDX the MDX files in DIR use -> <PDX>.P16 next to it
  mkpack.py A.MDX B.MDX ...          the same for the MDX files given
  mkpack.py X.PDX                    every sample of X.PDX at rate 4
  mkpack.py X.PDX A.MDX ...          the pairs these MDX files need, from X.PDX
  mkpack.py SONG.MDX [PDX] [-o OUT]  one song: version 1 pack <SONG>.P16 (as before)
  options: --all  -r  -d DIR  -o FILE  --shared  --check  --max-banks N  --prune  --x68filter
           (see USAGE)
Shared packs (version 2) hold the union of the pairs the songs of one PDX need (the pairs
of each song's 96-pair job table, in the loader's order). The PDX is looked for next to the
MDX only, by the name in the MDX (path dropped, upper case, .PDX added if there is no '.').
Exit code 1 on any problem (missing PDX, limits, pairs the driver can never load, --check).

File format (bank B = the first 8192 bytes; samples from bank B+1):
  version 1, bank B:
    0  'MXPK'   4  version (1)   5  entries n (<= 96)   6  sample banks   7  0
    8  n entries of 9 bytes: sample lo, sample hi, rate, bank (relative: 0 = B+1),
       address lo, address hi ($A000-$BF7F), length (ADPCM bytes, 24-bit little endian)
  version 2, bank B:
    0  'MXPK'   4  version (2)   5  flags (bit 0 shared, bit 1 every PDX sample,
       bit 2 --x68filter; the readers ignore the flags)
    6  sample banks nb   7  0   8  entries n (16-bit)   10  PDX table entries m (16-bit, <= 4096)
    12 sample part bytes S (24-bit; file size - 8192)   15  0   16  PDX size (24-bit)   19  0
    20 PDX CRC32   24  PDX name (12 bytes, NUL padded)   36  bitmap of the PDX entries
    that have data (ceil(m / 8) bytes)   then n entries as in version 1, by (sample, rate)
    (nb - 1) * 8192 < S <= (nb - 1) * 8192 + 8064
  banks B+1..: samples, 8064 bytes per bank + 128-byte copy of the next bank's start
       (not after the last bank); every sample is followed by 64 zero bytes
Then call mxdrv pcmpack(B) after setmdx.
"""
import os
import sys
import zlib

SBANK_DATA = 8064
SPAD = 64
NDIR = 96
DLT = [16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66,
       73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
       337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552]
DCT = [-1, -1, -1, -1, 2, 4, 6, 8] * 2
C1 = [16711, 12982, 8969, 6849, 4650]           # 1 - exp(-2 pi 183 / rate), x 65536 (mxload.s c1tab)
RATE_HZ = [15625 / 4, 15625 / 3, 15625 / 2, 15625 * 2 / 3, 15625]
# MDX command argument bytes for $E0-$FF: None = stop the walk, 'x' = special
CMDLEN = [None] * 7 + ['x'] + [0, 1, 'x', 'x', 'x', 1, 0, 1] + [1, None, 2, 2, 2, 2, 2, 0] + [1, 0, 0, 1, 1, 1, 2, 1]
E7LEN = [None, 1, 6, 1, 2, 1, 1]


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


# ---------------------------------------------------------------------------
# MDX scan (same superset as mxload.s l_begin / walk / add_note)
def mdx_body(d):
    i = d.index(b'\r\n\x1a') + 3
    j = d.index(b'\0', i)
    return d[i:j].decode('ascii', 'replace'), d[j + 1:]


def scan(body, driver_order=False):
    """(sample, rate) -> uses, in order of first use. driver_order: the order of the
    loader's job table (add_note walks the detune set from its last entry); the default
    order is the one the per-song packs were always built with (kept for identical files)."""
    be = lambda o: (body[o] << 8) | body[o + 1]
    jobs = {}
    for ch in range(8, 16):
        start = be(2 + 2 * ch)
        banks, rates, dets = {0}, {4}, [0]
        for pas in (0, 1):
            p, n = start, 0
            while p < len(body) and n < 65535:
                n += 1
                c = body[p]
                p += 1
                if c < 0x80:
                    continue
                if c < 0xE0:
                    note = c - 0x80
                    p += 1
                    if pas:
                        for d in (dets[::-1] if driver_order else dets):
                            v = (note + d) & 0xFF              # 8-bit as in add_note
                            idx = 0 if v & 0x80 else min(v, 95)
                            for b in sorted(banks):
                                smp = idx + 96 * b
                                for r in sorted(rates):
                                    if r <= 4:
                                        jobs[(smp, r)] = jobs.get((smp, r), 0) + 1
                    continue
                L = CMDLEN[c - 0xE0]
                if L is None:
                    break
                if L == 'x':
                    if c == 0xE7:
                        s = body[p]
                        p += 1
                        if s >= 7:
                            continue
                        if E7LEN[s] is None:
                            break
                        p += E7LEN[s]
                    else:                       # $EA-$EC
                        t = body[p]
                        p += 1
                        if not t & 0x80:
                            p += 4
                    continue
                if pas == 0 and c == 0xFD:
                    banks.add(body[p])
                elif pas == 0 and c == 0xED:
                    rates.add(body[p] & 7)
                elif pas == 0 and c == 0xF3:
                    v = s16(((body[p] << 8) | body[p + 1]) + 5) >> 6   # 16-bit, arithmetic
                    d = v & 0xFF                                       # (low byte, signed)
                    d = d - 256 if d & 0x80 else d
                    if d not in dets and len(dets) < 4:
                        dets.append(d)
                p += L
    return jobs


# ---------------------------------------------------------------------------
# decoder (exactly mxload.s dec_nib / build_hpf)
def hpf_tables(c):
    tl, th = [0] * 256, [0] * 256
    acc = 0
    for b in range(256):
        tl[b] = ((acc + 0x8000) >> 16) & 0xFF
        if b <= 128:
            v = ((acc + 128) >> 8) & 0xFFFF
            if b < 128:
                th[b] = v
            if b:
                th[256 - b] = (-v) & 0xFFFF
        acc += c
    return th, tl


def sat_add(a, b):
    r = s16(a) + s16(b)
    return max(-32768, min(32767, r)) & 0xFFFF


def adpcm(data):
    """MSM6258 ADPCM (x68sound compatible) -> 12-bit values, low nibble first"""
    pcm, scale = 0, 0
    for byte in data:
        for nib in (byte & 15, byte >> 4):
            d = DLT[scale]
            m = nib & 7
            mag = ((m >> 2) & 1) * d + ((m >> 1) & 1) * (d >> 1) + (m & 1) * (d >> 2) + (d >> 3)
            pcm = max(-2047, pcm - mag) if nib & 8 else min(2047, pcm + mag)
            scale = max(0, min(48, scale + DCT[nib]))
            yield pcm


def decode(data, rate, x68=False):
    """ADPCM bytes -> 8-bit samples (2 per byte) at the source rate: the loader's decoder
    (exactly), or with x68 the --x68filter one"""
    if x68:
        return decode_x68(data, rate)
    th1, tl1 = hpf_tables(C1[rate])
    out = bytearray(len(data) * 2)
    s1, xp = 0, 0
    k = 0
    for pcm in adpcm(data):
        x = pcm & 0xFFFC                        # S1 = sat(S1 + 2 (x - xp) - c S1)
        dd = ((x - xp) * 2) & 0xFFFF
        xp = x
        m1 = (th1[s1 >> 8] + tl1[s1 & 0xFF]) & 0xFFFF
        s1 = sat_add(s1, (dd - m1) & 0xFFFF)
        t = s16(s1) + 16                        # clip8((S1 + 16) >> 5)
        if t > 32767:
            o = 127
        else:
            hi = t >> 8
            if -16 <= hi <= 15:
                o = (t >> 5) & 0xFF
            else:
                o = 127 if hi >= 0 else 0x80
        out[k] = o & 0xFF
        k += 1
    return bytes(out)


# --x68filter ----------------------------------------------------------------
X68_TAPS = 1024
_x68_fir = {}


def x68_response(f):
    """the X68000's ADPCM output filters (complex response at f Hz, numpy)"""
    import numpy as np
    s = 2j * np.pi * np.asarray(f, float)
    wh, w0, w1, q = 2 * np.pi * 183, 2 * np.pi * 3800, 2 * np.pi * 7300, 0.78
    return s / (s + wh) * w0 * w0 / (s * s + s * w0 / q + w0 * w0) * w1 / (s + w1)


def x68_fir(rate):
    """causal minimum-phase FIR with |x68_response| up to half the rate (real cepstrum)"""
    import numpy as np
    if rate not in _x68_fir:
        n = 1 << 16
        f = np.fft.fftfreq(n, 1 / RATE_HZ[rate])
        mag = np.maximum(np.abs(x68_response(np.abs(f))), 1e-7)
        c = np.fft.ifft(np.log(mag)).real
        w = np.zeros(n)
        w[0] = w[n // 2] = 1
        w[1:n // 2] = 2
        _x68_fir[rate] = np.fft.ifft(np.exp(np.fft.fft(c * w))).real[:X68_TAPS]
    return _x68_fir[rate]


def x68_filter(x, rate):
    """float values -> the same number of filtered values: linear convolution with the FIR
    (causal, state 0 before the first value), cut off at the input's length"""
    import numpy as np
    x = np.asarray(x, float)
    if len(x) == 0:
        return x
    h = x68_fir(rate)
    nfft = 1 << (len(x) + len(h) - 2).bit_length()
    return np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(h, nfft), nfft)[:len(x)]


def x68_bytes(y):
    """filtered 12-bit values -> 8-bit samples (the loader's scale: / 16)"""
    import numpy as np
    o = np.clip(np.round(np.asarray(y) / 16), -128, 127).astype(np.int16) & 0xFF
    return bytes(o.astype(np.uint8))


def decode_x68(data, rate):
    return x68_bytes(x68_filter(list(adpcm(data)), rate))


# ---------------------------------------------------------------------------
def load_pdx(path):
    d = open(path, 'rb').read()
    tend = len(d)
    i, ent = 0, []
    while i + 8 <= tend:
        off = int.from_bytes(d[i:i + 4], 'big')
        ln = int.from_bytes(d[i + 4:i + 8], 'big')
        if off and off < tend:
            tend = off
        ent.append((off, ln))
        i += 8
    return d, ent


def find_pdx(mdx_path, name):
    folder = os.path.dirname(os.path.abspath(mdx_path))
    want = {name.upper(), (name + '.PDX').upper()}
    for f in os.listdir(folder):
        if f.upper() in want:
            return os.path.join(folder, f)
    return None


def build(mdx_path, pdx_path=None):
    d = open(mdx_path, 'rb').read()
    pdxname, body = mdx_body(d)
    if pdx_path is None:
        pdx_path = find_pdx(mdx_path, pdxname) if pdxname else None
    if pdx_path is None:
        raise SystemExit('%s: no PDX' % mdx_path)
    pdx, ent = load_pdx(pdx_path)
    jobs = scan(body)
    order = sorted(jobs, key=lambda k: -jobs[k])          # most used first
    entries, lin = [], bytearray()
    for smp, rate in order:
        if smp >= len(ent):
            continue
        off, ln = ent[smp]
        if not off or not ln or off + ln > len(pdx) or ln >= 1 << 24:
            continue
        if len(entries) >= NDIR:
            raise SystemExit('%s: more than %d (sample, rate) pairs in %s: the pack would be '
                             'incomplete' % (mdx_path, NDIR, os.path.basename(pdx_path)))
        samples = decode(pdx[off:off + ln], rate)
        entries.append((smp, rate, len(lin), ln))
        lin += samples + bytes(SPAD)
    used = len(lin)
    nb = max(1, -(-used // SBANK_DATA))
    lin += bytes(nb * SBANK_DATA + 128 - len(lin))
    banks = bytearray()
    for b in range(nb):
        banks += lin[b * SBANK_DATA:(b + 1) * SBANK_DATA + 128]
    del banks[(nb - 1) * 8192 + used - (nb - 1) * SBANK_DATA:]     # (unused end of the last bank)
    head = bytearray(b'MXPK') + bytes([1, len(entries), nb, 0])
    for smp, rate, pos, ln in entries:
        bank, addr = pos // SBANK_DATA, 0xA000 + pos % SBANK_DATA
        head += bytes([smp & 255, smp >> 8, rate, bank, addr & 255, addr >> 8]) + ln.to_bytes(3, 'little')
    head += bytes(8192 - len(head))
    return bytes(head + banks), entries, nb, pdx_path


# ---------------------------------------------------------------------------
# shared packs (format version 2, docs/api.md)
V2_HEAD = 36                    # fixed header bytes before the valid-entry bitmap
MAX_TABLE = 4096                # PDX table entries the bitmap may describe
MAX_BANKS = 232                 # default --max-banks: mdxplay on a 2 MB machine (banks 24-255)
RAM_1MB = 104                   # mdxplay on a 1 MB machine (banks 24-127)


class Problem(Exception):
    pass


def pdx_name(raw):
    """name in the MDX header -> (normalized file name, pack base name); '' = no PDX.
    As the player's loadpdx: path dropped, upper case, '.PDX' added if there is no '.'."""
    if not raw:
        return '', ''
    if any(ord(c) > 126 or ord(c) < 32 for c in raw):
        raise Problem('PDX name %r is not plain ASCII' % raw)
    for sep in '\\:/':
        raw = raw.rsplit(sep, 1)[-1]
    name = raw.upper()
    if not name:
        return '', ''
    if '.' not in name:
        name += '.PDX'
    return name, name.rsplit('.', 1)[0]


def find_in_dir(folder, name):
    """the file in folder whose name is name, ignoring case; Problem if more than one"""
    hits = [f for f in os.listdir(folder) if f.upper() == name and os.path.isfile(os.path.join(folder, f))]
    if len(hits) > 1:
        raise Problem('%s: more than one file named %s (%s)' % (folder, name, ', '.join(sorted(hits))))
    return os.path.join(folder, hits[0]) if hits else None


class Pdx:
    def __init__(self, path):
        self.path = path
        self.data, self.ent = load_pdx(path)
        if len(self.data) >= 1 << 24:
            raise Problem('%s: PDX of %d bytes is too large' % (path, len(self.data)))
        self.m = len(self.ent)
        self.crc = zlib.crc32(self.data) & 0xFFFFFFFF

    def valid(self, smp):
        """the entry has data (the driver's PDX loader could read it)"""
        if smp >= self.m:
            return False
        off, ln = self.ent[smp]
        return bool(off and ln and off + ln <= len(self.data) and ln < 1 << 24)


class Song:
    def __init__(self, path):
        self.path = path
        self.dir = os.path.dirname(os.path.abspath(path))
        d = open(path, 'rb').read()
        try:
            raw, self.body = mdx_body(d)
        except ValueError:
            raise Problem('%s: not an MDX file' % path)
        self.raw = raw
        self.name, self.base = pdx_name(raw)
        try:
            jobs = scan(self.body, driver_order=True)
        except IndexError:
            raise Problem('%s: broken MDX (the data ends early)' % path)
        keys = list(jobs)
        self.first = keys[:NDIR]            # what the loader's job table holds
        self.rest = keys[NDIR:]             # pairs the driver never loads for this song

    def required(self, pdx):
        return [k for k in self.first if pdx.valid(k[0])]

    def lost(self, pdx):
        return [k for k in self.rest if pdx.valid(k[0])]


def pack_banks(pdx, pairs):
    """sample banks a pack of pairs needs"""
    used = sum(2 * pdx.ent[smp][1] + SPAD for smp, _ in set(pairs))
    return max(1, -(-used // SBANK_DATA))


def build_v2(pdx, pairs, name, flags, max_banks=255):
    """version 2 pack of pairs (sorted by sample, rate) -> (bytes, banks); Problem if it does
    not fit: the header, the format's 255 banks, max_banks (checked before decoding).
    Flag bit 2 = the samples with --x68filter."""
    pairs = sorted(set(pairs))
    m = pdx.m
    if m > MAX_TABLE:
        raise Problem('PDX table of %d entries (at most %d)' % (m, MAX_TABLE))
    head_len = V2_HEAD + (m + 7) // 8 + 9 * len(pairs)
    if head_len > 8192:
        raise Problem('%d pairs do not fit in the 8 KB header (%d bytes)' % (len(pairs), head_len))
    nb = pack_banks(pdx, pairs)
    if nb > 255:
        raise Problem('%d sample banks (the format allows 255)' % nb)
    if nb > max_banks:
        raise Problem('%d sample banks, more than --max-banks %d' % (nb, max_banks))
    lin, entries = bytearray(), []
    for smp, rate in pairs:
        off, ln = pdx.ent[smp]
        entries.append((smp, rate, len(lin), ln))
        lin += decode(pdx.data[off:off + ln], rate, bool(flags & 4)) + bytes(SPAD)
    used = len(lin)
    assert nb == max(1, -(-used // SBANK_DATA))
    lin += bytes(nb * SBANK_DATA + 128 - len(lin))
    banks = bytearray()
    for b in range(nb):
        banks += lin[b * SBANK_DATA:(b + 1) * SBANK_DATA + 128]
    del banks[(nb - 1) * 8192 + used - (nb - 1) * SBANK_DATA:]
    size = len(banks)
    head = bytearray(b'MXPK') + bytes([2, flags, nb, 0])
    head += len(pairs).to_bytes(2, 'little') + m.to_bytes(2, 'little')
    head += size.to_bytes(3, 'little') + b'\0' + len(pdx.data).to_bytes(3, 'little') + b'\0'
    head += pdx.crc.to_bytes(4, 'little') + name.encode('ascii')[:12].ljust(12, b'\0')
    bits = bytearray((m + 7) // 8)
    for i in range(m):
        if pdx.valid(i):
            bits[i >> 3] |= 1 << (i & 7)
    head += bits
    for smp, rate, pos, ln in entries:
        bank, addr = pos // SBANK_DATA, 0xA000 + pos % SBANK_DATA
        head += bytes([smp & 255, smp >> 8, rate, bank, addr & 255, addr >> 8]) + ln.to_bytes(3, 'little')
    assert len(head) == head_len
    head += bytes(8192 - len(head))
    return bytes(head + banks), nb


def parse_pack(data):
    """header of a version 1 or 2 pack -> dict; Problem if the header or an entry reference
    breaks the format's rules (docs/api.md)"""
    if len(data) < 8192 or data[:4] != b'MXPK' or data[4] not in (1, 2):
        raise Problem('not an MXPK pack of version 1 or 2')
    ver = data[4]
    h = {'version': ver}
    if ver == 1:
        n, nb, pos = data[5], data[6], 8
        if n > NDIR or 8 + 9 * n > 8192:
            raise Problem('version 1 header: %d entries' % n)
        h.update(flags=0, m=None, bits=None, pdx_size=None, crc=None, name='')
    else:
        flags, nb = data[5], data[6]
        n = int.from_bytes(data[8:10], 'little')
        m = int.from_bytes(data[10:12], 'little')
        S = int.from_bytes(data[12:15], 'little')
        if m > MAX_TABLE:
            raise Problem('PDX table of %d entries' % m)
        pos = V2_HEAD + (m + 7) // 8
        if pos + 9 * n > 8192:
            raise Problem('%d entries do not fit in the header' % n)
        if not (1 <= nb and (nb - 1) * 8192 < S <= (nb - 1) * 8192 + SBANK_DATA):
            raise Problem('sample part of %d bytes does not match %d banks' % (S, nb))
        if len(data) != 8192 + S:
            raise Problem('file of %d bytes, the header says %d' % (len(data), 8192 + S))
        h.update(flags=flags, m=m, bits=data[V2_HEAD:pos], S=S,
                 pdx_size=int.from_bytes(data[16:19], 'little'),
                 crc=int.from_bytes(data[20:24], 'little'),
                 name=data[24:36].rstrip(b'\0').decode('ascii', 'replace'))
    if nb < 1:
        raise Problem('0 sample banks')
    ent, end = [], 0
    for i in range(n):
        e = data[pos + 9 * i:pos + 9 * i + 9]
        smp, rate, bank = e[0] | e[1] << 8, e[2], e[3]
        addr, ln = e[4] | e[5] << 8, int.from_bytes(e[6:9], 'little')
        if bank >= nb or not 0xA000 <= addr < 0xA000 + SBANK_DATA:
            raise Problem('entry %d: bank %d, address $%04X out of the pack' % (i, bank, addr))
        lin = bank * SBANK_DATA + addr - 0xA000
        end = max(end, lin + 2 * ln + SPAD)
        if ver == 2 and lin + 2 * ln + SPAD > h['S'] - (nb - 1) * 128:
            raise Problem('entry %d ends after the sample part' % i)
        if ver == 1 and lin + 2 * ln + SPAD > nb * SBANK_DATA:
            raise Problem('entry %d ends after the last bank' % i)
        ent.append((smp, rate, bank, addr, ln))
    if ver == 1:
        h['S'] = (nb - 1) * 128 + end if n else 0
        if len(data) != 8192 + h['S']:
            raise Problem('file of %d bytes, the entries need %d' % (len(data), 8192 + h['S']))
    keys = [(e[0], e[1]) for e in ent]
    if len(set(keys)) != len(keys):
        raise Problem('the same (sample, rate) twice')
    h.update(n=n, nb=nb, entries=ent, pairs=set(keys))
    return h


def sample_bytes(data, entry):
    """the decoded bytes (+ pad) of one entry, read through the bank layout"""
    smp, rate, bank, addr, ln = entry
    lin = bank * SBANK_DATA + addr - 0xA000
    out = bytearray()
    for p in range(lin, lin + 2 * ln + SPAD):
        out.append(data[8192 + (p // SBANK_DATA) * 8192 + p % SBANK_DATA])
    return bytes(out)


def bad_mirrors(data, nb):
    """banks whose last 128 bytes are not a copy of the next bank's start (the mixer reads
    them when a sample crosses into the next bank; zeros where the last bank is shorter)"""
    bad = []
    for b in range(nb - 1):
        base = 8192 + b * 8192
        nxt = data[base + 8192:base + 8192 + 128]
        if data[base + SBANK_DATA:base + 8192] != nxt + bytes(128 - len(nxt)):
            bad.append(b)
    return bad


class Group:
    """one shared pack: a PDX file and the songs that use it"""
    def __init__(self, pdx_path, base, out_dir):
        self.pdx_path, self.base, self.out_dir = pdx_path, base, out_dir
        self.songs, self.problems, self.notes = [], [], []

    @property
    def target(self):
        return os.path.join(self.out_dir, self.base + '.P16')


def song_files(folder):
    return sorted(os.path.join(folder, f) for f in os.listdir(folder)
                  if f.upper().endswith('.MDX') and os.path.isfile(os.path.join(folder, f)))


def plan(args, problems, infos):
    """-> list of Group (songs resolved, PDX found)"""
    groups = {}

    def add(song, pdx_path, base, out_dir):
        key = os.path.realpath(pdx_path), os.path.realpath(out_dir)
        g = groups.get(key)
        if g is None:
            g = groups[key] = Group(pdx_path, base, out_dir)
        elif g.base != base:
            problems.append('%s: %s is named both %s and %s in the MDX files'
                            % (out_dir, os.path.basename(pdx_path), g.base, base))
        g.songs.append(song)

    def out_for(folder, root):
        if args.d is None:
            return folder
        return os.path.normpath(os.path.join(args.d, os.path.relpath(folder, root))) if root else args.d

    def by_name(paths, root=None):
        for path in paths:
            try:
                song = Song(path)
                if not song.name:
                    infos.append('%s: no PDX (FM only)' % path)
                    continue
                pdx = find_in_dir(song.dir, song.name)
                if pdx is None:
                    problems.append('%s: PDX %s not found in %s' % (path, song.name, song.dir))
                    continue
                add(song, pdx, song.base, out_for(song.dir, root))
            except Problem as e:
                problems.append(str(e))

    if args.mode == 'dir':
        for top in args.paths:
            folders = [top]
            if args.r:
                folders = sorted(r for r, _, _ in os.walk(top))
            for folder in folders:
                by_name(song_files(folder), top)
    elif args.mode == 'mdx':
        by_name(args.paths)
    else:                                       # 'pdx': X.PDX [MDX...]
        pdx = args.paths[0]
        base = os.path.basename(pdx).upper().rsplit('.', 1)[0]
        out_dir = args.d if args.d is not None else os.path.dirname(os.path.abspath(pdx))
        g = groups[(os.path.realpath(pdx), os.path.realpath(out_dir))] = Group(pdx, base, out_dir)
        for path in args.paths[1:]:
            try:
                song = Song(path)
                if song.name != os.path.basename(pdx).upper():
                    infos.append('%s: names PDX %r, packed with %s as asked' % (path, song.raw, pdx))
                g.songs.append(song)
            except Problem as e:
                problems.append(str(e))
    out = list(groups.values())
    seen = {}
    for g in out:                               # two packs, one file name
        k = os.path.realpath(g.target).upper()
        seen.setdefault(k, []).append(g)
    for k, gs in seen.items():
        if len(gs) > 1:
            for g in gs:
                g.problems.append('%s would also be written for %s' % (
                    g.target, ', '.join(os.path.basename(x.pdx_path) for x in gs if x is not g)))
    return out


def v1_replaceable(path, old, g, pdx, need):
    """a version 1 (per-song) pack at path may be replaced or removed only if its own song
    loses nothing: the MDX of the same name in the same folder (that very file) is a song of
    this pack, none of its PDX pairs falls outside the pack (also none after the 96-pair job
    table), and every pair the old pack holds is in the new one. -> None, or why not."""
    base = os.path.basename(path).rsplit('.', 1)[0].upper()
    folder = os.path.dirname(os.path.abspath(path))
    try:
        mdx = find_in_dir(folder, base + '.MDX')
    except Problem as e:
        return str(e)
    if mdx is None:
        return 'no %s.MDX next to it' % base
    song = next((x for x in g.songs if os.path.realpath(x.path) == os.path.realpath(mdx)), None)
    if song is None:
        return '%s does not use this pack' % mdx
    if song.lost(pdx):
        return '%s has %d pairs after the 96-pair job table' % (mdx, len(song.lost(pdx)))
    if not set(song.required(pdx)) <= need:
        return '%s needs pairs this pack does not hold' % mdx
    try:
        pairs = parse_pack(old)['pairs']
    except Problem as e:
        return 'it cannot be read (%s)' % e
    extra = pairs - need
    if extra:
        return 'it holds %d pairs the new pack does not %s' % (len(extra), sorted(extra)[:8])
    return None


def write_file(path, data, keep_v1):
    """-> 'new' / 'unchanged' / 'updated' / 'replaced version 1 pack'. Problem if the file is
    not a pack, or is a version 1 pack keep_v1(path, old bytes) says must stay (a reason)"""
    if os.path.exists(path):
        old = open(path, 'rb').read()
        if old == data:
            return 'unchanged'
        if old[:4] != b'MXPK':
            raise Problem('%s exists and is not a pack: not overwritten' % path)
        if old[4:5] == b'\x01':
            why = keep_v1(path, old)
            if why:
                raise Problem('%s is a per-song pack and its song would lose PCM (%s): not '
                              'overwritten (move it away to replace it)' % (path, why))
            what = 'replaced version 1 pack'
        else:
            what = 'updated'
    else:
        what = 'new'
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    return what


def ram_note(nb):
    return '1 MB %s, 2 MB %s' % ('fits' if nb <= RAM_1MB else 'too big',
                                 'fits' if nb <= MAX_BANKS else 'too big')


def run_group(g, args):
    """build (or check) one shared pack; problems go to g.problems"""
    try:
        pdx = Pdx(g.pdx_path)
    except (Problem, OSError) as e:
        g.problems.append(str(e))
        return
    need = set()
    for song in g.songs:
        need.update(song.required(pdx))
        lost = song.lost(pdx)
        if lost:
            g.problems.append('%s: %d (sample, rate) pairs come after the driver\'s %d-pair job '
                              'table and are never loaded (PDX or pack)' % (song.path, len(lost), NDIR))
    every = args.all or not g.songs
    if every:
        need.update((i, 4) for i in range(pdx.m) if pdx.valid(i))
    rates = {}
    for _, r in need:
        rates[r] = rates.get(r, 0) + 1
    songs = ', '.join(os.path.basename(x.path) for x in g.songs) or '(none: every sample at rate 4)'
    target = args.o if args.o else g.target
    head = '%s <- %s: %d songs (%s)' % (target, os.path.basename(g.pdx_path), len(g.songs), songs)
    if not need:
        g.notes.append(head + '\n    no PCM pairs needed: no pack')
        return
    flags = 1 | (2 if every else 0) | (4 if args.x68 else 0)
    name = (g.songs[0].name if g.songs and g.songs[0].base == g.base else
            os.path.basename(g.pdx_path).upper())
    try:
        data, nb = build_v2(pdx, need, name, flags, args.max_banks)
    except Problem as e:
        g.problems.append('%s: %s' % (g.target, e))
        return
    info = '    %d pairs (%s), %d sample banks, %d bytes; mdxplay RAM: %s' % (
        len(need), ', '.join('rate %d: %d' % (r, rates[r]) for r in sorted(rates)), nb, len(data), ram_note(nb))
    if args.check:
        check_pack(g, pdx, data, target, need, args.x68)
        g.notes.append(head + '\n' + info + '\n    ' + ('; '.join(g.checked) if g.checked else ''))
        return
    keep_v1 = lambda path, old: v1_replaceable(path, old, g, pdx, need)
    try:
        what = write_file(target, data, keep_v1)
    except (Problem, OSError) as e:
        g.problems.append(str(e))
        return
    g.notes.append(head + '\n' + info + '\n    ' + what)
    stale_song_packs(g, args, target, keep_v1)


def check_pack(g, pdx, fresh, target, need, x68):
    g.checked = []
    if not os.path.exists(target):
        g.problems.append('%s: missing' % target)
        return
    data = open(target, 'rb').read()
    try:
        h = parse_pack(data)
    except Problem as e:
        g.problems.append('%s: %s' % (target, e))
        return
    if h['version'] != 2:
        g.problems.append('%s: version %d pack, not a shared one' % (target, h['version']))
        return
    if h['pdx_size'] != len(pdx.data) or h['crc'] != pdx.crc:
        g.problems.append('%s: made from another PDX (size / CRC differ from %s)' % (target, g.pdx_path))
        return
    if bool(h['flags'] & 4) != x68:
        g.problems.append('%s: made %s --x68filter: remake it' % (target, 'with' if h['flags'] & 4 else 'without'))
        return
    bad = bad_mirrors(data, h['nb'])
    if bad:
        g.problems.append('%s: the copy of the next bank\'s start differs at the end of %d sample banks %s: '
                          'remake it' % (target, len(bad), bad[:8]))
        return
    # the samples of the needed pairs it holds must be what this mkpack makes (an older tool
    # or another filter decodes differently); the order and extra pairs do not matter
    old = {(e[0], e[1]): e for e in h['entries']}
    new = {(e[0], e[1]): e for e in parse_pack(fresh)['entries']}
    differ = sorted(k for k in need & h['pairs'] if sample_bytes(data, old[k]) != sample_bytes(fresh, new[k]))
    if differ:
        g.problems.append('%s: the samples of %d pairs differ from what this mkpack makes (an older '
                          'tool or another filter) %s: remake it' % (target, len(differ), differ[:8]))
        return
    short, songs_need = 0, set()
    for song in g.songs:
        req = song.required(pdx)
        songs_need.update(req)
        miss = [k for k in req if k not in h['pairs']]
        if miss:
            short += 1
            g.problems.append('%s: %s lacks %d pairs %s' % (song.path, target, len(miss), sorted(miss)[:8]))
    rest = sorted(need - songs_need - h['pairs'])       # --all / PDX alone: every sample at rate 4
    if rest:
        short += 1
        g.problems.append('%s lacks %d of the PDX samples at rate 4 (--all / PDX given alone) %s'
                          % (target, len(rest), rest[:8]))
    g.checked.append('up to date' if data == fresh else
                     'holds everything asked for' if not short else 'stale')


def stale_song_packs(g, args, target, keep_v1):
    """per-song packs (MDX name .P16) left next to the songs of a shared pack"""
    if args.d is not None or args.o:
        return
    for song in g.songs:
        base = os.path.basename(song.path).rsplit('.', 1)[0].upper() + '.P16'
        try:
            p = find_in_dir(song.dir, base)
        except Problem as e:
            g.problems.append(str(e))
            continue
        if p is None or os.path.realpath(p).upper() == os.path.realpath(target).upper():
            continue
        old = open(p, 'rb').read()
        ver = old[4] if old[:4] == b'MXPK' and len(old) >= 5 else None
        why = keep_v1(p, old) if ver == 1 else None
        if args.prune and ver == 1 and why:
            g.problems.append('%s kept: its song would lose PCM (%s)' % (p, why))
        elif args.prune and ver == 1:
            os.remove(p)
            g.notes.append('    removed the per-song pack %s' % p)
        else:
            g.notes.append('    per-song pack %s still present%s' % (
                p, ' (version %d)' % ver if ver else ' (not a pack)'))


USAGE = """usage:
  mkpack.py DIR [-r]                 every PDX the MDX files in DIR use -> <PDX>.P16 (shared)
  mkpack.py A.MDX B.MDX ...          the same for the MDX files given
  mkpack.py X.PDX                    every sample of X.PDX at rate 4
  mkpack.py X.PDX A.MDX ...          the pairs these MDX files need, from X.PDX
  mkpack.py SONG.MDX [PDX] [-o OUT]  one song (version 1 pack, as before)
options: --all (every PDX sample at rate 4 too)  -r (subfolders)  -d DIR (output folder)
  -o FILE (one pack only)  --shared (shared pack for one MDX)  --check (write nothing,
  exit 1 if a pack is missing, stale or made from another PDX)  --max-banks N (default %d)
  --prune (remove per-song version 1 packs of the songs of a shared pack)
  --x68filter (the X68000's output filters up to half the sample rate, flag bit 2; not
  what the X16 decodes from the PDX; needs numpy; see the module's notes)""" % MAX_BANKS


def parse_args(argv):
    class A:
        pass
    a = A()
    a.all = a.r = a.shared = a.check = a.prune = a.x68 = False
    a.d = a.o = None
    a.max_banks = MAX_BANKS
    a.paths = []
    new_opt = False
    i = 0
    while i < len(argv):
        x = argv[i]
        if x == '--x68filter':
            try:
                import numpy  # noqa: F401
            except ImportError:
                raise SystemExit('mkpack: --x68filter needs numpy')
            a.x68, new_opt = True, True
        elif x in ('--all', '-r', '--shared', '--check', '--prune'):
            setattr(a, {'--all': 'all', '-r': 'r', '--shared': 'shared', '--check': 'check',
                        '--prune': 'prune'}[x], True)
            new_opt = True
        elif x in ('-d', '-o', '--max-banks'):
            if i + 1 >= len(argv):
                raise SystemExit(USAGE)
            v = argv[i + 1]
            i += 1
            if x == '-d':
                a.d, new_opt = v, True
            elif x == '-o':
                a.o = v
            else:
                a.max_banks, new_opt = int(v), True
        elif x.startswith('-'):
            raise SystemExit(USAGE)
        else:
            a.paths.append(x)
        i += 1
    if not a.paths:
        raise SystemExit(USAGE)
    kind = ['dir' if os.path.isdir(x) else 'pdx' if x.upper().endswith('.PDX') else
            'mdx' if x.upper().endswith('.MDX') else '?' for x in a.paths]
    if '?' in kind:
        raise SystemExit('%s: not a folder, MDX or PDX\n%s' % (a.paths[kind.index('?')], USAGE))
    a.legacy = (not new_opt and kind[0] == 'mdx' and
                (len(kind) == 1 or (len(kind) == 2 and kind[1] == 'pdx')))
    if a.legacy:
        return a
    if all(k == 'dir' for k in kind):
        a.mode = 'dir'
    elif kind[0] == 'pdx' and all(k == 'mdx' for k in kind[1:]):
        a.mode = 'pdx'
    elif all(k == 'mdx' for k in kind):
        a.mode = 'mdx'
    else:
        raise SystemExit('mixed arguments (folders, MDX, PDX)\n' + USAGE)
    if a.r and a.mode != 'dir':
        raise SystemExit('-r needs a folder')
    return a


def legacy(a):
    data, entries, nb, pdx_path = build(a.paths[0], a.paths[1] if len(a.paths) > 1 else None)
    out = a.o if a.o else os.path.splitext(a.paths[0])[0] + '.P16'
    song = Song(a.paths[0])
    lost = song.lost(Pdx(pdx_path))
    with open(out, 'wb') as f:
        f.write(data)
    print('%s: %d pairs from %s, %d sample banks, %d bytes' % (out, len(entries), os.path.basename(pdx_path), nb, len(data)))
    if lost:
        print('%s: %d (sample, rate) pairs come after the driver\'s %d-pair job table and are '
              'never loaded' % (a.paths[0], len(lost), NDIR))
        return 1
    return 0


def main(argv=None):
    a = parse_args(sys.argv[1:] if argv is None else argv)
    if a.legacy:
        try:
            return legacy(a)
        except Problem as e:
            print('mkpack: %s' % e)
            return 1
    problems, infos = [], []
    groups = plan(a, problems, infos)
    if a.o and len(groups) != 1:
        problems.append('-o needs exactly one pack (%d here)' % len(groups))
        groups = []
    for g in groups:
        if not g.problems:
            try:
                run_group(g, a)
            except Exception as e:                  # (one pack must not stop the others)
                g.problems.append('%s: internal error: %s: %s' % (g.target, type(e).__name__, e))
    for g in groups:
        for n in g.notes:
            print(n)
        problems += g.problems
    for i in infos:
        print('note: ' + i)
    for p in problems:
        print('PROBLEM: ' + p)
    if not groups and not problems and not infos:
        print('mkpack: no MDX files')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
