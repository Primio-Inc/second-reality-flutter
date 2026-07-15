import 'dart:typed_data';

/// The FOREST part's precomputed data (assets/tables/forest.srt, built by
/// tool/convert_forest.py from FOREST/O2.SCI and FOREST/POS1-3.DAT).
///
/// The part never projects anything at runtime: FOREST/ROUTINES.ASM's
/// `Putrouts` walks a flat list of font cells and, for each, a list of screen
/// offsets it lights up —
///
///     screen[offset] = background[offset] + fontCell
///
/// so the scroll text is a per-pixel BRIGHTENING of the background picture, and
/// a cell hidden behind a leaf is simply not in the list. The 3D warp of the
/// text across the hillside and the leaf occlusion are both baked into these
/// offsets; there is no mask and no depth test.
///
/// Three tables (POS1/2/3) are cycled one per frame, each drawing roughly a
/// third of the projected pixels, so a full refresh takes three frames — which
/// is also the rate at which the text scrolls (one column per three frames).
///
///     "FRS1"
///     u16 stripW (640), u16 stripH (31)
///     stripW*stripH bytes            -- the O2.SCI text strip, +128 applied
///     3x { u32 total, 7347 x u16 counts, total x u16 offsets }
class ForestTables {
  /// Font cells: the scroll window is 237 columns x 31 rows.
  static const int cols = 237;
  static const int rows = 31;
  static const int cells = cols * rows; // 7347

  /// The scroll text, [stripW] x [stripH], already carrying READ2.PAS's
  /// `if fbuf[x] > 0 then inc(fbuf[x],128)` — every set pixel indexes into the
  /// palette's upper bank, which is what the second fade brings up.
  final int stripW;
  final int stripH;
  final Uint8List strip;

  /// Per table, per cell: how many screen offsets that cell lights.
  final List<Uint16List> counts;

  /// Per table: every screen offset, concatenated in cell order. Cell `c` of
  /// table `p` owns `counts[p][c]` entries starting at `starts[p][c]`.
  final List<Uint16List> offsets;

  /// Prefix sums of [counts], so a cell's offsets can be found without a scan.
  final List<Int32List> starts;

  ForestTables._(this.stripW, this.stripH, this.strip, this.counts,
      this.offsets, this.starts);

  static ForestTables decode(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes[0] != 0x46 ||
        bytes[1] != 0x52 ||
        bytes[2] != 0x53 ||
        bytes[3] != 0x31) {
      throw const FormatException('not an FRS1 forest table');
    }
    final stripW = d.getUint16(4, Endian.little);
    final stripH = d.getUint16(6, Endian.little);
    var o = 8;
    final strip = Uint8List.sublistView(bytes, o, o + stripW * stripH);
    o += stripW * stripH;

    final counts = <Uint16List>[];
    final offsets = <Uint16List>[];
    final starts = <Int32List>[];
    for (var p = 0; p < 3; p++) {
      final total = d.getUint32(o, Endian.little);
      o += 4;
      final c = Uint16List(cells);
      final s = Int32List(cells);
      var acc = 0;
      for (var i = 0; i < cells; i++) {
        c[i] = d.getUint16(o + i * 2, Endian.little);
        s[i] = acc;
        acc += c[i];
      }
      o += cells * 2;
      if (acc != total) {
        throw FormatException('forest table $p: counts sum $acc != $total');
      }
      final off = Uint16List(total);
      for (var i = 0; i < total; i++) {
        off[i] = d.getUint16(o + i * 2, Endian.little);
      }
      o += total * 2;
      counts.add(c);
      offsets.add(off);
      starts.add(s);
    }
    return ForestTables._(stripW, stripH, strip, counts, offsets, starts);
  }
}
