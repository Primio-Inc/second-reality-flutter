#!/usr/bin/env python3
"""Offline replica of the 3D sinusfield (COMAN/MAIN.C + ASM.ASM + the unrolled
inner loop DOLOOP.C generates into THELOOP.INC), with the same integer math as
lib/parts/p15_sinfield.dart — for validating against the capture without the
build-web loop.

THELOOP.INC is a 192-step unrolled voxel raycaster, one ray per screen column.
It keeps the ray height in eax as a 16.16 fixed-point value with the INTEGER in
the LOW word (that is what DOLOOP.C's `wflip` is for: it pre-swaps every
constant so `add eax,K` puts the fraction in the high word and the integer in
ax, and `adc ax,0` folds the fraction's carry back into the integer). We emulate
the 32-bit adds and their carries exactly.

Usage: python3 tool/render_sinfield.py <frame> [<frame> ...] -o out_prefix
  <frame> 0 = capture 439.41s, 70 Hz.
"""
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SIN = [round(256 * math.sin(2 * math.pi * i / 1024)) for i in range(1024)]

# DOLOOP.C's generator constants.
HORIZONY = 70
BAIL = 192
BAILHALVE = 64
ZWAVE = [int(16.0 * math.sin(i * math.pi * 2.0 * 3.0 / BAIL)) for i in range(BAIL)]
FIRSTRAYDIR = -(200 - HORIZONY) * 2560

MASK32 = 0xFFFFFFFF


def wflip(v):
    """DOLOOP.C's wflip: swap the halves of a 32-bit word."""
    v &= MASK32
    return ((v & 0xFFFF) << 16) | (v >> 16)


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def load_waves():
    d = (ROOT / "assets/tables/sinfield.srt").read_bytes()
    assert d[:4] == b"SNF1"
    n = struct.unpack_from("<H", d, 4)[0]
    w1 = struct.unpack_from(f"<{n}h", d, 6)
    w2 = struct.unpack_from(f"<{n}h", d, 6 + n * 2)
    return list(w1), list(w2)


