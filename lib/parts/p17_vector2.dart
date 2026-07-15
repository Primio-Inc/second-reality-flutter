import 'dart:typed_data';
import 'dart:ui';

import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';
import '../engine/visu_renderer.dart';
import '../engine/visu_scene.dart';

/// Part 17 — the city fly-through (`U2E.EXE`, built from VISU/C/U2E.C over the
/// compiled scene `VISU/C/SCENE/U2E.*`): 42 objects in 58 `co[]` slots, a
/// 1801-frame animation stream, and the 3D "Future Crew" logo at the end of it.
///
/// It is the same VISU engine as the intro flyover, so the whole pipeline is
/// shared ([VisuRenderer]). What U2E does differently, and what this part
/// therefore has to carry, is all in U2E.C:
///
///  - THE HAND-OFF FROM THE JELLYPIC. U2E does not clear the screen: it reads
///    the DAC back (`jellywas`) and fades what is already there — the jellypic —
///    UP to white over 33 retraces (`fpal[a] += 2`), waits 16, writes its own
///    background into all four pages (`fadeset`: white inside the 25..174 draw
///    window, black above and below), waits 16, then fades every colour but the
///    window's back DOWN over another 33. 98 retraces, and the capture agrees:
///    two linear luma ramps at 480.20-480.60 and 481.15-481.60 with a hold
///    between them, then a white hold.
///
///  - THE START IS A MUSIC CUE. `while(!dis_exit()) { muscode 6; if (cx > 18)
///    break; }` — cx is the ORDER, so the vectors wait for MUSIC0 to reach order
///    19. The demo restarted MUSIC0 at order 18 for the ending, so that is the
///    very next order: 483.12s on the row clock.
///
///  - THE STREAM RUNS AT 35 Hz, NOT 70. U2E is far too heavy to draw every
///    retrace, so it quad-buffers: `copper2` displays a finished page and holds
///    it for as many retraces as it took, while the main loop advances
///    `currframe` by `repeat*2` and parses `repeat` stream frames. In steady
///    state currframe tracks the retrace counter, so the stream is consumed at
///    ONE frame per TWO retraces. 1801 frames = 51.5s, and the capture's
///    fly-through runs 484.2 -> 535.4. (At 70 Hz it would be over by 510.)
///
///  - TWO DRAW-ORDER OVERRIDES, straight out of U2E.C's sort loop:
///    objects whose name starts with `_` (the ground plates and platforms) get
///    `dist = 1000000000` so they always sort to the BACK, and while
///    `currframe` is in (1800, 2200) — stream frames 900..1100 — the `s01` ship
///    gets `dist = 1` so it sorts to the FRONT, in front of the buildings it is
///    flying past.
///
///  - THE EXIT is a white-out: 16 retraces of `fpal[a] += 4`. The END logo part
///    fades up out of that white.
///
/// SMOOTHNESS: the stream is sampled at a FRACTIONAL frame (see
/// [VisuRenderer.sample]), so the 35 Hz motion is interpolated up to the
/// display's refresh rate. At every integer frame the pose is still exactly what
/// the stream says.
class Vector2Part extends Part {
  /// The jellypic hand-off, in retraces (U2E.C's fade block).
  static const int _fadeUp = 33; // jellypic -> white
  static const int _hold1 = 16;
  static const int _hold2 = 16;
  static const int _fadeDown = 33; // -> the white draw window on black
  static const int _introRetraces = _fadeUp + _hold1 + _hold2 + _fadeDown; // 98

  /// The stream advances one frame per TWO retraces (the quad-buffer's steady
  /// state — see the class doc).
  static const double _streamFps = kDemoFps / 2; // 35

  /// Part-local time of the stream's frame 0. The cue (MUSIC0 order 19 =
  /// 483.12s = 2.72s local) starts the loop, but the four pages still hold
  /// `fadeset`'s white, so the display lags by the copper's 16-retrace delay
  /// plus the first page rotations.
  ///
  /// MEASURED. The escort ship carries an orange core, so counting orange pixels
  /// per capture frame gives a 1-D "how close is the ship" signal.
  /// Cross-correlating that against the ship's projected size, computed straight
  /// from the stream, pins the RATE beyond doubt: r = 0.86 at 35 fps and
  /// collapses at every other rate (0.49 at 34, 0.40 at 36, 0.04 at 70). That is
  /// the quad-buffer's one-frame-per-two-retraces.
  ///
  /// The same fit puts frame 0 at capture 484.7, while matching individual
  /// frames against the capture (the windowed wall the ship crosses at 486.3,
  /// the ship's close pass at 516.0) puts it at 484.2 and 484.4. The spread is
  /// the copper's own display lag — a page is shown for as many retraces as it
  /// took to draw, so what is ON SCREEN trails the animation clock by a varying
  /// few frames. We take the middle: capture 484.40 -> 484.60 in soundtrack time
  /// = 4.20s local, good to about a tenth of a second either way.
  static const double kVectorsAt = 4.20;

  /// Part-local time the exit white-out starts. The stream would run to frame
  /// 1800 (local 55.96), but the capture's white-out ramp begins at 535.567 ->
  /// 535.767 = 55.37s local, so the demo never shows the stream's last ~20
  /// frames (where the camera pulls back off the logo). We stop where it did.
  static const double kWhiteOutAt = 55.37;

