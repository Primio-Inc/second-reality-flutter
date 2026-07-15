import 'dart:typed_data';

import '../engine/asset_store.dart';
import '../engine/forest_tables.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 10 — the forest scroller (FOREST/READ2.PAS, built as MNTSCRL.EXE and
/// run after PANIC in MAIN/U2.ASM).
///
/// A night forest picture with a text scrolling along a curve across the sky,
/// passing BEHIND the leaves. Nothing is projected or masked at runtime:
///
///  - The text lives in a 640x31 strip (O2.SCI). A 237x31 window into it is the
///    "font" buffer; every third frame the window shifts one column left and a
///    fresh column is pulled in — so the scroll runs at one column per three
///    frames (23.3 px/s), and the strip's 640 columns are the whole message.
///  - Three precomputed tables (POS1/2/3) map each of the 237x31 font cells to
///    the screen pixels it lights. FOREST/ROUTINES.ASM's `Putrouts` then does
///    `screen[offset] = background[offset] + fontCell`: the text BRIGHTENS the
///    background rather than covering it, and a cell hidden behind a leaf is
///    simply absent from the table. The curve of the text and the leaf
///    occlusion are both baked into the offsets — there is no mask, no z-test.
///    One table is drawn per frame, so the picture fully refreshes every three
///    frames, in step with the scroll.
///  - The two fades are palette-only. The first (64 retraces) brings up the
///    LEAVES while colours 0-31 and 128-159 are pinned black, so the sky and
///    the text stay invisible; the second (64 steps over 127 retraces, colours
///    0-176) brings those in. That is why the leaves appear a full second
///    before the sky glow does.
///
/// MUSIC SYNC — and why two of these times are measured, not derived:
/// READ2.PAS gates itself on `dis_musplus()` (it waits for `>= 0` before the
/// second fade, and starts its fade-out when it reads exactly `-11`).
/// `dis_musplus` is DIS/DISINT.ASM `muscode_6`, which reads STMIK's `np_zplus`
/// / `np_zinfo` — the player's ZONE state. That state is computed inside
/// STMIK.300, a closed binary: the vendored sources never set it, both modules
/// contain no `Zxx` commands, and the order list has no 254 markers, so the
/// zone grid cannot be recovered from what shipped. It is NOT the order grid —
/// measured against the row clock, neither gate lands on an order boundary
/// (the fade-out fires 17 rows before MUSIC1 order 39, not 11).
///
/// So rather than invent a period (which the porting notes rightly forbid) these two
/// gates come from the capture, which is ground truth for what the demo did.
/// Both were measured by fitting the linear palette fades in the capture's own
/// luma (30fps signalstats scan), not eyeballed:
///
///   * frame 0 (leaves fade begins)  capture 231.50 -> 231.70 here
///   * the musplus gate releases     capture 233.45 -> 233.65 here (t = 1.95)
///   * the fade-out begins           capture 259.20 -> 259.40 here (t = 27.70)
///     and runs its 64 steps to black by capture 260.13, one frame before the
///     lens part's first pixel — which confirms the 64-step count.
class ForestPart extends Part {
  /// Part-local seconds at which the `dis_musplus() >= 0` wait releases and the
  /// second fade (sky + text) starts. See the note above.
  static const double kGate = 1.95;

  /// Part-local seconds at which `dis_musplus() == -11` fires the fade-out.
  static const double kFadeOut = 27.70;

  static const int kFade1Frames = 64; // for y := 0 to 63
  static const int kFade2Frames = 127; // for y := 0 to 63*2
  static const int kFadeOutSteps = 64; // fp counts to 64, then quit

  final IndexedSurface _s = IndexedSurface(320, 200);

  @override
  IndexedSurface? get indexed => _s;

  late Uint8List _bg; // the untouched background, 320x200
  late Uint8List _pal; // its palette, 768 bytes, 6-bit
  late ForestTables _t;

  /// The scroll window into the text strip: 31 rows of 237 columns. One byte
  /// over, because READ2.PAS's flat `move(font[1],font[0],237*31)` reads it.
  final Uint8List _font = Uint8List(ForestTables.cells + 1);

  final Uint8List _fpal = Uint8List(768); // what the DAC currently holds
  final Uint8List _tmppal = Uint8List(768); // what it is fading toward

  int _scp = 0; // next column of the strip to pull in
  int _sss = 0; // which position table this frame draws
  int _frame = 0;
  int _fadeOutStep = 0;

  int get _gateFrame => (kGate * kDemoFps).round();
  int get _fade2End => _gateFrame + kFade2Frames;
  int get _fadeOutFrame => (kFadeOut * kDemoFps).round();

  /// How long the part runs, in seconds.
  static double get duration =>
      kFadeOut + kFadeOutSteps / kDemoFps + 0.1;

  @override
  void init() {
    final pic = AssetStore.images['hillback']!;
    _bg = Uint8List.fromList(pic.pixels);
    _pal = Uint8List.fromList(pic.palette.bytes);
    _t = AssetStore.forest!;
    _reset();
  }

