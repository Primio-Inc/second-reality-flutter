#!/usr/bin/env python3
"""Convert the MODERNISED jellypic to the .sri the JPLOGO part reads.

  reference/art/icekngdm_ai.jpg -> assets/images/icekngdm.sri   (320x400)

This asset is deliberately NOT the original's pixels. JPLOGO/ICEKNGDM.UP is a
320x400 VGA picture whose ART lives in columns 70..253; here it is redrawn (AI,
at the user's request) in the same composition and quantised straight back into
the demo's own indexed format, so JP.C's logic is untouched: the scroll-in still
runs off the CRTC start address, and the jelly still resamples each row through
the same zoom table. Run tool/convert_jplogo.py to restore the original picture.

GEOMETRY. JP.C reads exactly columns 70..253 (184 px) of each of the 400 rows
and draws them at width 184 in a 320-wide field, so the art window is fixed. The
320x400 field is displayed as 4:3, i.e. pixels are 1.667x wider than tall, so
that window shows the art at 184*1.667 : 400 = 0.767:1 -- and the redraw has an
art aspect of 0.766, so it fills the window with no distortion and no crop. The
source's own black surround is detected and trimmed first.

PALETTE. Two indices are spoken for and must stay black:
  - index 0 is what the zoom routine writes OUTSIDE the picture (DOL.C's BLACK),
    so a bright colour there would light up the margins;
  - index 64 is forced black by JP.C (`palette[64*3+...] = 0`), which also
    re-maps the picture's own colour 0 onto it.
So the art is quantised to 254 colours and packed into indices 1..63 and 65..255.

Needs ffmpeg (crop/scale + a 256-colour palette with dithering); no Python deps.

Usage: python3 tool/convert_jplogo_ai.py
"""
import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'reference', 'art', 'icekngdm_ai.jpg')
OUT = os.path.join(ROOT, 'assets', 'images', 'icekngdm.sri')

W, H = 320, 400          # the stored field
ART_X, ART_W = 70, 184   # the columns JP.C actually draws


def run(*args):
    subprocess.run(args, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def probe_size(path):
    out = subprocess.run(
        ['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries',
         'stream=width,height', '-of', 'csv=p=0:s=x', path],
        check=True, capture_output=True, text=True).stdout.strip()
    return (int(v) for v in out.split('x'))


def art_bounds(path, w, h):
    """Trim the source's black surround: the columns/rows that carry the art."""
    with tempfile.TemporaryDirectory() as tmp:
        raw = os.path.join(tmp, 'p.raw')
        pw, ph = 200, max(1, round(200 * h / w))
        run('ffmpeg', '-v', 'error', '-y', '-i', path, '-vf', f'scale={pw}:{ph}',
            '-pix_fmt', 'rgb24', '-f', 'rawvideo', raw)
        with open(raw, 'rb') as f:
            d = f.read()

    def col_lit(x):
        return max(sum(d[(y * pw + x) * 3:(y * pw + x) * 3 + 3]) / 3
                   for y in range(ph))

    def row_lit(y):
        return max(sum(d[(y * pw + x) * 3:(y * pw + x) * 3 + 3]) / 3
                   for x in range(pw))

    xs = [x for x in range(pw) if col_lit(x) > 16]
    ys = [y for y in range(ph) if row_lit(y) > 16]
    if not xs or not ys:
        sys.exit('could not find the art in the source')
    x0 = round(xs[0] * w / pw)
    x1 = round((xs[-1] + 1) * w / pw)
    y0 = round(ys[0] * h / ph)
    y1 = round((ys[-1] + 1) * h / ph)
    return x0, y0, x1 - x0, y1 - y0


def main():
    if not os.path.exists(SRC):
        sys.exit(f'missing {SRC}')
    sw, sh = probe_size(SRC)
    cx, cy, cw, ch = art_bounds(SRC, sw, sh)
    print(f'source {sw}x{sh}, art at +{cx}+{cy} {cw}x{ch} '
          f'(aspect {cw / ch:.3f}; the 184x400 window shows {ART_W * 5 / 3 / H:.3f})')

    # Crop the surround, then squeeze into the 184x400 window JP.C draws.
    vf = f'crop={cw}:{ch}:{cx}:{cy},scale={ART_W}:{H}'

    with tempfile.TemporaryDirectory() as tmp:
        pal_png = os.path.join(tmp, 'pal.png')
        pal_raw = os.path.join(tmp, 'pal.raw')
        idx_raw = os.path.join(tmp, 'idx.raw')
        run('ffmpeg', '-v', 'error', '-y', '-i', SRC,
            '-vf', f'{vf},palettegen=max_colors=254:stats_mode=single', pal_png)
        run('ffmpeg', '-v', 'error', '-y', '-i', pal_png,
            '-pix_fmt', 'rgb24', '-f', 'rawvideo', pal_raw)
        run('ffmpeg', '-v', 'error', '-y', '-i', SRC, '-i', pal_png,
            '-lavfi', f'[0:v]{vf}[x];[x][1:v]paletteuse=dither=sierra2_4a',
            '-pix_fmt', 'pal8', '-f', 'rawvideo', idx_raw)
        with open(pal_raw, 'rb') as f:
            pal24 = f.read()
        with open(idx_raw, 'rb') as f:
            art = f.read()

    if len(art) != ART_W * H + 1024:
        sys.exit(f'art is {len(art)} bytes, expected {ART_W * H + 1024}')
    art = art[:ART_W * H]

    # Repack: indices 0 and 64 stay black, the art takes the other 254 slots.
    slots = [i for i in range(256) if i not in (0, 64)]
    used = sorted(set(art))
    if len(used) > len(slots):
        sys.exit(f'{len(used)} colours, only {len(slots)} slots')
    remap = {src: slots[k] for k, src in enumerate(used)}

    pal = bytearray(768)
    for src, dst in remap.items():
        for k in range(3):
            pal[dst * 3 + k] = pal24[src * 3 + k] >> 2  # 8-bit -> the 6-bit DAC

    px = bytearray(W * H)  # index 0 everywhere = the black surround
    for y in range(H):
        row = art[y * ART_W:(y + 1) * ART_W]
        base = y * W + ART_X
        for x in range(ART_W):
            px[base + x] = remap[row[x]]

    with open(OUT, 'wb') as f:
        f.write(b'SRI1')
        f.write(struct.pack('<HH', W, H))
        f.write(bytes(pal))
        f.write(bytes(px))
    print(f'icekngdm.sri  {W}x{H}, art in columns {ART_X}..{ART_X + ART_W - 1}, '
          f'{len(used)} colours (from {os.path.relpath(SRC, ROOT)})')


if __name__ == '__main__':
    main()
