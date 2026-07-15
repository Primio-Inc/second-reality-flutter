import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/indexed_surface.dart';
import 'package:second_reality/engine/vga_palette.dart';

void main() {
  test('clear fills, setPixel clips', () {
    final s = IndexedSurface(4, 3)..clear(7);
    expect(s.pixels.every((p) => p == 7), isTrue);
    s.setPixel(-1, 0, 1); // no throw
    s.setPixel(0, 99, 1);
    s.setPixel(2, 1, 9);
    expect(s.getPixel(2, 1), 9);
  });

  test('toRgbaBytes uses palette', () {
    final s = IndexedSurface(2, 1);
    s.palette = VgaPalette.black()..setRgb(1, 63, 0, 0);
    s.setPixel(1, 0, 1);
    final rgba = s.toRgbaBytes();
    expect(rgba.length, 8);
    expect(rgba[0], 0); // pixel 0 black
    expect(rgba[4], 255); // pixel 1 red
    expect(rgba[7], 255); // alpha
  });

  test('blit clips and honors transparency', () {
    final s = IndexedSurface(4, 4)..clear(0);
    final src = Uint8List.fromList([1, 0, 2, 3]); // 2x2, 0 transparent
    s.blit(src, 2, 2,
        srcX: 0, srcY: 0, dstX: 3, dstY: 3, w: 2, h: 2, transparent: 0);
    expect(s.getPixel(3, 3), 1); // rest clipped off-surface
    final s2 = IndexedSurface(4, 4)..clear(9);
    s2.blit(src, 2, 2,
        srcX: 0, srcY: 0, dstX: 0, dstY: 0, w: 2, h: 2, transparent: 0);
    expect(s2.getPixel(1, 0), 9); // transparent pixel left background
    expect(s2.getPixel(0, 1), 2);
  });
}
