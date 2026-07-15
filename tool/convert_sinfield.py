#!/usr/bin/env python3
"""Convert the 3D sinusfield's data (3DSINFLD.EXE, built from COMAN/) to
assets/tables/sinfield.srt.

Provenance (public domain, Unlicense -- github.com/mtuomi/SecondReality):

  COMAN/W1DTA.BIN, W2DTA.BIN -> sinfield.srt
      The two 32768-entry signed-word wave tables the voxel loop marches over
      (COMAN/ASM.ASM's `_wave1` / `_wave2`; MAIN.C links them as w1dta/w2dta,
      and COMAN/DOOBJS.BAT just slices these very .BIN files into the .OBJs the
      makefile links -- `getslice w1dta.bin 0 32768 w1dta1.bin`, etc).

      MAIN.C can also GENERATE them (the `#ifdef CALCW12` block: two sums of
      sines at 7x/3x and 5x/2x, with a dash of rand()), but the shipped build is
      compiled `noCALCW12` and links the precomputed data -- and that data has a
      random component, so it must be taken from the files, not regenerated.

      COMAN/DOLOOP.C's `zwave[]` (a third, 192-entry sine that ripples the
      terrain along the ray) is generated, not shipped, so the Dart side builds
      it with DOLOOP.C's own formula.

Layout of assets/tables/sinfield.srt ("SNF1"):

    "SNF1"
    u16 count (32768)
    count * i16le   -- wave1
    count * i16le   -- wave2

Usage: python3 tool/convert_sinfield.py
"""
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "original" / "COMAN"
COUNT = 32768


def main():
    out = bytearray(b"SNF1")
    out += struct.pack("<H", COUNT)
    for name in ("W1DTA.BIN", "W2DTA.BIN"):
        data = (SRC / name).read_bytes()
        assert len(data) == COUNT * 2, f"{name}: expected {COUNT*2} bytes"
        out += data
        vals = struct.unpack(f"<{COUNT}h", data)
        print(f"{name}: {COUNT} words, min {min(vals)}, max {max(vals)}")
    (ROOT / "assets/tables/sinfield.srt").write_bytes(bytes(out))
    print(f"assets/tables/sinfield.srt: {len(out)} bytes")


if __name__ == "__main__":
    main()
