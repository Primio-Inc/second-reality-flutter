import 'dart:ui';
import '../engine/part.dart';
import '../engine/text_fx.dart';

/// Part 1 — "Alkutekstit I" (ALKU/MAIN.C): the movie-style credit cards that
/// fade in and out on black before the horizon scene. Exact text, line
/// positions (centred about x=160, rows in the 320x400 field) and order from
/// the original source. Rendered as smooth modern serif text (not the original
/// pixelated font) per the port's philosophy.
///
/// Each card in the original is `dofade(in); wait(300); dofade(out)` — 64 + 300
/// + 64 vertical retraces — kicked off by a `dis_sync()` code fired from the
/// music. So the DURATIONS are fixed (below) and only the START of each card is
/// music-driven. The starts are the sync times measured off the capture, whose
/// timeline is aligned to the soundtrack (tool/analyze_video.py --scan): each
/// card's linear fade-in ramp begins at these seconds, and the resulting
/// 6.11s card span matches the original's 428 retraces exactly.
class CreditsPart extends Part {
  // dis_sync cues 1-3 (MUSIC0 orders 2:0 / 3:0 / 3:47) resolved through the
  // tempo-120 row clock: 16.090 / 24.090 / 29.965s. These match the times
  // measured off the capture (16.07 / 24.04 / 30.19) to within a video frame.
  static const _cards = <_Card>[
    _Card(16.090, [
      CreditLine('A', 120),
      CreditLine('Future Crew', 160),
      CreditLine('Production', 200),
    ]),
    _Card(24.090, [
      CreditLine('First Presented', 160),
      CreditLine('at Assembly 93', 200),
    ]),
    // The original's third card is "in" + the Dolby logo glyphs (y=120, then
    // 160/179); this port replaces it with its own credit (user request). Two
    // rows on the same grid as the other cards, so it fades in through the very
    // same _cardSpan path — nothing here is special-cased.
    // It appears 1s after its music cue and leaves 0.5s earlier than a
    // full-length card would: the hold absorbs BOTH, so the fade-out still
    // lands where it must — clear of the horizon part's cue at 37.965.
    //   in  30.965 -> full 33.255 -> fade at 36.041 -> gone 36.955
    _Card(
      29.965 + 1.0,
      [
        CreditLine('Flutter Version', 160),
        CreditLine('by Team Primio', 200),
      ],
      fadeIn: 160 / kDemoFps, // 2.29s — a soft, slow entrance (ours, not FC's)
      hold: 300 / kDemoFps - 1.0 - 0.5,
    ),
  ];

  // dofade() = 64 retraces, wait(300) = 300 retraces (ALKU/MAIN.C).
  static const _fadeIn = 64 / kDemoFps; // 0.914s
  static const _hold = 300 / kDemoFps; // 4.286s
  static const _fadeOut = 64 / kDemoFps; // 0.914s

  /// Smoothstep: eases the ramp in and out instead of running it linearly.
  ///
  /// The original fades a PALETTE linearly, which is linear in light — but this
  /// text is white on pure black, and a linear alpha ramp there reads as a pop:
  /// the glyphs are already near-solid a third of the way in. (The horizon's
  /// cards use the identical 64-retrace ramp yet look softer, because they fade
  /// over a lit picture rather than out of black.) Same durations, gentler
  /// curve — a rendering choice, in the spirit of "modern visuals".
  static double _ease(double x) {
    final c = x.clamp(0.0, 1.0);
    return c * c * (3 - 2 * c);
  }

  // Exposed for tests: the currently visible lines and their fade level.
  List<CreditLine> activeLines = const [];
  double textAlpha = 0;

  // Pure black background (the demo view clears to black); text is drawn in the
  // vector layer.
  @override
  void update(double t, List<int> syncCodes) {
    activeLines = const [];
    textAlpha = 0;
    for (final c in _cards) {
      final fadeIn = c.fadeIn;
      final hold = c.hold;
      final span = fadeIn + hold + _fadeOut;
      final lt = t - c.start;
      if (lt < 0 || lt >= span) continue;
      if (lt < fadeIn) {
        textAlpha = _ease(lt / fadeIn);
      } else if (lt < fadeIn + hold) {
        textAlpha = 1;
      } else {
        textAlpha = _ease(1 - (lt - fadeIn - hold) / _fadeOut);
      }
      activeLines = c.lines;
      break;
    }
  }

  @override
  void paintVector(Canvas canvas, Size size) {
    for (final line in activeLines) {
      drawMovieText(canvas, size, line.text,
          yTopFrac: line.y / kIntroFieldH, alpha: textAlpha);
    }
  }
}

class _Card {
  final double start;
  final List<CreditLine> lines;

  /// Fade-in length, seconds. The original's cards all use dofade(64); only our
  /// own Primio card overrides it (it is not the demo's content, so a longer,
  /// softer entrance costs no fidelity).
  final double fadeIn;

  /// Hold length, seconds — how long the card sits at full brightness before it
  /// fades. wait(300) in the original; ours is shorter (see the Primio card).
  final double hold;
  const _Card(this.start, this.lines,
      {this.fadeIn = CreditsPart._fadeIn, this.hold = CreditsPart._hold});
}
