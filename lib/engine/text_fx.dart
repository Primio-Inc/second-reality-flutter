import 'package:flutter/material.dart';

/// The intro renders in Mode X 320x400 (ALKU tweak mode). Text positions from
/// the original source are given in that field; map a source row to a viewport
/// fraction by dividing by this height.
const double kIntroFieldH = 400.0;

/// One centred credit line at source row [y] (in the 320x400 intro field).
class CreditLine {
  final String text;
  final int y;
  const CreditLine(this.text, this.y);
}

/// Draws smooth, anti-aliased movie-credit text (modern vector font) centred
/// at [centerXFrac], with the glyph top near [yTopFrac] of the viewport.
///
/// Per the port's "true code, modern visuals" philosophy: positions/timing come
/// from the original source, but the glyphs are a modern serif rendered by the
/// text engine rather than the original pixelated bitmap font.
void drawMovieText(
  Canvas canvas,
  Size size,
  String text, {
  required double yTopFrac,
  required double alpha,
  double centerXFrac = 0.5,
  double heightFrac = 0.082,
}) {
  final a = alpha.clamp(0.0, 1.0);
  if (a <= 0.0 || text.isEmpty) return;
  final fontSize = size.height * heightFrac;
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: Color.fromRGBO(255, 255, 255, a),
        fontSize: fontSize,
        fontFamily: 'Credits', // bundled EB Garamond (serif movie font)
        fontWeight: FontWeight.w500,
        letterSpacing: fontSize * 0.06,
        height: 1.0,
      ),
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout();
  final x = size.width * centerXFrac - tp.width / 2;
  // TextPainter's top includes ascent leading; nudge up so the cap-top sits
  // near yTopFrac.
  final y = size.height * yTopFrac - fontSize * 0.15;
  tp.paint(canvas, Offset(x, y));
}
