// The landing screen's START button must be reachable AND activatable with an
// Android TV D-pad: it is the one thing the whole app exists to do, and Play's
// TV review rejected the app for "Missing DPad functionality".
//
// The regression this guards: main.dart wraps the whole app in a
// Focus(onKeyEvent:) that carries the demo's desktop keyboard shortcuts. When
// that wrapper was ALSO an autofocusing focus stop, it STOLE focus from START's
// FocusableActionDetector — primaryFocus landed on the wrapper, not the button —
// so a D-pad centre press (Flutter maps `select`/`gameButtonA`/`enter` to
// ActivateIntent on the FOCUSED node) reached the wrapper's handler (which
// ignores everything before the demo starts) instead of activating START. The
// app could not be started with a D-pad at all.
//
// The fix makes the wrapper canRequestFocus:false — a pure ancestor key
// listener — so START's autofocus wins. If START did not hold focus, none of
// the activate keys below would fire onStart, so this is a decisive guard.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/start_screen.dart';

// Mirrors main.dart's build(): the landing screen under a non-focusable
// ancestor key listener.
Widget _wrapLikeMain(Widget child) => MaterialApp(
      home: Scaffold(
        body: Focus(
          canRequestFocus: false,
          onKeyEvent: (node, e) => KeyEventResult.ignored,
          child: child,
        ),
      ),
    );

void main() {
  // Every key Flutter's default shortcuts map to ActivateIntent on a TV remote /
  // gamepad / keyboard.
  for (final key in const [
    LogicalKeyboardKey.select, // D-pad centre
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
  ]) {
    testWidgets('${key.keyLabel} activates the autofocused START button',
        (t) async {
      var started = false;
      await t.pumpWidget(
          _wrapLikeMain(StartScreen(onStart: () => started = true)));
      // The backdrop animates forever, so pumpAndSettle would time out.
      await t.pump(const Duration(milliseconds: 16));

      await t.sendKeyEvent(key);
      await t.pump();

      expect(started, isTrue,
          reason: '${key.keyLabel} (a D-pad activate key) must start the demo; '
              'if it does not, START never received autofocus');
    });
  }
}
