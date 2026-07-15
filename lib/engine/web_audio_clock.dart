import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

import 'demo_clock.dart';

/// The web demo clock: WebAudio, NOT an `<audio>` element.
///
/// just_audio on web plays through an HTML audio element, and that element is
/// unusable as a demo clock: its reported `currentTime` LAGS the sound you
/// actually hear (measured ~4-5s on this machine), and the instant sound truly
/// starts — at play, and again after every seek into a 19MB ogg — is not
/// observable from Dart at all. Every desync we chased came from guessing one
/// of those two moments.
///
/// WebAudio removes the guessing entirely:
///  - the soundtrack is DECODED UP FRONT into an [web.AudioBuffer] (that is the
///    load gate — after it, playback and seeks are instant, no buffering ever);
///  - an [web.AudioBufferSourceNode] is SCHEDULED to start at an exact
///    `ctx.currentTime` in the near future, and WebAudio honours that
///    sample-exactly;
///  - `ctx.currentTime` is the audio hardware's own clock, and
///    `baseLatency`/`outputLatency` report how far the physical output is
///    behind it. So `seconds` is derived, not guessed:
///      pos = startPos + (ctx.currentTime - scheduledStart) - outputLatency
class WebAudioDemoClock extends DemoClock {
  final String assetPath;

  web.AudioContext? _ctx;
  web.AudioBuffer? _buffer;
  web.AudioBufferSourceNode? _node;

  // --- output probe -------------------------------------------------------
  // Taps the REAL output stream. Everything else in this file is a derivation;
  // this is a measurement. [probe] returns the loudness of the audio coming out
  // of the speakers RIGHT NOW, so the demo can be checked against what is
  // actually audible instead of against what we believe we scheduled.
  web.AnalyserNode? _analyser;
  JSFloat32Array? _probeBuf;
  JSUint8Array? _freqBuf;

  /// The output's real frequency spectrum, for the commentary's equaliser. Same
  /// AnalyserNode as the probe, so it is the audio actually being played.
  @override
  List<double>? get spectrum {
    final a = _analyser;
    var b = _freqBuf;
    if (a == null) return null;
    b ??= _freqBuf = Uint8List(a.frequencyBinCount).toJS;
    a.getByteFrequencyData(b);
    final d = b.toDart;
    return [for (var i = 0; i < d.length; i++) d[i] / 255.0];
  }

  /// RMS of the audio currently leaving the output, 0..1 (0 if no probe).
  @override
  double get outputLevel {
    final a = _analyser;
    final b = _probeBuf;
    if (a == null || b == null) return 0;
    a.getFloatTimeDomainData(b);
    final d = b.toDart;
    var sum = 0.0;
    for (var i = 0; i < d.length; i++) {
      sum += d[i] * d[i];
    }
    return math.sqrt(sum / d.length);
  }

  // The current node plays the buffer from `_startPos`, starting at the exact
  // context time `_startCtx` (scheduled, honoured sample-exactly).
  double _startPos = 0;
  double _startCtx = 0;
  bool _playing = false;

  WebAudioDemoClock(this.assetPath);

