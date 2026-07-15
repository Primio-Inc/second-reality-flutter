import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/plasma_tables.dart';
import '../engine/vga_palette.dart';

/// Part 12 — the plasma and the plasma cube (PLZPART, one EXE, two phases; its
/// MAIN.C is `init_copper(); initvect(); plz(); vect(); close_copper();`).
///
/// PHASE 1 — plz() (PLZ.C + ASMYT.ASM + COPPER.ASM).
///   The screen is NOT 320x200. TWEAK.ASM's tw_opengraph2 unchains mode 13h and
///   sets CRTC 09h=0 (no double scan -> 400 lines) and 13h=0x30 (offset 48 -> a
///   96-byte, 384-pixel row pitch). PLZ.C draws MAXY=280 rows of it at address
///   0, and the CRTC's LINE COMPARE (18h) splits the display at scanline 60: the
///   top 60 lines come from `cop_start` (the still-black page vect() will later
///   draw into) and everything below it restarts at address 0 = the plasma. That
///   is the 280-line band with 60 black lines above and below that the capture
///   shows — there is no letterbox in the drawing, it is the split screen.
///
///   Each byte plzline writes covers FOUR pixels (all four planes are the same
///   byte), so the plasma is sampled once per 4 pixels:
///       psini[c*8 + p1 + lsini16[(80-c)*4 + p2 + y]]
///     + psini[(80-c)*4 + p3 + 2y + lsini4[c*16 + p4 + y]]
///   and PLZ.C runs it TWICE per frame with two parameter sets (k and l),
///   masking planes 1+3 for one and 0+2 for the other, on alternate rows — a
///   per-pixel CHECKERBOARD of two different plasmas. COPPER.ASM's `pompota`
///   then flips the split line (60/61) and the pixel pan (2px/0px) every single
///   retrace, which SWAPS that checkerboard at 70 Hz. On a CRT the eye sees the
///   average of the two fields; at our scale a raw field is a hard dither, so we
///   render BOTH fields and average them in RGB (see _FlickerSurface). That is
///   the picture the original produced, not a smoothing we invented.
///
///   `moveplz` advances the two parameter sets every retrace; a `timetable` of
///   dis_getmframe() values switches the palette five times; each switch sets
///   `cop_drop=1`, and do_drop walks the line compare down the `dtau` gravity
///   parabola (60 -> 404 over 64 retraces) so the plasma FALLS off the bottom,
///   then `initpparas` reloads the parameters from `inittable` and the new
///   palette fades up over 31 more retraces. The first palette is different: it
///   fades over 127 retraces DOWN from white (init_plz sets the whole DAC to
///   63,63,63) — which is what catches the all-white screen the rotozoomer hands
///   over.
///
/// PHASE 2 — vect() (VECT.C + PLZFILL.C + PLZA.ASM + SPLINE.ASM).
///   A different mode again: tw_opengraph sets CRTC 09h=2 (3 scanlines a row ->
///   134 rows) and 13h=0x50 (a 160-byte, 640-pixel pitch), and the CRTC shows a
///   320-pixel window of that field from byte 40. The cube is 8 points at ±125
///   and 6 quads; its three face colours index three 128x256 PLASMA TEXTURES and
///   three 64-colour palettes that PLZFILL.C's initvect() generates (blue-white,
///   black-red-yellow, black-orange-violet) — that is why the faces are
///   different colours. Everything else (position, distance, the three rotation
///   angles and the two light angles) is EIGHT CHANNELS OF A SPLINE: SPLINE.ASM
///   evaluates RATA.INC's control points through SPLINE.INC's basis, at
///   `4*256 + frames*4`. Nothing here is hand-animated.
///
///   PLZA.ASM's do_block is the texture filler: it interpolates the texture
///   coordinates per scanline, and each write covers a whole 4-pixel byte, so
///   the texture is sampled once per 4 pixels too. It also displaces every fetch
///   through `dist1` (a sine of the texture row, scrolled one row per frame),
///   which is what makes the texture ripple. The pages carry the same 2px
///   flicker as the plasma (`page&1` draws at x+2 and the pan takes it back), so
///   the cube is averaged over the two fields as well.
///
/// TIMING. Both phases gate on `dis_musplus()` — STMIK zone state, which does
/// not exist in anything that shipped (see the porting notes), so the two gates are
/// MEASURED off the capture. But the palette switches are NOT measured: they run
/// on `dis_getmframe()`, which is STMIK's TICK counter, and MUSIC1's tempo is a
/// constant 130 over this whole part (every row in the row clock is 3 or 6 ticks
/// long), so a tick is exactly 1/52 s. The three drops in the capture land on
/// timetable[0..2] through that clock to within 0.05 s:
///
///   drop         capture   timetable   t0 + tt/52
///   1 (pals[1])  320.836      723        320.798
///   2 (pals[2])  335.560     1491        335.567
///   3 (exit)     342.920     1875        342.952
///
/// which fixes t0 (= dis_setmframe(0)) at capture 306.894 -> 307.09 here (a
/// least-squares fit of the three). The 127-retrace fade from white starts right
/// there; the capture only SEEMS to show a shorter fade because its white is
/// clipped for the first ~8 video frames.
///
/// ONE DEVIATION FROM THE VENDORED SOURCE, and it is deliberate: PLZ.C exits on
/// `curpal==5`, i.e. after a FOURTH switch (to pals[3], "RB-white") at
/// timetable[3]=2259. The capture shows only THREE palettes — RGB, RB-black,
/// white — and the part ends 64 retraces after the third drop (the screen goes
/// black at capture 343.83, exactly drop3 + 64/70). So the shipped build broke
/// one palette earlier than the source in the tree does; we follow the capture
/// and stop at the third. pals[3] is still built (it is the original's data),
/// just never shown.
class PlasmaPart extends Part {
  /// STMIK ticks per second: MUSIC1 is tempo 130 throughout, and ST3's tick rate
  /// is tempo * 2 / 5. `dis_getmframe()` counts these.
  static const double kTickRate = 52.0;

