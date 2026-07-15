import 'dart:ui';

import '../engine/asset_store.dart';
import '../engine/part.dart';
import '../engine/text_fx.dart';

/// Part 20 — the end scroller (`ENDSCRL.EXE`), the last thing the demo does.
///
/// A vertical scroller on black: the greetings from `MAIN/DATA/ENDSCROL.TXT`
/// walk up the screen forever (the original only stops on a keypress).
///
/// HOW THE ORIGINAL DOES IT (ENDSCRL/MAIN.C): the screen is a 401-row ring
/// buffer in a 400-row display (CRTC max-scan-line 0, so one memory row per
/// scanline). Each pass writes ONE font row of the current text line at ring row
/// `yscrl` (and again at `yscrl+401`, so the ring wraps seamlessly), bumps
/// `yscrl`, and moves the display start down one row with `setstart()`. So a
/// pass = one scanline of scroll, and a text line takes as many passes as the
/// font is tall.
///
/// The pass rate is `if (dis_waitb() == 1) dis_waitb();` — if only one retrace
/// had elapsed, burn another. So it advances ONE ROW PER TWO RETRACES = 35
/// rows/s, and the capture agrees exactly: 35.1 rows/s, measured by
/// cross-correlating the scroll across a 5s baseline.
///
/// THE VENDORED SOURCE IS NOT WHAT SHIPPED. `ENDSCRL/MAIN.C` is an older build:
/// it has the joke text hard-coded, a font test, `FONAY = 30`, and no notion of
/// the control lines the shipped `ENDSCROL.TXT` is full of. Two things therefore
/// come from MEASURING the capture instead (see tool/convert_endscroll.py):
///
///   * the font is 25 rows tall, not 30 — consecutive text lines are 25.0 rows
///     apart on screen (measured off the row profile, in the 400-row field);
///   * a line of the form `[N` is a CONTROL line: it prints nothing and advances
///     the scroll by N rows. The file uses [8, [10, [12 and [15. A text line
///     followed by `[12` puts the next line 37 rows down, which is exactly the
///     pitch the capture shows in the greetings list.
///
/// Fitting that model's line lattice against the capture's text bands at 760s,
/// 820s and 890s puts the first row at capture 653.05 (all three agree to 0.1s).
///
/// The glyphs are the modern vector font, not the original FONA bitmap — the
/// project renders all text that way (the porting notes), and here it is also what the
/// user asked for.
class EndScrollPart extends Part {
  /// The display is 400 rows; the text is centred in a 640-wide field.
  static const int fieldRows = 400;

  /// One row per two retraces.
  static const double rowsPerSecond = kDemoFps / 2; // 35

  /// The shipped font's height, in rows — MEASURED (see the class doc).
  static const int fonaY = 25;

  List<_Line> _lines = const [];
  double _scroll = 0; // rows scrolled so far

  @override
  void init() {
    final text = AssetStore.endScrollText;
    if (text == null) return;
    final out = <_Line>[];
    var row = 0;
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      // `%` ON ITS OWN IS THE END-OF-TEXT MARKER, not a character to scroll. It
      // occurs exactly once in the shipped file, after the last greeting and
      // before nothing but blank lines, and we were faithfully scrolling a lone
      // percent sign up the screen 20 seconds after the music had stopped.
      if (line.trim() == '%') break;
      if (line.startsWith('[')) {
        // A control line: advance N rows, print nothing.
        final n = int.tryParse(line.substring(1).trim());
        row += n ?? fonaY;
        continue;
      }
      if (line.trim().isNotEmpty) out.add(_Line(line.trim(), row));
      row += fonaY;
    }
    _lines = out;
  }

  @override
  void update(double t, List<int> syncCodes) {
    _scroll = t * rowsPerSecond;
  }

  @override
  void paintVector(Canvas canvas, Size size) {
    if (_lines.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    for (final line in _lines) {
      // The line's top row enters at the bottom of the screen (row 400) and
      // walks up one row per pass.
      final row = line.row - _scroll + fieldRows;
      if (row <= -fonaY || row >= fieldRows) continue;
      drawMovieText(canvas, size, line.text,
          yTopFrac: row / fieldRows,
          alpha: 1,
          heightFrac: fonaY / fieldRows);
    }
    canvas.restore();
  }
}

class _Line {
  final String text;

  /// The scroll row this line's cell starts at.
  final int row;
  const _Line(this.text, this.row);
}
