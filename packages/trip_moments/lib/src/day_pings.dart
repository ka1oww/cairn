/// Hard ceiling on how many pings a single day may ever contain.
///
/// This is enforced structurally by [DayPings] (it has exactly two
/// `DateTime` fields, no list to accidentally grow) rather than just by
/// convention — see the README section "The ceiling".
const int maxPingsPerDay = 2;

/// The at-most-[maxPingsPerDay] pings for one calendar day of a trip: the
/// shared daily moment and this device's scattered ping.
///
/// The two-field shape is deliberate: there is no `List<DateTime>` here to
/// accidentally append a third ping to. Anyone extending this package to
/// add a new kind of ping has to consciously widen this type (and update
/// [maxPingsPerDay] and the tests that pin it), rather than being able to
/// silently exceed the ceiling by pushing onto a collection.
class DayPings {
  /// The calendar date (in the trip's timezone) these pings are for.
  final DateTime date;

  /// The shared instant every device on the trip agrees on for this date.
  final DateTime dailyMoment;

  /// This device's own instant for this date.
  final DateTime scatteredPing;

  const DayPings({
    required this.date,
    required this.dailyMoment,
    required this.scatteredPing,
  });

  /// Both instants, for callers that want to iterate rather than address
  /// [dailyMoment] / [scatteredPing] by name (e.g. to register OS-level
  /// local notifications). Always exactly [maxPingsPerDay] entries.
  List<DateTime> get instants =>
      List.unmodifiable([dailyMoment, scatteredPing]);

  @override
  String toString() => 'DayPings(${date.toIso8601String().split('T').first}: '
      'moment=$dailyMoment, scatter=$scatteredPing)';
}
