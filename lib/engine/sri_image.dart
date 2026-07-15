import 'dart:typed_data';
import 'vga_palette.dart';

/// Runtime loader for the .sri asset format produced by
/// tool/convert_assets.dart:
/// "SRI1" + u16le width + u16le height + 768-byte 6-bit palette + pixels.
class SriImage {
  final int width;
  final int height;
  final Uint8List pixels;
  final VgaPalette palette;

  SriImage._(this.width, this.height, this.pixels, this.palette);

  static SriImage decode(Uint8List bytes) {
    if (bytes.length < 776 ||
        bytes[0] != 0x53 ||
        bytes[1] != 0x52 ||
        bytes[2] != 0x49 ||
        bytes[3] != 0x31) {
      throw const FormatException('not an SRI1 image');
    }
    final d = ByteData.sublistView(bytes);
    final w = d.getUint16(4, Endian.little);
    final h = d.getUint16(6, Endian.little);
    final pal = VgaPalette.fromBytes(Uint8List.sublistView(bytes, 8, 776));
    final px = Uint8List.sublistView(bytes, 776, 776 + w * h);
    return SriImage._(w, h, px, pal);
  }
}
