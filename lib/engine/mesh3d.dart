import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// A 3D triangle mesh loaded from the .svm asset produced by
/// tool/extract_mesh.py (originally Autodesk 3DS data from the demo, e.g.
/// 3DS/PXLSHIP.3DS). Vertices are centred on their bounding box and scaled so
/// the model's max half-extent is 1, so callers control on-screen size.
class Mesh3D {
  final Float32List verts; // xyz interleaved, centred + normalised
  final Uint32List faces; // triangle vertex indices (3 per face)

  Mesh3D(this.verts, this.faces);

  int get faceCount => faces.length ~/ 3;

  /// Build from an inline xyz vertex list (e.g. transcribed source data),
  /// centred and normalised; faces are supplied separately by the caller.
  factory Mesh3D.fromRaw(List<double> verts) =>
      Mesh3D._normalised(Float32List.fromList(verts), Uint32List(0));

  /// Decode "SVM1" | u16 meshCount | per mesh: u8 nameLen, name, u32 vCount,
  /// u32 fCount, verts(3×f32), faces(3×u32). All sub-meshes are merged.
  /// When [normalize] is false the original model-space coordinates are kept
  /// (needed when the caller drives the mesh with the original scene's
  /// keyframe positions/scales, which live in that same model space).
  static Mesh3D decode(Uint8List bytes, {bool normalize = true}) {
    if (bytes.length < 6 ||
        bytes[0] != 0x53 || bytes[1] != 0x56 || bytes[2] != 0x4D ||
        bytes[3] != 0x31) {
      throw const FormatException('not an SVM1 mesh');
    }
    final d = ByteData.sublistView(bytes);
    final meshCount = d.getUint16(4, Endian.little);
    final vs = <double>[];
    final fs = <int>[];
    var o = 6;
    for (var m = 0; m < meshCount; m++) {
      final nameLen = d.getUint8(o);
      o += 1 + nameLen;
      final vCount = d.getUint32(o, Endian.little);
      final fCount = d.getUint32(o + 4, Endian.little);
      o += 8;
      final base = vs.length ~/ 3;
      for (var i = 0; i < vCount * 3; i++) {
        vs.add(d.getFloat32(o + i * 4, Endian.little));
      }
      o += vCount * 12;
      for (var i = 0; i < fCount; i++) {
        fs.add(base + d.getUint32(o + i * 12, Endian.little));
        fs.add(base + d.getUint32(o + i * 12 + 4, Endian.little));
        fs.add(base + d.getUint32(o + i * 12 + 8, Endian.little));
      }
      o += fCount * 12;
    }
    final v = Float32List.fromList(vs);
    final f = Uint32List.fromList(fs);
    return normalize ? Mesh3D._normalised(v, f) : Mesh3D(v, f);
  }

  factory Mesh3D._normalised(Float32List v, Uint32List f) {
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity,
        maxZ = -double.infinity;
    for (var i = 0; i < v.length; i += 3) {
      minX = math.min(minX, v[i]);
      maxX = math.max(maxX, v[i]);
      minY = math.min(minY, v[i + 1]);
      maxY = math.max(maxY, v[i + 1]);
      minZ = math.min(minZ, v[i + 2]);
      maxZ = math.max(maxZ, v[i + 2]);
    }
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2, cz = (minZ + maxZ) / 2;
    final half = [
      (maxX - minX) / 2,
      (maxY - minY) / 2,
      (maxZ - minZ) / 2
    ].reduce(math.max);
    final s = half == 0 ? 1.0 : 1.0 / half;
    for (var i = 0; i < v.length; i += 3) {
      v[i] = (v[i] - cx) * s;
      v[i + 1] = (v[i + 1] - cy) * s;
      v[i + 2] = (v[i + 2] - cz) * s;
    }
    return Mesh3D(v, f);
  }
}

/// A 3x3 rotation applied as Z(roll) then X(pitch) then Y(yaw), matching the
/// order used across the port's 3D parts.
class Rot3 {
  final double cr, sr, cp, sp, cy, sy;
  Rot3(double roll, double pitch, double yaw)
      : cr = math.cos(roll),
        sr = math.sin(roll),
        cp = math.cos(pitch),
        sp = math.sin(pitch),
        cy = math.cos(yaw),
        sy = math.sin(yaw);

