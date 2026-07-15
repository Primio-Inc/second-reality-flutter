#!/usr/bin/env python3
"""Build the demo's music ROW clock (v2) via libopenmpt, from the INTACT
reference modules -- not the vendored (corrupt) original/MAIN/*.S3M.

The original's sync is on the tracker's row counter: `dis_musrow()` returns
the current pattern row, and DIS's part-trigger table `ordersync1`
(original/DIS/DISINT.ASM) keys off (order, row) pairs, packed as a
0xOORR word, scanned by `sync_10` -- that IS `dis_sync()`. To replay those
triggers we need the wall-clock start time of every (order, row) MUSIC0
visits, in the continuous soundtrack's timebase -- not just MUSIC0's intro
run, but also its second pass (the demo RESUMES MUSIC0 for the ending, at
orders 61-66).

v1 of this table (`music_rows.srt`, format "SRMR") only covered MUSIC0's
first 104.36s and dropped the order number entirely. v2 ("SRM2") covers all
three soundtrack segments and records the order:

    segment A: soundtrack [0.090, 103.600)   = MUSIC0 module [0, 103.510)
    segment B: soundtrack [103.600, 472.970) = MUSIC1 module [0, 369.370)
    segment C: soundtrack [473.730, end)     = MUSIC0 module resumed at
               module time ~134.800 (soundtrack = module + 338.930)

(Segment boundaries/offsets are measured by cross-correlation against
reference/soundtrack_events.json -- see reference/music/README.md. Segment C's
exact resume point is snapped to a real MUSIC0 order boundary near module
time 134.800s; see snap_segment_c_resume() and the printed candidates.)

Rather than re-derive the S3M speed/tempo/order-jump logic by hand, this
script uses libopenmpt itself as ground truth: step playback in small chunks
and watch (order, pattern, row) change. The chunk at which a new row first
appears IS that row's start time -- this captures every timing effect (Axx
speed, Txx tempo, Bxx/Cxx order jumps/breaks, pattern loops) for free, exactly
as libopenmpt's own player would apply them.

Output: assets/tables/music_rows.srt, little-endian:

    "SRM2"                magic, 4 bytes
    u16 count              total rows across all 3 segments, time-sorted
    then `count` records of:
        u32 t_ms            row start time in soundtrack milliseconds
        u8  order            tracker order index
        u8  row               row index within its pattern (0..63)
        u8  segment            0 = A (MUSIC0 intro), 1 = B (MUSIC1),
                                 2 = C (MUSIC0 resumed for the ending)

Also prints (stdout only, not persisted) the dis_sync CUE TABLE: for every
`ordersync1` entry, the soundtrack time of that (order, row) in MUSIC0 --
covering both the intro group (segment A) and the end group (orders 61-66,
segment C). These are the demo's exact part triggers, to be wired into
lib/demo_script.dart by hand.
"""

import bisect
import ctypes
import ctypes.util
import json
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MUSIC0 = os.path.join(ROOT, "reference", "music", "music0.s3m")
MUSIC1 = os.path.join(ROOT, "reference", "music", "music1.s3m")
OUT = os.path.join(ROOT, "assets", "tables", "music_rows.srt")

LIBOPENMPT_PATH = "/opt/homebrew/lib/libopenmpt.0.dylib"

# Measured by cross-correlation against reference/soundtrack_events.json (see
# reference/music/README.md).
SEG_A_OFFSET = 0.090       # MUSIC0 module t=0 -> soundtrack t
SEG_B_OFFSET = 109.750     # MUSIC1 module t=0 -> soundtrack t.
                           # NOT the explosion. MUSIC0 does not stop at the
                           # boom -- its own crash IS the boom (which is why it
                           # coincides with dis_sync cue 10 / order 13). MUSIC0
                           # plays on to ~108, the demo then goes SILENT while
                           # the title loads, and MUSIC1 starts at capture
                           # 109.55 = soundtrack 109.750 (cross-correlating
                           # MUSIC1's own render against the capture, r=0.93).
                           # Cutting MUSIC1 in at the boom played it 5.66s
                           # EARLY and left every later part looking that late.
SEG_A_END = 107.960        # MUSIC0 module time at which segment A ends (excl)
SEG_B_START = 0.0          # MUSIC1 module time at which segment B begins
SEG_B_END = 369.370        # MUSIC1 module time at which segment B ends (excl)
SEG_C_SOUNDTRACK_START = 479.120   # nominal; refined by the order-snap below
SEG_C_MODULE_TARGET = 140.417      # nominal MUSIC0 module time to resume at
                                   # (134.800 measured at tempo 125, rescaled
                                   # x125/120 to the STMIK-effective tempo)

