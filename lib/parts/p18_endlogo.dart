import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 18 — the END logo (`ENDLOGO.EXE` = END/END.C): the Future Crew rings,
/// faded up out of the white the vector part left behind.
///
/// END.C is short and does exactly four things:
///
///   1. Blank to WHITE (it OUTs 63 to every DAC entry, twice, around the mode
///      set) and wait 32 retraces. That is the white the fly-through's exit fade
///      hands over.
///   2. Blit `PIC.LBM` — a 320x400 chunky PBM (`NUTS.LBM` is a byte-identical
///      copy) — through `lineblit` into the unchained 320x400 mode. Nothing is
///      visible yet: the DAC is still all-white.
///   3. Fade white -> the picture's own palette over 129 retraces:
///      `pal2[a] = ((128-c)*63 + palette[a]*c) / 128` for c = 0..128.
///   4. Hold until `dis_musplus() > -16`, then fade to black over 64 retraces:
///      `pal2[a] = palette[a]*c/64` for c = 63..0.
///
/// The capture confirms all of it: the white hold runs 535.80-536.30, the
/// fade-in 536.30-538.10 (1.80s = 126 retraces, vs the code's 129), the hold to
/// 543.43, and the fade-out 543.43-544.30 (0.87s = 61 retraces, vs 64).
///
/// TIMING. The hold ends on `dis_musplus()`, which is STMIK zone state and
/// cannot be derived from anything that shipped (see the porting notes), so [kFadeOutAt]
/// is MEASURED off the capture's own luma — the fade is linear, which pins its
/// first frame.
class EndLogoPart extends Part {
  /// `for(a=0;a<32;a++) dis_waitb();` — the white hold before the picture.
  static const double _whiteHold = 32 / kDemoFps; // 0.457s

  /// The white -> colour fade: c = 0..128, one step per retrace.
  static const double _fadeIn = 129 / kDemoFps; // 1.843s

  /// The fade to black: c = 63..0, one step per retrace.
  static const double _fadeOut = 64 / kDemoFps; // 0.914s

  /// Part-local time at which the fade to black starts (the `dis_musplus() >
  /// -16` gate). Capture 543.43 -> 543.63 in soundtrack time, and the part
  /// starts at 536.03.
  static const double kFadeOutAt = 7.60;

  static double get duration => kFadeOutAt + _fadeOut;

  final IndexedSurface _s = IndexedSurface(320, 400);
  VgaPalette _pic = VgaPalette.black();

  @override
  IndexedSurface? get indexed => _s;

  @override
  void init() {
    final pic = AssetStore.images['fcrings'];
    if (pic != null) {
      _s.pixels.setAll(0, pic.pixels);
      _pic = VgaPalette.fromBytes(pic.palette.bytes);
    }
    _s.palette = _white();
  }

  static VgaPalette _white() {
    final p = VgaPalette.black();
    p.bytes.fillRange(0, 768, 63);
    return p;
  }

  @override
  void update(double t, List<int> syncCodes) {
    if (t < _whiteHold) {
      _s.palette = _white();
      return;
    }
    if (t < _whiteHold + _fadeIn) {
      // `pal2[a] = ((128-c)*63 + palette[a]*c) / 128` — a straight lerp from a
      // full-white DAC to the picture's own.
      final c = ((t - _whiteHold) * kDemoFps).clamp(0.0, 128.0);
      _s.palette = VgaPalette.lerp(_white(), _pic, c / 128.0);
      return;
    }
    if (t < kFadeOutAt) {
      _s.palette = _pic;
      return;
    }
    // `pal2[a] = palette[a]*c/64` for c = 63..0.
    final k = ((t - kFadeOutAt) / _fadeOut).clamp(0.0, 1.0);
    _s.palette = _pic.scaled(1.0 - k);
  }
}
