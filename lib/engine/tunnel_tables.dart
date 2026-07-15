import 'dart:typed_data';

/// The dot-tunnel lookup tables (TUNNELI), bundled verbatim from the original
/// TUNNEL.DAT + SINIT.DAT — see tool/convert_tunnel.py for provenance and the
/// generator formulas both files are verified against.
///
/// Format ('SRT1'): u16 radii | u16 pts | radii*pts*{i16 x,i16 y}
///                | u16 sinLen | u16 cosLen | i16 sin[] | i16 cos[]
class TunnelTables {
  /// pcalc[r][a] — the 64 dot positions of ring radius-index r (0..137),
  /// already centred on the 320x200 screen. Laid out as x,y pairs.
  final Int16List pcalc;
  final int radii;
  final int pts;

  /// The snaking-path tables; amplitude grows with the index, so the tunnel
  /// wanders further and further as the part runs.
  final Int16List sinit; // 4097 entries, index & 4095
  final Int16List cosit; // 2049 entries, index & 2047

  TunnelTables({
    required this.pcalc,
    required this.radii,
    required this.pts,
    required this.sinit,
    required this.cosit,
  });

  static TunnelTables decode(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes[0] != 0x53 || bytes[1] != 0x52 || bytes[2] != 0x54 || bytes[3] != 0x31) {
      throw ArgumentError('not an SRT1 table file');
    }
    final radii = d.getUint16(4, Endian.little);
    final pts = d.getUint16(6, Endian.little);
    var o = 8;
    final n = radii * pts * 2;
    final pcalc = Int16List(n);
    for (var i = 0; i < n; i++) {
      pcalc[i] = d.getInt16(o + i * 2, Endian.little);
    }
    o += n * 2;
    final sinLen = d.getUint16(o, Endian.little);
    final cosLen = d.getUint16(o + 2, Endian.little);
    o += 4;
    final sinit = Int16List(sinLen);
    for (var i = 0; i < sinLen; i++) {
      sinit[i] = d.getInt16(o + i * 2, Endian.little);
    }
    o += sinLen * 2;
    final cosit = Int16List(cosLen);
    for (var i = 0; i < cosLen; i++) {
      cosit[i] = d.getInt16(o + i * 2, Endian.little);
    }
    return TunnelTables(
        pcalc: pcalc, radii: radii, pts: pts, sinit: sinit, cosit: cosit);
  }
}
