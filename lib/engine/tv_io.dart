import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// Channel name, shared with MainActivity.kt.
const MethodChannel _channel = MethodChannel('second_reality/platform');

/// Native: ask Android's UiModeManager whether this is a TV.
///
/// Anything that cannot answer is NOT a TV: a thrown channel error means there
/// is no handler on the other side, which means this is not our Android
/// activity, and the link stays a link. Failing the other way would strip the
/// link off every desktop and iOS build.
Future<bool> detectAndroidTv() async {
  if (defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await _channel.invokeMethod<bool>('isTv') ?? false;
  } catch (_) {
    return false;
  }
}
