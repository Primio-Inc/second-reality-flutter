#!/usr/bin/env python3
"""Convert the FOREST part's data (MNTSCRL.EXE, built from READ2.PAS) to:

  assets/images/hillback.sri  -- the 320x200 forest background + its palette.
  assets/tables/forest.srt    -- the scroll-text strip + the three
                                  precalculated position tables consumed by
                                  ROUTINES.ASM's Putrouts.

Provenance (public domain, Unlicense -- github.com/mtuomi/SecondReality):

  FOREST/HILLBACK.CLX -> hillback.sri
      The static forest/hills background picture, shown under the scrolling
      "leaf" text. READ2.PAS's own header comment gives the layout: 10 bytes
      of header, then a 768-byte 6-bit VGA palette at offset 10
      (`move(mem[hback+10], pal, 768)`), then 64000 bytes of 320x200 chunky
      pixels at offset 778 (`move(mem[hback+778], mem[hback], 64000)` --
      READ2 shifts the picture down over its own header before blitting it;
      we just read the picture straight from its file offset). Verified here:
      10 + 768 + 64000 == 64778 == the file size, exactly.

  FOREST/O2.SCI -> folded into forest.srt (text strip)
      The scroll-text bitmap: same 10-byte "RIX3" header + 768-byte palette
      convention (the palette is unused here -- the strip is drawn as an
      ADDITIVE shade added onto the background, per Putrouts below). After
      the header, the file holds 640-wide rows; READ2.PAS only reads 31 of
      them (`for x := 0 to 30 do ... blockread(f, fbuf[x*640], 640)`, seeking
      to `x*640+778` each time) even though the file has room for 32
      (640*32 == 20480 == 21258-778, one row wider than what's used).
      READ2.PAS then does `if fbuf[x] > 0 then inc(fbuf[x], 128)` over the
      whole buffer -- we bake that +128 in here so Dart doesn't redo it.

  FOREST/POS1.DAT, POS2.DAT, POS3.DAT -> folded into forest.srt (pos tables)
      Precalculated destination-offset tables consumed by ROUTINES.ASM's
      `Putrouts`. Each is a stream of u16le words iterated for exactly
      237*31 = 7347 font cells, in row-major (cell = row*237 + col) order
      matching `font: array[0..237*31] of byte` in READ2.PAS:
        for each cell:
          N = next u16   (0 => cell hidden, no further words for this cell)
          if N != 0: N further u16 destination offsets follow (0..63999,
                     an index into the 320x200 VGA screen)
      Putrouts does, per offset in the cell: `screen[di] = background[di] +
      font[cell]` (the outer bx increments once per cell, so the whole cell's
      offset list shares one font byte -- that's why the file needs no value,
      only a *where*: the font value comes from the caller's font buffer).
      Each of the three .DAT files is a different scroll-text FRAME position
      (READ2.PAS's `scr(pos)` selects posi1/posi2/posi3 round-robin), so
      together they double as a soft mask that only lights up pixels where
      the leaf/branch foreground of hillback.sri does NOT occlude the text.

Layout of assets/tables/forest.srt ("FRS1"):
    "FRS1"
    u16le stripW (640), u16le stripH (31)
    stripW*stripH bytes        -- the O2.SCI strip, AFTER the +128 adjustment
    then, for each of the 3 position tables (POS1, POS2, POS3 in order):
        u32le totalOffsets     -- total destination offsets in this table
        7347 * u16le counts    -- per-cell offset count (0 == hidden cell)
        totalOffsets * u16le offsets  -- concatenated, in cell order

Usage: python3 tool/convert_forest.py
"""
import struct
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLONE = ROOT / "original"  # the vendored original source (see original/VENDORED.md)
FOREST = CLONE / "FOREST"

CELLS = 237 * 31  # font: array[0..237*31] of byte in READ2.PAS
STRIP_W, STRIP_H = 640, 31  # fbuf rows actually read by READ2.PAS (0..30)

HILLBACK_SRC = FOREST / "HILLBACK.CLX"
O2_SRC = FOREST / "O2.SCI"
POS_SRCS = [FOREST / "POS1.DAT", FOREST / "POS2.DAT", FOREST / "POS3.DAT"]

HILLBACK_OUT = ROOT / "assets/images/hillback.sri"
FOREST_OUT = ROOT / "assets/tables/forest.srt"


