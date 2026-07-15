#!/usr/bin/env python3
"""Parse 1993 Borland/TASM OMF .OBK object files (_CIRCLE.OBK / _CIRCLE2.OBK)
and reconstruct the raw segment bytes they define (_circle / _circle2 --
circular mask bitmaps used by the techno part).

OMF record framing: 1 byte record type, 2 bytes little-endian length L,
then (L-1) bytes of content, then 1 checksum byte (total record size = 3+L).

Handles the record types actually seen in these files:
  0x80        THEADR
  0x88        COMENT
  0x96        LNAMES
  0x98        SEGDEF
  0x90/0x91   PUBDEF
  0xA0/0xA1   LEDATA  (enumerated data)
  0xA2/0xA3   LIDATA  (iterated data) -- reported if present, not expected
  0x8A/0x8B   MODEND

LEDATA content: 1 byte segment index, 2 bytes little-endian data offset,
then raw data bytes (content length - 3 of them; the trailing checksum byte
is part of the record framing, not the data).

Usage: extract_obk.py <file.obk> [-o out.bin]
"""
import argparse
import struct
import sys
from pathlib import Path

RECNAMES = {
    0x80: "THEADR", 0x88: "COMENT", 0x96: "LNAMES", 0x98: "SEGDEF",
    0x90: "PUBDEF16", 0x91: "PUBDEF32",
    0xA0: "LEDATA16", 0xA1: "LEDATA32",
    0xA2: "LIDATA16", 0xA3: "LIDATA32",
    0x8A: "MODEND16", 0x8B: "MODEND32",
    0x9A: "GRPDEF", 0x9C: "FIXUPP16", 0x9D: "FIXUPP32",
    0x94: "LINNUM16", 0x95: "LINNUM32",
    0xB6: "LEXTDEF16", 0xB7: "LEXTDEF32",
    0xB4: "COMDEF",
}


def parse_records(data):
    """Yield (rectype, content_bytes) for every record in an OMF stream."""
    o = 0
    n = len(data)
    while o < n:
        if o + 3 > n:
            raise ValueError(f"truncated record header at offset {o}")
        rectype = data[o]
        reclen = struct.unpack_from("<H", data, o + 1)[0]
        start = o + 3
        end = start + reclen  # includes trailing checksum byte
        if end > n:
            raise ValueError(f"record at {o} (type {rectype:#x}) overruns "
                              f"file: end={end} filelen={n}")
        content = data[start:end - 1]  # strip checksum byte
        yield rectype, content
        o = end


def extract_segment_bytes(path):
    """Reconstruct the concatenated segment data from LEDATA/LIDATA records.

    Returns (bytes, used_lidata: bool, pieces: list of (offset, length)).
    """
    data = Path(path).read_bytes()
    pieces = []  # (offset, bytes)
    used_lidata = False
    public_names = []

    for rectype, content in parse_records(data):
        base = rectype & ~1  # 16/32-bit variants share handling below
        if rectype in (0xA0, 0xA1):  # LEDATA
            seg_index = content[0]
            if rectype == 0xA0:
                offset = struct.unpack_from("<H", content, 1)[0]
                payload = content[3:]
            else:
                offset = struct.unpack_from("<I", content, 1)[0]
                payload = content[5:]
            pieces.append((offset, payload))
        elif rectype in (0xA2, 0xA3):  # LIDATA -- iterated data, report only
            used_lidata = True
            pieces.append(("LIDATA", content))
        elif rectype in (0x90, 0x91):  # PUBDEF: record public symbol names
            body = content
            # PUBDEF: base group idx(1 or idx), base seg idx(1 or idx), [frame if idx0]
            # Simplify: just scan for length-prefixed name strings heuristically
            i = 0
            # group index (idx field: 1 byte if <=0x7f else 2 bytes with hi bit)
            def read_index(buf, i):
                b0 = buf[i]
                if b0 & 0x80:
                    return ((b0 & 0x7f) << 8 | buf[i + 1]), i + 2
                return b0, i + 1
            grp, i = read_index(body, i)
            seg, i = read_index(body, i)
            if seg == 0:
                i += 2  # frame number
            while i < len(body):
                namelen = body[i]
                i += 1
                if namelen == 0:
                    break
                name = body[i:i + namelen].decode('ascii', 'replace')
                i += namelen
                if rectype == 0x90:
                    off = struct.unpack_from("<H", body, i)[0]
                    i += 2
                else:
                    off = struct.unpack_from("<I", body, i)[0]
                    i += 4
                i += 1  # type index
                public_names.append((name, off))

    # Concatenate LEDATA pieces in order of their data offsets.
    numeric_pieces = [(off, buf) for off, buf in pieces if isinstance(off, int)]
    numeric_pieces.sort(key=lambda p: p[0])

    total_len = 0
    for off, buf in numeric_pieces:
        total_len = max(total_len, off + len(buf))

    out = bytearray(total_len)
    for off, buf in numeric_pieces:
        out[off:off + len(buf)] = buf

    return bytes(out), used_lidata, numeric_pieces, public_names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("obk", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None)
    args = ap.parse_args()

    out_bytes, used_lidata, pieces, publics = extract_segment_bytes(args.obk)

    print(f"{args.obk}: recovered {len(out_bytes)} bytes from "
          f"{len(pieces)} LEDATA record(s)")
    print(f"  LIDATA used: {used_lidata}")
    print(f"  PUBDEF symbols: {publics}")
    # sanity: check offsets are contiguous, no gaps/overlaps
    prev_end = 0
    gaps = []
    for off, buf in pieces:
        if off != prev_end:
            gaps.append((prev_end, off))
        prev_end = off + len(buf)
    if gaps:
        print(f"  WARNING: gaps/overlaps in LEDATA offsets: {gaps}")
    else:
        print(f"  LEDATA offsets are contiguous 0..{prev_end}")

    if args.out:
        args.out.write_bytes(out_bytes)
        print(f"  wrote {args.out} ({len(out_bytes)} bytes)")


if __name__ == "__main__":
    main()