# THE STMIK TEMPO QUIRK. MUSIC0's S3M header says initial tempo 125, and
# libopenmpt honours it -- but the original demo's player (STMIK 0.9) plays
# the module at effective tempo 120. Proven by chroma (melody) alignment of
# our render against the capture's own audio: at header tempo the lag GROWS
# linearly (-0.3s @14s .. -3.8s @102s = 4% fast, exactly 125/120); with the
# header patched to 120 the lag is flat (~+0.2s constant, r up to 0.95).
# Cross-check: the credit-card fades measured off the capture (16.07/24.04/
# 30.19s) match the tempo-120 row clock's cue times, not tempo-125's
# (15.45/23.13/28.77). MUSIC1's header tempo IS correct (the techno beat grid
# matched the capture to ~0.1%), so only MUSIC0 gets the patch.
STMIK_MUSIC0_TEMPO = 120
S3M_TEMPO_OFFSET = 0x32

SAMPLERATE = 48000
CHUNK_FRAMES = 64  # ~1.333ms of resolution at 48kHz -- plenty fine vs a ~58ms row

# original/DIS/DISINT.ASM `ordersync1`: dw <order:row packed 0xOORR>, <part>.
# Intro group runs within segment A (MUSIC0's first pass); the last four
# entries (orders 61/63/65/66) are the second pass, in segment C.
ORDERSYNC1 = [
    (0x00, 0x00, 0),
    (0x02, 0x00, 1),
    (0x03, 0x00, 2),
    (0x03, 0x2f, 3),
    (0x04, 0x2f, 4),
    (0x05, 0x2f, 5),
    (0x06, 0x2f, 6),
    (0x07, 0x2f, 7),
    (0x08, 0x2f, 8),
    (0x09, 0x00, 9),
    (0x0d, 0x00, 10),
    (0x3d, 0x00, 1),
    (0x3f, 0x00, 2),
    (0x41, 0x00, 3),
    (0x42, 0x00, 4),
]


def load_openmpt():
    lib = ctypes.CDLL(LIBOPENMPT_PATH)

    lib.openmpt_module_create_from_memory2.restype = ctypes.c_void_p
    lib.openmpt_module_create_from_memory2.argtypes = [
        ctypes.c_void_p, ctypes.c_size_t,  # filedata, filesize
        ctypes.c_void_p, ctypes.c_void_p,  # logfunc, loguser
        ctypes.c_void_p, ctypes.c_void_p,  # errfunc, erruser
        ctypes.c_void_p, ctypes.c_void_p,  # error, error_message
        ctypes.c_void_p,                   # ctls
    ]

    lib.openmpt_module_destroy.restype = None
    lib.openmpt_module_destroy.argtypes = [ctypes.c_void_p]

    lib.openmpt_module_read_float_stereo.restype = ctypes.c_size_t
    lib.openmpt_module_read_float_stereo.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_float), ctypes.POINTER(ctypes.c_float),
    ]

    lib.openmpt_module_get_current_order.restype = ctypes.c_int32
    lib.openmpt_module_get_current_order.argtypes = [ctypes.c_void_p]
    lib.openmpt_module_get_current_pattern.restype = ctypes.c_int32
    lib.openmpt_module_get_current_pattern.argtypes = [ctypes.c_void_p]
    lib.openmpt_module_get_current_row.restype = ctypes.c_int32
    lib.openmpt_module_get_current_row.argtypes = [ctypes.c_void_p]

    lib.openmpt_module_get_duration_seconds.restype = ctypes.c_double
    lib.openmpt_module_get_duration_seconds.argtypes = [ctypes.c_void_p]

    lib.openmpt_module_get_num_orders.restype = ctypes.c_int32
    lib.openmpt_module_get_num_orders.argtypes = [ctypes.c_void_p]

    lib.openmpt_module_set_position_order_row.restype = ctypes.c_double
    lib.openmpt_module_set_position_order_row.argtypes = [
        ctypes.c_void_p, ctypes.c_int32, ctypes.c_int32]
    lib.openmpt_module_is_order_skip_entry.restype = ctypes.c_int32
    lib.openmpt_module_is_order_skip_entry.argtypes = [ctypes.c_void_p, ctypes.c_int32]
    lib.openmpt_module_is_order_stop_entry.restype = ctypes.c_int32
    lib.openmpt_module_is_order_stop_entry.argtypes = [ctypes.c_void_p, ctypes.c_int32]

    return lib


