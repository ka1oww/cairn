/// A calendar date with no clock and no timezone attached: three numbers a
/// human would write on a page.
///
/// It is deliberately not a `DateTime`. A `DateTime` is an instant, and an
/// instant tempts you to compare it against another instant, call `.toUtc()`
/// on it, or add hours to it — none of which mean anything for "the fifth of
/// June". Which *instant* the fifth of June begins at depends on whose clock
/// you are reading, and in this app that is always a `TripClock`, never the
/// device's.
///
/// This is the same instinct as `LocalDateTime` in
/// `packages/photo_day_assignment`, which exists so an EXIF wall-clock
/// reading cannot silently become an instant before a zone has been chosen
/// for it.
final class CalendarDate implements Comparable<CalendarDate> {
  final int year;

  /// 1-12.
  final int month;

  /// 1-31, and never a day that does not exist in [month] of [year].
  final int day;

  /// Throws [ArgumentError] for a date the calendar does not have
  /// (`2026-02-30`, `2026-13-01`). An impossible date is a bug in the caller,
  /// not a value to carry around and discover later.
  CalendarDate(this.year, this.month, this.day) {
    if (month < 1 || month > 12) {
      throw ArgumentError.value(month, 'month', 'must be 1-12');
    }
    final maxDay = _daysInMonth(year, month);
    if (day < 1 || day > maxDay) {
      throw ArgumentError.value(
        day,
        'day',
        'must be 1-$maxDay for ${_pad(year, 4)}-${_pad(month, 2)}',
      );
    }
  }

  /// Reads only the wall-clock date fields of [dateTime], ignoring
  /// [DateTime.isUtc] and the time of day entirely.
  ///
  /// Use this when a caller already has a `DateTime` whose calendar fields are
  /// the ones you want (a date resolved by `itinerary_parser`, say) — not to
  /// convert an instant into "the day it happened on", which needs a clock and
  /// belongs to `TripClock.dateAt` instead.
  factory CalendarDate.fromDateTimeIgnoringZone(DateTime dateTime) =>
      CalendarDate(dateTime.year, dateTime.month, dateTime.day);

  /// The date [days] later (or earlier, if negative).
  ///
  /// Computed in UTC as pure calendar arithmetic. Adding a [Duration] to a
  /// *local* `DateTime` shifts by wall clock across a host-machine DST
  /// transition and can silently land on the wrong date; UTC has no DST, so
  /// `+ Duration(days: n)` is exact. `TripDefinition.calendarDateForDay` in
  /// `packages/photo_day_assignment` does the same thing for the same reason.
  CalendarDate addDays(int days) {
    final shifted = DateTime.utc(year, month, day).add(Duration(days: days));
    return CalendarDate(shifted.year, shifted.month, shifted.day);
  }

  /// The next calendar date.
  CalendarDate get next => addDays(1);

  /// `YYYY-MM-DD`, the same spelling `trip_moments`' `dateKey()` and
  /// `itinerary_parser`'s JSON output use.
  String get iso => '${_pad(year, 4)}-${_pad(month, 2)}-${_pad(day, 2)}';

  @override
  int compareTo(CalendarDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  bool operator <(CalendarDate other) => compareTo(other) < 0;

  bool operator <=(CalendarDate other) => compareTo(other) <= 0;

  bool operator >(CalendarDate other) => compareTo(other) > 0;

  bool operator >=(CalendarDate other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is CalendarDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}

const List<int> _monthLengths = [
  31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31, //
];

bool _isLeapYear(int year) =>
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

int _daysInMonth(int year, int month) =>
    month == 2 && _isLeapYear(year) ? 29 : _monthLengths[month - 1];

String _pad(int value, int width) => value.toString().padLeft(width, '0');
