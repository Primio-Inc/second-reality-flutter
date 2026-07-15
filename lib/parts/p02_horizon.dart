import 'dart:ui';
import '../engine/asset_store.dart';
import '../engine/indexed_surface.dart';
import '../engine/part.dart';
import '../engine/sri_image.dart';
import '../engine/text_fx.dart';
import '../engine/vga_palette.dart';
import 'intro_ship.dart';

/// Part 2 — the intro horizon scene ("maisema", ALKU/MAIN.C): the starfield /
/// blue-mountain picture (ALKU/HOI.LBM) scrolls slowly while the production
/// credits fade in over the sky, then a ship flies to the horizon and a white
/// flash hands off to the title. Credit text/positions are the original's;
/// glyphs are a modern serif (drawn in the vector layer). The horizon credits
/// are offset by +100 rows in the 320x400 field (source: `+176*100`).
class HorizonPart extends Part {
  static const shipCode = 20;
  // Exact horizon scroll rate: ALKU/MAIN.C `do_scroll` advances `a` by one
  // pixel every `SCRLF`=9 vertical retraces (@kDemoFps 70Hz) → 70/9 ≈ 7.78 px/s.
  // Confirmed against the video (15.6 px/s in the 640-wide capture = 7.78 in
  // the 320 field), measured over a clean 5s/10s window.
  static const scrollSpeed = kDemoFps / 9.0; // ≈ 7.78 px/s left scroll
  static const _rowOffset = 100; // horizon text is at row 100+y (MAIN.C)

  // (localTime, lines[(text,y)]) — times relative to part start; y from source
  // (ALKU/MAIN.C addtext calls).
  //
  // Each card is fired by a `dis_sync()` code (4+tptr), i.e. music cues 5..8 =
  // 45.965 / 53.965 / 61.965 / 69.965s (DIS/DISINT.ASM `ordersync1`, resolved
  // through the tempo-120 row clock). It does NOT appear then: `fmaketext(aa+16)`
  // composites the text into the SCROLLING picture buffer 16px ahead of the
  // scroll position, so the card is revealed as the scroll reaches it — the
  // ~2.5s lag between the cue and the text showing up on screen.
  //
  // We draw the cards directly rather than through the scroll buffer, so these
  // are the ON-SCREEN times (capture 48.30/56.30/64.20/72.20 → soundtrack
  // 48.50/56.50/64.40/72.40) minus the 37.965s part start. TODO: port
  // fmaketext's scroll-reveal so the lag falls out of the scroll instead of
  // being baked in here.
  static const _cards = <_Card>[
    _Card(10.535, [CreditLine('Graphics', 50), CreditLine('Marvel', 90), CreditLine('Pixel', 130)]),
    _Card(18.535, [CreditLine('Music', 50), CreditLine('Purple Motion', 90), CreditLine('Skaven', 130)]),
    _Card(26.435,
        [CreditLine('Code', 30), CreditLine('Psi', 70), CreditLine('Trug', 110), CreditLine('Wildfire', 148)]),
    _Card(34.435,
        [CreditLine('Additional Design', 50), CreditLine('Abyss', 90), CreditLine('Gore', 130)]),
  ];

  // The horizon-loop card cycle (ALKU/MAIN.C): the palette fades in over 64
  // retraces (cop_dofade=64), the card is held while the scroll counter `f`
  // runs 20..49 — 30 iterations of do_scroll at SCRLF=9 retraces each — and
  // then fades out over 64. So fade-out starts 30*9 = 270 retraces after the
  // fade-in did, and the fully-lit hold is the 270-64 in between.
  static const _cardFadeIn = 64 / kDemoFps; // 0.914s
  static const _cardHold = (30 * 9 - 64) / kDemoFps; // 2.943s
  static const _cardFadeOut = 64 / kDemoFps; // 0.914s

  /// The picture fades up over 128 retraces (`cop_dofade=128`, picin[]).
  static const _picFade = 128 / kDemoFps; // 1.829s

  final IndexedSurface _s = IndexedSurface(320, 200);
  late final SriImage _pic;
  late final VgaPalette _base;
  bool shipActive = false;
  double _shipStartT = 0;
  double _shipT = 0; // U2A animation frame (0..520), one per VGA retrace
  IntroShipScene? _shipScene;

  // Exposed for the vector layer / tests.
  List<CreditLine> activeLines = const [];
  double textAlpha = 0;

  @override
  IndexedSurface get indexed => _s;

