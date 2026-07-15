import 'dart:typed_data';
import 'vga_palette.dart';

/// A VGA-style indexed framebuffer (default 320x200, 320x400 for the
/// double-scanned picture parts).
class IndexedSurface {
  final int width;
  final int height;
  final Uint8List pixels;
  VgaPalette palette = VgaPalette.black();

  IndexedSurface(this.width, this.height) : pixels = Uint8List(width * height);

  void clear(int color) => pixels.fillRange(0, pixels.length, color);

  void setPixel(int x, int y, int color) {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    pixels[y * width + x] = color;
  }

  int getPixel(int x, int y) => pixels[y * width + x];

  void blit(Uint8List src, int srcW, int srcH,
      {required int srcX,
      required int srcY,
      required int dstX,
      required int dstY,
      required int w,
      required int h,
      int transparent = -1}) {
    for (var row = 0; row < h; row++) {
      final sy = srcY + row, dy = dstY + row;
      if (sy < 0 || sy >= srcH || dy < 0 || dy >= height) continue;
      for (var col = 0; col < w; col++) {
        final sx = srcX + col, dx = dstX + col;
        if (sx < 0 || sx >= srcW || dx < 0 || dx >= width) continue;
        final p = src[sy * srcW + sx];
        if (p == transparent) continue;
        pixels[dy * width + dx] = p;
      }
    }
  }

  Uint8List toRgbaBytes() {
    final out = Uint8List(width * height * 4);
    final lut = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      lut[i] = palette.rgba8888(i);
    }
    var o = 0;
    for (var i = 0; i < pixels.length; i++) {
      final c = lut[pixels[i]];
      out[o++] = c >>> 24;
      out[o++] = (c >>> 16) & 0xFF;
      out[o++] = (c >>> 8) & 0xFF;
      out[o++] = 0xFF;
    }
    return out;
  }
}
