#!/usr/bin/env python3
"""Convert the JPLOGO ("jellypic") picture to the .sri the part reads.

  original/JPLOGO/ICEKNGDM.UP -> assets/images/icekngdm.sri   (320x400)

Provenance (public domain, Unlicense -- github.com/mtuomi/SecondReality):

  ICEKNGDM.UP is the RLE picture JP.C links as `pic[]` and reads through
  READP.C's `readp()`. The format is READP.C's own `struct st_readp`:

      i16 magic, i16 wid, i16 hig, i16 cols, i16 add   (16-byte header)
      cols*3 bytes of 6-bit VGA palette at offset 16
      row data at offset add*16, one row after another:
          u16 byte count, then that many bytes:
              b & 0x80  -> run: (b & 0x7f) copies of the NEXT byte
              else      -> one literal pixel
  Verified here: the stream decodes to exactly 400 rows of 320 pixels and
  consumes the file to its last byte.

  JP.C only uses columns 70..253 of each row (`memcpy(row[y], rowbuf+70, 184)`)
  -- the black pillarbox bars in the file are not drawn, the 184-wide art is --
  and appends a 185th byte of colour 65, which the zoom routine's last sample
  can land on. The full 320x400 field is stored here anyway; the part slices it.

Run tool/convert_jplogo_ai.py instead to install the MODERNISED redraw.

Usage: python3 tool/convert_jplogo.py
"""
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "original" / "JPLOGO" / "ICEKNGDM.UP"
OUT = ROOT / "assets" / "images" / "icekngdm.sri"


def decode_up(data):
    _magic, wid, hig, cols, add = struct.unpack_from("<5h", data, 0)
    pal = bytearray(768)
    pal[:cols * 3] = data[16:16 + cols * 3]
    o = add * 16
    px = bytearray()
    for _ in range(hig):
        (n,) = struct.unpack_from("<H", data, o)
        o += 2
        end = o + n
        row = bytearray()
        while o < end:
            b = data[o]
            o += 1
            if b & 0x80:
                row += bytes([data[o]]) * (b & 0x7F)
                o += 1
            else:
                row.append(b)
        if len(row) != wid:
            sys.exit(f"row decoded to {len(row)} bytes, expected {wid}")
        px += row
    if o != len(data):
        sys.exit(f"{len(data) - o} trailing bytes")
    return wid, hig, bytes(pal), bytes(px)


def main():
    w, h, pal, px = decode_up(SRC.read_bytes())
    OUT.write_bytes(b"SRI1" + struct.pack("<HH", w, h) + pal + px)
    print(f"assets/images/icekngdm.sri: {w}x{h}, {len(set(px))} colours")


if __name__ == "__main__":
    main()
