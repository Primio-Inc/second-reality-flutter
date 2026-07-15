import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/asset_store.dart';
import 'package:second_reality/engine/part.dart';
import 'package:second_reality/engine/tunnel_tables.dart';
import 'package:second_reality/parts/p06_tunnel.dart';

/// Reference lit-pixel counts per jiffy, from an offline replica of
/// TUNNELI/TUN10.PAS driven by the original TUNNEL.DAT/SINIT.DAT tables.
const _expected = {
  20: 64, // first ring reaches the far end of the drawn range
  40: 551,
  100: 3378, // tunnel fully built up
  300: 3924,
  600: 3854,
  900: 3809,
  1010: 1845, // run-out: unlit rings sweeping in from the far end
  1050: 14,
};

void main() {
  setUpAll(() {
    final bytes = File('assets/tables/tunnel.srt').readAsBytesSync();
    AssetStore.tunnel = TunnelTables.decode(bytes);
  });

  test('tables decode to the original dimensions', () {
    final t = AssetStore.tunnel!;
    expect(t.radii, 138);
    expect(t.pts, 64);
    expect(t.sinit.length, 4097);
    expect(t.cosit.length, 2049);
    // pcalc ring 0 (z=10): a wide ellipse centred on the screen — 160 +- 17
    // horizontally (z*1.7) and 100 +- 10 vertically.
    expect(t.pcalc[0], 160); // a=0: sin(0)=0
    expect(t.pcalc[1], 110); // a=0: cos(0)=1 -> 100+10
  });

  test('renders the reference dot counts, far rings dark and near bright', () {
    final part = TunnelPart()..init();
    for (final entry in _expected.entries) {
      part.update(entry.key / kDemoFps, const []);
      final lit = part.indexed.pixels.where((p) => p != 0).length;
      expect(lit, entry.value, reason: 'jiffy ${entry.key}');
    }
  });

  test('the tunnel is empty before it starts and after it runs out', () {
    final part = TunnelPart()..init();
    part.update(0, const []);
    expect(part.indexed.pixels.every((p) => p == 0), isTrue);
    part.update(1060 / kDemoFps, const []);
    expect(part.indexed.pixels.every((p) => p == 0), isTrue);
  });
}
