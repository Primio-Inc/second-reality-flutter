import 'dart:math' as math;

import 'package:flutter/material.dart';


/// The landing screen.
///
/// Everything on it is borrowed from the demo itself rather than invented: the
/// background is a copper-bar gradient and a parallax starfield (the two oldest
/// tricks in the scene, and the horizon part's own sky), and the object turning
/// behind the type is THE GLENZ — the real mesh out of GLENZ/MAIN.C, projected
/// with the original's own camera (`sx = 256*x/z + 160`). No decoration here is
/// generic: it is all the demo, idling until you start it.
class StartScreen extends StatefulWidget {
  const StartScreen({
    super.key,
    required this.onStart,
    this.loading,
    this.error,
  });

  final VoidCallback onStart;

  /// Non-null while the assets and the soundtrack are loading.
  final String? loading;
  final String? error;

  @override
  State<StartScreen> createState() => _StartScreenState();
}

// The palette is the demo's: the void it opens in, the purple of the techno
// sky, the chrome of the title logo, and the amber of the monster's eyes.
const _void = Color(0xFF04050C);
const _deep = Color(0xFF150A2E);
const _steel = Color(0xFF9FB4E0);
const _chrome = Color(0xFFF2F6FF);
const _amber = Color(0xFFFFAE1A);

