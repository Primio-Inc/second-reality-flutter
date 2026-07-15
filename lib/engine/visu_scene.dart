import 'dart:typed_data';

/// A compiled VISU scene — the RUNTIME data the original demo actually played.
///
/// Sami Tammilehto's VISU engine (original/VISU) does not evaluate 3D Studio
/// keyframes at runtime. Its scene compiler bakes the whole shot into:
///
///  * one object file per mesh — vertices in OBJECT space, per-face colour,
///    per-face + per-vertex normals (`U2A.001/.002/.003`), and
///  * a delta-compressed animation stream (`U2A.0AB`) that, for every frame,
///    carries each object's full 3x3 matrix (rotation AND scale together), its
///    position, whether it is switched on, and the camera FOV.
///
/// So a frame is just `world = M * v + t` — there is no pivot to subtract, no
/// keyframe to interpolate and no separate scale track to re-apply. (Replaying
/// the `.PRJ` instead means reconstructing all of that by hand, and the mesh's
/// baked world-space placement makes it easy to apply the scale twice — which
/// is what flattened our mothership into a plate.)
///
/// Everything is fixed point with UNIT = 16384 (VISU/C.H).
///
/// Decoded from `.srv`, built by tool/extract_visu.py.
class VisuScene {
  /// Fixed-point unit: 16384 == 1.0 (VISU/C.H `UNIT`).
  static const int unit = 16384;
  static const int unitShr = 14;

  /// The 6-bit VGA palette from the scene's `.00M`. Entries 0..191 are the
  /// scene's own; 192..255 are overwritten at runtime by the background
  /// picture's palette (U2A.C), so objects only ever use 0..191.
  final Uint8List palette;

  final List<VisuMesh> meshes;

  /// One entry per `co[]` slot. `co[0]` is the camera (mesh index -1); the rest
  /// index into [meshes] — several slots can share a mesh (U2A has three `s01`
  /// escorts pointing at the same object file).
  final Int8List objectMesh;

  final List<VisuFrame> frames;

  VisuScene(this.palette, this.meshes, this.objectMesh, this.frames);

  int get objectCount => objectMesh.length;

  static VisuScene decode(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes[0] != 0x53 ||
        bytes[1] != 0x52 ||
        bytes[2] != 0x56 ||
        bytes[3] != 0x31) {
      throw const FormatException('not an SRV1 scene');
    }
    var p = 4;
    final objCount = d.getUint8(p++);
    final meshCount = d.getUint8(p++);
    final objMesh = Int8List(objCount);
    for (var i = 0; i < objCount; i++) {
      final v = d.getUint8(p++);
      objMesh[i] = v == 255 ? -1 : v; // 255 = the camera slot
    }
    final pal = Uint8List.sublistView(bytes, p, p + 768);
    p += 768;

    final meshes = <VisuMesh>[];
    for (var m = 0; m < meshCount; m++) {
      final nameLen = d.getUint8(p++);
      final name = String.fromCharCodes(bytes, p, p + nameLen)
          .replaceAll('"', ''); // the NAME chunk keeps 3DS's quotes
      p += nameLen;

      final vertCount = d.getUint16(p, Endian.little);
      p += 2;
      final verts = Int32List(vertCount * 3);
      for (var i = 0; i < vertCount * 3; i++) {
        verts[i] = d.getInt32(p, Endian.little);
        p += 4;
      }
      // Each vertex names its own normal (vlist.normal) — the gouraud normals.
      final vertNormals = Uint16List(vertCount);
      for (var i = 0; i < vertCount; i++) {
        vertNormals[i] = d.getUint16(p, Endian.little);
        p += 2;
      }

      final normCount = d.getUint16(p, Endian.little);
      final basicNorms = d.getUint16(p + 2, Endian.little);
      p += 4;
      final norms = Int16List(normCount * 3);
      for (var i = 0; i < normCount * 3; i++) {
        norms[i] = d.getInt16(p, Endian.little);
        p += 2;
      }

      final polyCount = d.getUint16(p, Endian.little);
      p += 2;
      final polys = <VisuPoly>[];
      for (var i = 0; i < polyCount; i++) {
        final sides = d.getUint8(p);
        final flags = d.getUint8(p + 1);
        final color = d.getUint8(p + 2);
        final normal = d.getUint16(p + 3, Endian.little);
        p += 5;
        final vs = Uint16List(sides);
        for (var k = 0; k < sides; k++) {
          vs[k] = d.getUint16(p, Endian.little);
          p += 2;
        }
        polys.add(VisuPoly(flags, color, normal, vs));
      }

      final center = d.getUint16(p, Endian.little);
      final orderCount = d.getUint8(p + 2);
      p += 3;
      final orders = <VisuOrder>[];
      for (var i = 0; i < orderCount; i++) {
        final ref = d.getUint16(p, Endian.little);
        final cnt = d.getUint16(p + 2, Endian.little);
        p += 4;
        final ps = List<int>.generate(cnt, (k) {
          final v = d.getUint16(p, Endian.little);
          p += 2;
          return v;
        });
        orders.add(VisuOrder(ref, ps));
      }
      meshes.add(VisuMesh(
          name, verts, vertNormals, norms, basicNorms, polys, center, orders));
    }

