import 'dart:math' as math;
import 'dart:typed_data';
import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/interference_tables.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 7 — the interference rings (TECHNO: KOEB `dointerference2`, then
/// KOEA `dointerference`). Ported at the indexed-framebuffer level.
///
/// The whole effect is two concentric-ring bitmaps sliding over each other in
/// a 16-colour planar mode:
///
///  - The STATIC field (`_circle`, 3 bitplanes = 8 shades) sits in planes 0-2
///    and supplies the low 3 bits of the colour index.
///  - The OVERLAY (`_circle2`, 1 bitplane) is re-blitted into plane 3 every
///    frame at its own offset, so it becomes bit 3 of the index — i.e. it
///    picks between two 8-colour palette BANKS. Where the two ring systems
///    overlap, the colours flip: that is the interference.
///  - Each bank is an 8-entry violet ramp, and both are rotated one entry per
///    frame (`palanimc += patdir`), which is what makes the rings appear to
///    travel inward.
///  - Both layers scroll on their own Lissajous path (`scrnrot += 5`,
///    `overrot += 7`), and from frame 350 the overlay also picks up a
///    per-scanline sine wobble whose amplitude ramps in over 240 frames.
///
/// The original hand-optimises the overlay blit with eight pre-shifted copies
/// of the bitmap (`circles[0..7]`, one per sub-byte shift) so it can move it a
/// pixel at a time with dword copies. Working out where each screen pixel
/// actually lands collapses that to a direct sample, which is what we do:
///
///     static  = field[scrny + L][scrnx + X]
///     overlay = field[overy + L][overx + wobble(L) - 7 + X]
///     colour  = static | overlay << 3
///
/// (the -7 falls out of the pre-shift indexing and is kept for exactness).
class InterferencePart extends Part {
  /// KOEB runs for exactly 256 frames, then KOEA takes over.
  static const int phase1Frames = 256;

  /// KOEA's `cmp cs:framecount,70*5` — when the scanline wobble starts.
  static const int wobbleStart = 350;

  final IndexedSurface _s = IndexedSurface(320, 200);
  late final InterferenceTables _t;
  late final Int16List _sin1024;

  @override
  IndexedSurface get indexed => _s;

  /// Arithmetic shift right (the ASM's `sar`), safe for the web: dart2js does
  /// bitwise ops on UNSIGNED 32-bit values, so `negativeValue >> n` yields a
  /// huge positive number in a web build (it worked in the VM only). Keep the
  /// shifted operand non-negative and fix up the sign by hand.
  static int _sar(int v, int n) => v >= 0 ? v >> n : -((-v - 1) >> n) - 1;

  /// SIN1024.INC, verified byte-exact against `trunc(256*sin(2*pi*k/1024))`.
  static Int16List _buildSin() {
    final s = Int16List(1024);
    for (var k = 0; k < 1024; k++) {
      s[k] = (256 * math.sin(k * 2 * math.pi / 1024)).truncate();
    }
    return s;
  }

  // KOEA pal1/pal2 — two 8-entry violet ramps (green pulled down to 8/9 and
  // 7/9 of red/blue). Stored twice so a rotated 8-entry read stays in bounds,
  // exactly as the ASM's 16-entry tables do.
  static const _ramp1 = [30, 60, 50, 40, 30, 20, 10, 0];
  static const _ramp2 = [0, 10, 20, 30, 40, 50, 60, 30];

  /// KOEB pal0 — only entry 0 of each 8 is lit, so exactly ONE of the eight
  /// ring shades glows and the rotation walks it outward through the rings.
  static const _pal0 = [
    [0, 30, 40],
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0],
    [0, 0, 0],
  ];

  @override
  void init() {
    _t = AssetStore.interference!;
    _sin1024 = _buildSin();
    _s.palette = VgaPalette.black();
  }

  /// The 8-entry ramp rotation after [frame] frames. `patdir` starts at 0 in
  /// KOEA and is latched to -3 by the first music row whose `row & 7` is 0 or
  /// 4 — and is never cleared again, so it is -3 within half a second of the
  /// part starting. KOEB already starts at -3, so we use -3 throughout rather
  /// than model a music-row counter the engine does not have. (Dart's `%`
  /// already returns a non-negative result for a positive divisor.)
  static int _rot(int frame) => (-3 * frame) % 24 ~/ 3;

  void _setPhase1Palette(int frame) {
    // `palfader` climbs by 2 a frame to 512: the first half (<=256) scales the
    // colours up from black, the second half ADDS a rising constant that
    // saturates every entry at 63 — so the part blows out to white before
    // KOEA's rings cut in.
    final palfader = math.min(512, 2 * (frame + 1));
    final rot = _rot(frame);
    final pal = VgaPalette.black();
    for (var j = 0; j < 8; j++) {
      final c = _pal0[(rot + j) & 7];
      int mix(int v) => palfader <= 256
          ? (v * palfader) >> 8
          : math.min(63, v + palfader - 256);
      final r = mix(c[0]), g = mix(c[1]), b = mix(c[2]);
      // Both banks are the same during phase 1 — the overlay is not drawn.
      pal.setRgb(j, r, g, b);
      pal.setRgb(8 + j, r, g, b);
    }
    _s.palette = pal;
  }

  void _setPhase2Palette(int n) {
    final rot = _rot(n);
    final pal = VgaPalette.black();
    for (var j = 0; j < 8; j++) {
      final v1 = _ramp1[(rot + j) & 7];
      pal.setRgb(j, v1, v1 * 8 ~/ 9, v1);
      final v2 = _ramp2[(rot + j) & 7];
      pal.setRgb(8 + j, v2, v2 * 7 ~/ 9, v2);
    }
    _s.palette = pal;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final frame = (t * kDemoFps).floor();
    const w = InterferenceTables.width;
    final sf = _t.staticField, ov = _t.overlay;
    final px = _s.pixels;

    if (frame < phase1Frames) {
      // KOEB: `sizefade` is zero and never changes (the code that would raise
      // it falls through to a no-op), so the window sits dead centre and only
      // the palette moves. The overlay blit is jumped over entirely.
      _setPhase1Palette(frame);
      const scrnx = 160, scrny = 100;
      for (var l = 0; l < 200; l++) {
        final srow = (scrny + l) * w + scrnx;
        final drow = l * 320;
        for (var x = 0; x < 320; x++) {
          px[drow + x] = sf[srow + x];
        }
      }
      return;
    }

    final n = frame - phase1Frames;
    _setPhase2Palette(n);

    final scrnrot = (5 * n) & 1023;
    final scrnx = _sar(_sin1024[scrnrot], 2) + 160;
    final scrny = _sar(_sin1024[(scrnrot + 256) & 1023], 2) + 100;

    final overrot = (211 + 7 * n) & 1023;
    final overx = _sar(_sin1024[overrot], 2) + 160;
    final overy = _sar(_sin1024[(overrot + 256) & 1023], 2) + 100;

    // `sinuspower` steps up once every 16 frames from frame 350, capping at 15.
    // power0[p][v] = v*p/15, so the wobble reaches the full sine at p=15.
    final sp = n < wobbleStart
        ? 0
        : math.min(15, (n - wobbleStart) ~/ 16 + 1);
    final sinurot = (7 * (n + 1)) & 1023;

    for (var l = 0; l < 200; l++) {
      final raw = _sar(_sin1024[(sinurot + 9 * (l + 1)) & 1023], 3); // +-32
      final wob = raw * sp ~/ 15; // power0[sp][raw], truncated toward zero
      final srow = (scrny + l) * w + scrnx;
      final orow = (overy + l) * w + overx + wob - 7;
      final drow = l * 320;
      for (var x = 0; x < 320; x++) {
        px[drow + x] = sf[srow + x] | ov[orow + x] << 3;
      }
    }
  }
}