def open_module(lib, path):
    data = open(path, "rb").read()
    if os.path.abspath(path) == os.path.abspath(MUSIC0):
        # Apply the STMIK tempo quirk (see STMIK_MUSIC0_TEMPO above).
        data = bytearray(data)
        assert data[S3M_TEMPO_OFFSET] in (125, STMIK_MUSIC0_TEMPO)
        data[S3M_TEMPO_OFFSET] = STMIK_MUSIC0_TEMPO
        data = bytes(data)
    buf = ctypes.create_string_buffer(data, len(data))
    mod = lib.openmpt_module_create_from_memory2(
        ctypes.cast(buf, ctypes.c_void_p), len(data),
        None, None, None, None, None, None, None,
    )
    if not mod:
        raise SystemExit("failed to load %s" % path)
    return mod


def extract_rows(lib, path):
    """Step the module in small chunks; record the time of the first chunk
    at which each new (order, row) pair is observed. Returns a list of
    dicts {t, order, pattern, row} in playback order, deduped consecutive
    repeats collapsed to their first occurrence."""
    mod = open_module(lib, path)
    duration = lib.openmpt_module_get_duration_seconds(mod)

    left = (ctypes.c_float * CHUNK_FRAMES)()
    right = (ctypes.c_float * CHUNK_FRAMES)()

    rows = []
    last_key = None
    t = 0.0
    while True:
        n = lib.openmpt_module_read_float_stereo(
            mod, SAMPLERATE, CHUNK_FRAMES, left, right)
        order = lib.openmpt_module_get_current_order(mod)
        pattern = lib.openmpt_module_get_current_pattern(mod)
        row = lib.openmpt_module_get_current_row(mod)
        key = (order, pattern, row)
        if key != last_key:
            rows.append({"t": t, "order": order, "pattern": pattern, "row": row})
            last_key = key
        t += n / SAMPLERATE
        if n == 0:
            break

    lib.openmpt_module_destroy(mod)
    return rows, duration


def extract_rows_linear(lib, path):
    """Like extract_rows, but forces SEQUENTIAL visitation of every order in
    the module's order list (0..num_orders-1), ignoring any in-pattern
    position-jump/pattern-break effect that would otherwise redirect
    playback elsewhere.

    MUSIC0 has exactly this case: order 62 (pattern 69)'s last row carries a
    jump back to order 33, an unconditional loop-back -- confirmed by
    watching plain playback run order 0->62 then jump to 33 and immediately
    hit libopenmpt's loop-detection stop (verified empirically: a plain
    extract_rows() run never sees orders 63/65/66, which the demo's DISINT.ASM
    ordersync1 table needs for its end-of-demo part triggers). That loop-back
    is presumably a jukebox/background-loop convenience for standalone module
    playback, not something the real demo (which resumes MUSIC0 for a *finite*
    ending) plays through -- so we linearize past it: each order is entered
    via an explicit seek (bypassing wherever the previous order's effects
    would have sent playback), and captured until ITS OWN current-order value
    changes (whether by falling off the end of the pattern or an internal
    jump), at which point we discard the destination and move on to the next
    order in sequence. Within an order, internal effects (speed/tempo
    changes, early pattern breaks) are still captured faithfully -- only the
    cross-order destination is overridden.

    Returns (rows, total_seconds) with cumulative time reconstructed by
    summing each order's own local duration."""
    mod = open_module(lib, path)
    n_orders = lib.openmpt_module_get_num_orders(mod)

    left = (ctypes.c_float * CHUNK_FRAMES)()
    right = (ctypes.c_float * CHUNK_FRAMES)()

    rows = []
    global_t = 0.0
    for order_idx in range(n_orders):
        if lib.openmpt_module_is_order_skip_entry(mod, order_idx):
            continue
        if lib.openmpt_module_is_order_stop_entry(mod, order_idx):
            break
        lib.openmpt_module_set_position_order_row(mod, order_idx, 0)

        local_t = 0.0
        last_row = None
        while True:
            n = lib.openmpt_module_read_float_stereo(
                mod, SAMPLERATE, CHUNK_FRAMES, left, right)
            if n == 0:
                break
            cur_order = lib.openmpt_module_get_current_order(mod)
            if cur_order != order_idx:
                break  # left this order (natural advance or internal jump)
            row = lib.openmpt_module_get_current_row(mod)
            if row != last_row:
                rows.append({"t": global_t + local_t, "order": order_idx, "row": row})
                last_row = row
            local_t += n / SAMPLERATE
        global_t += local_t

    lib.openmpt_module_destroy(mod)
    return rows, global_t


