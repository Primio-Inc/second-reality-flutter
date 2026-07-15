#!/usr/bin/env python3
"""Bundle the end scroller's text.

Source: original/MAIN/DATA/ENDSCROL.TXT — the SHIPPED greetings file (the one
checked into ENDSCRL/ is the dev build's joke text plus a font test, and is not
what the demo scrolls).

It is CP437 (the codepage a 1993 DOS text editor wrote), so a couple of Finnish
names carry high bytes; decode it as CP437 and write UTF-8, which is what the
Dart side reads.

The file's own markup, worked out from the capture (the vendored ENDSCRL/MAIN.C
is an older build and has neither the control lines nor the right font metrics —
see lib/parts/p20_endscroll.dart):

  * a text line advances the scroll by 25 rows (the shipped font's height),
  * a line of the form `[N` is a CONTROL line: it advances N rows and prints
    nothing. The file uses [8, [10, [12 and [15 to tighten the spacing inside
    the sponsor and BBS lists.

The original's own text is NOT rewritten — its markup is interpreted at runtime,
and this script only fixes the encoding. The one addition is PORT_HEADER below,
prepended so the scroller opens by saying who made this port before it hands over
to Future Crew's own credits. It lives here rather than in the checked-in asset
because the asset is GENERATED: edit it there and the next run of this script
silently throws it away.

Keep added lines <= 41 characters (the widest line the original uses, and what
fits the 640px field centred), and remember every line — blank ones included —
costs 25 rows of scroll, which is 0.714s at 35 rows/s.

Usage: python3 tool/convert_endscroll.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "original/MAIN/DATA/ENDSCROL.TXT"
OUT = ROOT / "assets/text/endscrol.txt"

# Ours, not Future Crew's.
#
# Two things this stanza has to get RIGHT, because the screen is where people
# will read it:
#   * "AI-powered conversion" is true but easy to misread as "an AI regenerated
#     the demo". It did not. The Dart is NEW code, written from the original's C,
#     assembly and Pascal — so do not say "the code is theirs", which is the
#     opposite of the truth.
#   * What IS theirs is Second Reality itself: the design, the algorithms, the
#     data. No ownership of it is claimed here, and the scroller says so.
PORT_HEADER = """\
Second Reality Flutter Port

July 2026 by Team Primio

primio.dev

AI-powered conversion.


Rewritten in Dart from the original
C, assembly and Pascal, and built as
a demonstration of Flutter running
everywhere from a single codebase.


Second Reality is Future Crew's work.
No ownership of it is claimed here.


The original 1993 credits follow.

---

"""


def main():
    text = PORT_HEADER + SRC.read_bytes().decode("cp437")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    lines = text.split("\n")
    ctrl = [ln for ln in lines if ln.startswith("[")]
    print(f"{OUT}: {len(lines)} lines ({len(ctrl)} control lines)")


if __name__ == "__main__":
    main()
