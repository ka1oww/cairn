import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('Party canonicalisation', () {
    test('sorts, so the order a device fetched the roster in cannot matter',
        () {
      final a = Party(const ['carla', 'alice', 'bob']);
      final b = Party(const ['bob', 'carla', 'alice']);
      expect(a.memberIds, equals(['alice', 'bob', 'carla']));
      expect(b.memberIds, equals(a.memberIds));
      expect(b.fingerprint, equals(a.fingerprint));
    });

    test('de-duplicates', () {
      final party = Party(const ['a', 'b', 'a', 'b', 'c']);
      expect(party.memberIds, equals(['a', 'b', 'c']));
      expect(party.size, equals(3));
    });

    test('rejects an empty party', () {
      expect(() => Party(const []), throwsA(isA<ArgumentError>()));
    });

    test('rejects an empty member id', () {
      // An empty id would let two different parties fingerprint alike.
      expect(() => Party(const ['a', '']), throwsA(isA<ArgumentError>()));
    });

    test('membership is queryable', () {
      final party = Party(const ['alice', 'bob']);
      expect(party.contains('alice'), isTrue);
      expect(party.contains('zoe'), isFalse);
    });

    test('a changed roster changes the fingerprint', () {
      expect(Party(const ['a', 'b']).fingerprint,
          isNot(equals(Party(const ['a', 'b', 'c']).fingerprint)));
    });

    test('the member list cannot be mutated after construction', () {
      final party = Party(const ['a', 'b']);
      expect(() => party.memberIds.add('c'), throwsUnsupportedError);
    });
  });

  group('tripDays', () {
    test('produces one day per calendar day, inclusive', () {
      final days = tripDays(
        fromDate: DateTime(2026, 4, 1),
        toDate: DateTime(2026, 4, 5),
        utcOffset: Duration.zero,
      );
      expect(days.length, equals(5));
      expect(dateKey(days.first.date), equals('2026-04-01'));
      expect(dateKey(days.last.date), equals('2026-04-05'));
    });

    test('crosses a month and a year boundary', () {
      expect(
        tripDays(
          fromDate: DateTime(2026, 12, 30),
          toDate: DateTime(2027, 1, 2),
          utcOffset: Duration.zero,
        ).map((d) => dateKey(d.date)),
        equals(['2026-12-30', '2026-12-31', '2027-01-01', '2027-01-02']),
      );
    });

    test('handles a leap day', () {
      expect(
        tripDays(
          fromDate: DateTime(2028, 2, 27),
          toDate: DateTime(2028, 3, 1),
          utcOffset: Duration.zero,
        ).map((d) => dateKey(d.date)),
        equals(['2028-02-27', '2028-02-28', '2028-02-29', '2028-03-01']),
      );
    });

    test('empty when toDate is before fromDate', () {
      expect(
        tripDays(
          fromDate: DateTime(2026, 4, 5),
          toDate: DateTime(2026, 4, 1),
          utcOffset: Duration.zero,
        ),
        isEmpty,
      );
    });

    test('arrival and departure apply only to the first and last day', () {
      final days = tripDays(
        fromDate: DateTime(2026, 4, 1),
        toDate: DateTime(2026, 4, 4),
        utcOffset: Duration.zero,
        arrival: const Duration(hours: 16),
        departure: const Duration(hours: 11),
      );
      expect(days.first.opensAt, equals(const Duration(hours: 16)));
      expect(days.first.closesAt, isNull);
      expect(days[1].opensAt, isNull);
      expect(days[1].closesAt, isNull);
      expect(days.last.opensAt, isNull);
      expect(days.last.closesAt, equals(const Duration(hours: 11)));
    });
  });

  group('tripSchedule', () {
    final party = Party(const ['alice', 'bob', 'carla', 'dan']);

    test('returns one assignment per day, in order', () {
      final schedule = tripSchedule(
        tripId: 'trip-sched',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 4, 1),
          toDate: DateTime(2026, 4, 5),
          utcOffset: Duration.zero,
        ),
      );
      expect(schedule.length, equals(5));
      for (var i = 1; i < schedule.length; i++) {
        expect(schedule[i].date.isAfter(schedule[i - 1].date), isTrue);
      }
    });

    test('matches calling dayAssignment directly, day by day', () {
      const offset = Duration(hours: 3);
      final days = tripDays(
        fromDate: DateTime(2026, 4, 1),
        toDate: DateTime(2026, 4, 10),
        utcOffset: offset,
      );
      final schedule =
          tripSchedule(tripId: 'trip-match', party: party, days: days);

      for (var i = 0; i < days.length; i++) {
        final direct = dayAssignment(
          tripId: 'trip-match',
          party: party,
          day: days[i],
        );
        expect(
          schedule[i].pings.map((p) => '${p.memberId}@${p.at}').toList(),
          equals(direct.pings.map((p) => '${p.memberId}@${p.at}').toList()),
        );
      }
    });

    test('an empty itinerary yields an empty schedule', () {
      expect(tripSchedule(tripId: 't', party: party, days: const []), isEmpty);
    });

    test('the whole trip registers in one offline pass', () {
      // The app opens once, computes every instant for the rest of the
      // trip, hands them to the OS scheduler and never calls this package
      // -- or a server -- again.
      final schedule = tripSchedule(
        tripId: 'trip-one-pass',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 8, 21),
          toDate: DateTime(2026, 8, 30),
          utcOffset: const Duration(hours: 8),
        ),
      );
      final mine = pingsForMember(schedule, 'bob');
      expect(mine.length, equals(10));
      expect(mine.every((p) => p.at.isUtc), isTrue);
      for (var i = 1; i < mine.length; i++) {
        expect(mine[i].at.isAfter(mine[i - 1].at), isTrue);
      }
    });

    test('pingsForMember skips days that had no slot for them', () {
      final bigParty = Party([for (var i = 0; i < 8; i++) 'member-$i']);
      final schedule = tripSchedule(
        tripId: 'trip-partial',
        party: bigParty,
        days: [
          TripDay(
            date: DateTime(2026, 9, 3),
            utcOffset: Duration.zero,
            closesAt: const Duration(hours: 11), // only six slots
          ),
          TripDay(date: DateTime(2026, 9, 4), utcOffset: Duration.zero),
        ],
      );

      final missed = schedule.first.unpingedMemberIds.first;
      expect(pingsForMember(schedule, missed).length, equals(1));
      expect(pingsForMember(schedule, missed).single.at.day, equals(4));
    });

    test('pingsForMember returns nothing for someone not on the trip', () {
      final schedule = tripSchedule(
        tripId: 't',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 4, 1),
          toDate: DateTime(2026, 4, 3),
          utcOffset: Duration.zero,
        ),
      );
      expect(pingsForMember(schedule, 'stranger'), isEmpty);
    });

    test('the returned schedule cannot be mutated', () {
      final schedule = tripSchedule(
        tripId: 't',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 4, 1),
          toDate: DateTime(2026, 4, 2),
          utcOffset: Duration.zero,
        ),
      );
      expect(() => schedule.first.pings.clear(), throwsUnsupportedError);
    });
  });

  group('Ping display', () {
    test('localLabel is HH:MM in the trip\'s clock', () {
      final ping = Ping(
        memberId: 'alice',
        slotIndex: 0,
        at: DateTime.utc(2026, 1, 1, 6, 5),
        localTimeOfDay: const Duration(hours: 8, minutes: 5),
      );
      expect(ping.localLabel, equals('08:05'));
      expect(ping.toString(), contains('alice'));
    });

    test('localLabel pads both fields', () {
      Ping at(Duration d) => Ping(
            memberId: 'x',
            slotIndex: 0,
            at: DateTime.utc(2026, 1, 1),
            localTimeOfDay: d,
          );
      expect(at(const Duration(hours: 8)).localLabel, equals('08:00'));
      expect(at(const Duration(hours: 22, minutes: 30)).localLabel,
          equals('22:30'));
      expect(at(const Duration(hours: 9, minutes: 7)).localLabel,
          equals('09:07'));
    });
  });
}
