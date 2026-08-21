// The single definition of what the golden values are.
//
// Shared by test/golden_values_test.dart, which pins these lines as
// literals, and tool/print_goldens.dart, which prints them so the same
// computation can be compiled with dart2js and run under Node. Both read
// this one function, so the values the test pins and the values the
// cross-platform check compares can never drift apart.
//
// No test framework import here on purpose: this file has to compile to
// JavaScript.

import 'package:trip_moments/trip_moments.dart';

/// Seeds chosen to be awkward: empty, non-ASCII, and long. An encoding or
/// arithmetic difference between backends shows up here first.
const goldenSeeds = <String>[
  '',
  'trip-fixture-001',
  'trip-alpha/2026-06-15',
  'trip-bravo-🚀',
  'a-very-long-trip-id-1234567890abcdef1234567890abcdef',
];

/// The eight-person party, the trip length and the arrival/departure times
/// the golden schedule is built from.
final goldenParty = Party(const [
  'alice',
  'bob',
  'carla',
  'dan',
  'eve',
  'frank',
  'gita',
  'hal',
]);

/// Every pinned value, rendered as comparable lines.
List<String> goldenLines() {
  final lines = <String>[
    for (final seed in goldenSeeds)
      'digest "$seed" = ${stableDigestValue(seed)}',
    for (final seed in goldenSeeds) 'index8 "$seed" = ${stableIndex(seed, 8)}',
    'fingerprint = ${goldenParty.fingerprint}',
  ];

  final schedule = tripSchedule(
    tripId: 'trip-bali-2026',
    party: goldenParty,
    days: tripDays(
      fromDate: DateTime(2026, 9, 3),
      toDate: DateTime(2026, 9, 6),
      utcOffset: const Duration(hours: 8),
      arrival: const Duration(hours: 16),
      departure: const Duration(hours: 11),
    ),
  );
  for (final day in schedule) {
    for (final ping in day.pings) {
      lines.add('${dateKey(day.date)} slot ${ping.slotIndex} '
          '${ping.memberId} ${ping.localLabel} ${ping.at.toIso8601String()}');
    }
    for (final id in day.unpingedMemberIds) {
      lines.add('${dateKey(day.date)} no-slot $id');
    }
  }
  return lines;
}
