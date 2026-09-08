import 'calendar_date.dart';
import 'clock_time.dart';
import 'day_standing.dart';
import 'equality.dart';
import 'stop.dart';
import 'trip_clock.dart';

/// Legacy domain representation of one day of the trip.
///
/// **A day is an artefact, not a measurement.** It is the thing the trip
/// produces once per day — a page of photos in the order they happened, sealed
/// at midnight (`docs/decisions/2026-08-22-the-moment.md`) — and like any
/// artefact it is made at a particular place and keeps that provenance
/// afterwards.
///
/// Its [clock] is fixed when the day is built. This is retained for older
/// domain and photo-related values; the live schedule does not derive a trip
/// clock from it. It receives the persisted destination IANA zone directly.
///
/// Nothing here can move a day's clock after the fact. [clock] is final, there
/// is no `copyWith`, and [startsAt], [endsAt] and [clockTimeOf] all read it
/// and nothing else — the trip's later position is not reachable from a day.
final class TripDay {
  /// 1-based position in the trip. Day 1 is the first day.
  final int number;

  /// The date this day carries, written on its own [clock].
  ///
  /// Not necessarily one more than the previous day's: a trip crossing the
  /// date line westward lives the same date twice, and eastward skips one.
  /// Days are ordered by [number] and by [startsAt], never by [date].
  final CalendarDate date;

  /// The legacy clock this day preserves. See the class doc.
  final TripClock clock;

  /// The city or place this day belongs to, if the itinerary named one. Maps
  /// straight from `itinerary_parser`'s `ParsedDay.place`.
  final String? place;

  /// The day's stops, in the order the itinerary listed them. Unmodifiable.
  final List<Stop> stops;

  TripDay({
    required this.number,
    required this.date,
    required this.clock,
    this.place,
    List<Stop> stops = const [],
  }) : stops = List.unmodifiable(stops) {
    if (number < 1) {
      throw ArgumentError.value(number, 'number', 'day numbers start at 1');
    }
    if (place != null && place!.trim().isEmpty) {
      throw ArgumentError.value(
        place,
        'place',
        'use null for a day with no place, not an empty string',
      );
    }
  }

  /// Builds legacy consecutive days, each on the trip's [clock] unless
  /// [clockOverridesByDay] gives that day its own.
  ///
  /// This is the same shape as `TripDefinition` in
  /// `packages/photo_day_assignment` (`defaultTimeZoneName` plus
  /// `timeZoneOverridesByDay`). Neither is the live ping scheduler's clock;
  /// it always receives the persisted destination IANA zone instead.
  ///
  /// All maps are keyed by 1-based day number.
  static List<TripDay> sequence({
    required CalendarDate startDate,
    required int length,
    required TripClock clock,
    Map<int, TripClock> clockOverridesByDay = const {},
    Map<int, String> placesByDay = const {},
    Map<int, List<Stop>> stopsByDay = const {},
  }) {
    if (length < 1) {
      throw ArgumentError.value(length, 'length', 'a trip runs at least a day');
    }
    for (final keys in [
      clockOverridesByDay.keys,
      placesByDay.keys,
      stopsByDay.keys,
    ]) {
      for (final day in keys) {
        if (day < 1 || day > length) {
          throw ArgumentError.value(
            day,
            'dayNumber',
            'no such day on a $length-day trip',
          );
        }
      }
    }
    return List.unmodifiable([
      for (var n = 1; n <= length; n++)
        TripDay(
          number: n,
          date: startDate.addDays(n - 1),
          clock: clockOverridesByDay[n] ?? clock,
          place: placesByDay[n],
          stops: stopsByDay[n] ?? const [],
        ),
    ]);
  }

  /// The instant this day begins: midnight on [date], on this day's [clock].
  /// Always UTC.
  DateTime get startsAt => clock.startOfDay(date);

  /// The instant this day ends, exclusive: exactly 24 hours after [startsAt].
  ///
  /// A day is 24 hours of its own clock. Two consequences worth knowing before
  /// building on this, both documented in the README:
  /// a DST transition inside a day makes the real midnight-to-midnight 23 or
  /// 25 hours and this does not model that; and where the next day starts on a
  /// different clock, the two windows can leave a gap or overlap in absolute
  /// time.
  DateTime get endsAt => startsAt.add(const Duration(days: 1));

  /// Whether [instant] falls inside this day's window, `[startsAt, endsAt)`.
  bool containsInstant(DateTime instant) {
    final utc = instant.toUtc();
    return !utc.isBefore(startsAt) && utc.isBefore(endsAt);
  }

  /// Where this day stands at [instant] — behind us, being lived, or still
  /// ahead — read on this day's own clock and no other.
  ///
  /// This is what the gate asks about time, and asking it here is what keeps
  /// the answer tied to the clock the day was fixed on: a day that began in
  /// Tokyo seals at Tokyo's midnight even for someone reading it in London.
  DayStanding standingAt(DateTime instant) {
    final utc = instant.toUtc();
    if (utc.isBefore(startsAt)) return DayStanding.notYet;
    if (utc.isBefore(endsAt)) return DayStanding.inProgress;
    return DayStanding.walked;
  }

  /// The hour [instant] reads as on *this day's* clock — the time printed
  /// beside a photo on this day's page.
  ///
  /// Deliberately does not require [instant] to fall inside the day. A photo
  /// can be placed on a day by hand (`photos.trip_day_is_manual`), and
  /// refusing to render an hour for it would break an escape hatch the backend
  /// exists to provide.
  ClockTime clockTimeOf(DateTime instant) => clock.clockTimeAt(instant);

  @override
  bool operator ==(Object other) =>
      other is TripDay &&
      other.number == number &&
      other.date == date &&
      other.clock == clock &&
      other.place == place &&
      listEquals(other.stops, stops);

  @override
  int get hashCode =>
      Object.hash(number, date, clock, place, Object.hashAll(stops));

  @override
  String toString() =>
      'TripDay($number, $date${place == null ? '' : ', $place'}, '
      '${clock.label}, ${stops.length} stops)';
}
