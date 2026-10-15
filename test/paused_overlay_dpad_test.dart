// The resume overlay (shown after the app comes back from the background) must
// be resumable with an Android TV remote, and the remote must not reach the
// demo behind it.
//
// The regression this guards: the overlay was a full-screen GestureDetector
// layered in the demo's Stack. On the Android TV emulator, after Home and back,
// a D-pad centre press went to the focused demo surface BEHIND it (toggling the
// commentary), the arrows reached the panel's controls, and nothing resumed.
// main.dart now wraps the layers behind the overlay in ExcludeFocus while
// paused, and PausedOverlay holds focus itself.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/paused_overlay.dart';

// Mirrors main.dart's paused demo: a non-focusable ancestor key listener, the
// autofocused demo surface and a panel control behind the overlay, excluded
// from focus, and the overlay on top.
Widget _pausedLikeMain({
  required VoidCallback onResume,
  required VoidCallback onBehind,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Focus(
          canRequestFocus: false,
          onKeyEvent: (node, e) => KeyEventResult.ignored,
          child: Stack(
            children: [
              Positioned.fill(
                child: ExcludeFocus(
                  child: Row(
                    children: [
                      const Expanded(
                        child: Focus(autofocus: true, child: SizedBox.expand()),
                      ),
                      TextButton(
                          onPressed: onBehind, child: const Text('panel')),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: PausedOverlay(onResume: onResume, remote: true),
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  // Every key that should resume: Flutter's default ActivateIntent keys (the
  // D-pad centre among them) plus the remote's play keys.
  for (final key in const [
    LogicalKeyboardKey.select, // D-pad centre
    LogicalKeyboardKey.gameButtonA,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.mediaPlayPause,
    LogicalKeyboardKey.mediaPlay,
  ]) {
    testWidgets('${key.keyLabel} resumes the paused demo', (t) async {
      var resumed = 0;
      var behind = 0;
      await t.pumpWidget(_pausedLikeMain(
          onResume: () => resumed++, onBehind: () => behind++));
      await t.pump();

      await t.sendKeyEvent(key);
      await t.pump();

      expect(resumed, 1, reason: '${key.keyLabel} must resume the demo');
      expect(behind, 0);
    });
  }

  testWidgets('the D-pad cannot reach the controls behind the overlay',
      (t) async {
    var resumed = 0;
    var behind = 0;
    await t.pumpWidget(
        _pausedLikeMain(onResume: () => resumed++, onBehind: () => behind++));
    await t.pump();

    for (final arrow in const [
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
    ]) {
      await t.sendKeyEvent(arrow);
      await t.pump();
    }
    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pump();

    expect(behind, 0, reason: 'focus escaped to a control behind the overlay');
    expect(resumed, 1, reason: 'focus left the resume action');
  });

  testWidgets('a tap still resumes, and the hint names the remote on a TV',
      (t) async {
    var resumed = 0;
    await t.pumpWidget(
        _pausedLikeMain(onResume: () => resumed++, onBehind: () {}));
    await t.pump();

    expect(find.text('press OK to resume'), findsOneWidget);
    await t.tap(find.text('PAUSED'));
    expect(resumed, 1);
  });
}
