import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('tripSchedule', () {
    test('produces one DayPings per calendar day, inclusive', () {
      final schedule = tripSchedule(
        tripId: 'trip-sched',
        deviceId: 'device-1',
        fromDate: DateTime(2026, 4, 1),
        toDate: DateTime(2026, 4, 5),
        tripUtcOffset: Duration.zero,
      );
      expect(schedule.length, equals(5));
      expect(schedule.first.date, equals(DateTime(2026, 4, 1)));
      expect(schedule.last.date, equals(DateTime(2026, 4, 5)));
    });

    test('empty range when toDate is before fromDate', () {
      final schedule = tripSchedule(
        tripId: 'trip-sched',
        deviceId: 'device-1',
        fromDate: DateTime(2026, 4, 5),
        toDate: DateTime(2026, 4, 1),
        tripUtcOffset: Duration.zero,
      );
      expect(schedule, isEmpty);
    });

    test('single-day range produces exactly one day', () {
      final schedule = tripSchedule(
        tripId: 'trip-sched',
        deviceId: 'device-1',
        fromDate: DateTime(2026, 4, 1),
        toDate: DateTime(2026, 4, 1),
        tripUtcOffset: Duration.zero,
      );
      expect(schedule.length, equals(1));
    });

    test('matches calling dailyMoment/scatteredPing directly, day by day', () {
      const tripId = 'trip-sched-match';
      const deviceId = 'device-match';
      const offset = Duration(hours: 3);
      final schedule = tripSchedule(
        tripId: tripId,
        deviceId: deviceId,
        fromDate: DateTime(2026, 4, 1),
        toDate: DateTime(2026, 4, 10),
        tripUtcOffset: offset,
      );

      for (final day in schedule) {
        expect(
          day.dailyMoment,
          equals(dailyMoment(
            tripId: tripId,
            date: day.date,
            tripUtcOffset: offset,
          )),
        );
        expect(
          day.scatteredPing,
          equals(scatteredPing(
            tripId: tripId,
            date: day.date,
            deviceId: deviceId,
            tripUtcOffset: offset,
          )),
        );
      }
    });

    test(
        'two devices scheduling the same trip get different scatter '
        'sequences but identical daily moments', () {
      const tripId = 'trip-two-devices';
      const offset = Duration(hours: -4);
      final scheduleA = tripSchedule(
        tripId: tripId,
        deviceId: 'device-A',
        fromDate: DateTime(2026, 6, 1),
        toDate: DateTime(2026, 6, 7),
        tripUtcOffset: offset,
      );
      final scheduleB = tripSchedule(
        tripId: tripId,
        deviceId: 'device-B',
        fromDate: DateTime(2026, 6, 1),
        toDate: DateTime(2026, 6, 7),
        tripUtcOffset: offset,
      );

      for (var i = 0; i < scheduleA.length; i++) {
        expect(scheduleA[i].dailyMoment, equals(scheduleB[i].dailyMoment));
        expect(
          scheduleA[i].scatteredPing,
          isNot(equals(scheduleB[i].scatteredPing)),
        );
      }
    });

    test(
        'registering "every remaining day" needs only one pass, no '
        'further calls needed for the rest of the trip', () {
      // Simulates: app opens once, computes the whole remaining schedule,
      // and could hand every instant to a local-notification scheduler in
      // one go without ever calling this package (or a server) again.
      final schedule = tripSchedule(
        tripId: 'trip-one-pass',
        deviceId: 'device-1',
        fromDate: DateTime(2026, 8, 21), // "today"
        toDate: DateTime(2026, 8, 30), // trip end
        tripUtcOffset: Duration(hours: 8),
      );
      final allInstants = schedule.expand((d) => d.instants).toList();
      expect(allInstants.length, equals(schedule.length * 2));
      expect(allInstants.every((i) => i.isUtc), isTrue);
    });
  });
}
