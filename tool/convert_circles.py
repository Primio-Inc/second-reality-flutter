#!/usr/bin/env python3
"""TECHNO's interference ring bitmaps -> assets/tables/interference.srt

The interference part (TECHNO/KOEA.ASM, KOEB.ASM) draws two concentric-ring
bitmaps that ship as linked OMF objects:

  _CIRCLE.OBK  -> `_circle`  24000 bytes = 200 rows x (3 planes x 40 bytes),
                  ROW-INTERLEAVED (plane0,plane1,plane2 per row -- bltline
                  advances si by 40 per plane, the caller by 40*3 per row).
                  3 bitplanes = the static ring field's 8 shades.
  _CIRCLE2.OBK -> `_circle2` 8000 bytes = 200 rows x 40 bytes, 1 bitplane.
                  The moving 1-bit ring overlay.

Both are a 320x200 QUARTER; init_interference mirrors each 4-way (bltline +
bltlinerev, top half and bottom half) into the 640x400 field the effect scrolls
around.  We store the quarters verbatim and mirror at load time, exactly as the
original does.

Layout of interference.srt:
    "SRI2"
    u8   version (1)
    static  : 24000 bytes  (row-interleaved 3-plane quarter)
    overlay :  8000 bytes  (1-plane quarter)
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_obk import extract_segment_bytes  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "original" / "TECHNO"
OUT = ROOT / "assets" / "tables" / "interference.srt"


def main():
    static, lid1, *_ = extract_segment_bytes(SRC / "_CIRCLE.OBK")
    overlay, lid2, *_ = extract_segment_bytes(SRC / "_CIRCLE2.OBK")

    print(f"_circle : {len(static)} bytes (want 24000), lidata={lid1}")
    print(f"_circle2: {len(overlay)} bytes (want 8000), lidata={lid2}")
    assert not lid1 and not lid2, "unexpected LIDATA"
    assert len(static) == 24000, len(static)
    assert len(overlay) == 8000, len(overlay)

    buf = bytearray(b"SRI2")
    buf.append(1)
    buf += static
    buf += overlay

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(buf)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(buf)} bytes)")


if __name__ == "__main__":
    main()
