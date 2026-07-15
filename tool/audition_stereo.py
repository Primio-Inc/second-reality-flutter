#!/usr/bin/env python3
"""A/B the soundtrack's stereo mixes: render every preset, cut excerpts, check.

The presets themselves live in tool/stereo_mix.py and are SHARED with
tool/render_soundtrack.py, so what you audition here is exactly what
`render_soundtrack.py --mix <name>` ships.

For each preset this writes a full-length WAV plus three excerpts (an
orchestral one, a techno one, one from the city fly-through) to build/audition/,
and asserts the things sync depends on:

  * SAME LENGTH and ZERO LAG against the unmixed render. The demo syncs on
    tracker rows (lib/engine/music_rows.dart), so a filter with latency would
    slide the whole soundtrack and every part with it.
  * The "repack" control -- the module repacked with the pan table left OFF --
    must render SAMPLE-IDENTICALLY to the unmixed one. That isolates the repack
    (inserted paragraphs, rewritten parapointers) from the mix choice, and it
    earned its keep: it caught that instrument headers carry their OWN
    sample-data pointers, which were not being shifted.
  * L/R correlation stays positive, i.e. the mix is mono-compatible.

Usage: python3 tool/audition_stereo.py
"""
import hashlib
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_soundtrack as rs  # noqa: E402  (segment map + module rendering)
import stereo_mix  # noqa: E402  (the presets, and the checks)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/audition"

# (label, start, end) in soundtrack time.
EXCERPTS = [
    ("intro", 20.0, 60.0),
    ("techno", 186.0, 216.0),
    ("city", 480.0, 510.0),
]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = OUT / "tmp"
    tmp.mkdir(exist_ok=True)

    ref_frames = None
    ref_env = None
    target_rms = 0.0
    digests = {}

    print(f"{'preset':14} {'corr':>7} {'side/mid':>9} {'peak':>6}  checks")
    for name, (_, graph) in stereo_mix.MIXES.items():
        raw = tmp / f"{name}_raw.wav"
        pcm = rs.render_pair(name, tmp, name)
        digests[name] = hashlib.sha256(pcm).hexdigest()
        rs.write_wav(raw, pcm)

        full = OUT / f"{name}.wav"
        stereo_mix.apply_dsp(raw, full, graph, ref_frames)

        n = stereo_mix.frames(full)
        if ref_frames is None:  # "original" is first in MIXES
            ref_frames, ref_env = n, stereo_mix.mid_envelope(full)
            corr, sm, target_rms, peak = stereo_mix.measure(full)
            print(f"{name:14} {corr:+7.3f} {sm:9.3f} {peak:6.2f}  (unmixed reference)")
            continue

        if n != ref_frames:
            sys.exit(f"{name}: {n} frames vs {ref_frames} -- length changed, would desync")
        lag = stereo_mix.peak_lag(ref_env, stereo_mix.mid_envelope(full))
        if lag != 0:
            sys.exit(f"{name}: envelope lag {lag} hops -- it SHIFTED the audio, would desync")
        if graph:
            stereo_mix.level_match(full, target_rms)
        corr, sm, _, peak = stereo_mix.measure(full)
        if corr < 0:
            sys.exit(f"{name}: L/R corr {corr:+.3f} -- OUT OF PHASE, would cancel in mono")
        print(f"{name:14} {corr:+7.3f} {sm:9.3f} {peak:6.2f}  lag 0, len ok")

        for label, start, end in EXCERPTS:
            subprocess.run(
                ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                 "-ss", str(start), "-to", str(end), "-i", str(full),
                 "-c:a", "libvorbis", "-q:a", "6", str(OUT / f"{name}_{label}.ogg")],
                check=True,
            )

    if digests["repack"] != digests["original"]:
        sys.exit("REPACK IS LOSSY: the repack control does not match the unmixed render")
    print("\nrepack verified lossless (repack == original, sample-exact)")
    print(f"auditions in {OUT}")


if __name__ == "__main__":
    main()
