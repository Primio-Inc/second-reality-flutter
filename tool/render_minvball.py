#!/usr/bin/env python3
"""Offline replica of MINVBALL (DOTS/MAIN.C + ASM.ASM), with the same integer
math as lib/parts/p13_minivectorballs.dart — for validating the port against the
capture without the build-web loop.

Usage: python3 tool/render_minvball.py <frame> [<frame> ...] -o out_prefix
  <frame> is the main-loop frame number (frame 0 = capture 374.95s, 70 Hz).
"""
import math
import struct
import sys
import zlib
from pathlib import Path

DOTNUM = 512
GRAVITY_BOTTOM = 8105
GRAVITY_D = 13

SIN = [round(256 * math.sin(2 * math.pi * i / 1024)) for i in range(1024)]


def isin(d):
    return SIN[d & 1023]


def icos(d):
    return SIN[(d + 256) & 1023]


def i16(v):
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def sar(v, n):
    return v >> n if v >= 0 else -((-v + (1 << n) - 1) >> n) if False else math.floor(v / (1 << n))


class Rand:
    def __init__(self):
        self.s = 1

    def __call__(self):
        self.s = (self.s * 214013 + 2531011) & 0xFFFFFFFF
        return (self.s >> 16) & 0x7FFF


def build_palette():
    pal = bytearray(768)
    cols = [0, 0, 0, 4, 25, 30, 8, 40, 45, 16, 55, 60]
    for a in range(16):
        for b in range(4):
            c = 100 + a * 9
            i = (a * 4 + b) * 3
            pal[i] = cols[b * 3]
            pal[i + 1] = cols[b * 3 + 1] * c // 256
            pal[i + 2] = cols[b * 3 + 2] * c // 256
    pal[255 * 3:255 * 3 + 3] = bytes([31, 0, 15])
    for a in range(100):
        c = 64 - 256 // (a + 4)
        c = c * c // 64
        i = (64 + a) * 3
        pal[i] = pal[i + 1] = pal[i + 2] = c // 4
    return pal


SHADE = []
for a in range(128):
    c = a - (43 + 20) // 2
    c = c * 3 // 4
    c += 8
    c = max(0, min(15, c))
    SHADE.append(15 - c)