  /// PLZ.C's timetable, in dis_getmframe() ticks. (The fourth entry, 2259, is
  /// the one the shipped build did not reach — see the class comment.)
  static const List<int> kTimeTable = [64 * 6 * 2 - 45, 64 * 6 * 4 - 45,
                                       64 * 6 * 5 - 45];

  /// Part-local seconds at which vect() takes over. Measured: the cube's first
  /// pixels are at capture 344.58 (a black-frame scan of 343.8-346.0; the plasma
  /// leaves at 343.83, and the 0.75s of black is vect()'s `while(dis_musplus()
  /// < 13)` gate plus its mode set). 344.58 + 0.20 - 307.09 = 37.69.
  static const double kCubeAt = 37.69;

  /// The cube's last frame: vect() breaks when dis_musplus() re-enters [-4,0).
  /// Measured — the screen goes black at capture 372.70 -> 372.90 here.
  static const double kEndAt = 65.81;

  static double get duration => kEndAt;

  static const int _rows = 280; // MAXY
  static const int _cols = 81; // byte columns needed for 320px + the 2px pan
  static const int _cubeRows = 134; // tw_opengraph: 134 rows of 3 scanlines
  static const int _cubeBytes = 160; // 640-pixel row pitch

  final _FlickerSurface _s = _FlickerSurface();

  @override
  IndexedSurface? get indexed => _s;

  late PlasmaTables _t;

  /// init_plz()'s five palettes. These are not DAC values but FADE DELTAS: the
  /// last thing init_plz does is `pals[0] = (pals[0]-63)*2` and `pals[1..4] *= 8`,
  /// because do_drop accumulates them into a 16.8 fixed-point `fadepal` and
  /// outputs its high byte (127 steps for pals[0], 31 for the rest).
  final List<Int16List> _pals = List.generate(6, (_) => Int16List(768));

  /// COPPER.ASM's `dtau` — the drop's gravity: `ccc*ccc/4*43/128+60`.
  final Int16List _dtau = Int16List(65);

  final Uint8List _dac = Uint8List(768);
  final Uint8List _kRow = Uint8List(_cols);
  final Uint8List _lRow = Uint8List(_cols);

