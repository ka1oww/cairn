import 'ping_window.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

// The database is bundled with this pure-Dart package. Initialise it here so
// every caller gets the same IANA rules, including historical DST changes.
final bool _timeZonesReady = (() {
  tz_data.initializeTimeZones();
  return true;
})();

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

/// The calendar date containing [instant] in [timeZone]. Returned at UTC
/// midnight because it is a date-only value, never an instant to add to.
DateTime dateInTimeZone(DateTime instant, String timeZone) {
  if (!_timeZonesReady) throw StateError('IANA timezone data is unavailable');
  final local = tz.TZDateTime.from(instant.toUtc(), tz.getLocation(timeZone));
  return DateTime.utc(local.year, local.month, local.day);
}

/// Whether [timeZone] names a zone in the bundled IANA database.
bool isKnownTimeZone(String timeZone) {
  try {
    if (!_timeZonesReady) return false;
    tz.getLocation(timeZone);
    return true;
  } on ArgumentError {
    return false;
  }
}

/// One calendar day of a trip, with the clock it is read in and any
/// itinerary bound that shortens it.
///
/// ## The clock is a real IANA zone
///
/// [timeZone] is an IANA name such as `Europe/Rome`. Each slot is converted
/// from its wall-clock minute through that zone, so a DST transition takes
/// effect on the actual date it occurs. [utcOffset] remains only for legacy
/// callers and fixed-offset test cases; new app code must pass [timeZone].
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

  /// The IANA zone this day is read in, if it is known.
  final String? timeZone;

  final Duration? _fixedUtcOffset;

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
    this.timeZone,
    Duration? utcOffset,
    this.opensAt,
    this.closesAt,
  })  : _fixedUtcOffset = utcOffset,
        assert(timeZone != null || utcOffset != null),
        assert(timeZone == null || utcOffset == null);

  /// The offset at local midnight, retained for the assignment's diagnostic
  /// surface and fixed-offset compatibility. Do not use it to convert a slot:
  /// a DST day can have a different offset by the waking window.
  Duration get utcOffset {
    final fixed = _fixedUtcOffset;
    if (fixed != null) return fixed;
    return _localDateTime(0).timeZoneOffset;
  }

  tz.Location? get _location {
    if (!_timeZonesReady || timeZone == null) return null;
    return tz.getLocation(timeZone!);
  }

  tz.TZDateTime _localDateTime(int minute) {
    final location = _location;
    if (location == null) {
      return tz.TZDateTime.utc(date.year, date.month, date.day).add(
        Duration(minutes: minute - utcOffset.inMinutes),
      );
    }
    return tz.TZDateTime(
      location,
      date.year,
      date.month,
      date.day,
      minute ~/ Duration.minutesPerHour,
      minute % Duration.minutesPerHour,
    );
  }

  /// The instant of local midnight for this day, as a UTC [DateTime].
  ///
  /// If the day's clock is UTC+8, local midnight is 16:00 UTC the previous
  /// day, i.e. `UTC = local - offset`.
  DateTime get localMidnightUtc => _localDateTime(0).toUtc();

  /// The real UTC instant for a wall-clock minute of this calendar day.
  DateTime instantAt(Duration localTimeOfDay) =>
      _localDateTime(localTimeOfDay.inMinutes).toUtc();

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
  String toString() =>
      'TripDay(${dateKey(date)}, ${timeZone ?? 'utc$utcOffset'}'
      '${opensAt != null ? ', opens $opensAt' : ''}'
      '${closesAt != null ? ', closes $closesAt' : ''})';
}
