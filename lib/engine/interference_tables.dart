import 'dart:typed_data';

/// The two concentric-ring bitmaps the interference part scrolls (TECHNO,
/// `_CIRCLE.OBK` / `_CIRCLE2.OBK`), bundled verbatim — see
/// tool/convert_circles.py for provenance.
///
/// Format ('SRI2'): 24000 bytes `_circle` (200 rows x 3 planes x 40 bytes,
/// ROW-INTERLEAVED) then 8000 bytes `_circle2` (200 rows x 40 bytes).
///
/// Both are a 320x200 QUARTER of the ring field. `init_interference` mirrors
/// each one 4-way into a 640x400 field — `bltline` lays the row down normally
/// in the left half, `bltlinerev` lays it down byte- and bit-reversed in the
/// right half, and both are repeated at row 399-r. So the field is mirrored
/// about x=320 and y=200, putting the rings' centre in the middle. We do the
/// same mirroring here, once, at load.
class InterferenceTables {
  /// 640x400, one byte per pixel, value 0..7 — the static ring field. Its
  /// three bitplanes are the low three bits of the 16-colour index.
  final Uint8List staticField;

  /// 640x400, one byte per pixel, 0 or 1 — the moving ring overlay. It becomes
  /// bit 3 of the colour index, i.e. it selects between the two palette banks.
  final Uint8List overlay;

  static const int width = 640;
  static const int height = 400;

  InterferenceTables({required this.staticField, required this.overlay});

  static InterferenceTables decode(Uint8List bytes) {
    if (bytes.length < 5 ||
        bytes[0] != 0x53 ||
        bytes[1] != 0x52 ||
        bytes[2] != 0x49 ||
        bytes[3] != 0x32) {
      throw const FormatException('not an SRI2 interference table');
    }
    const o = 5;
    final sq = Uint8List.sublistView(bytes, o, o + 24000);
    final oq = Uint8List.sublistView(bytes, o + 24000, o + 24000 + 8000);

    // Row y of the 3-plane quarter is plane0(40B), plane1(40B), plane2(40B).
    int staticPx(int x, int y) {
      final base = y * 120, byte = x >> 3, bit = 7 - (x & 7);
      return (sq[base + byte] >> bit & 1) |
          (sq[base + 40 + byte] >> bit & 1) << 1 |
          (sq[base + 80 + byte] >> bit & 1) << 2;
    }

    int overlayPx(int x, int y) =>
        oq[y * 40 + (x >> 3)] >> (7 - (x & 7)) & 1;

    Uint8List mirror(int Function(int, int) px) {
      final f = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        final sy = y < 200 ? y : 399 - y;
        final row = y * width;
        for (var x = 0; x < width; x++) {
          f[row + x] = px(x < 320 ? x : 639 - x, sy);
        }
      }
      return f;
    }

    return InterferenceTables(
      staticField: mirror(staticPx),
      overlay: mirror(overlayPx),
    );
  }
}
