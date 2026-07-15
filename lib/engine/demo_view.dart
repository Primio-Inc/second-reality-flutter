import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'av_probe.dart';
import 'build_info.dart';
import 'demo_clock.dart';
import 'perf_stats.dart';
import 'demo_timeline.dart';
import 'indexed_surface.dart';
import 'tablet_frame.dart';

/// Renders the running demo: blits the current part's indexed framebuffer
/// (scaled, FilterQuality.none) into a 4:3 letterboxed viewport, then lets
/// the part paint its native-resolution vector overlay.
class DemoView extends StatefulWidget {
  final DemoTimeline timeline;
  final DemoClock clock;
  final bool debugOverlay;

  /// When true, the demo is wrapped in the programmatic tablet frame; when
  /// false it is shown as a bare 4:3 letterbox. Toggled at runtime (key T).
  final bool framed;

  /// Smooth the upscale of the indexed framebuffer (key S). This is only a
  /// sampler flag on the one `drawImageRect` that blits the 320x200 (or
  /// 320x400) surface, so it is done by the GPU and costs nothing per frame —
  /// no extra CPU work, no change to any part's logic. Off by default because
  /// the ILBM pictures ARE pixel art; on, the palette effects (glenz, tunnel,
  /// interference, the forest's warped scroll) read much cleaner.
  final bool smooth;

  /// Fired once, when the demo is OVER — see [kDemoEnd].
  final VoidCallback? onFinished;

  /// When the demo actually ends: the music stops at 972.3s, and the end
  /// scroller's last line ("Thank you for experiencing / Second Reality")
  /// finishes clearing the screen at 982.6s. After that there is nothing left to
  /// draw and nothing left to hear, and without this the app scrolls an empty
  /// black field forever — holding the screen awake to do it.
  ///
  /// The 12s of silence at the end is deliberate and accepted: the scroller's
  /// start (653.25s) and speed (35 rows/s) are both MEASURED and are not ours to
  /// tune, so the only way to end on the music would be to cut the port's own
  /// title card out of the scroll.
  ///
  /// Every line added to the port's own header pushes this out by 25 rows =
  /// 0.714s; the "---" rule and its blank line cost 1.43s.
  static const double kDemoEnd = 984.03;

  const DemoView(
      {super.key,
      required this.timeline,
      required this.clock,
      this.debugOverlay = false,
      this.framed = true,
      this.smooth = false,
      this.onFinished});

  @override
  State<DemoView> createState() => DemoViewState();
}

