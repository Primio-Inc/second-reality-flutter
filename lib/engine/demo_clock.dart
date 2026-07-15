import 'dart:async';
import 'package:just_audio/just_audio.dart';

/// Master clock. The demo is slaved to this — audio position, never wall
/// clock — so visuals cannot drift from music (spec: Architecture).
abstract class DemoClock {
  double get seconds;
  Future<void> start();
  Future<void> seek(double seconds);

  /// Fully prepare the audio (fetch + decode) — returns only when the clock
  /// can start making sound IMMEDIATELY. Nothing may start the demo before
  /// this completes (spec: load-and-init gate).
  Future<void> load() async {}

  /// Audio/video offset, seconds. What a player REPORTS as its position is not
  /// what you HEAR: the browser's output buffer delays the sound, and the
  /// compositor delays the frame. Neither is knowable up front, so this is dialled
  /// in by ear ([ and ] in the app) and then baked in as [defaultAvOffset].
  ///
  /// `t = audioPosition + avOffset`, so:
  ///   POSITIVE — the demo renders content from further AHEAD, i.e. every visual
  ///              event happens EARLIER relative to the sound. Use when the
  ///              picture lags the music.
  ///   NEGATIVE — visuals happen LATER relative to the sound.
  double avOffset = defaultAvOffset;

  /// Zero by default: the clock already subtracts the output latency the
  /// platform reports ([DemoClock.outputLatency]), so anything baked in here is
  /// a correction for a latency the platform did NOT report — i.e. a property of
  /// one machine, not of the demo. A non-zero default drags every visual on
  /// every OTHER machine, which is worse than the error it was fixing.
  ///
  /// It was 1.0s, dialled in on one dev box from a beep test (key `B`) that
  /// measured ~1s of real delay while Chrome reported 37ms. If a machine needs
  /// that again, dial it in at runtime with `,` / `.` (`0` resets) — do not bake
  /// it back in without checking the beep test on a second machine.
  static const double defaultAvOffset = 0.0;

  /// The position the audio player itself reports, or null if this clock has no
  /// audio behind it.
  double? get audioPosition => null;

  /// What the platform claims its audio output latency is, seconds — the amount
  /// the clock SUBTRACTS to answer "what is audible right now".
  ///
  /// If the platform over-reports this (some drivers, and Bluetooth output, do),
  /// the clock is pushed that far BEHIND the music and every visual lands late.
  /// So it is not an internal detail: it is a number that can silently break the
  /// whole demo, and it belongs on the HUD.
  double get outputLatency => 0;

  /// The RAW platform latency numbers, for the HUD — so a bogus one is visible
  /// rather than silently absorbed into the clock.
  String get latencyReport => '-';

  /// Loudness (RMS, 0..1) of the audio LEAVING THE OUTPUT right now, or null if
  /// this clock cannot tap its output.
  ///
  /// This is the only number here that is a measurement rather than a
  /// derivation, and it is what [AvProbe] uses to check the clock against the
  /// sound the user can actually hear.
  double? get outputLevel => null;

  /// The real frequency spectrum of the audio leaving the output, as bin
  /// magnitudes 0..1, or null if this clock cannot tap its output.
  ///
  /// A MEASUREMENT, like [outputLevel] — the commentary's equaliser is driven by
  /// the actual soundtrack, not by an animation pretending to be one. Clocks
  /// without an output tap (the element fallback, native playback) return null,
  /// and the equaliser then simply does not appear rather than lying.
  List<double>? get spectrum => null;

  /// Stop playback for good. Called when the demo ENDS; there is no resume.
  void stop() {}

  /// Freeze the demo where it is: the audio stops AND the clock stops, so no
  /// time passes while the app is in the background. Called when the app is
  /// backgrounded on mobile — without it the music plays on over whatever the
  /// user switched to, and the demo silently races ahead of the picture.
  void pause() {}

  /// Resume from exactly where [pause] left off.
  Future<void> resume() async {}
}

/// The demo clock: the audio's own position, extrapolated at 1x between the
/// player's (coarse) position updates. Nothing is smoothed, slewed or
/// free-running — see [seconds]. Startup and seeks go through
/// [waitUntilRolling], so the demo never draws a frame against a player that
/// isn't actually making sound.
class AudioDemoClock implements DemoClock {
  final AudioPlayer _player = AudioPlayer();
  final String assetPath;
  final Stopwatch _sw = Stopwatch()..start();

