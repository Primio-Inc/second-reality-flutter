import 'part.dart';
import 'sync_table.dart';

class PartEntry {
  final double start; // music position (seconds) where this scene begins
  final Part Function() build;
  final String name; // human label for the scene menu
  const PartEntry(this.start, this.build, {this.name = ''});
}

/// The DIS equivalent: owns part sequencing. Clock value comes from outside
/// (audio position) — this class never reads wall time.
/// A named jump point INSIDE a part, for the scene menu. Some parts contain a
/// distinct set-piece you want to reach directly (the intro ship flies in half
/// way through the horizon part), but it is not a part of its own and must not
/// become one — the timeline's part boundaries are the original's.
class Bookmark {
  final double start; // music position (seconds)
  final String name;
  const Bookmark(this.start, this.name);
}

class DemoTimeline {
  final List<PartEntry> entries;
  final SyncTable sync;

  /// Extra menu jump points that live inside a part (see [Bookmark]).
  final List<Bookmark> bookmarks;

  Part? _current;
  int _index = -1;
  double _lastTime = double.negativeInfinity;

  DemoTimeline(
      {required this.entries,
      required this.sync,
      this.bookmarks = const []});

  Part? get current => _current;
  int get currentIndex => _index;
  double get lastTime => _lastTime;

  int _indexFor(double time) {
    var i = 0;
    while (i + 1 < entries.length && entries[i + 1].start <= time) {
      i++;
    }
    return i;
  }

  void tick(double time) {
    final seekBack = time < _lastTime - 0.5;
    final idx = _indexFor(time);
    if (idx != _index || seekBack) {
      _current?.dispose();
      _index = idx;
      _current = entries[idx].build()..init();
      _lastTime = seekBack ? time : entries[idx].start;
    }
    final events = sync.eventsBetween(_lastTime, time);
    _current!.musicTime = time;
    _current!.syncEvents = events;
    _current!.update(
        time - entries[_index].start, [for (final e in events) e.code]);
    _lastTime = time;
  }
}
