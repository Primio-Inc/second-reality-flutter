#!/usr/bin/env python3
"""Convert the RAYSCRL part's data (RAYSCRL.EXE, built from WATER/DEMO.PAS) to:

  assets/images/rayback.sri   -- the 320x200 raytraced background (the mirror
                                 balls on the rippling water) + its palette.
  assets/tables/rayscrl.srt   -- the scroll-text strip + the three precalculated
                                 position tables consumed by WATER/ROUTINES.ASM's
                                 Putrouts1.

Provenance (public domain, Unlicense -- github.com/mtuomi/SecondReality):

  WATER/BKG.CLX -> rayback.sri
      The static raytraced picture. Same "RIX3" convention as FOREST's .CLX:
      10 bytes of header, a 768-byte 6-bit VGA palette at offset 10, then 64000
      bytes of 320x200 chunky pixels at offset 778 (10 + 768 + 64000 == 64778
      == the file size). DEMO.PAS does `move(mem[tausta+778], mem[tausta], 64000)`
      and blits that; we read the picture straight from its file offset.

      NOTE the palette: DEMO.PAS takes the DAC from MIEKKA.SCI, not from BKG.CLX
      (`move(mem[_miekka+10], pal, 768)`), because the text and the picture share
      one 256-colour DAC. So that is the palette written here.

  WATER/MIEKKA.SCI -> folded into rayscrl.srt (the text strip)
      A 400x250 "RIX3" picture; DEMO.PAS reads only the first 34 rows as the
      scroll font (`move(mem[_miekka+778], font, 400*34)`), i.e. a 400-wide by
      34-tall strip of the words the part scrolls. Unlike FOREST's additive
      strip, these bytes are OPAQUE colour indices: Putrouts1 writes the font
      byte if it is non-zero and the background byte otherwise.

  WATER/WAT1.DAT, WAT2.DAT, WAT3.DAT -> folded into rayscrl.srt (pos tables)
      The precalculated cell->screen-offset tables. WATER/DATGEN.PAS built them
      from POV-ray renders of the water surface (k1/k2/k3/k5.mtv) used as a UV
      map: a pixel's RED channel holds the scroll cell's COLUMN (1..158) and
      GREEN.CLX holds its ROW (1..34). So the ripple distortion, the perspective
      and the occlusion behind the balls are all baked into these offsets --
      nothing is projected or masked at runtime.

      DATGEN writes the cells as `for y := 34 downto 1 do for tt := 1 to 158 do`,
      so the stream is 34*158 = 5372 cells in that order, each:
          N = next u16   (0 => this cell lights no pixels)
          if N != 0: N further u16 screen offsets (0..63999)
      Verified here: each of the three files is consumed to its last byte by
      exactly 5372 cells. (WAT4.DAT exists but DEMO.PAS's scr() only selects
      wat1..wat3, and it does NOT parse cleanly as 5372 cells -- it is a leftover
      of the commented-out `zeta('o:k4.mtv',...)` line in DATGEN.PAS.)

      DATGEN only emits a pixel where the mapping CHANGES between the two renders
      it was given (`r^[x] <> r1^[x]`), so each table is the INCREMENTAL update
      for one phase of the water's 3-frame ripple cycle, on top of the picture
      already on screen. That is why the tables are cycled one per frame and why
      the background is blitted once, up front.

Layout of assets/tables/rayscrl.srt ("RAY1"):

    "RAY1"
    u16 stripW (400), u16 stripH (34)
    stripW*stripH bytes            -- the MIEKKA.SCI text strip (opaque indices)
    3x { u32 total, 5372 x u16 counts, total x u16 offsets }

Usage: python3 tool/convert_rayscrl.py
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "original" / "WATER"

COLS = 158  # scroll cells across
ROWS = 34   # scroll cells down
CELLS = COLS * ROWS  # 5372, the `dx` Putrouts1 counts down

STRIP_W = 400
STRIP_H = 34


def read_table(path):
    """Parse one WATn.DAT into (counts, offsets)."""
    data = path.read_bytes()
    counts = []
    offsets = []
    o = 0
    for _ in range(CELLS):
        (n,) = struct.unpack_from("<H", data, o)
        o += 2
        counts.append(n)
        for _ in range(n):
            (off,) = struct.unpack_from("<H", data, o)
            o += 2
            if off >= 64000:
                sys.exit(f"{path.name}: offset {off} outside the 320x200 screen")
            offsets.append(off)
    if o != len(data):
        sys.exit(f"{path.name}: {len(data) - o} trailing bytes -- not {CELLS} cells")
    return counts, offsets


def main():
    bkg = (SRC / "BKG.CLX").read_bytes()
    miek = (SRC / "MIEKKA.SCI").read_bytes()
    if bkg[:4] != b"RIX3" or miek[:4] != b"RIX3":
        sys.exit("BKG.CLX / MIEKKA.SCI: not RIX3 pictures")

    # The picture, with the DAC DEMO.PAS actually loads (MIEKKA's).
    pal = miek[10:778]
    pic = bkg[778:778 + 64000]
    sri = b"SRI1" + struct.pack("<HH", 320, 200) + pal + pic
    (ROOT / "assets/images/rayback.sri").write_bytes(sri)

    strip = miek[778:778 + STRIP_W * STRIP_H]

    out = bytearray(b"RAY1")
    out += struct.pack("<HH", STRIP_W, STRIP_H)
    out += strip
    for name in ("WAT1.DAT", "WAT2.DAT", "WAT3.DAT"):
        counts, offsets = read_table(SRC / name)
        out += struct.pack("<I", len(offsets))
        out += struct.pack(f"<{CELLS}H", *counts)
        out += struct.pack(f"<{len(offsets)}H", *offsets)
        print(f"{name}: {len(offsets)} offsets over {CELLS} cells")

    (ROOT / "assets/tables/rayscrl.srt").write_bytes(bytes(out))
    print(f"assets/images/rayback.sri: 320x200")
    print(f"assets/tables/rayscrl.srt: {len(out)} bytes")


if __name__ == "__main__":
    main()
