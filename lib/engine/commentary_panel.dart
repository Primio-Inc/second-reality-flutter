import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../commentary_script.dart';
import 'demo_clock.dart';
import 'demo_timeline.dart';

/// The live commentary: the demo as a documentary.
///
/// It SCROLLS rather than flipping pages. A card that replaces its predecessor
/// gives you exactly as long to read as the next cue allows, and the cues are
/// 15 seconds apart in places, so a page-flip would lose slow readers a whole
/// card at a time. Instead the panel is a running transcript: each card is
/// appended at the bottom and the column eases up, the last card stays on screen
/// until the next one pushes it, and you can scroll BACK through everything said
/// so far at any time.
///
/// Cards are keyed to the music clock (the same clock the demo runs on), so the
/// commentary cannot drift from the picture. Nothing is paused and nothing is
/// seeked: the panel is a pure function of `clock.seconds`, which means a scrub
/// or a scene jump re-derives the transcript instead of getting out of step.
class CommentaryPanel extends StatefulWidget {
  const CommentaryPanel({
    super.key,
    required this.clock,
    required this.timeline,
    required this.onClose,
    required this.smooth,
    required this.onSmoothChanged,
  });
  final DemoClock clock;
  final DemoTimeline timeline;
  final VoidCallback onClose;

  /// The smooth upscale (the same flag key S drives). It lives here because it
  /// is the only PICTURE choice a viewer has any business making — everything
  /// else about how the demo looks is the demo's own — and because it is free:
  /// a GPU sampler flag, not a resample, so flipping it costs no frame time.
  final bool smooth;
  final ValueChanged<bool> onSmoothChanged;

  /// The panel's width. It is ALWAYS a right-hand column and never wraps to a
  /// band under the demo: a bottom band put the text and the equaliser below the
  /// picture, squashed the reading area, and read as a different app. On a
  /// narrow screen the column simply narrows.
  ///
  /// main.dart insets the demo by exactly this, so the two cannot disagree.
  ///
  /// COMPACT (a phone in landscape) takes EXACTLY a third, leaving two thirds to
  /// the demo. The desktop formula's 240px floor is the wrong rule there: on a
  /// 640-wide phone it is 37% of the screen and still climbing as the screen
  /// shrinks, so the smaller the device the MORE of it the text ate. A third is
  /// a third at every size.
  ///
  /// The gate is HEIGHT, not width — the same trap the landing screen documents:
  /// a phone in landscape is WIDE, so a `width < 720` test would call it a
  /// desktop.
  static bool isCompact(BuildContext context) =>
      MediaQuery.sizeOf(context).height < 560;

  static double widthFor(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (isCompact(context)) return size.width / 3;
    return math.min(380.0, math.max(240.0, size.width * 0.34));
  }

  @override
  State<CommentaryPanel> createState() => _CommentaryPanelState();
}

