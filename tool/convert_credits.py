#!/usr/bin/env python3
"""Convert the CREDITS part's 21 thumbnails into one `credits.srt` table.

Source: original/CREDITS/PICS/PIC*.LBM — one 160x100 ILBM per credit screen, in
the order CREDITS/MAIN.C names them (pic1..pic18, with the 'b' variants):

    PIC01 PIC02 PIC03 PIC04 PIC05 PIC05B PIC06 PIC07 PIC08 PIC09 PIC10
    PIC10B PIC11 PIC12 PIC13 PIC14 PIC14B PIC15 PIC16 PIC17 PIC18

MAIN.C's init() rewrites each palette before anything is drawn:

    memmove(&pic[16*3+16], &pic[16], 768-16*3);   // entries 0..239 -> 16..255
    for(a=0;a<10;a++) pic[a*3+...+16] = 7*a;      // entries 0..9 = a grey ramp

and screenin() then draws the picture with `+16` on every pixel. The shift frees
the bottom of the DAC for the FONA text (which is drawn with shade values 0..9),
and it is what makes index 0 BLACK — which is the colour of everything around the
picture on screen. We do that shift here, in the asset, so the part can blit the
picture straight out of the table: the port draws its text with a modern vector
font (see the porting notes), so the grey ramp is only ever the background black.

Format (little-endian):
    "SRC1"
    u8   count
    per screen:
      768 bytes  6-bit VGA palette (already shifted, with the grey ramp)
      16000 bytes  160x100 indices (already +16)

Usage: python3 tool/convert_credits.py
"""
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from extract_font import decode_lbm  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
PICS = ROOT / "original/CREDITS/PICS"
OUT = ROOT / "assets/tables/credits.srt"

# The order CREDITS/MAIN.C calls screenin() in.
ORDER = [
    "PIC01", "PIC02", "PIC03", "PIC04", "PIC05", "PIC05B", "PIC06", "PIC07",
    "PIC08", "PIC09", "PIC10", "PIC10B", "PIC11", "PIC12", "PIC13", "PIC14",
    "PIC14B", "PIC15", "PIC16", "PIC17", "PIC18",
]

W, H = 160, 100


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
    out = bytearray(b"SRC1")
    out += struct.pack("<B", len(ORDER))
    for name in ORDER:
        data = (PICS / f"{name}.LBM").read_bytes()
        w, h, px = decode_lbm(data)
        if (w, h) != (W, H):
            raise SystemExit(f"{name}: expected {W}x{H}, got {w}x{h}")
        cmap = read_cmap(data)

        pal = bytearray(768)
        for i in range(min(len(cmap), 768)):
            pal[i] = cmap[i] >> 2  # 8-bit CMAP -> 6-bit VGA DAC

        # init(): shift entries 0..239 up to 16..255, then lay a 10-step grey
        # ramp into 0..9. (Entries 10..15 keep whatever was there — the original
        # leaves them alone too, and nothing ever indexes them.)
        shifted = bytearray(768)
        shifted[48:768] = pal[0:768 - 48]
        for a in range(10):
            shifted[a * 3 + 0] = shifted[a * 3 + 1] = shifted[a * 3 + 2] = 7 * a

        out += bytes(shifted)
        out += bytes((p + 16) & 0xFF for p in px)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(bytes(out))
    print(f"{OUT}: {len(ORDER)} screens, {len(out)} bytes")


if __name__ == "__main__":
    main()
