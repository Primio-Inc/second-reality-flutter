import 'dart:typed_data';

/// The 3D sinusfield's wave tables (assets/tables/sinfield.srt, built by
/// tool/convert_sinfield.py from COMAN/W1DTA.BIN and W2DTA.BIN).
///
/// The terrain is separable: `height(x, y) = wave1[x] + wave2[y]`, which is why
/// THELOOP.INC can look it up with two independent 16-bit pointers walking two
/// flat tables. MAIN.C can also generate them (`#ifdef CALCW12`), but the
/// shipped build links the precomputed data — and the generator has a rand()
/// term in it, so the shipped tables are the only faithful source.
///
///     "SNF1" + u16 count (32768) + count*i16 wave1 + count*i16 wave2
class SinFieldTables {
  final Int16List wave1;
  final Int16List wave2;

  SinFieldTables._(this.wave1, this.wave2);

  static SinFieldTables decode(Uint8List bytes) {
    if (bytes[0] != 0x53 ||
        bytes[1] != 0x4E ||
        bytes[2] != 0x46 ||
        bytes[3] != 0x31) {
      throw const FormatException('not an SNF1 table');
    }
    final d = ByteData.sublistView(bytes);
    final count = d.getUint16(4, Endian.little);
    final w1 = Int16List(count);
    final w2 = Int16List(count);
    for (var i = 0; i < count; i++) {
      w1[i] = d.getInt16(6 + i * 2, Endian.little);
      w2[i] = d.getInt16(6 + count * 2 + i * 2, Endian.little);
    }
    return SinFieldTables._(w1, w2);
  }
}
