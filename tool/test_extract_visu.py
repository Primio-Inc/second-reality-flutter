#!/usr/bin/env python3
"""Tests for tool/extract_visu.py — the VISU animation-stream decoder.

The one that matters is THE STICKY OBJECT NUMBER. U2A.C/U2E.C set `onum = 0`
once per FRAME, not per token: a token carries only the low nibble of the object
number, and the high bits keep whatever the last 0xC0-prefixed token put there.

U2A has four co[] slots, so its high bits are always zero and a per-token reset
decodes it identically — which is why the bug survived the whole intro. U2E has
58 slots: with a per-token reset, every token after the first in a frame lands on
the wrong object, the ship never switches on, and the fly-through renders a
different film.

Usage: python3 tool/test_extract_visu.py
"""
import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENES = ROOT / "original/VISU/C/SCENE"

spec = importlib.util.spec_from_file_location("ev", ROOT / "tool/extract_visu.py")
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)


def conum_of(scene):
    import struct
    m00 = (SCENES / f"{scene}.00M").read_bytes()
    off = struct.unpack_from("<i", m00, 4)[0]
    return struct.unpack_from("<h", m00, off)[0]


def test_streams_decode_exactly():
    """A correct decode consumes the stream to its last byte and stops on the
    0xFF 0xFF terminator. A desync would misread a token's payload length and
    walk off the token grid, so this is a strong end-to-end check."""
    for scene, want_frames in (("U2A", 521), ("U2E", 1801)):
        data = (SCENES / f"{scene}.0AB").read_bytes()
        frames = ev.parse_anim(data, conum_of(scene))
        assert len(frames) == want_frames, (
            f"{scene}: {len(frames)} frames, expected {want_frames}")
        print(f"  {scene}: {len(frames)} frames from {len(data)} bytes  OK")


def test_object_numbers_stay_in_range():
    """U2E.C bails out with `if(onum >= conum) return(3)`. Every decoded token
    must address a real slot."""
    conum = conum_of("U2E")
    frames = ev.parse_anim((SCENES / "U2E.0AB").read_bytes(), conum)
    for f in frames:
        assert len(f[1]) == conum and len(f[2]) == conum
    print(f"  U2E: all tokens address slots < {conum}  OK")


def test_sticky_onum_switches_the_ship_on():
    """The ship (co[28], mesh 's01') is switched on for most of the fly-through.
    Decoding with a PER-TOKEN reset of onum instead of a per-frame one leaves it
    switched off almost throughout — that is exactly the bug this guards."""
    conum = conum_of("U2E")
    frames = ev.parse_anim((SCENES / "U2E.0AB").read_bytes(), conum)
    on = sum(1 for f in frames if f[2][28])
    assert on == 1467, f"ship on for {on} frames, expected 1467"
    # And a slot that only the 0xC0 path can ever reach must be reachable at all:
    # every slot >= 16 needs the prefix token.
    high = [i for i in range(16, conum) if any(f[2][i] for f in frames)]
    assert len(high) > 20, f"only {len(high)} slots above 15 ever switch on"
    print(f"  U2E: ship on for {on} frames, {len(high)} high slots used  OK")


if __name__ == "__main__":
    if not SCENES.exists():
        sys.exit(f"missing {SCENES}")
    test_streams_decode_exactly()
    test_object_numbers_stay_in_range()
    test_sticky_onum_switches_the_ship_on()
    print("all extract_visu tests passed")
