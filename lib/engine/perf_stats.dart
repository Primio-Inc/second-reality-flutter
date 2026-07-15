/// Continuous A/V health, on every Flutter target — not a browser-only hack.
///
/// A demo is a real-time contract with the music: a part that renders the right
/// pixels at the wrong moment is broken, and it is broken SILENTLY. This is the
/// instrument that makes that visible. The number that matters is not the frame
/// rate — it is [clockError]: how far our demo clock has wandered from the
/// audio's own reported position. If that is not ~0, the effects are off the
/// beat no matter how pretty the frame rate looks.
class PerfStats {
  /// Rolling frame intervals (seconds), newest last.
  final List<double> _frames = [];
  static const _window = 120; // ~2s at 60Hz

  double _lastWall = -1;

  /// Frames the demo SKIPPED because it could not keep up. The demo is slaved to
  /// the music, so falling behind must cost frames, never time (see
  /// [DemoTimeline]): we jump straight to the music's `t` rather than replay the
  /// frames we owe. This counts how often that happens.
  int skippedFrames = 0;


  /// The player's reported position, for the HUD.
  double? audioPos;

  void tick(double wallSeconds) {
    if (_lastWall >= 0) {
      final dt = wallSeconds - _lastWall;
      if (dt > 0 && dt < 1.0) {
        _frames.add(dt);
        if (_frames.length > _window) _frames.removeAt(0);
      }
    }
    _lastWall = wallSeconds;
  }

  /// The most recent frame interval, seconds.
  double get lastFrameSeconds => _frames.isEmpty ? 0 : _frames.last;

  double get fps {
    if (_frames.isEmpty) return 0;
    final mean = _frames.reduce((a, b) => a + b) / _frames.length;
    return mean > 0 ? 1 / mean : 0;
  }

  /// The worst frame in the window, in milliseconds — a demo that averages 60fps
  /// but stalls for 200ms still stutters, and the mean hides it.
  double get worstFrameMs {
    if (_frames.isEmpty) return 0;
    return _frames.reduce((a, b) => a > b ? a : b) * 1000;
  }

  /// Frames slower than 20ms (i.e. under ~50fps) as a fraction of the window.
  double get jankFraction {
    if (_frames.isEmpty) return 0;
    final bad = _frames.where((d) => d > 0.020).length;
    return bad / _frames.length;
  }

  String get line =>
      '${fps.toStringAsFixed(0)}fps  worst ${worstFrameMs.toStringAsFixed(0)}ms  '
      'jank ${(jankFraction * 100).toStringAsFixed(0)}%  '
      'skipped $skippedFrames  '
      'pos ${audioPos?.toStringAsFixed(2) ?? "-"}';
}
