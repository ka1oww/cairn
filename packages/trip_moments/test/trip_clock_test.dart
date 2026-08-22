// The clock is the trip's, and on a day that changes country it is the one
// the day started in.

import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

/// Wall-clock minutes since local midnight for [ping], read in [offset].
int _wallClockMinutes(Ping ping, Duration offset) {
  final local = ping.at.add(offset);
  return local.hour * 60 + local.minute;
}

void main() {
  final party = Party(const ['alice', 'bob', 'carla', 'dan', 'eve']);

  group('pings land in the trip\'s clock, not the phone\'s', () {
    test('an Auckland trip booked from a Pacific-time phone', () {
      // A ~20 hour gap, larger than a whole waking day. If the window were
      // applied in the device's clock these pings would land in the middle
      // of the Auckland night.
      const auckland = Duration(hours: 12);
      final day = dayAssignment(
        tripId: 'trip-nz',
        party: party,
        day: TripDay(date: DateTime(2026, 3, 15), utcOffset: auckland),
      );

      for (final ping in day.pings) {
        expect(
          _wallClockMinutes(ping, auckland),
          inInclusiveRange(8 * 60, 22 * 60 + 30),
          reason: '${ping.at} is not 08:00-22:30 Auckland time',
        );
      }
    });

    test('a clock west of UTC stays in-window across two months', () {
      const hawaii = Duration(hours: -10);
      for (var i = 0; i < 60; i++) {
        final day = dayAssignment(
          tripId: 'trip-hawaii',
          party: party,
          day: TripDay(
            date: DateTime(2026, 3, 15).add(Duration(days: i)),
            utcOffset: hawaii,
          ),
        );
        for (final ping in day.pings) {
          expect(_wallClockMinutes(ping, hawaii),
              inInclusiveRange(8 * 60, 22 * 60 + 30));
        }
      }
    });

    test('a half-hour offset is handled exactly', () {
      const kathmandu = Duration(hours: 5, minutes: 45);
      final day = dayAssignment(
        tripId: 'trip-np',
        party: party,
        day: TripDay(date: DateTime(2026, 4, 4), utcOffset: kathmandu),
      );
      for (final ping in day.pings) {
        expect(_wallClockMinutes(ping, kathmandu),
            inInclusiveRange(8 * 60, 22 * 60 + 30));
      }
    });
  });

  group('a day that changes country keeps the clock it started in', () {
    // Bangkok (UTC+7) to Tokyo (UTC+9) overnight: the 3rd is read in +7
    // for its whole length, and the clock moves to +9 for the 4th.
    const bangkok = Duration(hours: 7);
    const tokyo = Duration(hours: 9);

    final days = [
      TripDay(date: DateTime(2026, 5, 3), utcOffset: bangkok),
      TripDay(date: DateTime(2026, 5, 4), utcOffset: tokyo),
      TripDay(date: DateTime(2026, 5, 5), utcOffset: tokyo),
    ];

    test('every ping on the crossing day reads in the starting clock', () {
      final schedule =
          tripSchedule(tripId: 'trip-asia', party: party, days: days);

      final crossingDay = schedule.first;
      expect(crossingDay.utcOffset, equals(bangkok));
      for (final ping in crossingDay.pings) {
        // The last ping of the day, hours after the border, is still read
        // in Bangkok time. One clock, start to finish.
        expect(_wallClockMinutes(ping, bangkok),
            inInclusiveRange(8 * 60, 22 * 60 + 30));
      }
    });

    test('the clock moves at the day boundary, not before it', () {
      final schedule =
          tripSchedule(tripId: 'trip-asia', party: party, days: days);

      expect(schedule[0].utcOffset, equals(bangkok));
      expect(schedule[1].utcOffset, equals(tokyo));
      for (final ping in schedule[1].pings) {
        expect(_wallClockMinutes(ping, tokyo),
            inInclusiveRange(8 * 60, 22 * 60 + 30));
      }
    });

    test('the slots stay stable: no overlap, no gap at the border', () {
      final schedule =
          tripSchedule(tripId: 'trip-asia', party: party, days: days);

      // Day 3 ends before day 4 begins, in absolute time, even though the
      // clock changed between them. A mid-day clock shift is what would
      // break this.
      for (var i = 1; i < schedule.length; i++) {
        expect(
          schedule[i].pings.first.at.isAfter(schedule[i - 1].pings.last.at),
          isTrue,
          reason: 'day $i starts before day ${i - 1} finished',
        );
      }
      // And each day still holds one ping per person.
      for (final day in schedule) {
        expect(day.pings.length, equals(party.size));
      }
    });

    test(
        'the same date in two clocks yields the same people in the same '
        'slots, shifted whole', () {
      // The deal does not depend on the clock -- only on trip, party and
      // date -- so a border crossing moves the times without re-dealing
      // who is where. That is what keeps a day's page coherent.
      final inBangkok = dayAssignment(
        tripId: 'trip-asia',
        party: party,
        day: TripDay(date: DateTime(2026, 5, 3), utcOffset: bangkok),
      );
      final inTokyo = dayAssignment(
        tripId: 'trip-asia',
        party: party,
        day: TripDay(date: DateTime(2026, 5, 3), utcOffset: tokyo),
      );

      expect(
        inTokyo.pings.map((p) => p.memberId).toList(),
        equals(inBangkok.pings.map((p) => p.memberId).toList()),
      );
      for (var i = 0; i < inBangkok.pings.length; i++) {
        expect(inTokyo.pings[i].localTimeOfDay,
            equals(inBangkok.pings[i].localTimeOfDay));
        expect(
          inBangkok.pings[i].at.difference(inTokyo.pings[i].at),
          equals(tokyo - bangkok),
        );
      }
    });
  });

  group('PingWindow', () {
    test('the waking day is 08:00 to 22:30', () {
      expect(PingWindow.standard.start, equals(const Duration(hours: 8)));
      expect(PingWindow.standard.end,
          equals(const Duration(hours: 22, minutes: 30)));
      expect(PingWindow.standard.span,
          equals(const Duration(hours: 14, minutes: 30)));
    });

    test('the retired 09:00-21:00 window is really gone', () {
      // Pins the decision rather than the number: 22:30 exists so the last
      // slot reaches dinner. A silent revert to 21:00 would take dinner
      // back out.
      expect(PingWindow.standard.end, isNot(equals(const Duration(hours: 21))));
      expect(
          PingWindow.standard.start, isNot(equals(const Duration(hours: 9))));
    });

    test('is configurable', () {
      const custom =
          PingWindow(start: Duration(hours: 7), end: Duration(hours: 20));
      expect(custom.span, equals(const Duration(hours: 13)));

      final day = dayAssignment(
        tripId: 'trip-custom',
        party: party,
        day: TripDay(date: DateTime(2026, 8, 8), utcOffset: Duration.zero),
        window: custom,
      );
      for (final ping in day.pings) {
        expect(ping.localTimeOfDay, greaterThanOrEqualTo(custom.start));
        expect(ping.localTimeOfDay, lessThanOrEqualTo(custom.end));
      }
    });

    test('rejects an end at or before start', () {
      const invalid =
          PingWindow(start: Duration(hours: 12), end: Duration(hours: 12));
      expect(() => invalid.span, throwsA(isA<AssertionError>()));
    });
  });
}
