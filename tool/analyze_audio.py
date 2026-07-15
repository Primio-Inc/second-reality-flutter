#!/usr/bin/env python3
"""Analyze the demo soundtrack into a machine-readable EVENT MAP so demo
effects can be synced to the music EXACTLY (the dis_muscode equivalent),
instead of eyeballing seconds against a video capture.

Pipeline (pure python + ffmpeg, no numpy):
  1. ffmpeg decodes assets/music/soundtrack.ogg -> mono s16le @ 11025 Hz.
  2. Three one-pole band splits:  bass = LP(200Hz), mid = LP(2kHz)-bass,
     high = x-LP(2kHz).
  3. Per 23ms hop (256 samples): mean |energy| per band.
  4. Onset strength = half-wave-rectified relative energy rise per band;
     broadband strength = weighted sum.  Peaks >= adaptive threshold with
     120ms minimum separation are events.

Outputs:
  reference/soundtrack_events.json  (tooling data — NOT bundled in the app)
    { "hop": secs, "energy": [[bass,mid,high] per hop, quantized 0-99],
      "onsets": [ {"t": secs, "s": strength, "b": [bass,mid,high rise]} ] }
  and prints the strongest events (use these for SyncTable timestamps).

Usage: python3 tool/analyze_audio.py [--top N] [--near T WINDOW]
  --near 103.8 1.0   list onsets within 1s of 103.8s (checking a sync point)
"""
import json
import math
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets/music/soundtrack.ogg"
OUT = ROOT / "reference/soundtrack_events.json"

RATE = 11025
HOP = 256  # ~23.2ms


def decode():
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(SRC), "-ac", "1",
         "-ar", str(RATE), "-f", "s16le", "-"],
        capture_output=True, check=True).stdout
    n = len(raw) // 2
    return struct.unpack(f"<{n}h", raw[: n * 2])


def band_energies(samples):
    """One-pole band split; per-hop mean absolute energy for bass/mid/high."""
    # One-pole LP coefficient: a = dt / (rc + dt), rc = 1/(2*pi*fc)
    def alpha(fc):
        rc = 1.0 / (2 * math.pi * fc)
        dt = 1.0 / RATE
        return dt / (rc + dt)

    a_b = alpha(200.0)
    a_m = alpha(2000.0)
    lp_b = 0.0
    lp_m = 0.0
    hops = []
    acc_b = acc_m = acc_h = 0.0
    cnt = 0
    for s in samples:
        x = s / 32768.0
        lp_b += a_b * (x - lp_b)
        lp_m += a_m * (x - lp_m)
        acc_b += abs(lp_b)
        acc_m += abs(lp_m - lp_b)
        acc_h += abs(x - lp_m)
        cnt += 1
        if cnt == HOP:
            hops.append((acc_b / HOP, acc_m / HOP, acc_h / HOP))
            acc_b = acc_m = acc_h = 0.0
            cnt = 0
    return hops


def onsets(hops):
    """Per-band half-wave-rectified relative rise -> peak-picked events."""
    eps = 1e-4
    strength = [0.0]
    rises = [(0.0, 0.0, 0.0)]
    for i in range(1, len(hops)):
        rb = max(0.0, hops[i][0] - hops[i - 1][0]) / (hops[i - 1][0] + eps)
        rm = max(0.0, hops[i][1] - hops[i - 1][1]) / (hops[i - 1][1] + eps)
        rh = max(0.0, hops[i][2] - hops[i - 1][2]) / (hops[i - 1][2] + eps)
        rises.append((rb, rm, rh))
        strength.append(rb * 1.0 + rm * 0.8 + rh * 0.6)
    # Adaptive threshold: local mean over +-1s.
    w = int(1.0 * RATE / HOP)
    events = []
    min_sep = int(0.120 * RATE / HOP)
    last = -min_sep
    for i in range(1, len(strength) - 1):
        lo = max(0, i - w)
        hi = min(len(strength), i + w)
        local = sum(strength[lo:hi]) / (hi - lo)
        if (strength[i] > strength[i - 1] and strength[i] >= strength[i + 1]
                and strength[i] > 4 * local + 0.3 and i - last >= min_sep):
            events.append((i * HOP / RATE, strength[i], rises[i]))
            last = i
    return events


def main():
    samples = decode()
    hops = band_energies(samples)
    evs = onsets(hops)
    OUT.write_text(json.dumps({
        "hop": HOP / RATE,
        "energy": [[min(99, int(b * 300)), min(99, int(m * 300)),
                    min(99, int(h * 300))] for b, m, h in hops],
        "onsets": [{"t": round(t, 3), "s": round(s, 2),
                    "b": [round(x, 2) for x in r]} for t, s, r in evs],
    }))
    print(f"{OUT.name}: {len(hops)} hops, {len(evs)} onsets")

    if "--near" in sys.argv:
        i = sys.argv.index("--near")
        t0 = float(sys.argv[i + 1])
        win = float(sys.argv[i + 2])
        print(f"onsets within {win}s of {t0}s:")
        for t, s, r in evs:
            if abs(t - t0) <= win:
                print(f"  t={t:8.3f}  s={s:5.2f}  bass={r[0]:.2f} "
                      f"mid={r[1]:.2f} high={r[2]:.2f}")
        return

    top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv \
        else 40
    print(f"top {top} onsets:")
    for t, s, r in sorted(evs, key=lambda e: -e[1])[:top]:
        print(f"  t={t:8.3f}  s={s:5.2f}  bass={r[0]:.2f} mid={r[1]:.2f} "
              f"high={r[2]:.2f}")


if __name__ == "__main__":
    main()
