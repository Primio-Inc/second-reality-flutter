#!/usr/bin/env python3
"""Render the demo soundtrack from our OWN copies of the real tracker
modules, instead of the archive.org "Metropolis" mastered re-recording.

WHY: the mastered rip (previously built by tool/fetch_music.sh, backed up to
reference/music/soundtrack_mastered.ogg by this script's first run) drifts
against the modules by about 0.04% -- MUSIC1's measured alignment walks from
+104.340s at soundtrack t=120s to +104.460s at t=440s. The demo syncs on
tracker ROWS (see lib/engine/music_rows.dart), so that drift slowly corrupts
sync in long parts. Rendering the real modules ourselves with libopenmpt
(openmpt123) removes the drift entirely: the render IS the row clock's
timebase, sample for sample.

Inputs (see reference/music/README.md -- these are the INTACT copies; the
vendored original/MAIN/MUSIC{0,1}.S3M have scrambled pattern data and must
NOT be used):
  reference/music/music0.s3m  "UnreaL ][ - The 2ND Reality" -- intro AND end tune
  reference/music/music1.s3m  "UnreaL ][ / PM" -- main demo tune

Segment map (measured by normalized cross-correlation of onset envelopes
against the previous soundtrack; see the task that produced this script):
  segment A: soundtrack [0.090, 103.600)   = MUSIC0 module time [0, 103.510)
  segment B: soundtrack [103.600, 472.970) = MUSIC1 module time [0, 369.370)

  The A->B cut is placed so THE BOOM LANDS ON THE EXPLOSION'S WHITE FLASH.
  MUSIC1 does not hit on its first sample: its boom starts 0.230s into the module
  (measured off the render's waveform). The capture puts the boom's attack at
  103.835s and the video flash at 103.833s -- they coincide -- so the demo began
  MUSIC1 at 103.600 and the bang caught up 0.23s later. Cutting at the module's
  first SAMPLE instead (103.830) puts the bang 0.23s behind the picture. (An earlier cut at 104.360 came from correlating against the mastered
  rip and played 0.53s of MUSIC0 the demo never plays, which threw every
  post-explosion part off the music.)
  segment C: soundtrack [473.730, end)     = MUSIC0 module time [134.880, end)
  i.e. segment C's module time t maps to soundtrack time t + 338.850.

  The resume point is SNAPPED to a music order boundary (MUSIC0 order 18 starts
  at module t=134.880s, 80ms past the correlation-measured 134.800s): the demo
  resumes the module at an order, and the row clock in
  tool/extract_music_rows.py snaps to the same place. The two MUST agree, or
  every row in the end section is 80ms out.

Pipeline:
  1. openmpt123 renders each module (ALL subsongs consecutively -- MUSIC0's 77
     orders are split into 3 subsongs by libopenmpt, and STMIK plays them
     straight through) to
     16-bit PCM WAV at 48kHz stereo, best-quality 8-tap interpolation.
  2. Segments are cut directly from the raw PCM sample arrays (no ffmpeg
     -ss/-t, no codec re-encode) so the cut points are sample-exact and
     drift-free.
  3. Concatenated with a leading 0.090s of silence, written to WAV, then
     encoded once to assets/music/soundtrack.ogg (libvorbis q6).

Usage: python3 tool/render_soundtrack.py
"""
import argparse
import array
import shutil
import struct
import subprocess
import sys
import wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import stereo_mix  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
MUSIC0 = ROOT / "reference/music/music0.s3m"
MUSIC1 = ROOT / "reference/music/music1.s3m"
BACKUP = ROOT / "reference/music/soundtrack_mastered.ogg"
OUT = ROOT / "assets/music/soundtrack.ogg"
OPENMPT123 = "/opt/homebrew/bin/openmpt123"

RATE = 48000
CHANNELS = 2

LEAD_SILENCE = 0.090

