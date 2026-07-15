#!/usr/bin/env python3
"""Convert the original TECHNO troll picture to the .sri format read by
lib/engine/sri_image.dart.

Provenance (public domain, Unlicense -- github.com/mtuomi/SecondReality):
  TECHNO/TROLL.UP -> troll.sri   the muscular troll/brute sitting on a rock
                                 against a purple sky, shown by KOE.C's
                                 doit1()/doit2() techno-box sequence.

Format reverse-engineered from TECHNO/READP.C (the `readp()` decoder) and its
caller in TECHNO/KOE.C:

  Header: 5x u16le { magic, wid, hig, cols, add }, padded to 16 bytes.
  Palette: cols*3 bytes at file offset 16, 6-bit VGA values (0..63).
  Row data starts at byte offset add*16. Each row is a u16le byte count `n`
  followed by `n` bytes of RLE payload:
    - byte with bit7 clear (< 0x80): literal pixel, emit once.
    - byte with bit7 set: count = byte & 0x7f, next byte is the pixel value,
      emit it `count` times.
  Decoded row is exactly `wid` pixels wide.

Usage: python3 tool/convert_troll.py
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLONE = ROOT / "original"  # the vendored original source (see original/VENDORED.md)

SRC = CLONE / "TECHNO/TROLL.UP"
OUT = ROOT / "assets/images/troll.sri"


def decode_row(payload: bytes, wid: int) -> bytes:
    out = bytearray()
    i = 0
    n = len(payload)
    while i < n:
        al = payload[i]
        i += 1
        if al & 0x80:
            count = al & 0x7f
            val = payload[i]
            i += 1
            out.extend([val] * count)
        else:
            out.append(al)
    if len(out) != wid:
        raise ValueError(f"row decoded to {len(out)} pixels, expected {wid}")
    return bytes(out)


def main():
    data = SRC.read_bytes()
    magic, wid, hig, cols, add = struct.unpack("<5h", data[:10])
    print(f"header: magic={magic & 0xffff:#06x} wid={wid} hig={hig} cols={cols} add={add}")
    assert wid == 320, wid
    assert hig == 400, hig

    pal_off = 16
    pal_src = data[pal_off:pal_off + cols * 3]
    pal = bytearray(768)
    pal[:len(pal_src)] = pal_src

    off = add * 16
    pixels = bytearray(wid * hig)
    for row in range(hig):
        n = struct.unpack_from("<H", data, off)[0]
        off += 2
        payload = data[off:off + n]
        off += n
        pixels[row * wid:(row + 1) * wid] = decode_row(payload, wid)

    out = b"SRI1" + struct.pack("<HH", wid, hig) + bytes(pal) + bytes(pixels)
    OUT.write_bytes(out)
    print(f"assets/images/troll.sri: {wid}x{hig}, {len(out)} bytes")
    print(f"source: {SRC.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
