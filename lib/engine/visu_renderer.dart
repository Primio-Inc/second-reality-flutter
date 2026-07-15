import 'dart:typed_data';
import 'dart:ui';

import 'visu_scene.dart';

/// The original VISU engine's render pipeline, ported step for step, and driven
/// by the COMPILED scene data the demo actually played (see [VisuScene]).
///
/// Both vector parts use it: the intro flyover (`VISU/C/U2A.C`, the mothership)
/// and the city fly-through near the end (`VISU/C/U2E.C`).
///
///   U2A.C/U2E.C  apply the camera to every switched-on object, z-sort the
///                objects by their centre vertex, draw back to front.
///   ACALC.ASM    calc_applyrmatrix / calc_rotate / calc_nrotate /
///                calc_project / calc_singlez — Q18.14 fixed point, UNIT=16384.
///   AVID.ASM     vid_window(0,319,25,174,512,9999999) and vid_cameraangle:
///                projmulx comes from the `_avistan` cotangent table, projmuly
///                is projmulx*225/256 (the VGA's non-square pixel).
///   ADRAW.ASM    backface cull (dot(normal, vertex) >= 0 is hidden), the
///                hardcoded light (12118,10603,3030) applied to the CAMERA-
///                rotated normal, the shade ramp, and the final palette index
///                = face.color + shade.
///
/// Rendering is modernised per the project's philosophy: the same palette
/// colours and the same shade values, but drawn anti-aliased at native
/// resolution, with the gouraud faces interpolated as vertex colours instead of
/// as 8.8 palette indices — and sampled at a FRACTIONAL frame (see [sample]) so
/// the motion is not quantised to the original's 70 Hz retrace grid.
class VisuRenderer {
  final VisuScene scene;

  /// Called for every switched-on object once its z-sort distance is known, so
  /// a part can override the draw order the way the original does. U2E.C forces
  /// the ground plates to the back and, for a stretch of the animation, the
  /// ship to the front; U2A.C has no such rule.
  final int Function(int slot, VisuMesh mesh, int dist, double frame)? distOf;

  VisuRenderer(this.scene, {this.distOf}) {
    // Palette -> RGB, once. 6-bit VGA components.
    _colors = List<Color>.generate(256, (i) {
      final r = scene.palette[i * 3], g = scene.palette[i * 3 + 1];
      final b = scene.palette[i * 3 + 2];
      return Color.fromARGB(255, r * 255 ~/ 63, g * 255 ~/ 63, b * 255 ~/ 63);
    });
  }

  late final List<Color> _colors;

  int get frameCount => scene.frames.length;

  // --- the original's projection constants -----------------------------------
  // U2A.C:247 / U2E.C  vid_window(0, 319, 25, 174, 512, 9999999)
  static const int _clipXMin = 0, _clipXMax = 319;
  static const int _clipYMin = 25, _clipYMax = 174;
  static const int _clipZMin = 512;
  static const int _addX = (_clipXMin + _clipXMax) >> 1; // 159
  static const int _addY = (_clipYMin + _clipYMax) >> 1; // 99
  static const int _projAspect = 225; // AVIDM1.ASM — the VGA pixel is not square

  // ADRAW.ASM:20 `newlight` — a FIXED light in camera space (magnitude = UNIT).
  static const int _lightX = 12118, _lightY = 10603, _lightZ = 3030;

  static const int _f2Side = 0x200;
  static const int _fShade32 = 0xC00;
  static const int _fGouraud = 0x1000;

  /// AVID.ASM:vid_cameraangle — FOV (65536 == 360 deg) to the projection scales.
  static (double, double) _cameraAngle(double fov) {
    const halfWidth = _clipXMax - _addX; // 160
    var ha = fov / 2;
    if (ha < 512) ha = 512;
    if (ha > 16383) ha = 16383;
    // The table is sampled at even indices; interpolate between them so a FOV
    // that drifts across an entry does not step.
    final x = ha / 64.0; // (ha >> 5) & ~1, in table steps of 2
    final i0 = x.floor().clamp(0, 127), i1 = (i0 + 1).clamp(0, 127);
    final t = (x - i0).clamp(0.0, 1.0);
    final tan = _avistan[i0 * 2] * (1 - t) + _avistan[i1 * 2] * t;
    final mulX = halfWidth * tan / 256.0;
    return (mulX, mulX * _projAspect / 256.0);
  }