class _StartScreenState extends State<StartScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 120),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width;
    final narrow = w < 720;
    // SHORT, not narrow — the two are different, and conflating them is what
    // buried the button. A phone in LANDSCAPE is WIDE (so it takes the desktop
    // path: 64px logo, 40px gaps, both paragraphs) but only ~390px TALL, so the
    // one thing the page exists for ended up below the fold with no hint it was
    // there. Height is the constraint here, never width.
    final short = size.height < 560;
    // A demo is motion; but if the viewer has asked for less of it, the scene
    // holds still rather than disappearing.
    final still = MediaQuery.of(context).disableAnimations;

    return Container(
      color: _void,
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _ScenePainter(still ? 0.08 : _c.value),
              ),
            ),
          ),
          // The monster owns the right-hand column on a wide screen. Its left
          // edge is faded to nothing rather than cut: the picture's own left
          // pixels are #010109..#0c0818, i.e. the page's [_void] (#04050C), so
          // once the alpha reaches zero there is no seam to see. On a narrow
          // screen there is no room for a split, so it becomes a dim backdrop
          // BEHIND the copy and the scrim below keeps the type readable.
          _Monster(narrow: narrow),
          // Keeps the type readable over the brightest copper bars.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xF204050C), Color(0xCC04050C), Color(0x1A04050C)],
                stops: [0.0, 0.5, 0.92],
              ),
            ),
          ),
          // The copy owns the LEFT column and the glenz the right — a split,
          // not a centred card over a backdrop.
          SafeArea(
            child: Align(
              alignment: narrow ? Alignment.center : Alignment.centerLeft,
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                    horizontal: narrow ? 24 : 72, vertical: short ? 18 : 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // SelectionArea so the copy is copy-pastable on web
                      // (Flutter web paints text; nothing selects without it).
                      // The button stays OUTSIDE it: selection gestures fight
                      // tap/hover gestures inside the area.
                      SelectionArea(
                          child: _copy(narrow, short: short, still: still)),
                      SizedBox(height: short ? 20 : 40),
                      _StartButton(
                        onStart: widget.onStart,
                        loading: widget.loading,
                        error: widget.error,
                      ),
                      // On a short screen the backstory moves BELOW the button
                      // rather than being hidden behind a disclosure: once the
                      // logo is one line and the lede is one sentence, the whole
                      // page fits a landscape phone anyway, so a "more" link
                      // would buy nothing and cost a tap.
                      if (short) ...[
                        const SizedBox(height: 20),
                        SelectionArea(child: _blurb(withLede: true)),
                        const SizedBox(height: 18),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _copy(bool narrow, {required bool short, required bool still}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Eyebrow(),
          SizedBox(height: short ? 10 : 18),
          AnimatedBuilder(
            animation: _c,
            // 120s controller -> a chrome sweep every 6s.
            builder: (context, _) => _Title(
                narrow: narrow,
                short: short,
                phase: still ? 0.3 : (_c.value * 20) % 1.0),
          ),
          SizedBox(height: short ? 14 : 28),
          // On a short screen the lede is ONE sentence — enough to say what this
          // is, short enough that the button still clears the fold.
          Text(
            short
                ? 'At Assembly 1993, Future Crew showed what a home PC could '
                    'really do.'
                : 'At Assembly 1993, Future Crew showed what a home PC could '
                    'really do. Second Reality is widely considered the greatest '
                    'and most influential demo in the history of the demoscene.',
            style: TextStyle(
                color: _chrome,
                fontSize: short ? 15 : 17,
                height: 1.5,
                letterSpacing: .1),
          ),
          if (!short) ...[
            const SizedBox(height: 22),
            _blurb(),
          ],
        ],
      );

  /// The who-and-why paragraph. Full-height screens show it inline; short ones
  /// keep it behind [_MoreLink], below the button.
  ///
  /// [withLede] carries the sentence the SHORT lede had to drop, so the copy is
  /// complete in both layouts and duplicated in neither.
  Widget _blurb({bool withLede = false}) => Text.rich(
        TextSpan(
          style: const TextStyle(
              color: _steel, fontSize: 15, height: 1.6, letterSpacing: .1),
          children: [
            if (withLede)
              const TextSpan(
                  text: 'Second Reality is widely considered the greatest and '
                      'most influential demo in the history of the demoscene. '),
            const TextSpan(text: 'Thirty-three years on, the people behind '),
            const TextSpan(text: 'primio.dev', style: TextStyle(color: _amber)),
            const TextSpan(
              text: ', the Flutter-based AI app builder, bring it to '
                  'Flutter. A port, and an upgrade: the original code and '
                  'data, with upgraded visuals (AI-regenerated artwork, '
                  'native-resolution rendering) and upgraded sound, on '
                  'every platform Flutter supports.',
            ),
          ],
        ),
      );
}

/// The monster picture (reference art, quantised nowhere — this is the landing
/// page, not the demo). Faded on every edge that meets the page so it reads as
/// part of the backdrop rather than a pasted-in rectangle.
class _Monster extends StatelessWidget {
  /// assets/images/monster.jpg is 1142x1377.
  static const double _monsterAspect = 1142 / 1377;

  final bool narrow;
  const _Monster({required this.narrow});

  @override
  Widget build(BuildContext context) {
    final image = Image.asset(
      'assets/images/monster.jpg',
      fit: BoxFit.cover,
      alignment: Alignment.bottomCenter,
      filterQuality: FilterQuality.medium,
    );

    if (narrow) {
      // No room to sit beside the copy: sink him into the background instead.
      return Opacity(
        opacity: 0.28,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white],
            stops: [0.0, 0.35, 1.0],
          ).createShader(r),
          child: image,
        ),
      );
    }

    // The box takes the PICTURE's aspect (and BoxFit.cover fills it), so the
    // mask's edges are the picture's edges. Sizing the box any other way was
    // the bug: a wider box letterboxes the picture inside it, and the fade then
    // lands somewhere out in the padding while the picture's own edge — its sky
    // is a lighter purple than the page — draws a hard line down the screen.
    return Align(
      alignment: Alignment.centerRight,
      child: AspectRatio(
        aspectRatio: _monsterAspect,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          // Fade BOTH vertical edges. The left one is what lets the copy sit
          // over him; the right one matters just as much, because the picture's
          // own sky is a lighter purple than the page and its edge would
          // otherwise read as a seam down the screen.
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              Colors.transparent,
              Colors.white,
              Colors.white,
              Colors.transparent
            ],
            stops: [0.0, 0.42, 0.86, 1.0],
          ).createShader(r),
          child: image,
        ),
      ),
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow();

  @override
  Widget build(BuildContext context) => const Text(
        'FUTURE CREW  1993     ⟶     FLUTTER  2026',
        style: TextStyle(
          color: _amber,
          fontFamily: 'monospace',
          fontSize: 14,
          letterSpacing: 2.2,
        ),
      );
}

