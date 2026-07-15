import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web: the Screen Wake Lock API, called directly.
///
/// NOT through wakelock_plus. Its web plugin injects a NoSleep.js asset and
/// drives it from Dart, and in this app that path silently did nothing — no
/// script tag in the DOM, no `navigator.wakeLock.request`, no error to explain
/// it. Nine lines of the real API are cheaper than a black box, and they are
/// checkable from the console.
///
/// The lock is NOT durable: the browser drops it the moment the tab is hidden,
/// and a released sentinel cannot be reused. So we hold the sentinel, and
/// re-request on `visibilitychange` for as long as the demo wants it — without
/// that, tabbing away once and coming back leaves the screen free to sleep
/// through the rest of the demo.
web.WakeLockSentinel? _sentinel;
bool _wanted = false;
bool _listening = false;

void keepScreenAwake(bool on) {
  _wanted = on;
  if (on) {
    if (!_listening) {
      _listening = true;
      web.document.addEventListener(
        'visibilitychange',
        ((web.Event _) {
          if (_wanted && web.document.visibilityState == 'visible') _request();
        }).toJS,
      );
    }
    _request();
  } else {
    _sentinel?.release();
    _sentinel = null;
  }
}

void _request() {
  // A hidden document is not allowed to take a screen wake lock — the request
  // rejects with NotAllowedError. The visibilitychange listener retakes it.
  if (web.document.visibilityState != 'visible') return;
  try {
    web.window.navigator.wakeLock.request('screen').toDart.then(
      (s) => _sentinel = s,
      // Unsupported browser, insecure origin, or a hidden tab: not fatal, the
      // demo just plays with the screen free to dim.
      onError: (_) => _sentinel = null,
    );
  } catch (_) {
    // navigator.wakeLock is undefined (Safari < 16.4, http:// origin, ...).
  }
}
