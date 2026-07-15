import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/visu_renderer.dart';
import 'package:second_reality/engine/visu_scene.dart';

/// The smoothing: [VisuRenderer.sample] evaluates the animation stream at a
/// FRACTIONAL frame so the motion is not quantised to the original's retrace
/// grid. It must interpolate ordinary motion, but NEVER blend across a switch or
/// a cut — see the doc on sample().
VisuScene _scene(List<VisuFrame> frames) => VisuScene(
      Uint8List(768),
      const [],
      Int8List.fromList([-1, 0]), // co[0] = camera, co[1] = one object
      frames,
    );

VisuFrame _frame({
  required int fov,
  required int on,
  required int m0,
  required int x,
}) {
  final mats = Int32List(2 * 9);
  final pos = Int32List(2 * 3);
  // co[0], the camera: identity, at the origin.
  mats[0] = mats[4] = mats[8] = VisuScene.unit;
  // co[1], the object.
  mats[9] = m0;
  pos[3] = x;
  return VisuFrame(fov, Uint8List.fromList([1, on]), mats, pos);
}

void main() {
  test('an integer frame is the stream, untouched', () {
    final r = VisuRenderer(_scene([
      _frame(fov: 1000, on: 1, m0: 100, x: 10),
      _frame(fov: 2000, on: 1, m0: 200, x: 20),
    ]));
    final f = r.sample(0);
    expect(f.fov, 1000);
    expect(f.mats[9], 100);
    expect(f.pos[3], 10);
  });

  test('between two frames, position, matrix and FOV interpolate', () {
    final r = VisuRenderer(_scene([
      _frame(fov: 1000, on: 1, m0: 100, x: 10),
      _frame(fov: 2000, on: 1, m0: 200, x: 20),
    ]));
    final f = r.sample(0.5);
    expect(f.fov, 1500);
    expect(f.mats[9], 150);
    expect(f.pos[3], 15);
  });

  test('an object being switched on does NOT blend across the switch', () {
    final r = VisuRenderer(_scene([
      _frame(fov: 1000, on: 0, m0: 100, x: 10),
      _frame(fov: 1000, on: 1, m0: 900, x: 900),
    ]));
    final f = r.sample(0.5);
    // It holds frame 0's transform rather than sliding in from a stale pose.
    expect(f.on[1], 0);
    expect(f.mats[9], 100);
    expect(f.pos[3], 10);
  });

  test('a cut — a matrix jump of more than UNIT/4 in one frame — snaps', () {
    const jump = VisuScene.unit ~/ 2;
    final r = VisuRenderer(_scene([
      _frame(fov: 1000, on: 1, m0: 0, x: 0),
      _frame(fov: 1000, on: 1, m0: jump, x: 500),
    ]));
    final f = r.sample(0.5);
    expect(f.mats[9], 0, reason: 'a cut must not be interpolated through');
    expect(f.pos[3], 0);
  });

  test('sampling is clamped to the stream', () {
    final r = VisuRenderer(_scene([
      _frame(fov: 1000, on: 1, m0: 100, x: 10),
      _frame(fov: 2000, on: 1, m0: 200, x: 20),
    ]));
    expect(r.sample(-5).fov, 1000);
    expect(r.sample(99).fov, 2000);
  });
}
