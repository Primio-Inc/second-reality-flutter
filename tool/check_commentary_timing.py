#!/usr/bin/env python3
"""Can the commentary actually be READ in the time it is on screen?

The panel is a transcript, so a card appends and the next one pushes it up. A
card's DWELL is therefore the gap to the next card: that is how long it is the
current card, at the bottom, where the reader is looking.

The audience is not all native English speakers and the vocabulary is
technical, so the budget is WPM = 130 -- slower than the ~200-250 wpm of a
native reader skimming familiar prose. A card whose words need longer than its
dwell is one the reader cannot finish before the next one arrives.

THIS IS A VOLUME CONSTRAINT, NOT A SCHEDULING ONE. The whole script must fit
into the demo's run time: sum(words)/WPM*60 <= kDemoEnd. No reordering can
create room that is not there.

Usage: python3 tool/check_commentary_timing.py [--verbose]
Exit code 1 if any card is unreadable in its dwell.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "lib/commentary_script.dart"

WPM = 130
DEMO_END = 982.6  # DemoView.kDemoEnd

# A card may run slightly past its dwell: the previous card stays on screen
# above the current one (fading, but legible), so a small overrun is read in
# the next card's window rather than lost. Beyond this it reads as a card that
# vanished mid-sentence.
GRACE = 2.0


def cards() -> list[tuple[float, str, str]]:
    src = SCRIPT.read_text()
    out = []
    for m in re.finditer(
        r"CommentaryCard\(\s*([\d.]+),\s*\n?\s*'((?:[^'\\]|\\.)*)',\s*(.*?),\s*\)",
        src,
        re.S,
    ):
        body = "".join(re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(3)))
        out.append((float(m.group(1)), m.group(2).replace("\\'", "'"),
                    body.replace("\\'", "'")))
    out.sort()
    return out


def main() -> None:
    verbose = "--verbose" in sys.argv
    cs = cards()
    total_words = sum(len(t.split()) + len(b.split()) for _, t, b in cs)
    budget = total_words / WPM * 60

    bad = []
    if verbose:
        print(f"{'t':>7} {'dwell':>6} {'words':>5} {'need':>6} {'slack':>7}  title")
    for i, (t, title, body) in enumerate(cs):
        nxt = cs[i + 1][0] if i + 1 < len(cs) else DEMO_END
        dwell = nxt - t
        words = len(title.split()) + len(body.split())
        need = words / WPM * 60
        slack = dwell - need
        if verbose:
            flag = "  <-- TOO FAST" if slack < -GRACE else ""
            print(f"{t:7.1f} {dwell:6.1f} {words:5d} {need:6.1f} {slack:+7.1f}  "
                  f"{title}{flag}")
        if slack < -GRACE:
            bad.append((slack, t, title, words, dwell))

    print(f"\n{len(cs)} cards, {total_words} words.")
    print(f"reading time at {WPM} wpm: {budget:.0f}s of the demo's {DEMO_END:.0f}s "
          f"({budget / DEMO_END * 100:.0f}%)")

    if bad:
        bad.sort()
        print(f"\n{len(bad)} card(s) cannot be read in time:")
        for slack, t, title, words, dwell in bad:
            print(f"  {t:7.1f}  {title:34} {words:3d} words in {dwell:5.1f}s "
                  f"(short by {-slack:5.1f}s)")
        sys.exit(1)
    print("\nevery card is readable in its dwell at %d wpm" % WPM)


if __name__ == "__main__":
    main()
