/// The window of the trip's local day inside which pings are allowed.
///
/// Both the daily moment and the scattered ping are always mapped into this
/// window, in the *trip's* timezone (see [TripClock] / `tripUtcOffset`
/// parameters elsewhere in this package) — never the phone's home
/// timezone. That is what stops someone getting pinged mid-flight or at
/// 3am because they are still on home time.
class QuietWindow {
  /// Offset from local midnight at which the window opens. Default 09:00.
  final Duration start;

  /// Offset from local midnight at which the window closes. Default 21:00.
  final Duration end;

  const QuietWindow({
    this.start = const Duration(hours: 9),
    this.end = const Duration(hours: 21),
  });
  // Note: `end > start` can't be asserted here — Duration's comparison
  // operators aren't usable in a const-constructor initializer list, and
  // this constructor must stay const so it can back a `static const`
  // default window. It's validated instead wherever [span] is read.

  /// The default 09:00-21:00 window.
  static const QuietWindow standard = QuietWindow();

  /// Length of the window. Asserts `end` is after `start`.
  Duration get span {
    assert(
      end > start,
      'QuietWindow.end must be after QuietWindow.start',
    );
    return end - start;
  }

  @override
  String toString() => 'QuietWindow($start..$end)';
}