  void _reset() {
    _frame = 0;
    _sss = 0;
    _fadeOutStep = 0;

    // The picture is blitted once and then only ever ADDED to; every pixel a
    // position table touches is rewritten from the background each pass, so it
    // heals itself as the text moves on.
    _s.pixels.setAll(0, _bg);

    // The DAC starts black and fades toward the picture's palette with the sky
    // (0-31) and the text bank (128-159) pinned at zero.
    _fpal.fillRange(0, 768, 0);
    _tmppal.setAll(0, _pal);
    _tmppal.fillRange(0, 32 * 3, 0);
    _tmppal.fillRange(128 * 3, 128 * 3 + 32 * 3, 0);
    _applyPalette();

    _font.fillRange(0, _font.length, 0);
    _scp = 0;
  }

  void _applyPalette() {
    final p = VgaPalette.black();
    p.bytes.setRange(0, 768, _fpal);
    _s.palette = p;
  }

  /// The `for x := 0 to N do if fpal < tmppal then inc(fpal)` ramp — one DAC
  /// step per component, which is what makes the fades linear.
  void _fadeUp(int lastColour) {
    for (var i = 0; i < (lastColour + 1) * 3; i++) {
      if (_fpal[i] < _tmppal[i]) _fpal[i]++;
    }
  }

  void _fadeDown() {
    for (var i = 0; i < 768; i++) {
      if (_fpal[i] > _tmppal[i]) _fpal[i]--;
    }
  }

  /// FOREST/ROUTINES.ASM `Putrouts`, plus READ2.PAS's `scr()` wrapper: draw one
  /// position table, and on the third of the three, scroll the font one column.
  void _scr(int pos) {
    final counts = _t.counts[pos];
    final starts = _t.starts[pos];
    final offs = _t.offsets[pos];
    final px = _s.pixels;
    final bg = _bg;
    final font = _font;

    for (var c = 0; c < ForestTables.cells; c++) {
      final n = counts[c];
      if (n == 0) continue; // hidden — behind a leaf
      final v = font[c];
      var i = starts[c];
      final end = i + n;
      for (; i < end; i++) {
        final o = offs[i];
        px[o] = (bg[o] + v) & 0xFF;
      }
    }

    if (pos == 2) {
      // `move(font[1],font[0],237*31)` — a FLAT shift of the whole buffer, not
      // a per-row one. Each row's last column is then overwritten from the
      // strip, so the row-to-row bleed the flat move would cause never shows.
      font.setRange(0, ForestTables.cells, font, 1);
      for (var r = 0; r < ForestTables.rows; r++) {
        font[r * ForestTables.cols + 236] = _t.strip[r * _t.stripW + _scp];
      }
      if (_scp < 639) _scp++;
    }
  }

  /// One retrace.
  void _step() {
    final f = _frame;

    if (f < kFade1Frames) {
      // Fade 1: the leaves come up out of black. No text yet — the font buffer
      // has not even been filled.
      _applyPalette();
      _fadeUp(255);
      if (f == kFade1Frames - 1) {
        // READ2.PAS snaps to the exact palette here, re-zeroes the sky and text
        // banks, and only THEN loads the first 133 columns of the strip into
        // the scroll window. The next fade brings those banks up.
        _tmppal.setAll(0, _pal);
        _fpal.setAll(0, _pal);
        _fpal.fillRange(0, 32 * 3, 0);
        _fpal.fillRange(128 * 3, 128 * 3 + 32 * 3, 0);
        _applyPalette();
        for (var r = 0; r < ForestTables.rows; r++) {
          _font.setRange(r * ForestTables.cols + 104,
              r * ForestTables.cols + 104 + 133, _t.strip, r * _t.stripW);
        }
        _scp = 133;
      }
    } else if (f < _gateFrame) {
      // The `dis_musplus() >= 0` spin: nothing moves, nothing fades.
    } else if (f < _fade2End) {
      // Fade 2: the sky and the text bank come up, over 64 steps taken on every
      // other retrace, while the scroll is already running.
      final y = f - _gateFrame;
      if (y.isOdd) {
        _applyPalette();
        _fadeUp(176);
      }
      _scr(_sss);
      _sss = _sss == 2 ? 0 : _sss + 1;
      if (f == _fade2End - 1) _tmppal.fillRange(0, 768, 0); // fade-out target
    } else if (f < _fadeOutFrame) {
      _scr(_sss);
      _sss = _sss == 2 ? 0 : _sss + 1;
    } else if (_fadeOutStep < kFadeOutSteps) {
      _applyPalette();
      _fadeDown();
      _fadeOutStep++;
      _scr(_sss);
      _sss = _sss == 2 ? 0 : _sss + 1;
    }

    _frame++;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final target = (t * kDemoFps).floor();
    if (target < _frame) _reset();
    // The scroll is an accumulation (the font window has been shifted N times),
    // so catching up means replaying frames — bounded, so a seek can't hang.
    var budget = 4000;
    while (_frame <= target && budget-- > 0) {
      _step();
    }
    if (_frame < target) _frame = target;
  }
}