def snap_segment_c_resume(rows0):
    """MUSIC0's order-start times (row==0 first occurrence per order), used
    to pick the real resume point nearest SEG_C_MODULE_TARGET. Prints the
    candidates in [120, 150]s and returns (order, t_module) of the chosen
    resume row (which need not be a row-0 boundary if none is close enough)."""
    order_starts = {}
    for e in rows0:
        if e["order"] not in order_starts:
            order_starts[e["order"]] = e["t"]

    print()
    print("=== MUSIC0 order starts in [120s, 150s] (segment C resume search) ===")
    candidates = sorted(
        (t, o) for o, t in order_starts.items() if 120.0 <= t <= 150.0)
    for t, o in candidates:
        print("  order %3d starts at module t=%.3fs (delta from target %.3f = %+.3fs)"
              % (o, t, SEG_C_MODULE_TARGET, t - SEG_C_MODULE_TARGET))

    # Nearest order-start row (row 0) to the target.
    if candidates:
        best_t, best_o = min(candidates, key=lambda p: abs(p[0] - SEG_C_MODULE_TARGET))
    else:
        best_t, best_o = None, None

    # Also find the literal nearest ROW (any row, not just order starts), for
    # comparison / fallback.
    nearest_row = min(rows0, key=lambda e: abs(e["t"] - SEG_C_MODULE_TARGET))

    print("nearest MUSIC0 order-start to target: order %d at t=%.3fs (delta %+.3fs)"
          % (best_o, best_t, best_t - SEG_C_MODULE_TARGET) if best_o is not None
          else "no order-start candidate found in window")
    print("nearest MUSIC0 row (any) to target: order=%d row=%d at t=%.3fs (delta %+.3fs)"
          % (nearest_row["order"], nearest_row["row"], nearest_row["t"],
             nearest_row["t"] - SEG_C_MODULE_TARGET))

    if best_o is not None and abs(best_t - SEG_C_MODULE_TARGET) <= 0.5:
        print("-> snapping segment C resume to order %d, row 0, module t=%.3fs "
              "(within 0.5s of target, using order boundary)" % (best_o, best_t))
        return best_o, 0, best_t
    else:
        e = nearest_row
        print("-> no order boundary within 0.5s; snapping to nearest row: "
              "order %d row %d, module t=%.3fs" % (e["order"], e["row"], e["t"]))
        return e["order"], e["row"], e["t"]


def build_table():
    lib = load_openmpt()

    rows0, dur0 = extract_rows_linear(lib, MUSIC0)
    rows1, dur1 = extract_rows(lib, MUSIC1)
    print("MUSIC0 (linearized, bypassing the order62->33 loop-back): %d rows, "
          "reconstructed duration %.3fs, last row observed at %.3fs"
          % (len(rows0), dur0, rows0[-1]["t"]))
    print("MUSIC1: %d rows, libopenmpt duration %.3fs, last row observed at %.3fs"
          % (len(rows1), dur1, rows1[-1]["t"]))

    resume_order, resume_row, resume_t = snap_segment_c_resume(rows0)
    seg_c_offset = SEG_C_SOUNDTRACK_START - resume_t  # module t -> soundtrack t
    seg_c_soundtrack_start = resume_t + seg_c_offset
    print()
    print("=== segment C resume chosen ===")
    print("  MUSIC0 order=%d row=%d, module t=%.3fs" % (resume_order, resume_row, resume_t))
    print("  soundtrack switch time adjusted to %.3fs (offset module->soundtrack = %+.3fs)"
          % (seg_c_soundtrack_start, seg_c_offset))

    merged = []  # (t_soundtrack, order, row, segment)
    counts = {0: 0, 1: 0, 2: 0}
    dropped = {"A": 0, "B": 0, "C": 0}

    for e in rows0:
        if e["t"] >= SEG_A_END:
            dropped["A"] += 1
            continue
        st = e["t"] + SEG_A_OFFSET
        merged.append((st, e["order"] & 0xFF, e["row"] & 0xFF, 0))
        counts[0] += 1

    for e in rows1:
        if e["t"] < SEG_B_START or e["t"] >= SEG_B_END:
            dropped["B"] += 1
            continue
        st = e["t"] + SEG_B_OFFSET
        merged.append((st, e["order"] & 0xFF, e["row"] & 0xFF, 1))
        counts[1] += 1

    for e in rows0:
        if e["t"] < resume_t:
            dropped["C"] += 1
            continue
        st = e["t"] + seg_c_offset
        merged.append((st, e["order"] & 0xFF, e["row"] & 0xFF, 2))
        counts[2] += 1

    merged.sort(key=lambda r: r[0])
    print()
    print("segment A (MUSIC0 intro): %d rows (dropped %d at/after module t=%.3fs)"
          % (counts[0], dropped["A"], SEG_A_END))
    print("segment B (MUSIC1): %d rows (dropped %d at/after module t=%.3fs)"
          % (counts[1], dropped["B"], SEG_B_END))
    print("segment C (MUSIC0 resumed): %d rows (dropped %d before module t=%.3fs)"
          % (counts[2], dropped["C"], resume_t))

    return merged, rows0, resume_order, resume_row, resume_t, seg_c_offset


