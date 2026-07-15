import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/music_rows.dart';
import 'package:second_reality/engine/visu_scene.dart';
import 'package:second_reality/demo_script.dart';
import 'package:second_reality/parts/p02_horizon.dart';

/// The intro flyover's timing is DERIVED, not fitted — this pins the derivation.
///
/// `VISU/C/U2A.C` waits on the music before it starts:
///
///     _asm { mov bx,6 ; int 0fch ; mov a,cx ; mov b,bx }
///     if(a>10 && b>46) break;
///
/// `int 0FCh` function 6 is `muscode_6` (DIS/DISINT.ASM), which returns
/// CX = the music ORDER and BX = the ROW. So the part starts at the first frame
/// where order > 10 and row > 46 — i.e. MUSIC0 order 11, row 47 — and the row
/// clock turns that into a soundtrack time. Nothing here is measured off the
/// video.
///
/// It then plays U2A.0AB at one frame per VGA retrace (copper 2 is the retrace
/// interrupt; `currframe` advances with it), so the shot's length is fixed by
/// the frame count, not by the machine.
void main() {
  test('the ship trigger is the music row U2A.C waits for (order 11, row 47)',
      () {
    final rows = MusicRows.decode(
        File('assets/tables/music_rows.srt').readAsBytesSync());

    // The first row at/after order 11 row 47 in MUSIC0's first pass (segment 0).
    double? cue;
    for (var i = 0; i < rows.times.length; i++) {
      if (rows.segments[i] == 0 &&
          rows.orders[i] == 11 &&
          rows.rows[i] == 47) {
        cue = rows.times[i];
        break;
      }
    }
    expect(cue, isNotNull, reason: 'order 11 row 47 must exist in MUSIC0');
    expect(cue!, closeTo(93.965, 0.005));

    // demo_script must fire the ship on exactly that cue.
    final ship = buildDemoTimeline()
        .sync
        .events
        .firstWhere((e) => e.code == HorizonPart.shipCode);
    expect(ship.time, closeTo(cue, 0.005));
  });

  test('U2A.0AB replays the original objects and their on/off frames', () {
    final scene = VisuScene.decode(
        Uint8List.fromList(File('assets/meshes/u2a.srv').readAsBytesSync()));

    // 6 co[] slots: the camera, three s01 escorts, Sippi and moottori.
    expect(scene.objectCount, 6);
    expect(scene.frames.length, 521);
    expect(scene.meshes.map((m) => m.name), ['s01', 'Sippi', 'moottori']);

    /// The frame an object is switched on (the stream's 0x80 token).
    int onAt(int slot) =>
        scene.frames.indexWhere((f) => f.on[slot] != 0);

    // The mothership comes first and the escorts burst in ~3.5s later — the
    // capture shows exactly that (disc entering at 94.2s, escorts at 97.7s).
    expect(onAt(2), 16); // Sippi
    expect(onAt(1), 259); // s01 #1
    expect(onAt(4), 259); // s01 #2
    expect(onAt(5), 270); // s01 #3
    // 70.086 Hz retrace: Sippi at 94.19s, the escorts at 97.66s.
    expect((onAt(1) - onAt(2)) / 70.086, closeTo(3.47, 0.05));

    // The matrix carries rotation AND scale, so no scale track is applied on
    // top of it — Sippi's own matrix must not be near-identity-scaled.
    final f = scene.frames[100];
    expect(f.on[2], isNot(0));
    expect(f.mats[2 * 9 + 0].abs(), greaterThan(1000));
  });
}
