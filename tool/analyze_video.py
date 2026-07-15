#!/usr/bin/env python3
"""Analyze the demo capture into a machine-readable FRAME MAP, so scenes and
sync points can be located DETERMINISTICALLY instead of eyeballing screenshots.

This is the video counterpart to tool/analyze_audio.py. The workflow it exists
to support:

    1. `--cuts` / `--segments` / `--find`   -> narrow a question down to a few
       candidate timestamps, deterministically (no image reading at all).
    2. `--frames T...`                      -> dump just those frames as PNGs.
    3. only then LOOK at that shortlist.

Pipeline (pure python + ffmpeg, no numpy/PIL):
  ffmpeg decodes /tmp/sr_demo.mp4 -> rgb24 @ 64x40, `--fps` frames/sec.
  Per frame, cheap deterministic features:
    luma      mean / std of luma
    black,white  fraction of pixels below 8 / above 245  (blackouts, flashes)
    rgb       mean r,g,b            (scene tint: red glenz, blue title, ...)
    sat       mean saturation       (mono vs colourful)
    detail    mean |horizontal luma gradient|  (dot fields / dithered plasma
              score high; smooth gradients and flat fills score near zero)
    box       content bounding box as (top,bottom,left,right) rows/cols in a
              0..99 scale, ignoring black borders  (letterboxing / padding)
    diff      mean |luma - previous frame's luma|  (the cut score)

Derived: cuts (diff peaks), flashes (white), blackouts (black), and segments
(the runs between cuts, with their median features).

Outputs reference/video_events.json (tooling data — NOT bundled in the app).

Usage:
  python3 tool/analyze_video.py                    build the map (once)
  python3 tool/analyze_video.py --cuts             list scene cuts
  python3 tool/analyze_video.py --segments         list scenes + their look
  python3 tool/analyze_video.py --near 153.5 2     per-frame features around T
  python3 tool/analyze_video.py --scan 153 154.5   re-scan a window at 30fps
  python3 tool/analyze_video.py --find white       flashes (also: black, dots)
  python3 tool/analyze_video.py --frames 153.6 160 dump PNGs of a shortlist
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VIDEO = Path("/tmp/sr_demo.mp4")
OUT = ROOT / "reference/video_events.json"
FRAMES_DIR = ROOT / "reference/shortlist"

W, H = 64, 40  # feature resolution
DEFAULT_FPS = 10.0


def decode(fps, start=None, end=None):
    """Yield (t, rgb_bytes) for each frame at `fps`."""
    cmd = ["ffmpeg", "-loglevel", "error"]
    if start is not None:
        cmd += ["-ss", str(start)]
    if end is not None:
        cmd += ["-to", str(end)]
    cmd += ["-i", str(VIDEO), "-vf", f"fps={fps},scale={W}:{H}",
            "-pix_fmt", "rgb24", "-f", "rawvideo", "-"]
    p = subprocess.run(cmd, capture_output=True, check=True)
    size = W * H * 3
    t0 = start or 0.0
    for i in range(len(p.stdout) // size):
        yield t0 + i / fps, p.stdout[i * size:(i + 1) * size]


def features(buf, prev_luma):
    n = W * H
    luma = bytearray(n)
    sr = sg = sb = 0
    sat = 0
    for i in range(n):
        r, g, b = buf[i * 3], buf[i * 3 + 1], buf[i * 3 + 2]
        sr += r
        sg += g
        sb += b
        mx, mn = max(r, g, b), min(r, g, b)
        sat += 0 if mx == 0 else (mx - mn) * 255 // mx
        luma[i] = (r * 77 + g * 150 + b * 29) >> 8

    tot = sum(luma)
    mean = tot / n
    var = sum((v - mean) ** 2 for v in luma) / n
    black = sum(1 for v in luma if v < 8) / n
    white = sum(1 for v in luma if v > 245) / n

    detail = 0
    for y in range(H):
        row = y * W
        for x in range(W - 1):
            detail += abs(luma[row + x + 1] - luma[row + x])
    detail /= n

    # content bounding box (rows/cols holding anything non-black)
    top, bot, left, right = H, -1, W, -1
    for y in range(H):
        row = y * W
        if any(luma[row + x] >= 8 for x in range(W)):
            top = min(top, y)
            bot = max(bot, y)
    for x in range(W):
        if any(luma[y * W + x] >= 8 for y in range(H)):
            left = min(left, x)
            right = max(right, x)
    if bot < 0:
        top = bot = left = right = 0

    diff = 0.0
    if prev_luma is not None:
        diff = sum(abs(luma[i] - prev_luma[i]) for i in range(n)) / n

    return {
        "luma": round(mean, 1),
        "std": round(var ** 0.5, 1),
        "black": round(black, 3),
        "white": round(white, 3),
        "rgb": [sr // n, sg // n, sb // n],
        "sat": round(sat / n, 1),
        "detail": round(detail, 1),
        "box": [round(top * 100 / H), round((bot + 1) * 100 / H),
                round(left * 100 / W), round((right + 1) * 100 / W)],
        "diff": round(diff, 1),
    }, luma


def build(fps=DEFAULT_FPS):
    if not VIDEO.exists():
        sys.exit(f"{VIDEO} missing — re-download with yt-dlp (see the porting notes)")
    frames, prev = [], None
    for t, buf in decode(fps):
        f, prev = features(buf, prev)
        f["t"] = round(t, 3)
        frames.append(f)
        if len(frames) % 500 == 0:
            print(f"  {t:.0f}s...", file=sys.stderr)

    cuts = detect_cuts(frames)
    data = {
        "fps": fps,
        "frames": frames,
        "cuts": cuts,
        "segments": segments(frames, cuts),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(data))
    print(f"wrote {OUT}: {len(frames)} frames, {len(cuts)} cuts")


def detect_cuts(frames, thresh=12.0):
    """A cut = a local maximum of the frame-to-frame difference."""
    cuts = []
    for i in range(1, len(frames) - 1):
        d = frames[i]["diff"]
        if d < thresh:
            continue
        if d >= frames[i - 1]["diff"] and d > frames[i + 1]["diff"]:
            cuts.append({"t": frames[i]["t"], "d": d})
    return cuts


def segments(frames, cuts):
    """Median look of each run between cuts — a deterministic scene table."""
    bounds = [0] + [next(i for i, f in enumerate(frames) if f["t"] >= c["t"])
                    for c in cuts] + [len(frames)]
    out = []
    for a, b in zip(bounds, bounds[1:]):
        if b - a < 3:
            continue
        run = frames[a:b]

        def med(k):
            vs = sorted(f[k] for f in run)
            return vs[len(vs) // 2]
        out.append({
            "t0": run[0]["t"], "t1": run[-1]["t"],
            "dur": round(run[-1]["t"] - run[0]["t"], 2),
            "luma": med("luma"), "sat": med("sat"), "detail": med("detail"),
            "black": med("black"), "box": run[len(run) // 2]["box"],
            "rgb": run[len(run) // 2]["rgb"],
        })
    return out


def load():
    if not OUT.exists():
        sys.exit(f"{OUT} missing — run `python3 tool/analyze_video.py` first")
    return json.loads(OUT.read_text())


def fmt(f):
    return (f"t={f['t']:8.3f}  luma={f['luma']:5.1f} std={f['std']:5.1f} "
            f"blk={f['black']:.2f} wht={f['white']:.2f} sat={f['sat']:5.1f} "
            f"det={f['detail']:5.1f} rgb={str(f['rgb']):16s} box={f['box']} "
            f"diff={f['diff']:5.1f}")


def main():
    a = sys.argv[1:]
    if not a:
        return build()

    if a[0] == "--scan":  # fine re-scan straight from the video, no cache
        t0, t1 = float(a[1]), float(a[2])
        fps = float(a[3]) if len(a) > 3 else 30.0
        prev = None
        for t, buf in decode(fps, t0, t1):
            f, prev = features(buf, prev)
            f["t"] = round(t, 3)
            print(fmt(f))
        return

    d = load()
    frames = d["frames"]

    if a[0] == "--cuts":
        for c in d["cuts"]:
            print(f"t={c['t']:8.3f}  diff={c['d']:5.1f}")
    elif a[0] == "--segments":
        print(f"{'t0':>8} {'t1':>8} {'dur':>6}  luma   sat  detail  black  "
              f"box                rgb")
        for s in d["segments"]:
            print(f"{s['t0']:8.2f} {s['t1']:8.2f} {s['dur']:6.2f}  "
                  f"{s['luma']:5.1f} {s['sat']:5.1f} {s['detail']:6.1f} "
                  f"{s['black']:6.2f}  {str(s['box']):18s} {s['rgb']}")
    elif a[0] == "--near":
        t, win = float(a[1]), float(a[2]) if len(a) > 2 else 1.0
        for f in frames:
            if abs(f["t"] - t) <= win:
                print(fmt(f))
    elif a[0] == "--find":
        what = a[1]
        tests = {
            "white": lambda f: f["white"] > 0.6,
            "black": lambda f: f["black"] > 0.95,
            "dots": lambda f: f["detail"] > 8 and f["luma"] < 40,
            "mono": lambda f: f["sat"] < 12,
            "color": lambda f: f["sat"] > 60,
        }
        if what not in tests:
            sys.exit(f"--find: pick one of {', '.join(tests)}")
        hits = [f for f in frames if tests[what](f)]
        # collapse into runs
        runs = []
        for f in hits:
            if runs and f["t"] - runs[-1][1] <= 1.5 / d["fps"] + 1e-6:
                runs[-1][1] = f["t"]
            else:
                runs.append([f["t"], f["t"]])
        for t0, t1 in runs:
            print(f"{t0:8.3f} .. {t1:8.3f}  ({t1 - t0:5.2f}s)")
    elif a[0] == "--frames":
        FRAMES_DIR.mkdir(parents=True, exist_ok=True)
        for ts in a[1:]:
            p = FRAMES_DIR / f"{float(ts):08.3f}.png"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", ts,
                            "-i", str(VIDEO), "-frames:v", "1", str(p)],
                           check=True)
            print("wrote", p)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
