import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'flic_clip.dart';
import 'forest_tables.dart';
import 'interference_tables.dart';
import 'lens_tables.dart';
import 'mesh3d.dart';
import 'music_rows.dart';
import 'plasma_tables.dart';
import 'rayscrl_tables.dart';
import 'sinfield_tables.dart';
import 'sri_image.dart';
import 'tunnel_tables.dart';
import 'visu_scene.dart';

/// Preloaded converted assets. Tests inject entries directly; the app calls
/// [loadAll] on the start screen before the timeline is built.
class AssetStore {
  static final Map<String, SriImage> images = {};
  static final Map<String, Mesh3D> meshes = {};
  static final Map<String, FlicClip> flics = {};
  static final Map<String, VisuScene> scenes = {};
  static MusicRows? musicRows;
  static TunnelTables? tunnel;
  static InterferenceTables? interference;
  static ForestTables? forest;
  static LensTables? lens;
  static PlasmaTables? plasma;
  static RayscrlTables? rayscrl;
  static SinFieldTables? sinfield;
  /// The credit screens' thumbnails — OUR renders of the parts they credit,
  /// produced by tool/capture_thumbs.dart. The original's own 160x100 pixel-art
  /// thumbnails are mush at 4:3 (and one of them was never finished), so the
  /// credits show the port's picture of each part instead.
  static final List<ui.Image> creditThumbs = [];
  static String? endScrollText;

  static Future<void> loadAll() async {
    for (final name in [
      'hoi',
      'srtitle',
      'fc',
      'troll',
      'hillback',
      'lenspic',
      'rayback',
      'icekngdm',
      'fcrings',
    ]) {
      final data = await rootBundle.load('assets/images/$name.sri');
      images[name] = SriImage.decode(data.buffer.asUint8List());
    }
    for (final name in ['pxlship']) {
      final data = await rootBundle.load('assets/meshes/$name.svm');
      meshes[name] = Mesh3D.decode(data.buffer.asUint8List());
    }
    // The intro flyover is the original's COMPILED scene (objects + the baked
    // animation stream), not the 3D Studio project — see VisuScene.
    for (final name in ['u2a', 'u2e']) {
      final data = await rootBundle.load('assets/meshes/$name.srv');
      scenes[name] = VisuScene.decode(data.buffer.asUint8List());
    }
    for (final name in ['prax4']) {
      final data = await rootBundle.load('assets/anim/$name.sfl');
      flics[name] = FlicClip.decode(data.buffer.asUint8List());
    }
    final tun = await rootBundle.load('assets/tables/tunnel.srt');
    tunnel = TunnelTables.decode(tun.buffer.asUint8List());
    final itf = await rootBundle.load('assets/tables/interference.srt');
    interference = InterferenceTables.decode(itf.buffer.asUint8List());
    final frs = await rootBundle.load('assets/tables/forest.srt');
    forest = ForestTables.decode(frs.buffer.asUint8List());
    final lns = await rootBundle.load('assets/tables/lens.srt');
    lens = LensTables.decode(lns.buffer.asUint8List());
    final plz = await rootBundle.load('assets/tables/plasma.srt');
    plasma = PlasmaTables.decode(plz.buffer.asUint8List());
    final ray = await rootBundle.load('assets/tables/rayscrl.srt');
    rayscrl = RayscrlTables.decode(ray.buffer.asUint8List());
    final snf = await rootBundle.load('assets/tables/sinfield.srt');
    sinfield = SinFieldTables.decode(snf.buffer.asUint8List());
    creditThumbs.clear();
    for (var i = 1; i <= 21; i++) {
      final n = i.toString().padLeft(2, '0');
      final data = await rootBundle.load('assets/images/credits/$n.png');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      creditThumbs.add((await codec.getNextFrame()).image);
    }
    final mr = await rootBundle.load('assets/tables/music_rows.srt');
    musicRows = MusicRows.decode(mr.buffer.asUint8List());
    // The end scroller's greetings — the SHIPPED text, with its `[N` control
    // lines (see tool/convert_endscroll.py).
    endScrollText = await rootBundle.loadString('assets/text/endscrol.txt');
  }
}
