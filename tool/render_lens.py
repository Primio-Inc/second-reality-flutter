#!/usr/bin/env python3
"""Offline rasteriser for the LENS + ROTOZOOMER part (LENS/MAIN.C + ASM.ASM).

Same math as lib/parts/p11_lens.dart, so a scene can be validated against the
capture without the build-web + browser loop. Renders part-local times to PNGs.

    tool/render_lens.py out/ 0.2 0.5 1.0 8.0 12.0 17.2 20 30 40

Part-local time: 0 = the fir-fade reveal's first frame; the lens starts at
6.83s and the rotozoomer at 17.12s (see p11_lens.dart for how those were
measured off the capture).
"""

import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FPS = 70.0

PART2_START = 6.83
PART3_START = 17.12


def load():
    with open(os.path.join(ROOT, 'assets', 'images', 'lenspic.sri'), 'rb') as f:
        b = f.read()
    w, h = struct.unpack_from('<HH', b, 4)
    pal = bytearray(b[8:8 + 768])
    pix = bytearray(b[8 + 768:8 + 768 + w * h])

    with open(os.path.join(ROOT, 'assets', 'tables', 'lens.srt'), 'rb') as f:
        t = f.read()
    assert t[:4] == b'LNS1'
    o = 4
    lw, lh = struct.unpack_from('<HH', t, o); o += 4
    tint = t[o:o + 9]; o += 9
    layers = []
    for _ in range(4):
        (rows,) = struct.unpack_from('<H', t, o); o += 2
        rt = []
        for _ in range(rows):
            wi, cnt = struct.unpack_from('<IH', t, o); o += 6
            rt.append((wi, cnt))
        (n,) = struct.unpack_from('<I', t, o); o += 4
        ws = struct.unpack_from(f'<{n}h', t, o); o += n * 2
        layers.append((rt, ws))
    (n1,) = struct.unpack_from('<H', t, o); o += 2
    p1 = struct.unpack_from(f'<{n1 * 2}h', t, o); o += n1 * 4
    (n2,) = struct.unpack_from('<H', t, o); o += 2
    p2 = struct.unpack_from(f'<{n2 * 4}h', t, o); o += n2 * 8
    return pal, pix, lw, lh, tint, layers, p1, p2


