#!/usr/bin/env python3
"""Convert the MODERNISED END logo (the Future Crew rings) to the .sri the part
reads.

  reference/art/fcrings_ai.png -> assets/images/fcrings.sri  (320x400, 256 col)

Like the troll, the horizon, the title and the jellypic, this is a redraw (AI, at
the user's request) quantised back into the demo's own indexed format, so
END/END.C's logic is untouched: p18_endlogo still lerps EVERY palette entry from
pure WHITE to its real colour over 129 retraces, holds, and then scales every
entry to black over 64. Nothing else shares this palette, so the art is free to
use all 256 colours — and because the fade comes FROM white and ends in black,
the original's black background is fine to keep.

GEOMETRY. The 320x400 field is double-scanned and displayed as 4:3, so a 4:3
source fills it exactly: it is simply scaled to 320x400 (vertically squashed in
storage, un-squeezed on screen). No padding, no crop.

Restore the original END/PIC.LBM with tool/convert_assets.py.

Needs ffmpeg; no Python deps.
"""

import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'reference', 'art', 'fcrings_ai.png')
OUT = os.path.join(ROOT, 'assets', 'images', 'fcrings.sri')

W, H = 320, 400
SCALE = f'scale={W}:{H}'


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

        run('ffmpeg', '-v', 'error', '-y', '-i', SRC,
            '-vf', f'{SCALE},palettegen=max_colors=256:stats_mode=single',
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

    if len(raw) != W * H + 1024:  # rawvideo pal8 appends 256 x BGRA
        sys.exit(f'picture is {len(raw)} bytes, expected {W * H + 1024}')
    pixels = raw[:W * H]
    pal = bytes(v >> 2 for v in pal24)  # the DAC is 6-bit

    with open(OUT, 'wb') as f:
        f.write(b'SRI1')
        f.write(struct.pack('<HH', W, H))
        f.write(pal)
        f.write(pixels)
    print(f'fcrings.sri  {W}x{H}, {len(set(pixels))} colours used '
          f'(from {os.path.relpath(SRC, ROOT)})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
