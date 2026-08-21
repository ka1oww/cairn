// Nobody owns the breakfast slot for the whole trip.
//
// The permutation is reseeded with the date, so the same party gets a
// different deal every day. Without this the schedule would be fair in
// aggregate and deeply unfair in practice: one person pinged before
// breakfast every single morning of a two-week trip.

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

  List<String> orderOn(DateTime date, {String tripId = 'trip-shuffle'}) {
    return dayAssignment(
      tripId: tripId,
      party: party,
      day: TripDay(date: date, utcOffset: Duration.zero),
    ).pings.map((p) => p.memberId).toList();
  }

  group('the deal reshuffles daily', () {
    test('consecutive days never repeat the same order', () {
      // 8! is 40320, so a repeat is possible in principle. Across 200
      // consecutive pairs there are none, which is the practical claim.
      final start = DateTime(2026, 1, 1);
      var repeats = 0;
      for (var i = 1; i <= 200; i++) {
        final before = orderOn(start.add(Duration(days: i - 1)));
        final after = orderOn(start.add(Duration(days: i)));
        if (before.join(',') == after.join(',')) repeats++;
      }
      expect(repeats, equals(0));
    });

    test('the first slot rotates through the party over a fortnight', () {
      final start = DateTime(2026, 6, 1);
      final breakfastHolders = {
        for (var i = 0; i < 14; i++) orderOn(start.add(Duration(days: i))).first
      };
      expect(breakfastHolders.length, greaterThanOrEqualTo(4),
          reason: 'the early slot is being hoarded by too few people');
    });

    test('no member is stuck in one slot across a fortnight', () {
      final start = DateTime(2026, 6, 1);
      final slotsSeen = <String, Set<int>>{
        for (final id in party.memberIds) id: <int>{},
      };
      for (var i = 0; i < 14; i++) {
        final order = orderOn(start.add(Duration(days: i)));
        for (var slot = 0; slot < order.length; slot++) {
          slotsSeen[order[slot]]!.add(slot);
        }
      }
      for (final entry in slotsSeen.entries) {
        expect(entry.value.length, greaterThan(1),
            reason: '${entry.key} held the same slot every day');
      }
    });

    test('over a long run each member visits every slot', () {
      final start = DateTime(2026, 1, 1);
      final slotsSeen = <String, Set<int>>{
        for (final id in party.memberIds) id: <int>{},
      };
      for (var i = 0; i < 400; i++) {
        final order = orderOn(start.add(Duration(days: i)));
        for (var slot = 0; slot < order.length; slot++) {
          slotsSeen[order[slot]]!.add(slot);
        }
      }
      for (final entry in slotsSeen.entries) {
        expect(entry.value.length, equals(party.size),
            reason: '${entry.key} never reached some slots');
      }
    });

    test('a different trip with the same party deals differently', () {
      final date = DateTime(2026, 9, 3);
      expect(
        orderOn(date, tripId: 'trip-one'),
        isNot(equals(orderOn(date, tripId: 'trip-two'))),
      );
    });

    test('a different party deals differently on the same day', () {
      final date = DateTime(2026, 9, 3);
      final withoutHal = Party(party.memberIds.take(7));
      final a = dayAssignment(
        tripId: 'trip-party-change',
        party: party,
        day: TripDay(date: date, utcOffset: Duration.zero),
      );
      final b = dayAssignment(
        tripId: 'trip-party-change',
        party: withoutHal,
        day: TripDay(date: date, utcOffset: Duration.zero),
      );
      expect(b.pings.length, equals(7));
      expect(
        a.pings.take(7).map((p) => p.memberId).toList(),
        isNot(equals(b.pings.map((p) => p.memberId).toList())),
        reason: 'the party is part of the seed; changing it must re-deal',
      );
    });
  });
}
