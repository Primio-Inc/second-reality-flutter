// A tappable inline external link that works in every Flutter target, including
// the --wasm web release. See external_link_web.dart / external_link_stub.dart
// for why the obvious approaches (Flutter onTap, launchUrl from a gesture,
// url_launcher's Link widget) all fail on web release inside a SelectionArea.
//
// [child] is the visible widget (the styled link text); [url] is opened in a new
// tab on web, or the system browser on native.

import 'package:flutter/widgets.dart';

import 'external_link_stub.dart'
    if (dart.library.js_interop) 'external_link_web.dart' as impl;

Widget buildExternalLink(String url, Widget child) =>
    impl.buildExternalLink(url, child);
