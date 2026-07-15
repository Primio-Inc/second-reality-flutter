import 'dart:developer' as developer;

/// Checks the demo clock against the sound that is ACTUALLY COMING OUT.
///
/// Every other check we built could not fail: they compared the clock against
/// another derivation of the same number. This one watches the output stream
/// (see `DemoClock.outputLevel`, tapped from an AnalyserNode on web) for the
/// loudest transient in a window, and reports the clock time at which that
/// transient was audible.
///
/// Point it at an event whose music position we know exactly — the explosion's
/// boom, at soundtrack 104.090s — and the answer is unambiguous:
///   heard at ~104.09  → the clock is honest; a perceived lag is output latency.
///   heard at ~99      → the audio is running AHEAD of the clock by 5s.
///   heard at ~109     → the audio is running BEHIND the clock by 5s.
/// It measures the whole chain (decode → schedule → device) in the real
/// browser, with no ears in the loop.
class AvProbe {
  /// Watch window in soundtrack seconds, and what we expect to hear in it.
  final double from, to, expected;
  final String label;

  AvProbe({
    required this.label,
    required this.from,
    required this.to,
    required this.expected,
  });

  /// The techno part's big hit — the loudest transient in OUR soundtrack by a
  /// factor of three (onset map: t=182.532, s=618; nothing else in the window
  /// exceeds 200), so "the strongest onset heard in [175,190]" can only be it.
  ///
  /// NOT the explosion boom: since the recut, MUSIC0 runs seamlessly INTO the
  /// boom with no silent gap, so the boom is no longer a distinctive energy
  /// RISE and a rise-detector locks onto a later transient instead. Pick a probe
  /// target that dominates its window, or the probe measures the wrong event.
  static AvProbe technoHit() =>
      AvProbe(label: 'hit', from: 175.0, to: 190.0, expected: 182.532);

  double _peak = 0;
  double _peakAt = 0;
  double _prev = 0;
  bool _reported = false;

  /// Result once the window has passed: the clock time of the loudest onset
  /// heard, or null while still watching.
  double? heardAt;

  /// heardAt - expected. Positive = the clock ran AHEAD of the audio (visuals
  /// early); negative = the clock ran BEHIND (visuals late). Null until done.
  double? get error => heardAt == null ? null : heardAt! - expected;

  void tick(double clockSeconds, double? level) {
    if (level == null || _reported) return;
    if (clockSeconds >= from && clockSeconds <= to) {
      // Onset strength, not loudness: the boom is a JUMP in energy, and the
      // music around it is already loud.
      final rise = level - _prev;
      if (rise > _peak) {
        _peak = rise;
        _peakAt = clockSeconds;
      }
      _prev = level;
    } else if (clockSeconds > to && _peak > 0) {
      heardAt = _peakAt;
      _reported = true;
      developer.log(
        '[AvProbe] $label heard at clock t=${_peakAt.toStringAsFixed(3)}s '
        '(expected ${expected.toStringAsFixed(3)}s, '
        'error ${(error! * 1000).toStringAsFixed(0)}ms)',
        name: 'AvProbe',
      );
    }
  }

  String get line => heardAt == null
      ? '$label: watching…'
      : '$label heard ${heardAt!.toStringAsFixed(2)} '
          'err ${(error! * 1000).toStringAsFixed(0)}ms';
}