  /// Fetch + fully decode the soundtrack. Slow once (a 19MB ogg), instant
  /// forever after — this IS the "DECODING SOUNDTRACK" gate.
  @override
  Future<void> load() async {
    final ctx = web.AudioContext();
    _ctx = ctx;
    final data = await rootBundle.load(assetPath);
    final bytes = Uint8List.fromList(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
    _buffer = await ctx.decodeAudioData(bytes.buffer.toJS).toDart;

    final an = ctx.createAnalyser();
    an.fftSize = 1024;
    an.connect(ctx.destination);
    _analyser = an;
    _probeBuf = Float32List(an.fftSize).toJS;
  }

  /// How far the physical output lags `ctx.currentTime`. `outputLatency` is
  /// not implemented in every browser; `baseLatency` is.
  ///
  /// CLAMPED, deliberately. This value is SUBTRACTED from the clock, so a
  /// platform that over-reports it drags every visual late by that much — the
  /// exact "everything is seconds behind the music" failure we chased for days.
  /// Real output latency is milliseconds (a few hundred at worst, on Bluetooth);
  /// anything beyond that is the driver lying, and we refuse to believe it.
  static const double _maxLatency = 0.5;

  @override
  double get outputLatency {
    final ctx = _ctx;
    if (ctx == null) return 0;
    var l = ctx.baseLatency;
    final out = ctx.outputLatency;
    if (out.isFinite && out > 0) l += out;
    if (!l.isFinite || l < 0) return 0;
    return l > _maxLatency ? _maxLatency : l;
  }

  /// The RAW, unclamped platform numbers — for the HUD, so a bogus one is
  /// visible rather than silently absorbed.
  @override
  String get latencyReport {
    final ctx = _ctx;
    if (ctx == null) return '-';
    final b = ctx.baseLatency;
    final o = ctx.outputLatency;
    return 'base ${(b * 1000).toStringAsFixed(0)}ms '
        'out ${o.isFinite ? (o * 1000).toStringAsFixed(0) : "?"}ms '
        '-> used ${(outputLatency * 1000).toStringAsFixed(0)}ms';
  }

  @override
  double get seconds {
    final ctx = _ctx;
    if (ctx == null || !_playing) return _startPos + avOffset;
    // Before the scheduled start instant no sound has come out yet.
    final elapsed = ctx.currentTime - _startCtx;
    if (elapsed <= 0) return _startPos + avOffset;
    return _startPos + elapsed - outputLatency + avOffset;
  }

  @override
  double? get audioPosition => seconds - avOffset;

  /// (Re)start playback of the decoded buffer from `pos`: kill the old node,
  /// schedule a fresh one a hair in the future, and anchor the clock to the
  /// SCHEDULED instant. Buffer sources are one-shot and free — this is how
  /// WebAudio seeks.
  void _startNode(double pos) {
    final ctx = _ctx!;
    try {
      _node?.stop();
    } catch (_) {} // stopping a never-started/finished node throws; harmless
    final node = ctx.createBufferSource();
    node.buffer = _buffer;
    // Through the probe (which is wired to the destination), so what we measure
    // IS what is played.
    node.connect(_analyser ?? ctx.destination);
    final when = ctx.currentTime + 0.05;
    node.start(when, pos);
    _node = node;
    _startPos = pos;
    _startCtx = when;
    _playing = true;
  }

  @override
  Future<void> start() async {
    // The context starts suspended until a user gesture; our start flow is
    // click-driven, so resume() succeeds here.
    await _ctx!.resume().toDart;
    _startNode(0);
  }

  @override
  Future<void> seek(double s) async => _startNode(s);

  /// The demo is over. Kill the source node and freeze the clock WHERE IT IS —
  /// latch the current position into `_startPos` first, or clearing `_playing`
  /// would make `seconds` snap back to wherever playback last started.
  @override
  void stop() {
    _startPos = seconds - avOffset;
    try {
      _node?.stop();
    } catch (_) {} // a finished/never-started node throws; harmless
    _node = null;
    _playing = false;
  }

  /// Freeze where we are. A WebAudio source node cannot be un-paused, so pause
  /// is "remember the position and kill the node", and resume is a fresh node
  /// started at that position — which is exactly what [seek] already does.
  @override
  void pause() {
    if (!_playing) return;
    _startPos = seconds - avOffset;
    try {
      _node?.stop();
    } catch (_) {}
    _node = null;
    _playing = false;
  }

  @override
  Future<void> resume() async {
    if (_playing || _ctx == null || _buffer == null) return;
    await _ctx!.resume().toDart; // the context suspends when the tab is hidden
    _startNode(_startPos);
  }
}

/// Factory used by main.dart through the conditional import.
DemoClock createDemoAudioClock(String assetPath) =>
    WebAudioDemoClock(assetPath);
