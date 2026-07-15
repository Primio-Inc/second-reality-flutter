@Tags(['dump'])
library;

import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/asset_store.dart';
import 'package:second_reality/engine/indexed_surface.dart';
import 'package:second_reality/engine/part.dart';
import 'package:second_reality/engine/sri_image.dart';
import 'package:second_reality/engine/tunnel_tables.dart';
import 'package:second_reality/parts/p02_horizon.dart';
import 'package:second_reality/parts/p06_tunnel.dart';

/// Not a test — a visual-check harness. Renders parts' indexed surfaces to PNGs
/// under build/frames/ so they can be compared against reference/frames/.
///   flutter test test/parts/dump_frames_test.dart --tags dump
void main() {
  Future<void> dump(IndexedSurface s, String name) async {
    final rgba = s.toRgbaBytes();
    final buf = await ImmutableBuffer.fromUint8List(rgba);
    final desc = ImageDescriptor.raw(buf,
        width: s.width, height: s.height, pixelFormat: PixelFormat.rgba8888);
    final codec = await desc.instantiateCodec();
    final img = (await codec.getNextFrame()).image;
    final png = await img.toByteData(format: ImageByteFormat.png);
    final f = File('build/frames/$name.png')..createSync(recursive: true);
    f.writeAsBytesSync(png!.buffer.asUint8List());
    // ignore: avoid_print
    print('wrote ${f.path}');
  }

  test('dump horizon + tunnel', () async {
    AssetStore.images['hoi'] = SriImage.decode(
        File('assets/images/hoi.sri').readAsBytesSync());
    AssetStore.tunnel = TunnelTables.decode(
        File('assets/tables/tunnel.srt').readAsBytesSync());

    final h = HorizonPart()..init();
    for (final t in [2.0, 19.0]) {
      h.update(t, const []);
      await dump(h.indexed, 'horizon_${t.toStringAsFixed(0)}s');
    }

    final tun = TunnelPart()..init();
    for (final f in [60, 200, 700, 1000]) {
      tun.update(f / kDemoFps, const []);
      await dump(tun.indexed, 'tunnel_f$f');
    }
  }, tags: ['dump']);
}
