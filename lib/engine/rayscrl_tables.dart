import 'dart:typed_data';

/// The RAYSCRL part's precomputed data (assets/tables/rayscrl.srt, built by
/// tool/convert_rayscrl.py from WATER/MIEKKA.SCI and WATER/WAT1-3.DAT).
///
/// Like FOREST, this part projects nothing at runtime. WATER/ROUTINES.ASM's
/// `Putrouts1` walks a flat list of scroll cells and, for each, the list of
/// screen offsets that cell covers —
///
///     al = font[cell]; if (al == 0) al = background[offset];
///     screen[offset] = al
///
/// — so unlike FOREST's additive leaves, the text here is OPAQUE: a non-zero
/// cell paints its own colour, and a zero cell repaints the background.
///
/// The offsets themselves are a raytraced UV map. WATER/DATGEN.PAS rendered the
/// water surface with POV-ray and read the scroll cell's COLUMN out of the RED
/// channel and its ROW out of a fixed GREEN mask, so the ripple distortion, the
/// perspective and the occlusion behind the mirror balls are all baked in.
///
/// DATGEN only emitted a pixel where the mapping CHANGED between the two frames
/// it was given, so each of the three tables is the INCREMENTAL update for one
/// phase of the water's 3-frame ripple cycle, painted on top of the background
/// picture that was blitted once at the start. That is why they are cycled one
/// per frame, and why the text appears to swim on the water.
///
///     "RAY1"
///     u16 stripW (400), u16 stripH (34)
///     stripW*stripH bytes            -- the MIEKKA.SCI text strip
///     3x { u32 total, 5372 x u16 counts, total x u16 offsets }
class RayscrlTables {
  /// The scroll window: 158 cells across, 34 down. DATGEN.PAS emits them as
  /// `for y := 34 downto 1 do for tt := 1 to 158 do`, and Putrouts1 walks the
  /// file in that order with one font byte per cell — so cell index IS the
  /// index into the part's scroll buffer.
  static const int cols = 158;
  static const int rows = 34;
  static const int cells = cols * rows; // 5372

  final int stripW;
  final int stripH;

  /// The scroll text, [stripW] x [stripH], as opaque colour indices.
  final Uint8List strip;

  /// Per table, per cell: how many screen offsets that cell paints.
  final List<Uint16List> counts;

  /// Per table: the offsets themselves, cell after cell (use [counts] to walk).
  final List<Uint16List> offsets;

  RayscrlTables._(
      this.stripW, this.stripH, this.strip, this.counts, this.offsets);

  static RayscrlTables decode(Uint8List bytes) {
    if (bytes[0] != 0x52 ||
        bytes[1] != 0x41 ||
        bytes[2] != 0x59 ||
        bytes[3] != 0x31) {
      throw const FormatException('not a RAY1 table');
    }
    final d = ByteData.sublistView(bytes);
    final stripW = d.getUint16(4, Endian.little);
    final stripH = d.getUint16(6, Endian.little);
    var o = 8;
    final strip = Uint8List.sublistView(bytes, o, o + stripW * stripH);
    o += stripW * stripH;

    final counts = <Uint16List>[];
    final offsets = <Uint16List>[];
    for (var t = 0; t < 3; t++) {
      final total = d.getUint32(o, Endian.little);
      o += 4;
      final c = Uint16List(cells);
      for (var i = 0; i < cells; i++) {
        c[i] = d.getUint16(o + i * 2, Endian.little);
      }
      o += cells * 2;
      final f = Uint16List(total);
      for (var i = 0; i < total; i++) {
        f[i] = d.getUint16(o + i * 2, Endian.little);
      }
      o += total * 2;
      counts.add(c);
      offsets.add(f);
    }
    return RayscrlTables._(stripW, stripH, strip, counts, offsets);
  }
}
