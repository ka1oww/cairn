import 'calendar_date.dart';
import 'clock_time.dart';

/// Legacy value model for a trip clock: a fixed UTC offset and, where known,
/// the IANA zone name it came from.
///
/// A trip has one clock its members share. Nobody's phone gets to decide what
/// time it is on the trip: someone still on home time must not be pinged at
/// 3am local-to-the-trip, and a day must not seal at eight different
/// midnights. The production schedule now passes the persisted IANA zone
/// directly to `trip_moments`; this value remains for the older domain and
/// photo-assignment types that still carry an offset with their zone name.
///
/// **Two spellings, both carried, neither resolved.** This package has no
/// timezone database, so it cannot derive a date-specific offset from
/// [zoneId]. New scheduling code must use the IANA-aware `trip_moments`
/// surface rather than this fixed-offset arithmetic.
final class TripClock {
  /// How far ahead of UTC this clock reads. Positive is east of Greenwich.
  ///
  /// This is retained for legacy fixed-offset consumers only.
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
