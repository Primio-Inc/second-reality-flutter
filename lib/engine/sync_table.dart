class SyncEvent {
  final double time;
  final int code;
  const SyncEvent(this.time, this.code);
}

/// The dis_muscode equivalent: hand-tuned music sync events. The original
/// DIS pulled these from STMIK's pattern data; here they are timestamped
/// against the pre-rendered track.
class SyncTable {
  final List<SyncEvent> events;
  const SyncTable(this.events);

  List<int> codesBetween(double t0, double t1) =>
      [for (final e in eventsBetween(t0, t1)) e.code];

  /// The full events (with their TIMES) fired in (t0, t1]. A part that anchors
  /// an animation to a sync event must anchor to `event.time`, never to the
  /// moment of delivery: a seek can cross the event seconds after it "fired",
  /// and latching the delivery time plays the animation late by the skip.
  List<SyncEvent> eventsBetween(double t0, double t1) {
    if (t1 < t0) return const [];
    return [
      for (final e in events)
        if (e.time > t0 && e.time <= t1) e,
    ];
  }
}
