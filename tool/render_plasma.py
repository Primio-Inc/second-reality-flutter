#!/usr/bin/env python3
"""Offline replica of PLZPART's plz() -- the flat plasma -- used to validate the
port's math, palettes, drop and timing against the video capture before touching
Dart.  Same math as lib/parts/p12_plasma.dart.

The screen it models is NOT 320x200.  TWEAK.ASM's tw_opengraph2 turns mode 13h
into a 4-plane unchained mode with CRTC 09h=0 (no double scan -> 400 lines) and
13h=0x30 (offset 48 -> a 96-byte / 384-pixel row pitch), and PLZ.C draws only
MAXY=280 rows of it at address 0.  A split screen (CRTC 18h = the line compare)
puts the plasma BELOW scanline 60 and the (black) cop_start page above it, so the
plasma sits in a 280-line band with 60 black lines above and below -- exactly
what the capture shows.  COPPER.ASM's do_drop then walks the line compare down a
gravity parabola (dtau) to push the plasma off the bottom at each palette change.

Usage:
  render_plasma.py --frame N [--pal P] [--params K1,K2,K3,K4,L1,L2,L3,L4]
  render_plasma.py --capture T     # render the frame the capture shows at T
"""
import argparse
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "assets" / "tables" / "plasma.srt"

COLS = 84            # bytes written per scanline by plzline (84*4 = 336 px)
MAXY = 280           # PLZ.C
PITCH = 384          # 96 bytes * 4 planes
W, H = 320, 400      # visible
FPS = 70.086         # the VGA retrace = COPPER.ASM's copper2

