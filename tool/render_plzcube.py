#!/usr/bin/env python3
"""Offline replica of PLZPART's vect() -- the plasma cube (VECT.C + PLZFILL.C +
PLZA.ASM + SPLINE.ASM).  Same math as lib/parts/p12_plasma.dart's cube phase;
used to validate the camera path, the projection and the texture filler against
the capture before touching Dart.

The mode here is NOT the plasma's: vect() calls tw_opengraph(), which sets CRTC
09h=2 (3 scanlines per row -> 134 rows) and 13h=0x50 (offset 80 -> a 160-byte /
640-pixel row pitch).  The cube is projected into that 640x134 field and the
CRTC shows a 320-pixel window of it starting at byte 40 (= pixel 160).  Since
all four planes are written at once, ONE byte = 4 pixels of one colour: the
texture is sampled once per 4 pixels, which is where the chunkiness comes from.

Usage: render_plzcube.py --frame N [-o out.png]   (N = retraces since vect()'s
music gate; --capture T maps a capture time through CAP_F0.)
"""
import argparse
import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "assets" / "tables" / "plasma.srt"

W, H = 320, 400
ROWS = 134           # tw_opengraph: 134 rows of 3 scanlines
BYTES = 160          # row pitch (640 px)
FPS = 70.086

# The frame the capture shows the cube's first pixels (see p12_plasma.dart).
CAP_F0 = 344.58


def load_tables():
    b = TBL.read_bytes()
    assert b[:4] == b"SRP2", b[:4]
    o = 5
    o += 16384 + 16384 + 16384 + 129        # psini, lsini4, lsini16, ptau
    sinit = list(struct.unpack_from("<1280h", b, o)); o += 2560
    spline = list(struct.unpack_from("<1024h", b, o)); o += 2048
    n = struct.unpack_from("<H", b, o)[0]; o += 2
    rata = list(struct.unpack_from(f"<{n * 8}h", b, o))
    return sinit, spline, rata


SINIT, SPLINE, RATA = load_tables()
KOSINIT = SINIT[256:]                        # COPPER/INCLUDE.ASM: kosinit=sinit+512


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def sar(v, n):
    return v >> n if v >= 0 else -((-v - 1) >> n) - 1


# --- SPLINE.ASM getspl ------------------------------------------------------
def getspl(pos):
    """8 spline channels: tx, ty, dis, kx, ky, kz, ls_kx, ls_ky."""
    seg = (pos >> 8) * 8            # 8 words per control point
    u = pos & 255
    out = []
    for c in range(8):
        v = (RATA[seg + 3 * 8 + c] * SPLINE[u]
             + RATA[seg + 2 * 8 + c] * SPLINE[u + 256]
             + RATA[seg + 1 * 8 + c] * SPLINE[u + 512]
             + RATA[seg + 0 * 8 + c] * SPLINE[u + 768])
        out.append(s16(sar(v, 15)))
    return out


# --- PLZFILL.C initvect -----------------------------------------------------
def init_textures():
    sini = [int(math.sin(a / 1024.0 * math.pi * 4) * 127) for a in range(2000)]
    kuva = [bytearray(128 * 256) for _ in range(3)]
    def cdiv(a, b):                       # C truncates toward zero
        return abs(a) // abs(b) * (1 if (a < 0) == (b < 0) else -1)

    for y in range(64):
        for x in range(256):
            v = cdiv(sini[(y * 4 + sini[x * 2]) & 511], 4) + 32
            for c in range(3):
                kuva[c][y * 256 + x] = (v + 64 * c) & 0xFF
    dist = bytearray(128 * 256)
    for y in range(128):
        v = cdiv(sini[y * 8], 3)
        for x in range(256):
            dist[y * 256 + x] = v & 0xFF
    pal = bytearray(768)
    for a in range(1, 32):                       # black-blue-white
        pal[a * 3 + 2] = a * 2
    for a in range(32):
        pal[(a + 32) * 3] = a * 2
        pal[(a + 32) * 3 + 1] = a * 2
        pal[(a + 32) * 3 + 2] = 63
    for a in range(32):                          # black-red-yellow
        pal[64 * 3 + a * 3] = a * 2
    for a in range(32):
        pal[64 * 3 + (a + 32) * 3] = 63
        pal[64 * 3 + (a + 32) * 3 + 1] = a * 2
    for a in range(32):                          # black-orange-violet
        pal[128 * 3 + a * 3] = a
        pal[128 * 3 + a * 3 + 2] = a * 2 // 3
    for a in range(32):
        pal[128 * 3 + (a + 32) * 3] = 31 - a
        pal[128 * 3 + (a + 32) * 3 + 1] = a * 2
        pal[128 * 3 + (a + 32) * 3 + 2] = 21
    return kuva, dist, pal