# THE STMIK TEMPO QUIRK. MUSIC0's S3M header says initial tempo 125 and
# libopenmpt honours it -- but the original demo's player (STMIK 0.9) plays it
# at effective tempo 120 (4% slower). Proven by chroma (melody) alignment
# against the capture's own audio: at header tempo the lag grows linearly to
# -3.8s by the boom (ratio exactly 125/120); patched to 120 it is flat.
# Cross-checks: the capture-measured credit-card fades (16.07/24.04/30.19s)
# match the tempo-120 cue times (16.09/24.09/29.97), and dis_sync cue 10 (the
# module switch, order 13 row 0) lands at module t=104.000 = the capture's
# boom. MUSIC1's header tempo IS correct (techno beat grid matched the capture
# to ~0.1%), so only MUSIC0 is patched. Keep in sync with
# tool/extract_music_rows.py.
STMIK_MUSIC0_TEMPO = 120
S3M_TEMPO_OFFSET = 0x32

# Segment A: MUSIC0 [0, A_END). MUSIC0 does NOT stop at the explosion: its own
# crash IS the boom (it falls on dis_sync cue 10 / order 13, which is exactly
# why the cue and the bang coincide — that coincidence fooled us into thinking
# the module switched there). MUSIC0 plays on to ~108, then stops.
A_END = 107.960
# THE LOAD SILENCE. After MUSIC0 ends the original is SILENT while the title
# picture loads, and only then does MUSIC1 start. Measured in the capture:
# audio dies at ~107.85 and MUSIC1 begins at 109.55 (cross-correlating MUSIC1's
# own render against the capture: r=0.93). In soundtrack time (= capture +
# 0.200) that is 109.750.
#
# WE HAD NO SILENCE AT ALL — MUSIC0 was cut into MUSIC1 at the boom, so every
# note of MUSIC1 played 5.66s EARLY and every part from the explosion onward
# looked that far late. Do not "tighten" this gap: it is not dead air, it is
# where the demo's music actually is.
SEG_B_SOUNDTRACK_START = 109.750
# Segment B: MUSIC1 [B_START, B_END) — from the module's true start (its first
# four rows are silent; the demo plays them).
B_START = 0.0
B_END = 369.370
# Segment C: MUSIC0 [C_START, end of module) -- order 18's start at tempo 120
# (was 134.880 at tempo 125; same order boundary, rescaled clock). Must match
# the snap chosen by tool/extract_music_rows.py.
C_START = 140.500  # MUSIC0 order 18 (tempo 120)

# Soundtrack timestamps these segments must land at (for the report only --
# they fall out automatically from concatenation order + LEAD_SILENCE).
SEG_A_START = LEAD_SILENCE
SEG_B_START = LEAD_SILENCE + A_END  # == 104.360
SEG_C_START = SEG_B_START + B_END  # == 473.730


def render_module(
    src: Path,
    dst: Path,
    patch_tempo: int | None = None,
    pans: list[int] | None = None,
) -> None:
    if patch_tempo is not None or pans is not None:
        # The tempo patch and the STEREO PAN TABLE (tool/stereo_mix.py) are the
        # only edits made to the modules, and neither moves a sample.
        src = stereo_mix.patch_module(
            src, dst.with_suffix(".patched.s3m"), pans, patch_tempo
        )
    subprocess.run(
        [
            OPENMPT123,
            "--batch",
            "--quiet",
            "--force",  # overwrite a WAV left by a previous run
            "--samplerate",
            str(RATE),
            "--channels",
            str(CHANNELS),
            "--no-float",
            "--filter",
            "8",  # best-quality windowed-sinc interpolation
            "--ramping",
            "-1",  # libopenmpt default (avoids click artifacts)
            # Dither is RANDOM, so with openmpt123's default no render reproduces
            # itself byte-for-byte -- which the audition's repack control has to
            # rely on. It is inaudible LSB noise at 16 bits.
            "--dither",
            "0",
            # -1 = play every subsong consecutively, which is what STMIK does:
            # it walks the module's order list straight through. libopenmpt
            # splits MUSIC0's 77 orders into THREE "subsongs", and rendering
            # only subsong 0 stopped the ending tune 130s early (module 503.8s
            # instead of 633.4s) -- the credits and the end scroller would have
            # run out of music. The row clock (tool/extract_music_rows.py) never
            # selects a subsong either, so this keeps the two in step.
            "--subsong",
            "-1",
            "-o",
            str(dst),
            str(src),
        ],
        check=True,
    )