def build_palette():
    """MAIN.C's palette: a blue/red ramp over entries 8..223 (only 0..127 are
    ever drawn -- the terrain colour is a byte shifted right one)."""
    pal = bytearray(768)
    def cdiv(x, y):
        # C truncates toward zero; Python's // floors. (230-a)/4 and sin/32 both
        # go negative here, so the difference is real.
        q = abs(x) // abs(y)
        return -q if (x < 0) != (y < 0) else q

    for a in range(256):
        uc = (223 - a * 22 // 26) * 3
        b = cdiv(230 - a, 4) + cdiv(SIN[(a * 4) & 1023], 32)
        b = max(0, min(63, b))
        pal[uc + 1] = b
        b = min(63, (255 - a) // 3)
        pal[uc + 2] = b
        b = abs(a - 220)
        b = 40 - min(40, b)
        pal[uc + 0] = b // 3
    for a in range(768 - 16 * 3):
        pal[a] = min(63, pal[a] * 9 // 6)
    for a in range(24):
        uc = (255 - a) * 3
        b = max(0, a - 4)
        pal[uc + 0] = b // 2
        pal[uc + 1] = 0
        pal[uc + 2] = 0
    pal[0] = pal[1] = pal[2] = 0
    return pal


class Field:
    def __init__(self):
        self.w1, self.w2 = load_waves()
        self.pal = build_palette()
        self.vbuf = bytearray(65536)
        self.rot = 0
        self.rot2 = 0
        self.xwav = 0
        self.ywav = 0
        self.startrise = 160
        self.frame = 0

    def docol(self, xw, yw, xa, ya, bp):
        """theloop: march one ray and paint its terrain column, bottom-up."""
        w1, w2, vbuf = self.w1, self.w2, self.vbuf
        si = xw & 0xFFFE
        di = yw & 0xFFFE
        xs1 = xa & 0xFFFE
        ys1 = ya & 0xFFFE
        xs2 = (xs1 * 2) & 0xFFFF
        ys2 = (ys1 * 2) & 0xFFFF

        E = 0                      # eax: ray height, integer in the low word
        C = wflip(FIRSTRAYDIR)     # ecx: per-row height step (negative)

        j = 0
        while j < BAIL:
            sina2 = j >= BAILHALVE
            xs = xs2 if sina2 else xs1
            ys = ys2 if sina2 else ys1
            si = (si + xs) & 0xFFFF
            bx = w1[si >> 1]
            di = (di + ys) & 0xFFFF
            bx = s16(bx + w2[di >> 1])
            bx = s16(bx + ZWAVE[j] - 240)

            ax = s16(E & 0xFFFF)
            if ax < bx:
                # A hit: paint the column until the ray climbs above the terrain.
                col = ((bx + 120 - j // 8) & 0xFF) >> 1
                step = wflip((j * 2560) & MASK32)
                while True:
                    s = (E & MASK32) + step
                    carry = 1 if s > MASK32 else 0
                    E = s & MASK32
                    ax = ((E & 0xFFFF) + carry) & 0xFFFF
                    E = (E & 0xFFFF0000) | ax
                    if 0 <= bp < 65536:
                        vbuf[bp] = col
                    bp -= 160
                    # `add ecx,<2560>` / `adc cx,0`: the ray's slope flattens by
                    # one row's worth. The adc is NOT optional -- without it the
                    # fraction's carry never reaches the integer, the ray never
                    # levels off toward the horizon, and every column paints to
                    # the top of the screen.
                    s = (C & MASK32) + wflip(2560)
                    carry = 1 if s > MASK32 else 0
                    C = s & MASK32
                    cx = ((C & 0xFFFF) + carry) & 0xFFFF
                    C = (C & 0xFFFF0000) | cx
                    if s16(ax) >= bx:
                        break
                    if bp < -160:
                        break
            # seeko: advance the ray one (or two) steps along its direction.
            s = (E & MASK32) + (C & MASK32)
            carry = 1 if s > MASK32 else 0
            E = s & MASK32
            if sina2:
                s = (E & MASK32) + (C & MASK32) + carry
                carry = 1 if s > MASK32 else 0
                E = s & MASK32
            ax = ((E & 0xFFFF) + 0xFFFF + carry) & 0xFFFF
            E = (E & 0xFFFF0000) | ax

            j += 2 if sina2 else 1

    def step(self):
        """One frame of doit().

        docopy() copies the vbuf to the screen and THEN clears rows 68..97 for
        the next frame, so the clear must happen BEFORE this frame's columns are
        drawn, never between drawing and copying (doing it the other way punches
        a black band straight through the terrain).
        """
        for row in range(68, 98):
            self.vbuf[row * 160:(row + 1) * 160] = bytes(160)
        self.rot2 += 4
        v = SIN[self.rot2 & 1023]
        self.rot += int(v / 15)  # C truncates toward zero
        r = math.floor(self.rot / 8)  # C's >>3 on a signed int
        rsin = SIN[r & 1023]
        rcos = SIN[(r + 256) & 1023]
        rsin2 = SIN[(r + 177) & 1023]
        rcos2 = SIN[(r + 177 + 256) & 1023]
        xw, yw = self.xwav, self.ywav
        for a in range(160):
            x = a - 80
            y = 160
            xa = int((x * rcos + y * rsin) / 256)
            ya = int((y * rcos2 - x * rsin2) / 256)
            b = (a & 1) * 80 + (a >> 1) + 199 * 160
            self.docol(s16(xw), s16(yw), s16(xa), s16(ya), b)
            if a == 80:
                self.xwav = s16(self.xwav + xa * 4)
                self.ywav = s16(self.ywav + ya * 4)
        if self.frame < 400 and self.startrise > 0:
            self.startrise -= 1
        self.frame += 1

    def screen(self):
        """docopy: vbuf rows 60..199 -> screen rows 70..209, shifted down by
        startrise; everything above is black."""
        px = bytearray(320 * 200)
        for sy in range(200):
            vr = 60 + (sy - 70 - self.startrise)
            if vr < 60 or vr > 199:
                continue
            for a in range(160):
                v = self.vbuf[vr * 160 + (a & 1) * 80 + (a >> 1)]
                px[sy * 320 + a * 2] = v
                px[sy * 320 + a * 2 + 1] = v
        return px


def write_png(path, rgb, w, h):
    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3]) for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b""))


def main():
    args = sys.argv[1:]
    out = "sinfield"
    if "-o" in args:
        i = args.index("-o")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    frames = sorted(int(a) for a in args)
    f = Field()
    for target in frames:
        while f.frame < target:
            f.step()
        px = f.screen()
        rgb = bytearray()
        for y in range(400):
            for x in range(320):
                p = px[(y // 2) * 320 + x]
                c = (min(255, f.pal[p * 3] * 4), min(255, f.pal[p * 3 + 1] * 4),
                     min(255, f.pal[p * 3 + 2] * 4))
                rgb += bytes(c)
                rgb += bytes(c)
        write_png(f"{out}_{target:05d}.png", rgb, 640, 400)
        print(f"{out}_{target:05d}.png  (capture t = {439.41 + target / 70:.2f}s)")


if __name__ == "__main__":
    main()
