import 'package:trip_moments/trip_moments.dart';
import 'package:test/test.dart';

void main() {
  group('stableUnitInterval', () {
    test('is deterministic for a fixed seed', () {
      expect(stableUnitInterval('abc'), equals(stableUnitInterval('abc')));
    });

    test('always returns a value in [0, 1)', () {
      for (final seed in ['', 'a', 'trip-1/2026-01-01', 'x' * 500]) {
        final v = stableUnitInterval(seed);
        expect(v, greaterThanOrEqualTo(0.0));
        expect(v, lessThan(1.0));
      }
    });

    test('different seeds produce different values (no obvious collisions)',
        () {
      final values = List.generate(200, (i) => stableUnitInterval('seed-$i'));
      expect(values.toSet().length, equals(values.length));
    });
  });
}
