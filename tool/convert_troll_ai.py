#!/usr/bin/env python3
"""Convert the MODERNISED troll picture to the .sri the techno part reads.

  reference/art/troll_ai.jpg -> assets/images/troll.sri   (320x400, 256 colours)

This one asset is deliberately NOT the original's pixels. TECHNO/TROLL.UP is a
320x400 VGA picture; here it is redrawn (AI, at the user's request) in the same
composition, and quantised straight back into the demo's own indexed format --
so everything downstream is untouched: KOE.C's scroll-in and damped ripple
still address it as one 640x400 planar field, its `+45` palette flash is still
a clamped add over the picture's own 6-bit DAC entries, and PANIC still reads
that DAC back and shuts the picture down. Run tool/convert_troll.py instead to
restore the original picture.

GEOMETRY. The 320x400 field is displayed as 4:3 (double-scanned, 1.67:1 pixels),
so a near-square source has to be pillarboxed, not cropped, to keep the troll's
proportions and his full height. The source is scaled to full height and to
`320 * aspect / (4/3)` px wide -- which un-squeezes back to its true aspect on
screen -- and centred in the 320-wide field, leaving the same black side borders
the original picture has.

Needs ffmpeg (scaling + a 256-colour palette with dithering); no Python deps.
"""

import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'reference', 'art', 'troll_ai.jpg')
OUT = os.path.join(ROOT, 'assets', 'images', 'troll.sri')

W, H = 320, 400
DISPLAY_ASPECT = 4 / 3


def run(*args):
    subprocess.run(args, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def source_aspect(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height', '-of', 'csv=p=0:s=x', path],
        check=True, capture_output=True, text=True).stdout.strip()
    w, h = (int(v) for v in out.split('x'))
    return w / h


def main():
    if not os.path.exists(SRC):
        sys.exit(f'missing {SRC}')

    # Full height, and as wide as the source's true aspect asks for once the
    # 4:3 display un-squeezes these pixels. Even width, so the pad is centred.
    inner = round(W * source_aspect(SRC) / DISPLAY_ASPECT / 2) * 2
    if inner > W:
        sys.exit(f'source is wider than 4:3; it would need cropping, not padding')
    pad = (W - inner) // 2
    scale = f'scale={inner}:{H},pad={W}:{H}:{pad}:0:black'

    with tempfile.TemporaryDirectory() as tmp:
        pal_png = os.path.join(tmp, 'pal.png')
        pal_raw = os.path.join(tmp, 'pal.raw')
        idx_raw = os.path.join(tmp, 'idx.raw')

        run('ffmpeg', '-v', 'error', '-y', '-i', SRC,
            '-vf', f'{scale},palettegen=max_colors=256:stats_mode=single',
            pal_png)
        run('ffmpeg', '-v', 'error', '-y', '-i', pal_png,
            '-pix_fmt', 'rgb24', '-f', 'rawvideo', pal_raw)
        run('ffmpeg', '-v', 'error', '-y', '-i', SRC, '-i', pal_png,
            '-lavfi', f'[0:v]{scale}[x];[x][1:v]paletteuse=dither=sierra2_4a',
            '-pix_fmt', 'pal8', '-f', 'rawvideo', idx_raw)

        with open(pal_raw, 'rb') as f:
            pal24 = f.read()
        with open(idx_raw, 'rb') as f:
            pixels = f.read()

    if len(pal24) != 256 * 3:
        sys.exit(f'palette is {len(pal24)} bytes, expected 768')
    # ffmpeg's rawvideo pal8 appends the palette (256 x BGRA) after the plane.
    if len(pixels) != W * H + 1024:
        sys.exit(f'picture is {len(pixels)} bytes, expected {W * H + 1024}')
    tail, pixels = pixels[W * H:], pixels[:W * H]
    for i in range(256):
        b, g, r, _ = tail[i * 4:i * 4 + 4]
        if (r, g, b) != tuple(pal24[i * 3:i * 3 + 3]):
            sys.exit(f'palette entry {i} disagrees with the palette image')

    # The DAC is 6-bit. Index 0 must stay pure black: the ripple and the
    # scroll-in expose it as the background, and PANIC fades it out.
    pal = bytes(v >> 2 for v in pal24)
    with open(OUT, 'wb') as f:
        f.write(b'SRI1')
        f.write(struct.pack('<HH', W, H))
        f.write(pal)
        f.write(pixels)
    print(f'troll.sri    {W}x{H}, {len(set(pixels))} colours used '
          f'(from {os.path.relpath(SRC, ROOT)})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