# PLZ.C
TIMETABLE = [64 * 6 * 2 - 45, 64 * 6 * 4 - 45, 64 * 6 * 5 - 45, 64 * 6 * 6 - 45]
INITTABLE = [
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
    [1000, 2000, 4000, 4000, 1500, 2300, 3900, 1670],
    [3500, 1000, 3000, 1000, 3500, 3300, 2900, 2670],
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
]
# COPPER.ASM `dtau`: dw ccc*ccc/4*43/128+60, ccc = 0..64  (the drop's gravity)
DTAU = [(c * c // 4) * 43 // 128 + 60 for c in range(65)]

# --- the capture's own timeline (see p12_plasma.dart for how it was measured) --
CAP_T0 = 306.98          # dis_setmframe(0): fitted from the three drops
CAP_DROPS = [320.836, 335.560, 342.920]


def load_tables():
    b = TBL.read_bytes()
    # SRP2 added the spline/path tables the CUBE needs, AFTER the four tables
    # this renderer reads — so the prefix is unchanged and either version loads.
    assert b[:4] in (b"SRP1", b"SRP2"), b[:4]
    o = 5
    psini = list(b[o:o + 16384]); o += 16384
    lsini4 = list(struct.unpack_from("<8192h", b, o)); o += 16384
    lsini16 = list(struct.unpack_from("<8192h", b, o)); o += 16384
    ptau = list(b[o:o + 129])
    return psini, lsini4, lsini16, ptau


PSINI, LSINI4, LSINI16, PTAU = load_tables()


def build_palettes():
    """init_plz()'s five palettes, and the *8 / (x-63)*2 scaling it ends with.

    These are FADE DELTAS, not DAC values: COPPER.ASM's do_drop accumulates them
    into a 16.8 fixed-point `fadepal` and outputs the high byte.
    """
    pals = [[0] * 768 for _ in range(6)]

    def fill(p, seq):
        i = 3
        for rgb in seq:
            for v in rgb:
                pals[p][i] = v
                i += 1

    t = PTAU
    fill(0, [(t[a], t[0], t[0]) for a in range(1, 64)]          # RGB
          + [(t[63 - a], t[0], t[0]) for a in range(64)]
          + [(t[0], t[0], t[a]) for a in range(64)]
          + [(t[a], t[0], t[63 - a]) for a in range(64)])
    fill(1, [(t[a], t[0], t[0]) for a in range(1, 64)]          # RB-black
          + [(t[63 - a], t[0], t[a]) for a in range(64)]
          + [(t[0], t[a], t[63 - a]) for a in range(64)]
          + [(t[a], t[63], t[a]) for a in range(64)])
    fill(3, [(t[a], t[0], t[0]) for a in range(1, 64)]          # RB-white
          + [(t[63], t[a], t[a]) for a in range(64)]
          + [(t[63 - a], t[63 - a], t[63]) for a in range(64)]
          + [(t[0], t[0], t[63]) for a in range(64)])
    fill(2, [(t[0] // 2,) * 3 for a in range(1, 64)]            # white
          + [(t[a] // 2,) * 3 for a in range(64)]
          + [(t[63 - a] // 2,) * 3 for a in range(64)]
          + [(t[0] // 2,) * 3 for a in range(64)])
    fill(4, [(t[63 - a * 64 // 75],) * 3 for a in range(1, 75)]  # white II
          + [(0, 0, 0) for a in range(106)]
          + [(t[a * 64 // 75] * 8 // 10, t[a * 64 // 75] * 9 // 10,
              t[a * 64 // 75]) for a in range(75)])

    for i in range(768):
        pals[0][i] = (pals[0][i] - 63) * 2
    for p in range(1, 5):
        for i in range(768):
            pals[p][i] *= 8
    return pals


PALS = build_palettes()


def fade_dac(pal, steps, start_hi):
    """COPPER.ASM do_drop's palette fade: a 16.8 accumulator per DAC byte."""
    dac = []
    for i in range(768):
        acc = (start_hi << 8) + steps * PALS[pal][i]
        dac.append(max(0, min(63, acc >> 8)))
    return dac


def plasma_byte(c, y, p1, p2, p3, p4):
    """One byte of plzline (ASMYT.ASM), byte-column c (=4 pixels), scanline y.

    setplzparas patches the four displacements; the reads are
        psini[c*8 + p1 + lsini16[(80-c)*4 + p2 + y]]
      + psini[(80-c)*4 + p3 + 2*y + lsini4[c*16 + p4 + y]]
    """
    s = LSINI16[(80 - c) * 4 + p2 + y]
    a = PSINI[c * 8 + p1 + s]
    u = LSINI4[c * 16 + p4 + y]
    b = PSINI[(80 - c) * 4 + p3 + 2 * y + u]
    return (a + b) & 255


def moveplz(p, n):
    """n applications of COPPER.ASM's moveplz to (k1..k4, l1..l4)."""
    d = (-3, -2, 1, 2, -1, -2, 2, 3)   # k1..k4, l1..l4
    return [(p[i] + d[i] * n) & 4095 for i in range(8)]


def render(k, l, lc, dac, avg=True):
    """The visible 320x400 screen.

    Planes 1,3 (odd x) carry the k plasma on even memory rows and the l plasma
    on odd ones; planes 0,2 (even x) carry the other -- a per-pixel checkerboard
    of two plasmas.  COPPER.ASM's pompota then flickers the split line (60/61)
    and the pixel pan (2px/0px) every retrace, which swaps the checkerboard at
    70 Hz; on a CRT the eye sees the AVERAGE of the two fields, and that is what
    --avg reproduces (the raw single field is a hard dither at our scale).
    """
    rows = {}

    def prow(pp, my):
        key = (tuple(pp), my)
        if key not in rows:
            rows[key] = [plasma_byte(c, my, *pp) for c in range(COLS)]
        return rows[key]

    img = bytearray(W * H * 3)
    for y in range(H):
        for phase in (0, 1) if avg else (0,):
            pan, split = (2, lc) if phase == 0 else (0, lc + 1)
            my = y - split
            if my < 0 or my >= MAXY:
                px = None
            else:
                kb = prow(k, my)
                lb = prow(l, my)
            for x in range(W):
                mx = x + pan
                if my < 0 or my >= MAXY:
                    v = 0
                else:
                    row = kb if ((mx + my) & 1) else lb
                    v = row[mx >> 2]
                o = (y * W + x) * 3
                for j in range(3):
                    c = dac[v * 3 + j] * 255 // 63
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


def state_at_capture(t):
    """(k, l, lc, dac) for the frame the capture shows at time t.

    Anchored on the three drops measured off the capture, so it needs no model
    of the mframe clock: after each switch COPPER.ASM's initpparas reloads the
    plasma parameters from inittable, which makes the phase EXACT from there on.
    """
    phase = sum(1 for d in CAP_DROPS if t >= d)     # palette in use = phase
    if phase == 0:
        base = INITTABLE[0]
        n = round((t - CAP_T0) * FPS)               # (see p12_plasma: phase 0's
        p = moveplz(base[4:] + base[:4], n)         # absolute phase is unknowable)
        drop = 0
        steps = min(127, n)
        dac = fade_dac(0, steps, 63)
    else:
        d0 = CAP_DROPS[phase - 1]
        n = round((t - d0) * FPS)                   # frames since cop_drop = 1
        drop = min(n + 1, 64) if n < 64 else 0
        base = INITTABLE[phase]
        p = moveplz(base[4:] + base[:4], max(0, n - 64))
        steps = max(0, min(31, n - 64))
        dac = fade_dac(phase, steps, 0)
    k, l = p[:4], p[4:]
    lc = DTAU[drop] if drop else 60
    return k, l, lc, dac


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", type=float)
    ap.add_argument("--frame", type=int)
    ap.add_argument("--pal", type=int, default=0)
    ap.add_argument("--raw", action="store_true", help="one field, no flicker avg")
    ap.add_argument("-o", default="plasma.png")
    a = ap.parse_args()
    if a.capture is not None:
        k, l, lc, dac = state_at_capture(a.capture)
        print(f"capture t={a.capture}: k={k} l={l} lc={lc}")
    else:
        n = a.frame
        base = INITTABLE[a.pal]
        p = moveplz(base[4:] + base[:4], n)
        k, l, lc = p[:4], p[4:], 60
        dac = fade_dac(a.pal, 31 if a.pal else 127, 0 if a.pal else 63)
    write_png(a.o, render(k, l, lc, dac, avg=not a.raw), W, H)
    print(f"wrote {a.o}")
