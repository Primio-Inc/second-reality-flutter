import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/demo_timeline.dart';
import 'package:second_reality/engine/part.dart';
import 'package:second_reality/engine/sync_table.dart';

class SpyPart extends Part {
  final log = <String>[];
  @override
  void init() => log.add('init');
  @override
  void update(double t, List<int> codes) =>
      log.add('u ${t.toStringAsFixed(1)} $codes');
  @override
  void dispose() => log.add('dispose');
}

void main() {
  test('switches parts at boundaries, part-local time, sync delivery', () {
    final a = SpyPart(), b = SpyPart();
    final tl = DemoTimeline(
      entries: [PartEntry(0, () => a), PartEntry(10, () => b)],
      sync: const SyncTable([SyncEvent(0.5, 42)]),
    );
    tl.tick(0.0);
    tl.tick(1.0);
    expect(a.log, ['init', 'u 0.0 []', 'u 1.0 [42]']);
    tl.tick(10.5);
    expect(a.log.last, 'dispose');
    expect(b.log, ['init', 'u 0.5 []']);
    expect(tl.currentIndex, 1);
  });

  test('backwards seek rebuilds part', () {
    var built = 0;
    final tl = DemoTimeline(
      entries: [
        PartEntry(0, () {
          built++;
          return SpyPart();
        })
      ],
      sync: const SyncTable([]),
    );
    tl.tick(5.0);
    tl.tick(1.0); // seek back
    expect(built, 2);
  });
}
