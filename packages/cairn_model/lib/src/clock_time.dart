/// A time of day in 24-hour form, with no date and no timezone.
///
/// Two things in the app are a [ClockTime]: the time written next to a stop in
/// the pasted itinerary, and the hour printed beside a photo on the day page.
/// Both are read off a clock someone was standing in front of, which is why
/// neither is an instant.
///
/// This is the same shape as `ParsedTime` in `packages/itinerary_parser`;
/// converting is `ClockTime(parsed.hour, parsed.minute)`. That package keeps
/// its own copy because it must not depend on the domain, not because the two
/// disagree.
final class ClockTime implements Comparable<ClockTime> {
  /// 0-23.
  final int hour;

  /// 0-59.
  final int minute;

  const ClockTime(this.hour, this.minute)
      : assert(hour >= 0 && hour <= 23, 'hour must be 0-23'),
        assert(minute >= 0 && minute <= 59, 'minute must be 0-59');

  /// `HH:MM`, zero-padded, 24-hour — the spelling the day page prints.
  String get iso =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  /// Minutes since midnight on the clock this time was read from.
  int get minutesSinceMidnight => hour * 60 + minute;

  @override
  int compareTo(ClockTime other) =>
      minutesSinceMidnight.compareTo(other.minutesSinceMidnight);

  @override
  bool operator ==(Object other) =>
      other is ClockTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => iso;
}
