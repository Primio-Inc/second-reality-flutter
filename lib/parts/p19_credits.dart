import 'dart:typed_data';
import 'dart:ui';

import '../engine/asset_store.dart';
import '../engine/part.dart';
import '../engine/text_fx.dart';

/// Part 19 — the credits (`CRED.EXE` = CREDITS/MAIN.C): 21 screens, each a
/// picture of a part with its credit lines under it, sliding into place.
///
/// THE ANIMATION IS PURE CRTC. Nothing is redrawn per frame; `screenin()` draws
/// the picture and the text ONCE into two different places in video memory, and
/// then moves the display over them:
///
///   * TWEAK.ASM's mode is unchained with CRTC offset 0x50, so the DISPLAY steps
///     160 bytes per row while `tw_putpixel` addresses rows 80 bytes apart. The
///     display therefore shows only the EVEN putpixel rows — which is why the
///     picture is drawn at `(400+x, 400+2y)` and lands as an unsquashed 160x100
///     image in the top half of the screen, and why the text, drawn 32 rows
///     tall, appears 16 rows tall.
///   * The picture sits at putpixel x = 400..559, i.e. off the right edge of the
///     320-wide window. `tw_setstart(160*200 + yy/4)` plus the attribute
///     controller's pixel pan (`yy & 3`) pans the window right by `yy` pixels, so
///     as yy walks 0 -> 320 the picture slides IN FROM THE RIGHT to columns
///     80..239.
///   * The text is at address 0, and `tw_setsplit()` sets the CRTC LINE COMPARE:
///     below scanline `split` the display restarts at address 0. As split walks
///     400 -> 200 the text block RISES from the bottom edge to the middle of the
///     screen, revealed from its first line down.
///
///   Both are driven by one variable:  split = y/128 + 200,  yy = 320 - y/80.
///     in:   y = 200*128, then `y = y*12/13` per retrace  (102 retraces, easing
///           out — the picture is visually home after ~45 of them)
///     hold: 200 retraces
///     out:  y = 0, `y += v; v += 15` per retrace (59 retraces, accelerating) —
///           `yy = 320 + y/80` now, so the picture slides on out to the LEFT and
///           the text sinks back down.
///
///   361 retraces per screen = 5.157s, and the capture's 21 screens are 5.17s
///   apart. 21 * 5.157 = 108.3s.
///
/// THE PICTURES ARE OURS. The original's thumbnails (CREDITS/PICS/PIC*.LBM) are
/// 160x100 pixel art; stretched over half a 4:3 screen they are mush, and one of
/// them (PIC02, the ship) was never finished — it is a hand-scrawled "PARTPIC
/// MISSING (PXL SUX)" placeholder, so it is not even what the demo shipped. So
/// each screen shows OUR OWN render of the part it credits, shot straight out of
/// the running port by tool/capture_thumbs.dart. Same 21 screens, same order,
/// same credit lines, same slide — a modern picture in the same frame, which is
/// exactly what this port does with every other picture.
///
/// TEXT. The original prints its lines with the FONA bitmap font, centred at
/// x=160, first line at putpixel y=16 and every next one FONAY+10 = 42 rows
/// below — i.e. 21 DISPLAY rows apart, starting 8 display rows below the split.
/// An empty line still advances y (that is what the leading `"\0"` in half the
/// screens' text is for). We keep the positions and render the glyphs with the
/// modern vector font (see the porting notes).
class EndCreditsPart extends Part {
  /// One screen: 102 + 200 + 59 retraces (see the class doc).
  static const int _inRetraces = 102;
  static const int _holdRetraces = 200;
  static const int _outRetraces = 59;
  static const int screenRetraces =
      _inRetraces + _holdRetraces + _outRetraces; // 361

  static const double screenSeconds = screenRetraces / kDemoFps; // 5.157s

  /// The picture's place on the settled screen: 160x100 of the 320x200 field.
  static const int picW = 160, picH = 100;

