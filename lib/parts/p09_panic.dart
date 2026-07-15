import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/vga_palette.dart';

/// Part 9 — the "panic" TV power-off (PANIC/SHUTDOWN.C, built as PANICEND.EXE
/// and run straight after TECHNO in MAIN/U2.ASM).
///
/// There is no new picture here: the part shuts down whatever is already on the
/// screen, which is TECHNO's troll. (`SHUTDOWN.C` is compiled with `_LOADER_`
/// defined, so it never loads MONSTER.U — it calls `getpal()` to read back the
/// palette the previous part left in the DAC and works on the video memory it
/// inherited.)
///
/// It is a hardware effect, not a drawing one, so we emulate the VGA the way
/// TECHNO does rather than imitating the look:
///
///  - The mode is TWEAK.ASM's 4-plane 320x400: 400 scanlines, a 160-byte row
///    pitch = a 640-pixel-wide virtual screen of which 320 are displayed. The
///    picture sits in the RIGHT half (x >= 320) at double height; the left half
///    is the scratch area the shutdown composes in.
///  - `shutdown()` first resamples the picture down into 100 rows of the left
///    half and points the CRTC at it, then turns on double-scanning (CRTC 0x09
///    = 0x41) and DOUBLES the row pitch (CRTC 0x13 = 0xA0), so the display now
///    shows only every other stored row. The picture halves again for free.
///  - The squeeze loop then redraws the picture into `a` rows centred on the
///    middle — a = 32, 26, 21, ... 3 (`a = a*5/6`) — one row-set per retrace,
///    while the palette walks through 64 precomputed fades toward white. The
///    copies are VGA latch copies (write mode 1), 160 bytes = 640 pixels at a
///    time, which is why the picture's own right half gets chewed up as it
///    collapses: that is in the original too.
///  - What is left is one white line. It is eaten inward from both ends four
///    pixels at a time, and a single dot (colour index 1) is left pulsing on a
///    cosine for 60 retraces before the screen goes dark.
///
/// Memory model: one flat 640x400 byte array. A VGA byte offset `o` addresses
/// the four pixels `4o..4o+3` (one per plane), so a latch copy of N bytes is
/// exactly a copy of 4N consecutive pixels — the plane interleave cancels out
/// and `copyline` becomes a straight memmove in pixel space.
class PanicPart extends Part {
  /// The squeeze: `for (a = 32; a > 2; a = a * 5 / 6)`, integer division.
  static List<int> _squeezeSteps() {
    final out = <int>[];
    for (var a = 32; a > 2; a = a * 5 ~/ 6) {
      out.add(a);
    }
    return out;
  }

  static final List<int> _steps = _squeezeSteps();

  /// The horizontal eat: `for (x = 20; x <= 160; x += 3)`.
  static const int _eatCount = 47; // x = 20, 23, ... 158

  static const int _pulseFrames = 60; // the cosine on the last dot
  static const int _holdFrames = 70; // SHUTDOWN.C's closing sleep(1)

  // Frame numbers at which each stage begins (one frame = one VGA retrace).
  static final int _fSqueeze = 3;
  static final int _fBlank = _fSqueeze + _steps.length;
  static final int _fEat = _fBlank + 1;
  static final int _fDot = _fEat + _eatCount;
  static final int _fEnd = _fDot + _pulseFrames + _holdFrames;

  /// How long the part runs, in seconds. After this it is just black.
  static double get duration => _fEnd / kDemoFps;

  final IndexedSurface _s = IndexedSurface(320, 400);

  @override
  IndexedSurface? get indexed => _s;

  /// The 640x400 tweaked screen, one byte per pixel.
  final Uint8List _mem = Uint8List(640 * 400);

  // CRTC state.
  int _start = 0; // 0x0C/0x0D, in bytes
  int _stride = 160; // 0x13 (offset), in bytes per displayed line
  bool _doubleScan = false; // 0x09 bit for "each row twice"

  /// The palette the previous part left behind — `getpal()`.
  late Uint8List _kuvapal;

  /// `fadepals[a][b] = (a*63 + kuvapal[b]*(64-a))/64` for b >= 3; colour 0 is
  /// left at zero (the array is a C global), which is what makes the copied
  /// lines read as black.
  late List<Uint8List> _fadepals;

  int _frame = 0;

  @override
  void init() {
    _kuvapal = Uint8List.fromList(AssetStore.images['troll']!.palette.bytes);

    _fadepals = List.generate(64, (a) {
      final p = Uint8List(768);
      for (var b = 3; b < 768; b++) {
        p[b] = (a * 63 + _kuvapal[b] * (64 - a)) ~/ 64;
      }
      return p;
    });

    _reset();
  }