def decode_hillback():
    """HILLBACK.CLX -> (w, h, 768-byte 6-bit palette, 64000 pixel bytes)."""
    data = HILLBACK_SRC.read_bytes()
    assert len(data) == 64778, f"HILLBACK.CLX size {len(data)}, expected 64778"
    assert 10 + 768 + 64000 == 64778
    magic = data[:4]
    assert magic == b"RIX3", f"unexpected magic {magic!r}"
    w, h = struct.unpack_from("<HH", data, 4)
    assert (w, h) == (320, 200), f"unexpected dims {w}x{h}"
    pal = data[10:778]
    px = data[778:778 + 64000]
    assert len(pal) == 768 and len(px) == 64000
    assert max(pal) <= 63, f"palette byte > 63 found: max={max(pal)} (not 6-bit)"
    return w, h, pal, px


def decode_strip():
    """O2.SCI -> 640x31 strip bytes, with the +128 rule already applied."""
    data = O2_SRC.read_bytes()
    magic = data[:4]
    assert magic == b"RIX3", f"unexpected magic {magic!r}"
    w, h = struct.unpack_from("<HH", data, 4)
    assert w == 640, f"unexpected strip width {w}"
    # The file holds 32 rows of 640 after the header; READ2.PAS only reads 31.
    assert len(data) - 778 == 640 * 32, f"O2.SCI pixel area size {len(data) - 778}"

    strip = bytearray(STRIP_W * STRIP_H)
    for row in range(STRIP_H):
        off = 778 + row * 640  # matches READ2.PAS: seek(f, x*640+778)
        strip[row * STRIP_W:(row + 1) * STRIP_W] = data[off:off + STRIP_W]

    for i, v in enumerate(strip):
        if v > 0:
            strip[i] = v + 128  # READ2.PAS: if fbuf[x] > 0 then inc(fbuf[x],128)
    return bytes(strip)


def decode_pos_table(path):
    """One POS*.DAT -> (counts[7347], offsets[] concatenated in cell order)."""
    data = path.read_bytes()
    n = len(data)
    off = 0
    counts = []
    offsets = []
    for cell in range(CELLS):
        if off + 2 > n:
            raise AssertionError(f"{path.name}: truncated before cell {cell}")
        (cnt,) = struct.unpack_from("<H", data, off)
        off += 2
        counts.append(cnt)
        for _ in range(cnt):
            if off + 2 > n:
                raise AssertionError(f"{path.name}: truncated inside cell {cell}")
            (d,) = struct.unpack_from("<H", data, off)
            off += 2
            if not (0 <= d <= 63999):
                raise AssertionError(f"{path.name}: offset {d} out of 0..63999")
            offsets.append(d)
    if off != n:
        raise AssertionError(
            f"{path.name}: {n - off} trailing bytes after {CELLS} cells")
    return counts, offsets


def main():
    # --- hillback.sri ---
    w, h, pal, px = decode_hillback()
    hist = Counter(px)
    print(f"HILLBACK.CLX: {w}x{h}, palette max={max(pal)} (6-bit ok), "
          f"pixel range {min(px)}..{max(px)}, "
          f"top colours {hist.most_common(5)}")

    hb_out = b"SRI1" + struct.pack("<HH", w, h) + bytes(pal) + bytes(px)
    HILLBACK_OUT.parent.mkdir(parents=True, exist_ok=True)
    HILLBACK_OUT.write_bytes(hb_out)
    print(f"wrote {HILLBACK_OUT} ({len(hb_out)} bytes)")

    # --- text strip ---
    strip = decode_strip()
    shist = Counter(strip)
    print(f"O2.SCI strip: {STRIP_W}x{STRIP_H}, "
          f"value range {min(strip)}..{max(strip)}, top {shist.most_common(5)}")

    # --- position tables ---
    buf = bytearray(b"FRS1")
    buf += struct.pack("<HH", STRIP_W, STRIP_H)
    buf += strip

    for path in POS_SRCS:
        counts, offsets = decode_pos_table(path)
        hidden = sum(1 for c in counts if c == 0)
        print(f"{path.name}: {CELLS} cells, {hidden} hidden, "
              f"{len(offsets)} total offsets, max per cell {max(counts)}")
        buf += struct.pack("<I", len(offsets))
        buf += struct.pack(f"<{CELLS}H", *counts)
        buf += struct.pack(f"<{len(offsets)}H", *offsets)

    FOREST_OUT.parent.mkdir(parents=True, exist_ok=True)
    FOREST_OUT.write_bytes(buf)
    print(f"wrote {FOREST_OUT} ({len(buf)} bytes)")


if __name__ == "__main__":
    main()
