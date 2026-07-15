import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/mesh3d.dart';

/// Encode an .svm the way tool/extract_mesh.py does.
Uint8List buildSvm(List<(String, List<double>, List<int>)> meshes) {
  final b = BytesBuilder();
  b.add('SVM1'.codeUnits);
  final cnt = ByteData(2)..setUint16(0, meshes.length, Endian.little);
  b.add(cnt.buffer.asUint8List());
  for (final (name, verts, faces) in meshes) {
    b.add([name.length]);
    b.add(name.codeUnits);
    final hdr = ByteData(8)
      ..setUint32(0, verts.length ~/ 3, Endian.little)
      ..setUint32(4, faces.length ~/ 3, Endian.little);
    b.add(hdr.buffer.asUint8List());
    for (final v in verts) {
      final f = ByteData(4)..setFloat32(0, v, Endian.little);
      b.add(f.buffer.asUint8List());
    }
    for (final i in faces) {
      final u = ByteData(4)..setUint32(0, i, Endian.little);
      b.add(u.buffer.asUint8List());
    }
  }
  return b.toBytes();
}

void main() {
  test('decodes and normalises to unit half-extent, merges meshes', () {
    // A 2x2x2 cube centred at (10,10,10): one triangle enough to check.
    final svm = buildSvm([
      ('a', [9, 9, 9, 11, 9, 9, 11, 11, 9], [0, 1, 2]),
      ('b', [11, 11, 11], []), // no faces -> still merges verts
    ]);
    final m = Mesh3D.decode(svm);
    expect(m.faceCount, 1);
    // faces from mesh 'a' keep local indices (base 0)
    expect([m.faces[0], m.faces[1], m.faces[2]], [0, 1, 2]);
    // normalised: max half-extent maps to 1.0
    var maxAbs = 0.0;
    for (final c in m.verts) {
      if (c.abs() > maxAbs) maxAbs = c.abs();
    }
    expect(maxAbs, closeTo(1.0, 1e-5));
  });

  test('rejects bad magic', () {
    expect(() => Mesh3D.decode(Uint8List(6)), throwsFormatException);
  });

  test('Rot3 identity leaves points unchanged', () {
    final r = Rot3(0, 0, 0);
    expect(r.apply(1, 2, 3), [1.0, 2.0, 3.0]);
  });
}