/// The logo is chrome, as it is in the demo's own title picture: a hard
/// steel-to-white sweep across the letterforms, not a flat fill — and the
/// sweep MOVES. The gradient itself is constant; the shader rect it is created
/// from slides with [phase], so the highlight travels across the letters the
/// way a raster bar travels through a scene logo.
class _Title extends StatelessWidget {
  const _Title(
      {required this.narrow, required this.short, required this.phase});
  final bool narrow;

  /// A landscape phone: the logo has to give up height to the button.
  final bool short;

  /// 0..1, one full sweep of the chrome highlight.
  final double phase;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (r) => const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [_steel, _chrome, Color(0xFF6E86BE), _chrome, _steel],
        stops: [0.0, 0.32, 0.5, 0.68, 1.0],
        tileMode: TileMode.mirror,
      ).createShader(r.shift(Offset(-r.width * 2 * phase, 0))),
      // On a short screen the logo goes on ONE line: two stacked lines cost a
      // whole line-height that the button needs, and the width is there anyway
      // (a landscape phone is wide). FittedBox rather than a fixed size, so it
      // shrinks to the column instead of overflowing on the narrowest handset.
      child: short
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text('SECOND REALITY', style: _logo(40)),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('SECOND', style: _logo(narrow ? 44 : 64)),
                Text('REALITY', style: _logo(narrow ? 44 : 64)),
              ],
            ),
    );
  }

  TextStyle _logo(double size) => TextStyle(
        color: Colors.white,
        fontSize: size,
        height: 0.98,
        fontWeight: FontWeight.w900,
        letterSpacing: size * 0.02,
      );
}

/// The button doubles as the loader. The original demo loaded each part off a
/// floppy between scenes and said so; here the same wait is the same message.
class _StartButton extends StatefulWidget {
  const _StartButton({required this.onStart, this.loading, this.error});
  final VoidCallback onStart;
  final String? loading;
  final String? error;

  @override
  State<_StartButton> createState() => _StartButtonState();
}

