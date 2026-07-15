import 'dart:ui';
import 'indexed_surface.dart';
import 'sync_table.dart';

/// The demo's native frame rate: the original parts wait on the vertical
/// retrace (~70 Hz), and all frame-based logic (rotation steps, physics)
/// assumes it. Derive a part's frame number as `localSeconds * kDemoFps` so
/// motion runs at the original speed regardless of the browser's refresh rate.
const double kDemoFps = 70.0;

/// One full revolution in the original's angle units (see MATH.ASM `checkdeg`,
/// which wraps rotation angles at 3600 = 360.0°).
const int kAngleFullRev = 3600;

/// One self-contained demo part, mirroring the original's one-EXE-per-part
/// structure (each PART talked to DIS; here PartContext/DemoTimeline is DIS).
abstract class Part {
  /// The absolute music position (soundtrack seconds) of the current frame, set
  /// by [DemoTimeline] before each [update]. Parts that sync on the music ROW
  /// grid (see `MusicRows`, the engine's `dis_musrow()`) need it: [update]'s `t`
  /// is part-local, but the row clock is in soundtrack time.
  double musicTime = 0;

  /// The sync events fired since the previous update, WITH their times, set by
  /// [DemoTimeline] before each [update]. Anchor event-driven animation to
  /// `event.time` (converted to part-local via [musicTime]), never to the
  /// delivery frame — after a seek those differ by the whole skipped span.
  List<SyncEvent> syncEvents = const [];

  /// Non-null for parts that render VGA-style indexed graphics.
  IndexedSurface? get indexed => null;

  void init() {}

  /// [t] is part-local seconds; [syncCodes] are the dis_muscode-style events
  /// fired since the previous update.
  void update(double t, List<int> syncCodes);

  /// Native-resolution overlay (3D/vector elements). [size] is the 4:3
  /// demo viewport in logical pixels. Default: nothing.
  void paintVector(Canvas canvas, Size size) {}

  void dispose() {}
}
