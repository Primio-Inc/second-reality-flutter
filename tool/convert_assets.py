#!/usr/bin/env python3
"""Convert original Second Reality picture assets to the .sri format read by
lib/engine/sri_image.dart. Uses the shared ILBM/PBM decoder in extract_font.py.

Provenance (public domain, Unlicense — github.com/mtuomi/SecondReality):
  ALKU/HOI.LBM   -> hoi.sri     intro horizon (starfield + blue mountains)
  BEG/SRTITLE.LBM -> srtitle.sri "Second Reality" demon-logo title
  GLENZ/FC.LBM   -> fc.sri      glenz checkerboard picture (board rows 0-99,
                                front-edge rows 100-115), revealed by MAIN.C
  END/PIC.LBM    -> fcrings.sri the Future Crew rings, the END logo (320x400,
                                double-scanned; END.C fades it up from white).
                                NUTS.LBM is a byte-identical copy of it.

The movie font (ALKU/FONA.LBM) is handled by tool/extract_font.py.

Usage: python3 tool/convert_assets.py
"""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_font import decode_lbm  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CLONE = ROOT / "original"  # the vendored original source (see original/VENDORED.md)

JOBS = {
    "ALKU/HOI.LBM": "hoi",
    "BEG/SRTITLE.LBM": "srtitle",
    "GLENZ/FC.LBM": "fc",
    "END/PIC.LBM": "fcrings",
}


def read_cmap(data):
    o = 12
    while o + 8 <= len(data):
        cid = data[o:o + 4]
        ln = struct.unpack(">I", data[o + 4:o + 8])[0]
        if cid == b"CMAP":
            return data[o + 8:o + 8 + ln]
        o += 8 + ln + (ln & 1)
    return bytes(768)


def main():
    for src, name in JOBS.items():
        data = (CLONE / src).read_bytes()
        w, h, px = decode_lbm(data)
        cmap = read_cmap(data)
        pal = bytearray(768)
        for i in range(min(len(cmap), 768)):
            pal[i] = cmap[i] >> 2  # 8-bit CMAP -> 6-bit VGA DAC
        out = b"SRI1" + struct.pack("<HH", w, h) + bytes(pal) + bytes(px)
        (ROOT / f"assets/images/{name}.sri").write_bytes(out)
        print(f"assets/images/{name}.sri: {w}x{h}")


if __name__ == "__main__":
    main()
