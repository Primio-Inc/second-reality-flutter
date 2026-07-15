// Web implementation of [buildExternalLink]: overlay a REAL `<a target="_blank">`
// DOM element on top of the painted link text, so the BROWSER owns the click.
//
// This is what neither a Flutter tap handler nor url_launcher's Link widget could
// give us in the release build:
//   - a Flutter onTap is eaten by the surrounding SelectionArea's gesture arena
//     (flutter/flutter#141151),
//   - launchUrl(window.open) from a Flutter pointer callback is popup-blocked
//     because the browser does not see it as a user activation, and
//   - url_launcher's Link builds its anchor through the SEMANTICS tree, which is
//     off in a release build until accessibility engages — so in --wasm/CanvasKit
//     release there was literally no `<a>` in the DOM (verified: 0 anchors).
// A real anchor we place ourselves has none of those problems, and it also gives
// the native right-click menu ("Open in New Tab", "Copy Link Address") and the
// status-bar URL preview. package:web (not dart:html) because we build --wasm.

import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

final Set<String> _registered = <String>{};

Widget buildExternalLink(String url, Widget child) {
  final viewType = 'sr-ext-link:$url';
  if (_registered.add(viewType)) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final a = web.HTMLAnchorElement()
        ..href = url
        ..target = '_blank'
        ..rel = 'noopener noreferrer';
      a.style
        ..display = 'block'
        ..width = '100%'
        ..height = '100%'
        ..cursor = 'pointer'
        ..backgroundColor = 'transparent';
      return a;
    });
  }
  // The Stack sizes to its first (non-positioned) child — the painted text — and
  // Positioned.fill stretches the transparent anchor to exactly cover it.
  return Stack(
    alignment: Alignment.center,
    children: [
      child,
      Positioned.fill(child: HtmlElementView(viewType: viewType)),
    ],
  );
}
