import 'dart:typed_data';

import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/rayscrl_tables.dart';
import '../engine/vga_palette.dart';

/// Part 14 — the mirror-ball scroll (`RAYSCRL.EXE`, built from WATER/DEMO.PAS +
/// ROUTINES.ASM). A raytraced still of two chrome balls on rippling water, with
/// the scroll text swimming across the surface.
///
/// It is FOREST's trick again, and just as much of it is precomputed: the text
/// is not projected onto anything at runtime. WATER/DATGEN.PAS raytraced the
/// water as a UV map (the scroll cell's column in the red channel, its row in a
/// fixed green mask) and wrote, per cell, the list of screen offsets that cell
/// covers. `Putrouts1` then walks those lists and writes the cell's byte where
/// it is non-zero and the BACKGROUND byte where it is zero — the text is opaque
/// here, not additive as in the forest. The ripple, the perspective and the
/// occlusion behind the balls all live in the offsets.
///
/// The three tables are the incremental update for one phase each of the water's
/// 3-frame cycle (DATGEN only emitted pixels whose mapping CHANGED between
/// consecutive renders), so they are cycled one per frame on top of the picture
/// blitted once at the start — and the scroll advances one column every third
/// frame, when the cycle comes back round.
///
/// TIMING. Every gate in this part reads STMIK state through `int 0FCh` fn 6,
/// so none of them can be derived — all three are measured off the capture:
///   - Frame 0 (the fade-in) waits for `dis_musplus() >= 0`. Its 128-retrace
///     palette ramp measures 410.20 -> 412.03 in the capture (1.83s = 128/70
///     exactly, which is what confirms the ramp IS this fade), so the part
///     starts at capture 410.20 -> 410.40 in soundtrack time.
///   - The main loop waits for fn 6's "order" field to CHANGE and its "row"
///     field to reach 16. That reads like a row-clock lookup, and it is not:
///     resolving it against our order/row grid (order 75 row 16 = 412.725s)
///     puts the scroll SEVEN SECONDS early. Fitting the sword's own pixel count
///     across the whole part against the capture's gives a single clean peak at
///     capture 419.30 (r = 0.981; the row-clock candidates score r = -0.01 and
///     r = 0.92), so [kScrollAt] is that measurement. Whatever fn 6 returns in
///     CX/BX here, it is not the (order, row) our row clock counts — same family
///     of un-derivable STMIK state as dis_musplus.
///   - The fade-out waits for `dis_musplus() == -11` (the same gate value FOREST
///     uses). Measured at capture 438.40 -> 438.60; it then runs 64 retraces and
///     quits.
class RayscrlPart extends Part {
  /// `for y := 0 to 63*2 do` — the fade-in, one palette step every other retrace.
  static const int _fadeRetraces = 128;

  /// Where the scroll starts — DEMO.PAS's post-fade music wait, MEASURED
  /// (capture 419.30 -> 419.50 here); see the note above on why it cannot be
  /// resolved through the row clock.
  static const double kScrollAt = 419.50;

  /// `if fp = 64 then quit := 1` — the fade-out, one palette step per retrace.
  static const double kFadeOutAt = 438.60;
  static const int _fadeOutRetraces = 64;

  final IndexedSurface _s = IndexedSurface(320, 200);
  late final RayscrlTables _t;
  late final Uint8List _bg;

  /// The target DAC (MIEKKA.SCI's palette, which the picture and the text share).
  late final VgaPalette _target;

  /// DEMO.PAS's `pal` — the working DAC, ramped up and then down.
  final Uint8List _pal = Uint8List(769);

  /// `fbuf` — the scroll buffer, one byte per cell, shifted left one byte every
  /// third frame. 5373 bytes: DEMO.PAS declares `array[0..158*34]`, and the
  /// column insert writes at 158*(x+1), which reaches the last index.
  final Uint8List _fbuf = Uint8List(RayscrlTables.cells + 1);

  int _sss = 0; // which of the three tables is next
  int _scp = 0; // the scroll's column in the text strip
  int _frame = 0; // main-loop retraces elapsed
  int _fadeStep = 0;

  @override
  IndexedSurface? get indexed => _s;

