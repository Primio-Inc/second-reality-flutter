#!/usr/bin/env python3
"""Convert the LENS + ROTOZOOMER part's data (LNS&ZOOM.EXE = LENS/MAIN.C) to:

  assets/images/lenspic.sri   -- the 320x200 monster picture + its palette.
  assets/tables/lens.srt      -- the lens sprite tables, the tint triples and
                                 the two recorded motion paths.

Provenance (public domain, Unlicense -- github.com/mtuomi/SecondReality).
Everything here is data the original SHIPPED; nothing is regenerated:

  LENS/LENSPIC.BBK -> lenspic.sri
      The monster picture. NOT LENS.EXB, and NOT LENSPIC.LBM: both of those are
      STALE in the source tree. The demo builds its picture with RUNME2.BAT
      (`glvp lenspic.lbm -xv!` -> lens.exb, a 16-byte header + a 768-byte 6-bit
      palette + 64000 chunky pixels, which MAIN.C reads at offset 784), but the
      LENSPIC.LBM that shipped with the sources is an EARLIER revision of the
      art: it has no PENTAGRAM on the monster's forehead, and the capture
      plainly does. LENSPIC.BBK -- Deluxe Paint's backup of the same picture --
      is the finished one, and it matches the capture pixel for pixel. Its
      palette is the same 64 colours as LENS.EXB's (identical after the 8->6 bit
      shift) and it indexes only 0..63, which is what MAIN.C's palette banks
      assume; only the pixels moved on. So: art from the .BBK, everything else
      from the shipped tables below.
      (The built MAIN/DATA/LNS&ZOOM.EXE would settle it directly, but it is
      PKLITE-compressed, and the .BBK already agrees with the capture.)

  LENS/LENS.EX0 -> the header of lens.srt
      u16 lens width (152), u16 lens height (116), then THREE RGB triples --
      (0,5,15), (0,7,26), (0,9,37). MAIN.C builds palette banks 1..3 by adding
      each triple to the picture's own 64 colours (clamped to 63); the lens
      then draws the refracted picture into bank 1 and its two highlight
      layers into banks 2 and 3. (The rest of the file is CALC.C's joke text
      plus 111 random bytes -- unused.)

  LENS/LENS.EX1..EX4 -> the four lens layers in lens.srt
      CALC.C precomputed these from LENS.U (its hand-drawn lens shape) by
      running `lenscalc` -- the actual refraction -- once, offline. There is NO
      runtime lens math: each layer is, per row, a run of (destination, source)
      screen offsets, and ASM.ASM's `dorow`/`dorow2`/`dorow3` just replay them.
      File layout (CALC.C's writer): 120 rows of {u16 byte offset of the row's
      words, u16 count}, then the words themselves (signed 16-bit deltas). The
      byte offset is `rowbeg*2 + 120*4`, so the word index is `(off-480)/2`.
      Layer 1 (colour 1 of LENS.U, OR 0x40): a contiguous run -- one SOURCE
      delta per pixel. Layers 2 and 3 (colours 2/3, OR 0x80/0xC0): PAIRS of
      (dest, source) deltas. Layer 4 (colour 4): plain offsets, copied back
      from the background -- this is the erase ring that heals the lens's
      trail as it moves.
      Every run's deltas are relative to the run's first pixel, and every row
      starts with that pixel's x within the lens.

  LENS/LENS.EXP -> the two paths in lens.srt
      MAIN.C is compiled with `#define noSAVEPATH`, so neither the bouncing
      lens's physics nor the rotozoomer's easing runs in the demo: both were
      recorded once (the `#ifdef SAVEPATH` branches) and REPLAYED from this
      file. Layout: u16 0, u16 pathstart2 (a word index), then path 1 --
      pairs of (x,y), one per frame -- and at word pathstart2 path 2 -- quads
      of (x, y, xa, ya), one per frame. 715 lens frames, 2000 rotozoomer
      frames, and 4 + 2*(715*2 + 2000*4) == 18864 == the file size, exactly.

Output `lens.srt` ("LNS1", little-endian):

    "LNS1"
    u16 lensWidth, u16 lensHeight
    9 bytes                          -- the three 6-bit RGB tint triples
    4x layer { u16 rows(120),
               rows x { u32 wordIndex, u16 count },
               u32 nwords, nwords x i16 }
    u16 path1Frames, path1Frames x 2 x i16
    u16 path2Frames, path2Frames x 4 x i16
"""

import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LENS = os.path.join(ROOT, 'original', 'LENS')

ROWS = 120          # CALC.C's ymax -- the row table it writes for every layer
HEADER_BYTES = ROWS * 4


def read(name):
    with open(os.path.join(LENS, name), 'rb') as f:
        return f.read()


