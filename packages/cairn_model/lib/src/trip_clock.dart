import 'calendar_date.dart';
import 'clock_time.dart';

/// The clock a trip is read on: the wall clock everyone on the trip looks at,
/// expressed as an offset from UTC and, where it is known, the IANA zone that
/// offset came from.
///
/// A trip has one clock its members share. Nobody's phone gets to decide what
/// time it is on the trip: someone still on home time must not be pinged at
/// 3am local-to-the-trip, and a day must not seal at eight different
/// midnights. `packages/trip_moments` already works this way (`tripUtcOffset`,
/// and the dangling `[TripClock]` reference in its `quiet_window.dart` that
/// this type answers), and so does `packages/photo_day_assignment`
/// (`TripDefinition.defaultTimeZoneName`).
///
/// **Two spellings, both carried, neither resolved.** `trip_moments` needs a
/// fixed [utcOffset] and cannot do DST at all; `photo_day_assignment` needs a
/// real IANA [zoneId] and has a timezone database to read it with. This
/// package has no timezone database and never will — it is pure Dart with no
/// I/O — so it holds whichever spellings a caller knows and converts between
/// them never. Build a clock with [TripClock.zone] whenever the zone is
/// known, so the layer below has the name it needs.
final class TripClock {
  /// How far ahead of UTC this clock reads. Positive is east of Greenwich.
  ///
  /// This is the value `trip_moments` takes as `tripUtcOffset`.
  final Duration utcOffset;

  /// The IANA zone name this clock came from, e.g. `'Asia/Tokyo'`, or null
  /// when only an offset is known.
  ///
  /// This is the value `photo_day_assignment` takes as a timezone name, and
  /// the value `photos.capture_timezone` stores in the backend.
  final String? zoneId;

  /// A clock known only as an offset from UTC.
  TripClock.fixedOffset(this.utcOffset) : zoneId = null {
    _validateOffset(utcOffset);
  }

  /// A clock known by IANA zone name, together with the offset that zone was
  /// in when the clock was read.
  ///
  /// The offset is required, not derived: resolving `'Asia/Tokyo'` to `+09:00`
  /// takes a timezone database, which this package does not have. The caller
  /// that has one (`photo_day_assignment`, or the app's own tz lookup) passes
  /// the answer in.
  TripClock.zone(String this.zoneId, {required this.utcOffset}) {
    if (zoneId!.isEmpty) {
      throw ArgumentError.value(zoneId, 'zoneId', 'must not be empty');
    }
    _validateOffset(utcOffset);
  }

  static void _validateOffset(Duration offset) {
    if (offset.inMicroseconds % Duration.microsecondsPerMinute != 0) {
      throw ArgumentError.value(
        offset,
        'utcOffset',
        'must be a whole number of minutes',
      );
    }
    if (offset.inHours.abs() > 18) {
      throw ArgumentError.value(
        offset,
        'utcOffset',
        'must be within 18 hours of UTC',
      );
    }
  }

  /// The instant at which [date] begins on this clock.
  ///
  /// If the clock is UTC+9, midnight on the fifth is 16:00 UTC on the fourth:
  /// the returned `DateTime` is always UTC. Same arithmetic as
  /// `trip_moments`' `_placeInWindow`.
  DateTime startOfDay(CalendarDate date) =>
      DateTime.utc(date.year, date.month, date.day).subtract(utcOffset);

  /// What [instant] reads as on this clock.
  DateTime _wallClock(DateTime instant) => instant.toUtc().add(utcOffset);

  /// The date [instant] falls on, read on this clock.
  CalendarDate dateAt(DateTime instant) {
    final local = _wallClock(instant);
    return CalendarDate(local.year, local.month, local.day);
  }

  /// The time of day [instant] reads as on this clock — the hour printed
  /// beside a photo on the day page.
  ClockTime clockTimeAt(DateTime instant) {
    final local = _wallClock(instant);
    return ClockTime(local.hour, local.minute);
  }

  /// The zone name if there is one, otherwise the offset written out
  /// (`UTC+09:00`). For debugging and log lines, not for display.
  String get label => zoneId ?? _formatOffset(utcOffset);

  @override
  bool operator ==(Object other) =>
      other is TripClock &&
      other.utcOffset == utcOffset &&
      other.zoneId == zoneId;

  @override
  int get hashCode => Object.hash(utcOffset, zoneId);

  @override
  String toString() => 'TripClock($label)';
}

String _formatOffset(Duration offset) {
  final sign = offset.isNegative ? '-' : '+';
  final total = offset.abs();
  final hours = total.inHours.toString().padLeft(2, '0');
  final minutes = (total.inMinutes % 60).toString().padLeft(2, '0');
  return 'UTC$sign$hours:$minutes';
}
