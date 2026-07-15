import 'package:wakelock_plus/wakelock_plus.dart';

/// Native (Android/iOS/desktop): hold the screen awake through the plugin, which
/// maps to `FLAG_KEEP_SCREEN_ON` / `idleTimerDisabled`.
///
/// Fire-and-forget by design: a platform that cannot do this must not take the
/// demo down with it.
void keepScreenAwake(bool on) {
  WakelockPlus.toggle(enable: on).catchError((_) {});
}
