#!/usr/bin/env python3
"""Extract the original Second Reality proportional movie font (ALKU/FONA.LBM)
into the .srf font asset used by the Flutter port.

Replicates ALKU/MAIN.C: each pixel's low 2 bits are a shade (0..3, the "3
väriä" movie font); glyphs are separated by fully-empty columns and mapped in
the order of the `fonaorder` string. Space is width 16.

.srf format (little-endian):
  "SRF1" | u8 height | u16 glyphCount
  per glyph: u16 codepoint | u8 width | width*height shade bytes (0..3)

Usage: python3 tool/extract_font.py <FONA.LBM> <out.srf> [--preview word]
"""
import struct
import subprocess
import sys
from pathlib import Path

# fonaorder from ALKU/MAIN.C. Caps are A..X only (no Y/Z in the sheet).
# The four extended bytes (\x8f, \x99) are the Dolby-logo glyphs; map them to
# private codepoints 0xE000.. so the credits' ASCII stays clean.
_SPECIAL = {0x8f: 0xE000, 0x99: 0xE001}
FONAORDER_BYTES = (
    b"ABCDEFGHIJKLMNOPQRSTUVWX"
    b"abcdefghijklmnopqrstuvwxyz"
    b"0123456789"
    b"!?,.:\x8f\x8f()+-*='\x8f\x99\""
)


def decode_lbm(data):
    assert data[:4] == b"FORM", "not IFF"
    o = 12
    w = h = planes = comp = 0
    body = None
    ftype = data[8:12]  # 'ILBM' (planar) or 'PBM ' (chunky)
    while o + 8 <= len(data):
        cid = data[o:o + 4]
        ln = struct.unpack(">I", data[o + 4:o + 8])[0]
        ch = data[o + 8:o + 8 + ln]
        if cid == b"BMHD":
            w, h = struct.unpack(">HH", ch[0:4])
            planes, comp = ch[8], ch[10]
        elif cid == b"BODY":
            body = ch
        o += 8 + ln + (ln & 1)

    rb = ((w + 15) // 16) * 2

    def unpack(src):
        out = bytearray()
        i = 0
        while i < len(src):
            n = struct.unpack("b", src[i:i + 1])[0]
            i += 1
            if n >= 0:
                out += src[i:i + n + 1]
                i += n + 1
            elif n != -128:
                out += src[i:i + 1] * (1 - n)
                i += 1
        return bytes(out)

    raw = unpack(body) if comp == 1 else body

    if ftype == b"PBM ":  # chunky: one byte per pixel
        px = bytearray(raw[:w * h])
        if len(px) < w * h:
            px += bytes(w * h - len(px))
        return w, h, px

    # ILBM: planar, deinterleave bitplanes
    if len(raw) < rb * planes * h:
        raw = raw + bytes(rb * planes * h - len(raw))
    px = bytearray(w * h)
    p = 0
    for y in range(h):
        for pl in range(planes):
            for x in range(w):
                if (raw[p + (x >> 3)] >> (7 - (x & 7))) & 1:
                    px[y * w + x] |= 1 << pl
            p += rb
    return w, h, px


def extract(path):
    w, h, px = decode_lbm(Path(path).read_bytes())
    # The FONA sheet is an anti-aliased display image (cyan gradient palette);
    # a glyph pixel is simply any non-zero index. Store solid coverage (3);
    # the demo re-colours the movie font to white and fades it.
    shade = [[(3 if px[y * w + x] else 0) for x in range(w)] for y in range(h)]

    def col_empty(x):
        return all(shade[y][x] == 0 for y in range(h))

    order = []
    for b in FONAORDER_BYTES:
        order.append(_SPECIAL.get(b, b))

    glyphs = {}  # codepoint -> (width, grid rows[h][width])
    x = 0
    for cp in order:
        while x < w and col_empty(x):
            x += 1
        start = x
        while x < w and not col_empty(x):
            x += 1
        if start >= w:
            break
        gw = x - start
        if cp not in glyphs:  # first occurrence wins (matches C: last write, but
            glyphs[cp] = (gw, [row[start:start + gw] for row in shade])
    # Space: explicit width 16 (fonaw[32]=16 in the original).
    glyphs[0x20] = (16, [[0] * 16 for _ in range(h)])
    return h, glyphs


def encode_srf(height, glyphs):
    out = bytearray(b"SRF1")
    out += struct.pack("<BH", height, len(glyphs))
    for cp in sorted(glyphs):
        gw, grid = glyphs[cp]
        out += struct.pack("<HB", cp, gw)
        for row in grid:
            out += bytes(row)
    return bytes(out)


def preview(height, glyphs, word):
    total = sum(glyphs.get(ord(c), (0, None))[0] + 2 for c in word)
    img = [[0] * total for _ in range(height)]
    cx = 0
    for c in word:
        g = glyphs.get(ord(c))
        if not g:
            continue
        gw, grid = g
        for y in range(height):
            for x in range(gw):
                img[y][cx + x] = grid[y][x]
        cx += gw + 2
    ppm = bytearray(f"P6\n{total} {height}\n255\n".encode())
    lut = {0: (0, 0, 0), 1: (90, 90, 110), 2: (170, 170, 190), 3: (255, 255, 255)}
    for row in img:
        for s in row:
            ppm += bytes(lut[s])
    Path("/tmp/_font.ppm").write_bytes(ppm)
    subprocess.run(["sips", "-s", "format", "png", "/tmp/_font.ppm",
                    "--out", "/tmp/font_preview.png"], capture_output=True)
    print("preview -> /tmp/font_preview.png")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    height, glyphs = extract(src)
    Path(dst).write_bytes(encode_srf(height, glyphs))
    print(f"{dst}: {len(glyphs)} glyphs, height {height}")
    if "--preview" in sys.argv:
        preview(height, glyphs, sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