def cmap(iff):
    """The CMAP (palette) chunk of an IFF file."""
    o = 12
    while o + 8 <= len(iff):
        tag = iff[o:o + 4]
        n = struct.unpack_from('>I', iff, o + 4)[0]
        if tag == b'CMAP':
            return iff[o + 8:o + 8 + n]
        o += 8 + n + (n & 1)
    raise ValueError('no CMAP chunk')


def decode_layer(blob, stride):
    """One LENS.EXn -> (per-row (wordIndex, count), the i16 word array).

    `stride` is how many words a row's count consumes per unit: 1 for the
    contiguous layer 1 and the erase layer 4, 2 for the (dest,source) pairs of
    layers 2 and 3.
    """
    rows = []
    for y in range(ROWS):
        off, cnt = struct.unpack_from('<HH', blob, y * 4)
        if (off - HEADER_BYTES) % 2:
            raise ValueError(f'row {y}: odd word offset {off}')
        rows.append(((off - HEADER_BYTES) // 2, cnt))
    words = list(struct.unpack_from(
        f'<{(len(blob) - HEADER_BYTES) // 2}h', blob, HEADER_BYTES))
    for y, (wi, cnt) in enumerate(rows):
        # dorow reads words[wi] (the run's x) then `stride*count` more; a row
        # with no pixels of this colour has count 0 and is skipped entirely.
        if cnt and wi + 1 + stride * cnt > len(words):
            raise ValueError(f'row {y}: run {wi}+{cnt} past the {len(words)} words')
    return rows, words


def convert_picture(dst):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from extract_font import decode_lbm  # the shared ILBM/PBM decoder

    blob = read('LENSPIC.BBK')
    w, h, pixels = decode_lbm(blob)
    if (w, h) != (320, 200):
        raise ValueError(f'LENSPIC.BBK is {w}x{h}, expected 320x200')
    if max(pixels) > 63:
        raise ValueError('LENSPIC.BBK uses colours above 63; the palette banks '
                         'MAIN.C builds at 64/128/192 would collide with them')
    palette = bytes(v >> 2 for v in cmap(blob))  # 8-bit CMAP -> the 6-bit DAC

    # The picture's own 64 colours must still be the ones the shipped LENS.EXB
    # carried -- if they are not, this is a different picture, not a newer
    # render of the same one, and the lens's palette banks would be wrong.
    exb = read('LENS.EXB')
    if palette[:192] != exb[16:16 + 192]:
        raise ValueError('LENSPIC.BBK palette does not match LENS.EXB')

    with open(dst, 'wb') as f:
        f.write(b'SRI1')
        f.write(struct.pack('<HH', 320, 200))
        f.write(palette)
        f.write(pixels)
    return len(palette) + len(pixels)


def convert_tables(dst):
    ex0 = read('LENS.EX0')
    lenswid, lenshig = struct.unpack_from('<HH', ex0, 0)
    tint = ex0[4:13]
    if lenswid != 152 or lenshig != 116:
        raise ValueError(f'unexpected lens size {lenswid}x{lenshig}')

    layers = [decode_layer(read(f'LENS.EX{i}'), stride)
              for i, stride in ((1, 1), (2, 2), (3, 2), (4, 1))]

    exp = read('LENS.EXP')
    _, pathstart2 = struct.unpack_from('<HH', exp, 0)
    words = struct.unpack_from(f'<{(len(exp) - 4) // 2}h', exp, 4)
    p1 = words[:pathstart2]
    p2 = words[pathstart2:]
    if len(p1) % 2 or len(p2) % 4:
        raise ValueError('path data is not a whole number of frames')
    n1, n2 = len(p1) // 2, len(p2) // 4

    out = bytearray(b'LNS1')
    out += struct.pack('<HH', lenswid, lenshig)
    out += tint
    for rows, ws in layers:
        out += struct.pack('<H', ROWS)
        for wi, cnt in rows:
            out += struct.pack('<IH', wi, cnt)
        out += struct.pack('<I', len(ws))
        out += struct.pack(f'<{len(ws)}h', *ws)
    out += struct.pack('<H', n1) + struct.pack(f'<{len(p1)}h', *p1)
    out += struct.pack('<H', n2) + struct.pack(f'<{len(p2)}h', *p2)
    with open(dst, 'wb') as f:
        f.write(out)
    return lenswid, lenshig, n1, n2, len(out)


def main():
    img = os.path.join(ROOT, 'assets', 'images', 'lenspic.sri')
    tbl = os.path.join(ROOT, 'assets', 'tables', 'lens.srt')
    n = convert_picture(img)
    print(f'lenspic.sri  320x200, {n} bytes of palette+pixels')
    w, h, n1, n2, size = convert_tables(tbl)
    print(f'lens.srt     lens {w}x{h}, {n1} lens frames, {n2} zoom frames, '
          f'{size} bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
