#!/usr/bin/env python3
"""The soundtrack's STEREO MIX: pan tables + post-DSP, in one place.

Imported by tool/render_soundtrack.py (which ships assets/music/soundtrack.ogg)
and tool/audition_stereo.py (which A/Bs the presets). A preset here IS the mix
the demo plays -- swap it with `render_soundtrack.py --mix <name>`.

WHAT SHIPS BY DEFAULT IS NOT HARD-PANNED. The two S3Ms are 8-channel with
channel settings 0,8,1,9,... , which say only "left channel" / "right channel";
ST3 on a SoundBlaster placed those at ~20%/80% and libopenmpt emulates it.
Measured over MUSIC0's first 30s the untouched render gives L/R correlation
+0.479 and side/mid 0.595, an explicit 3/12 pan table reproduces that (+0.471,
0.602), and a true hard 0/15 pan gives +0.001 / 0.999. So every preset below is
relative to 3/12: there is no ping-pong to undo, only eight voices to re-place.

NOTHING HERE MAY MOVE A SAMPLE. The demo syncs on tracker rows
(lib/engine/music_rows.dart), so the render must stay the same length with zero
lag against the unmixed one. Panning and the DSP below are timing-neutral, and
both callers assert it.
"""
import array
import struct
import subprocess
import wave
from pathlib import Path

RATE = 48000

S3M_DEFAULT_PAN_FLAG = 0x35  # 0xFC => a 32-byte pan table follows the header block
S3M_TEMPO_OFFSET = 0x32

# Per-channel pan, 0 = hard left .. 8 = centre .. 15 = hard right.
PANS = {
    # Varied positions instead of two mirrored points: roughly the shipped
    # width, a less two-dimensional image.
    "spread": [2, 13, 4, 11, 3, 12, 5, 10],
    # Wider than shipped.
    "wide": [1, 14, 3, 12, 2, 13, 4, 11],
}

# Mono below here. The channels are NOT instrument busses -- MUSIC0's channel 1
# plays strings, kettle drum, snare and lead at different times -- so no pan
# choice can centre "the bass". Collapsing the low end is the one fix that does
# not need to know what is playing.
MONO_BASS_HZ = 110

# A STEREO room. Three gotchas, all found by measuring, all easy to re-introduce:
#   * aecho's out_gain is a MASTER gain, not a wet level: out_gain=0.22 pulled
#     the whole track down 13dB (peak 1.00 -> 0.24). Keep it ~1 and set the
#     depth with the DECAYS.
#   * aecho applies the SAME delays to both channels, so its tail is MONO and it
#     RAISES L/R correlation -- it narrows the mix instead of widening it. Hence
#     the split into per-side taps, which decorrelates the tails: that is what
#     reads as air around the music rather than as an echo.
#   * WIDEN BY MID/SIDE, never by decorrelation. stereowiden (a Haas-type
#     allpass) drove L/R correlation NEGATIVE (-0.09, and -0.40 when eased) --
#     out of phase, partly cancelling on any mono speaker. Scaling the SIDE
#     component leaves the mono sum (the MID) untouched by construction.
ROOM_L = "aecho=1:0.9:37|53|71:0.18|0.13|0.09"
ROOM_R = "aecho=1:0.9:43|61|79:0.17|0.14|0.08"
WIDEN = "extrastereo=m=1.25:c=1"


def _dsp(widen: bool = False) -> str:
    tail = f",{WIDEN}" if widen else ""
    return (
        f"[0:a]asplit=2[lo][hi];"
        f"[lo]lowpass=f={MONO_BASS_HZ},"
        f"pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1[lom];"
        f"[hi]highpass=f={MONO_BASS_HZ}[hif];"
        f"[lom][hif]amix=inputs=2:weights=1 1:normalize=0[dry];"
        f"[dry]channelsplit=channel_layout=stereo[cl][cr];"
        f"[cl]{ROOM_L}[rl];[cr]{ROOM_R}[rr];"
        f"[rl][rr]join=inputs=2:channel_layout=stereo{tail}[out]"
    )


