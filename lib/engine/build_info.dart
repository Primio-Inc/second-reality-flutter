/// A visible, unmistakable stamp of WHICH BUILD is running.
///
/// We lost hours to a browser quietly serving an old build (a service worker
/// registered by an earlier `flutter build web` keeps serving its cached
/// main.dart.js and the 19MB soundtrack no matter what Cache-Control the server
/// sends). The fix is in web/index.html, but the real lesson is that "is this
/// even the new code?" must be answerable AT A GLANCE, not inferred from
/// whether the demo looks right.
///
/// Bump this whenever a change must be confirmed in the browser. It is shown on
/// the start screen and in the debug HUD (D).
const String kBuildId = 'footer-fold-1';