def read_pcm(path: Path) -> bytes:
    with wave.open(str(path), "rb") as w:
        assert w.getnchannels() == CHANNELS
        assert w.getsampwidth() == 2
        assert w.getframerate() == RATE
        return w.readframes(w.getnframes())


def seconds_to_bytes(t: float) -> int:
    frame = round(t * RATE)
    return frame * CHANNELS * 2  # s16le stereo


def write_wav(path: Path, pcm: bytes) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(CHANNELS)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)


def rms(pcm: bytes) -> float:
    if not pcm:
        return 0.0
    n = len(pcm) // 2
    samples = struct.unpack(f"<{n}h", pcm[: n * 2])
    ss = sum(s * s for s in samples)
    return (ss / n) ** 0.5


def concat(m0_pcm: bytes, m1_pcm: bytes) -> bytes:
    """The three segments, as documented at the top of this file."""
    silence = b"\x00" * seconds_to_bytes(LEAD_SILENCE)
    seg_a = m0_pcm[: seconds_to_bytes(A_END)]
    seg_b = m1_pcm[seconds_to_bytes(B_START): seconds_to_bytes(B_END)]
    gap_secs = SEG_B_SOUNDTRACK_START - (LEAD_SILENCE + A_END)
    if gap_secs < 0:
        sys.exit(f"MUSIC1 starts before MUSIC0 ends (gap {gap_secs:.3f}s)")
    load_gap = b"\x00" * seconds_to_bytes(gap_secs)
    seg_c = m0_pcm[seconds_to_bytes(C_START):]
    return silence + seg_a + load_gap + seg_b + seg_c


