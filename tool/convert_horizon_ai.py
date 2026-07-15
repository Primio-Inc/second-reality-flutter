#!/usr/bin/env python3
"""Convert the MODERNISED horizon background to the .sri the intro part reads.

  reference/art/hoi_ai.jpg -> assets/images/hoi.sri   (640x200, 256 colours)

Like the troll, this asset is deliberately NOT the original's pixels: HOI.LBM is
redrawn (AI, at the user's request) and quantised straight back into the demo's
own indexed format, so ALKU/MAIN.C's logic is untouched -- the 320-wide window
still scrolls across it one pixel per SCRLF=9 retraces and parks at 320, and the
picture still fades up over its 128 retraces. Run tool/convert_assets.py to
restore the original picture.

GEOMETRY -- the original's framing, kept exactly. HOI.LBM is 640x200 but only
its top 151 rows hold art; the original CENTRES that band in the 200-row screen
(rows 25..175) with black above and below, and p02_horizon.dart finds the band by
scanning for the last row that is mostly non-zero. So the redraw is scaled to
640x151, laid in rows 0..150, and the rest left black.

INDEX 0 IS RESERVED for that padding (and for the demo's black), so the art is
quantised to 255 colours in indices 1..255 and shifted up by one. Without that, a
dark pixel in the art could quantise to 0 and the band-detection scan could stop
short of the picture's real bottom.

Needs ffmpeg; no Python deps.
"""

import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'reference', 'art', 'hoi_ai.jpg')
OUT = os.path.join(ROOT, 'assets', 'images', 'hoi.sri')

W, H = 640, 200
ART_ROWS = 151                   # the band the original fills; the rest is black
SCALE = f'scale={W}:{ART_ROWS}'


def run(*args):
    subprocess.run(args, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if not os.path.exists(SRC):
        sys.exit(f'missing {SRC}')
    with tempfile.TemporaryDirectory() as tmp:
        pal_png = os.path.join(tmp, 'pal.png')
        pal_raw = os.path.join(tmp, 'pal.raw')
        idx_raw = os.path.join(tmp, 'idx.raw')

        # 255 colours: index 0 of OUR palette is reserved for black.
        run('ffmpeg', '-v', 'error', '-y', '-i', SRC,
            '-vf', f'{SCALE},palettegen=max_colors=255:stats_mode=single',
            pal_png)
        run('ffmpeg', '-v', 'error', '-y', '-i', pal_png,
            '-pix_fmt', 'rgb24', '-f', 'rawvideo', pal_raw)
        run('ffmpeg', '-v', 'error', '-y', '-i', SRC, '-i', pal_png,
            '-lavfi', f'[0:v]{SCALE}[x];[x][1:v]paletteuse=dither=sierra2_4a',
            '-pix_fmt', 'pal8', '-f', 'rawvideo', idx_raw)

        with open(pal_raw, 'rb') as f:
            pal24 = f.read()
        with open(idx_raw, 'rb') as f:
            raw = f.read()

    art = W * ART_ROWS
    if len(raw) != art + 1024:  # rawvideo pal8 appends 256 x BGRA
        sys.exit(f'picture is {len(raw)} bytes, expected {art + 1024}')
    art_px = raw[:art]
    used = max(art_px)
    if used > 254:
        sys.exit(f'quantiser used index {used}; it must stay under 255 so every '
                 'colour can be shifted up past the reserved black')

    # Shift every art index up by one and put pure black at 0.
    pal = bytearray(768)
    for i in range(255):
        for k in range(3):
            pal[(i + 1) * 3 + k] = pal24[i * 3 + k] >> 2  # the DAC is 6-bit
    pixels = bytearray(W * H)  # the padding rows stay 0 = black
    for i, v in enumerate(art_px):
        pixels[i] = v + 1

    with open(OUT, 'wb') as f:
        f.write(b'SRI1')
        f.write(struct.pack('<HH', W, H))
        f.write(pal)
        f.write(pixels)
    print(f'hoi.sri      {W}x{H}, art in rows 0..{ART_ROWS - 1}, '
          f'{len(set(pixels))} colours used (from {os.path.relpath(SRC, ROOT)})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
