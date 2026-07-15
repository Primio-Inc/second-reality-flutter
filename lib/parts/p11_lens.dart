import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/lens_tables.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 11 — the lens and the rotozoomer (LENS/MAIN.C + LENS/ASM.ASM, built as
/// the single LNS&ZOOM.EXE that MAIN/U2.ASM's `partexecute` list runs after the
/// forest scroller). One EXE, three phases:
///
///  1. `part1` — the "fir fade". The monster picture is not blitted and not
///     faded in: two curtains of single pixels sweep out of a diagonal line and
///     scribble it onto the screen, one pixel per row per pass, six passes a
///     frame, at a per-row speed of `(19 + y/5 + 4) & ~7` sixty-fourths of a
///     pixel. It runs 80 frames of drawing inside a 300-retrace phase.
///  2. `part2` — the lens. A refracting glass ball bounces across the picture
///     for 715 frames. NOTHING here is computed at runtime: the refraction is a
///     table CALC.C baked offline (see LensTables) and the bounce is a REPLAY of
///     LENS.EXP, which MAIN.C recorded once with its `#ifdef SAVEPATH` physics.
///     Its three palette banks fade up over frames 32..96.
///  3. `part3` — the rotozoomer. `inittwk` switches to the tweaked 320x400 mode
///     and `rotate` resamples a 256x256 wrap-around copy of the picture at
///     160x100 (each sample 2px wide, each row 4 scanlines — which is the same
///     4:3 field as our 320x200 surface with every sample a 2x2 block). Also a
///     replay: 2000 frames of (origin, step) from LENS.EXP. It ends by fading
///     colours 0-63 to white over its last 128 retraces and holding white while
///     the next part loads.
///
/// TIMING — measured, because it cannot be derived. MAIN.C gates all three
/// phases on `dis_musplus()`, which is STMIK's zone state and does not exist in
/// anything that shipped (see ForestPart and the porting notes). So the two internal
/// starts come from the capture, and each is cross-checked against the phase
/// lengths the code itself fixes:
///
///   * frame 0 (the fir fade's first pixels)  capture 260.23 -> 260.43 here.
///   * the lens starts                        capture 267.06 (t = 6.83).
///   * the rotozoomer starts                  capture 277.35 (t = 17.12), the
///     frame the picture is replaced by the flat cleared tweak-mode screen.
///
/// The two later ones are one measurement, not two: 277.35 - 715/70 = 267.06 is
/// exactly where the lens first noses in from the top of the capture. And the
/// rotozoomer's own 2000 frames check out from the far end — its fade-to-white
/// starts at frame 1872 (capture 304.09, fitted from the luma ramp) and the
/// picture freezes on the all-white palette at frame 2000 (capture 305.87).
class LensPart extends Part {
  /// Part-local seconds at which `part2` (the lens) starts.
  static const double kLensAt = 6.83;

  /// Part-local seconds at which `part3` (the rotozoomer) starts.
  static const double kZoomAt = 17.12;

  static const int _fadeSteps = 80; // 64 to white + 16 overbright
  static const int _zoomFadeOut = 128; // the last 128 retraces go to white

  final IndexedSurface _s = IndexedSurface(320, 200);

  @override
  IndexedSurface? get indexed => _s;

  /// A 64K VGA segment, exactly as the original addresses it: every offset the
  /// lens tables carry is a 16-bit one and wraps inside this.
  final Uint8List _vram = Uint8List(65536);
  final Uint8List _back = Uint8List(65536);

  /// The 256x256 wrap-around picture the rotozoomer samples, and its 90-degree
  /// rotation (`rotate` swaps to it when the step is steeper in x than in y, so
  /// its 8-bit-at-a-time address arithmetic stays in range).
  final Uint8List _rotpic = Uint8List(65536);
  final Uint8List _rotpic90 = Uint8List(65536);

  final Uint8List _pal = Uint8List(768); // the picture + its three lens banks
  late Uint8List _fade; // 80 x 192: colours 0-63 to white, then overbright
  late Uint8List _fade2; // 32 x 576: the lens banks fading up from their tint
  final VgaPalette _dac = VgaPalette.black();

  late LensTables _t;

  /// The rotozoomer's per-column displacements — 160 of them, rebuilt each
  /// frame by `rotate`.
  final Uint16List _cols = Uint16List(160);

  int _frame = -1;

  int get _lensFrame => (kLensAt * kDemoFps).round();
  int get _zoomFrame => (kZoomAt * kDemoFps).round();

  /// How long the part runs: the rotozoomer's 2000 frames, and then it holds
  /// white while the next part loads.
  static double get duration => kZoomAt + 2000 / kDemoFps;

  @override
  void init() {
    final pic = AssetStore.images['lenspic']!;
    _t = AssetStore.lens!;

    _back.setRange(0, 64000, pic.pixels);
    // MAIN.C pads the picture out to a full 64K segment so the lens's 16-bit
    // offsets can run past the last row without reading nothing.
    _back.setRange(64000, 65536, _back.sublist(64000 - 1536, 64000));

    // Palette banks 1..3 = the picture's own 64 colours plus each lens tint,
    // clamped. Bank 1 is the refracted body, 2 and 3 the highlights.
    _pal.setRange(0, 768, pic.palette.bytes);
    for (var i = 1; i < 4; i++) {
      for (var a = 0; a < 64 * 3; a += 3) {
        for (var k = 0; k < 3; k++) {
          _pal[a + i * 192 + k] =
              math.min(63, _t.tint[(i - 1) * 3 + k] + _pal[a + k]);
        }
      }
    }

    _fade = Uint8List(_fadeSteps * 192);
    var o = 0;
    for (var x = 0; x < 64; x++) {
      for (var y = 0; y < 192; y++) {
        _fade[o++] = (_pal[y] * (63 - x) + x * 63) ~/ 63;
      }
    }
    for (var x = 0; x < 16; x++) {
      for (var y = 0; y < 192; y++) {
        _fade[o++] = math.min(63, _pal[y] + (15 - x) * 5);
      }
    }
    _fade2 = Uint8List(32 * 576);
    o = 0;
    for (var x = 0; x < 32; x++) {
      for (var y = 192; y < 768; y++) {
        _fade2[o++] = _pal[y] - _pal[y % 192] * (31 - x) ~/ 31;
      }
    }

    // MAIN.C's "rotpic readymake": columns 32..287 of the picture, its rows
    // stretched 11/10 and shifted up, into a 256x256 field that wraps.
    for (var x = 0; x < 256; x++) {
      for (var y = 0; y < 256; y++) {
        var a = y * 10 ~/ 11 - 18;
        if (a < 0 || a > 199) a = 0;
        _rotpic[x + y * 256] = _back[x + 32 + a * 320];
      }
    }
    for (var x = 0; x < 256; x++) {
      for (var y = 0; y < 256; y++) {
        _rotpic90[x + y * 256] = _rotpic[y + (255 - x) * 256];
      }
    }

    _s.palette = _dac;
    _reset();
  }

  // The fir fade's per-row positions (16.6 fixed) and speeds.
  final Int32List _f1 = Int32List(200);
  final Int32List _f2 = Int32List(200);
  final Int32List _f1a = Int32List(200);
  final Int32List _f2a = Int32List(200);

  void _reset() {
    _frame = -1;
    _vram.fillRange(0, 65536, 0);
    for (var y = 0; y < 200; y++) {
      _f1[y] = _f2[y] = 170 * 64 + (100 - y) * 50;
      // C's `v & ~7` rounds toward -infinity: down for the rightward curtain,
      // UP in magnitude for the leftward one (-62 & ~7 == -64). Written as
      // arithmetic because dart2js's `&` yields an unsigned 32-bit result and
      // would turn the negative one into a huge positive (see the porting notes).
      _f1a[y] = ((19 + y ~/ 5 + 4) ~/ 8) * 8;
      final v = 19 + (199 - y) ~/ 5 + 4;
      _f2a[y] = -(((v + 7) ~/ 8) * 8);
    }
    _dac.bytes.setRange(0, 768, _pal);
  }

  void _setPal(Uint8List src, int off, int first, int count) {
    _dac.bytes.setRange(first * 3, (first + count) * 3, src, off);
  }

  // ---- ASM.ASM -------------------------------------------------------------

  /// The lens body: one contiguous run per row, each pixel sampled from the
  /// background at its own precomputed offset, ORed into palette bank 1.
  void _dorow(LensLayer l, int u, int row, int col) {
    final cnt = l.count[row];
    if (cnt < 4) return;
    final wi = l.start[row];
    final di = (u + l.words[wi]) & 0xFFFF;
    for (var i = 0; i < cnt; i++) {
      _vram[(di + i) & 0xFFFF] =
          _back[(di + (l.words[wi + 1 + i] & 0xFFFF)) & 0xFFFF] | col;
    }
  }

  /// The two highlight layers: (destination, source) pairs.
  void _dorow2(LensLayer l, int u, int row, int col) {
    final cnt = l.count[row];
    if (cnt == 0) return;
    final wi = l.start[row];
    final di = (u + l.words[wi]) & 0xFFFF;
    for (var i = 0; i < cnt; i++) {
      final dst = l.words[wi + 1 + i * 2] & 0xFFFF;
      final src = l.words[wi + 2 + i * 2] & 0xFFFF;
      _vram[(dst + di) & 0xFFFF] = _back[(src + di) & 0xFFFF] | col;
    }
  }

  /// The erase ring: copy the background straight back, no colour bits — this
  /// is what wipes the lens's trail as it moves.
  void _dorow3(LensLayer l, int u, int row) {
    final cnt = l.count[row];
    if (cnt == 0) return;
    final wi = l.start[row];
    final di = (u + l.words[wi]) & 0xFFFF;
    for (var i = 0; i < cnt; i++) {
      final o = ((l.words[wi + 1 + i] & 0xFFFF) + di) & 0xFFFF;
      _vram[o] = _back[o];
    }
  }

  /// MAIN.C `drawlens`: the sprite is drawn from both ends toward the middle,
  /// and a row whose base offset is off-screen is skipped whole.
  void _drawLens(int x0, int y0) {
    final xs = _t.width ~/ 2;
    final ys = _t.height ~/ 2;
    var u1 = (x0 - xs) + (y0 - ys) * 320;
    var u2 = (x0 - xs) + (y0 + ys - 1) * 320;
    final ye = _t.height - 1;
    for (var y = 0; y < ys; y++) {
      if (u1 >= 0 && u1 <= 64000) {
        _dorow(_t.layers[0], u1, y, 0x40);
        _dorow2(_t.layers[1], u1, y, 0x80);
        _dorow2(_t.layers[2], u1, y, 0xC0);
        _dorow3(_t.layers[3], u1, y);
      }
      u1 += 320;
      if (u2 >= 0 && u2 <= 64000) {
        _dorow(_t.layers[0], u2, ye - y, 0x40);
        _dorow2(_t.layers[1], u2, ye - y, 0x80);
        _dorow2(_t.layers[2], u2, ye - y, 0xC0);
        _dorow3(_t.layers[3], u2, ye - y);
      }
      u2 -= 320;
    }
  }

  /// dart2js does bitwise ops on UNSIGNED 32-bit ints, so `>>` on a negative
  /// value is wrong there (it works in the VM and in tests — see the porting notes).
  static int _sar(int v, int n) => v >= 0 ? v >> n : -((-v - 1) >> n) - 1;

  /// ASM.ASM `_rotate`. The screen is walked as a rotated, scaled grid over the
  /// 256x256 picture: down a row the sample moves by (xadd, yadd), across a
  /// column by (yadd, -xadd). Both are 16.16 fixed, and the picture address is
  /// literally `(y & 255) << 8 | (x & 255)`, so it tiles for free.
  void _rotate(int x, int y, int xa, int ya) {
    // Multiplications, not shifts: dart2js's `<<` is a 32-bit op and a negative
    // operand does not survive it.
    var xpos = (x * 65536) & 0xFFFFFFFF;
    var ypos = (y * 65536) & 0xFFFFFFFF;
    var xadd = xa * 64; // the path's units are already 16.16 after this
    var yadd = ya * 64;
    var pic = _rotpic;

    // Steeper in x than in y: sample the pre-rotated copy instead, with the
    // axes swapped, so the 8-bit column accumulator below cannot overrun.
    if (xadd.abs() > yadd.abs()) {
      pic = _rotpic90;
      final t = xadd;
      xadd = -yadd;
      yadd = t;
      final tp = xpos;
      xpos = (-_s32(ypos)) & 0xFFFFFFFF;
      ypos = tp;
    }

    // The per-column table: the low byte accumulates picture-x (step +yadd),
    // the high byte picture-y (step -xadd), carrying 8 bits at a time exactly
    // as the `adc al,bl` / `adc ah,bh` pair does.
    var si = 0, di = 0, al = 0, ah = 0;
    final cx = yadd & 0xFFFF;
    final bl = _sar(yadd, 16) & 0xFF;
    final negx = (-xadd) & 0xFFFFFFFF;
    final dx = negx & 0xFFFF;
    final bh = (negx >>> 16) & 0xFF;
    for (var c = 0; c < 160; c++) {
      si += cx;
      al = (al + bl + (si >>> 16)) & 0xFF;
      si &= 0xFFFF;
      di += dx;
      ah = (ah + bh + (di >>> 16)) & 0xFF;
      di &= 0xFFFF;
      _cols[c] = (ah << 8) | al;
    }

    // Aspect ratio: the per-ROW step is 307/256 of the per-column one. (The
    // original's `mul`/`sar` pair is mod 2^32, but 307 * a 16.16 step of at
    // most 2.0 cannot reach that, so plain arithmetic is the same thing.)
    xadd = _sar(307 * xadd, 8);
    yadd = _sar(307 * yadd, 8);

    final px = _vram;
    for (var row = 0; row < 100; row++) {
      ypos = (ypos + yadd) & 0xFFFFFFFF;
      xpos = (xpos + xadd) & 0xFFFFFFFF;
      final bx = ((ypos >>> 8) & 0xFF00) | ((xpos >>> 16) & 0xFF);
      final base = row * 640;
      for (var c = 0; c < 160; c++) {
        final v = pic[(bx + _cols[c]) & 0xFFFF];
        final o = base + c * 2;
        px[o] = v;
        px[o + 1] = v;
        px[o + 320] = v;
        px[o + 321] = v;
      }
    }
  }

  static int _s32(int v) {
    v &= 0xFFFFFFFF;
    return (v & 0x80000000) != 0 ? v - 0x100000000 : v;
  }

  // ---- MAIN.C --------------------------------------------------------------

  /// One pass of `part1`'s reveal: six sub-passes, each plotting one pixel per
  /// row from each of the two curtains and advancing them.
  void _firFade() {
    for (var c = 0; c < 6; c++) {
      for (var y = 0; y < 200; y++) {
        var o = y * 320 + _sar(_f1[y], 6);
        if (o >= 0 && o < 64000) _vram[o] = _back[o];
        _f1[y] += _f1a[y];
        o = y * 320 + _sar(_f2[y], 6);
        if (o >= 0 && o < 64000) _vram[o] = _back[o];
        _f2[y] += _f2a[y];
      }
    }
  }

  /// The visible page of the 64K segment.
  void _present() => _s.pixels.setRange(0, 64000, _vram);

  @override
  void update(double t, List<int> syncCodes) {
    final target = math.max(0, (t * kDemoFps).floor());
    final lens = _lensFrame, zoom = _zoomFrame;

    if (target >= lens) {
      // The lens and the rotozoomer are both stateless in the frame: the lens
      // repaints the picture under itself from `back` (its erase ring is what
      // does that in the original) and the rotozoomer overwrites every pixel.
      // So a seek costs one frame, not a replay of thousands.
      _frame = target;
      if (target < zoom) {
        final f = target - lens;
        _dac.bytes.setRange(0, 192, _pal);
        _setPal(_fade2, math.min(31, math.max(0, (f - 32) ~/ 2)) * 576, 64, 192);
        _vram.setRange(0, 64000, _back);
        final i = math.min(f, _t.lensFrames - 1);
        _drawLens(_t.path1[i * 2], _t.path1[i * 2 + 1]);
        _present();
        return;
      }

      // `inittwk` blanks the DAC (which clobbers MAIN.C's own `setpalarea` of
      // the first overbright step one line above it); the capture shows the
      // bright palette up from the very first frame, so we keep the palette the
      // code asks for. Colours 64-255 stay black — the zoomer never uses them.
      final f = target - zoom;
      _dac.bytes.fillRange(0, 768, 0);
      if (f >= _t.zoomFrames) {
        // The loop is over: every colour goes to 63 and the white holds while
        // the next part loads.
        _dac.bytes.fillRange(0, 768, 63);
        _present();
        return;
      }
      final i = f * 4;
      _rotate(_t.path2[i], _t.path2[i + 1], _t.path2[i + 2], _t.path2[i + 3]);
      if (f < 16) {
        _setPal(_fade, (64 + f) * 192, 0, 64); // the overbright settles
      } else {
        _setPal(_fade, 79 * 192, 0, 64);
      }
      if (f > _t.zoomFrames - _zoomFadeOut) {
        final a = math.min(63, (f - (_t.zoomFrames - _zoomFadeOut)) ~/ 2);
        _setPal(_fade, a * 192, 0, 64);
      }
      _present();
      return;
    }

    // part1 accumulates (it scribbles the picture on), so it is replayed — but
    // it is only 300 retraces long, of which 80 draw.
    if (target < _frame) _reset();
    while (_frame < target) {
      _frame++;
      if (_frame < 80) _firFade();
    }
    _present();
  }
}
