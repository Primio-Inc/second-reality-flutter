// Native implementation of [buildExternalLink]: open [url] in the system
// browser. A Listener (not a GestureDetector) so it fires even inside a
// SelectionArea — onPointerUp is dispatched during hit-testing and never enters
// the gesture arena that a tap would lose. On native there is no popup blocker,
// so launchUrl works straight from the pointer callback.

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

Widget buildExternalLink(String url, Widget child) {
  return Listener(
    onPointerUp: (PointerUpEvent _) =>
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
    child: child,
  );
}
