import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('scattered pings', () {
    const tripId = 'trip-scatter';
    final date = DateTime(2026, 7, 4);
    const offset = Duration(hours: 1);

    test('two different devices on the same trip get different times', () {
      final a = scatteredPing(
        tripId: tripId,
        date: date,
        deviceId: 'device-alice',
        tripUtcOffset: offset,
      );
      final b = scatteredPing(
        tripId: tripId,
        date: date,
        deviceId: 'device-bob',
        tripUtcOffset: offset,
      );
      expect(a, isNot(equals(b)));
    });

    test('many devices on the same trip/day are pairwise distinct', () {
      final times = List.generate(
        30,
        (i) => scatteredPing(
          tripId: tripId,
          date: date,
          deviceId: 'device-$i',
          tripUtcOffset: offset,
        ),
      );
      expect(times.toSet().length, equals(times.length));
    });

    test('a device recomputing its own time gets the same answer back', () {
      final first = scatteredPing(
        tripId: tripId,
        date: date,
        deviceId: 'device-consistent',
        tripUtcOffset: offset,
      );
      final second = scatteredPing(
        tripId: tripId,
        date: date,
        deviceId: 'device-consistent',
        tripUtcOffset: offset,
      );
      expect(first, equals(second));
    });

    test('scattered ping differs from the shared daily moment', () {
      final moment = dailyMoment(
        tripId: tripId,
        date: date,
        tripUtcOffset: offset,
      );
      final scatter = scatteredPing(
        tripId: tripId,
        date: date,
        deviceId: 'device-alice',
        tripUtcOffset: offset,
      );
      expect(scatter, isNot(equals(moment)));
    });

    test('same device, different trips -> different times', () {
      final a = scatteredPing(
        tripId: 'trip-x',
        date: date,
        deviceId: 'device-same',
        tripUtcOffset: offset,
      );
      final b = scatteredPing(
        tripId: 'trip-y',
        date: date,
        deviceId: 'device-same',
        tripUtcOffset: offset,
      );
      expect(a, isNot(equals(b)));
    });
  });
}
