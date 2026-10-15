import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shown when the app comes back from the background. The demo is frozen at the
/// exact music position it left off at; resuming starts the audio and the clock
/// together.
///
/// It must work with an Android TV remote, not just a finger. A full-screen
/// GestureDetector takes taps and nothing else, and as a plain Stack layer it
/// does not hold focus either: on a TV the remote's centre press went to the
/// demo surface BEHIND it (toggling the commentary), the arrows reached the
/// panel's controls, and the demo could not be resumed at all. So the overlay
/// is its own autofocusing FocusScope with one real focus target, and
/// main.dart wraps everything behind it in ExcludeFocus while it is up.
///
/// Flutter's default shortcuts already map the D-pad centre (`select`), the
/// gamepad A button, enter and space to ActivateIntent; the remote's play/pause
/// keys are mapped here too, since resuming IS play.
class PausedOverlay extends StatefulWidget {
  const PausedOverlay({
    super.key,
    required this.onResume,
    required this.remote,
  });

  final VoidCallback onResume;

  /// True on Android TV: there is nothing to tap, so the hint names the
  /// remote's button instead.
  final bool remote;

  @override
  State<PausedOverlay> createState() => _PausedOverlayState();
}

class _PausedOverlayState extends State<PausedOverlay> {
  static const _amber = Color(0xFFFFAE1A);

  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      autofocus: true,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.mediaPlayPause): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.mediaPlay): ActivateIntent(),
        },
        child: FocusableActionDetector(
          autofocus: true,
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onResume();
                return null;
              },
            ),
          },
          child: Semantics(
            button: true,
            label: 'Resume the demo',
            child: GestureDetector(
              onTap: widget.onResume,
              child: ColoredBox(
                color: const Color(0xCC04050C),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 140),
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: _focused ? _amber : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: const Icon(Icons.play_arrow_rounded,
                            color: _amber, size: 56),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'PAUSED',
                        style: TextStyle(
                          color: _amber,
                          fontFamily: 'monospace',
                          fontSize: 14,
                          letterSpacing: 3,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.remote ? 'press OK to resume' : 'tap to resume',
                        style: TextStyle(
                          color:
                              const Color(0xFFDDDDE6).withValues(alpha: 0.75),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
