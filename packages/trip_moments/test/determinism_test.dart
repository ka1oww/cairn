// The point of this package: independent devices, sharing only the party
// and the date, compute bit-for-bit identical assignments.
//
// If this test ever fails, the no-server architecture claim is false and
// two people on the same trip will disagree about who is pinged when --
// silently, with no error and nothing in a stack trace.

import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

/// Everything a device would act on, flattened to a comparable string.
String _fingerprintOf(DayAssignment day) => [
      dateKey(day.date),
      day.opensAt.toString(),
      day.closesAt.toString(),
      for (final p in day.pings)
        '${p.slotIndex}|${p.memberId}|${p.at.toIso8601String()}|'
            '${p.localTimeOfDay.inMinutes}',
      'out:${day.unpingedMemberIds.join(",")}',
    ].join('\n');

void main() {
  group('independent devices agree exactly', () {
    test('two devices that share only the party and the date', () {
      // Two separately constructed worlds. Nothing is passed between them:
      // no shared Party instance, no shared TripDay, no shared list.
      // Alice's phone received the roster in join order; Bob's phone
      // received it reversed from a different query.
      final alicesParty =
          Party(const ['alice', 'bob', 'carla', 'dan', 'eve', 'frank']);
      final bobsParty =
          Party(const ['frank', 'eve', 'dan', 'carla', 'bob', 'alice']);

      final alicesDay = TripDay(
        date: DateTime(2026, 9, 3),
        utcOffset: const Duration(hours: 8),
      );
      final bobsDay = TripDay(
        date: DateTime(2026, 9, 3, 14, 22, 7), // a stray time component
        utcOffset: const Duration(hours: 8),
      );

      final alices = dayAssignment(
        tripId: 'trip-bali-2026',
        party: alicesParty,
        day: alicesDay,
      );
      final bobs = dayAssignment(
        tripId: 'trip-bali-2026',
        party: bobsParty,
        day: bobsDay,
      );

      expect(_fingerprintOf(bobs), equals(_fingerprintOf(alices)));
      expect(alices.pings.every((p) => p.at.isUtc), isTrue);
    });

    test('eight devices, computed independently, all land in one place', () {
      final ids = const ['alice', 'bob', 'carla', 'dan', 'eve', 'frank'];
      final results = List.generate(8, (device) {
        // Each "device" builds its own Party from its own shuffled view of
        // the roster, the way eight phones would after eight fetches.
        final rotated = [
          ...ids.skip(device % ids.length),
          ...ids.take(device % ids.length)
        ];
        return dayAssignment(
          tripId: 'trip-eight',
          party: Party(rotated),
          day: TripDay(
            date: DateTime(2026, 7, 14),
            utcOffset: const Duration(hours: -4),
          ),
        );
      });

      for (final r in results) {
        expect(_fingerprintOf(r), equals(_fingerprintOf(results.first)));
      }
    });

    test('a device recomputing later gets the same answer back', () {
      final party = Party(const ['a', 'b', 'c', 'd']);
      final day = TripDay(date: DateTime(2026, 2, 2), utcOffset: Duration.zero);
      final first = dayAssignment(tripId: 't', party: party, day: day);
      final second = dayAssignment(tripId: 't', party: party, day: day);
      expect(_fingerprintOf(second), equals(_fingerprintOf(first)));
    });

    test('a duplicated roster entry does not split two devices', () {
      // One device's fetch double-counted a member. The party canonicalises
      // to the same set, so the schedules still match.
      final clean = Party(const ['a', 'b', 'c']);
      final duplicated = Party(const ['a', 'b', 'b', 'c', 'a']);
      final day = TripDay(date: DateTime(2026, 3, 3), utcOffset: Duration.zero);
      expect(
        _fingerprintOf(dayAssignment(tripId: 't', party: duplicated, day: day)),
        equals(
            _fingerprintOf(dayAssignment(tripId: 't', party: clean, day: day))),
      );
    });

    test('only the calendar fields of the date are read', () {
      final party = Party(const ['a', 'b', 'c']);
      final morning = dayAssignment(
        tripId: 't',
        party: party,
        day: TripDay(
          date: DateTime(2026, 5, 1, 3, 15, 59),
          utcOffset: const Duration(hours: 2),
        ),
      );
      final night = dayAssignment(
        tripId: 't',
        party: party,
        day: TripDay(
          date: DateTime(2026, 5, 1, 23, 0, 0),
          utcOffset: const Duration(hours: 2),
        ),
      );
      expect(_fingerprintOf(night), equals(_fingerprintOf(morning)));
    });

    test('whole schedules match between two devices', () {
      final days = tripDays(
        fromDate: DateTime(2026, 9, 3),
        toDate: DateTime(2026, 9, 17),
        utcOffset: const Duration(hours: 8),
        arrival: const Duration(hours: 16),
        departure: const Duration(hours: 11),
      );
      final a = tripSchedule(
        tripId: 'trip-bali-2026',
        party: Party(const ['alice', 'bob', 'carla', 'dan']),
        days: days,
      );
      final b = tripSchedule(
        tripId: 'trip-bali-2026',
        party: Party(const ['dan', 'carla', 'bob', 'alice']),
        days: days,
      );
      expect(a.length, equals(b.length));
      for (var i = 0; i < a.length; i++) {
        expect(_fingerprintOf(b[i]), equals(_fingerprintOf(a[i])));
      }
    });
  });
}
