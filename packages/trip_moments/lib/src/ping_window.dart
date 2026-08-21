/// The waking day: the band of the trip's local day that pings are dealt
/// across.
///
/// `08:00` to `22:30`, in the trip's own clock, never the phone's home
/// clock. The `22:30` close is deliberate and is not a rounding of
/// `22:00`: it pushes the whole last slot later so that the person holding
/// it is interrupted during dinner rather than before it. Dinner is the
/// part of a trip day most worth a photograph and the part a `22:00` close
/// reliably missed.
///
/// The `08:00` open is the other end of the same judgement: early enough
/// to catch breakfast, late enough that the first ping is not delivered to
/// someone still asleep.
class PingWindow {
  /// Offset from local midnight at which the waking day opens. Default
  /// 08:00.
  final Duration start;

  /// Offset from local midnight at which the waking day closes. Default
  /// 22:30.
  final Duration end;

  const PingWindow({
    this.start = const Duration(hours: 8),
    this.end = const Duration(hours: 22, minutes: 30),
  });
  // Note: `end > start` can't be asserted here -- Duration's comparison
  // operators aren't usable in a const-constructor initializer list, and
  // this constructor must stay const so it can back a `static const`
  // default window. It's validated instead wherever [span] is read.

  /// The default 08:00-22:30 waking day.
  static const PingWindow standard = PingWindow();

  /// Length of the waking day. Asserts [end] is after [start].
  Duration get span {
    assert(end > start, 'PingWindow.end must be after PingWindow.start');
    return end - start;
  }

  @override
  String toString() => 'PingWindow($start..$end)';
}