  // --- the cube ---
  final List<Uint8List> _kuva = List.generate(3, (_) => Uint8List(128 * 256));
  final Uint8List _dist = Uint8List(128 * 256);
  final Uint8List _pal = Uint8List(768); // the three 64-colour texture banks
  final Uint8List _fpal = Uint8List(768); // ...shaded per face (shadepal)
  final Uint8List _vram = Uint8List(_cubeBytes * _cubeRows);
  final Int32List _px = Int32List(8 * 5); // xx,yy,zz,xxx,yyy per point

  /// VECT.C's cube and its face list (p1..p4 + the texture/palette bank).
  static const List<List<int>> _pnt = [
    [125, 125, 125], [125, -125, 125], [-125, -125, 125], [-125, 125, 125],
    [125, 125, -125], [125, -125, -125], [-125, -125, -125], [-125, 125, -125],
  ];
  static const List<List<int>> _face = [
    [1, 2, 3, 0, 0], [7, 6, 5, 4, 0], [0, 4, 5, 1, 1],
    [1, 5, 6, 2, 2], [2, 6, 7, 3, 1], [3, 7, 4, 0, 2],
  ];
  /// PLZFILL.C do_poly's fixed texture quad.
  static const List<List<int>> _txt = [[64, 4], [190, 4], [190, 60], [64, 60]];

  @override
  void init() {
    _t = AssetStore.plasma!;
    for (var c = 0; c <= 64; c++) {
      _dtau[c] = (c * c ~/ 4) * 43 ~/ 128 + 60;
    }
    _buildPalettes();
    _initvect();
    _s.palette = VgaPalette.black();
  }

  /// dart2js does bitwise ops on UNSIGNED 32-bit ints, so `>>` on a negative
  /// value is wrong there (it works in the VM and in tests — see the porting notes).
  static int _sar(int v, int n) => v >= 0 ? v >> n : -((-v - 1) >> n) - 1;

  // ---- PLZ.C init_plz ------------------------------------------------------

  void _buildPalettes() {
    final t = _t.ptau;
    void fill(int p, List<List<int>> seq) {
      var i = 3;
      for (final rgb in seq) {
        for (final v in rgb) {
          _pals[p][i++] = v;
        }
      }
    }

    List<List<int>> ramp(int n, List<int> Function(int) f) =>
        List.generate(n, f);

    // RGB
    fill(0, [
      ...ramp(63, (a) => [t[a + 1], t[0], t[0]]),
      ...ramp(64, (a) => [t[63 - a], t[0], t[0]]),
      ...ramp(64, (a) => [t[0], t[0], t[a]]),
      ...ramp(64, (a) => [t[a], t[0], t[63 - a]]),
    ]);
    // RB-black
    fill(1, [
      ...ramp(63, (a) => [t[a + 1], t[0], t[0]]),
      ...ramp(64, (a) => [t[63 - a], t[0], t[a]]),
      ...ramp(64, (a) => [t[0], t[a], t[63 - a]]),
      ...ramp(64, (a) => [t[a], t[63], t[a]]),
    ]);
    // RB-white (built, never shown — see the class comment)
    fill(3, [
      ...ramp(63, (a) => [t[a + 1], t[0], t[0]]),
      ...ramp(64, (a) => [t[63], t[a], t[a]]),
      ...ramp(64, (a) => [t[63 - a], t[63 - a], t[63]]),
      ...ramp(64, (a) => [t[0], t[0], t[63]]),
    ]);
    // white
    fill(2, [
      ...ramp(63, (a) => [t[0] ~/ 2, t[0] ~/ 2, t[0] ~/ 2]),
      ...ramp(64, (a) => [t[a] ~/ 2, t[a] ~/ 2, t[a] ~/ 2]),
      ...ramp(64, (a) => [t[63 - a] ~/ 2, t[63 - a] ~/ 2, t[63 - a] ~/ 2]),
      ...ramp(64, (a) => [t[0] ~/ 2, t[0] ~/ 2, t[0] ~/ 2]),
    ]);
    // white II
    fill(4, [
      ...ramp(74, (a) {
        final v = t[63 - (a + 1) * 64 ~/ 75];
        return [v, v, v];
      }),
      ...ramp(106, (a) => [0, 0, 0]),
      ...ramp(75, (a) => [
            t[a * 64 ~/ 75] * 8 ~/ 10,
            t[a * 64 ~/ 75] * 9 ~/ 10,
            t[a * 64 ~/ 75]
          ]),
    ]);

    for (var i = 0; i < 768; i++) {
      _pals[0][i] = (_pals[0][i] - 63) * 2;
    }
    for (var p = 1; p < 5; p++) {
      for (var i = 0; i < 768; i++) {
        _pals[p][i] *= 8;
      }
    }
  }