  @override
  double avOffset = DemoClock.defaultAvOffset;

  // Anchor: where the music is, and the wall time that was true at. The clock
  // runs from it at 1x (audio plays at exactly 1x, so wall time IS music time
  // once we know when playback began).
  double _anchorPos = 0;
  double _anchorWall = 0;
  bool _haveAnchor = false;


  AudioDemoClock(this.assetPath);

  /// Load AND wait until the player can actually play — `setAsset` returning
  /// only means the source is set, not that audio is ready to come out. Starting
  /// the demo against a still-buffering player bakes that delay into t=0 and
  /// every part inherits it for the rest of the run.
  @override
  Future<void> load() async {
    await _player.setAsset(assetPath);
    if (_player.processingState == ProcessingState.ready) return;
    await _player.processingStateStream
        .firstWhere((s) => s == ProcessingState.ready)
        .timeout(const Duration(seconds: 30));
  }

  @override
  double? get audioPosition => _player.position.inMicroseconds / 1e6;

  @override
  double? get outputLevel => null; // element-based playback: no output tap

  @override
  List<double>? get spectrum => null; // no output tap: no equaliser

  @override
  void stop() => _player.stop();

  @override
  void pause() {
    if (!_haveAnchor || !_player.playing) return;
    _anchorPos = seconds - avOffset; // freeze the clock, not just the audio
    _player.pause();
  }

  @override
  Future<void> resume() async {
    await _player.seek(Duration(microseconds: (_anchorPos * 1e6).round()));
    unawaited(_player.play()); // never await: it completes at END of playback
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _haveAnchor = true;
  }

  @override
  double get outputLatency => 0; // element playback: not reported

  @override
  String get latencyReport => '-';


  /// ANCHOR ONCE, THEN RUN FREE — do NOT keep re-anchoring to `position`.
  ///
  /// just_audio's reported position on web LAGS the audio you actually hear (we
  /// measured ~4-5s: the bang, which sits at 103.80s in the file, was audible
  /// while `position` still read ~100). The sound starts before the player begins
  /// counting. A clock that re-anchors to that value every update is *pinned* to
  /// the lag — which is exactly the constant "everything is ~5s late" desync.
  ///
  /// Audio plays at exactly 1x, so once we know WHEN playback began, wall time
  /// since that instant IS the music position. [waitUntilRolling] establishes
  /// that anchor at start and after every seek. `position` is kept only as a
  /// diagnostic ([positionDrift]) and as a coarse guard against a stall.
  @override
  double get seconds {
    final wall = _sw.elapsedMicroseconds / 1e6;

    if (!_haveAnchor || !_player.playing) return _anchorPos + avOffset;
    return _anchorPos + (wall - _anchorWall) + avOffset;
  }

  @override
  Future<void> start() async {
    // just_audio's play() Future completes only when playback *finishes*
    // (end of track), not when it starts — never await it.
    unawaited(_player.play());
    _anchorPos = 0;
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _haveAnchor = true;
  }


  @override
  Future<void> seek(double s) {
    _anchorPos = s;
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _haveAnchor = true;
    return _player.seek(Duration(microseconds: (s * 1e6).round()));
  }
}

class StopwatchDemoClock implements DemoClock {
  final Stopwatch _sw = Stopwatch();
  double _offset = 0;

  @override
  double avOffset = DemoClock.defaultAvOffset;

  @override
  Future<void> load() async {} // nothing to load

  @override
  double? get audioPosition => null; // no audio behind it

  @override
  double? get outputLevel => null;

  @override
  List<double>? get spectrum => null; // a stopwatch has no audio to analyse

  @override
  void stop() => _sw.stop();

  @override
  void pause() => _sw.stop();

  @override
  Future<void> resume() async => _sw.start();

  @override
  double get outputLatency => 0;

  @override
  String get latencyReport => '-';



  @override
  double get seconds => _offset + _sw.elapsedMicroseconds / 1e6 + avOffset;

  @override
  Future<void> start() async => _sw.start();

  @override
  Future<void> seek(double s) async {
    _offset = s;
    _sw.reset();
  }
}
