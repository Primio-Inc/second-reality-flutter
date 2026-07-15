#!/usr/bin/env python3
"""Regenerate reference/commentary.md from lib/commentary_script.dart.

The Dart file is the SOURCE OF TRUTH: it is what ships. This doc exists so the
commentary can be read and edited as prose, and generating it means the review
copy can never drift from the copy the viewer actually sees.

    python3 tool/dump_commentary.py

Also lints the copy for em dashes, which we do not use.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
DART = ROOT / 'lib' / 'commentary_script.dart'
OUT = ROOT / 'reference' / 'commentary.md'

# CommentaryCard(<time>, '<title>', '<body...>' ...),
CARD = re.compile(
    r"CommentaryCard\(\s*([\d.]+)\s*,\s*'((?:[^'\\]|\\.)*)'\s*,\s*(.*?),?\s*\),",
    re.S,
)
PIECE = re.compile(r"'((?:[^'\\]|\\.)*)'")


def unescape(s: str) -> str:
    # \n is a real paragraph break in a card (the panel's Text renders it), so
    # it has to become one here too, or the doc shows a literal backslash-n.
    return (s.replace("\\'", "'")
             .replace('\\n', '\n')
             .replace('\\\\', '\\'))


def main() -> int:
    src = DART.read_text()
    cards = []
    for m in CARD.finditer(src):
        time = float(m.group(1))
        title = unescape(m.group(2))
        body = ''.join(unescape(p) for p in PIECE.findall(m.group(3)))
        cards.append((time, title, body))

    if not cards:
        print('no cards parsed; did the Dart layout change?', file=sys.stderr)
        return 1

    bad = [t for _, t, b in cards if '—' in t or '—' in b]
    if bad:
        print(f'em dash found in: {bad}', file=sys.stderr)
        return 1

    lines = [
        '# Live Commentary',
        '',
        '**GENERATED from `lib/commentary_script.dart` by '
        '`tool/dump_commentary.py`. Edit the Dart, not this file.**',
        '',
        'The (i) button turns the demo into a documentary. Cards are keyed to '
        'the music clock (the same clock every part uses, so the commentary '
        'cannot drift), and the panel is a running transcript that SCROLLS: '
        'each card is appended at the bottom and the column eases up, so a slow '
        'reader never loses a card to a page flip and can scroll back at any '
        'time.',
        '',
        'The spine of the script is one idea: **the demo is not computing what '
        'you see, it is looking it up.** Refraction, occlusion, camera paths, '
        'bounce physics and even the water were baked offline in 1993; at run '
        'time the CPU mostly copies memory.',
        '',
        f'{len(cards)} cards.',
        '',
    ]
    for time, title, body in cards:
        mins, secs = divmod(time, 60)
        lines.append(f'### {time:g}s ({int(mins)}:{secs:04.1f}) · {title}')
        lines.append('')
        lines.append(body)
        lines.append('')

    OUT.write_text('\n'.join(lines))
    print(f'wrote {OUT.relative_to(ROOT)} ({len(cards)} cards)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