  List<double> apply(double x, double y, double z) {
    final rx = x * cr - y * sr, ry = x * sr + y * cr;
    x = rx;
    y = ry;
    final py = y * cp - z * sp, pz = y * sp + z * cp;
    y = py;
    z = pz;
    final yx = x * cy + z * sy, yz = -x * sy + z * cy;
    return [yx, y, yz];
  }
}

/// Renders [mesh] with a perspective camera at the origin looking down +Z:
/// each vertex is rotated by [rot], scaled by [scale], translated to world
/// ([wx],[wy],[wz]), projected, then faces are painter-sorted and flat-shaded
/// from [shade] (a function of the 0..1 lambert term) toward the screen.
void paintMesh(
  Canvas canvas,
  Size size,
  Mesh3D mesh, {
  required Rot3 rot,
  required double scale,
  required double wx,
  required double wy,
  required double wz,
  required double focal, // in units of min(size.w,size.h)
  double sx = 1, // per-axis (squash) scale, applied before rotation
  double sy = 1,
  double sz = 1,
  double cxFrac = 0.5,
  double cyFrac = 0.5,
  List<double> light = const [0.35, 0.6, 0.72],
  required Color Function(double lambert) color,
  bool wireframe = false,
}) {
  final v = mesh.verts;
  final n = v.length ~/ 3;
  final px = Float32List(n);
  final py = Float32List(n);
  final pz = Float32List(n);
  final cx = size.width * cxFrac;
  final cy = size.height * cyFrac;
  final f = math.min(size.width, size.height) * focal;
  // light normalised
  var lx = light[0], ly = light[1], lz = light[2];
  final ll = math.sqrt(lx * lx + ly * ly + lz * lz);
  lx /= ll;
  ly /= ll;
  lz /= ll;

  for (var i = 0; i < n; i++) {
    final r = rot.apply(v[i * 3] * scale * sx, v[i * 3 + 1] * scale * sy,
        v[i * 3 + 2] * scale * sz);
    final x = r[0] + wx, y = r[1] + wy, z = r[2] + wz;
    pz[i] = z;
    if (z > 0.001) {
      px[i] = cx + f * x / z;
      py[i] = cy - f * y / z;
    } else {
      px[i] = -10000;
      py[i] = -10000;
    }
  }

  final faces = mesh.faces;
  final fc = mesh.faceCount;
  final order = List.generate(fc, (i) => i);
  order.sort((a, b) {
    final za = pz[faces[a * 3]] + pz[faces[a * 3 + 1]] + pz[faces[a * 3 + 2]];
    final zb = pz[faces[b * 3]] + pz[faces[b * 3 + 1]] + pz[faces[b * 3 + 2]];
    return zb.compareTo(za); // far first
  });

  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8;
  for (final fi in order) {
    final a = faces[fi * 3], b = faces[fi * 3 + 1], c = faces[fi * 3 + 2];
    if (pz[a] <= 0.001 || pz[b] <= 0.001 || pz[c] <= 0.001) continue;
    // rotated (view-space) normal for lighting
    final ra = rot.apply(v[a * 3], v[a * 3 + 1], v[a * 3 + 2]);
    final rb = rot.apply(v[b * 3], v[b * 3 + 1], v[b * 3 + 2]);
    final rc = rot.apply(v[c * 3], v[c * 3 + 1], v[c * 3 + 2]);
    final ux = rb[0] - ra[0], uy = rb[1] - ra[1], uz = rb[2] - ra[2];
    final vx = rc[0] - ra[0], vy = rc[1] - ra[1], vz = rc[2] - ra[2];
    var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx;
    final nl = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nl > 0) {
      nx /= nl;
      ny /= nl;
      nz /= nl;
    }
    final lambert = (nx * lx + ny * ly + nz * lz).abs().clamp(0.0, 1.0);
    final path = Path()
      ..moveTo(px[a], py[a])
      ..lineTo(px[b], py[b])
      ..lineTo(px[c], py[c])
      ..close();
    final col = color(lambert);
    canvas.drawPath(path, Paint()..color = col);
    if (wireframe) canvas.drawPath(path, stroke..color = col);
  }
}