  /// COPPER.ASM do_drop's palette fade: a 16.8 accumulator per DAC byte, from
  /// `start` (63 = the white screen the previous part left, 0 after a memset).
  void _fade(int pal, int steps, int start) {
    for (var i = 0; i < 768; i++) {
      final v = _sar((start << 8) + steps * _pals[pal][i], 8);
      _dac[i] = v < 0 ? 0 : (v > 63 ? 63 : v);
    }
    _s.palette.bytes.setRange(0, 768, _dac);
  }

  // ---- ASMYT.ASM plzline ---------------------------------------------------

  void _plzRow(Uint8List out, int y, int p1, int p2, int p3, int p4) {
    final psini = _t.psini, l4 = _t.lsini4, l16 = _t.lsini16;
    for (var c = 0; c < _cols; c++) {
      final s = l16[(80 - c) * 4 + p2 + y];
      final a = psini[c * 8 + p1 + s];
      final u = l4[c * 16 + p4 + y];
      final b = psini[(80 - c) * 4 + p3 + 2 * y + u];
      out[c] = (a + b) & 255;
    }
  }

  // ---- the plz() frame -----------------------------------------------------

  int _switchFrame(int i) =>
      ((kTimeTable[i] + 1) / kTickRate * kDemoFps).ceil();

  void _plasma(int f) {
    // Which palette is up, and when its drop started.
    var phase = 0;
    for (var i = 0; i < kTimeTable.length; i++) {
      if (f >= _switchFrame(i)) phase = i + 1;
    }

    var lc = 60; // pompota holds the split at 60/61 whenever do_drop is idle
    int fadePal, fadeSteps;
    if (phase == 0) {
      fadePal = 0;
      fadeSteps = math.min(f, 127); // cop_drop 128..255
    } else {
      final df = f - _switchFrame(phase - 1); // retraces since cop_drop = 1
      if (df >= 1 && df <= 63) {
        lc = _dtau[df + 1]; // the drop (do_drop incs before it reads dtau)
      } else if (df == 64) {
        lc = 400; // @@l5: the split is disabled for one frame
      }
      if (df <= 64) {
        // Still showing the OLD palette, fully faded.
        fadePal = phase - 1;
        fadeSteps = phase == 1 ? 127 : 31;
      } else {
        fadePal = phase;
        fadeSteps = math.min(df - 64, 31);
      }
    }
    _fade(fadePal, fadeSteps, fadePal == 0 ? 63 : 0);

    // moveplz, from the last initpparas (which is what makes every phase after
    // the first EXACT: the parameters are reloaded from inittable).
    var base = 0, reset = 0;
    for (var p = 1; p <= phase; p++) {
      final rf = _switchFrame(p - 1) + 64;
      if (f >= rf) {
        base = p;
        reset = rf;
      }
    }
    final n = f - reset;
    final it = _inittable[base];
    final k1 = (it[4] - 3 * n) & 4095, k2 = (it[5] - 2 * n) & 4095;
    final k3 = (it[6] + n) & 4095, k4 = (it[7] + 2 * n) & 4095;
    final l1 = (it[0] - n) & 4095, l2 = (it[1] - 2 * n) & 4095;
    final l3 = (it[2] + 2 * n) & 4095, l4 = (it[3] + 3 * n) & 4095;

    final a = _s.pixels, b = _s.planeB;
    a.fillRange(0, a.length, 0);
    b.fillRange(0, b.length, 0);
    for (var my = 0; my < _rows; my++) {
      final yA = my + lc, yB = my + lc + 1;
      if (yA >= 400 && yB >= 400) break;
      _plzRow(_kRow, my, k1, k2, k3, k4);
      _plzRow(_lRow, my, l1, l2, l3, l4);
      // Field A: pan 2px, split at lc. Field B: pan 0, split at lc+1. The
      // checkerboard lives in VRAM (k on the odd pixels of even memory rows),
      // so it is (mx + my) that picks the plasma, not the scanline.
      if (yA >= 0 && yA < 400) {
        final o = yA * 320;
        for (var x = 0; x < 320; x++) {
          final mx = x + 2;
          a[o + x] = ((mx + my) & 1) != 0 ? _kRow[mx >> 2] : _lRow[mx >> 2];
        }
      }
      if (yB >= 0 && yB < 400) {
        final o = yB * 320;
        for (var x = 0; x < 320; x++) {
          b[o + x] = ((x + my) & 1) != 0 ? _kRow[x >> 2] : _lRow[x >> 2];
        }
      }
    }
  }

