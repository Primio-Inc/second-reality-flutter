import 'dart:typed_data';
import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/tunnel_tables.dart';
import '../engine/vga_palette.dart';

/// Part 6 — the dot tunnel (TUNNELI/TUN10.PAS), ported at the indexed-
/// framebuffer level. Nothing here is invented; every number comes from the
/// original Pascal + its two lookup tables (see engine/tunnel_tables.dart).
///
///  - The tunnel is a queue of 100 rings ("putki", Finnish for pipe). Every
///    jiffy a new ring is pushed at the FAR end and the whole queue shifts one
///    slot toward the viewer, so ring index 99 = farthest, 4 = nearest.
///  - A ring's screen radius comes from `sade[i] = 16384 div (i*7+95)` — a 1/z
///    perspective divide — used as the row index into the precalculated
///    pcalc[radius][64] dot table.
///  - A ring's centre is the snaking path, sampled at the step it was injected:
///    the whole tunnel is drawn RELATIVE to ring 5's centre (`putki[5]`), which
///    is what makes the camera fly along the pipe rather than watch it wobble.
///  - Colour = the ring's palette base (64 or 128, alternating every 8 jiffies
///    to give the travelling light/dark bands) + a depth shade `round(i/1.3)`,
///    so near rings are bright and far rings fall to near-black — the dark hole
///    in the middle of the screen IS the far end of the tunnel.
///  - The last 102 jiffies inject unlit rings (c=0), so the tunnel empties from
///    the far end and the part fades itself out.
class TunnelPart extends Part {
  /// TUN10.PAS `veke` — the part's length in jiffies (1060 @ 70Hz ≈ 15.2s).
  static const _veke = 1060;
  static const _nearRing = 4, _farRing = 80, _camRing = 5;

  final IndexedSurface _s = IndexedSurface(320, 200);
  late final TunnelTables _t;
  late final Int16List _sade; // ring index -> pcalc radius row
  late final Int8List _shade; // ring index -> depth shade added to the colour

  @override
  IndexedSurface get indexed => _s;

  @override
  void init() {
    _t = AssetStore.tunnel!;

    // `for Z := 0 to 100 do sade[z] := round(16384 div ((Z*7)+95));`
    _sade = Int16List(101);
    for (var z = 0; z <= 100; z++) {
      _sade[z] = 16384 ~/ (z * 7 + 95);
    }
    // `bbc := putki[x].c + round(x / 1.3);`
    _shade = Int8List(101);
    for (var i = 0; i <= 100; i++) {
      _shade[i] = (i / 1.3).round();
    }

    // Two grey ramps, bright at the base index and falling to black. Written in
    // the original's order — index 128 belongs to the second ramp.
    //   for x := 0 to 64 do setrgb(64+x ,(64-x),(64-x),(64-x));
    //   for x := 0 to 64 do setrgb(128+x,(64-x)*3 div 4, ...);
    //   setrgb(68,0,0,0);  setrgb(132,0,0,0);
    // Note 64-x reaches 64, which the 6-bit DAC truncates to 0 — so the base
    // entry of the first ramp is black, exactly as on the hardware.
    final pal = VgaPalette.black();
    for (var x = 0; x <= 64; x++) {
      final v = (64 - x) & 63;
      pal.setRgb(64 + x, v, v, v);
    }
    for (var x = 0; x <= 64; x++) {
      final v = ((64 - x) * 3 ~/ 4) & 63;
      pal.setRgb(128 + x, v, v, v);
    }
    // Ring 5 is the one the camera sits on; its colour index is punched black
    // so it never draws over the view.
    pal.setRgb(68, 0, 0, 0);
    pal.setRgb(132, 0, 0, 0);
    _s.palette = pal;
  }

  /// Centre of the ring injected at step [r] (`putki[100]` before the shift).
  ///
  /// The original reads:
  ///   putki[100].x := cosit[sy and 2047]-sinit[sy*3 and 4095]-cosit[sx and 2047];
  ///   putki[100].y := sinit[sx*2 and 4095]-cosit[sx and 2047]+sinit[y and 4095];
  /// `sx` and `sy` are both zero-initialised and incremented together, so they
  /// are always equal and the two cosit terms in x cancel; `y` is never
  /// assigned after init, so sinit[y] is sinit[0] = 0. What is left is below.
  int _pathX(int r) => -_t.sinit[(3 * r) & 4095];
  int _pathY(int r) => _t.sinit[(2 * r) & 4095] - _t.cosit[r & 2047];

  /// Palette base of the ring injected at step [r]. Rings that were never
  /// injected (r < 0) and the run-out rings are unlit.
  ///
  ///   if (sy and 15) > 7 then putki[99].c := 128 else putki[99].c := 64;
  ///   if frame >= veke-102 then putki[99].c := 0;
  /// `sy` has already been incremented when c is assigned, hence (r+1).
  int _ringColor(int r) {
    if (r < 0 || r >= _veke - 102) return 0;
    return ((r + 1) & 15) > 7 ? 128 : 64;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final frame = (t * kDemoFps).floor();

    // After F jiffies the queue holds, at index i, the ring injected at step
    // F-100+i (index 99 = newest/farthest, shifting down toward the viewer).
    int ringAt(int i) => frame - 100 + i;

    _s.clear(0);
    final r5 = ringAt(_camRing);
    final camX = r5 < 0 ? 0 : _pathX(r5);
    final camY = r5 < 0 ? 0 : _pathY(r5);

    // Far to near, so nearer (brighter) rings paint over the distant ones.
    for (var i = _farRing; i >= _nearRing; i--) {
      final r = ringAt(i);
      final c = _ringColor(r);
      final bbc = c + _shade[i];
      if (bbc < 64) continue; // unlit ring — `if bbc >= 64 then` in the original

      final bx = _pathX(r) - camX;
      final by = _pathY(r) - camY;
      final base = _sade[i] * _t.pts * 2;
      for (var a = 0; a < _t.pts; a++) {
        final x = _t.pcalc[base + a * 2] + bx;
        final y = _t.pcalc[base + a * 2 + 1] + by;
        if (x < 0 || x > 319 || y < 0 || y > 199) continue;
        _s.pixels[y * 320 + x] = bbc;
      }
    }
  }
}
