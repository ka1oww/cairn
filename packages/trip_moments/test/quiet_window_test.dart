import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('quiet window', () {
    test('default window is 09:00-21:00', () {
      expect(QuietWindow.standard.start, equals(const Duration(hours: 9)));
      expect(QuietWindow.standard.end, equals(const Duration(hours: 21)));
    });

    test('is configurable', () {
      const custom = QuietWindow(
        start: Duration(hours: 8),
        end: Duration(hours: 22),
      );
      expect(custom.span, equals(const Duration(hours: 14)));
    });

    test('rejects an end at or before start', () {
      const invalid = QuietWindow(
        start: Duration(hours: 12),
        end: Duration(hours: 12),
      );
      expect(() => invalid.span, throwsA(isA<AssertionError>()));
    });

    test(
        'pings land in the *trip* timezone even when it is sharply '
        'different from the device/home timezone', () {
      // A trip to Auckland (UTC+12) booked from a device on US Pacific
      // time (nominally UTC-8) is a ~20 hour gap — larger than a full
      // day's quiet window. If the window were applied in the device's
      // timezone instead of the trip's, this ping would land far outside
      // 09:00-21:00 Auckland time.
      const tripUtcOffset = Duration(hours: 12); // Auckland, no DST modeled
      final date = DateTime(2026, 3, 15);

      final moment = dailyMoment(
        tripId: 'trip-nz',
        date: date,
        tripUtcOffset: tripUtcOffset,
      );

      // Reconstruct "wall clock time in the trip's timezone" for the
      // resulting UTC instant and check it's inside the window.
      final localInstant = moment.add(tripUtcOffset);
      final minutesSinceLocalMidnight =
          localInstant.hour * 60 + localInstant.minute;
      expect(
        minutesSinceLocalMidnight,
        inInclusiveRange(9 * 60, 21 * 60),
        reason: 'moment should be 09:00-21:00 Auckland time, not device '
            'time',
      );
    });

    test('negative trip offsets (west of UTC) also stay in-window', () {
      const tripUtcOffset = Duration(hours: -10); // Hawaii
      final date = DateTime(2026, 3, 15);

      for (var i = 0; i < 60; i++) {
        final d = date.add(Duration(days: i));
        final moment = dailyMoment(
          tripId: 'trip-hawaii',
          date: d,
          tripUtcOffset: tripUtcOffset,
        );
        final localInstant = moment.add(tripUtcOffset);
        final minutesSinceLocalMidnight =
            localInstant.hour * 60 + localInstant.minute;
        expect(minutesSinceLocalMidnight, inInclusiveRange(9 * 60, 21 * 60));
      }
    });

    test('scattered pings also respect the trip timezone', () {
      const tripUtcOffset = Duration(hours: 12);
      final date = DateTime(2026, 3, 15);
      final moment = scatteredPing(
        tripId: 'trip-nz',
        date: date,
        deviceId: 'device-1',
        tripUtcOffset: tripUtcOffset,
      );
      final localInstant = moment.add(tripUtcOffset);
      final minutesSinceLocalMidnight =
          localInstant.hour * 60 + localInstant.minute;
      expect(minutesSinceLocalMidnight, inInclusiveRange(9 * 60, 21 * 60));
    });
  });
}
