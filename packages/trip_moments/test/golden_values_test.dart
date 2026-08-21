// Golden-value regression table.
//
// The multi-device simulation in determinism_test.dart proves the
// derivation is a pure function of (tripId, date) — but every simulated
// "device" in that test still runs on the Dart VM. It cannot catch a
// backend-specific divergence (VM vs. dart2js/web), because there is no
// second backend inside that test to disagree with.
//
// This file is what actually protects cross-platform agreement: every
// value below was computed once on the Dart VM *and* independently
// verified to be bit-for-bit identical when the same call was compiled
// with `dart compile js` and run under Node — see the package README,
// "Verified cross-platform", for how and why. If a future change to the
// hashing (algorithm, byte count, arithmetic) ever causes the VM's output
// to drift from what dart2js would produce, this table has no way to
// detect that drift live — it only pins the VM side. That's why the
// arithmetic in lib/src/stable_hash.dart being backend-portable
// (multiplication/addition, not bitwise shifts) is the actual guarantee;
// this test just pins known-good values so a future regression on the VM
// itself is caught immediately.
import 'package:test/test.dart';
import 'package:trip_moments/trip_moments.dart';

void main() {
  group('golden values (pinned, cross-platform verified)', () {
    // (tripId, date, expected unit in [0,1), expected UTC instant at
    // tripUtcOffset = Duration.zero).
    final cases = <(String, DateTime, double, String)>[
      (
        'trip-fixture-001',
        DateTime(2026, 1, 1),
        0.4224609111990369,
        '2026-01-01T14:04:10.311364Z',
      ),
      (
        'trip-alpha',
        DateTime(2026, 6, 15),
        0.09626710350303504,
        '2026-06-15T10:09:18.738871Z',
      ),
      (
        'trip-bravo-🚀',
        DateTime(2027, 12, 31),
        0.5401285745560732,
        '2027-12-31T15:28:53.554421Z',
      ),
      (
        '',
        DateTime(2024, 2, 29),
        0.9018794705160108,
        '2024-02-29T19:49:21.193126Z',
      ),
      (
        'a-very-long-trip-id-1234567890abcdef1234567890abcdef',
        DateTime(2030, 7, 4),
        0.8120379801401854,
        '2030-07-04T18:44:40.040742Z',
      ),
    ];

    for (final (tripId, date, expectedUnit, expectedInstant) in cases) {
      final label = '$tripId @ ${dateKey(date)}';

      test('$label: stableUnitInterval', () {
        final seed = 'trip_moments/v1/daily/$tripId/${dateKey(date)}';
        expect(stableUnitInterval(seed), equals(expectedUnit));
      });

      test('$label: dailyMoment', () {
        final moment = dailyMoment(
          tripId: tripId,
          date: date,
          tripUtcOffset: Duration.zero,
        );
        expect(moment, equals(DateTime.parse(expectedInstant)));
      });
    }
  });
}
