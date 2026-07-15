import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import 'demo_clock.dart';

/// The native demo clock: audioplayers with a PRE-SET source.
///
/// The recipe (proven in Logicats' SoundManager): call `setSource()` once at
/// init so the native player is fully prepared, then playback is
/// `seek + resume` on that prepared player — no source switching, no prepare
/// latency, instant seeks. The clock itself is anchor-once like the web
/// clock: anchor to the position we asked for at the instant playback
/// begins, then run on the monotonic clock (audio advances at exactly 1x).
class AudioplayersDemoClock extends DemoClock {
  /// Path as pubspec asset ('assets/music/soundtrack.ogg'); audioplayers wants
  /// it relative to the assets/ root.
  final String assetPath;
  final AudioPlayer _player = AudioPlayer();
  final Stopwatch _sw = Stopwatch()..start();

  double _anchorPos = 0;
  double _anchorWall = 0;
  bool _rolling = false;

  AudioplayersDemoClock(this.assetPath);

  @override
  Future<void> load() async {
    // ReleaseMode.stop keeps the player resumable after playback ends instead
    // of releasing native resources.
    await _player.setReleaseMode(ReleaseMode.stop);
    final rel = assetPath.startsWith('assets/')
        ? assetPath.substring('assets/'.length)
        : assetPath;
    // Fully prepares the native player — after this, resume() is instant.
    await _player.setSource(AssetSource(rel));
  }

  @override
  double get seconds {
    if (!_rolling) return _anchorPos + avOffset;
    final wall = _sw.elapsedMicroseconds / 1e6;
    return _anchorPos + (wall - _anchorWall) + avOffset;
  }

  @override
  double? get audioPosition => seconds - avOffset;

  @override
  Future<void> start() async {
    await _player.resume(); // prepared source: starts immediately
    _anchorPos = 0;
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _rolling = true;
  }

  @override
  Future<void> seek(double s) async {
    _anchorPos = s;
    await _player.seek(Duration(microseconds: (s * 1e6).round()));
    await _player.resume();
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _rolling = true;
  }

  /// The app went to the background. Latch the position, then stop the clock as
  /// well as the audio: `_rolling = false` makes [seconds] return the frozen
  /// `_anchorPos`, so no demo time passes while we are away. Pausing only the
  /// PLAYER would leave the wall-clock extrapolation running and the demo would
  /// come back seconds ahead of the music.
  @override
  void pause() {
    if (!_rolling) return;
    _anchorPos = seconds - avOffset;
    _rolling = false;
    _player.pause();
  }

  @override
  Future<void> resume() async {
    if (_rolling) return;
    // Seek before resuming: the native player's own position may have drifted
    // from ours across the background transition, and _anchorPos is the truth.
    await _player.seek(Duration(microseconds: (_anchorPos * 1e6).round()));
    await _player.resume();
    _anchorWall = _sw.elapsedMicroseconds / 1e6;
    _rolling = true;
  }

  /// The demo is over. Without this the native build inherits the base class's
  /// no-op and the soundtrack plays on over the landing screen.
  @override
  void stop() {
    _rolling = false;
    _player.stop();
  }
}
