import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/vga_palette.dart';

void main() {
  test('black palette maps every index to opaque black', () {
    final p = VgaPalette.black();
    expect(p.rgba8888(0), 0x000000FF);
    expect(p.rgba8888(255), 0x000000FF);
  });

  test('6-bit 63 scales to 8-bit 255', () {
    final p = VgaPalette.black()..setRgb(1, 63, 0, 32);
    expect(p.rgba8888(1) >> 24, 255);
    expect((p.rgba8888(1) >> 8) & 0xFF, (32 << 2) | (32 >> 4));
  });

  test('fromBytes requires 768 bytes', () {
    expect(() => VgaPalette.fromBytes(Uint8List(10)), throwsArgumentError);
  });

  test('lerp midpoint', () {
    final a = VgaPalette.black();
    final b = VgaPalette.black()..setRgb(5, 60, 60, 60);
    final mid = VgaPalette.lerp(a, b, 0.5);
    expect(mid.bytes[5 * 3], 30);
  });

  test('scaled(0) is black, scaled(1) is identity', () {
    final b = VgaPalette.black()..setRgb(2, 10, 20, 30);
    expect(b.scaled(0).rgba8888(2), 0x000000FF);
    expect(b.scaled(1).bytes[2 * 3 + 2], 30);
  });

  test('grayscale collapses channels to luma', () {
    final p = VgaPalette.black()..setRgb(3, 63, 0, 0);
    final g = p.grayscale();
    final e = g.bytes;
    expect(e[9], e[10]);
    expect(e[10], e[11]);
    expect(e[9], (0.299 * 63).round());
  });
}
