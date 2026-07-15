import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/interference_tables.dart';

/// Algorithmic checks only (project rule: no unit tests for rendered demo
/// effects — those are validated visually against the capture). This covers
/// the SRI2 decode + the 4-way mirroring, which must reproduce what TECHNO's
/// init_interference builds from `_CIRCLE.OBK` / `_CIRCLE2.OBK`.
void main() {
  late InterferenceTables t;

  setUpAll(() {
    final bytes = File('assets/tables/interference.srt').readAsBytesSync();
    t = InterferenceTables.decode(bytes);
  });

  test('ring fields mirror 4-way into a 640x400 field', () {
    expect(t.staticField.length, 640 * 400);
    expect(t.overlay.length, 640 * 400);
    // Three bitplanes -> eight shades; the overlay is a single plane.
    expect(t.staticField.toSet().toList()..sort(), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(t.overlay.toSet().toList()..sort(), [0, 1]);
    // bltlinerev mirrors about x=320, and the row 399-r pass about y=200.
    for (final (x, y) in [(50, 100), (17, 3), (300, 199)]) {
      expect(t.staticField[y * 640 + x], t.staticField[y * 640 + (639 - x)]);
      expect(t.staticField[y * 640 + x], t.staticField[(399 - y) * 640 + x]);
      expect(t.overlay[y * 640 + x], t.overlay[y * 640 + (639 - x)]);
    }
  });

  test('decode rejects a wrong magic', () {
    expect(() => InterferenceTables.decode(File('assets/tables/tunnel.srt')
        .readAsBytesSync()), throwsFormatException);
  });
}
