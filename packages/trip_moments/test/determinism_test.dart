// The point of this package: several independent "devices", given nothing
// but the trip id and the date, compute exactly the same daily moment.
// If this test ever fails, the no-server architecture claim is false.

import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('daily moment determinism (the point of this package)', () {
    test('N independent "devices" agree exactly on the same trip/date', () {
      const tripId = 'trip-bali-2026';
      final date = DateTime(2026, 9, 3);
      const tripUtcOffset = Duration(hours: 8); // WITA

      // Simulate 8 independent devices, none of which see each other's
      // work: each calls the pure function fresh with only tripId + date.
      final results = List.generate(
        8,
        (_) => dailyMoment(
          tripId: tripId,
          date: date,
          tripUtcOffset: tripUtcOffset,
        ),
      );

      for (final r in results) {
        expect(r, equals(results.first));
        expect(r.isUtc, isTrue);
      }
    });

    test('same trip, same date -> same instant, called repeatedly', () {
      final a = dailyMoment(
        tripId: 'trip-a',
        date: DateTime(2026, 1, 10),
        tripUtcOffset: Duration.zero,
      );
      final b = dailyMoment(
        tripId: 'trip-a',
        date: DateTime(2026, 1, 10),
        tripUtcOffset: Duration.zero,
      );
      expect(a, equals(b));
    });

    test('different trips, same date -> different instants', () {
      final date = DateTime(2026, 5, 1);
      final a = dailyMoment(
          tripId: 'trip-a', date: date, tripUtcOffset: Duration.zero);
      final b = dailyMoment(
          tripId: 'trip-b', date: date, tripUtcOffset: Duration.zero);
      expect(a, isNot(equals(b)));
    });

    test('same trip, different dates -> different instants', () {
      const tripId = 'trip-a';
      final a = dailyMoment(
        tripId: tripId,
        date: DateTime(2026, 5, 1),
        tripUtcOffset: Duration.zero,
      );
      final b = dailyMoment(
        tripId: tripId,
        date: DateTime(2026, 5, 2),
        tripUtcOffset: Duration.zero,
      );
      expect(a, isNot(equals(b)));
    });

    test('only the calendar fields of the date are read', () {
      const tripId = 'trip-a';
      const offset = Duration(hours: 2);
      final a = dailyMoment(
        tripId: tripId,
        date: DateTime(2026, 5, 1, 3, 15, 59),
        tripUtcOffset: offset,
      );
      final b = dailyMoment(
        tripId: tripId,
        date: DateTime(2026, 5, 1, 23, 0, 0),
        tripUtcOffset: offset,
      );
      expect(a, equals(b));
    });

    test('regression: pinned output for a known (tripId, date, offset)', () {
      // Frozen expectation, computed once from this implementation and
      // pinned here so a future accidental change to the hash/derivation
      // is caught by CI rather than discovered mid-trip. See README
      // "What must never change".
      final moment = dailyMoment(
        tripId: 'trip-fixture-001',
        date: DateTime(2026, 1, 1),
        tripUtcOffset: Duration.zero,
      );
      expect(moment, equals(_pinnedFixtureMoment));
    });
  });
}

// See the regression test above. Computed once from this implementation.
final _pinnedFixtureMoment = DateTime.parse('2026-01-01T14:04:10.311364Z');