    final frameCount = d.getUint16(p, Endian.little);
    p += 2;
    final frames = <VisuFrame>[];
    for (var f = 0; f < frameCount; f++) {
      final fov = d.getUint16(p, Endian.little);
      p += 2;
      final on = Uint8List(objCount);
      final mats = Int32List(objCount * 9);
      final pos = Int32List(objCount * 3);
      for (var o = 0; o < objCount; o++) {
        on[o] = d.getUint8(p++);
        for (var k = 0; k < 9; k++) {
          mats[o * 9 + k] = d.getInt32(p, Endian.little);
          p += 4;
        }
        for (var k = 0; k < 3; k++) {
          pos[o * 3 + k] = d.getInt32(p, Endian.little);
          p += 4;
        }
      }
      frames.add(VisuFrame(fov, on, mats, pos));
    }
    return VisuScene(pal, meshes, objMesh, frames);
  }
}

class VisuMesh {
  final String name;

  /// Object-space vertices, integer world units, x,y,z interleaved.
  final Int32List verts;

  /// Per vertex, the index of ITS OWN normal (VISU's `vlist.normal`). The
  /// gouraud path shades a vertex from this, not from the face's normal.
  final Uint16List vertNormals;

  /// Normals, 3 * int16 each, scaled to UNIT (a unit normal has length 16384).
  /// The first [basicNormals] are the FACE normals; the rest are the per-vertex
  /// normals used for gouraud shading.
  final Int16List normals;
  final int basicNormals;

  final List<VisuPoly> polys;

  /// The object's centre vertex — the z-sort key (`calc_singlez`).
  final int center;

  /// Eight polygon draw orders, one per view octant, each already sorted back
  /// to front. `vis_drawobject` picks the list whose reference vertex is
  /// nearest the camera and draws in that order — the original never sorts
  /// polygons at runtime, it precomputed every order it could need.
  final List<VisuOrder> orders;

  VisuMesh(this.name, this.verts, this.vertNormals, this.normals,
      this.basicNormals, this.polys, this.center, this.orders);

  int get vertexCount => verts.length ~/ 3;
}

class VisuOrder {
  /// The vertex whose camera z decides whether this list is the one to use.
  final int ref;
  final List<int> polys;
  VisuOrder(this.ref, this.polys);
}

class VisuPoly {
  final int flags;

  /// Base palette index — the bottom of this face's 32-entry shade ramp. The
  /// lighting adds a shade offset to it (see VisuRenderer).
  final int color;

  /// Index into [VisuMesh.normals] of this face's normal.
  final int normal;

  final Uint16List verts;

  VisuPoly(this.flags, this.color, this.normal, this.verts);
}

/// One animation frame: every object's absolute transform, already accumulated
/// from the stream's deltas.
class VisuFrame {
  /// Camera FOV as the original's angle unit — 65536 == 360 degrees.
  final int fov;

  /// Per `co[]` slot: is the object switched on this frame?
  final Uint8List on;

  /// Per slot, 9 fixed-point matrix elements (rotation AND scale).
  final Int32List mats;

  /// Per slot, fixed-point x,y,z.
  final Int32List pos;

  VisuFrame(this.fov, this.on, this.mats, this.pos);
}
