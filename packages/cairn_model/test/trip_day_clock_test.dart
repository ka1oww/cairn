import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

/// The subtle one: a day's clock is fixed where the day starts, and does not
/// move when the trip crosses a border in the afternoon.
void main() {
  // Tokyo in June is UTC+9; London in June is UTC+1 (BST).
  final tokyo =
      TripClock.zone('Asia/Tokyo', utcOffset: const Duration(hours: 9));
  final london =
      TripClock.zone('Europe/London', utcOffset: const Duration(hours: 1));

  // Three days. The group wakes in Tokyo on day 2 and lands in London that
  // afternoon, so London's clock only takes over on day 3 -- the first day
  // that *starts* there.
  final days = TripDay.sequence(
    startDate: CalendarDate(2026, 6, 4),
    length: 3,
    clock: tokyo,
    clockOverridesByDay: {3: london},
  );
  final trip = Trip(
    id: const TripId('trip-tokyo-london'),
    name: 'Tokyo to London',
    startedBy: const MemberId('mum'),
    clock: tokyo,
    members: [Member(id: const MemberId('mum'), displayName: 'Mum')],
    days: days,
  );

  // 15:00 in London on 5 June, which is 23:00 the same evening in Tokyo.
  final afterLanding = DateTime.utc(2026, 6, 5, 14);

  // 08:40 in Tokyo that same morning, before the flight.
  final breakfast = DateTime.utc(2026, 6, 4, 23, 40);

  group('a day is read on the clock it started on', () {
    test('day 2 keeps Tokyo even though the trip ends up in London', () {
      expect(trip.day(2).clock, tokyo);
      expect(trip.day(3).clock, london);
      expect(trip.clock, tokyo, reason: 'the trip clock is its own thing');
    });

    test('day 2 runs midnight to midnight in Tokyo', () {
      expect(trip.day(2).startsAt, DateTime.utc(2026, 6, 4, 15));
      expect(trip.day(2).endsAt, DateTime.utc(2026, 6, 5, 15));
    });

    test('a photo taken after landing still belongs to the Tokyo day', () {
      expect(trip.day(2).containsInstant(afterLanding), isTrue);
      expect(trip.day(3).containsInstant(afterLanding), isFalse);
    });

    test('and reads at the hour the day was on, not the hour it landed at', () {
      // The whole point. 15:00 in London, printed on the day page as 23:00,
      // because that is what the clock in their pockets said all day.
      expect(trip.day(2).clockTimeOf(afterLanding), const ClockTime(23, 0));
      expect(trip.day(2).clockTimeOf(breakfast), const ClockTime(8, 40));
    });

    test('the same day on the destination clock would answer differently', () {
      // Not a supported construction -- built here only to show that the clock
      // is what fixes the day, so that moving it silently would move
      // everything.
      final asIfLondon =
          TripDay(number: 2, date: CalendarDate(2026, 6, 5), clock: london);
      expect(asIfLondon.clockTimeOf(afterLanding), const ClockTime(15, 0));
      expect(asIfLondon.startsAt, isNot(trip.day(2).startsAt));
    });
  });

  test('changing clock between days can leave a gap in absolute time', () {
    // Day 2 seals at Tokyo midnight; day 3 opens at London midnight, eight
    // hours later. Nothing is lost -- placing an in-transit instant is
    // photo_day_assignment's problem, and it refuses to guess rather than
    // clamping. This test pins that the model reproduces the gap honestly
    // instead of papering over it.
    expect(trip.day(3).startsAt.difference(trip.day(2).endsAt),
        const Duration(hours: 8));
  });

  test('the timeline orders by instant, so the morning photo comes first', () {
    final pool = DayPool.of(2, [
      PhotoRef(
        id: const PhotoId('evening'),
        dayNumber: 2,
        contributor: const MemberId('mum'),
        takenAt: afterLanding,
        origin: PhotoOrigin.pinged,
      ),
      PhotoRef(
        id: const PhotoId('breakfast'),
        dayNumber: 2,
        contributor: const MemberId('mum'),
        takenAt: breakfast,
        origin: PhotoOrigin.imported,
      ),
    ]);
    expect(
      pool.photos.map((photo) => trip.day(2).clockTimeOf(photo.takenAt).iso),
      ['08:40', '23:00'],
    );
  });

  test('a trip crossing the date line may live the same date twice', () {
    // Auckland to Honolulu: both days are the tenth on their own clock. The
    // trip is still well formed, because days are ordered by when they begin
    // and not by the date they carry.
    final auckland = TripClock.zone('Pacific/Auckland',
        utcOffset: const Duration(hours: 12));
    final honolulu = TripClock.zone('Pacific/Honolulu',
        utcOffset: const Duration(hours: -10));
    final crossing = Trip(
      id: const TripId('trip-dateline'),
      name: 'The long tenth',
      startedBy: const MemberId('mum'),
      clock: auckland,
      members: [Member(id: const MemberId('mum'), displayName: 'Mum')],
      days: [
        TripDay(number: 1, date: CalendarDate(2026, 6, 10), clock: auckland),
        TripDay(number: 2, date: CalendarDate(2026, 6, 10), clock: honolulu),
      ],
    );
    expect(crossing.day(1).date, crossing.day(2).date);
    expect(crossing.day(2).startsAt.isAfter(crossing.day(1).startsAt), isTrue);
  });
}
