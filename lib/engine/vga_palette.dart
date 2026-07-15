import 'dart:typed_data';

/// VGA DAC palette: 256 entries, 6 bits per channel (0..63), as on the
/// original hardware (see Sanglard's review; original parts OUT to 0x3C8/9).
class VgaPalette {
  final Uint8List bytes; // 768 bytes, r,g,b per entry, 0..63

  VgaPalette.black() : bytes = Uint8List(768);

  VgaPalette.fromBytes(Uint8List b) : bytes = Uint8List.fromList(b) {
    if (b.length != 768) {
      throw ArgumentError('palette must be 768 bytes, got ${b.length}');
    }
  }

  static int _to8(int v6) => (v6 << 2) | (v6 >> 4);

  int rgba8888(int index) {
    final i = index * 3;
    return (_to8(bytes[i]) << 24) |
        (_to8(bytes[i + 1]) << 16) |
        (_to8(bytes[i + 2]) << 8) |
        0xFF;
  }

  void setRgb(int index, int r6, int g6, int b6) {
    final i = index * 3;
    bytes[i] = r6;
    bytes[i + 1] = g6;
    bytes[i + 2] = b6;
  }

  static VgaPalette lerp(VgaPalette a, VgaPalette b, double t) {
    final tt = t.clamp(0.0, 1.0);
    final out = VgaPalette.black();
    for (var i = 0; i < 768; i++) {
      out.bytes[i] = (a.bytes[i] + (b.bytes[i] - a.bytes[i]) * tt).round();
    }
    return out;
  }

  VgaPalette scaled(double t) => lerp(VgaPalette.black(), this, t);

  VgaPalette grayscale() {
    final out = VgaPalette.black();
    for (var i = 0; i < 256; i++) {
      final y = (0.299 * bytes[i * 3] +
              0.587 * bytes[i * 3 + 1] +
              0.114 * bytes[i * 3 + 2])
          .round();
      out.setRgb(i, y, y, y);
    }
    return out;
  }
}