# THE PRESETS. name -> (pan preset or None, ffmpeg filtergraph or None).
#   original    -- the modules as ST3 played them; what the port shipped before.
#   repack      -- control: repack the file, leave the pan table OFF. Must render
#                  sample-identically to `original`, which isolates the repack
#                  (see patch_pan) from the mix choice.
#   spread      -- pan table only.
#   spread_room -- pan table + mono bass + stereo room.  <-- the shipping mix
#   wide_room   -- wider pans + mono bass + stereo room + mid/side widening.
MIXES = {
    "original": (None, None),
    "repack": ("repack", None),
    "spread": ("spread", None),
    "spread_room": ("spread", _dsp()),
    "wide_room": ("wide", _dsp(widen=True)),
}

DEFAULT_MIX = "spread_room"


def patch_module(
    src: Path, dst: Path, pans: list[int] | None, tempo: int | None
) -> Path:
    """Write `src` to `dst` with an optional tempo patch and pan table.

    Layout after the 0x60 header: orders, instrument parapointers, pattern
    parapointers, then (iff 0x35 == 0xFC) the 32-byte pan table. Neither module
    has one, and the slack before the first data is only 14 bytes (MUSIC0) / 6
    (MUSIC1) -- so we insert whole PARAGRAPHS and add the same count to every
    parapointer, which is exact because parapointers are paragraph offsets.

    pans=None skips the table entirely (the "repack" control).
    """
    d = bytearray(src.read_bytes())
    if tempo is not None:
        assert d[S3M_TEMPO_OFFSET] in (125, tempo)
        d[S3M_TEMPO_OFFSET] = tempo

    ordnum, insnum, patnum = struct.unpack("<HHH", d[0x20:0x26])
    ins_at = 0x60 + ordnum
    table_at = ins_at + insnum * 2 + patnum * 2
    ptrs = list(struct.unpack(f"<{insnum + patnum}H", d[ins_at:table_at]))

    def memseg(at: int) -> int:
        return d[at] << 16 | d[at + 1] | d[at + 2] << 8

    def set_memseg(at: int, seg: int) -> None:
        d[at] = (seg >> 16) & 0xFF
        d[at + 1] = seg & 0xFF
        d[at + 2] = (seg >> 8) & 0xFF

    # Sample DATA hangs off a SECOND set of pointers: each instrument header
    # carries its own memseg at +0x0D (hi byte, then a little-endian low word).
    # Shifting only the header's pointer table leaves every sample reading from
    # its old offset -- the repack control caught exactly that.
    segs = [memseg(p * 16 + 0x0D) for p in ptrs[:insnum] if p]
    first_data = min([p * 16 for p in ptrs if p] + [s * 16 for s in segs if s])
    need = 32 - (first_data - table_at)
    shift = max(0, -(-need // 16))  # paragraphs to insert
    if shift:
        d[first_data:first_data] = b"\x00" * (shift * 16)
        ptrs = [p + shift if p else 0 for p in ptrs]
        d[ins_at:table_at] = struct.pack(f"<{insnum + patnum}H", *ptrs)
        # ...and the instrument headers have MOVED with it, so their memsegs are
        # read and written at the NEW header positions.
        for p in ptrs[:insnum]:
            at = p * 16 + 0x0D
            if p and memseg(at):
                set_memseg(at, memseg(at) + shift)

    if pans is not None:
        d[S3M_DEFAULT_PAN_FLAG] = 252
        for c in range(32):
            d[table_at + c] = 0x20 | (pans[c] if c < len(pans) else 8)
    dst.write_bytes(bytes(d))
    return dst


# ---------------------------------------------------------------------------
# The DSP stage, and the checks that keep it from breaking sync.
# ---------------------------------------------------------------------------


def apply_dsp(src: Path, dst: Path, graph: str | None, limit: int | None) -> None:
    """Run the mix's filtergraph, trimmed back to `limit` frames.

    The room's taps ring on past the input, extending the TAIL (they shift
    nothing), so the output is trimmed to the unmixed length -- the file has to
    stay a drop-in for the row clock's timebase.
    """
    args = ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(src)]
    if graph:
        if limit is not None:
            graph = graph.replace("[out]", f",atrim=end_sample={limit}[out]")
        args += ["-filter_complex", graph, "-map", "[out]"]
    args += [str(dst)]
    subprocess.run(args, check=True)


def read_frames(path: Path, start: float = 0.0, secs: float | None = None):
    with wave.open(str(path), "rb") as w:
        w.setpos(int(start * RATE))
        n = w.getnframes() if secs is None else int(secs * RATE)
        a = array.array("h")
        a.frombytes(w.readframes(n))
        return a


def frames(path: Path) -> int:
    with wave.open(str(path), "rb") as w:
        return w.getnframes()


def measure(path: Path, start: float = 120.0, secs: float = 120.0):
    """(L/R correlation, side/mid, rms, peak) over a busy stretch."""
    a = read_frames(path, start, secs)
    L, R = a[0::2], a[1::2]
    sl = sum(x * x for x in L) ** 0.5
    sr = sum(x * x for x in R) ** 0.5
    corr = sum(x * y for x, y in zip(L, R)) / (sl * sr) if sl and sr else 0.0
    mid = sum(((x + y) / 2) ** 2 for x, y in zip(L, R)) ** 0.5
    side = sum(((x - y) / 2) ** 2 for x, y in zip(L, R)) ** 0.5
    rms = ((sl * sl + sr * sr) / len(a)) ** 0.5
    peak = max(max(L), max(R), -min(L), -min(R)) / 32768
    return corr, side / mid if mid else 0.0, rms, peak


def level_match(path: Path, target_rms: float) -> float:
    """Match the unmixed loudness, capped so a room on top cannot clip.

    The unmixed render already peaks at full scale, so the gain is limited to
    keep the peak under 0.99; the mix then sits a dB or two lower rather than
    distorting.
    """
    _, _, rms, peak = measure(path)
    if rms <= 0 or peak <= 0:
        return 1.0
    gain = min(target_rms / rms, 0.99 / peak)
    if abs(gain - 1.0) < 0.01:
        return 1.0
    out = path.with_suffix(".gain.wav")
    subprocess.run(
        ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(path),
         "-af", f"volume={gain:.4f}", str(out)],
        check=True,
    )
    out.replace(path)
    return gain


