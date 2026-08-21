// The crux of the rewrite: slots are dealt across the party, not hashed
// independently per device.
//
// Independent hashing -- what this package did before -- permits two
// people to land on the same minute and permits the whole party to bunch
// into one part of the day, because nothing coordinates the draws. Dealing
// a permutation of slots over the party makes both impossible by
// construction rather than improbable.

import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

/// Consecutive gaps, in minutes, for one day's pings.
List<int> _gaps(DayAssignment day) => [
      for (var i = 1; i < day.pings.length; i++)
        day.pings[i].localTimeOfDay.inMinutes -
            day.pings[i - 1].localTimeOfDay.inMinutes,
    ];

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

  group('no two members of a party collide', () {
    test('over two months of full days, no minute is ever shared', () {
      final schedule = tripSchedule(
        tripId: 'trip-collide',
        party: party,
        days: tripDays(
          fromDate: DateTime(2026, 1, 1),
          toDate: DateTime(2026, 3, 1),
          utcOffset: const Duration(hours: 8),
        ),
      );

      for (final day in schedule) {
        final instants = day.pings.map((p) => p.at).toList();
        expect(instants.toSet().length, equals(instants.length),
            reason: 'two people were pinged at the same instant on '
                '${dateKey(day.date)}');
        final minutes =
            day.pings.map((p) => p.localTimeOfDay.inMinutes).toList();
        expect(minutes.toSet().length, equals(minutes.length));
      }
    });

    test('holds for party sizes from 1 to 24', () {
      for (var size = 1; size <= 24; size++) {
        final p = Party([for (var i = 0; i < size; i++) 'member-$i']);
        final day = dayAssignment(
          tripId: 'trip-sizes',
          party: p,
          day: TripDay(date: DateTime(2026, 7, 7), utcOffset: Duration.zero),
        );
        final minutes =
            day.pings.map((p) => p.localTimeOfDay.inMinutes).toList();
        expect(minutes.toSet().length, equals(minutes.length),
            reason: 'collision at party size $size');
        // 14.5h holds 29 slots of 30 minutes, so every size here fits.
        expect(day.pings.length, equals(size));
      }
    });

    test('pings come back in strict time order', () {
      final day = dayAssignment(
        tripId: 'trip-order',
        party: party,
        day: TripDay(date: DateTime(2026, 4, 2), utcOffset: Duration.zero),
      );
      for (var i = 1; i < day.pings.length; i++) {
        expect(day.pings[i].at.isAfter(day.pings[i - 1].at), isTrue);
        expect(day.pings[i].slotIndex, equals(i));
      }
    });
  });

  group('the party spreads across the day rather than bunching', () {
    test('exactly one ping falls inside each equal slot of the day', () {
      // This is the structural statement of "not clustered": with eight
      // people the day is cut into eight equal pieces and each piece holds
      // exactly one person. No amount of hash luck can put two in one
      // piece or leave one empty.
      const window = PingWindow.standard;
      final open = window.start.inMinutes;
      final close = window.end.inMinutes;

      for (var i = 0; i < 120; i++) {
        final day = dayAssignment(
          tripId: 'trip-spread',
          party: party,
          day: TripDay(
            date: DateTime(2026, 1, 1).add(Duration(days: i)),
            utcOffset: Duration.zero,
          ),
        );

        final occupancy = List<int>.filled(party.size, 0);
        for (final ping in day.pings) {
          final minute = ping.localTimeOfDay.inMinutes;
          expect(minute, greaterThanOrEqualTo(open));
          expect(minute, lessThanOrEqualTo(close));
          final slot = ((minute - open) * party.size) ~/ (close - open);
          occupancy[slot < party.size ? slot : party.size - 1]++;
        }
        expect(occupancy, everyElement(equals(1)),
            reason: 'day $i put two people in one slot, or left one empty');
      }
    });

    test('consecutive pings are never closer than 40% of a slot', () {
      // The floor that stops two people being interrupted back to back at
      // a slot boundary. It is a fraction of the slot, so it scales with
      // how crowded the day is -- see _slotInsetPercent in lib/src/slots.
      const window = PingWindow.standard;
      final slotMinutes = window.span.inMinutes / party.size;

      for (var i = 0; i < 120; i++) {
        final day = dayAssignment(
          tripId: 'trip-gaps',
          party: party,
          day: TripDay(
            date: DateTime(2026, 3, 1).add(Duration(days: i)),
            utcOffset: Duration.zero,
          ),
        );
        for (final gap in _gaps(day)) {
          expect(gap, greaterThanOrEqualTo(slotMinutes * 0.4 - 2));
          expect(gap, lessThanOrEqualTo(slotMinutes * 1.6 + 2));
        }
      }
    });

    test('over many days the party covers the whole day, edge to edge', () {
      // Guards the other failure mode: slots that are individually spread
      // but collectively hug the middle, leaving breakfast and dinner
      // permanently unphotographed.
      const window = PingWindow.standard;
      final open = window.start.inMinutes;
      final close = window.end.inMinutes;

      final minutes = <int>[];
      for (var i = 0; i < 200; i++) {
        final day = dayAssignment(
          tripId: 'trip-coverage',
          party: party,
          day: TripDay(
            date: DateTime(2026, 1, 1).add(Duration(days: i)),
            utcOffset: Duration.zero,
          ),
        );
        minutes.addAll(day.pings.map((p) => p.localTimeOfDay.inMinutes));
      }
      minutes.sort();

      // Earliest ping is inside the first half hour of the waking day, and
      // the latest is inside the last half hour, so the 22:30 close is
      // genuinely reaching dinner rather than being decorative.
      expect(minutes.first, lessThan(open + 30));
      expect(minutes.last, greaterThan(close - 30));

      // No decile of the day is starved or crowded.
      const buckets = 10;
      final counts = List<int>.filled(buckets, 0);
      for (final m in minutes) {
        var idx = ((m - open) * buckets) ~/ (close - open);
        if (idx >= buckets) idx = buckets - 1;
        counts[idx]++;
      }
      final expected = minutes.length / buckets;
      for (final count in counts) {
        expect(count, inInclusiveRange(expected * 0.5, expected * 1.5));
      }
    });
  });
}