  /// The exit white-out: `for(b=0;b<16;b++) fpal[a] += 4`.
  static const double _exitFade = 16 / kDemoFps;

  final IndexedSurface _s = IndexedSurface(320, 400);
  late final Uint8List _jelly; // the settled jellypic, as it is handed over
  late final Uint8List _frame; // fadeset's background
  late final VgaPalette _jellyPal;

  VisuRenderer? _scene;
  double _frameNo = 0;
  double _whiteout = 0; // 0..1 — the exit fade

  /// The part is over once the exit white-out has finished.
  static double get duration => kWhiteOutAt + _exitFade;

  @override
  IndexedSurface? get indexed => _s;

  @override
  void init() {
    final scene = AssetStore.scenes['u2e'];
    if (scene != null) {
      _scene = VisuRenderer(scene, distOf: _sortOverride);
    }

    // The jellypic as JPLOGO leaves it: the spring has settled, so the picture
    // is at full height and its rows are unwarped — JP.C's zoom at width 184
    // maps screen column x in [68, 252] to source column x - 68 of the 185-byte
    // strip it copies out of columns 70..253.
    _jelly = Uint8List(320 * 400);
    final pic = AssetStore.images['icekngdm'];
    if (pic != null) {
      for (var y = 0; y < 400; y++) {
        for (var x = 68; x <= 252; x++) {
          final sx = x - 68 + 70;
          if (sx < pic.width) {
            _jelly[y * 320 + x] = pic.pixels[y * pic.width + sx];
          }
        }
      }
      _jellyPal = VgaPalette.fromBytes(pic.palette.bytes);
    } else {
      _jellyPal = VgaPalette.black();
    }

    // fadeset: white inside the draw window (320x200 rows 25..174, i.e. rows
    // 50..349 of this double-scanned field), black above and below.
    _frame = Uint8List(320 * 400);
    for (var y = 50; y < 350; y++) {
      _frame.fillRange(y * 320, y * 320 + 320, _cWindow);
    }
  }

  // Palette slots we own for the hand-off. The original uses the VGA's own
  // 252..255 for exactly this (fadeset writes 252/253/254 and vid_setpal then
  // forces 252/255 black and 253/254 white).
  static const int _cBlack = 0;
  static const int _cWindow = 254;

  /// U2E.C's sort loop, verbatim.
  int _sortOverride(int slot, VisuMesh mesh, int dist, double frame) {
    // `co[a].o->name[1] == '_'` — name[0] is 3DS's opening quote.
    if (mesh.name.startsWith('_')) return 1000000000;
    // `if (currframe > 900*2 && currframe < 1100*2)` — currframe counts
    // RETRACES (two per stream frame), so this is stream frames 900..1100.
    if (frame > 900 && frame < 1100 && mesh.name.startsWith('s01')) return 1;
    return dist;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final r = t * kDemoFps; // retraces since the part started

    if (r < _introRetraces) {
      _paintHandoff(r);
      _frameNo = -1;
      return;
    }

    // From here the screen is the draw window: black, with the vectors painted
    // over it in the vector layer.
    _s.pixels.fillRange(0, _s.pixels.length, _cBlack);
    _s.palette = VgaPalette.black();

    final last = (_scene?.frameCount ?? 1) - 1;
    _frameNo =
        ((t - kVectorsAt) * _streamFps).clamp(0.0, last.toDouble());
    _whiteout = t <= kWhiteOutAt
        ? 0.0
        : ((t - kWhiteOutAt) / _exitFade).clamp(0.0, 1.0);
  }

  /// The 98-retrace hand-off from the jellypic.
  void _paintHandoff(double r) {
    if (r < _fadeUp + _hold1) {
      // The jellypic, its DAC walked up to white: `fpal[a] += 2` per retrace,
      // clamped at 63.
      _s.pixels.setAll(0, _jelly);
      final add = (2 * r).floor();
      final pal = VgaPalette.black();
      for (var i = 0; i < 768; i++) {
        final v = _jellyPal.bytes[i] + add;
        pal.bytes[i] = v > 63 ? 63 : v;
      }
      _s.palette = pal;
      return;
    }
    // fadeset has run: the screen is now the draw window plus the black bars,
    // and the second ramp takes everything but the window back down to black.
    _s.pixels.setAll(0, _frame);
    final k = r - (_fadeUp + _hold1 + _hold2); // < 0 during the second hold
    final down = k <= 0 ? 0 : (2 * k).floor();
    var bars = 63 - down;
    if (bars < 0) bars = 0;
    final pal = VgaPalette.black();
    pal.setRgb(_cBlack, bars, bars, bars);
    pal.setRgb(_cWindow, 63, 63, 63);
    _s.palette = pal;
  }

  @override
  void paintVector(Canvas canvas, Size size) {
    final scene = _scene;
    if (scene != null && _frameNo >= 0) {
      scene.paint(canvas, size, _frameNo);
    }
    if (_whiteout > 0) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 255, 255, _whiteout),
      );
    }
  }
}