def print_cue_table(rows0, seg_c_offset, resume_t):
    """Print the dis_sync cue table: for each ordersync1 entry, find the
    soundtrack time of that (order, row) in MUSIC0, for both the intro pass
    (segment A) and the end pass (segment C, orders 61-66)."""
    # Build (order, row) -> first module-time-of-order-and-exact-row lookup.
    # sync_10 does `dx <= table[bx]`, i.e. it finds the first ordersync1 entry
    # whose (order,row) is >= current position -- so the *trigger* fires the
    # first time playback reaches that exact (order,row) or, if that row is
    # skipped, the next position >= it within non-decreasing (order,row).
    # For our purposes (deriving the wall-clock trigger time) we want the
    # first observed row whose packed (order<<8|row) >= the target.
    def packed(order, row):
        return (order << 8) | row

    events_by_packed = sorted(
        ((packed(e["order"], e["row"]), e["t"]) for e in rows0),
        key=lambda p: p[0])
    packed_keys = [p[0] for p in events_by_packed]

    def first_time_at_or_after(target_packed):
        i = bisect.bisect_left(packed_keys, target_packed)
        if i >= len(packed_keys):
            return None
        return events_by_packed[i][1]

    print()
    print("=== dis_sync CUE TABLE (ordersync1, soundtrack time) ===")
    print("%-6s %-6s %-5s %-5s %-10s %-8s" % ("sync#", "part", "order", "row", "module_t", "soundtrack_t"))
    for i, (order, row, part) in enumerate(ORDERSYNC1):
        target = packed(order, row)
        mt = first_time_at_or_after(target)
        if mt is None:
            print("%-6d %-6d 0x%02x   0x%02x  %-10s %-8s (not found in MUSIC0 playthrough)"
                  % (i, part, order, row, "-", "-"))
            continue
        # Determine which pass (A = first time through, C = second time
        # through, i.e. at/after the resume point) this belongs to from the
        # actual matched module time -- MUSIC0's order:row sequence is
        # monotonically increasing (confirmed: ordersync1 itself is sorted
        # ascending by packed order:row), so a single forward playthrough of
        # rows0 already yields entries in chronological order; we only need
        # to know whether the match landed before or after the segment C
        # resume point (entries before it are audible in segment A, entries
        # at/after it are audible in segment C, since segment A cuts off at
        # SEG_A_END before segment C's resume_t).
        if mt < resume_t:
            st = mt + SEG_A_OFFSET
            seg = "A"
        else:
            st = mt + seg_c_offset
            seg = "C"
        print("%-6d %-6d 0x%02x   0x%02x  %-10.3f %-8.3f  seg=%s"
              % (i, part, order, row, mt, st, seg))


def write_srt(rows, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"SRM2")
        f.write(struct.pack("<H", len(rows)))
        for t, order, row, segment in rows:
            t_ms = round(t * 1000.0)
            if t_ms < 0:
                t_ms = 0
            f.write(struct.pack("<IBBB", t_ms, order, row, segment))


def read_srt(path):
    with open(path, "rb") as f:
        data = f.read()
    assert data[:4] == b"SRM2", "bad magic"
    (count,) = struct.unpack_from("<H", data, 4)
    out = []
    off = 6
    for _ in range(count):
        t_ms, order, row, segment = struct.unpack_from("<IBBB", data, off)
        off += 7
        out.append((t_ms, order, row, segment))
    return out


