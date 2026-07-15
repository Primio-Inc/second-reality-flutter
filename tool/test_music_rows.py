#!/usr/bin/env python3
"""Checks on assets/tables/music_rows.srt v2 (built by extract_music_rows.py).

Run with `python3 -m pytest tool/test_music_rows.py`, or directly as a script
(`python3 tool/test_music_rows.py`) which runs the same checks via plain
asserts in a __main__ block.
"""

import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRT = os.path.join(ROOT, "assets", "tables", "music_rows.srt")

# MUSIC1's row duration at speed 3 / tempo 130: speed / (tempo * 2 / 5).
MUSIC1_ROW_S = 3 / (130 * 2 / 5)

# Segment boundaries in soundtrack time (see extract_music_rows.py).
SEG_B_START = 104.360
SEG_C_START = 473.730


def read_srt(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"SRM2", "bad magic: %r" % data[:4]
    (count,) = struct.unpack_from("<H", data, 4)
    expected_len = 6 + count * 7
    assert len(data) == expected_len, (
        "file size %d does not match header count %d (expected %d)"
        % (len(data), count, expected_len))
    out = []
    off = 6
    for _ in range(count):
        t_ms, order, row, segment = struct.unpack_from("<IBBB", data, off)
        off += 7
        out.append((t_ms, order, row, segment))
    return out


def test_file_exists():
    assert os.path.exists(SRT), (
        "%s missing -- run tool/extract_music_rows.py first" % SRT)


def test_decodes_and_nonempty():
    rows = read_srt(SRT)
    assert len(rows) > 1000, "suspiciously few rows: %d" % len(rows)


def test_strictly_increasing_time():
    rows = read_srt(SRT)
    for i in range(1, len(rows)):
        assert rows[i][0] > rows[i - 1][0], (
            "row times not strictly increasing at index %d: %r -> %r"
            % (i, rows[i - 1], rows[i]))


def test_values_in_range():
    rows = read_srt(SRT)
    for t_ms, order, row, segment in rows:
        assert 0 <= order <= 99, "order %d out of range at t=%dms" % (order, t_ms)
        assert 0 <= row <= 63, "row %d out of range at t=%dms" % (row, t_ms)
        assert segment in (0, 1, 2), "bad segment id %d at t=%dms" % (segment, t_ms)


def test_all_three_segments_present():
    rows = read_srt(SRT)
    segments_seen = set(r[3] for r in rows)
    assert segments_seen == {0, 1, 2}, (
        "expected rows in all 3 segments, got %r" % segments_seen)


def test_music1_row_spacing_near_expected():
    """Consecutive segment-B (MUSIC1) rows should be spaced ~0.0577s apart
    (speed 3, tempo 130), to within a few ms -- catches gross timing
    regressions without being brittle to exact chunk-quantization rounding."""
    rows = read_srt(SRT)
    seg_b = [t_ms for t_ms, order, row, segment in rows if segment == 1]
    assert len(seg_b) > 1000
    deltas_ms = [seg_b[i + 1] - seg_b[i] for i in range(len(seg_b) - 1)]
    # Most rows are a plain single-row step; pattern breaks/jumps produce
    # occasional larger or smaller gaps, so check the median, not every one.
    deltas_ms.sort()
    median_ms = deltas_ms[len(deltas_ms) // 2]
    expected_ms = MUSIC1_ROW_S * 1000.0
    assert abs(median_ms - expected_ms) < 5.0, (
        "segment B median row spacing %.2fms far from expected %.2fms"
        % (median_ms, expected_ms))


def test_segment_boundaries():
    """Segment A rows must end before the MUSIC1 switch, segment B rows must
    fall within [switch, segment C start), and segment C rows must start
    at/after the resume switch."""
    rows = read_srt(SRT)
    seg_a = [t_ms for t_ms, order, row, segment in rows if segment == 0]
    seg_b = [t_ms for t_ms, order, row, segment in rows if segment == 1]
    seg_c = [t_ms for t_ms, order, row, segment in rows if segment == 2]
    assert max(seg_a) < SEG_B_START * 1000, (
        "segment A row at/after the MUSIC1 switch (%dms >= %dms)"
        % (max(seg_a), SEG_B_START * 1000))
    assert min(seg_b) >= SEG_B_START * 1000
    assert max(seg_b) < SEG_C_START * 1000, (
        "segment B row at/after the segment C switch (%dms >= %dms)"
        % (max(seg_b), SEG_C_START * 1000))
    assert min(seg_c) >= SEG_C_START * 1000


ALL_TESTS = [
    test_file_exists,
    test_decodes_and_nonempty,
    test_strictly_increasing_time,
    test_values_in_range,
    test_all_three_segments_present,
    test_music1_row_spacing_near_expected,
    test_segment_boundaries,
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