class Sim:
    def __init__(self):
        self.rnd = Rand()
        self.frame = 0
        self.f = 0
        self.j = 0
        self.dropper = 22000
        self.grav = 3
        self.rot = 0
        self.rots = 0
        self.rota = -64
        self.rotsin = 0
        self.rotcos = 0
        self.order = list(range(DOTNUM))
        for _ in range(500):
            b = self.rnd() % DOTNUM
            c = self.rnd() % DOTNUM
            self.order[b], self.order[c] = self.order[c], self.order[b]
        self.x = [0] * DOTNUM
        self.y = [i16(2560 - self.dropper)] * DOTNUM
        self.z = [0] * DOTNUM
        self.yadd = [0] * DOTNUM
        self.olds = [0] * DOTNUM
        self.oldb = [0] * DOTNUM
        for _ in range(500):
            self.rnd()
            self.rnd()
        self.bg = bytearray(64000)
        for a in range(100):
            self.bg[(100 + a) * 320:(101 + a) * 320] = bytes([a + 64]) * 320
        self.px = bytearray(self.bg)

    def step(self):
        self.frame += 1
        if self.frame == 500:
            self.f = 0
        i = self.order[self.j]
        self.j = (self.j + 1) % DOTNUM
        f = self.f
        if self.frame < 500:
            self.x[i] = i16(isin(f * 11) * 40)
            self.y[i] = i16(icos(f * 13) * 10 - self.dropper)
            self.z[i] = i16(isin(f * 17) * 40)
            self.yadd[i] = 0
        elif self.frame < 900:
            self.x[i] = i16(icos(f * 15) * 55)
            self.y[i] = i16(self.dropper)
            self.z[i] = i16(isin(f * 15) * 55)
            self.yadd[i] = -260
        elif self.frame < 1700:
            a = SIN[self.frame & 1023] // 8
            self.x[i] = i16(icos(f * 66) * a)
            self.y[i] = 8000
            self.z[i] = i16(isin(f * 66) * a)
            self.yadd[i] = -300
        elif self.frame < 2360:
            self.x[i] = i16(self.rnd() - 16384)
            self.y[i] = i16(8000 - self.rnd() // 2)
            self.z[i] = i16(self.rnd() - 16384)
            self.yadd[i] = 0
            if self.frame > 1900 and not (self.frame & 31) and self.grav > 0:
                self.grav -= 1
        if self.dropper > 4000:
            self.dropper -= 100
        self.rotcos = i16(icos(self.rot) * 64)
        self.rotsin = i16(isin(self.rot) * 64)
        self.rots += 2
        if self.frame > 1900:
            self.rot += self.rota // 64 if self.rota >= 0 else -((-self.rota) // 64)
            self.rota -= 1
        else:
            self.rot = isin(self.rots)
        self.f += 1

    def erase_shadow(self, off):
        if 0 <= off and off + 1 < 64000:
            self.px[off] = self.bg[off]
            self.px[off + 1] = self.bg[off + 1]

    def erase_ball(self, off):
        if 0 <= off and off + 643 < 64000:
            for r in range(3):
                o = off + r * 320
                self.px[o:o + 4] = self.bg[o:o + 4]

    def drawdots(self):
        for d in range(DOTNUM):
            bp = i16(sar(self.z[d] * self.rotcos, 16)
                     - sar(self.x[d] * self.rotsin, 16) + 9000)
            if bp == 0:
                continue
            v = sar(self.x[d] * self.rotcos + self.z[d] * self.rotsin, 8)
            v = v + sar(v, 3)
            q = int(v / bp)  # idiv truncates toward zero
            sx = i16(i16(q) + 160)
            off = sx < 0 or sx > 319
            sy = 0
            if not off:
                sy = i16(i16(524288 // bp if bp > 0 else int(524288 / bp)) + 100)
                off = sy < 0 or sy > 199
            if off:
                self.erase_ball(self.oldb[d])
                self.erase_shadow(self.olds[d])
                continue
            so = sy * 320 + sx
            self.erase_shadow(self.olds[d])
            if so + 1 < 64000:
                self.px[so] = 87
                self.px[so + 1] = 87
            self.olds[d] = so

            ya = i16(self.yadd[d] + self.grav)
            y = i16(self.y[d] + ya)
            if y >= GRAVITY_BOTTOM:
                ya = sar(i16(-ya * GRAVITY_D), 4)
                y = i16(y + ya)
            self.yadd[d] = ya
            self.y[d] = y

            by = i16(i16(int((y * 64) / bp)) + 100)
            if by < 0 or by > 199:
                self.erase_ball(self.oldb[d])
                continue
            bo = by * 320 + sx
            self.erase_ball(self.oldb[d])
            c = SHADE[(bp >> 8) & 127]
            edge, mid = 4 * c + 2, 4 * c + 3
            if bo + 643 < 64000:
                self.px[bo + 1] = edge
                self.px[bo + 2] = edge
                self.px[bo + 320] = edge
                self.px[bo + 321] = mid
                self.px[bo + 322] = mid
                self.px[bo + 323] = edge
                self.px[bo + 641] = edge
                self.px[bo + 642] = edge
            self.oldb[d] = bo


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
    out = "minvball"
    if "-o" in args:
        i = args.index("-o")
        out = args[i + 1]
        args = args[:i] + args[i + 2:]
    frames = sorted(int(a) for a in args)
    pal = build_palette()
    sim = Sim()
    for target in frames:
        while sim.frame < target:
            sim.step()
            sim.drawdots()
        # 640x400: the 320x200 field at its 4:3 shape.
        rgb = bytearray()
        for y in range(400):
            row = sim.px[(y // 2) * 320:(y // 2) * 320 + 320]
            for p in row:
                rgb += bytes((min(255, pal[p * 3] * 4), min(255, pal[p * 3 + 1] * 4),
                              min(255, pal[p * 3 + 2] * 4)))
                rgb += bytes((min(255, pal[p * 3] * 4), min(255, pal[p * 3 + 1] * 4),
                              min(255, pal[p * 3 + 2] * 4)))
        write_png(f"{out}_{target:05d}.png", rgb, 640, 400)
        print(f"{out}_{target:05d}.png  (capture t = {374.95 + target / 70:.2f}s)")


if __name__ == "__main__":
    main()