KUVA, DIST, PAL = init_textures()

# VECT.C's cube
PNT = [(125, 125, 125), (125, -125, 125), (-125, -125, 125), (-125, 125, 125),
       (125, 125, -125), (125, -125, -125), (-125, -125, -125), (-125, 125, -125)]
FACE = [(1, 2, 3, 0, 0), (7, 6, 5, 4, 0), (0, 4, 5, 1, 1),
        (1, 5, 6, 2, 2), (2, 6, 7, 3, 1), (3, 7, 4, 0, 2)]
TXT = [(64, 4), (190, 4), (190, 60), (64, 60)]


def frame_state(frames):
    """VECT.C calculate(): the spline, the matrix, the projected points and the
    visible faces with their light."""
    tx, ty, dis, kx, ky, kz, ls_kx, ls_ky = getspl(4 * 256 + frames * 4)
    kx &= 1023; ky &= 1023; kz &= 1023
    ls_kx &= 1023; ls_ky &= 1023
    SX, SY, SZ = SINIT[kx], SINIT[ky], SINIT[kz]
    CX, CY, CZ = KOSINIT[kx], KOSINIT[ky], KOSINIT[kz]

    ls_y = sar(KOSINIT[ls_kx], 8)
    ls_x = sar(sar(SINIT[ls_kx], 8) * sar(SINIT[ls_ky], 8), 7)
    ls_z = sar(sar(SINIT[ls_kx], 8) * sar(KOSINIT[ls_ky], 8), 7)

    cxx = sar(CY * CZ, 22); cxy = sar(CY * SZ, 22); cxz = sar(-SY, 7)
    cyx = sar(sar(SX * CZ + 16384, 15) * SY - CX * SZ, 22)
    cyy = sar(sar(SX * SY + 16384, 15) * SZ + CX * CZ, 22)
    cyz = sar(CY * SX, 22)
    czx = sar(sar(CX * CZ + 16384, 15) * SY + SX * SZ, 22)
    czy = sar(sar(CX * SY + 16384, 15) * SZ - SX * CZ, 22)
    czz = sar(CY * CX, 22)

    pts = []
    for (x, y, z) in PNT:
        xx = s16(sar(sar(x * cxx, 1) + sar(y * cxy, 1) + sar(z * cxz, 1), 7) + tx)
        yy = s16(sar(sar(x * cyx, 1) + sar(y * cyy, 1) + sar(z * cyz, 1), 7) + ty)
        zz = s16(sar(sar(x * czx, 1) + sar(y * czy, 1) + sar(z * czz, 1), 7) + dis)
        xxx = int(xx * 256 / zz) + 320 if zz else 0
        yyy = int(yy * 142 / zz) + 66 if zz else 0
        pts.append((xx, yy, zz, xxx, yyy))

    draw = []
    for f in FACE:
        p1, p2, p3, p4, col = f
        x, y, z = pts[p1][0], pts[p1][1], pts[p1][2]
        ax, ay, az = (pts[p2][i] - (x, y, z)[i] for i in range(3))
        bx, by, bz = (pts[p3][i] - (x, y, z)[i] for i in range(3))
        nx = ay * bz - az * by
        ny = az * bx - ax * bz
        nz = ax * by - ay * bx
        if -x * nx + -y * ny + -z * nz > 0:
            continue                                       # backface
        s = int((ls_x * nx + ls_y * ny + ls_z * nz) / 250000) + 32
        draw.append((f, s))
    return pts, draw


def shadepal(shade, bank, fpal):
    for i in range(192):
        fpal[bank * 192 + i] = (PAL[bank * 192 + i] * (shade & 0xFF) >> 6) & 0xFF