def validate(rows):
    # rows are (t_ms, order, row, segment); work in seconds throughout.
    times = [r[0] / 1000.0 for r in rows]
    print()
    print("=== VALIDATION ===")
    t0, t1 = times[0], times[-1]
    print("total rows: %d, time span: %.3fs .. %.3fs (%.3fs)"
          % (len(rows), t0, t1, t1 - t0))

    for seg, name in ((0, "A (MUSIC0 intro)"), (1, "B (MUSIC1)"), (2, "C (MUSIC0 resumed)")):
        seg_rows = [r for r in rows if r[3] == seg]
        if not seg_rows:
            print("segment %d %s: EMPTY" % (seg, name))
            continue
        st, en = seg_rows[0][0] / 1000.0, seg_rows[-1][0] / 1000.0
        print("segment %d %s: %d rows, %.3fs .. %.3fs" % (seg, name, len(seg_rows), st, en))

    def row_duration_near(target):
        near = sorted(t for t in times if abs(t - target) < 3.0)
        deltas = [near[i + 1] - near[i] for i in range(len(near) - 1)]
        deltas = [d for d in deltas if d > 0.001]
        deltas.sort()
        return deltas[len(deltas) // 2] if deltas else float("nan")

    d_a = row_duration_near(50.0)
    d_b = row_duration_near(190.0)
    d_c = row_duration_near(500.0)
    print()
    print("row duration near t=50s (segment A, expect ~0.12s = speed6/tempo125): %.4fs" % d_a)
    print("row duration near t=190s (segment B, expect ~0.0577s = speed3/tempo130): %.4fs" % d_b)
    print("row duration near t=500s (segment C, expect ~0.12s = speed6/tempo125): %.4fs" % d_c)

    # Cross-check against reference/soundtrack_events.json onsets.
    events_path = os.path.join(ROOT, "reference", "soundtrack_events.json")
    if os.path.exists(events_path):
        try:
            ev = json.load(open(events_path))
        except json.JSONDecodeError:
            print()
            print("(reference/soundtrack_events.json failed to parse -- looks like it's "
                  "mid-write by another process; skipping onset cross-check)")
            return
        onsets = ev.get("onsets", [])
        window = [o for o in onsets if 150.0 <= o["t"] <= 220.0]
        window.sort(key=lambda o: -o.get("s", 0))
        top30 = window[:30]

        row_times = sorted(times)

        diffs = []
        for o in top30:
            t = o["t"]
            i = bisect.bisect_left(row_times, t)
            cands = []
            if i < len(row_times):
                cands.append(row_times[i])
            if i > 0:
                cands.append(row_times[i - 1])
            nearest = min(cands, key=lambda rt: abs(rt - t))
            diffs.append(abs(nearest - t) * 1000.0)  # ms

        if diffs:
            mean_d = sum(diffs) / len(diffs)
            rms_d = (sum(d * d for d in diffs) / len(diffs)) ** 0.5
            print()
            print("onset cross-check: %d strongest onsets in [150,220]s vs nearest row"
                  % len(top30))
            print("  mean distance: %.2f ms" % mean_d)
            print("  RMS distance:  %.2f ms" % rms_d)
            print("  per-onset (t, strength, dist_ms):")
            for o, d in zip(top30, diffs):
                print("    t=%8.3f s=%6.2f dist=%6.2f ms" % (o["t"], o.get("s", 0), d))
    else:
        print("(reference/soundtrack_events.json not found -- skipping onset cross-check;"
              " run tool/analyze_audio.py first)")

    # Rows nearest 187.2s.
    print()
    print("rows nearest 187.2s:")
    near = [r for r in rows if abs(r[0] / 1000.0 - 187.2) < 1.0]
    for t_ms, order, row, segment in near:
        flash = (row & 7) == 7
        print("  t=%8.3fs  order=%3d row=%2d  segment=%d%s"
              % (t_ms / 1000.0, order, row, segment,
                 "  <-- (row&7)==7 FLASH" if flash else ""))


def main():
    merged, rows0, resume_order, resume_row, resume_t, seg_c_offset = build_table()
    write_srt(merged, OUT)
    size = os.path.getsize(OUT)
    print()
    print("wrote %s (%d bytes, %d rows)" % (os.path.relpath(OUT, ROOT), size, len(merged)))

    # sanity: round-trip
    back = read_srt(OUT)
    assert len(back) == len(merged)

    print_cue_table(rows0, seg_c_offset, resume_t)
    validate(back)


if __name__ == "__main__":
    main()