class DemoViewState extends State<DemoView>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  ui.Image? _frame;
  bool _converting = false;

  /// A/V health. Kept always-on (cheap); shown with the debug overlay (D).
  final PerfStats perf = PerfStats();

  /// The one check that can actually fail: is the boom AUDIBLE when the clock
  /// says it should be? (Taps the real output — see AvProbe.)
  final AvProbe probe = AvProbe.technoHit();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  bool _finished = false;

  void _onTick(Duration elapsed) {
    final t = widget.clock.seconds;

    // The demo is over: the last line of the scroller has cleared and the music
    // stopped ten seconds ago. Fire once and stop drawing.
    if (!_finished && t >= DemoView.kDemoEnd) {
      _finished = true;
      _ticker.stop();
      widget.onFinished?.call();
      return;
    }

    // A/V health, every frame, on every target. Falling behind must cost FRAMES,
    // never TIME: the demo is slaved to the music, so we render whatever `t` the
    // music is at now and let the frames we owe simply not happen. (That is what
    // `tick(t)` already does — every part derives its state from `t`, so a slow
    // frame skips ahead rather than replaying. This counts it.)
    perf.tick(elapsed.inMicroseconds / 1e6);
    perf.audioPos = widget.clock.audioPosition;
    probe.tick(t, widget.clock.outputLevel);
    final expected = 1 / 60.0;
    final last = perf.lastFrameSeconds;
    if (last > expected * 1.5) {
      perf.skippedFrames += (last / expected).floor() - 1;
    }

    try {
      widget.timeline.tick(t);
    } catch (e, st) {
      // Spec: a crashing part must not kill the demo in release.
      assert(() {
        Error.throwWithStackTrace(e, st);
      }());
    }
    _blit(widget.timeline.current?.indexed);
    setState(() {});
  }

  void _blit(IndexedSurface? s) {
    if (s == null || _converting) return;
    _converting = true;
    ui.decodeImageFromPixels(
        s.toRgbaBytes(), s.width, s.height, ui.PixelFormat.rgba8888, (img) {
      _frame?.dispose();
      _frame = img;
      _converting = false;
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  /// The platform's RAW reported audio latency. The clock subtracts this to
  /// answer "what is audible now", so an over-reported value drags every visual
  /// late — it must be visible, not hidden.
  String _latencyLine() => widget.clock.latencyReport;

  /// The debug HUD. It answers the questions actually asked while working on a
  /// part: WHICH part am I looking at, how far into it am I, and what is next?
  /// A bare part INDEX answered none of them — you had to go count entries in
  /// demo_script.dart to find out what "part 0" was.
  ///
  /// The A/V probe's `lvl`/`hit:` line is gone: it is a one-shot calibration
  /// tool (it watches for a single known transient), so it says "watching..."
  /// for the entire run and costs a line of screen to do it.
  String _hud() {
    final t = widget.clock.seconds;
    final tl = widget.timeline;
    final i = tl.currentIndex;
    final e = (i >= 0 && i < tl.entries.length) ? tl.entries[i] : null;

    // Where we are INSIDE the part, and what follows it — the two numbers you
    // reach for when a part starts or ends at the wrong moment.
    final local = e == null ? 0.0 : t - e.start;
    final next = (i + 1 < tl.entries.length) ? tl.entries[i + 1] : null;
    final upNext = next == null
        ? 'end'
        : '${next.name} in ${(next.start - t).toStringAsFixed(1)}s';

    return 'build $kBuildId  '
        't=${t.toStringAsFixed(2)}  '
        'av=${(widget.clock.avOffset * 1000).toStringAsFixed(0)}ms  '
        'smooth[S]=${widget.smooth ? "on" : "off"}  '
        'frame[T]=${widget.framed ? "on" : "off"}\n'
        'part ${i + 1}/${tl.entries.length}  ${e?.name ?? "-"}  '
        '+${local.toStringAsFixed(2)}s (from ${e?.start.toStringAsFixed(2)})\n'
        'next: $upNext\n'
        '${perf.line}\n'
        'latency ${_latencyLine()}';
  }

  @override
  Widget build(BuildContext context) {
    final screen = CustomPaint(
      painter:
          _DemoPainter(_frame, widget.timeline, widget.smooth),
      child: widget.debugOverlay
          ? Align(
              alignment: Alignment.topLeft,
              child: Text(
                _hud(),
                style: const TextStyle(
                    color: Colors.green, fontFamily: 'monospace'),
              ),
            )
          : null,
    );
    // The whole demo runs at the original 4:3 display ratio; optionally inside a
    // programmatic tablet frame (global requirement — see the porting notes).
    if (widget.framed) {
      return TabletFrame(screen: SizedBox.expand(child: screen));
    }
    return Center(
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ClipRect(child: screen),
      ),
    );
  }
}

class _DemoPainter extends CustomPainter {
  final ui.Image? frame;
  final DemoTimeline timeline;

  /// See DemoView.smooth — a GPU sampler flag, not a resample.
  final bool smooth;
  _DemoPainter(this.frame, this.timeline, this.smooth);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final img = frame;
    if (img != null && timeline.current?.indexed != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint()
          ..filterQuality = smooth ? FilterQuality.medium : FilterQuality.none,
      );
    }
    timeline.current?.paintVector(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _DemoPainter old) => true;
}
