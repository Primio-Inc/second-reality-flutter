#!/usr/bin/env python3
"""The Android launcher icon (the LENS monster's head) and the Android TV banner.

Source is the demo's OWN art -- assets/images/lenspic.sri, the picture the lens
bounces over and the rotozoomer spins (LENS/LENSPIC.BBK; see the note in
the porting notes about LENS.EXB being stale). Nothing is redrawn: the head is decoded
from the indexed picture, un-squeezed, cropped and scaled.

THE PICTURE IS NOT SQUARE-PIXELLED. It is a 320x200 field shown on a 4:3
display, so every pixel is 1.2x taller than it is wide; it is scaled to 320x240
first, or the head comes out squashed.

Android wants TWO things and this writes both:
  * mipmap-*/ic_launcher.png -- the legacy square icon (pre-API 26).
  * mipmap-*/ic_launcher_foreground.png + mipmap-anydpi-v26/ic_launcher.xml --
    the ADAPTIVE icon, whose foreground lives on a 108dp canvas of which only
    the inner ~72dp is guaranteed visible (the launcher masks the rest to a
    circle, squircle, ...). So the head is scaled into that safe zone on a
    transparent canvas, over a black background layer -- black being what the
    picture's own border is, so the two meet invisibly.

THE TV ICON is a THIRD thing. Play's TV quality bar (TV-LB) wants a banner AND
an app icon of at least 160x160 at xhdpi, and the phone's xhdpi legacy icon is
96x96 -- the phone convention, and under the bar. A 1080p TV IS xhdpi, so it
would pick that 96. Raising the phone icon to satisfy a TV would be wrong, so
the TV gets its own, under the `television` UI-mode qualifier. The qualifier
order is not free: Android requires UI mode BEFORE density, so the directory is
mipmap-television-xhdpi and NOT mipmap-xhdpi-television, which aapt2 rejects.
UI mode also outranks density in resource matching, so this PNG beats the
anydpi-v26 adaptive icon on a TV while phones keep the adaptive one.

THE TV BANNER is a different thing from the icon: Android TV's launcher shows
each app as a 320x180 landscape banner (xhdpi drawable), not as a square icon.
It is generated here from reference/art/banner_16_9.png. That source is
2752x1536, which is 1.79:1 and NOT exactly 16:9, so it is centre-CROPPED to
16:9 before scaling; forcing 320x180 would squash the artwork by about a
percent.

Usage: python3 tool/make_app_icon.py
"""
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "assets/images/lenspic.sri"
BANNER_SRC = ROOT / "reference/art/banner_16_9.png"
RES = ROOT / "android/app/src/main/res"
WEB = ROOT / "web/icons"
BUILD = ROOT / "build/app_icon"

# Android TV's launcher banner. 320x180 at xhdpi is the size Google specifies.
BANNER_SIZE = (320, 180)

# The head in the un-squeezed 320x240 picture: a square crop around it, taken
# from the art itself (the head spans x 75..250, y 10..235).
CROP = (43, 0, 240, 240)  # x, y, w, h -- square, head centred

# Launcher densities: legacy icon size, adaptive foreground canvas (108dp).
DENSITIES = {
    "mdpi": (48, 108),
    "hdpi": (72, 162),
    "xhdpi": (96, 216),
    "xxhdpi": (144, 324),
    "xxxhdpi": (192, 432),
}

# The TV's own launcher icon: Play's TV-LB asks for at least 160x160 at xhdpi.
TV_ICON = 160

# Fraction of the 108dp canvas the head occupies. The inner 72dp (=0.667) is
# the guaranteed-visible zone; 0.72 lets the head fill the mask nicely while
# keeping his ears clear of a circular crop.
FOREGROUND_SCALE = 0.72

ADAPTIVE_XML = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
"""

COLORS_XML = """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- The LENS picture's own background, so the head's black border and the
         adaptive icon's background layer meet invisibly. -->
    <color name="ic_launcher_background">#000000</color>