  /// PLZ.C's inittable — the parameters initpparas reloads at each palette
  /// switch (l1..l4 then k1..k4). Row 0 is also the file-scope initialiser.
  static const List<List<int>> _inittable = [
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
    [1000, 2000, 4000, 4000, 1500, 2300, 3900, 1670],
    [3500, 1000, 3000, 1000, 3500, 3300, 2900, 2670],
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
    [1000, 2000, 3000, 4000, 3500, 2300, 3900, 3670],
  ];

  // ---- PLZFILL.C initvect --------------------------------------------------

  void _initvect() {
    final sini = Int16List(2000);
    for (var a = 0; a < 2000; a++) {
      sini[a] = (math.sin(a / 1024.0 * math.pi * 4) * 127).toInt();
    }
    for (var y = 0; y < 64; y++) {
      for (var x = 0; x < 256; x++) {
        // `~/`, not `>>`: C's division truncates TOWARD ZERO and sini is signed.
        final v = sini[(y * 4 + sini[x * 2]) & 511] ~/ 4 + 32;
        for (var c = 0; c < 3; c++) {
          _kuva[c][y * 256 + x] = (v + 64 * c) & 0xFF;
        }
      }
    }
    for (var y = 0; y < 128; y++) {
      final v = sini[y * 8] ~/ 3;
      for (var x = 0; x < 256; x++) {
        _dist[y * 256 + x] = v & 0xFF;
      }
    }
    for (var a = 1; a < 32; a++) {
      _pal[a * 3 + 2] = a * 2; // black-blue-white
    }
    for (var a = 0; a < 32; a++) {
      _pal[(a + 32) * 3] = a * 2;
      _pal[(a + 32) * 3 + 1] = a * 2;
      _pal[(a + 32) * 3 + 2] = 63;
    }
    for (var a = 0; a < 32; a++) {
      _pal[64 * 3 + a * 3] = a * 2; // black-red-yellow
      _pal[64 * 3 + (a + 32) * 3] = 63;
      _pal[64 * 3 + (a + 32) * 3 + 1] = a * 2;
    }
    for (var a = 0; a < 32; a++) {
      _pal[128 * 3 + a * 3] = a; // black-orange-violet
      _pal[128 * 3 + a * 3 + 2] = a * 2 ~/ 3;
      _pal[128 * 3 + (a + 32) * 3] = 31 - a;
      _pal[128 * 3 + (a + 32) * 3 + 1] = a * 2;
      _pal[128 * 3 + (a + 32) * 3 + 2] = 21;
    }
  }

  // ---- SPLINE.ASM getspl ---------------------------------------------------

  /// The eight channels of the path: tx, ty, dis, kx, ky, kz, ls_kx, ls_ky.
  final Int32List _spl = Int32List(8);

  void _getspl(int pos) {
    final seg = (pos >> 8) * 8;
    final u = pos & 255;
    final r = _t.rata, s = _t.spline;
    for (var c = 0; c < 8; c++) {
      final v = r[seg + 24 + c] * s[u] +
          r[seg + 16 + c] * s[u + 256] +
          r[seg + 8 + c] * s[u + 512] +
          r[seg + c] * s[u + 768];
      _spl[c] = _sar(v, 15);
    }
  }