  /// Sample the animation at a FRACTIONAL frame.
  ///
  /// The stream stores one absolute transform per frame (the original stepped it
  /// once per retrace, or — in U2E — once per two retraces), so replaying it
  /// verbatim quantises all motion to that grid. We interpolate between the two
  /// bracketing frames instead: at every integer frame the pose is still exactly
  /// what the stream says, but in between the camera and the objects move
  /// continuously, which is what makes the fly-through smooth on a 60/120 Hz
  /// display.
  ///
  /// Interpolating the matrices element-wise is safe here (and is what keeps
  /// rotation AND scale together, which the stream stores as one matrix): the
  /// per-frame deltas are small, so the result stays orthogonal to within a
  /// fraction of a percent. A large jump — an object being repositioned as it is
  /// switched on, or a camera cut — is NOT interpolated: it snaps, exactly as
  /// the original did.
  VisuFrame sample(double f) {
    final n = scene.frames.length;
    if (n == 0) throw StateError('empty scene');
    if (f <= 0) return scene.frames[0];
    if (f >= n - 1) return scene.frames[n - 1];
    final i0 = f.floor();
    final t = f - i0;
    if (t < 1e-4) return scene.frames[i0];
    final a = scene.frames[i0], b = scene.frames[i0 + 1];

    final count = scene.objectCount;
    final mats = Int32List(count * 9);
    final pos = Int32List(count * 3);
    final on = Uint8List(count);
    for (var o = 0; o < count; o++) {
      on[o] = a.on[o];
      // An object whose on/off state flips between the two frames is being
      // switched — its transform on the other side of the flip is not part of
      // the same motion, so do not blend across it.
      var blend = a.on[o] == b.on[o] || o == 0;
      if (blend) {
        // A cut: any matrix element moving by more than a quarter of UNIT in one
        // frame is not a rotation step, it is a jump. Snap.
        for (var k = 0; k < 9; k++) {
          if ((b.mats[o * 9 + k] - a.mats[o * 9 + k]).abs() >
              VisuScene.unit ~/ 4) {
            blend = false;
            break;
          }
        }
      }
      for (var k = 0; k < 9; k++) {
        final m0 = a.mats[o * 9 + k];
        mats[o * 9 + k] =
            blend ? (m0 + (b.mats[o * 9 + k] - m0) * t).round() : m0;
      }
      for (var k = 0; k < 3; k++) {
        final p0 = a.pos[o * 3 + k];
        pos[o * 3 + k] =
            blend ? (p0 + (b.pos[o * 3 + k] - p0) * t).round() : p0;
      }
    }
    final fov = (a.fov + (b.fov - a.fov) * t).round();
    return VisuFrame(fov, on, mats, pos);
  }

  /// How long an object takes to fade in or out when the stream switches it,
  /// in stream frames. 0 = the original's hard pop.
  ///
  /// The stream's per-object on/off flags are the shot's own visibility list —
  /// hand-authored, and NOT a distance cull: the camera flies straight through
  /// several of the buildings, and they are switched off so it can. (Forcing
  /// every static object on fills the lens with the wall the camera is inside;
  /// replacing the list with a real distance cull strips the scene bare. Both
  /// were tried against the capture.) So we keep the list exactly, and only
  /// soften the moment it flips: an object being switched on ramps up over these
  /// frames instead of appearing between two frames.
  static const int fadeFrames = 8; // 0.23s at the stream's 35 fps

  /// The alpha an object is drawn with at frame [i], from how close [i] is to a
  /// switch in the stream's own on/off list.
  double _switchAlpha(int oi, int i) {
    if (fadeFrames <= 0) return 1;
    final frames = scene.frames;
    // Fading IN: how many frames has it been on?
    var on = 0;
    for (var k = 1; k <= fadeFrames; k++) {
      final j = i - k;
      if (j < 0) break;
      if (frames[j].on[oi] == 0) break;
      on = k;
    }
    // Fading OUT: how many frames until it goes off?
    var left = fadeFrames;
    for (var k = 1; k <= fadeFrames; k++) {
      final j = i + k;
      if (j >= frames.length) break;
      if (frames[j].on[oi] == 0) {
        left = k - 1;
        break;
      }
    }
    final a = (on < left ? on : left) / fadeFrames;
    return a.clamp(0.0, 1.0);
  }