class Lens:
    def __init__(self):
        (pal, pix, self.lw, self.lh, tint, self.layers,
         self.p1, self.p2) = load()

        # MAIN.C: palette banks 1..3 = the picture's 64 colours + each tint.
        self.pal = bytearray(768)
        self.pal[:768] = pal
        for i in range(1, 4):
            r, g, b = tint[(i - 1) * 3:(i - 1) * 3 + 3]
            for a in range(0, 64 * 3, 3):
                for k, v in enumerate((r, g, b)):
                    self.pal[a + i * 192 + k] = min(63, v + self.pal[a + k])

        # fade[]: 64 steps of colours 0-63 toward white, then 16 overbright
        # steps settling back to the picture's own palette.
        self.fade = bytearray()
        for x in range(64):
            for y in range(192):
                self.fade.append((self.pal[y] * (63 - x) + x * 63) // 63)
        for x in range(16):
            for y in range(192):
                self.fade.append(min(63, self.pal[y] + (15 - x) * 5))
        # fade2[]: 32 steps bringing the three lens banks up from just their
        # tint delta to the full colour.
        self.fade2 = bytearray()
        for x in range(32):
            for y in range(192, 768):
                a = y % 192
                self.fade2.append(self.pal[y] - self.pal[a] * (31 - x) // 31)

        self.back = bytearray(65536)
        self.back[:64000] = pix
        self.back[64000:] = self.back[64000 - 1536:64000]

        # rotpic readymake: columns 32..287, rows scaled 11/10 and shifted up.
        self.rotpic = bytearray(65536)
        for x in range(256):
            for y in range(256):
                a = y * 10 // 11 - 18
                if a < 0 or a > 199:
                    a = 0
                self.rotpic[x + y * 256] = self.back[x + 32 + a * 320]
        self.rotpic90 = bytearray(65536)
        for x in range(256):
            for y in range(256):
                self.rotpic90[x + y * 256] = self.rotpic[y + (255 - x) * 256]

        self.reset()

    def reset(self):
        self.vram = bytearray(65536)
        self.dac = bytearray(self.pal)
        self.frame = -1
        self.f1 = [170 * 64 + (100 - y) * 50 for y in range(200)]
        self.f2 = list(self.f1)
        self.f1a = [(19 + y // 5 + 4) & ~7 for y in range(200)]
        self.f2a = [-(19 + (199 - y) // 5 + 4) & ~7 for y in range(200)]
        self.mode3 = False

    def setpal(self, src, off, first, count):
        self.dac[first * 3:(first + count) * 3] = src[off:off + count * 3]

    # ---- ASM.ASM ------------------------------------------------------------
    def dorow(self, layer, u, row, col):
        rt, ws = layer
        wi, cnt = rt[row]
        if cnt < 4:
            return
        di = (u + ws[wi]) & 0xFFFF
        for i in range(cnt):
            self.vram[(di + i) & 0xFFFF] = \
                self.back[(di + (ws[wi + 1 + i] & 0xFFFF)) & 0xFFFF] | col

    def dorow2(self, layer, u, row, col):
        rt, ws = layer
        wi, cnt = rt[row]
        if cnt == 0:
            return
        di = (u + ws[wi]) & 0xFFFF
        for i in range(cnt):
            dst = ws[wi + 1 + i * 2] & 0xFFFF
            src = ws[wi + 2 + i * 2] & 0xFFFF
            self.vram[(dst + di) & 0xFFFF] = \
                self.back[(src + di) & 0xFFFF] | col

    def dorow3(self, layer, u, row):
        rt, ws = layer
        wi, cnt = rt[row]
        if cnt == 0:
            return
        di = (u + ws[wi]) & 0xFFFF
        for i in range(cnt):
            o = ((ws[wi + 1 + i] & 0xFFFF) + di) & 0xFFFF
            self.vram[o] = self.back[o]

    def drawlens(self, x0, y0):
        xs, ys2 = self.lw // 2, self.lh // 2
        u1 = (x0 - xs) + (y0 - ys2) * 320
        u2 = (x0 - xs) + (y0 + ys2 - 1) * 320
        ye = self.lh - 1
        for y in range(ys2):
            if 0 <= u1 <= 64000:
                self.dorow(self.layers[0], u1, y, 0x40)
                self.dorow2(self.layers[1], u1, y, 0x80)
                self.dorow2(self.layers[2], u1, y, 0xC0)
                self.dorow3(self.layers[3], u1, y)
            u1 += 320
            if 0 <= u2 <= 64000:
                self.dorow(self.layers[0], u2, ye - y, 0x40)
                self.dorow2(self.layers[1], u2, ye - y, 0x80)
                self.dorow2(self.layers[2], u2, ye - y, 0xC0)
                self.dorow3(self.layers[3], u2, ye - y)
            u2 -= 320

    def rotate(self, x, y, xa, ya):
        """ASM.ASM `_rotate`: a 160x100 chunky rotozoom of the 256x256 rotpic,
        displayed 2px wide over the 320-px screen (and 4 scanlines tall in the
        original's tweaked 320x400 mode -> 2 rows of our 320x200 surface)."""
        xpos = (x << 16) & 0xFFFFFFFF
        ypos = (y << 16) & 0xFFFFFFFF
        xadd = (xa << 6)
        yadd = (ya << 6)
        pic = self.rotpic
        if abs(xadd) > abs(yadd):
            pic = self.rotpic90
            xadd, yadd = yadd, xadd
            xadd = -xadd
            xpos, ypos = s32(-s32(ypos)), s32(xpos)
        xadd, yadd = s32(xadd), s32(yadd)

        # The per-column table: step (+yadd, -xadd), accumulated 8 bits at a
        # time, giving a 16-bit (y:x) displacement into the wrapping 256x256.
        cols = []
        si = di = al = ah = 0
        cx = yadd & 0xFFFF
        bl = (yadd >> 16) & 0xFF
        negx = (-xadd) & 0xFFFFFFFF
        dx = negx & 0xFFFF
        bh = (negx >> 16) & 0xFF
        for _ in range(160):
            si += cx
            al = (al + bl + (si >> 16)) & 0xFF
            si &= 0xFFFF
            di += dx
            ah = (ah + bh + (di >> 16)) & 0xFF
            di &= 0xFFFF
            cols.append((ah << 8) | al)

        # aspect ratio: the per-ROW step is 307/256 of the per-column one.
        xadd = s32((307 * (xadd & 0xFFFFFFFF)) & 0xFFFFFFFF) >> 8
        yadd = s32((307 * (yadd & 0xFFFFFFFF)) & 0xFFFFFFFF) >> 8

        for row in range(100):
            ypos = (ypos + yadd) & 0xFFFFFFFF
            xpos = (xpos + xadd) & 0xFFFFFFFF
            bx = (((ypos >> 8) & 0xFF00) | ((xpos >> 16) & 0xFF))
            base = row * 320 * 2
            for c in range(160):
                v = pic[(bx + cols[c]) & 0xFFFF]
                o = base + c * 2
                self.vram[o] = v
                self.vram[o + 1] = v
                self.vram[o + 320] = v
                self.vram[o + 321] = v

    # ---- MAIN.C -------------------------------------------------------------
    def step(self):
        self.frame += 1
        f = self.frame
        p2 = int(PART2_START * FPS)
        p3 = int(PART3_START * FPS)

        if f < 300:                                   # part1 -- the fir fade
            if f < 80:
                for _ in range(6):
                    for y in range(200):
                        for arr, add in ((self.f1, self.f1a), (self.f2, self.f2a)):
                            o = y * 320 + (arr[y] >> 6)
                            if 0 <= o < 64000:
                                self.vram[o] = self.back[o]
                            arr[y] += add[y]
        elif f < p2:
            pass                                      # the dis_musplus wait
        elif f < p3:                                  # part2 -- the lens
            uf = f - p2
            if uf < 96:
                a = max(0, (uf - 32) // 2)
                self.setpal(self.fade2, a * 576, 64, 192)
            if uf < 715:
                self.drawlens(self.p1[uf * 2], self.p1[uf * 2 + 1])
        else:                                         # part3 -- the rotozoomer
            zf = f - p3
            if zf == 0:
                # inittwk: 320x400 tweaked mode, VRAM and DAC cleared. (The DAC
                # clear clobbers MAIN.C's own `setpalarea(fade+64*192,0,64)` one
                # line above it; the capture shows the bright palette up from the
                # first frame, so we keep the palette the code asks for.)
                self.mode3 = True
                self.vram = bytearray(65536)
                self.dac = bytearray(768)
                self.setpal(self.fade, 64 * 192, 0, 64)
            if zf < 2000:
                i = zf * 4
                self.rotate(self.p2[i], self.p2[i + 1], self.p2[i + 2],
                            self.p2[i + 3])
                if zf < 16:
                    self.setpal(self.fade, (64 + zf) * 192, 0, 64)
                if zf > 2000 - 128:
                    a = min(63, (zf - (2000 - 128)) // 2)
                    self.setpal(self.fade, a * 192, 0, 64)
            elif zf == 2000:
                self.dac = bytearray([63] * 768)

    def run_to(self, t):
        target = int(t * FPS)
        if target < self.frame:
            self.reset()
        while self.frame < target:
            self.step()


def s32(v):
    v &= 0xFFFFFFFF
    return v - 0x100000000 if v & 0x80000000 else v


def png(path, w, h, rgb):
    raw = b''.join(b'\0' + bytes(rgb[y * w * 3:(y + 1) * w * 3])
                   for y in range(h))
    def chunk(tag, data):
        c = struct.pack('>I', len(data)) + tag + data
        return c + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        f.write(chunk(b'IEND', b''))


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    times = [float(a) for a in sys.argv[2:]]
    lens = Lens()
    for t in sorted(times):
        lens.run_to(t)
        rgb = bytearray(320 * 200 * 3)
        for i in range(64000):
            c = lens.vram[i] * 3
            for k in range(3):
                rgb[i * 3 + k] = min(255, lens.dac[c + k] * 255 // 63)
        p = os.path.join(out, f'lens_{t:07.3f}.png')
        png(p, 320, 200, rgb)
        print(p)


if __name__ == '__main__':
    sys.exit(main())