def render_pair(mix: str, tmp: Path, tag: str) -> bytes:
    """Render both modules under a mix preset and concatenate them."""
    pan_name, _ = stereo_mix.MIXES[mix]
    pans = None if pan_name in (None, "repack") else stereo_mix.PANS[pan_name]
    out = []
    for name, src, tempo in (
        ("music0", MUSIC0, STMIK_MUSIC0_TEMPO),
        ("music1", MUSIC1, None),
    ):
        wav = tmp / f"{name}_{tag}.wav"
        render_module(src, wav, patch_tempo=tempo, pans=pans)
        out.append(read_pcm(wav))
    return concat(*out)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--mix",
        default=stereo_mix.DEFAULT_MIX,
        choices=list(stereo_mix.MIXES),
        help="stereo mix preset (see tool/stereo_mix.py); "
             f"default {stereo_mix.DEFAULT_MIX}",
    )
    args = ap.parse_args()
    mix = args.mix
    _, graph = stereo_mix.MIXES[mix]

    if not MUSIC0.exists() or not MUSIC1.exists():
        sys.exit(f"missing {MUSIC0} or {MUSIC1}")

    if OUT.exists() and not BACKUP.exists():
        BACKUP.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(OUT, BACKUP)
        print(f"backed up previous soundtrack -> {BACKUP}")
    elif BACKUP.exists():
        print(f"backup already present at {BACKUP} (not overwriting)")

    tmp = ROOT / "build/render_soundtrack_tmp"
    tmp.mkdir(parents=True, exist_ok=True)

    print(f"mix: {mix}")
    print("rendering music0.s3m (all subsongs, STMIK tempo %d) + music1.s3m..."
          % STMIK_MUSIC0_TEMPO)
    full = render_pair(mix, tmp, mix)

    # THE REFERENCE: the same soundtrack with NO mix. Every check below is
    # against this, because a mix that moved a sample would desync every part
    # (the demo syncs on tracker rows, not on the audio).
    ref = full if mix == "original" else render_pair("original", tmp, "ref")

    silence_b = seconds_to_bytes(LEAD_SILENCE)
    seg_a_b = seconds_to_bytes(A_END)
    gap_secs = SEG_B_SOUNDTRACK_START - (LEAD_SILENCE + A_END)
    gap_b = seconds_to_bytes(gap_secs)
    seg_b_b = seconds_to_bytes(B_END) - seconds_to_bytes(B_START)

    print(f"load silence: {gap_secs:.3f}s "
          f"(MUSIC0 ends {LEAD_SILENCE + A_END:.3f}, "
          f"MUSIC1 starts {SEG_B_SOUNDTRACK_START:.3f})")
    total_secs = len(full) / (RATE * CHANNELS * 2)

    def secs(b: int) -> float:
        return b / (RATE * CHANNELS * 2)

    seg_a_start = secs(silence_b)
    seg_b_start = secs(silence_b + seg_a_b + gap_b)
    seg_c_start = secs(silence_b + seg_a_b + gap_b + seg_b_b)

    print()
    print(f"segment A (MUSIC0 [0, {A_END:.3f})):   soundtrack [{seg_a_start:.3f}, {seg_b_start:.3f})")
    print(f"segment B (MUSIC1 [{B_START:.3f}, {B_END:.3f})): soundtrack [{seg_b_start:.3f}, {seg_c_start:.3f})")
    print(f"segment C (MUSIC0 [{C_START:.3f}, end)): soundtrack [{seg_c_start:.3f}, {total_secs:.3f})")
    print(f"final duration: {total_secs:.3f}s")

    # Boundary RMS sanity check (0.5s each side of each cut).
    half_b = seconds_to_bytes(0.5)

    def window_rms(offset_b: int, before: bool) -> float:
        if before:
            start = max(0, offset_b - half_b)
            chunk = full[start:offset_b]
        else:
            chunk = full[offset_b : offset_b + half_b]
        return rms(chunk)

    for label, off_secs in (
        ("A/B boundary", seg_b_start),
        ("B/C boundary", seg_c_start),
    ):
        off_b = seconds_to_bytes(off_secs)
        before = window_rms(off_b, True)
        after = window_rms(off_b, False)
        print(f"{label} @ {off_secs:.3f}s: RMS before={before:.1f} after={after:.1f}")

    full_wav = tmp / "full.wav"
    write_wav(full_wav, full)
    ref_wav = tmp / "ref.wav"
    write_wav(ref_wav, ref)

    # The mix's DSP, trimmed to the unmixed length (the room's taps ring past
    # the end of the input; they shift nothing) and level-matched to it.
    mixed_wav = tmp / "mixed.wav"
    ref_frames = stereo_mix.frames(ref_wav)
    stereo_mix.apply_dsp(full_wav, mixed_wav, graph, ref_frames)
    if graph:
        _, _, target_rms, _ = stereo_mix.measure(ref_wav)
        gain = stereo_mix.level_match(mixed_wav, target_rms)
        if gain != 1.0:
            print(f"level-matched to the unmixed render: gain {gain:.3f}")

    # THE CHECKS THAT PROTECT SYNC. Same length, and zero lag against the
    # unmixed render -- a filter with latency would slide the whole soundtrack
    # against the row clock and every part with it.
    n = stereo_mix.frames(mixed_wav)
    if n != ref_frames:
        sys.exit(f"mix changed the length ({n} vs {ref_frames} frames) -- would desync")
    lag = stereo_mix.peak_lag(
        stereo_mix.mid_envelope(ref_wav), stereo_mix.mid_envelope(mixed_wav)
    )
    if lag != 0:
        sys.exit(f"mix SHIFTED the audio ({lag} envelope hops) -- would desync")
    corr, side_mid, _, peak = stereo_mix.measure(mixed_wav)
    if corr < 0:
        sys.exit(f"mix is OUT OF PHASE (L/R corr {corr:+.3f}) -- it would cancel in mono")
    print(f"\nsync ok: same length, lag 0 vs the unmixed render")
    print(f"stereo:  L/R corr {corr:+.3f}, side/mid {side_mid:.3f}, peak {peak:.2f}")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            str(mixed_wav),
            "-c:a",
            "libvorbis",
            "-q:a",
            "6",
            str(OUT),
        ],
        check=True,
    )
    print(f"wrote {OUT}  (mix: {mix})")

    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