  /// Render the scene at (fractional) animation frame [f] into the 4:3 [size].
  ///
  /// The original draws into a 320x200 field and confines the scene to rows
  /// 25..174, so we scale that field to the viewport rather than reprojecting.
  void paint(Canvas canvas, Size size, double f) {
    if (f < 0 || f >= scene.frames.length) return;
    final fr = sample(f);
    final (mulX, mulY) = _cameraAngle(fr.fov.toDouble());

    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / 320.0, size.height / 200.0);

    // co[0] is the camera. Apply it to every switched-on object and z-sort them
    // by the object's centre vertex, farthest first.
    final draws = <_Draw>[];
    for (var oi = 1; oi < scene.objectCount; oi++) {
      if (fr.on[oi] == 0) continue;
      final mi = scene.objectMesh[oi];
      if (mi < 0) continue;
      final mesh = scene.meshes[mi];
      final r = _applyCamera(fr, oi);
      // calc_singlez on the centre vertex — the z row only.
      final cv = mesh.center * 3;
      var dist = _sar(
              r.m[6] * mesh.verts[cv] +
                  r.m[7] * mesh.verts[cv + 1] +
                  r.m[8] * mesh.verts[cv + 2],
              VisuScene.unitShr) +
          r.z;
      if (distOf != null) dist = distOf!(oi, mesh, dist, f);
      final alpha = _switchAlpha(oi, f.round().clamp(0, frameCount - 1));
      if (alpha <= 0) continue;
      draws.add(_Draw(mesh, r, dist, alpha));
    }
    draws.sort((a, b) => b.dist.compareTo(a.dist)); // far first

