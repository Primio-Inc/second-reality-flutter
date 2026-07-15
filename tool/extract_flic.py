#!/usr/bin/env python3
"""Decode an Autodesk FLIC animation (.FLI / .FLC) into the .sfl asset the
Flutter port plays. Used for the intro Praxis explosion (PAM/PRAX4.FLI).

Chunk handling follows the FLIC spec and the original PAM/VFLI.C reader:
frame chunks 0xF1FA contain sub-chunks 4 (COLOR_256), 11 (COLOR_64, 6-bit),
12 (DELTA_FLI line-compressed), 13 (BLACK), 15 (BYTE_RUN), 16 (COPY).

.sfl format (little-endian): "SFL1" | u16 w | u16 h | u16 frameCount |
  per frame: 768-byte 6-bit VGA palette + w*h index bytes (full frame).

Usage: python3 tool/extract_flic.py <in.fli> <out.sfl> [--preview dir]
"""
import struct
import subprocess
import sys
from pathlib import Path


def decode_flic(data):
    size, magic, frames, w, h = struct.unpack_from("<IHHHH", data, 0)
    assert magic in (0xAF11, 0xAF12), f"not a FLIC (magic 0x{magic:04x})"
    pix = bytearray(w * h)          # persistent canvas (frames are deltas)
    pal = bytearray(768)            # 6-bit VGA palette, persistent
    out_frames = []
    o = 128                         # frame data starts after the 128-byte header

    def read_color(o, eight_bit):
        npkts = struct.unpack_from("<H", data, o)[0]
        o += 2
        idx = 0
        for _ in range(npkts):
            skip = data[o]
            count = data[o + 1]
            o += 2
            if count == 0:
                count = 256
            idx += skip
            for _ in range(count):
                r, g, b = data[o], data[o + 1], data[o + 2]
                o += 3
                if eight_bit:
                    r, g, b = r >> 2, g >> 2, b >> 2
                pal[idx * 3] = r
                pal[idx * 3 + 1] = g
                pal[idx * 3 + 2] = b
                idx += 1
        return o

    def read_delta_fli(o):
        first = struct.unpack_from("<H", data, o)[0]
        nlines = struct.unpack_from("<H", data, o + 2)[0]
        o += 4
        for ln in range(first, first + nlines):
            npkts = data[o]
            o += 1
            col = ln * w
            for _ in range(npkts):
                skip = data[o]
                sz = struct.unpack_from("b", data, o + 1)[0]
                o += 2
                col += skip
                if sz >= 0:
                    pix[col:col + sz] = data[o:o + sz]
                    o += sz
                    col += sz
                else:
                    b = data[o]
                    o += 1
                    for _ in range(-sz):
                        pix[col] = b
                        col += 1
        return o

    def read_brun(o):
        for ln in range(h):
            o += 1  # per-line packet count (ignored per spec)
            col = ln * w
            while col < (ln + 1) * w:
                cnt = struct.unpack_from("b", data, o)[0]
                o += 1
                if cnt >= 0:
                    b = data[o]
                    o += 1
                    for _ in range(cnt):
                        pix[col] = b
                        col += 1
                else:
                    n = -cnt
                    pix[col:col + n] = data[o:o + n]
                    o += n
                    col += n
        return o

    for _ in range(frames):
        fsize, ftype = struct.unpack_from("<IH", data, o)
        fstart = o
        if ftype != 0xF1FA:
            o = fstart + fsize
            continue
        nsub = struct.unpack_from("<H", data, o + 6)[0]
        p = o + 16  # frame header is 16 bytes
        for _ in range(nsub):
            csize, ctype = struct.unpack_from("<IH", data, p)
            body = p + 6
            if ctype == 11:
                read_color(body, False)
            elif ctype == 4:
                read_color(body, True)
            elif ctype == 12:
                read_delta_fli(body)
            elif ctype == 15:
                read_brun(body)
            elif ctype == 16:
                pix[:] = data[body:body + w * h]
            elif ctype == 13:
                for i in range(w * h):
                    pix[i] = 0
            p += csize
        out_frames.append((bytes(pal), bytes(pix)))
        o = fstart + fsize

    return w, h, out_frames


def encode_sfl(w, h, frames):
    out = bytearray(b"SFL1")
    out += struct.pack("<HHH", w, h, len(frames))
    for pal, pix in frames:
        out += pal
        out += pix
    return bytes(out)


def preview(w, h, frames, outdir):
    Path(outdir).mkdir(parents=True, exist_ok=True)
    for i in (0, len(frames) // 4, len(frames) // 2, 3 * len(frames) // 4,
              len(frames) - 1):
        pal, pix = frames[i]
        ppm = bytearray(f"P6\n{w} {h}\n255\n".encode())
        for p in pix:
            r, g, b = pal[p * 3], pal[p * 3 + 1], pal[p * 3 + 2]
            ppm += bytes(((r << 2) | (r >> 4), (g << 2) | (g >> 4),
                          (b << 2) | (b >> 4)))
        Path(f"{outdir}/_f.ppm").write_bytes(ppm)
        subprocess.run(["sips", "-s", "format", "png", f"{outdir}/_f.ppm",
                        "--out", f"{outdir}/frame{i:02d}.png"],
                       capture_output=True)
        print(f"{outdir}/frame{i:02d}.png")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    w, h, frames = decode_flic(Path(src).read_bytes())
    Path(dst).write_bytes(encode_sfl(w, h, frames))
    print(f"{dst}: {w}x{h}, {len(frames)} frames")
    if "--preview" in sys.argv:
        preview(w, h, frames, sys.argv[sys.argv.index("--preview") + 1])


if __name__ == "__main__":
    main()