  // ---- VECT.C --------------------------------------------------------------

  final List<int> _drawFace = [];
  final List<int> _drawShade = [];

  void _calculate(int frames) {
    _getspl(4 * 256 + frames * 4);
    final tx = _spl[0], ty = _spl[1], dis = _spl[2];
    final kx = _spl[3] & 1023, ky = _spl[4] & 1023, kz = _spl[5] & 1023;
    final lkx = _spl[6] & 1023, lky = _spl[7] & 1023;
    final sn = _t.sinit;
    final sx = sn[kx], sy = sn[ky], sz = sn[kz];
    final cx = _t.kosinit(kx), cy = _t.kosinit(ky), cz = _t.kosinit(kz);

    final lsY = _sar(_t.kosinit(lkx), 8);
    final lsX = _sar(_sar(sn[lkx], 8) * _sar(sn[lky], 8), 7);
    final lsZ = _sar(_sar(sn[lkx], 8) * _sar(_t.kosinit(lky), 8), 7);

    // count_const(). NOTE C's precedence: `a >> 15+7` is `a >> 22`.
    final cxx = _sar(cy * cz, 22), cxy = _sar(cy * sz, 22), cxz = _sar(-sy, 7);
    final cyx = _sar(_sar(sx * cz + 16384, 15) * sy - cx * sz, 22);
    final cyy = _sar(_sar(sx * sy + 16384, 15) * sz + cx * cz, 22);
    final cyz = _sar(cy * sx, 22);
    final czx = _sar(_sar(cx * cz + 16384, 15) * sy + sx * sz, 22);
    final czy = _sar(_sar(cx * sy + 16384, 15) * sz - sx * cz, 22);
    final czz = _sar(cy * cx, 22);

    for (var a = 0; a < 8; a++) {
      final x = _pnt[a][0], y = _pnt[a][1], z = _pnt[a][2];
      final xx = _sar(_sar(x * cxx, 1) + _sar(y * cxy, 1) + _sar(z * cxz, 1), 7) + tx;
      final yy = _sar(_sar(x * cyx, 1) + _sar(y * cyy, 1) + _sar(z * cyz, 1), 7) + ty;
      final zz = _sar(_sar(x * czx, 1) + _sar(y * czy, 1) + _sar(z * czz, 1), 7) + dis;
      _px[a * 5] = xx;
      _px[a * 5 + 1] = yy;
      _px[a * 5 + 2] = zz;
      _px[a * 5 + 3] = (xx * 256) ~/ zz + 320;
      _px[a * 5 + 4] = (yy * 142) ~/ zz + 66;
    }

    // sort_faces(): backface cull, then light each visible face and shade its
    // palette bank. (The original caches this in `lls[]` per polygon SLOT, so it
    // can leave a bank carrying another face's shade for a frame; we always
    // re-shade, which keeps the frame stateless — and so the seek instant.)
    _drawFace.clear();
    _drawShade.clear();
    for (var f = 0; f < 6; f++) {
      final p1 = _face[f][0], p2 = _face[f][1], p3 = _face[f][2];
      final x = _px[p1 * 5], y = _px[p1 * 5 + 1], z = _px[p1 * 5 + 2];
      final ax = _px[p2 * 5] - x, ay = _px[p2 * 5 + 1] - y, az = _px[p2 * 5 + 2] - z;
      final bx = _px[p3 * 5] - x, by = _px[p3 * 5 + 1] - y, bz = _px[p3 * 5 + 2] - z;
      final nx = ay * bz - az * by;
      final ny = az * bx - ax * bz;
      final nz = ax * by - ay * bx;
      if (-x * nx + -y * ny + -z * nz > 0) continue;
      final s = (lsX * nx + lsY * ny + lsZ * nz) ~/ 250000 + 32;
      _drawFace.add(f);
      _drawShade.add(s);
    }
    for (var i = 0; i < _drawFace.length; i++) {
      final bank = _face[_drawFace[i]][4];
      final sh = _drawShade[i].clamp(0, 64);
      for (var j = 0; j < 192; j++) {
        _fpal[bank * 192 + j] = (_pal[bank * 192 + j] * sh) >> 6;
      }
    }
  }

