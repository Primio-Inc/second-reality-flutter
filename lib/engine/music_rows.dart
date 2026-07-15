import 'dart:typed_data';

/// The demo's music ROW clock — the engine's `dis_musrow()`.
///
/// The original does not sync on seconds, it syncs on tracker rows: parts ask
/// the music player which pattern row is playing and act on it (TECHNO/KOE.C
/// flashes its palette on every row where `(row & 7) == 7`, and its column wipe
/// waits for that same row). Anything derived from a fitted "beat period"
/// drifts; the row grid does not, because it is what the music actually does.
///
/// Backed by assets/tables/music_rows.srt, built by tool/extract_music_rows.py:
/// libopenmpt steps the two real modules (MUSIC0 = the intro tune, MUSIC1 = the
/// main tune from 104.36s) and reports the start time of every row, so speed
/// (Axx), tempo (Txx) and order jumps are all baked in. Times are in the
/// continuous soundtrack's timebase.
///
///     "SRM2" + u16 count + count * { u32 t_ms, u8 order, u8 row, u8 segment }
///
/// Segment: 0 = MUSIC0's head (the intro), 1 = MUSIC1 (the main demo), 2 =
/// MUSIC0 resumed for the ending. Times are already in soundtrack seconds.
class MusicRows {
  /// Row start times, soundtrack seconds, ascending.
  final Float64List times;

  /// The row index within its pattern (0..63) for each entry in [times].
  final Uint8List rows;

  /// The music order (position in the module's order list) of each row.
  final Uint8List orders;

  /// Which stretch of the soundtrack each row belongs to: 0 = MUSIC0's head
  /// (the intro), 1 = MUSIC1 (the main demo), 2 = MUSIC0 resumed (the ending).
  /// The same (order,row) occurs in BOTH MUSIC0 segments, so a lookup must say
  /// which one it means — `ordersync1` has cue groups in each.
  final Uint8List segments;

  MusicRows._(this.times, this.rows, this.orders, this.segments);

  static MusicRows decode(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    if (bytes[0] != 0x53 ||
        bytes[1] != 0x52 ||
        bytes[2] != 0x4D ||
        bytes[3] != 0x32) {
      throw const FormatException('not an SRM2 row table');
    }
    final count = d.getUint16(4, Endian.little);
    final times = Float64List(count);
    final rows = Uint8List(count);
    final orders = Uint8List(count);
    final segments = Uint8List(count);
    for (var i = 0; i < count; i++) {
      final o = 6 + i * 7;
      times[i] = d.getUint32(o, Endian.little) / 1000.0;
      orders[i] = d.getUint8(o + 4);
      rows[i] = d.getUint8(o + 5);
      segments[i] = d.getUint8(o + 6);
    }
    return MusicRows._(times, rows, orders, segments);
  }

  /// The soundtrack time a given music position starts — `dis_sync`'s
  /// `ordersync1` entries are exactly this: an (order, row) pair. Returns null
  /// if that position is never played.
  double? timeOf(int order, int row, {int segment = 0}) {
    for (var i = 0; i < times.length; i++) {
      if (segments[i] == segment && orders[i] == order && rows[i] == row) {
        return times[i];
      }
    }
    return null;
  }

  /// Index of the last row that has started at soundtrack time [t], or -1
  /// before the first row. Binary search — parts call this every frame.
  int indexAt(double t) {
    var lo = 0, hi = times.length - 1, best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] <= t) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  /// `dis_musrow()`: the pattern row playing at [t], or -1 before the music.
  int rowAt(double t) {
    final i = indexAt(t);
    return i < 0 ? -1 : rows[i];
  }
}
