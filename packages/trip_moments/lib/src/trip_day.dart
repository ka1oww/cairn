import 'ping_window.dart';

/// Formats a calendar date as `YYYY-MM-DD`.
///
/// Only [DateTime.year], [DateTime.month] and [DateTime.day] are read --
/// any time-of-day or timezone component on the [DateTime] passed in is
/// ignored. Callers pass the trip's *calendar* date for the day in
/// question, not a specific instant.
String dateKey(DateTime date) {
  final y = date.year.toString().padLeft(4, '0');
  final m = date.month.toString().padLeft(2, '0');
  final d = date.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}

/// One calendar day of a trip, with the clock it is read in and any
/// itinerary bound that shortens it.
///
/// ## The clock is fixed where the day starts
///
/// [utcOffset] is the offset in force *where the day begins*, and it holds
/// for the whole day even if the party crosses a border at noon. A day is
/// an artefact, not a measurement: the day's page is one page, and slots
/// that shifted an hour sideways halfway through it would leave two people
/// pinged at the same wall-clock minute, or a gap where the clock jumped.
/// The clock moves at the next day boundary, which is exactly where the
/// artefact changes anyway.
///
/// The app layer supplies the offset. This package models a day's clock as
/// a fixed [Duration] rather than a full IANA zone, so the app is also
/// where DST is resolved -- see the package README, "What this cannot do".
///
/// ## Arrival and departure
///
/// [opensAt] and [closesAt] are the only two things an itinerary reliably
/// knows better than the default window: you land at 16:00 on the first
/// day and fly out at 11:00 on the last. Leave them null on every other
/// day. They are offsets from local midnight in the day's own clock, the
/// same units as [PingWindow.start].
///
/// Both are treated as *narrowing* the waking day, never widening it: a
/// 05:40 landing does not buy a 05:40 ping, and a 23:50 departure does not
/// extend the day past 22:30. See [resolveBounds].
class TripDay {
  /// The calendar date, in the trip's clock. Only year/month/day are read.
  final DateTime date;

  /// The UTC offset in force where this day *starts*. Held for the whole
  /// day; see the class doc.
  final Duration utcOffset;

  /// Earliest a ping may land, as an offset from local midnight. Null on
  /// an ordinary day. Set this to the arrival time on the day the trip
  /// begins.
  final Duration? opensAt;

  /// Latest a ping may land, as an offset from local midnight. Null on an
  /// ordinary day. Set this to the departure time on the day the trip
  /// ends.
  final Duration? closesAt;

  const TripDay({
    required this.date,
    required this.utcOffset,
    this.opensAt,
    this.closesAt,
  });

  /// The instant of local midnight for this day, as a UTC [DateTime].
  ///
  /// If the day's clock is UTC+8, local midnight is 16:00 UTC the previous
  /// day, i.e. `UTC = local - offset`.
  DateTime get localMidnightUtc =>
      DateTime.utc(date.year, date.month, date.day).subtract(utcOffset);

  /// This day's effective bounds: the waking day narrowed by any arrival
  /// or departure time.
  ///
  /// Returns `(open, close)` as offsets from local midnight. `close` may
  /// be at or before `open`, which means the day is too short to hold any
  /// slot at all -- land at 23:00 and nobody is pinged that day. That is
  /// the correct answer, not a shortfall to pad.
  (Duration, Duration) resolveBounds(PingWindow window) {
    var open = window.start;
    var close = window.end;
    final arrival = opensAt;
    final departure = closesAt;
    if (arrival != null && arrival > open) open = arrival;
    if (departure != null && departure < close) close = departure;
    return (open, close);
  }

  @override
  String toString() => 'TripDay(${dateKey(date)}, utc$utcOffset'
      '${opensAt != null ? ', opens $opensAt' : ''}'
      '${closesAt != null ? ', closes $closesAt' : ''})';
}