  // ---- PLZA.ASM do_block ---------------------------------------------------

  int _yy = 0;

  void _put(int y, int b, int tx, int ty, int bank, int dd) {
    if (b < 0 || b >= _cubeBytes) return;
    final a = (((ty >> 16) & 0xFF) << 8) | ((tx >> 16) & 0xFF);
    final si = _dist[(a + dd * 256) & 0x7FFF];
    _vram[y * _cubeBytes + b] = _kuva[bank][(a + si) & 0x7FFF];
  }

  /// PLZFILL.C do_poly: the quad is walked from its topmost vertex down both
  /// edge chains, and each scanline is filled at BYTE (4-pixel) granularity with
  /// the texture interpolated between the two chains. do_block leaves the two
  /// boundary bytes alone (do_clear masks them out), so the faces carry a thin
  /// dark seam — that is the original's, not a gap in ours.
  void _doPoly(List<int> px, List<int> py, int bank, int dd) {
    dd = (dd + 1) & 63;
    var n = 0;
    for (var a = 1; a < 4; a++) {
      if (py[a] < py[n]) n = a;
    }
    var s1 = n, s2 = n, d1 = (n + 1) & 3, d2 = (n - 1) & 3;

    var ax1 = 0, ax2 = 0, xx1 = 0, xx2 = 0;
    var txx1 = 0, txy1 = 0, txx2 = 0, txy2 = 0;
    var tax1 = 0, tay1 = 0, tax2 = 0, tay2 = 0;

    void edge1() {
      var dy = py[d1] - py[s1];
      if (dy == 0) dy++;
      ax1 = 65536 * (px[d1] - px[s1]) ~/ dy;
      xx1 = (px[s1] << 16) + 0x8000;
      txx1 = (_txt[s1][0] << 16) + 0x8000;
      txy1 = (_txt[s1][1] << 16) + 0x8000;
      tax1 = 65536 * (_txt[d1][0] - _txt[s1][0]) ~/ dy;
      tay1 = 65536 * (_txt[d1][1] - _txt[s1][1]) ~/ dy;
    }

    void edge2() {
      var dy = py[d2] - py[s2];
      if (dy == 0) dy++;
      ax2 = 65536 * (px[d2] - px[s2]) ~/ dy;
      xx2 = (px[s2] << 16) + 0x8000;
      txx2 = (_txt[s2][0] << 16) + 0x8000;
      txy2 = (_txt[s2][1] << 16) + 0x8000;
      tax2 = 65536 * (_txt[d2][0] - _txt[s2][0]) ~/ dy;
      tay2 = 65536 * (_txt[d2][1] - _txt[s2][1]) ~/ dy;
    }

    edge1();
    edge2();
    _yy = py[s1];
    var done = 0;
    while (done < 4) {
      final m = math.min(py[d1], py[d2]);
      final lines = m - _yy; // do_block(m - yy): the count is taken UP FRONT
      for (var i = 0; i < lines; i++) {
        if (_yy >= _cubeRows) return; // y-clip: do_block bails out entirely
        if (_yy >= 0) {
          final xl = _sar(xx2, 16), xr = _sar(xx1, 16);
          final di = _sar(xl, 2);
          final nb = _sar(xr, 2) - di;
          if (nb == 0 || nb == 1) {
            _put(_yy, di, txx2, txy2, bank, dd);
            if (nb == 1) _put(_yy, di + 1, txx1, txy1, bank, dd);
          } else if (nb > 1) {
            final steps = nb - 1;
            final addx = (txx2 - txx1) ~/ steps;
            final addy = (txy2 - txy1) ~/ steps;
            var tx = txx1, ty = txy1;
            for (var j = 0; j < steps; j++) {
              _put(_yy, di + nb - 1 - j, tx, ty, bank, dd);
              tx += addx;
              ty += addy;
            }
          }
        }
        _yy++;
        xx1 += ax1;
        xx2 += ax2;
        txx1 += tax1;
        txy1 += tay1;
        txx2 += tax2;
        txy2 += tay2;
      }
      _yy = m;
      if (py[d1] == py[d2]) {
        s1 = d1;
        d1 = (s1 + 1) & 3;
        s2 = d2;
        d2 = (s2 - 1) & 3;
        done += 2;
        edge1();
        edge2();
      } else if (py[d1] < py[d2]) {
        s1 = d1;
        d1 = (s1 + 1) & 3;
        done++;
        edge1();
      } else {
        s2 = d2;
        d2 = (s2 - 1) & 3;
        done++;
        edge2();
      }
    }
  }

