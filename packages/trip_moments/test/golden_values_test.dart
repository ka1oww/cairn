// Golden-value regression table.
//
// The multi-device simulation in determinism_test.dart proves the
// derivation is a pure function of (tripId, party, date) -- but every
// simulated "device" in it still runs on the Dart VM, so it cannot catch a
// backend-specific divergence. This file is what protects that: every line
// below was computed on the Dart VM *and* verified byte-for-byte identical
// when the same computation was compiled with `dart compile js` and run
// under Node. See tool/print_goldens.dart for the exact commands, which
// are four lines and worth re-running whenever lib/src/stable_hash.dart or
// lib/src/slots.dart changes.
//
// These values changed wholesale in the rewrite that replaced the shared
// daily moment with per-person slots dealt across the party. They were
// regenerated deliberately, not repaired to make a failing test pass. If
// they change again without a matching change to the derivation being the
// point of the commit, something is wrong -- see the package README,
// "What must never change".

import 'package:test/test.dart';

import 'golden_fixture.dart';

void main() {
  test('golden values (pinned, VM and dart2js verified)', () {
    expect(goldenLines(), equals(_pinned));
  });

  test('the pinned table actually covers the awkward cases', () {
    // A table that quietly stopped exercising the empty seed, the
    // non-ASCII seed or the short departure day would still pass while
    // protecting much less.
    expect(_pinned.any((l) => l.startsWith('digest "" =')), isTrue);
    expect(_pinned.any((l) => l.contains('🚀')), isTrue);
    expect(_pinned.any((l) => l.contains('no-slot')), isTrue);
    expect(_pinned.length, equals(goldenLines().length));
  });
}

/// Regenerate with: `dart run tool/print_goldens.dart`
const _pinned = <String>[
  'digest "" = 250348346448124',
  'digest "trip-fixture-001" = 190246294933710',
  'digest "trip-alpha/2026-06-15" = 70172693670882',
  'digest "trip-bravo-🚀" = 181497317165802',
  'digest "a-very-long-trip-id-1234567890abcdef1234567890abcdef" = 146831430488401',
  'index8 "" = 4',
  'index8 "trip-fixture-001" = 6',
  'index8 "trip-alpha/2026-06-15" = 2',
  'index8 "trip-bravo-🚀" = 2',
  'index8 "a-very-long-trip-id-1234567890abcdef1234567890abcdef" = 1',
  'fingerprint = 08cc6ef80177e958',
  '2026-09-03 slot 0 alice 16:27 2026-09-03T08:27:00.000Z',
  '2026-09-03 slot 1 carla 17:27 2026-09-03T09:27:00.000Z',
  '2026-09-03 slot 2 bob 18:08 2026-09-03T10:08:00.000Z',
  '2026-09-03 slot 3 hal 18:46 2026-09-03T10:46:00.000Z',
  '2026-09-03 slot 4 frank 19:45 2026-09-03T11:45:00.000Z',
  '2026-09-03 slot 5 dan 20:14 2026-09-03T12:14:00.000Z',
  '2026-09-03 slot 6 eve 21:09 2026-09-03T13:09:00.000Z',
  '2026-09-03 slot 7 gita 21:55 2026-09-03T13:55:00.000Z',
  '2026-09-04 slot 0 gita 09:19 2026-09-04T01:19:00.000Z',
  '2026-09-04 slot 1 bob 10:18 2026-09-04T02:18:00.000Z',
  '2026-09-04 slot 2 hal 12:30 2026-09-04T04:30:00.000Z',
  '2026-09-04 slot 3 carla 14:38 2026-09-04T06:38:00.000Z',
  '2026-09-04 slot 4 dan 16:34 2026-09-04T08:34:00.000Z',
  '2026-09-04 slot 5 eve 17:38 2026-09-04T09:38:00.000Z',
  '2026-09-04 slot 6 alice 19:58 2026-09-04T11:58:00.000Z',
  '2026-09-04 slot 7 frank 22:08 2026-09-04T14:08:00.000Z',
  '2026-09-05 slot 0 frank 09:10 2026-09-05T01:10:00.000Z',
  '2026-09-05 slot 1 eve 11:13 2026-09-05T03:13:00.000Z',
  '2026-09-05 slot 2 hal 12:25 2026-09-05T04:25:00.000Z',
  '2026-09-05 slot 3 carla 14:29 2026-09-05T06:29:00.000Z',
  '2026-09-05 slot 4 alice 15:36 2026-09-05T07:36:00.000Z',
  '2026-09-05 slot 5 bob 18:19 2026-09-05T10:19:00.000Z',
  '2026-09-05 slot 6 dan 19:20 2026-09-05T11:20:00.000Z',
  '2026-09-05 slot 7 gita 21:51 2026-09-05T13:51:00.000Z',
  '2026-09-06 slot 0 hal 08:15 2026-09-06T00:15:00.000Z',
  '2026-09-06 slot 1 frank 08:36 2026-09-06T00:36:00.000Z',
  '2026-09-06 slot 2 alice 09:13 2026-09-06T01:13:00.000Z',
  '2026-09-06 slot 3 gita 09:53 2026-09-06T01:53:00.000Z',
  '2026-09-06 slot 4 bob 10:07 2026-09-06T02:07:00.000Z',
  '2026-09-06 slot 5 eve 10:45 2026-09-06T02:45:00.000Z',
  '2026-09-06 no-slot carla',
  '2026-09-06 no-slot dan',
];
