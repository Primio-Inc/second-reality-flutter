// Renders the CREDITS part's 21 thumbnails from OUR OWN parts.
//
// The original's thumbnails (CREDITS/PICS/PIC*.LBM) are 160x100 pixel art, and
// blown up to the 4:3 screen they are mush — and one of them (PIC02) is not even
// finished, it is a "PARTPIC MISSING (PXL SUX)" placeholder that the shipped
// EXE clearly did not use. So the credits show OUR renders of the very parts
// they credit, at the port's own resolution.
//
// Everything else about the part is unchanged: the same 21 screens in the same
// order, the same credit lines, the same CRTC slide-in.
//
// It is not a test — it is a renderer that happens to run in the test harness,
// because that is where a headless Flutter canvas and the asset bundle live.
//
// Usage:  flutter test tool/capture_thumbs.dart
// Output: assets/images/credits/NN.png (and reference/art/credits/NN.png)
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/demo_script.dart';
import 'package:second_reality/engine/asset_store.dart';
import 'package:second_reality/engine/part.dart';

/// The moment of each part that best says what the part IS — matched to the
/// subject of the original's own thumbnail for that screen (extracted from the
/// capture: horizon, ship, explosion, title, glenz, tunnel, interference,
/// techno, troll, forest, lens, rotozoomer, plasma, cube, dots, sword scroll,
/// sinusfield, jellypic, city, rings, and the credits themselves).
const List<(String, double)> shots = [
  ('01', 75.0), // the horizon, with a production credit up
  ('02', 97.0), // the mothership flyover
  ('03', 105.5), // the explosion
  ('04', 110.3), // the title splash
  ('05', 127.0), // the glenz over the checkerboard
  ('06', 160.0), // the dot tunnel
  ('07', 178.5), // the interference rings
  ('08', 201.5), // the techno boxes
  ('09', 221.5), // the troll
  ('10', 241.7), // the forest scroller
  ('11', 270.5), // the lens
  ('12', 292.0), // the rotozoomer
  ('13', 330.0), // the plasma
  ('14', 356.0), // the plasma cube
  ('15', 393.3), // the minivectorballs
  ('16', 424.4), // the mirror-ball sword scroll
  ('17', 454.7), // the 3D sinusfield
  ('18', 473.7), // the jellypic
  ('19', 500.5), // the vector city
  ('20', 541.0), // the FC rings
  // The credits screen itself — the original's last thumbnail is a picture of
  // the credits. Ours is too, which means this one has to be shot in a SECOND
  // pass, once the other twenty exist.
  ('21', 547.6),
];

const double outW = 640, outH = 400;
const ui.Rect outRect = ui.Rect.fromLTWH(0, 0, outW, outH);
const ui.Size outSize = ui.Size(outW, outH);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render the credit thumbnails', () async {
    // The credit text is drawn with the bundled vector font; without loading it
    // here the harness falls back to a box glyph and the text comes out as tofu.
    final fd = await rootBundle.load('assets/fonts/EBGaramond.ttf');
    await (FontLoader('Credits')..addFont(Future.value(fd))).load();
    await AssetStore.loadAll();
    Directory('assets/images/credits').createSync(recursive: true);
    Directory('reference/art/credits').createSync(recursive: true);

    for (final (name, at) in shots) {
      final timeline = buildDemoTimeline();
      // Parts derive their state from t, but a few (the techno VGA emulation,
      // the plasma's page flipping) accumulate it, so step the part from its
      // own start at the demo's retrace rate rather than jumping.
      final start = timeline.entries
          .lastWhere((e) => e.start <= at)
          .start;
      for (var t = start; t < at; t += 1 / kDemoFps) {
        timeline.tick(t);
      }
      timeline.tick(at);
      final part = timeline.current!;

      final rec = ui.PictureRecorder();
      final canvas = ui.Canvas(
          rec, outRect);
      canvas.drawRect(outRect, ui.Paint()..color = const ui.Color(0xFF000000));

      final surf = part.indexed;
      if (surf != null) {
        final img = await _decode(surf.toRgbaBytes(), surf.width, surf.height);
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(0, 0, surf.width.toDouble(), surf.height.toDouble()),
          outRect,
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
      }
      part.paintVector(canvas, outSize);

      final pic = rec.endRecording();
      final out = await pic.toImage(outW.toInt(), outH.toInt());
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      final bytes = png!.buffer.asUint8List();
      File('assets/images/credits/$name.png').writeAsBytesSync(bytes);
      File('reference/art/credits/$name.png').writeAsBytesSync(bytes);
      // ignore: avoid_print
      print('credits/$name.png  <- ${part.runtimeType} @ ${at}s');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

Future<ui.Image> _decode(List<int> rgba, int w, int h) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      Uint8List.fromList(rgba), w, h, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}
