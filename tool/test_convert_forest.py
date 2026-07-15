#!/usr/bin/env python3
"""Checks on assets/images/hillback.sri and assets/tables/forest.srt (built by
convert_forest.py) -- round-trips them against the original FOREST/*.DAT /
*.CLX / *.SCI source files.

Run with `python3 -m pytest tool/test_convert_forest.py`, or directly as a
script (`python3 tool/test_convert_forest.py`) which runs the same checks via
plain asserts in a __main__ block.
"""

import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FOREST_SRC = os.path.join(ROOT, "original", "FOREST")
HILLBACK_SRI = os.path.join(ROOT, "assets", "images", "hillback.sri")
FOREST_SRT = os.path.join(ROOT, "assets", "tables", "forest.srt")

CELLS = 237 * 31
STRIP_W, STRIP_H = 640, 31
POS_NAMES = ["POS1.DAT", "POS2.DAT", "POS3.DAT"]


def read_sri(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"SRI1", "bad magic: %r" % data[:4]
    w, h = struct.unpack_from("<HH", data, 4)
    pal = data[8:8 + 768]
    px = data[776:776 + w * h]
    assert len(px) == w * h
    return w, h, pal, px


def read_forest_srt(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"FRS1", "bad magic: %r" % data[:4]
    stripW, stripH = struct.unpack_from("<HH", data, 4)
    off = 8
    strip = data[off:off + stripW * stripH]
    off += stripW * stripH

    tables = []
    for _ in range(3):
        (total,) = struct.unpack_from("<I", data, off)
        off += 4
        counts = struct.unpack_from("<%dH" % CELLS, data, off)
        off += 2 * CELLS
        offsets = struct.unpack_from("<%dH" % total, data, off)
        off += 2 * total
        tables.append((counts, offsets))
    assert off == len(data), (
        "%d trailing bytes after decoding forest.srt" % (len(data) - off))
    return stripW, stripH, strip, tables


def decode_pos_reference(path):
    """Independent re-decode of a POS*.DAT straight from the ASM's own
    layout, used only to verify convert_forest.py's output -- must never
    share code with convert_forest.decode_pos_table()."""
    with open(path, "rb") as f:
        data = f.read()
    n = len(data)
    off = 0
    counts = []
    offsets = []
    for cell in range(CELLS):
        (cnt,) = struct.unpack_from("<H", data, off)
        off += 2
        counts.append(cnt)
        for _ in range(cnt):
            (d,) = struct.unpack_from("<H", data, off)
            off += 2
            offsets.append(d)
    assert off == n, "%s: %d trailing bytes" % (path, n - off)
    return counts, offsets


def test_files_exist():
    assert os.path.exists(HILLBACK_SRI), (
        "%s missing -- run tool/convert_forest.py first" % HILLBACK_SRI)
    assert os.path.exists(FOREST_SRT), (
        "%s missing -- run tool/convert_forest.py first" % FOREST_SRT)


def test_hillback_matches_source():
    src = open(os.path.join(FOREST_SRC, "HILLBACK.CLX"), "rb").read()
    assert len(src) == 64778
    w, h, pal, px = read_sri(HILLBACK_SRI)
    assert (w, h) == (320, 200)
    assert pal == src[10:778], "palette does not match HILLBACK.CLX offset 10"
    assert px == src[778:778 + 64000], (
        "pixels do not match HILLBACK.CLX offset 778")
    assert max(pal) <= 63, "palette not 6-bit"


def test_strip_matches_source_with_128_rule():
    src = open(os.path.join(FOREST_SRC, "O2.SCI"), "rb").read()
    assert len(src) - 778 == 640 * 32
    _, _, strip, _ = read_forest_srt(FOREST_SRT)
    assert len(strip) == STRIP_W * STRIP_H
    for row in range(STRIP_H):
        src_off = 778 + row * 640
        raw_row = src[src_off:src_off + STRIP_W]
        got_row = strip[row * STRIP_W:(row + 1) * STRIP_W]
        for x in range(STRIP_W):
            expected = raw_row[x] + 128 if raw_row[x] > 0 else raw_row[x]
            assert got_row[x] == expected, (
                "strip mismatch at row %d col %d: got %d want %d"
                % (row, x, got_row[x], expected))


def test_pos_tables_roundtrip_exactly():
    _, _, _, tables = read_forest_srt(FOREST_SRT)
    for name, (counts, offsets) in zip(POS_NAMES, tables):
        ref_counts, ref_offsets = decode_pos_reference(
            os.path.join(FOREST_SRC, name))
        assert len(counts) == CELLS == len(ref_counts)
        assert list(counts) == ref_counts, "%s: counts differ" % name
        assert list(offsets) == ref_offsets, "%s: offsets differ" % name


def test_pos_offsets_in_range_and_counts_consistent():
    _, _, _, tables = read_forest_srt(FOREST_SRT)
    for name, (counts, offsets) in zip(POS_NAMES, tables):
        assert sum(counts) == len(offsets), (
            "%s: sum(counts)=%d != len(offsets)=%d"
            % (name, sum(counts), len(offsets)))
        assert all(0 <= d <= 63999 for d in offsets), (
            "%s: an offset is out of 0..63999" % name)


ALL_TESTS = [
    test_files_exist,
    test_hillback_matches_source,
    test_strip_matches_source_with_128_rule,
    test_pos_tables_roundtrip_exactly,
    test_pos_offsets_in_range_and_counts_consistent,
]


if __name__ == "__main__":
    failures = 0
    for t in ALL_TESTS:
        try:
            t()
            print("PASS %s" % t.__name__)
        except AssertionError as e:
            failures += 1
            print("FAIL %s: %s" % (t.__name__, e))
    if failures:
        print("%d/%d tests failed" % (failures, len(ALL_TESTS)))
        sys.exit(1)
    print("all %d tests passed" % len(ALL_TESTS))