</resources>
"""


def decode_sri(path: Path) -> tuple[int, int, bytes]:
    d = path.read_bytes()
    if d[:4] != b"SRI1":
        sys.exit(f"{path} is not an .sri")
    w, h = struct.unpack("<HH", d[4:8])
    pal, px = d[8:8 + 768], d[8 + 768:]
    rgb = bytearray()
    for i in px[: w * h]:
        rgb += bytes(
            (pal[i * 3] * 255 // 63, pal[i * 3 + 1] * 255 // 63,
             pal[i * 3 + 2] * 255 // 63)
        )
    return w, h, bytes(rgb)


def ffmpeg(args: list[str]) -> None:
    subprocess.run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error"] + args,
                   check=True)


def main() -> None:
    BUILD.mkdir(parents=True, exist_ok=True)
    w, h, rgb = decode_sri(SRC)
    ppm = BUILD / "lenspic.ppm"
    ppm.write_bytes(b"P6\n%d %d\n255\n" % (w, h) + rgb)

    # Un-squeeze to square pixels (4:3), then crop the head.
    x, y, cw, ch = CROP
    head = BUILD / "head.png"
    ffmpeg(["-i", str(ppm),
            "-vf", f"scale=320:240:flags=lanczos,crop={cw}:{ch}:{x}:{y}",
            str(head)])

    for density, (legacy, canvas) in DENSITIES.items():
        out = RES / f"mipmap-{density}"
        out.mkdir(parents=True, exist_ok=True)

        ffmpeg(["-i", str(head),
                "-vf", f"scale={legacy}:{legacy}:flags=lanczos",
                str(out / "ic_launcher.png")])

        inner = round(canvas * FOREGROUND_SCALE)
        pad = (canvas - inner) // 2
        ffmpeg(["-i", str(head),
                "-vf",
                f"scale={inner}:{inner}:flags=lanczos,format=rgba,"
                f"pad={canvas}:{canvas}:{pad}:{pad}:color=#00000000",
                str(out / "ic_launcher_foreground.png")])

    # The TV's launcher icon (TV-LB). See the module docstring for why this is
    # television-qualified rather than a bigger xhdpi icon for everyone.
    tv = RES / "mipmap-television-xhdpi"
    tv.mkdir(parents=True, exist_ok=True)
    ffmpeg(["-i", str(head),
            "-vf", f"scale={TV_ICON}:{TV_ICON}:flags=lanczos",
            str(tv / "ic_launcher.png")])

    anydpi = RES / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    (anydpi / "ic_launcher.xml").write_text(ADAPTIVE_XML)
    (anydpi / "ic_launcher_round.xml").write_text(ADAPTIVE_XML)
    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(COLORS_XML)

    # The web app's icons come from the same head.
    if WEB.exists():
        for size in (192, 512):
            for name in (f"Icon-{size}.png", f"Icon-maskable-{size}.png"):
                p = WEB / name
                if p.exists():
                    ffmpeg(["-i", str(head),
                            "-vf", f"scale={size}:{size}:flags=lanczos", str(p)])
        fav = ROOT / "web/favicon.png"
        if fav.exists():
            ffmpeg(["-i", str(head), "-vf", "scale=32:32:flags=lanczos", str(fav)])

    print(f"icon: the LENS monster's head, crop {CROP} of the un-squeezed picture")
    print(f"wrote legacy + adaptive mipmaps under {RES}")

    if BANNER_SRC.exists():
        bw, bh = BANNER_SIZE
        tv = RES / "drawable-xhdpi"
        tv.mkdir(parents=True, exist_ok=True)
        # Centre-crop to 16:9 first (the source is 1.79:1), then scale. Forcing
        # the scale would squash the artwork.
        ffmpeg(["-i", str(BANNER_SRC),
                "-vf", f"crop=ih*{bw}/{bh}:ih,scale={bw}:{bh}:flags=lanczos",
                str(tv / "banner.png")])
        print(f"banner: {bw}x{bh} Android TV banner from {BANNER_SRC.name}")
    else:
        print(f"no {BANNER_SRC}, skipping the TV banner")


if __name__ == "__main__":
    main()
