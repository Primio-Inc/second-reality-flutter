import 'audioplayers_clock.dart';
import 'demo_clock.dart';

/// Non-web targets: audioplayers with a pre-set source (instant resume/seek —
/// the Logicats SoundManager recipe). Web resolves to web_audio_clock.dart via
/// the conditional import in main.dart.
DemoClock createDemoAudioClock(String assetPath) =>
    AudioplayersDemoClock(assetPath);
