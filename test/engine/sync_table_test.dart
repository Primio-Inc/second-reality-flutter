import 'package:flutter_test/flutter_test.dart';
import 'package:second_reality/engine/sync_table.dart';

void main() {
  const table = SyncTable([
    SyncEvent(1.0, 10),
    SyncEvent(2.0, 11),
    SyncEvent(2.0, 12),
    SyncEvent(5.0, 13),
  ]);

  test('half-open interval (t0, t1]', () {
    expect(table.codesBetween(0.0, 1.0), [10]);
    expect(table.codesBetween(1.0, 2.0), [11, 12]);
    expect(table.codesBetween(2.0, 4.9), isEmpty);
  });

  test('backwards range is empty', () {
    expect(table.codesBetween(3.0, 1.0), isEmpty);
  });
}