class _CommentaryPanelState extends State<CommentaryPanel>
    with SingleTickerProviderStateMixin {
  // NOT `late final ... = createTicker(...)`. A late field initialises on first
  // ACCESS, and nothing accesses the ticker until dispose() — so it was never
  // created, never started, and the commentary froze on whatever card was due
  // when it opened.
  Ticker? _ticker;
  final ScrollController _scroll = ScrollController();

  /// How many cards are due at the current music position.
  int _shown = 0;

  /// True while the viewer has scrolled back to read: we then stop yanking the
  /// view to the bottom under their finger.
  bool _userScrolled = false;

  /// True while OUR OWN animateTo is running. Without this the panel disables
  /// itself: animateTo fires the scroll listener on every frame of its flight,
  /// and mid-flight the offset is not yet at the bottom, so the listener read it
  /// as "the viewer scrolled back" and suppressed every future auto-scroll. The
  /// transcript then stopped following the demo after exactly one card.
  bool _autoScrolling = false;

  /// How much of the top fade to apply, 0..1. It exists to stop text being
  /// guillotined by the top edge as it scrolls away, so it must be OFF while
  /// nothing has scrolled away yet: at rest it was fading out the first card's
  /// own heading, which made the opening card look like it was already history.
  double _topFade = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _poll())..start();
    _shown = _dueAt(widget.clock.seconds);
    // Opened mid-demo, the transcript already has everything said so far in it.
    // Start at the CURRENT card, not back at 1993.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      // Our own animation is not the viewer changing their mind.
      if (!_autoScrolling) {
        // Within a hair of the bottom counts as "following along" again.
        final atBottom = _scroll.offset >= _scroll.position.maxScrollExtent - 24;
        _userScrolled = !atBottom;
      }

      // Ramp the fade in over the first 32px of scroll, so it arrives with the
      // text it is there to soften rather than snapping on.
      final f = (_scroll.offset / 32).clamp(0.0, 1.0);
      if ((f - _topFade).abs() > 0.01) setState(() => _topFade = f);
    });
  }

  /// How long the transcript takes to ease up to a newly appended card. Named,
  /// because [kLeadIn] has to cover it — a card that is still sliding when the
  /// effect it describes hits is a card nobody read.
  static const Duration kScrollIn = Duration(milliseconds: 1100);

  /// How far AHEAD of its scripted time a card is appended.
  ///
  /// The card times in commentary_script.dart are authored as "the part's start
  /// + 1.2s" — i.e. they describe the effect you are about to see. But appending
  /// a card is not the same as SHOWING it: it slides in over [kScrollIn], and
  /// during a hard cut (the explosion, the glenz hitting the floor) the reader
  /// was watching the text still travel while the thing it explains was already
  /// on screen and gone. The text must be SETTLED before the effect lands, not
  /// arriving with it.
  ///
  ///   1.2s  undo the script's own "just after the part starts" offset
  /// + 1.1s  the slide-in ([kScrollIn]) must be FINISHED, not starting
  /// + 0.5s  and finished a beat early, so there is time to begin reading
  /// = 2.8s
  ///
  /// So a card is fully in place ~0.5s BEFORE its part's first frame. This is a
  /// presentation lead only: the card times themselves stay keyed to the music
  /// clock, so the commentary still cannot drift and a scene jump re-derives it.
  static const double kLeadIn = 2.8;

  static int _dueAt(double t) {
    var n = 0;
    for (final c in kCommentary) {
      if (c.time - kLeadIn <= t) n++;
    }
    return n;
  }

  void _poll() {
    final due = _dueAt(widget.clock.seconds);
    if (due == _shown) return;
    setState(() => _shown = due);
    // A new card arrived: ease the transcript up to it. Deliberately slow, so
    // it reads as a scroll and not as a jump cut.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_scroll.hasClients || _userScrolled) return;
      _autoScrolling = true;
      try {
        await _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: kScrollIn,
          curve: Curves.easeInOutCubic,
        );
      } finally {
        _autoScrolling = false;
      }
    });
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final compact = CommentaryPanel.isCompact(context);
    final panel = DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xE60A0B12),
        border: Border(left: BorderSide(color: Color(0x22FFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: ShaderMask(
              // The oldest text fades out at the top edge rather than being
              // guillotined by it. Scaled by [_topFade], so at rest (nothing
              // scrolled off) the mask is fully opaque and the first card is
              // shown at full strength.
              shaderCallback: (r) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 1 - _topFade),
                  Colors.white,
                  Colors.white,
                ],
                stops: const [0.0, 0.10, 1.0],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: LayoutBuilder(
                builder: (context, box) => ListView.builder(
                  controller: _scroll,
                  // The current card settles just ABOVE the footer, with a
                  // little air under it. That keeps the cards before it on
                  // screen, fading out at the top, so the commentary reads as a
                  // continuous transcript. Pushing the current card to the top
                  // of the panel instead (a deep bottom gutter) left the
                  // previous card off-screen entirely and lost that thread.
                  padding: compact
                      ? const EdgeInsets.fromLTRB(10, 4, 10, 12)
                      : const EdgeInsets.fromLTRB(18, 8, 18, 20),
                  itemCount: _shown,
                  itemBuilder: (context, i) => _CardView(
                    card: kCommentary[i],
                    // Only the newest card is at full strength; the transcript
                    // behind it recedes but stays readable.
                    current: i == _shown - 1,
                  ),
                ),
              ),
            ),
          ),
          // The footer does two jobs: it tells you WHERE you are (part number,
          // part name, running time), and it gives the transcript a floor to
          // sit on, which pushes the reading line further up the panel.
          _CommentaryFooter(
            clock: widget.clock,
            timeline: widget.timeline,
            smooth: widget.smooth,
            onSmoothChanged: widget.onSmoothChanged,
          ),
        ],
      ),
    );

    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(width: CommentaryPanel.widthFor(context), child: panel),
    );
  }

  /// The header is the title and the close button, and NOTHING is centred in a
  /// touch target.
  ///
  /// A Material `IconButton` is 48px tall whatever icon you put in it, and it
  /// was the tallest thing in this Row — so the title got centred in a 48px box
  /// and picked up ~17px of dead space ABOVE it, on top of the padding. That is
  /// why the gap over "LIVE COMMENTARY" read as bigger than the gap under the
  /// footer's own text even though both paddings were ~14px. A bare tappable
  /// icon ([_IconTap]) makes the row as tall as its text, and then the padding
  /// numbers mean what they say: the space above the title MATCHES the space
  /// below the footer's last line (12/14 desktop, 6/8 compact).
  ///
  /// COMPACT trims the chrome, never the text. On a phone in landscape the panel
  /// is ~270px wide and ~430px tall, and this header was eating a fifth of it.
  /// The transcript is the only thing on this panel anyone came to read.
  Widget _header() {
    final compact = CommentaryPanel.isCompact(context);
    return Padding(
        padding: compact
            ? const EdgeInsets.fromLTRB(10, 6, 10, 4)
            : const EdgeInsets.fromLTRB(18, 12, 18, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'LIVE COMMENTARY',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFFFFAE1A),
                  fontFamily: 'monospace',
                  fontSize: compact ? 10 : 12,
                  letterSpacing: compact ? 1.2 : 2.0,
                ),
              ),
            ),
            _IconTap(
              icon: Icons.close,
              tooltip: 'Close commentary',
              onTap: widget.onClose,
              size: compact ? 18 : 20,
            ),
          ],
        ),
      );
  }
}