  @override
  void init() {
    _pic = AssetStore.images['hoi']!;
    // The intro "mothership" flyover — a replay of the original's COMPILED
    // scene (VISU/C/SCENE/U2A.*), objects and baked animation stream both. See
    // IntroShipScene: 'Sippi' is the big panelled disc that slides in from the
    // top and recedes to the horizon, trailed by three 's01' escorts.
    final u2a = AssetStore.scenes['u2a'];
    if (u2a != null) _shipScene = IntroShipScene(u2a);
    _base = VgaPalette.fromBytes(_pic.palette.bytes);

    // HOI.LBM is 640x200 but only its top 151 rows hold the sky+mountains; the
    // rest is black. The original centres that band vertically in the 200-row
    // screen, leaving black padding above and below (measured in the capture:
    // content occupies rows 25..175).
    var last = _pic.height - 1;
    for (; last > 0; last--) {
      var nz = 0;
      for (var x = 0; x < _pic.width; x++) {
        if (_pic.pixels[last * _pic.width + x] != 0) nz++;
      }
      if (nz > _pic.width ~/ 2) break;
    }
    _picRows = last + 1;
    _picTop = (200 - _picRows + 1) ~/ 2;
  }

  late final int _picRows; // rows of real content in the picture (151)
  late final int _picTop; // screen row the picture starts at (25)

  @override
  void update(double t, List<int> syncCodes) {
    for (final e in syncEvents) {
      if (e.code == shipCode && !shipActive) {
        shipActive = true;
        // Anchor to the EVENT's music time, not the delivery frame: a seek can
        // cross the cue seconds late, and the flyover must not shift with it.
        _shipStartT = t - (musicTime - e.time);
      }
    }
    // U2A.C advances the animation ONE FRAME PER VGA RETRACE: `copper2` (the
    // retrace interrupt) ticks `syncframe`, and the main loop advances
    // `currframe` by however many retraces have passed — so a slow machine
    // SKIPS frames and the shot always lasts 521/70 = 7.44s. Same here.
    if (shipActive) _shipT = (t - _shipStartT) * kDemoFps;

    // Scroll a 320-wide window across the 640-wide picture — and STOP at 320.
    //
    // ALKU/MAIN.C runs the horizon as `for(f=60; a<320 && !dis_exit();)`, with
    // `a` advancing one pixel every SCRLF=9 retraces. So the scroll travels
    // exactly 320px (320*9/70 = 41.14s), parks there, and the scene HOLDS that
    // frame until the explosion part takes over. It does not wrap, and it does
    // not keep going: the ships fly over a background that has already stopped.
    //
    // (We used to take the scroll modulo the picture width, so it scrolled on
    // forever, and froze it artificially when the ship triggered to hide that.)
    const scrollEnd = 320;
    final scroll = (t * scrollSpeed).floor().clamp(0, scrollEnd);
    _s.pixels.fillRange(0, _s.pixels.length, 0);
    for (var y = 0; y < _picRows; y++) {
      final srow = y * _pic.width;
      final drow = (y + _picTop) * 320;
      for (var x = 0; x < 320; x++) {
        _s.pixels[drow + x] = _pic.pixels[srow + (scroll + x) % _pic.width];
      }
    }

    // Active credit card + its fade level (text drawn in the vector layer).
    activeLines = const [];
    textAlpha = 0;
    for (final c in _cards) {
      final lt = t - c.start;
      if (lt < 0 || lt >= _cardFadeIn + _cardHold + _cardFadeOut) continue;
      if (lt < _cardFadeIn) {
        textAlpha = lt / _cardFadeIn;
      } else if (lt < _cardFadeIn + _cardHold) {
        textAlpha = 1;
      } else {
        textAlpha = 1 - (lt - _cardFadeIn - _cardHold) / _cardFadeOut;
      }
      activeLines = c.lines;
      break;
    }

    // Palette: the picture fades up over its 128 retraces. The scene hands off
    // to the explosion part (PRAX4.FLI), which provides the white-out.
    _s.palette = _base.scaled((t / _picFade).clamp(0.0, 1.0));
  }

  @override
  void paintVector(Canvas canvas, Size size) {
    // Credit text over the horizon: rows 100+y in the 320x400 field.
    for (final line in activeLines) {
      drawMovieText(canvas, size, line.text,
          yTopFrac: (_rowOffset + line.y) / kIntroFieldH, alpha: textAlpha);
    }

    // The mothership + escort flyover: the original's own animation stream,
    // replayed one frame per retrace but SAMPLED at a fractional frame, so the
    // motion is interpolated to the display's refresh rate instead of stepping
    // at 70 Hz. It runs out after 521 frames and the sky is empty again just
    // before the explosion takes over.
    final scene = _shipScene;
    if (shipActive && scene != null) {
      scene.paint(canvas, size, _shipT);
    }
  }
}

class _Card {
  final double start;
  final List<CreditLine> lines;
  const _Card(this.start, this.lines);
}


