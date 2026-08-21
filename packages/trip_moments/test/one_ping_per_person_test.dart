// One interruption per person per day, and never a second.
//
// Cairn's whole permission ask rests on this: it interrupts once a day and
// never otherwise. The package this file replaced fired twice -- a shared
// daily moment and a scattered ping -- and both mechanics are retired. See
// docs/decisions/2026-08-21-first-calls.md, "The second solo ping is cut".

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

  group('one ping per person per day', () {
    test('the ceiling is one, not two', () {
      expect(pingsPerPersonPerDay, equals(1));
    });

    test('every member appears exactly once in a full day', () {
      final day = dayAssignment(
        tripId: 'trip-once',
        party: party,
        day: TripDay(date: DateTime(2026, 9, 4), utcOffset: Duration.zero),
      );

      final ids = day.pings.map((p) => p.memberId).toList();
      expect(ids.length, equals(party.size));
      expect(ids.toSet().length, equals(ids.length),
          reason: 'a member cannot hold two slots');
      expect(ids.toSet(), equals(party.memberIds.toSet()));
      expect(day.unpingedMemberIds, isEmpty);
    });

    test('holds across every day of a long trip', () {
      final schedule = tripSchedule(
        tripId: 'trip-long',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 1, 1),
          toDate: DateTime(2026, 2, 28),
          utcOffset: const Duration(hours: 8),
        ),
      );
      expect(schedule.length, equals(59));

      for (final day in schedule) {
        for (final id in party.memberIds) {
          // pingFor answers with a single Ping, not a collection: there is
          // structurally nowhere for a second one to live.
          expect(day.pingFor(id), isNotNull);
        }
        expect(day.pings.length, equals(party.size));
        expect(day.pings.map((p) => p.memberId).toSet().length,
            equals(party.size));
      }
    });

    test('a member\'s own line through the trip is one ping per day', () {
      final schedule = tripSchedule(
        tripId: 'trip-mine',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 5, 1),
          toDate: DateTime(2026, 5, 14),
          utcOffset: const Duration(hours: 2),
        ),
      );
      final mine = pingsForMember(schedule, 'carla');

      expect(mine.length, equals(schedule.length));
      expect(mine.every((p) => p.memberId == 'carla'), isTrue);
      // One per calendar day, no day doubled up.
      final dayKeys = mine.map((p) => p.at.toIso8601String().split('T').first);
      expect(dayKeys.toSet().length, equals(mine.length));
    });

    test('someone not on the trip gets no ping at all', () {
      final day = dayAssignment(
        tripId: 'trip-once',
        party: party,
        day: TripDay(date: DateTime(2026, 9, 4), utcOffset: Duration.zero),
      );
      expect(day.pingFor('someone-else'), isNull);
    });
  });
}