  @override
  void init() {
    _t = AssetStore.rayscrl!;
    final pic = AssetStore.images['rayback']!;
    _bg = pic.pixels;
    _target = VgaPalette.fromBytes(pic.palette.bytes);
    _reset();
  }

  void _reset() {
    _sss = 0;
    _scp = 0;
    _frame = 0;
    _fadeStep = 0;
    _fbuf.fillRange(0, _fbuf.length, 0);
    _pal.fillRange(0, _pal.length, 0);
    _s.pixels.setAll(0, _bg);
  }

  /// `scr(pos)` -> Putrouts1: paint one table's cells over the screen.
  void _scr(int table) {
    final counts = _t.counts[table];
    final offs = _t.offsets[table];
    final px = _s.pixels;
    var k = 0;
    for (var cell = 0; cell < RayscrlTables.cells; cell++) {
      final n = counts[cell];
      if (n == 0) continue;
      final v = _fbuf[cell];
      for (var i = 0; i < n; i++) {
        final off = offs[k++];
        px[off] = v != 0 ? v : _bg[off];
      }
    }
  }

  /// One retrace of the main loop.
  void _step() {
    _scr(_sss);
    if (_sss == 2) {
      _sss = 0;
      // `move(fbuf[1],fbuf,sizeof(fbuf))` — the whole buffer shifts one cell,
      // so the new column arrives one row at a time at 158*(x+1).
      _fbuf.setRange(0, RayscrlTables.cells, _fbuf, 1);
      for (var x = 0; x < 34; x++) {
        _fbuf[158 + x * 158] = _t.strip[x * _t.stripW + _scp];
      }
      if (_scp < 390) _scp++;
    } else {
      _sss++;
    }
    _frame++;
  }

  /// The fade-in / fade-out palette ramp. Both loops in DEMO.PAS walk
  /// `for pf := 0 to 3`, i.e. FOUR bytes of a three-byte entry — so every
  /// entry's red is also stepped as the previous entry's `pf = 3`, and the reds
  /// ramp twice as fast as the greens and blues. That is why [_pal] is 769 bytes
  /// long and why the quirk is kept: it is what the hardware showed.
  void _rampUp() {
    for (var x = 0; x < 256; x++) {
      for (var pf = 0; pf < 4; pf++) {
        final i = x * 3 + pf;
        if (i < 768 && _pal[i] < _target.bytes[i]) _pal[i]++;
      }
    }
  }

  @override
  void update(double t, List<int> syncCodes) {
    final retrace = (t * kDemoFps).floor();
    final partStart = musicTime - t;

    // The main loop's retraces, counted from the measured scroll gate.
    final scrollLocal = kScrollAt - partStart;
    final target = retrace < scrollLocal * kDemoFps
        ? 0
        : (retrace - (scrollLocal * kDemoFps).floor());

    if (target < _frame || _fadeStep * 2 > retrace) _reset();

    // The fade-in runs before (and, at 128 retraces, well before) the scroll,
    // and paints nothing: fbuf is still empty, so scr() only repaints the
    // background over itself.
    final wantFade = retrace.clamp(0, _fadeRetraces) ~/ 2;
    while (_fadeStep < wantFade) {
      _rampUp();
      _fadeStep++;
    }

    var budget = 4000;
    while (_frame < target && budget-- > 0) {
      _step();
    }
    if (_frame < target) _frame = target;

    // The fade-out: one step per retrace from the measured dis_musplus gate.
    final out = ((musicTime - kFadeOutAt) * kDemoFps).floor();
    if (out > 0) {
      // Recomputed from the target each frame rather than accumulated, so a
      // seek into the fade lands on the right step.
      final want = out.clamp(0, _fadeOutRetraces);
      final pal = VgaPalette.fromBytes(_pal.sublist(0, 768));
      for (var s = 0; s < want; s++) {
        for (var x = 0; x < 256; x++) {
          for (var pf = 0; pf < 4; pf++) {
            final i = x * 3 + pf;
            if (i < 768 && pal.bytes[i] > 0) pal.bytes[i]--;
          }
        }
      }
      _s.palette = pal;
      return;
    }

    _s.palette = VgaPalette.fromBytes(_pal.sublist(0, 768));
  }
}
