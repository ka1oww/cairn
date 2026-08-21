// The arrival and departure days follow the itinerary, not the clock.
//
// These are the only two days where the fixed 08:00-22:30 waking day is
// reliably wrong: you were on a plane for the first half of one and the
// second half of the other. Fewer slots on a short day is the correct
// answer, not a shortfall to pad.

import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  final party = Party(const [
    'alice',
    'bob',
    'carla',
    'dan',
    'eve',
    'frank',
    'gita',
    'hal',
  ]);

  DayAssignment assign({Duration? opensAt, Duration? closesAt}) {
    return dayAssignment(
      tripId: 'trip-edges',
      party: party,
      day: TripDay(
        date: DateTime(2026, 9, 3),
        utcOffset: const Duration(hours: 8),
        opensAt: opensAt,
        closesAt: closesAt,
      ),
    );
  }

  group('a shortened first day', () {
    test('landing at 16:00 runs the day 16:00-22:30', () {
      final day = assign(opensAt: const Duration(hours: 16));

      expect(day.opensAt, equals(const Duration(hours: 16)));
      expect(day.closesAt, equals(const Duration(hours: 22, minutes: 30)));

      for (final ping in day.pings) {
        expect(ping.localTimeOfDay, greaterThanOrEqualTo(day.opensAt),
            reason: '${ping.localLabel} is before the plane landed');
        expect(ping.localTimeOfDay, lessThanOrEqualTo(day.closesAt));
      }
      // 390 minutes holds thirteen 30-minute slots, so all eight fit.
      expect(day.pings.length, equals(8));
      expect(day.unpingedMemberIds, isEmpty);
    });

    test('the slots compress rather than spilling past the close', () {
      final day = assign(opensAt: const Duration(hours: 16));
      final gaps = [
        for (var i = 1; i < day.pings.length; i++)
          day.pings[i].localTimeOfDay.inMinutes -
              day.pings[i - 1].localTimeOfDay.inMinutes,
      ];
      // 390 minutes over eight people is a ~49 minute slot, not the ~109
      // of a full day.
      expect(gaps.reduce((a, b) => a + b) / gaps.length, lessThan(70));
      expect(gaps.every((g) => g > 0), isTrue);
    });

    test('landing before the day opens does not buy an earlier ping', () {
      // An 05:40 red-eye landing is still not a reason to ping someone at
      // 05:40. An itinerary bound narrows the waking day; it never widens
      // it.
      final day = assign(opensAt: const Duration(hours: 5, minutes: 40));
      expect(day.opensAt, equals(PingWindow.standard.start));
      expect(day.pings.first.localTimeOfDay,
          greaterThanOrEqualTo(PingWindow.standard.start));
    });
  });

  group('a shortened last day', () {
    test('flying out at 11:00 runs the day 08:00-11:00', () {
      final day = assign(closesAt: const Duration(hours: 11));

      expect(day.opensAt, equals(PingWindow.standard.start));
      expect(day.closesAt, equals(const Duration(hours: 11)));
      for (final ping in day.pings) {
        expect(ping.localTimeOfDay, greaterThanOrEqualTo(day.opensAt));
        expect(ping.localTimeOfDay, lessThanOrEqualTo(day.closesAt),
            reason: '${ping.localLabel} is after the plane left');
      }
    });

    test('fewer slots than people, and the rest sit the day out', () {
      // 180 minutes at a 30-minute floor is six slots for eight people.
      final day = assign(closesAt: const Duration(hours: 11));
      expect(day.pings.length, equals(6));
      expect(day.unpingedMemberIds.length, equals(2));

      final dealt = day.pings.map((p) => p.memberId).toSet();
      expect(dealt.intersection(day.unpingedMemberIds.toSet()), isEmpty);
      expect(dealt.union(day.unpingedMemberIds.toSet()),
          equals(party.memberIds.toSet()));
      for (final id in day.unpingedMemberIds) {
        expect(day.pingFor(id), isNull);
      }
    });

    test('who sits out rotates with the daily reshuffle', () {
      final missed = <String>{};
      for (var i = 0; i < 20; i++) {
        final day = dayAssignment(
          tripId: 'trip-rotate-out',
          party: party,
          day: TripDay(
            date: DateTime(2026, 9, 3).add(Duration(days: i)),
            utcOffset: Duration.zero,
            closesAt: const Duration(hours: 11),
          ),
        );
        missed.addAll(day.unpingedMemberIds);
      }
      expect(missed.length, greaterThanOrEqualTo(5),
          reason: 'the same people keep missing out');
    });

    test('a late departure does not extend the day past the close', () {
      final day = assign(closesAt: const Duration(hours: 23, minutes: 50));
      expect(day.closesAt, equals(PingWindow.standard.end));
      expect(day.pings.last.localTimeOfDay,
          lessThanOrEqualTo(PingWindow.standard.end));
    });
  });

  group('a day with no room at all', () {
    test('landing at 23:00 pings nobody', () {
      final day = assign(opensAt: const Duration(hours: 23));
      expect(day.pings, isEmpty);
      expect(day.slotCount, equals(0));
      expect(day.unpingedMemberIds, equals(party.memberIds));
    });

    test('twenty minutes left is less than one slot, so no slot', () {
      final day = assign(opensAt: const Duration(hours: 22, minutes: 10));
      expect(day.pings, isEmpty);
    });

    test('exactly thirty minutes left is exactly one slot', () {
      final day = assign(opensAt: const Duration(hours: 22));
      expect(day.pings.length, equals(1));
      expect(day.pings.single.localTimeOfDay,
          greaterThanOrEqualTo(const Duration(hours: 22)));
      expect(day.pings.single.localTimeOfDay,
          lessThanOrEqualTo(day.closesAt));
      expect(day.unpingedMemberIds.length, equals(7));
    });
  });

  test('a whole trip: short first day, full middle, short last day', () {
    final schedule = tripSchedule(
      tripId: 'trip-bali-2026',
      party: party,
      days: tripDays(
        fromDate: DateTime(2026, 9, 3),
        toDate: DateTime(2026, 9, 10),
        utcOffset: const Duration(hours: 8),
        arrival: const Duration(hours: 16),
        departure: const Duration(hours: 11),
      ),
    );

    expect(schedule.length, equals(8));
    expect(schedule.first.opensAt, equals(const Duration(hours: 16)));
    expect(schedule.last.closesAt, equals(const Duration(hours: 11)));

    // Only the two edge days are narrowed; the middle keeps the full
    // waking day.
    for (final day in schedule.sublist(1, schedule.length - 1)) {
      expect(day.opensAt, equals(PingWindow.standard.start));
      expect(day.closesAt, equals(PingWindow.standard.end));
      expect(day.pings.length, equals(party.size));
    }
    expect(schedule.last.pings.length, lessThan(party.size));
  });

  test('a party larger than the day can hold is partly dealt in', () {
    // 870 minutes at a 30-minute floor is 29 slots. A forty-person trip is
    // outside what Cairn is built for, but it must degrade the same way a
    // short day does rather than crowd everyone in.
    final crowd = Party([for (var i = 0; i < 40; i++) 'member-$i']);
    final day = dayAssignment(
      tripId: 'trip-crowd',
      party: crowd,
      day: TripDay(date: DateTime(2026, 9, 3), utcOffset: Duration.zero),
    );
    expect(day.pings.length, equals(29));
    expect(day.unpingedMemberIds.length, equals(11));
    final minutes = day.pings.map((p) => p.localTimeOfDay.inMinutes).toList();
    expect(minutes.toSet().length, equals(minutes.length));
  });

  test('a single-day trip honours both bounds at once', () {
    final days = tripDays(
      fromDate: DateTime(2026, 9, 3),
      toDate: DateTime(2026, 9, 3),
      utcOffset: Duration.zero,
      arrival: const Duration(hours: 10),
      departure: const Duration(hours: 18),
    );
    expect(days.length, equals(1));
    final day = dayAssignment(
      tripId: 'trip-day-trip',
      party: party,
      day: days.single,
    );
    expect(day.opensAt, equals(const Duration(hours: 10)));
    expect(day.closesAt, equals(const Duration(hours: 18)));
    for (final ping in day.pings) {
      expect(ping.localTimeOfDay,
          greaterThanOrEqualTo(const Duration(hours: 10)));
      expect(ping.localTimeOfDay, lessThanOrEqualTo(const Duration(hours: 18)));
    }
  });
}