    for (final d in draws) {
      _drawObject(canvas, d.mesh, d.r, mulX, mulY, d.alpha);
    }
    canvas.restore();
  }

  /// ACALC.ASM:calc_applyrmatrix — `r := camera o objectMatrix`.
  _RMatrix _applyCamera(VisuFrame fr, int oi) {
    final cm = fr.mats, cp = fr.pos;
    final m = Int32List(9);
    // (cam.m * obj.m) >> 14, row-major.
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        m[row * 3 + col] = _sar(
            cm[row * 3 + 0] * cm[9 * oi + 0 * 3 + col] +
                cm[row * 3 + 1] * cm[9 * oi + 1 * 3 + col] +
                cm[row * 3 + 2] * cm[9 * oi + 2 * 3 + col],
            VisuScene.unitShr);
      }
    }
    // The object's position is rotated by the CAMERA's matrix, then the
    // camera's own translation is added.
    final ox = cp[oi * 3], oy = cp[oi * 3 + 1], oz = cp[oi * 3 + 2];
    final x =
        _sar(cm[0] * ox + cm[1] * oy + cm[2] * oz, VisuScene.unitShr) + cp[0];
    final y =
        _sar(cm[3] * ox + cm[4] * oy + cm[5] * oz, VisuScene.unitShr) + cp[1];
    final z =
        _sar(cm[6] * ox + cm[7] * oy + cm[8] * oz, VisuScene.unitShr) + cp[2];
    return _RMatrix(m, x, y, z);
  }

  void _drawObject(Canvas canvas, VisuMesh mesh, _RMatrix r, double mulX,
      double mulY, double alpha) {
    final n = mesh.vertexCount;
    // calc_rotate: camera-space vertices.
    final vz = Int32List(n);
    final sx = Float32List(n), sy = Float32List(n);
    final cxv = Int32List(n), cyv = Int32List(n), czv = Int32List(n);
    for (var i = 0; i < n; i++) {
      final x = mesh.verts[i * 3],
          y = mesh.verts[i * 3 + 1],
          z = mesh.verts[i * 3 + 2];
      final vx =
          _sar(r.m[0] * x + r.m[1] * y + r.m[2] * z, VisuScene.unitShr) + r.x;
      final vy =
          _sar(r.m[3] * x + r.m[4] * y + r.m[5] * z, VisuScene.unitShr) + r.y;
      final vzz =
          _sar(r.m[6] * x + r.m[7] * y + r.m[8] * z, VisuScene.unitShr) + r.z;
      cxv[i] = vx;
      cyv[i] = vy;
      czv[i] = vzz;
      vz[i] = vzz;
      // calc_project — the original does NOT clip geometry to the near plane,
      // it only clamps the z used for the divide.
      final zz = vzz < _clipZMin ? _clipZMin : vzz;
      sx[i] = vx * mulX / zz + _addX;
      sy[i] = vy * mulY / zz + _addY;
    }
    // calc_nrotate: camera-space normals (rotation only, no translation).
    final nn = mesh.normals.length ~/ 3;
    final nx = Int32List(nn), ny = Int32List(nn), nz = Int32List(nn);
    for (var i = 0; i < nn; i++) {
      final a = mesh.normals[i * 3],
          b = mesh.normals[i * 3 + 1],
          c = mesh.normals[i * 3 + 2];
      nx[i] = _sar(r.m[0] * a + r.m[1] * b + r.m[2] * c, VisuScene.unitShr);
      ny[i] = _sar(r.m[3] * a + r.m[4] * b + r.m[5] * c, VisuScene.unitShr);
      nz[i] = _sar(r.m[6] * a + r.m[7] * b + r.m[8] * c, VisuScene.unitShr);
    }

    // vis_drawobject: of the eight direction-sorted polygon lists, take the one
    // whose reference vertex is nearest the camera. That list IS the painter's
    // order — the original precomputed it so it never has to sort at runtime.
    List<int> order = const [];
    var best = 0x7fffffff;
    for (final od in mesh.orders) {
      final z = vz[od.ref];
      if (z < best) {
        best = z;
        order = od.polys;
      }
    }
    if (order.isEmpty) {
      order = List<int>.generate(mesh.polys.length, (i) => i);
    }

    final paint = Paint()..style = PaintingStyle.fill;
    for (final pi in order) {
      final poly = mesh.polys[pi];
      // ADRAW.ASM:466-470 — the object's flags (F_DEFAULT) OR 0x0F00, ANDed
      // with the face's own flag byte shifted into bits 8..15.
      final flags = (0xf001 | 0x0F00) & (poly.flags << 8);
      final fn = poly.normal;
      final v0 = poly.verts[0];

      if ((flags & _f2Side) == 0) {
        // Backface: dot(face normal, one of its vertices) >= 0 in camera space.
        final dot = nx[fn] * cxv[v0] + ny[fn] * cyv[v0] + nz[fn] * czv[v0];
        if (dot >= 0) continue;
      }

      if ((flags & _fGouraud) != 0) {
        // Gouraud: the original shades each vertex from ITS OWN normal (the
        // extra normals nnum1..nnum) and interpolates the palette index across
        // the face. We interpolate the ramp's colours instead — same ramp, same
        // shades, smooth instead of banded.
        _drawGouraud(canvas, mesh, poly, flags, sx, sy, nx, ny, nz, alpha);
      } else {
        final path = Path();
        for (var k = 0; k < poly.verts.length; k++) {
          final v = poly.verts[k];
          if (k == 0) {
            path.moveTo(sx[v], sy[v]);
          } else {
            path.lineTo(sx[v], sy[v]);
          }
        }
        path.close();
        final shade = _shade(flags, nx[fn], ny[fn], nz[fn]);
        final c = _colors[(poly.color + shade) & 0xff];
        paint.color = alpha >= 1 ? c : c.withValues(alpha: alpha);
        canvas.drawPath(path, paint);
      }
    }
  }

  /// Per-vertex shading, drawn as an interpolated triangle fan.
  void _drawGouraud(Canvas canvas, VisuMesh mesh, VisuPoly poly, int flags,
      Float32List sx, Float32List sy, Int32List nx, Int32List ny, Int32List nz,
      double alpha) {
    final n = poly.verts.length;
    final cols = List<Color>.generate(n, (k) {
      // ADRAW.ASM's gouraud path shades each vertex from the vertex's OWN
      // normal (vlist.normal — the extra normals nnum1..nnum), not the face's.
      final vn = mesh.vertNormals[poly.verts[k]];
      final s = _shade(flags, nx[vn], ny[vn], nz[vn]);
      final c = _colors[(poly.color + s) & 0xff];
      return alpha >= 1 ? c : c.withValues(alpha: alpha);
    });
    // Triangle fan with per-vertex colours.
    final verts = <Offset>[];
    final vcols = <Color>[];
    for (var k = 1; k < n - 1; k++) {
      verts.add(Offset(sx[poly.verts[0]], sy[poly.verts[0]]));
      verts.add(Offset(sx[poly.verts[k]], sy[poly.verts[k]]));
      verts.add(Offset(sx[poly.verts[k + 1]], sy[poly.verts[k + 1]]));
      vcols.add(cols[0]);
      vcols.add(cols[k]);
      vcols.add(cols[k + 1]);
    }
    if (verts.isEmpty) return;
    // BlendMode.dst takes the vertex colours as-is; alpha has to ride on the
    // Paint for the fade to composite against what is already drawn.
    canvas.drawVertices(
      Vertices(VertexMode.triangles, verts, colors: vcols),
      alpha >= 1 ? BlendMode.dst : BlendMode.srcOver,
      Paint(),
    );
  }

  /// ADRAW.ASM: normallight + calclight.
  static int _shade(int flags, int nx, int ny, int nz) {
    final dot = nx * _lightX + ny * _lightY + nz * _lightZ;
    var bright = _sar(dot, 21) + 128;
    if (bright < 0) bright = 0;
    if (bright > 255) bright = 255;
    final mask = flags & _fShade32;
    if (mask == 0) return 1;
    // SHADE8 -> >>5 (0..7), SHADE16 -> >>4 (0..15), SHADE32 -> >>3 (0..31),
    // then clamped to 1..30.
    var s = bright >> (6 - (mask >> 10));
    if (s < 1) s = 1;
    if (s > 30) s = 30;
    return s;
  }

  /// Arithmetic shift right. dart2js does bitwise ops on UNSIGNED 32-bit ints,
  /// so `>>` on a negative value is wrong on web (it works in the VM). Every
  /// shift here can see a negative dot product, so all of them go through this.
  static int _sar(int v, int n) => (v / (1 << n)).floor();
}

