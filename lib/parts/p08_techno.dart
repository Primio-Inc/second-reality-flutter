import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 8 — the techno boxes and the troll (TECHNO/KOE.C, everything after the
/// interference: the white wipe, `doit1`/`doit2`/`doit3`, then TROLL.UP).
///
/// The whole thing runs in a 16-colour PLANAR mode (4 bitplanes, 40 bytes a
/// row), and the effect is a hardware trick rather than a drawing one:
///
///  - Each frame the rotating quads are XOR-outlined into a 1-bit buffer
///    (`vbuf`, 8000 bytes) — one bit per pixel, edges only. `blit16` then fills
///    them by running a prefix-XOR along each row: bit i of the output byte is
///    the parity of the input bits at and left of it, so every span between two
///    edge crossings comes out solid. That is the entire polygon filler.
///  - The filled bitmap is written into ONE plane (`pl` = 1,2,4,8) of ONE of
///    eight 8KB pages (`plv`), and that page is the one displayed. `plv` steps
///    every frame and `pl` only shifts when `plv` wraps, so the four planes of
///    any given page were written 8, 16, 24 and 32 frames apart. The colour
///    index of a pixel is therefore "which of the last four passes covered me",
///    and the palette turns that into a lavender shade by POPCOUNT. The ghost
///    trails are free.
///  - `waitborder` reloads the palette every frame from one of 16 pre-brightened
///    copies, latching the brightest on every 8th music row and decaying it —
///    the beat flash.
///
/// We emulate the VGA itself (a 64K byte-addressed planar memory, plus the CRTC
/// start address / pixel pan) rather than the drawing, so the page cycling, the
/// plane masking and `doit3`'s hardware scroll-off all fall out on their own.
class TechnoPart extends Part {
  TechnoPart();

  // ---- music sync --------------------------------------------------------
  //
  // `waitborder()` flashes on every 8th music ROW and the column wipe waits for
  // that same row, so this part rides the real row grid (MusicRows = the
  // engine's `dis_musrow()`), not a fitted beat period. A fitted period walks
  // off the music; the row clock cannot, because it IS the music.

  /// Before the wipe, KOE.C switches video mode, clears all eight pages, fills
  /// page 0 white and waits on `dis_musplus()` — and only THEN waits for a
  /// `row & 7 == 7` row. That music-position gate carries the white past the
  /// first such row (186.700s), so the wipe starts on the next one: 187.141s in
  /// the row table, which is where the capture's white ends. We hold white for
  /// at least this long (part-local) and take the first flash row after it.
  static const double kWhiteHold = 0.5;

  /// Part-local seconds at which the troll picture starts sliding in. In the
  /// original this is a disk load (`open("troll.up")`) followed by a wait for
  /// music order 35 row 48; the capture's first troll pixel is at 217.90s
  /// absolute (tool/analyze_video.py --scan 216.3 219 30), i.e. 31.60s in.
  static const double kTrollAt = 31.60;

  final IndexedSurface _s = IndexedSurface(320, 200);
  final IndexedSurface _pic = IndexedSurface(320, 400);
  bool _onPic = false;

  @override
  IndexedSurface? get indexed => _onPic ? _pic : _s;

  // ---- emulated VGA ------------------------------------------------------

  /// 64K of planar video memory, unpacked: one byte per (address, bit) pair
  /// holding that pixel's 4 plane bits. `_vga[addr << 3 | bit]`.
  final Uint8List _vga = Uint8List(65536 * 8);
  int _startAddr = 0; // CRTC 0x0C/0x0D — displayed page + scroll
  int _stride = 40; // CRTC 0x13 — bytes per row
  int _pan = 0; // attribute 0x13 — horizontal pixel pan

  /// The 1-bit XOR-edge buffer the quads are drawn into (200 rows x 40 bytes).
  final Uint8List _vbuf = Uint8List(8000);

  /// `blit16t`: prefix-XOR fill. `_fill[carry << 8 | byte]` is the filled byte;
  /// its bit 0 is the carry into the next byte (the original keeps that in dh).
  static final Uint8List _fill = _buildFill();

  static Uint8List _buildFill() {
    final t = Uint8List(512);
    for (var carry = 0; carry < 2; carry++) {
      for (var b = 0; b < 256; b++) {
        var acc = carry, out = 0;
        for (var i = 7; i >= 0; i--) {
          acc ^= (b >> i) & 1;
          out |= acc << i;
        }
        t[carry << 8 | b] = out;
      }
    }
    return t;
  }

  static final Int16List _sin = _buildSin();

  /// SIN1024.INC — verified byte-exact against `trunc(256*sin(2*pi*k/1024))`.
  static Int16List _buildSin() {
    final s = Int16List(1024);
    for (var k = 0; k < 1024; k++) {
      s[k] = (256 * math.sin(k * 2 * math.pi / 1024)).truncate();
    }
    return s;
  }

  int _sin1024(int i) => _sin[i & 1023];

  // ---- palettes ----------------------------------------------------------

  /// The 16 pre-brightened 16-colour palettes (KOE.C's `pal`). Colour `a` is
  /// keyed by POPCOUNT(a) — how many of the four passes covered the pixel —
  /// and copy `c` is that ramp scaled up, `c` = 15 being the beat flash.
  final List<Uint8List> _pal = [];

  /// `flash()`'s captured base palette (`pal1`), 16 entries x rgb.
  final Uint8List _pal1 = Uint8List(48);

  void _buildPalettes() {
    const shade = [
      [0, 0, 0],
      [38 * 64 ~/ 111, 33 * 64 ~/ 111, 44 * 64 ~/ 111],
      [52 * 64 ~/ 111, 45 * 64 ~/ 111, 58 * 64 ~/ 111],
      [67 * 64 ~/ 111, 61 * 64 ~/ 111, 73 * 64 ~/ 111],
      [83 * 64 ~/ 111, 77 * 64 ~/ 111, 89 * 64 ~/ 111],
    ];
    for (var c = 0; c < 16; c++) {
      final p = Uint8List(48);
      for (var a = 0; a < 16; a++) {
        final bits = shade[_popcount(a)];
        final gain = [10 + c, 10 + c * 7 ~/ 9, 10 + c * 5 ~/ 9];
        for (var k = 0; k < 3; k++) {
          p[a * 3 + k] = math.min(63, bits[k] * gain[k] ~/ 10);
        }
      }
      _pal.add(p);
    }
  }

  static int _popcount(int a) =>
      (a & 1) + ((a >> 1) & 1) + ((a >> 2) & 1) + ((a >> 3) & 1);

  /// `flash(i)`: cross-fade the captured palette to white. i=256 is full white,
  /// i=0 is the captured palette itself.
  void _flash(int i) {
    final pal = VgaPalette.black();
    final j = 256 - i;
    for (var a = 0; a < 16; a++) {
      pal.setRgb(
        a,
        (_pal1[a * 3] * j + 63 * i) >> 8,
        (_pal1[a * 3 + 1] * j + 63 * i) >> 8,
        (_pal1[a * 3 + 2] * j + 63 * i) >> 8,
      );
    }
    _s.palette = pal;
  }

  void _setPal(int curpal) {
    final p = _pal[curpal];
    final pal = VgaPalette.black();
    for (var a = 0; a < 16; a++) {
      pal.setRgb(a, p[a * 3], p[a * 3 + 1], p[a * 3 + 2]);
    }
    _s.palette = pal;
  }

  // ---- VGA writes --------------------------------------------------------

  void _writeByte(int addr, int mask, int bits) {
    final base = (addr & 0xffff) << 3;
    for (var i = 0; i < 8; i++) {
      final p = _vga[base + i];
      _vga[base + i] =
          (bits >> (7 - i)) & 1 == 1 ? p | mask : p & (~mask & 15);
    }
  }

  /// `memset(vram, v, n)` with all four planes selected.
  void _memset(int addr, int value, int count) {
    final v = value == 0 ? 0 : 15;
    for (var i = 0; i < count; i++) {
      final base = ((addr + i) & 0xffff) << 3;
      for (var k = 0; k < 8; k++) {
        _vga[base + k] = v;
      }
    }
  }

  /// `blit16`/`blit16b`: fill `_vbuf` by prefix-XOR and write it into the
  /// plane(s) `mask` of the page at `base`, `stride` bytes a row.
  void _blitFilled(int base, int stride, int mask) {
    var src = 0;
    for (var y = 0; y < 200; y++) {
      var carry = 0;
      final row = base + y * stride;
      for (var i = 0; i < 40; i++) {
        final t = _fill[carry << 8 | _vbuf[src++]];
        carry = t & 1;
        _writeByte(row + i, mask, t);
      }
    }
  }

  void _present() {
    final px = _s.pixels;
    for (var y = 0; y < 200; y++) {
      final row = _startAddr + y * _stride;
      final o = y * 320;
      for (var x = 0; x < 320; x++) {
        final xx = x + _pan;
        px[o + x] = _vga[((row + (xx >> 3)) & 0xffff) << 3 | (xx & 7)];
      }
    }
  }

  // ---- the polygon pipeline (KOEA.ASM drawline + POLYCLIP.ASM) -----------

  static const int _wminx = 0, _wmaxx = 319, _wminy = 0, _wmaxy = 199;

  /// `drawline`: XOR exactly one pixel per scanline into `_vbuf`, for rows
  /// y1..y2-1. Horizontal edges contribute nothing — that is what makes the
  /// prefix-XOR fill come out right.
  void _drawLine(int x1, int y1, int x2, int y2) {
    if (y1 == y2) return;
    if (y1 > y2) {
      final tx = x1, ty = y1;
      x1 = x2;
      y1 = y2;
      x2 = tx;
      y2 = ty;
    }
    final dy = y2 - y1;
    final sx = x2 >= x1 ? 1 : -1;
    final adx = (x2 - x1).abs();
    var err = -(dy >> 1);
    var x = x1, y = y1, count = dy;
    while (true) {
      _vbuf[y * 40 + (x >> 3)] ^= 0x80 >> (x & 7);
      y++;
      if (--count == 0) return;
      err += adx;
      while (err >= 0) {
        x += sx;
        err -= dy;
      }
    }
  }

  /// `clipmacro`: move (v,w) along the segment until w == wl.
  static int _interp(int v1, int v2, int w1, int w2, int wl) {
    if (w2 == w1) return v1;
    return v1 + (v2 - v1) * (wl - w1) ~/ (w2 - w1);
  }

  /// `cliplinex`/`clipliney` in one: clip a segment against [lo,hi] on one
  /// axis. Returns null when the whole segment is outside (the original's
  /// "trivially rejected" return, which drops the edge entirely).
  static List<int>? _clipSeg(List<int> p, int axis, int lo, int hi) {
    var a0 = p[0], a1 = p[1], b0 = p[2], b1 = p[3];
    int key(int u, int v) => axis == 0 ? u : v;
    var fa = 0, fb = 0;
    if (key(a0, a1) < lo) fa |= 1;
    if (key(a0, a1) > hi) fa |= 2;
    if (key(b0, b1) < lo) fb |= 1;
    if (key(b0, b1) > hi) fb |= 2;
    if (fa & fb != 0) return null;

    // x-axis: interpolate y against x; y-axis: interpolate x against y.
    void clipA(int wl) {
      if (axis == 0) {
        a1 = _interp(a1, b1, a0, b0, wl);
        a0 = wl;
      } else {
        a0 = _interp(a0, b0, a1, b1, wl);
        a1 = wl;
      }
    }

    void clipB(int wl) {
      if (axis == 0) {
        b1 = _interp(b1, a1, b0, a0, wl);
        b0 = wl;
      } else {
        b0 = _interp(b0, a0, b1, a1, wl);
        b1 = wl;
      }
    }

    if (fa & 1 != 0) clipA(lo);
    if (fa & 2 != 0) clipA(hi);
    if (fb & 1 != 0) clipB(lo);
    if (fb & 2 != 0) clipB(hi);
    return [a0, a1, b0, b1];
  }

  /// `clipanypoly`: clip every edge of the polygon against y, then against x,
  /// emitting the clipped endpoints and dropping consecutive duplicates.
  static List<int> _clipPass(List<int> xy, int axis, int lo, int hi) {
    final n = xy.length ~/ 2;
    final out = <int>[];
    int? lx, ly;
    void emit(int x, int y) {
      if (lx == x && ly == y) return;
      out.add(x);
      out.add(y);
      lx = x;
      ly = y;
    }

    for (var i = 0; i < n; i++) {
      final j = (i + n - 1) % n; // the edge is prev -> cur
      final seg = _clipSeg(
          [xy[j * 2], xy[j * 2 + 1], xy[i * 2], xy[i * 2 + 1]], axis, lo, hi);
      if (seg == null) continue;
      emit(seg[0], seg[1]);
      emit(seg[2], seg[3]);
    }
    if (out.length >= 4 && out[0] == lx && out[1] == ly) {
      out.removeRange(out.length - 2, out.length);
    }
    return out;
  }

  /// `asmbox`: clip the quad, then XOR its edges into `_vbuf`.
  void _box(int x1, int y1, int x2, int y2, int x3, int y3, int x4, int y4) {
    var p = _clipPass([x1, y1, x2, y2, x3, y3, x4, y4], 1, _wminy, _wmaxy);
    if (p.length < 4) return;
    p = _clipPass(p, 0, _wminx, _wmaxx);
    final n = p.length ~/ 2;
    if (n < 2) return;
    for (var i = 0; i < n; i++) {
      final j = (i + 1) % n;
      _drawLine(p[i * 2], p[i * 2 + 1], p[j * 2], p[j * 2 + 1]);
    }
  }

  /// The 11 stacked quads of `doit1`/`doit2`/`doit3`: one rotating bar,
  /// repeated along its own thin axis. `hx/hy` is the long axis (16x bigger, so
  /// the bars run right off both sides of the screen), `vx/vy` the short one,
  /// squeezed by the bouncing `vm`.
  void _drawBars(int rot, int vmScaled, int wx, int wy) {
    final hx = _sin1024(rot) * 16 * 6 ~/ 5;
    final hy = _sin1024(rot + 256) * 16;
    var vx = _sin1024(rot + 256) * 6 ~/ 5;
    var vy = _sin1024(rot + 512);
    vx = vx * vmScaled ~/ 100;
    vy = vy * vmScaled ~/ 100;
    for (var c = -10; c < 11; c += 2) {
      final cx = vx * c * 2, cy = vy * c * 2;
      _box(
        (-hx - vx + cx) ~/ 16 + wx, (-hy - vy + cy) ~/ 16 + wy,
        (-hx + vx + cx) ~/ 16 + wx, (-hy + vy + cy) ~/ 16 + wy,
        (hx + vx + cx) ~/ 16 + wx, (hy + vy + cy) ~/ 16 + wy,
        (hx - vx + cx) ~/ 16 + wx, (hy - vy + cy) ~/ 16 + wy,
      );
    }
  }

  // ---- state machine -----------------------------------------------------

  static const int _phWhite = 0,
      _phWipe = 1,
      _phDoit1 = 2,
      _phDoit2 = 3,
      _phDoit3 = 4,
      _phBlack = 5,
      _phTrollIn = 6,
      _phTrollRipple = 7,
      _phTrollHold = 8;

  int _phase = _phWhite;

  /// Phase index — offline sync check only (test/scratch_techno_sync_test).
  int get debugPhase => _phase;

  int _frame = 0; // frames simulated (70 Hz)
  int _beat = -1; // last music row index seen
  double _partStart = 0; // soundtrack seconds at this part's frame 0

  // waitborder
  int _curpal = 0;

  // page cycling
  int _pl = 1, _plv = 0;

  // the wipe
  int _wipeStrip = 0, _wipeA = 256, _wipeZy = 0, _wipeZya = 0, _wipeFlash = -1;
  bool _wipeWaiting = false;

  // doit1/2/3
  int _count = 0, _rot = 0, _rota = 10, _rot2 = 0, _vm = 0, _vma = 0;
  int _xpos = 320, _xposa = 0;

  // troll
  late Uint8List _trollField; // 640x400, the picture in its right half
  int _ripple = 0, _ripplep = 8, _rippleC = 0;

  @override
  void init() {
    _buildPalettes();
    final troll = AssetStore.images['troll']!;
    _trollField = Uint8List(640 * 400);
    for (var y = 0; y < 400; y++) {
      for (var x = 0; x < 320; x++) {
        _trollField[y * 640 + 320 + x] = troll.pixels[y * 320 + x];
      }
    }
    _pic.palette = troll.palette;

    // main(): the mode is set up, all eight pages cleared, and page 0 filled
    // white. `flash(-1)` has just captured the palette the interference ended
    // on and ramped it to white, and `ip` is then overwritten with the blue
    // ramp the wipe fades back down to.
    _memset(0, 0, 64000);
    _memset(0, 255, 8000);
    for (var a = 0; a < 16; a++) {
      _pal1[a * 3] = a * 6 ~/ 2;
      _pal1[a * 3 + 1] = a * 7 ~/ 2;
      _pal1[a * 3 + 2] = a * 8 ~/ 2;
    }
    _flash(256);
    _present();
  }

  /// `waitborder()`'s row test: true on the first frame of a NEW music row
  /// whose `row & 7 == 7` — the original latches its flash there, and the wipe
  /// waits for it. [frame] is this part's 70 Hz frame; the row clock is in
  /// soundtrack time, so go through the part's start.
  bool _onBeat(int frame) {
    final rows = AssetStore.musicRows;
    if (rows == null) return false;
    final i = rows.indexAt(_partStart + frame / kDemoFps);
    if (i < 0 || i == _beat) return false;
    _beat = i;
    return rows.rows[i] & 7 == 7;
  }

  /// `waitborder()`: latch the flash palette on the beat, then decay it.
  void _waitBorder(int frame) {
    if (_onBeat(frame)) _curpal = 15;
    _setPal(_curpal);
    if (_curpal > 0) _curpal--;
  }

  /// One 70 Hz frame of the original's main loop.
  void _step() {
    final f = _frame;
    switch (_phase) {
      case _phWhite:
        // Hold white until the flash row the wipe starts on.
        if (_onBeat(f) && f / kDemoFps >= kWhiteHold) {
          _phase = _phWipe;
          _wipeStrip = 0;
          _wipeA = 256;
          _wipeZy = 0;
          _wipeZya = 0;
          _wipeWaiting = false;
          _stepWipe();
        }
        break;
      case _phWipe:
        _stepWipe();
        break;
      case _phDoit1:
        _waitBorder(f);
        _renderBars(_rot, _vm, 160, 100);
        _rot += 2;
        _vm += _vma;
        if (_vm < 25) {
          _vm -= _vma;
          _vma = -_vma;
        }
        _vma--;
        _flip(1);
        if (--_count <= 0) {
          _phase = _phDoit2;
          _count = 70 * 12;
          _rot = 50;
          _rota = 10;
          _vm = 100 * 64;
          _vma = 0;
          _pl = 1;
          _plv = 0;
        }
        break;
      case _phDoit2:
        _waitBorder(f);
        _renderBars(_rot, _vm ~/ 64, 160, 100);
        _rot += _rota ~/ 10;
        _vm += _vma;
        if (_vm < 0) {
          _vm -= _vma;
          _vma = -_vma;
        }
        _vma--;
        _rota++;
        _flip(1);
        if (--_count <= 0) _startDoit3();
        break;
      case _phDoit3:
        _stepDoit3(f);
        break;
      case _phBlack:
        if (f / kDemoFps >= kTrollAt) {
          _onPic = true;
          _phase = _phTrollIn;
          _xpos = 0;
          _xposa = 0;
          _presentPic(0);
        }
        break;
      case _phTrollIn:
        _xpos += _xposa ~/ 4;
        if (_xpos > 320) {
          _xpos = 320;
        } else {
          _xposa++;
        }
        _presentPic(_xpos);
        if (_xpos == 320) {
          _phase = _phTrollRipple;
          _count = 50;
          _ripple = 0;
          _ripplep = 8;
          _rippleC = 0;
        }
        break;
      case _phTrollRipple:
        _ripplep = _ripplep > 1023 ? 1024 : _ripplep * 5 ~/ 4;
        _presentPic(320 + _sin1024(_ripple) ~/ _ripplep);
        _ripple += _ripplep + 100;
        // palfade: the picture lands blown out (+45 on every channel) and
        // settles to its own palette over 16 frames.
        if (_rippleC < 16) {
          _setPicPalette(45 - _rippleC * 3);
          _rippleC++;
        }
        if (--_count <= 0) {
          _setPicPalette(0);
          _phase = _phTrollHold;
        }
        break;
      case _phTrollHold:
        break;
    }
    _frame++;
  }

  /// `memset(vbuf,0,8000)` + the quads + `asmdoit(vbuf,vram)`: XOR-outline the
  /// bars, prefix-XOR them into solid spans, and write those into plane `_pl`
  /// of page `_plv`.
  void _renderBars(int rot, int vmScaled, int wx, int wy) {
    _vbuf.fillRange(0, _vbuf.length, 0);
    _drawBars(rot, vmScaled, wx, wy);
    final doit3 = _phase == _phDoit3;
    _blitFilled(_plv * 0x2000 + (doit3 ? 40 : 0), doit3 ? 80 : 40, _pl);
  }

  /// The page/plane flip at the bottom of every `doit`: show the page we just
  /// wrote, step to the next one, and shift the plane mask when we wrap.
  void _flip(int plvStep) {
    _startAddr = _plv * 0x2000 + (_phase == _phDoit3 ? _xpos >> 3 : 0);
    _pan = _phase == _phDoit3 ? _xpos & 7 : 0;
    _present();
    _plv = (_plv + plvStep) & 7;
    if (_plv == 0) {
      _pl <<= 1;
      if (_pl > 15) _pl = 1;
    }
  }

  void _stepWipe() {
    if (_wipeWaiting) {
      // Between strips the original waits for the next 8th row, then flashes
      // the palette back to white over four frames (32, 64, 192, 256).
      if (_wipeFlash >= 0) {
        const ramp = [32, 64, 192, 256];
        _flash(ramp[_wipeFlash]);
        _present();
        _wipeFlash++;
        if (_wipeFlash == 4) {
          _wipeFlash = -1;
          _wipeWaiting = false;
          _wipeStrip++;
          _wipeA = 256;
          _wipeZy = 0;
          _wipeZya = 0;
          if (_wipeStrip == 4) {
            // dis_partstart(); doit1(70*6);
            _phase = _phDoit1;
            _count = 70 * 6;
            _rot = 45;
            _vm = 50;
            _vma = 0;
            _pl = 1;
            _plv = 0;
            _curpal = 0;
          }
        }
        return;
      }
      if (_onBeat(_frame)) _wipeFlash = 0;
      return;
    }

    // One step of the falling strip: clear rows [zly, zy) of this 80-pixel
    // column (10 bytes), and fade the palette from white back to the blue ramp.
    final zly = _wipeZy;
    _wipeZya++;
    _wipeZy += _wipeZya;
    for (var y = zly; y < _wipeZy && y < 200; y++) {
      _memset(y * 40 + _wipeStrip * 10, 0, 10);
    }
    _flash(_wipeA > 0 ? _wipeA : 0);
    _present();
    _wipeA -= 32;
    if (_wipeA <= -400) _wipeWaiting = true;
  }

  void _startDoit3() {
    _phase = _phDoit3;
    _count = 70 * 14;
    _rot = 45;
    _rota = 10;
    _rot2 = 0;
    _vm = 100 * 64;
    _vma = 0;
    _pl = 1;
    _plv = 0;
    _xpos = 320;
    _xposa = 0;
    // A 640-pixel-wide virtual screen (80 bytes a row): the boxes are drawn in
    // its right half and the scroll walks the window left into black.
    _stride = 80;
    _memset(0, 0, 65536);
  }

  void _stepDoit3(int f) {
    // The wobble the whole stack of bars now rides on.
    final int wx, wy;
    if (_rot2 < 32) {
      wx = _sin1024(_rot2) * _rot2 ~/ 8 + 160;
      wy = _sin1024(_rot2 + 256) * _rot2 ~/ 8 + 100;
    } else {
      wx = _sin1024(_rot2) ~/ 4 + 160;
      wy = _sin1024(_rot2 + 256) ~/ 4 + 100;
    }
    _rot2 += 17;

    _waitBorder(f);
    _count--;
    if (_count < 333) {
      // The scroll-off: the window accelerates left into the black half.
      _xpos -= _xposa ~/ 4;
      if (_xpos < 0) {
        _xpos = 0;
      } else {
        _xposa++;
      }
      if (_xpos == 0) {
        _phase = _phBlack;
        _s.pixels.fillRange(0, _s.pixels.length, 0);
        return;
      }
    }

    _renderBars(_rot, _vm ~/ 64, wx, wy);
    _rot += _rota ~/ 10;
    _vm += _vma;
    if (_vm < 0) {
      _vm -= _vma;
      _vma = -_vma;
    }
    _vma--;
    _rota++;
    _flip(2);
  }

  /// The troll runs in the 320x400 tweaked mode: a 640-wide virtual screen with
  /// the picture in its right half, scrolled in from the right.
  void _presentPic(int xpos) {
    final px = _pic.pixels;
    for (var y = 0; y < 400; y++) {
      final src = y * 640 + xpos;
      final dst = y * 320;
      for (var x = 0; x < 320; x++) {
        final i = src + x;
        px[dst + x] = i < _trollField.length ? _trollField[i] : 0;
      }
    }
  }

  void _setPicPalette(int add) {
    final base = AssetStore.images['troll']!.palette;
    if (add == 0) {
      _pic.palette = base;
      return;
    }
    final pal = VgaPalette.black();
    for (var i = 0; i < 768; i++) {
      pal.bytes[i] = math.min(63, base.bytes[i] + add);
    }
    _pic.palette = pal;
  }

  @override
  void update(double t, List<int> syncCodes) {
    _partStart = musicTime - t;
    final target = (t * kDemoFps).floor();
    if (target < _frame) {
      // Seeking backwards: the effect is a running accumulation (eight pages of
      // plane history), so there is nothing to do but replay it from the start.
      _reset();
    }
    var budget = 4000; // bounded catch-up, so a seek can never hang a frame
    while (_frame < target && budget-- > 0) {
      _step();
    }
    if (_frame < target) _frame = target;
  }

  void _reset() {
    _vga.fillRange(0, _vga.length, 0);
    _vbuf.fillRange(0, _vbuf.length, 0);
    _phase = _phWhite;
    _frame = 0;
    _beat = -1;
    _curpal = 0;
    _pl = 1;
    _plv = 0;
    _startAddr = 0;
    _stride = 40;
    _pan = 0;
    _onPic = false;
    _pal.clear();
    init();
  }
}
