import '../engine/asset_store.dart';
import '../engine/flic_clip.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Intro explosion — the "Praxis" shockwave (PAM/PRAX4.FLI, played by the
/// original PAM/OUTTAA.C). After the ship shrinks to a point it explodes: the
/// screen FLASHES WHITE as the blast begins, the shockwave rushes the viewer,
/// and the screen WHITES OUT into the demon-logo title.
///
/// Both flashes come straight from OUTTAA.C's `wfade[]` table: the displayed
/// palette is the frame's palette blended toward white by `wfade[f]/64`, one
/// step every 4 jiffies (@70Hz). `wfade[]` starts at 63 (full white), drops to
/// 0 over ~7 frames, holds, then ramps back up to 63 at the end.
class ExplosionPart extends Part {
  static const frameDur = 4.0 / 70.0; // OUTTAA.C waits 4 jiffies per step

  // OUTTAA.C wfade[] — white-blend amount (0..63) per animation step.
  static const List<int> _wfade = [
    63, 32, 16, 8, 4, 2, 1, 0, 0, 0, //
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
    1, 2, 4, 6, 9, 14, 20, 28, 37, 46, //
    56, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,
  ];

  final IndexedSurface _s = IndexedSurface(320, 200);
  late final FlicClip _clip;
  late final double duration;

  @override
  IndexedSurface get indexed => _s;

  @override
  void init() {
    _clip = AssetStore.flics['prax4']!;
    duration = _wfade.length * frameDur;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final f = (t / frameDur).floor();
    // OUTTAA.C draws animation frames only while f<=40, holding the last one.
    final frame = f.clamp(0, _clip.frameCount - 1);
    _clip.copyFrame(frame, _s);

    // Blend the frame palette toward white by wfade[f]/64 (start + end flash).
    final wf = _wfade[f.clamp(0, _wfade.length - 1)];
    if (wf > 0) {
      final white = VgaPalette.black();
      for (var c = 0; c < 256; c++) {
        white.setRgb(c, 63, 63, 63);
      }
      _s.palette = VgaPalette.lerp(_s.palette, white, wf / 64.0);
    }
  }
}