class _RMatrix {
  final Int32List m;
  final int x, y, z;
  _RMatrix(this.m, this.x, this.y, this.z);
}

class _Draw {
  final VisuMesh mesh;
  final _RMatrix r;
  final int dist;

  /// 0..1 while the stream is switching this object on or off.
  final double alpha;
  _Draw(this.mesh, this.r, this.dist, this.alpha);
}

/// AVID.ASM `_avistan` (AVISTAN.INC): "Visual angle tangent table
/// (256 words = 90 degrees)" — a cotangent-shaped LUT scaled by 256.
/// vid_cameraangle indexes it with (halfAngle >> 5) & ~1 and renormalises >> 8.
const List<int> _avistan = <int>[
  32767, 32767, 20859, 13905, 10428, 8341, 6950, 5956, 5210, 4631, 4166,
  3787, 3470, 3202, 2972, 2773, 2599, 2445, 2308, 2185, 2075, 1975, 1884,
  1801, 1725, 1655, 1591, 1531, 1475, 1423, 1374, 1329, 1286, 1246, 1209,
  1173, 1140, 1108, 1077, 1049, 1022, 996, 971, 947, 925, 903, 882, 862,
  843, 825, 808, 791, 774, 759, 744, 729, 715, 701, 688, 675, 663, 651, 640,
  628, 618, 607, 597, 587, 577, 568, 558, 549, 541, 532, 524, 516, 508, 500,
  493, 486, 478, 471, 465, 458, 451, 445, 439, 433, 427, 421, 415, 409, 404,
  398, 393, 388, 383, 378, 373, 368, 363, 358, 354, 349, 345, 340, 336, 332,
  328, 323, 319, 315, 311, 308, 304, 300, 296, 293, 289, 285, 282, 278, 275,
  272, 268, 265, 262, 259, 256, 252, 249, 246, 243, 240, 237, 234, 232, 229,
  226, 223, 220, 218, 215, 212, 210, 207, 204, 202, 199, 197, 194, 192, 189,
  187, 185, 182, 180, 177, 175, 173, 171, 168, 166, 164, 162, 159, 157, 155,
  153, 151, 149, 147, 145, 142, 140, 138, 136, 134, 132, 130, 128, 126, 124,
  123, 121, 119, 117, 115, 113, 111, 109, 107, 106, 104, 102, 100, 98, 96,
  95, 93, 91, 89, 88, 86, 84, 82, 81, 79, 77, 75, 74, 72, 70, 69, 67, 65,
  64, 62, 60, 59, 57, 55, 54, 52, 50, 49, 47, 46, 44, 42, 41, 39, 37, 36,
  34, 33, 31, 29, 28, 26, 25, 23, 22, 20, 18, 17, 15, 14, 12, 11, 9, 7, 6,
  4, 3, 1
];
