import '../engine/visu_renderer.dart';
import '../engine/visu_scene.dart';

/// The intro "mothership" flyover — a replay of the original's COMPILED scene
/// (`VISU/C/SCENE/U2A.*`), drawn by the ported VISU pipeline ([VisuRenderer]).
///
/// This is not a reinterpretation of the 3D Studio project: `U2A.C` (the part's
/// own player) loads three object files and a delta-compressed animation stream,
/// and for every frame the stream hands it each object's full 3x3 matrix
/// (rotation AND scale), its position, whether it is switched on, and the camera
/// FOV. We replay that stream. See [VisuScene].
///
/// U2A steps the stream once per VGA retrace, so its 521 frames run for 7.44s.
/// The part feeds [VisuRenderer.paint] a FRACTIONAL frame, so the motion is
/// interpolated up to the display's refresh rate instead of stepping at 70 Hz.
///
/// U2A.C sorts objects purely by their centre vertex — none of U2E's draw-order
/// overrides — so the renderer is used as-is.
class IntroShipScene extends VisuRenderer {
  IntroShipScene(super.scene);
}
