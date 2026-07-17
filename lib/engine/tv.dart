import 'tv_io.dart' if (dart.library.js_interop) 'tv_web.dart';

/// Whether this build is running on an Android TV.
///
/// Resolved ONCE, in main(), before the first frame — the landing screen reads
/// it while building, so it cannot be a Future there, and it cannot change
/// while the app runs (a TV does not stop being a TV).
///
/// It exists for exactly one thing: Play's TV quality bar (TV-WB) says a TV app
/// must not attempt to launch a web browser, and most TVs have none to launch,
/// so the landing screen's primio.dev link is plain text on a TV. Reach for it
/// only where the TV genuinely differs; the demo itself is identical.
bool isAndroidTv = false;

/// Ask the platform once. Safe to call anywhere: it never throws.
Future<void> initTvDetection() async {
  isAndroidTv = await detectAndroidTv();
}
