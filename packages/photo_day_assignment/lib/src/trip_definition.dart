/// A trip's shape: when it starts, how many days it runs, and which IANA
/// timezone(s) its day boundaries are drawn in.
///
/// Most trips have one timezone for their whole duration — set
/// [defaultTimeZoneName] and leave [timeZoneOverridesByDay] empty. A trip
/// that itself moves between timezones (a multi-city itinerary planned in
/// advance, not just "a photo happened to be taken abroad") can give
/// individual days their own zone via [timeZoneOverridesByDay]; each day's
/// midnight-to-midnight window is then computed in *that* day's own zone.
/// See the README for how that interacts with GPS-based placement.
class TripDefinition {
  /// The calendar date of day 1. Only the year/month/day fields matter —
  /// any time-of-day component is ignored, since a day always starts at
  /// midnight in its own zone.
  final DateTime startDate;

  /// How many days the trip runs, inclusive of day 1. Must be >= 1.
  final int numberOfDays;

  /// The IANA timezone name (e.g. `'Asia/Tokyo'`) used for day boundaries on
  /// any day without an entry in [timeZoneOverridesByDay], and used as "the
  /// trip's timezone" for rung 2 of the ladder (EXIF present, GPS absent)
  /// regardless of per-day overrides — see the README's "which zone counts
  /// as *the* trip timezone" note.
  final String defaultTimeZoneName;

  /// Optional per-day timezone overrides, keyed by 1-based day number.
  /// A day not present here uses [defaultTimeZoneName].
  final Map<int, String> timeZoneOverridesByDay;

  TripDefinition({
    required this.startDate,
    required this.numberOfDays,
    required this.defaultTimeZoneName,
    this.timeZoneOverridesByDay = const {},
  }) : assert(numberOfDays >= 1, 'a trip must run at least one day');

  /// The IANA timezone name governing day [dayNumber]'s midnight-to-midnight
  /// boundary (1-based).
  String timeZoneNameForDay(int dayNumber) =>
      timeZoneOverridesByDay[dayNumber] ?? defaultTimeZoneName;

  /// The calendar date (year/month/day only) of day [dayNumber] (1-based).
  ///
  /// Computed in UTC purely as calendar arithmetic (not as an elapsed-time
  /// instant): adding a [Duration] to a *local* [DateTime] shifts by wall
  /// clock across a host-machine DST transition, which would silently corrupt
  /// the calendar date. UTC has no DST, so `+ Duration(days: n)` is exact.
  DateTime calendarDateForDay(int dayNumber) {
    final day1 = DateTime.utc(startDate.year, startDate.month, startDate.day);
    return day1.add(Duration(days: dayNumber - 1));
  }
}