def do_poly(vram, p, txt, color, dd):
    """PLZFILL.C do_poly + PLZA.ASM do_block, at BYTE (4-pixel) granularity."""
    dd = (dd + 1) & 63
    n = 0
    for a in range(1, 4):
        if p[a][1] < p[n][1]:
            n = a
    s1 = s2 = n
    d1, d2 = (s1 + 1) & 3, (s2 - 1) & 3

    def edge(s, d):
        dy = p[d][1] - p[s][1] or 1
        return (65536 * (p[d][0] - p[s][0]) // dy if p[d][0] >= p[s][0]
                else -(65536 * (p[s][0] - p[d][0]) // dy),
                (p[s][0] << 16) + 0x8000,
                (txt[s][0] << 16) + 0x8000, (txt[s][1] << 16) + 0x8000,
                cdiv(65536 * (txt[d][0] - txt[s][0]), dy),
                cdiv(65536 * (txt[d][1] - txt[s][1]), dy))

    def cdiv(a, b):
        q = abs(a) // abs(b)
        return q if (a < 0) == (b < 0) else -q

    ax1, xx1, txx1, txy1, tax1, tay1 = edge(s1, d1)
    ax2, xx2, txx2, txy2, tax2, tay2 = edge(s2, d2)
    yy = p[s1][1]
    cnt = 0
    while cnt < 4:
        m = min(p[d1][1], p[d2][1])
        # ---- do_block(m - yy)
        for _ in range(m - yy):
            if yy >= ROWS:
                return
            if yy >= 0:
                xl, xr = xx2 >> 16, xx1 >> 16
                di, nb = xl >> 2, (xr >> 2) - (xl >> 2)
                if nb >= 0:
                    if nb <= 1:
                        put(vram, yy, di, txx2, txy2, color, dd)
                        if nb == 1:
                            put(vram, yy, di + 1, txx1, txy1, color, dd)
                    else:
                        steps = nb - 1
                        tx, ty = txx1, txy1
                        addx = cdiv(txx2 - txx1, steps)
                        addy = cdiv(txy2 - txy1, steps)
                        for i in range(steps):
                            put(vram, yy, di + nb - 1 - i, tx, ty, color, dd)
                            tx += addx
                            ty += addy
            yy += 1
            xx1 += ax1; xx2 += ax2
            txx1 += tax1; txy1 += tay1
            txx2 += tax2; txy2 += tay2
        yy = m
        if p[d1][1] == p[d2][1]:
            s1, d1 = d1, (d1 + 1) & 3
            s2, d2 = d2, (d2 - 1) & 3
            cnt += 2
            ax1, xx1, txx1, txy1, tax1, tay1 = edge(s1, d1)
            ax2, xx2, txx2, txy2, tax2, tay2 = edge(s2, d2)
        elif p[d1][1] < p[d2][1]:
            s1, d1 = d1, (d1 + 1) & 3
            cnt += 1
            ax1, xx1, txx1, txy1, tax1, tay1 = edge(s1, d1)
        else:
            s2, d2 = d2, (d2 - 1) & 3
            cnt += 1
            ax2, xx2, txx2, txy2, tax2, tay2 = edge(s2, d2)


def put(vram, y, b, tx, ty, color, dd):
    if b < 0 or b >= BYTES:
        return
    a = (((ty >> 16) & 0xFF) << 8) | ((tx >> 16) & 0xFF)
    si = DIST[(a + dd * 256) & 0x7FFF]
    vram[y * BYTES + b] = KUVA[color][(a + si) & 0x7FFF]


def render(frames, avg=True):
    fpal = bytearray(768)
    pts, draw = frame_state(frames)
    for f, s in draw:
        shadepal(s, f[4], fpal)

    img = bytearray(W * H * 3)
    for phase in (0, 1) if avg else (0,):
        vram = bytearray(BYTES * ROWS)
        off = 2 if phase else 0     # page&1 draws at x+2; the pan takes it back
        for f, s in draw:
            p = [(pts[f[i]][3] + off, pts[f[i]][4]) for i in range(4)]
            do_poly(vram, p, TXT, f[4], frames & 63)
        for y in range(H):
            r = y // 3
            if r >= ROWS:
                continue
            for x in range(W):
                fx = 160 + x + off      # field pixel (pan cancels the +2)
                v = vram[r * BYTES + (fx >> 2)]
                o = (y * W + x) * 3
                for j in range(3):
                    c = fpal[v * 3 + j] * 255 // 63
                    img[o + j] = (img[o + j] + c) // 2 if (avg and phase) else c
    return img


def write_png(path, rgb, w, h):
    raw = b"".join(b"\x00" + bytes(rgb[y * w * 3:(y + 1) * w * 3])
                   for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return (struct.pack(">I", len(data)) + c
                + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF))

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b""))


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--frame", type=int)
    ap.add_argument("--capture", type=float)
    ap.add_argument("--raw", action="store_true")
    ap.add_argument("-o", default="cube.png")
    a = ap.parse_args()
    n = a.frame if a.frame is not None else round((a.capture - CAP_F0) * FPS)
    pts, draw = frame_state(n)
    print(f"frame {n}: spline={getspl(4 * 256 + n * 4)} faces={[f[0][4] for f in draw]}")
    write_png(a.o, render(n, avg=not a.raw), W, H)
    print(f"wrote {a.o}")