class _StartButtonState extends State<_StartButton>
    with SingleTickerProviderStateMixin {
  bool _hover = false;

  /// Runs only while hovered: drives the sheen sweeping through the fill and
  /// the pulse of the glow. Idle, the button costs nothing per frame.
  late final AnimationController _sheen = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  void _setHover(bool h) {
    setState(() => _hover = h);
    if (h) {
      _sheen.repeat();
    } else {
      _sheen.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.loading != null;
    final label = widget.loading ?? (widget.error != null ? 'RETRY' : 'START THE DEMO');
    final hot = _hover && !busy;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A GestureDetector CANNOT BE REACHED BY A D-PAD: it takes taps and
        // nothing else, so on Android TV the one button this page exists for was
        // unreachable. FocusableActionDetector makes it a real focus target,
        // autofocused so the remote lands on it, and Flutter's own shortcuts
        // already map the D-pad's centre (LogicalKeyboardKey.select), the
        // gamepad A button, enter and space to ActivateIntent. The focus ring
        // reuses the HOVER look, so a remote sees exactly what a mouse sees.
        FocusableActionDetector(
          autofocus: true,
          onShowFocusHighlight: (v) => _setHover(v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                if (!busy) widget.onStart();
                return null;
              },
            ),
          },
          child: MouseRegion(
            onEnter: (_) => _setHover(true),
            onExit: (_) => _setHover(false),
            cursor: busy ? SystemMouseCursors.wait : SystemMouseCursors.click,
            child: Semantics(
              button: true,
              label: 'Start the demo',
              child: GestureDetector(
                onTap: busy ? null : widget.onStart,
              child: AnimatedBuilder(
                animation: _sheen,
                builder: (context, child) {
                  final v = _sheen.value;
                  final pulse = hot ? 0.5 + 0.5 * math.sin(v * math.pi * 2) : 0.0;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 34, vertical: 20),
                    decoration: BoxDecoration(
                      // Hot: an amber fill with a hard chrome sheen racing
                      // through it — the same moving-highlight trick as the
                      // logo, just faster.
                      gradient: hot
                          ? LinearGradient(
                              begin: Alignment(-1 + 4 * v - 2, -0.3),
                              end: Alignment(1 + 4 * v - 2, 0.3),
                              colors: const [
                                _amber,
                                Color(0xFFFFE9B8),
                                _amber,
                              ],
                              stops: const [0.35, 0.5, 0.65],
                            )
                          : null,
                      border: Border.all(
                          color: hot ? const Color(0xFFFFD37A) : _amber,
                          width: 2),
                      boxShadow: hot
                          ? [
                              BoxShadow(
                                  color: const Color(0xFFFFAE1A)
                                      .withValues(alpha: 0.35 + 0.25 * pulse),
                                  blurRadius: 30 + 18 * pulse,
                                  spreadRadius: 1 + 2 * pulse),
                            ]
                          : const [],
                    ),
                    child: child,
                  );
                },
                child: Text(
                  label,
                  style: TextStyle(
                    color: hot ? _void : _amber,
                    fontFamily: 'monospace',
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2.4,
                  ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.error != null) ...[
          const SizedBox(height: 14),
          Text(
            widget.error!,
            style: const TextStyle(
              color: Color(0xFFFF6B6B),
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: .6,
            ),
          ),
        ],
      ],
    );
  }
}

/// Copper bars and a parallax starfield. The glenz used to turn here; the
/// monster picture now owns the right-hand column, so it is gone — it lives on
/// in the demo itself (p05_glenz). What is left is still the demo's own
/// vocabulary, as the
/// dark — the demo, idling.
class _ScenePainter extends CustomPainter {
  _ScenePainter(this.t);

  /// 0..1, one turn of the whole scene.
  final double t;

  static final List<_Star> _stars = _makeStars();

  static List<_Star> _makeStars() {
    final rnd = math.Random(1993);
    return List.generate(220, (_) {
      final depth = rnd.nextDouble(); // 0 = far, 1 = near
      return _Star(rnd.nextDouble(), rnd.nextDouble(), depth,
          rnd.nextDouble() * math.pi * 2);
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size,
        Paint()..shader = _sky(size));

    _copperBars(canvas, size);

    // The starfield drifts, as the horizon part's sky does — right to left,
    // the near stars faster than the far ones.
    for (final s in _stars) {
      final speed = 0.02 + s.depth * 0.12;
      final x = ((s.x - t * speed) % 1.0) * w;
      final y = s.y * h;
      final twinkle = 0.55 + 0.45 * math.sin(t * 40 + s.phase);
      final r = 0.5 + s.depth * 1.3;
      canvas.drawCircle(
        Offset(x, y),
        r,
        Paint()
          ..color = Color.lerp(_steel, _chrome, s.depth)!
              .withValues(alpha: (0.15 + s.depth * 0.55) * twinkle),
      );
    }

  }

  Shader _sky(Size size) => const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0xFF2A1147), _deep, _void],
        stops: [0.0, 0.45, 1.0],
      ).createShader(Offset.zero & size);

  /// Copper bars: horizontal bands whose position is a sine of time. The
  /// oldest gradient in the scene, and the reason palette tricks existed.
  void _copperBars(Canvas canvas, Size size) {
    const bars = 5;
    for (var i = 0; i < bars; i++) {
      final phase = t * math.pi * 2 + i * 1.1;
      final cy = size.height * (0.5 + 0.42 * math.sin(phase));
      final bh = size.height * 0.09;
      final hue = i / (bars - 1);
      final c = Color.lerp(_amber, const Color(0xFF7B5CFF), hue)!;
      canvas.drawRect(
        Rect.fromCenter(
            center: Offset(size.width * 0.5, cy),
            width: size.width,
            height: bh),
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              c.withValues(alpha: 0.0),
              c.withValues(alpha: 0.10),
              c.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCenter(
              center: Offset(size.width * 0.5, cy),
              width: size.width,
              height: bh)),
      );
    }
  }


  @override
  bool shouldRepaint(_ScenePainter old) => old.t != t;
}

class _Star {
  const _Star(this.x, this.y, this.depth, this.phase);
  final double x, y, depth, phase;
}
