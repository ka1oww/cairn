import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('two pings a day, hard maximum', () {
    test('maxPingsPerDay is exactly 2', () {
      expect(maxPingsPerDay, equals(2));
    });

    test('DayPings.instants can never exceed maxPingsPerDay', () {
      final day = DayPings(
        date: DateTime(2026, 1, 1),
        dailyMoment: DateTime.utc(2026, 1, 1, 10),
        scatteredPing: DateTime.utc(2026, 1, 1, 14),
      );
      // Structural guarantee: DayPings has exactly two DateTime fields, so
      // .instants is always exactly this length. This assertion pins that
      // guarantee so it fails loudly if the type is ever widened without
      // updating maxPingsPerDay.
      expect(day.instants.length, equals(maxPingsPerDay));
    });

    test('no day in a full trip schedule ever produces more than 2 pings', () {
      final schedule = tripSchedule(
        tripId: 'trip-ceiling',
        deviceId: 'device-1',
        fromDate: DateTime(2026, 1, 1),
        toDate: DateTime(2026, 1, 31),
        tripUtcOffset: Duration.zero,
      );

      expect(schedule, isNotEmpty);
      for (final day in schedule) {
        expect(day.instants.length, lessThanOrEqualTo(maxPingsPerDay));
        expect(day.instants.length, equals(2));
        expect(day.instants.toSet().length, equals(day.instants.length),
            reason: 'the two pings on a given day should not coincide');
      }
    });
  });
}
