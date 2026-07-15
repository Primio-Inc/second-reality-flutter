import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 4 — the "Second Reality" demon-logo title (BEG/SRTITLE.LBM, 320x400,
/// BEG.C). The screen starts fully white; the picture's palette then fades in
/// over 129 frames — each entry lerps straight from white to its real colour
/// (no grayscale step):
///   pal2[a] = ((128-c)*63 + realpal[a]*c) / 128,  c = 0..128
/// After the fade the real palette holds (the next part takes over; the
/// original does not fade the title out).
class TitlePart extends Part {
  static const _frames = 128; // c = 0..128
  static const _fadeDur = 129.0 / 70.0; // one dis_waitb() per step at ~70Hz

  late final IndexedSurface _s;
  late final VgaPalette _real;

  @override
  IndexedSurface get indexed => _s;

  @override
  void init() {
    final pic = AssetStore.images['srtitle']!;
    _s = IndexedSurface(pic.width, pic.height);
    _s.pixels.setAll(0, pic.pixels);
    _real = pic.palette;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final c = (t / _fadeDur * _frames).clamp(0.0, _frames.toDouble()).round();
    if (c >= _frames) {
      _s.palette = _real;
      return;
    }
    final out = VgaPalette.black();
    final r = _real.bytes;
    for (var a = 0; a < 768; a++) {
      out.bytes[a] = ((_frames - c) * 63 + r[a] * c) ~/ _frames;
    }
    _s.palette = out;
  }
}