/// Where you are: part number, part name, running time, and the soundtrack's
/// own spectrum.
///
/// It carries its OWN ticker and repaints alone. Driving the whole panel at 60
/// fps just to move an equaliser would rebuild the entire transcript every
/// frame, and the transcript is the expensive half.
class _CommentaryFooter extends StatefulWidget {
  const _CommentaryFooter({
    required this.clock,
    required this.timeline,
    required this.smooth,
    required this.onSmoothChanged,
  });

  final bool smooth;
  final ValueChanged<bool> onSmoothChanged;
  final DemoClock clock;
  final DemoTimeline timeline;

  @override
  State<_CommentaryFooter> createState() => _CommentaryFooterState();
}

class _CommentaryFooterState extends State<_CommentaryFooter>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;

  /// Bar heights, and the falling peak-hold caps above them. Bars rise
  /// instantly and fall slowly; caps hang and then sink. That behaviour, plus
  /// the LED segments, is what makes a meter read as an equaliser.
  final List<double> _bars = List.filled(_barCount, 0);
  final List<double> _caps = List.filled(_barCount, 0);
  static const int _barCount = 20;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(_sample))..start();
  }

  void _sample() {
    final s = widget.clock.spectrum;
    if (s == null || s.isEmpty) return;

    // LOG-SPACED BANDS, not linear ones. Sampling equal slices of the FFT gives
    // a meter that always slopes down and never moves, because nearly all the
    // energy in music sits in the bottom few bins and the rest is a long tail.
    // Hearing is logarithmic, so the bands must be too: each is a constant
    // RATIO wider than the last, which is what spreads the bass, mids and highs
    // across the meter the way Winamp's did.
    const loBin = 1.0;
    final hiBin = s.length * 0.75;
    for (var i = 0; i < _barCount; i++) {
      final f0 = loBin * math.pow(hiBin / loBin, i / _barCount).toDouble();
      final f1 =
          loBin * math.pow(hiBin / loBin, (i + 1) / _barCount).toDouble();
      final lo = f0.floor().clamp(0, s.length - 1);
      final hi = f1.ceil().clamp(lo + 1, s.length);

      var peak = 0.0;
      for (var k = lo; k < hi; k++) {
        if (s[k] > peak) peak = s[k];
      }
      // getByteFrequencyData is ALREADY dB-scaled (it maps the analyser's
      // -100..-30 dB window onto 0..255), so on loud music almost every bin
      // reads high and a raw plot pins every bar to the ceiling: a solid block,
      // not a meter. Subtract a noise floor and rescale, so the bars use their
      // whole travel and actually dance.
      const floor = 0.38;
      var v = ((peak - floor) / (1 - floor)).clamp(0.0, 1.0);
      // A gentle tilt only: the top bands carry less energy, but overdoing this
      // saturates them into the same flat block.
      v = (v * (1.0 + 0.5 * (i / (_barCount - 1)))).clamp(0.0, 1.0);

      _bars[i] = v > _bars[i] ? v : _bars[i] * 0.82 + v * 0.18;
      // The cap sits on the peak and sinks away from it.
      _caps[i] = _bars[i] > _caps[i] ? _bars[i] : (_caps[i] - 0.012).clamp(0.0, 1.0);
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  /// The controls block — the SMOOTH PIXELS switch and the equaliser — folds
  /// away behind the chevron. Kept in the FOOTER's state, not the panel's:
  /// folding it must not rebuild the transcript, which is the expensive half.
  bool _showControls = true;

  static String _mmss(double t) {
    final s = t.clamp(0, 99 * 60).round();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tl = widget.timeline;
    final i = tl.currentIndex;
    final e = (i >= 0 && i < tl.entries.length) ? tl.entries[i] : null;
    final hasAudioTap = widget.clock.spectrum != null;

    return Container(
      padding: CommentaryPanel.isCompact(context)
          ? const EdgeInsets.fromLTRB(10, 6, 10, 8)
          : const EdgeInsets.fromLTRB(18, 12, 18, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x1AFFFFFF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The chevron folds away EVERYTHING above the "where you are" line —
          // the switch AND the equaliser — because they are one block: the
          // controls. Folding only the LEDs left the switch behind and the
          // footer barely shrank. Down to hide, up to bring it back: the arrow
          // shows where the panel will GO, not what is currently on.
          //
          // It rides on the switch's own row rather than taking a row of its
          // own, so when the block is open the chevron costs nothing, and when
          // it is closed the footer is just the chevron and the part line.
          Row(
            children: [
              _IconTap(
                icon: _showControls
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_up,
                tooltip: _showControls ? 'Hide controls' : 'Show controls',
                onTap: () => setState(() => _showControls = !_showControls),
              ),
              const SizedBox(width: 6),
              if (_showControls)
                Expanded(
                  child: _SmoothSwitch(
                    value: widget.smooth,
                    onChanged: widget.onSmoothChanged,
                  ),
                ),
            ],
          ),
          if (_showControls) const SizedBox(height: 10),
          if (_showControls && hasAudioTap)
            SizedBox(
              // Tall enough for the LED segments to be countable.
              height: 44,
              child: CustomPaint(painter: _EqualiserPainter(_bars, _caps)),
            ),
          if (_showControls && hasAudioTap) const SizedBox(height: 12),
          if (!_showControls) const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(
                  e == null
                      ? '-'
                      : 'PART ${i + 1}/${tl.entries.length}  ${e.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF9AA0B0),
                    fontFamily: 'monospace',
                    fontSize: 11,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _mmss(widget.clock.seconds),
                style: const TextStyle(
                  color: Color(0xFFFFAE1A),
                  fontFamily: 'monospace',
                  fontSize: 11,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The one picture control a viewer gets: the smooth upscale (key S).
///
/// Deliberately SMALL and quiet — it sits under the transcript, not over the
/// demo, and it must not compete with the equaliser for the eye. Material's
/// stock Switch is built for a 48px touch target and is twice the height of the
/// footer's type, so it is shrink-wrapped and scaled down to the panel's scale.
class _SmoothSwitch extends StatelessWidget {
  const _SmoothSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            // NOT "SMOOTH" (smooth what?) and NOT "ANTI-ALIASING", which would
            // be a lie: nothing is anti-aliased here. The flag is a bilinear
            // sampler on the upscale of a 320x200 field — it softens the PIXELS.
            // Say what the viewer sees change.
            'SMOOTH PIXELS',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              // Lit when on, receding when off — so the state reads from the
              // label as well as from the switch.
              color: value ? const Color(0xFFFFAE1A) : const Color(0xFF6A7080),
              fontFamily: 'monospace',
              fontSize: 11,
              letterSpacing: 1.1,
            ),
          ),
        ),
        SizedBox(
          height: 20,
          child: FittedBox(
            fit: BoxFit.contain,
            child: Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeThumbColor: const Color(0xFF0A0B12),
              activeTrackColor: const Color(0xFFFFAE1A),
              inactiveThumbColor: const Color(0xFF6A7080),
              inactiveTrackColor: const Color(0x22FFFFFF),
              trackOutlineColor:
                  const WidgetStatePropertyAll(Color(0x33FFFFFF)),
            ),
          ),
        ),
      ],
    );
  }
}

