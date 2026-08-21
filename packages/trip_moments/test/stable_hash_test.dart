import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('stableDigestValue', () {
    test('is deterministic for a fixed seed', () {
      expect(stableDigestValue('abc'), equals(stableDigestValue('abc')));
    });

    test('always lands in [0, 2^48)', () {
      for (final seed in ['', 'a', 'trip-1/2026-01-01', 'x' * 500, '🚀']) {
        final v = stableDigestValue(seed);
        expect(v, greaterThanOrEqualTo(0));
        expect(v, lessThanOrEqualTo(stableDigestMax));
      }
    });

    test('stays inside the range JavaScript can represent exactly', () {
      // 2^53. Above this dart2js loses precision and two backends would
      // silently derive different schedules -- the failure this package's
      // 48-bit choice exists to prevent.
      const jsExactLimit = 9007199254740992;
      expect(stableDigestMax, lessThan(jsExactLimit));
      expect(stableDigestMax, equals(281474976710655));
    });

    test('different seeds do not collide over a large sample', () {
      final values = List.generate(2000, (i) => stableDigestValue('seed-$i'));
      expect(values.toSet().length, equals(values.length));
    });

    test('a one-character change changes the value', () {
      expect(stableDigestValue('trip-a'),
          isNot(equals(stableDigestValue('trip-b'))));
    });
  });

  group('stableIndex', () {
    test('stays inside the bound', () {
      for (var bound = 1; bound <= 32; bound++) {
        for (var i = 0; i < 100; i++) {
          final v = stableIndex('seed-$i', bound);
          expect(v, greaterThanOrEqualTo(0));
          expect(v, lessThan(bound));
        }
      }
    });

    test('a bound of one always yields zero', () {
      expect(stableIndex('anything', 1), equals(0));
    });

    test('rejects a non-positive bound', () {
      expect(() => stableIndex('x', 0), throwsA(isA<ArgumentError>()));
      expect(() => stableIndex('x', -3), throwsA(isA<ArgumentError>()));
    });

    test('covers its whole range without obvious bias', () {
      final counts = List<int>.filled(8, 0);
      for (var i = 0; i < 4000; i++) {
        counts[stableIndex('bias-$i', 8)]++;
      }
      expect(counts.every((c) => c > 0), isTrue);
      for (final c in counts) {
        expect(c, inInclusiveRange(500 * 0.75, 500 * 1.25));
      }
    });
  });

  group('stableFingerprint', () {
    test('is a fixed 16 characters whatever the input size', () {
      expect(stableFingerprint(['a']).length, equals(16));
      expect(
        stableFingerprint(List.generate(200, (i) => 'member-$i')).length,
        equals(16),
      );
    });

    test('is order-sensitive, so callers must canonicalise first', () {
      // Party sorts before fingerprinting for exactly this reason.
      expect(stableFingerprint(['a', 'b']),
          isNot(equals(stableFingerprint(['b', 'a']))));
    });

    test('cannot be confused by concatenation', () {
      expect(stableFingerprint(['ab', 'c']),
          isNot(equals(stableFingerprint(['a', 'bc']))));
    });
  });

  group('slot geometry', () {
    test('slots tile the day exactly, with no gap and no drift', () {
      const open = 8 * 60;
      const close = 22 * 60 + 30;
      for (var count = 1; count <= 20; count++) {
        var previousEnd = open;
        for (var i = 0; i < count; i++) {
          final start = slotStartMinute(
              openMinute: open,
              closeMinute: close,
              slotCount: count,
              slotIndex: i);
          expect(start, equals(previousEnd));
          previousEnd = slotStartMinute(
              openMinute: open,
              closeMinute: close,
              slotCount: count,
              slotIndex: i + 1);
        }
        expect(previousEnd, equals(close),
            reason: 'the last slot must end exactly on the close');
      }
    });

    test('slot lengths differ by at most one minute', () {
      const open = 8 * 60;
      const close = 22 * 60 + 30;
      for (var count = 1; count <= 20; count++) {
        final lengths = [
          for (var i = 0; i < count; i++)
            slotStartMinute(
                    openMinute: open,
                    closeMinute: close,
                    slotCount: count,
                    slotIndex: i + 1) -
                slotStartMinute(
                    openMinute: open,
                    closeMinute: close,
                    slotCount: count,
                    slotIndex: i),
        ];
        expect(lengths.reduce((a, b) => a > b ? a : b) -
            lengths.reduce((a, b) => a < b ? a : b),
            lessThanOrEqualTo(1));
      }
    });

    test('slotCountFor gives one slot per person until the day runs out', () {
      expect(slotCountFor(partySize: 8, availableMinutes: 870), equals(8));
      expect(slotCountFor(partySize: 8, availableMinutes: 390), equals(8));
      // 180 minutes at a 30-minute floor is six slots, not eight.
      expect(slotCountFor(partySize: 8, availableMinutes: 180), equals(6));
      expect(slotCountFor(partySize: 8, availableMinutes: 30), equals(1));
      expect(slotCountFor(partySize: 8, availableMinutes: 29), equals(0));
      expect(slotCountFor(partySize: 8, availableMinutes: 0), equals(0));
      expect(slotCountFor(partySize: 8, availableMinutes: -60), equals(0));
      expect(minimumSlotMinutes, equals(30));
    });

    test('a dealt slot is never shorter than the minimum', () {
      const open = 8 * 60;
      for (final available in [30, 45, 90, 180, 390, 870]) {
        final count =
            slotCountFor(partySize: 40, availableMinutes: available);
        for (var i = 0; i < count; i++) {
          final length = slotStartMinute(
                  openMinute: open,
                  closeMinute: open + available,
                  slotCount: count,
                  slotIndex: i + 1) -
              slotStartMinute(
                  openMinute: open,
                  closeMinute: open + available,
                  slotCount: count,
                  slotIndex: i);
          expect(length, greaterThanOrEqualTo(minimumSlotMinutes));
        }
      }
    });

    test('the ping always lands strictly inside its own slot', () {
      const open = 8 * 60;
      const close = 22 * 60 + 30;
      for (var count = 1; count <= 20; count++) {
        for (var i = 0; i < count; i++) {
          final start = slotStartMinute(
              openMinute: open,
              closeMinute: close,
              slotCount: count,
              slotIndex: i);
          final end = slotStartMinute(
              openMinute: open,
              closeMinute: close,
              slotCount: count,
              slotIndex: i + 1);
          final minute = pingMinuteForSlot(
              seedBase: 'seed/$count',
              openMinute: open,
              closeMinute: close,
              slotCount: count,
              slotIndex: i);
          expect(minute, greaterThan(start));
          expect(minute, lessThan(end));
        }
      }
    });
  });

  group('dealOrder', () {
    test('is a permutation of the whole party', () {
      for (var size = 1; size <= 30; size++) {
        final order = dealOrder(seedBase: 'seed-$size', partySize: size);
        expect(order.length, equals(size));
        expect(order.toSet().length, equals(size));
        expect(order.every((i) => i >= 0 && i < size), isTrue);
      }
    });

    test('is deterministic', () {
      expect(dealOrder(seedBase: 'x', partySize: 12),
          equals(dealOrder(seedBase: 'x', partySize: 12)));
    });

    test('a different seed deals differently', () {
      expect(dealOrder(seedBase: 'x', partySize: 12),
          isNot(equals(dealOrder(seedBase: 'y', partySize: 12))));
    });
  });
}
