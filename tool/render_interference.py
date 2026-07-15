#!/usr/bin/env python3
"""Offline replica of TECHNO's interference part (KOEB dointerference2 +
KOEA dointerference), used to validate the Dart port against the capture.

Usage: render_interference.py <frame> [-o out.png]
  frame 0..255      -> phase 1 (KOEB): static rings only, fade black->white
  frame 256..       -> phase 2 (KOEA): + moving overlay = the interference
"""
import argparse
import re
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TBL = ROOT / "assets" / "tables" / "interference.srt"
SIN = ROOT / "original" / "TECHNO" / "SIN1024.INC"

W, H = 640, 400          # the mirrored ring field
SW, SH = 320, 200        # the visible window
PHASE1 = 256             # KOEB runs exactly 256 frames


def load_sin1024():
    vals = []
    for line in SIN.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line.lower().startswith("dw"):
            continue
        for tok in re.split(r"[,\s]+", line[2:].strip()):
            if tok:
                vals.append(int(tok))
    assert len(vals) == 1024, len(vals)
    return vals


SIN1024 = load_sin1024()


def mirror(quarter_bit):
    """4-way mirror a 320x200 sampler into the 640x400 field.

    init_interference blits each source row to the left half normally and to
    the right half byte- and bit-reversed (bltlinerev), and repeats both for
    row 399-r -- so the field is mirrored about x=320 and y=200.
    """
    field = bytearray(W * H)
    for y in range(H):
        sy = y if y < 200 else 399 - y
        row = y * W
        for x in range(W):
            sx = x if x < 320 else 639 - x
            field[row + x] = quarter_bit(sx, sy)
    return field


def load_fields():
    b = TBL.read_bytes()
    assert b[:4] == b"SRI2"
    o = 5
    static_q = b[o:o + 24000]; o += 24000
    overlay_q = b[o:o + 8000]

    def static_px(x, y):
        # row-interleaved: row y = plane0(40B), plane1(40B), plane2(40B)
        base = y * 120
        bit = 7 - (x & 7)
        byte = x >> 3
        v = 0
        for p in range(3):
            if static_q[base + p * 40 + byte] >> bit & 1:
                v |= 1 << p
        return v

    def overlay_px(x, y):
        return overlay_q[y * 40 + (x >> 3)] >> (7 - (x & 7)) & 1

    return mirror(static_px), mirror(overlay_px)


STATIC, OVERLAY = load_fields()

# --- palettes ---------------------------------------------------------------
# KOEA pal1/pal2: two 8-entry violet ramps (G = R*8/9 and R*7/9), stored twice
# so a 24-byte read at any rotation offset 0..21 stays in bounds.
PAL1 = [(v, v * 8 // 9, v) for v in (30, 60, 50, 40, 30, 20, 10, 0)] * 2
PAL2 = [(v, v * 7 // 9, v) for v in (0, 10, 20, 30, 40, 50, 60, 30)] * 2
# KOEB pal0: only entry 0 of each 8 is lit, so exactly one ring band glows.
PAL0 = [(0, 30, 40)] + [(0, 0, 0)] * 7
PAL0 = PAL0 * 2


def sar(v, n):
    return v >> n if v >= 0 else -((-v) >> n) if False else v >> n


def phase1_palette(frame):
    """KOEB: both banks are pal0, rotated, mixed through palfader 0->512."""
    palanimc = (-3 * frame) % 24          # patdir = -3 from the start
    palfader = min(512, 2 * (frame + 1))
    rot = palanimc // 3
    out = []
    for j in range(8):
        r, g, b = PAL0[rot + j]
        if palfader <= 256:
            out.append(tuple(c * palfader >> 8 for c in (r, g, b)))
        else:
            out.append(tuple(min(63, c + palfader - 256) for c in (r, g, b)))
    return out + out                       # colours 8..15 = same bank


def phase2_palette(frame):
    palanimc = (-3 * frame) % 24
    rot = palanimc // 3
    return [PAL1[rot + j] for j in range(8)] + [PAL2[rot + j] for j in range(8)]


def phase2_state(n):
    """State after n applications of do_interference's MOVE block."""
    scrnrot = (5 * n) & 1023
    scrnx = (SIN1024[scrnrot] >> 2) + 160
    scrny = (SIN1024[(scrnrot + 256) & 1023] >> 2) + 100
    overrot = (211 + 7 * n) & 1023
    overx = (SIN1024[overrot] >> 2) + 160
    overy = (SIN1024[(overrot + 256) & 1023] >> 2) + 100
    # sinuspower ramps in from frame 70*5, one step per 16 frames, cap 15.
    sp = 0 if n < 350 else min(15, (n - 350) // 16 + 1)
    sinurot = (7 * (n + 1)) & 1023
    return scrnx, scrny, overx, overy, sp, sinurot


def render(frame):
    px = bytearray(SW * SH)
    if frame < PHASE1:
        pal = phase1_palette(frame)
        scrnx, scrny = 160, 100            # sizefade = 0 -> no scroll
        for L in range(SH):
            row = (scrny + L) * W + scrnx
            for X in range(SW):
                px[L * SW + X] = STATIC[row + X]
    else:
        n = frame - PHASE1
        pal = phase2_palette(n)
        scrnx, scrny, overx, overy, sp, sinurot = phase2_state(n)
        for L in range(SH):
            idx = (sinurot + 9 * (L + 1)) & 1023
            raw = SIN1024[idx] >> 3                 # sar bx,3  -> +-32
            wob = int(raw * sp / 15)                # power0[sp][raw], trunc
            srow = (scrny + L) * W + scrnx
            orow = (overy + L) * W + overx + wob - 7
            for X in range(SW):
                px[L * SW + X] = STATIC[srow + X] | OVERLAY[orow + X] << 3

    rgb = bytearray(SW * SH * 3)
    for i, v in enumerate(px):
        r, g, b = pal[v]
        rgb[i * 3] = r * 255 // 63
        rgb[i * 3 + 1] = g * 255 // 63
        rgb[i * 3 + 2] = b * 255 // 63
    return rgb


def write_png(path, rgb, w, h):
    import zlib
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
    ap.add_argument("frame", type=int)
    ap.add_argument("-o", default="interference.png")
    a = ap.parse_args()
    write_png(a.o, render(a.frame), SW, SH)
    print(f"wrote {a.o} frame={a.frame} "
          f"({'phase1' if a.frame < PHASE1 else 'phase2'})")
