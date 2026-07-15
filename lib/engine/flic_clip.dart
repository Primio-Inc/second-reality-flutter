import 'dart:typed_data';
import 'indexed_surface.dart';
import 'vga_palette.dart';

/// A decoded FLIC animation loaded from the .sfl asset produced by
/// tool/extract_flic.py (the intro Praxis explosion, PAM/PRAX4.FLI). Frames are
/// stored fully expanded (indexed pixels + a 6-bit palette each).
///
/// Format (little-endian): "SFL1" | u16 w | u16 h | u16 frameCount |
///   per frame: 768-byte 6-bit palette + w*h index bytes.
class FlicClip {
  final int width;
  final int height;
  final List<VgaPalette> palettes;
  final List<Uint8List> frames;

  FlicClip(this.width, this.height, this.palettes, this.frames);

  int get frameCount => frames.length;

  static FlicClip decode(Uint8List bytes) {
    if (bytes.length < 10 ||
        bytes[0] != 0x53 || bytes[1] != 0x46 || bytes[2] != 0x4C ||
        bytes[3] != 0x31) {
      throw const FormatException('not an SFL1 clip');
    }
    final d = ByteData.sublistView(bytes);
    final w = d.getUint16(4, Endian.little);
    final h = d.getUint16(6, Endian.little);
    final count = d.getUint16(8, Endian.little);
    final palettes = <VgaPalette>[];
    final frames = <Uint8List>[];
    var o = 10;
    for (var i = 0; i < count; i++) {
      palettes.add(VgaPalette.fromBytes(Uint8List.sublistView(bytes, o, o + 768)));
      o += 768;
      frames.add(Uint8List.fromList(Uint8List.sublistView(bytes, o, o + w * h)));
      o += w * h;
    }
    return FlicClip(w, h, palettes, frames);
  }

  /// Copy frame [i] (pixels and palette) into [s] (must match dimensions).
  void copyFrame(int i, IndexedSurface s) {
    final f = i.clamp(0, frameCount - 1);
    s.pixels.setAll(0, frames[f]);
    s.palette = VgaPalette.fromBytes(palettes[f].bytes);
  }
}