  void _cube(int frames) {
    _calculate(frames);
    _s.palette.bytes.setRange(0, 768, _fpal);

    final px = List.filled(4, 0), py = List.filled(4, 0);
    for (var field = 0; field < 2; field++) {
      final off = field * 2; // swappage: page&1 draws at x+2, the pan takes it back
      _vram.fillRange(0, _vram.length, 0);
      for (var i = 0; i < _drawFace.length; i++) {
        final f = _face[_drawFace[i]];
        for (var v = 0; v < 4; v++) {
          px[v] = _px[f[v] * 5 + 3] + off;
          py[v] = _px[f[v] * 5 + 4];
        }
        _doPoly(px, py, f[4], frames & 63);
      }
      final out = field == 0 ? _s.pixels : _s.planeB;
      out.fillRange(0, out.length, 0);
      for (var y = 0; y < 400; y++) {
        final r = y ~/ 3;
        if (r >= _cubeRows) break;
        final src = r * _cubeBytes, dst = y * 320;
        for (var x = 0; x < 320; x++) {
          out[dst + x] = _vram[src + ((160 + x + off) >> 2)];
        }
      }
    }
  }

  @override
  void update(double t, List<int> syncCodes) {
    final f = math.max(0, (t * kDemoFps).floor());
    if (t < kCubeAt) {
      // plz() runs out 64 retraces after the last drop starts; the screen is
      // then black until vect()'s music gate.
      if (f < _switchFrame(kTimeTable.length - 1) + 65) {
        _plasma(f);
        return;
      }
      _blank();
      return;
    }
    if (t > kEndAt) {
      _blank();
      return;
    }
    _cube(((t - kCubeAt) * kDemoFps).floor());
  }

  void _blank() {
    _s.pixels.fillRange(0, _s.pixels.length, 0);
    _s.planeB.fillRange(0, _s.planeB.length, 0);
    _s.palette.bytes.fillRange(0, 768, 0);
  }
}

/// The two 70 Hz fields, averaged.
///
/// PLZPART draws a per-pixel checkerboard of two plasmas (and, in the cube, a
/// 4-pixel-quantised polygon) and then flickers the split line and the pixel pan
/// every retrace, so consecutive frames carry the two halves of the picture. On
/// a 70 Hz CRT the eye integrates them; a single field, blown up on a modern
/// display, is a hard dither the original never showed. So the part fills BOTH
/// fields and this surface averages them in RGB on the way out — one extra byte
/// plane and one add per pixel, no change to any of the demo's own math.
class _FlickerSurface extends IndexedSurface {
  final Uint8List planeB;

  _FlickerSurface()
      : planeB = Uint8List(320 * 400),
        super(320, 400);

  static int _to8(int v6) => (v6 << 2) | (v6 >> 4);

  @override
  Uint8List toRgbaBytes() {
    final out = Uint8List(width * height * 4);
    final p = palette.bytes;
    final r = Uint8List(256), g = Uint8List(256), b = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      r[i] = _to8(p[i * 3]);
      g[i] = _to8(p[i * 3 + 1]);
      b[i] = _to8(p[i * 3 + 2]);
    }
    var o = 0;
    for (var i = 0; i < pixels.length; i++) {
      final a = pixels[i], c = planeB[i];
      out[o++] = (r[a] + r[c]) >> 1;
      out[o++] = (g[a] + g[c]) >> 1;
      out[o++] = (b[a] + b[c]) >> 1;
      out[o++] = 0xFF;
    }
    return out;
  }
}
