import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 13 — the minivectorballs (`MINVBALL.EXE`, built from `DOTS/`: MAIN.C +
/// ASM.ASM). 512 little balls rain onto a shaded floor, bounce, and are finally
/// scattered into a cloud that whites out.
///
/// Everything below is the original's arithmetic, kept at the indexed-
/// framebuffer level because the whole part is a mode-13h erase/redraw loop:
///
///  - The floor is not geometry. MAIN.C fills screen rows 100..199 with colour
///    index `64+row`, and palette entries 64..163 are a grey ramp
///    `c = 64-256/(a+4); c = c*c/64; grey = c/4` — dark at the horizon, bright
///    at the bottom. That picture is copied to `bgpic` and every dot ERASES
///    itself from it, so the floor is also the background buffer.
///  - A ball is a 4x3 sprite whose colour comes from `depthtable1..3`, indexed
///    by the ball's own depth (`bp >> 8`): shade `c = 15 - clamp((a-31)*3/4+8)`,
///    palette index `4*c + 2` (edges) or `4*c + 3` (centre row), i.e. one of
///    the 16 brightness groups of the cyan ramp. Near = bright.
///  - A ball's SHADOW is the same projection with the world y pinned to the
///    floor (`dx:ax = 8<<16`, i.e. y = 8192), drawn as two pixels of colour 87
///    — a fixed grey out of the floor's own ramp.
///  - Physics is 16-bit and per-retrace: `yadd += gravity`, and on crossing
///    `gravitybottom = 8105` the ball bounces with `yadd = -yadd*13 >> 4`.
///    Gravity starts at 3 and is stepped down to 0 after frame 1900, which is
///    what makes the cloud hang in the air at the end.
///  - Exactly ONE ball is respawned per retrace (`i = dottaul[j++]`, a shuffled
///    order), so the emitter draws its Lissajous figures one dot at a time.
///
/// TIMING. The part is not music-gated (MAIN.C only breaks out on
/// `dis_musplus()` at the very end), so frame 0 is capture-measured — and the
/// measurement is exact rather than eyeballed, twice over:
///   - The 65-step fade-in (2 retraces per step) subtracts `b` from every DAC
///     entry, but the floor ramp's brightest entry is only ~15, so the floor
///     stays black until b < 15 — the last 30 retraces. The capture's luma ramps
///     374.53 -> 374.95 (0.42s = 30 retraces) and then holds. So frame 0 =
///     capture 374.95, and the part (its fade) starts 130 retraces earlier at
///     373.09 -> 373.29 in soundtrack time.
///   - The white-out (frames 2360..2400) then predicts capture 408.66..409.23;
///     the capture's white segment is 408.70..409.20. The 70 Hz frame clock and
///     frame 0 are both confirmed.
class MiniVectorBallsPart extends Part {
  /// The 65 fade-in steps of `for(b=64;b>=0;b--) { dis_waitb(); dis_waitb(); }`.
  static const int _fadeRetraces = 130;

  /// `while(!dis_exit() && frame<2450)`.
  static const int _lastFrame = 2450;

  static const int _dotNum = 512;
  static const int _gravityBottom = 8105;
  static const int _gravityD = 13;

  final IndexedSurface _s = IndexedSurface(320, 200);

  /// The DAC as MAIN.C leaves it after building the ramps — `pal[]`, which the
  /// original reads back off the hardware with `inp(0x3c9)`.
  final VgaPalette _pal = VgaPalette.black();

  /// The floor picture, and the source every dot erases itself from (`bgpic`).
  final Uint8List _bg = Uint8List(64000);

  /// `dottaul[]` — the shuffled respawn order.
  final Int16List _order = Int16List(_dotNum);

  final Int16List _x = Int16List(_dotNum);
  final Int16List _y = Int16List(_dotNum);
  final Int16List _z = Int16List(_dotNum);
  final Int16List _yadd = Int16List(_dotNum);

  /// `dot[].old1` / `dot[].old2` — where the shadow and the ball were last
  /// drawn, so the next frame can restore the background under them.
  final Int32List _oldShadow = Int32List(_dotNum);
  final Int32List _oldBall = Int32List(_dotNum);

  /// `depthtable1..3`, as the shade `c` they encode (the tables are just
  /// `0x04040404*c` added to a fixed byte pattern).
  final Int8List _shade = Int8List(128);

  /// The original's `sin1024[]`: 1024 entries of `round(256*sin)`.
  final Int16List _sin = Int16List(1024);

  // The C locals, carried across frames.
  int _frame = 0;
  int _f = 0;
  int _j = 0;
  int _dropper = 22000;
  int _grav = 3;
  int _rot = 0;
  int _rots = 0;
  int _rota = -64;
  int _rotSin = 0;
  int _rotCos = 0;
  int _rand = 1; // Microsoft C rand(), never seeded, so seed = 1.

  @override
  IndexedSurface? get indexed => _s;

  int _isin(int deg) => _sin[deg & 1023];
  int _icos(int deg) => _sin[(deg + 256) & 1023];

  /// The Microsoft C library's `rand()` — the exact cloud the original scatters
  /// depends on this sequence, so it is ported rather than replaced.
  int _nextRand() {
    _rand = (_rand * 214013 + 2531011) & 0xFFFFFFFF;
    return (_rand >> 16) & 0x7FFF;
  }

  /// Arithmetic shift right. `>>` is an UNSIGNED 32-bit op under dart2js, so a
  /// negative product would come back as a huge positive — see the project's
  /// dart2js note.
  static int _sar(int v, int n) => (v / (1 << n)).floor();

  /// Truncate to a signed 16-bit register, which the original's math relies on.
  static int _i16(int v) {
    v &= 0xFFFF;
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  @override
  void init() {
    for (var i = 0; i < 1024; i++) {
      _sin[i] = (256 * math.sin(2 * math.pi * i / 1024)).round();
    }

    // The cyan ramp: 16 brightness groups (a) x 4 shades (b).
    //   c = 100 + a*9;  r = cols[b].r;  g = cols[b].g*c/256;  b = cols[b].b*c/256
    const cols = <int>[0, 0, 0, 4, 25, 30, 8, 40, 45, 16, 55, 60];
    for (var a = 0; a < 16; a++) {
      for (var b = 0; b < 4; b++) {
        final c = 100 + a * 9;
        _pal.setRgb(a * 4 + b, cols[b * 3], cols[b * 3 + 1] * c ~/ 256,
            cols[b * 3 + 2] * c ~/ 256);
      }
    }
    _pal.setRgb(255, 31, 0, 15);
    // The floor ramp, 64..163.
    for (var a = 0; a < 100; a++) {
      var c = 64 - 256 ~/ (a + 4);
      c = c * c ~/ 64;
      _pal.setRgb(64 + a, c ~/ 4, c ~/ 4, c ~/ 4);
    }

    // `depthtable1[a] = 0x202 + 0x04040404*c` etc — only `c` matters here.
    for (var a = 0; a < 128; a++) {
      var c = a - (43 + 20) ~/ 2;
      c = c * 3 ~/ 4;
      c += 8;
      if (c < 0) {
        c = 0;
      } else if (c > 15) {
        c = 15;
      }
      _shade[a] = 15 - c;
    }

    _reset();
  }

  void _reset() {
    _frame = 0;
    _f = 0;
    _j = 0;
    _dropper = 22000;
    _grav = 3;
    _rot = 0;
    _rots = 0;
    _rota = -64;
    _rand = 1;

    for (var a = 0; a < _dotNum; a++) {
      _order[a] = a;
    }
    for (var a = 0; a < 500; a++) {
      final b = _nextRand() % _dotNum;
      final c = _nextRand() % _dotNum;
      final d = _order[b];
      _order[b] = _order[c];
      _order[c] = d;
    }
    for (var a = 0; a < _dotNum; a++) {
      _x[a] = 0;
      _y[a] = 2560 - _dropper;
      _z[a] = 0;
      _yadd[a] = 0;
      _oldShadow[a] = 0;
      _oldBall[a] = 0;
    }
    // The second scramble swaps positions, which at this point are all equal —
    // but it burns 1000 rand() calls, and the cloud at frame 1700 depends on
    // where the sequence stands. So it is replayed, not skipped.
    for (var a = 0; a < 500; a++) {
      _nextRand();
      _nextRand();
    }

    // The floor picture, and the copy every dot erases from.
    _s.clear(0);
    for (var a = 0; a < 100; a++) {
      _s.pixels.fillRange((100 + a) * 320, (101 + a) * 320, a + 64);
    }
    _bg.setAll(0, _s.pixels);
  }

  /// One retrace of the inner `while(repeat--)` loop.
  void _step() {
    _frame++;
    if (_frame == 500) _f = 0;

    final i = _order[_j];
    _j = (_j + 1) % _dotNum;

    if (_frame < 500) {
      _x[i] = _i16(_isin(_f * 11) * 40);
      _y[i] = _i16(_icos(_f * 13) * 10 - _dropper);
      _z[i] = _i16(_isin(_f * 17) * 40);
      _yadd[i] = 0;
    } else if (_frame < 900) {
      _x[i] = _i16(_icos(_f * 15) * 55);
      _y[i] = _i16(_dropper);
      _z[i] = _i16(_isin(_f * 15) * 55);
      _yadd[i] = -260;
    } else if (_frame < 1700) {
      final a = _sin[_frame & 1023] ~/ 8;
      _x[i] = _i16(_icos(_f * 66) * a);
      _y[i] = 8000;
      _z[i] = _i16(_isin(_f * 66) * a);
      _yadd[i] = -300;
    } else if (_frame < 2360) {
      _x[i] = _i16(_nextRand() - 16384);
      _y[i] = _i16(8000 - _nextRand() ~/ 2);
      _z[i] = _i16(_nextRand() - 16384);
      _yadd[i] = 0;
      if (_frame > 1900 && (_frame & 31) == 0 && _grav > 0) _grav--;
    }
    // frames 2360..2440 only rewrite pal2 (the white-out and the fade to
    // black); that is done in _paletteFor().

    if (_dropper > 4000) _dropper -= 100;
    _rotCos = _i16(_icos(_rot) * 64);
    _rotSin = _i16(_isin(_rot) * 64);
    _rots += 2;
    if (_frame > 1900) {
      _rot += _rota ~/ 64;
      _rota--;
    } else {
      _rot = _isin(_rots);
    }
    _f++;
  }

  /// `drawdots()` — ASM.ASM. Erases each ball and its shadow from the floor
  /// picture, advances the physics, and redraws them.
  void _drawDots() {
    final px = _s.pixels;
    final gravity = _grav;

    for (var d = 0; d < _dotNum; d++) {
      // bp = the depth, ((Z*rotcos - X*rotsin) >> 16) + 9000. The original
      // subtracts the two HIGH words (the low-word borrow is dropped — `sub
      // dx,cx`, not `sbb`), so that is what is done here.
      final bp = _i16(_sar(_z[d] * _rotCos, 16) - _sar(_x[d] * _rotSin, 16) + 9000);
      if (bp == 0) continue;

      // The screen x: ((X*rotcos + Z*rotsin) >> 8) * 9/8, divided by the depth.
      var v = _sar(_x[d] * _rotCos + _z[d] * _rotSin, 8);
      v = v + _sar(v, 3);
      final sx = _i16(_i16(v ~/ bp) + 160);

      var offscreen = sx < 0 || sx > 319;
      var shadowY = 0;
      if (!offscreen) {
        // The shadow: the same divide with the world y pinned to the floor
        // (8 << 16 = 8192 * 64).
        shadowY = _i16(_i16(524288 ~/ bp) + 100);
        offscreen = shadowY < 0 || shadowY > 199;
      }

      if (offscreen) {
        // @@2 — erase both sprites and leave the dot's physics FROZEN for this
        // frame (the original jumps past the gravity update, so a ball that is
        // off the side of the screen simply stops falling).
        _eraseBall(px, _oldBall[d]);
        _eraseShadow(px, _oldShadow[d]);
        continue;
      }

      // The shadow, two pixels of the floor's own grey 87.
      final sOff = shadowY * 320 + sx;
      _eraseShadow(px, _oldShadow[d]);
      if (sOff + 1 < 64000) {
        px[sOff] = 87;
        px[sOff + 1] = 87;
      }
      _oldShadow[d] = sOff;

      // The physics — 16-bit, one retrace's worth.
      var ya = _i16(_yadd[d] + gravity);
      var y = _i16(_y[d] + ya);
      if (y >= _gravityBottom) {
        ya = _sar(_i16(-ya * _gravityD), 4);
        y = _i16(y + ya);
      }
      _yadd[d] = ya;
      _y[d] = y;

      final ballY = _i16(_i16((y * 64) ~/ bp) + 100);
      if (ballY < 0 || ballY > 199) {
        // @@3 — the ball is above or below the screen; erase only.
        _eraseBall(px, _oldBall[d]);
        continue;
      }

      final bOff = ballY * 320 + sx;
      _eraseBall(px, _oldBall[d]);

      // The depth shade: `shr bp,6` then the dword index, i.e. bp >> 8.
      final c = _shade[(bp >> 8) & 127];
      final edge = 4 * c + 2;
      final mid = 4 * c + 3;
      if (bOff + 643 < 64000) {
        px[bOff + 1] = edge;
        px[bOff + 2] = edge;
        px[bOff + 320] = edge;
        px[bOff + 321] = mid;
        px[bOff + 322] = mid;
        px[bOff + 323] = edge;
        px[bOff + 641] = edge;
        px[bOff + 642] = edge;
      }
      _oldBall[d] = bOff;
    }
  }

  void _eraseShadow(Uint8List px, int off) {
    if (off < 0 || off + 1 >= 64000) return;
    px[off] = _bg[off];
    px[off + 1] = _bg[off + 1];
  }

  void _eraseBall(Uint8List px, int off) {
    if (off < 0 || off + 643 >= 64000) return;
    for (var r = 0; r < 3; r++) {
      final o = off + r * 320;
      px[o] = _bg[o];
      px[o + 1] = _bg[o + 1];
      px[o + 2] = _bg[o + 2];
      px[o + 3] = _bg[o + 3];
    }
  }

  /// The DAC for the current frame. Before the main loop this is the 65-step
  /// fade-up (`pal2[c] = max(0, pal[c] - b)`); inside it the palette is only
  /// touched from frame 2300 on — first the white-out, then down to black.
  VgaPalette _paletteFor(int retrace) {
    final out = VgaPalette.black();
    if (retrace < _fadeRetraces) {
      final b = 64 - retrace ~/ 2;
      for (var c = 0; c < 768; c++) {
        final a = _pal.bytes[c] - b;
        out.bytes[c] = a < 0 ? 0 : a;
      }
      return out;
    }
    final f = _frame;
    if (f < 2360) return _pal;
    if (f < 2400) {
      final a = f - 2360;
      for (var b = 0; b < 768; b += 3) {
        out.bytes[b] = _min63(_pal.bytes[b] + a * 3);
        out.bytes[b + 1] = _min63(_pal.bytes[b + 1] + a * 3);
        out.bytes[b + 2] = _min63(_pal.bytes[b + 2] + a * 4);
      }
      return out;
    }
    final a = f - 2400;
    final c = 63 - a * 2 < 0 ? 0 : 63 - a * 2;
    for (var b = 0; b < 768; b++) {
      out.bytes[b] = c;
    }
    return out;
  }

  static int _min63(int v) => v > 63 ? 63 : v;

  @override
  void update(double t, List<int> syncCodes) {
    final retrace = (t * kDemoFps).floor();
    final target = retrace - _fadeRetraces;

    if (target < _frame) _reset();

    var budget = 4000;
    while (_frame < target && _frame < _lastFrame && budget-- > 0) {
      _step();
      _drawDots();
    }

    _s.palette = _paletteFor(retrace);
  }
}