def mid_envelope(path: Path, upto: float = 120.0, hop: int = 256) -> list[float]:
    """Coarse |mid| envelope -- enough to detect a whole-track time shift."""
    pcm = read_frames(path, 0.0, upto)
    env = []
    for i in range(0, len(pcm) - 2 * hop, 2 * hop):
        acc = 0
        for j in range(i, i + 2 * hop, 2):
            acc += abs(pcm[j] + pcm[j + 1])
        env.append(acc / hop)
    return env


def peak_lag(a: list[float], b: list[float], max_lag: int = 40) -> int:
    """Lag (in envelope hops) at which b best matches a. 0 = no time shift.

    NORMALISED -- a raw dot product is biased toward whichever lag drags the
    loudest samples into the window, and reported a phantom 1-hop shift on two
    IDENTICAL renders.
    """
    best, best_lag = -1e30, 0
    n = min(len(a), len(b)) - max_lag
    for lag in range(-max_lag, max_lag + 1):
        num = sum(a[i] * b[i + lag] for i in range(max_lag, n))
        den = (
            sum(a[i] * a[i] for i in range(max_lag, n))
            * sum(b[i + lag] * b[i + lag] for i in range(max_lag, n))
        ) ** 0.5
        r = num / den if den else 0.0
        if r > best:
            best, best_lag = r, lag
    return best_lag