  void _reset() {
    _frame = 0;
    _mem.fillRange(0, _mem.length, 0);

    // What the loader left us: the picture in the right half at double height,
    // displayed from byte 80 (= x 320).
    final troll = AssetStore.images['troll']!.pixels;
    for (var y = 0; y < 200; y++) {
      for (var x = 0; x < 320; x++) {
        final c = troll[y * 320 + x];
        _mem[(y * 2) * 640 + 320 + x] = c;
        _mem[(y * 2 + 1) * 640 + 320 + x] = c;
      }
    }
    _start = 80;
    _stride = 160;
    _doubleScan = false;
    _setPalette(_kuvapal);

    // shutdown(), everything before the first dis_waitb():
    //   the top-left line is cleared (it is the source of every "black" latch
    //   copy below), the picture is resampled into 100 rows at y = 150..249 of
    //   the left half, and the CRTC is pointed at row 100.
    for (var a = 0; a < 320; a++) {
      _put(a, 0, 0);
    }
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 320; x++) {
        _put(x, y + 150, _get(x + 320, y * 4));
      }
    }
    _start = 100 * 160;
  }

  // ---- the emulated VGA ---------------------------------------------------

  void _put(int x, int y, int c) {
    if (x < 0 || y < 0 || x >= 640 || y >= 400) return;
    _mem[y * 640 + x] = c;
  }

  int _get(int x, int y) => _mem[y * 640 + x];

  /// ASMYT.ASM `copyline`: `rep movsw` of [words] words = `words * 2` bytes,
  /// with the VGA in write mode 1 (latch transfer, map mask 1111). One byte
  /// carries four pixels, so this moves `words * 8` pixels.
  void _copyline(int fromByte, int toByte, int words) {
    final src = fromByte * 4, dst = toByte * 4, len = words * 8;
    if (src < 0 || dst < 0 || src + len > _mem.length || dst + len > _mem.length) {
      return;
    }
    _mem.setRange(dst, dst + len, _mem, src);
  }

  void _setPalette(Uint8List pal) {
    final p = VgaPalette.black();
    p.bytes.setRange(0, 768, pal);
    _s.palette = p;
  }

  void _setRgb(int index, int r, int g, int b) {
    // The surface's palette is replaced wholesale by _setPalette, so mutate a
    // copy to keep the two in step.
    final p = VgaPalette.black();
    p.bytes.setRange(0, 768, _s.palette.bytes);
    p.bytes[index * 3 + 0] = r;
    p.bytes[index * 3 + 1] = g;
    p.bytes[index * 3 + 2] = b;
    _s.palette = p;
  }

  /// Scan out the CRTC's view of memory into the 320x400 surface.
  void _present() {
    final px = _s.pixels;
    final first = _start * 4;
    final pitch = _stride * 4; // pixels advanced per displayed line
    for (var line = 0; line < 400; line++) {
      final row = _doubleScan ? line >> 1 : line;
      var i = first + row * pitch;
      final dst = line * 320;
      for (var x = 0; x < 320; x++) {
        px[dst + x] = _mem[(i + x) % (640 * 400)];
      }
    }
  }

  // ---- shutdown() ---------------------------------------------------------

  /// One retrace's worth of work — the code between two `dis_waitb()` calls.
  void _step() {
    final f = _frame;

    if (f == 1) {
      // CRTC 0x09 = 0x41: every stored row is scanned twice. The GC goes to
      // write mode 1 (latch transfer) and the map mask to 1111, so from here on
      // a byte move copies all four planes at once.
      _doubleScan = true;
      _setPalette(_fadepals[3]);
      _setRgb(0, 63, 63, 63); // one frame of white surround — the flash
      _start = 0;
    } else if (f == 2) {
      // fadepals[20] puts colour 0 back to black, and CRTC 0x13 = 0xA0 doubles
      // the row pitch: the display now samples every OTHER stored row, halving
      // the picture again.
      _setPalette(_fadepals[20]);
      _stride = 320;
    } else if (f >= _fSqueeze && f < _fBlank) {
      final a = _steps[f - _fSqueeze];
      _setPalette(_fadepals[63 - a]);
      // Blank the rows outside the shrinking band by latch-copying the cleared
      // top line over them.
      for (var b = a ~/ 2; b <= a; b++) {
        _copyline(0, 200 * 160 - (b * 320), 80);
        _copyline(0, 200 * 160 + (b * 320), 80);
      }
      // Resample the picture (still in the right half) into `a` rows centred on
      // the middle of the screen.
      for (var b = 0; b < a; b++) {
        _copyline(80 + (400 * b ~/ a) * 160, 200 * 160 + (b - a ~/ 2) * 320, 80);
      }
    } else if (f == _fBlank) {
      // Everything but the middle line goes.
      _copyline(0, 202 * 160, 80);
      _copyline(0, 198 * 160, 80);
    } else if (f >= _fEat && f < _fDot) {
      // Eat the line inward from both ends, four pixels at a time. (Back in
      // write mode 0 — these are ordinary putpixels.)
      final x = 20 + (f - _fEat) * 3;
      for (var i = 0; i < 4; i++) {
        _put(x + i, 200, 0);
        _put(320 - x - i, 200, 0);
      }
    } else if (f == _fDot) {
      _put(160, 200, 1);
    }

    if (f >= _fDot && f < _fDot + _pulseFrames) {
      final a = f - _fDot;
      final b = (math.cos(a / 120.0 * 3 * 2 * math.pi) * 31.0 + 32).toInt();
      _setRgb(1, b, b, b);
    }

    _frame++;
  }

  @override
  void update(double t, List<int> syncCodes) {
    final target = (t * kDemoFps).floor();
    if (target < _frame) _reset();
    var budget = 4000;
    while (_frame <= target && _frame < _fEnd && budget-- > 0) {
      _step();
    }
    _present();
  }
}