/// A bare tappable icon at the footer's own scale. Material's IconButton brings
/// a 48px touch target with it, which is taller than the row it would sit in.
class _IconTap extends StatelessWidget {
  const _IconTap({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 18,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 16,
        child: Icon(icon, size: size, color: const Color(0xFF9AA0B0)),
      ),
    );
  }
}

/// The equaliser, drawn the way Winamp drew it: a column of discrete LED
/// SEGMENTS per band, climbing a green-to-amber-to-red ramp, under a white
/// peak-hold cap that hangs at the loudest recent value and sinks.
///
/// Driven by the REAL output spectrum (see DemoClock.spectrum), not a canned
/// animation. A solid bar whose colour merely brightens reads as a bar chart;
/// the segments and the falling caps are what make it read as a meter.
class _EqualiserPainter extends CustomPainter {
  _EqualiserPainter(this.bars, this.caps);
  final List<double> bars;
  final List<double> caps;

  /// LED geometry.
  static const double _segH = 3.0; // lit segment height
  static const double _segGap = 1.0; // dark line between segments

  @override
  void paint(Canvas canvas, Size size) {
    final n = bars.length;
    const gap = 2.0;
    final w = (size.width - gap * (n - 1)) / n;
    final segments = (size.height / (_segH + _segGap)).floor().clamp(1, 64);
    final paint = Paint();

    for (var i = 0; i < n; i++) {
      final x = i * (w + gap);
      final lit = (bars[i].clamp(0.0, 1.0) * segments).round();

      for (var s = 0; s < segments; s++) {
        final t = s / (segments - 1); // 0 at the floor, 1 at the ceiling
        final y = size.height - (s + 1) * (_segH + _segGap) + _segGap;
        if (s < lit) {
          // Cool at the bottom, hot at the top: the classic meter ramp.
          paint.color = t < 0.6
              ? Color.lerp(const Color(0xFF35D07F), const Color(0xFFFFAE1A),
                  t / 0.6)!
              : Color.lerp(const Color(0xFFFFAE1A), const Color(0xFFFF4A3D),
                  (t - 0.6) / 0.4)!;
        } else {
          paint.color = const Color(0x14FFFFFF); // the unlit LED, faintly there
        }
        canvas.drawRect(Rect.fromLTWH(x, y, w, _segH), paint);
      }

      // The peak-hold cap.
      final capSeg = (caps[i].clamp(0.0, 1.0) * segments).round();
      if (capSeg > 0) {
        final y = size.height - capSeg * (_segH + _segGap) + _segGap;
        paint.color = const Color(0xCCFFFFFF);
        canvas.drawRect(Rect.fromLTWH(x, y, w, 1.5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_EqualiserPainter old) => true;
}

class _CardView extends StatelessWidget {
  const _CardView({required this.card, required this.current});
  final CommentaryCard card;
  final bool current;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      // A past card is dimmed to say "not the current one", NOT to retire it:
      // the panel is a transcript and a viewer scrolls BACK through it, so it
      // has to stay comfortable to read. 0.45 was too far down for that; 0.72
      // still reads as behind the current card without turning it into grey.
      opacity: current ? 1.0 : 0.72,
      duration: const Duration(milliseconds: 600),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              card.title.toUpperCase(),
              style: const TextStyle(
                color: Color(0xFFFFAE1A),
                fontFamily: 'monospace',
                fontSize: 11,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Text.rich(
              _body(card.body),
              style: const TextStyle(
                color: Color(0xFFE7EAF2),
                fontSize: 14,
                height: 1.55,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A card's body is plain text with ONE piece of markup: `**bold**`. The
  /// script is prose, not a document, so it gets the smallest thing that lets a
  /// name stand out — and `**` is markdown, so `reference/commentary.md` (which
  /// tool/dump_commentary.py generates from the same string) renders it bold too,
  /// with no second syntax to keep in step.
  static TextSpan _body(String body) {
    final spans = <TextSpan>[];
    for (final (i, part) in body.split('**').indexed) {
      if (part.isEmpty) continue;
      spans.add(TextSpan(
        text: part,
        // Every odd piece sits between a pair of markers, so it is the bold one.
        style: i.isOdd
            ? const TextStyle(fontWeight: FontWeight.w700)
            : null,
      ));
    }
    return TextSpan(children: spans);
  }
}