  /// CREDITS/MAIN.C, screen for screen. A leading empty line is the original's
  /// `"\0GRAPHICS - PIXEL\0"` — it prints nothing but still steps y by 42.
  static const List<List<String>> texts = [
    ['GRAPHICS - MARVEL', 'MUSIC - SKAVEN', 'CODE - WILDFIRE'],
    ['GRAPHICS - MARVEL', 'MUSIC - SKAVEN', 'CODE - PSI'],
    [
      'GRAPHICS - MARVEL',
      'MUSIC - SKAVEN',
      'CODE - WILDFIRE',
      'ANIMATION - TRUG'
    ],
    ['', 'GRAPHICS - PIXEL'],
    ['GRAPHICS - PIXEL', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - TRUG'],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['', 'GRAPHICS - PIXEL', 'MUSIC - PURPLE MOTION'],
    [
      'GRAPHICS - PIXEL',
      'MUSIC - PURPLE MOTION',
      'CODE - TRUG',
      'RENDERING - TRUG'
    ],
    ['GRAPHICS - PIXEL, SKAVEN', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['GRAPHICS - PIXEL, SKAVEN', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - WILDFIRE'],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - WILDFIRE'],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    [
      'GRAPHICS - PIXEL',
      'MUSIC - PURPLE MOTION',
      'CODE - TRUG',
      'RENDERING - TRUG'
    ],
    ['', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['GRAPHICS - MARVEL', 'MUSIC - PURPLE MOTION', 'CODE - PSI'],
    ['', 'MUSIC - SKAVEN', 'CODE - PSI'],
    ['', 'GRAPHICS - PIXEL', 'MUSIC - PURPLE MOTION'],
    ['GRAPHICS - PIXEL', 'MUSIC - PURPLE MOTION', 'CODE - WILDFIRE'],
  ];

  static double get duration => texts.length * screenSeconds;

  int _screen = 0;
  int _splitRow = 200; // the display row the text region starts at
  int _panX = 0; // the picture's left edge, in display columns
  bool _live = false;

  /// `for(y=200*128; y>0; y=y*12L/13)` and `for(y=0,v=0; ...; y=y+v, v+=15)` —
  /// the two motion loops, replayed by retrace index.
  static final Int32List _inY = _buildIn();
  static final Int32List _outY = _buildOut();

  static Int32List _buildIn() {
    final out = <int>[];
    var y = 200 * 128;
    while (y > 0) {
      out.add(y);
      y = y * 12 ~/ 13;
    }
    return Int32List.fromList(out);
  }

  static Int32List _buildOut() {
    final out = <int>[];
    var y = 0, v = 0;
    for (var i = 0; i < _outRetraces; i++) {
      out.add(y);
      y += v;
      v += 15;
    }
    return Int32List.fromList(out);
  }

  @override
  void update(double t, List<int> syncCodes) {
    final r = (t * kDemoFps).floor();
    final screen = r ~/ screenRetraces;
    if (screen < 0 || screen >= texts.length) {
      _live = false;
      return;
    }
    _live = true;
    _screen = screen;
    final k = r % screenRetraces;

    // The two motion loops, and the still hold between them.
    int y;
    bool goingOut = false;
    if (k < _inRetraces) {
      y = k < _inY.length ? _inY[k] : 0;
    } else if (k < _inRetraces + _holdRetraces) {
      y = 0;
    } else {
      goingOut = true;
      final i = k - _inRetraces - _holdRetraces;
      y = i < _outY.length ? _outY[i] : _outY.last;
    }

    // split is in SCANLINES (two per display row); yy is the horizontal pan.
    final split = y ~/ 128 + 200;
    final yy = goingOut ? 320 + y ~/ 80 : 320 - y ~/ 80;
    _splitRow = (split ~/ 2).clamp(0, 200);
    // The picture is at putpixel x = 400..559 and the window pans right by yy,
    // so its left edge lands at display column 400 - yy (80 when yy = 320).
    _panX = 400 - yy;
  }

  @override
  void paintVector(Canvas canvas, Size size) {
    if (!_live) return;
    final sx = size.width / 320.0, sy = size.height / 200.0;

    // The picture lives ABOVE the line compare, and is cut off by it.
    final img = _screen < AssetStore.creditThumbs.length
        ? AssetStore.creditThumbs[_screen]
        : null;
    if (img != null && _splitRow > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, 0, size.width, _splitRow * sy));
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(_panX * sx, 0, picW * sx, picH * sy),
        Paint()..filterQuality = FilterQuality.medium,
      );
      canvas.restore();
    }

    // The text lives BELOW it, and rises with it — the reveal IS the clip.
    final lines = texts[_screen];
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(0, _splitRow * sy, size.width, size.height));
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].isEmpty) continue;
      // putpixel y = 16 + 42*i, displayed at half that below the split.
      final row = _splitRow + 8 + 21 * i;
      drawMovieText(canvas, size, lines[i],
          yTopFrac: row / 200.0, alpha: 1, heightFrac: 16 / 200);
    }
    canvas.restore();
  }
}
