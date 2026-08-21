/// A wall-clock date and time with **no** associated timezone.
///
/// This is exactly the shape EXIF `DateTimeOriginal` stores: digits with no
/// UTC offset and no zone name. It is deliberately not a [DateTime], because
/// a [DateTime] tempts you to call `.toUtc()` or compare it directly against
/// another timestamp, and doing that silently (assuming it means "UTC" or
/// "whatever the current device zone is") is the exact bug this package
/// exists to prevent. A [LocalDateTime] can only become a real instant in
/// time once you've picked a [Location][:timezone.Location] to interpret it
/// in — see `assignPhotoToDay` for how that choice is made.
class LocalDateTime {
  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;
  final int second;

  const LocalDateTime({
    required this.year,
    required this.month,
    required this.day,
    this.hour = 0,
    this.minute = 0,
    this.second = 0,
  });

  /// Builds a [LocalDateTime] from a [DateTime], reading only its wall-clock
  /// fields (year/month/day/hour/minute/second) and ignoring [DateTime.isUtc]
  /// entirely. Use this when a caller already parsed the EXIF string into a
  /// [DateTime] but the offset/zone flag on that object means nothing (EXIF
  /// carries none) — the caller must not have called `.toUtc()` first, or the
  /// wall-clock digits will already be wrong.
  factory LocalDateTime.fromDateTimeIgnoringZone(DateTime dt) => LocalDateTime(
    year: dt.year,
    month: dt.month,
    day: dt.day,
    hour: dt.hour,
    minute: dt.minute,
    second: dt.second,
  );

  @override
  String toString() {
    String two(int n) => n.toString().padLeft(2, '0');
    return '$year-${two(month)}-${two(day)} ${two(hour)}:${two(minute)}:${two(second)}';
  }

  @override
  bool operator ==(Object other) =>
      other is LocalDateTime &&
      other.year == year &&
      other.month == month &&
      other.day == day &&
      other.hour == hour &&
      other.minute == minute &&
      other.second == second;

  @override
  int get hashCode => Object.hash(year, month, day, hour, minute, second);
}
