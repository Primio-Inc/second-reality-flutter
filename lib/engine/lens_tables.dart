import 'dart:typed_data';

/// The LENS + ROTOZOOMER part's precomputed data (assets/tables/lens.srt, built
/// by tool/convert_lens.py from LENS/LENS.EX0..EX4 and LENS/LENS.EXP).
///
/// Nothing in this part is computed at runtime that the original precomputed
/// offline, and that is almost everything:
///
///  - The LENS is not a refraction shader. LENS/CALC.C ran `lenscalc` once, over
///    a hand-drawn lens shape (LENS.U), and wrote out, per row, the list of
///    screen offsets each lens pixel takes its colour FROM. ASM.ASM's
///    `dorow`/`dorow2`/`dorow3` just replay those lists against the background.
///    Four layers: the lens body (contiguous, one SOURCE offset per pixel), two
///    highlight layers ((dest, source) PAIRS), and an erase ring that copies the
///    background back and so heals the lens's trail as it moves.
///  - Both MOTION PATHS are recordings. MAIN.C is compiled with
///    `#define noSAVEPATH`, so neither the bouncing lens's physics nor the
///    rotozoomer's easing runs in the demo: both were played once with the
///    `#ifdef SAVEPATH` branches writing every frame's state to LENS.EXP, and
///    the demo replays that file. 715 lens frames, 2000 zoomer frames.
///
///     "LNS1"
///     u16 width (152), u16 height (116)
///     9 bytes                          -- three 6-bit RGB tints (palette banks)
///     4x { u16 rows(120), rows x { u32 wordIndex, u16 count },
///          u32 nwords, nwords x i16 }
///     u16 lensFrames,  lensFrames x 2 x i16   -- (x, y)
///     u16 zoomFrames,  zoomFrames x 4 x i16   -- (x, y, xa, ya)
class LensTables {
  /// The lens sprite's size, from LENS.EX0 (152 x 116).
  final int width;
  final int height;

  /// The three RGB triples MAIN.C adds to the picture's 64 colours to make
  /// palette banks 1..3 — the lens body's tint and its two highlight tints.
  final Uint8List tint;

  final List<LensLayer> layers;

  /// (x, y) per frame for the bouncing lens.
  final Int16List path1;

  /// (x, y, xa, ya) per frame for the rotozoomer: the sample origin and the
  /// rotation/scale step, already in the original's units (`xa` is
  /// `-1024*sin(angle)*scale`, which ASM.ASM shifts left 6 into 16.16 fixed).
  final Int16List path2;

  LensTables._(this.width, this.height, this.tint, this.layers, this.path1,
      this.path2);

  int get lensFrames => path1.length ~/ 2;
  int get zoomFrames => path2.length ~/ 4;

  static LensTables decode(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes[0] != 0x4C ||
        bytes[1] != 0x4E ||
        bytes[2] != 0x53 ||
        bytes[3] != 0x31) {
      throw const FormatException('not an LNS1 lens table');
    }
    var o = 4;
    final width = d.getUint16(o, Endian.little);
    final height = d.getUint16(o + 2, Endian.little);
    o += 4;
    final tint = Uint8List.fromList(bytes.sublist(o, o + 9));
    o += 9;

    final layers = <LensLayer>[];
    for (var l = 0; l < 4; l++) {
      final rows = d.getUint16(o, Endian.little);
      o += 2;
      final start = Int32List(rows);
      final count = Uint16List(rows);
      for (var r = 0; r < rows; r++) {
        start[r] = d.getUint32(o, Endian.little);
        count[r] = d.getUint16(o + 4, Endian.little);
        o += 6;
      }
      final n = d.getUint32(o, Endian.little);
      o += 4;
      final words = Int16List(n);
      for (var i = 0; i < n; i++) {
        words[i] = d.getInt16(o + i * 2, Endian.little);
      }
      o += n * 2;
      layers.add(LensLayer(start, count, words));
    }

    final n1 = d.getUint16(o, Endian.little);
    o += 2;
    final path1 = Int16List(n1 * 2);
    for (var i = 0; i < n1 * 2; i++) {
      path1[i] = d.getInt16(o + i * 2, Endian.little);
    }
    o += n1 * 4;
    final n2 = d.getUint16(o, Endian.little);
    o += 2;
    final path2 = Int16List(n2 * 4);
    for (var i = 0; i < n2 * 4; i++) {
      path2[i] = d.getInt16(o + i * 2, Endian.little);
    }
    return LensTables._(width, height, tint, layers, path1, path2);
  }
}

/// One of the four layers CALC.C wrote. Row `r` owns [count] entries in [words]
/// starting at `start[r] + 1`; `words[start[r]]` is the run's x within the lens.
class LensLayer {
  final Int32List start;
  final Uint16List count;
  final Int16List words;
  const LensLayer(this.start, this.count, this.words);
}
