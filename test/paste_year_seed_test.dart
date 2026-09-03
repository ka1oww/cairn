// The year answer, seeded honestly. `useYear` used to hand the parser a bare
// 1 January of the chosen year as the trip start, and a year-straddling plan
// paid for it: its January days sat eleven months "before" the invented
// start, outside the parser's roll-forward window, and every one of them was
// dated a year early. The seed is now the plan's own first year-less date in
// the chosen year, so the parser rolls the calendar forward exactly as it
// would have if the plan had named its year.
//
// Model-half harness, same as paste_editor_test.dart: `PasteFlow` through a
// bare ProviderContainer, because this is date arithmetic, not interface.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/app_state/paste_flow.dart';

/// A New Year trip with no year anywhere — the shape the old seed broke.
const newYearPlan = '''
30 December - Osaka
- Dotonbori

31 December - Osaka
- Countdown

1 January - Kyoto
- Hatsumode at Fushimi Inari
''';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [todayProvider.overrideWithValue(DateTime.utc(2026, 6, 14))],
    );
    addTearDown(container.dispose);
  });

  ItineraryReview read() =>
      (container.read(pasteFlowProvider) as PasteReview).review;

  PasteFlow flow() => container.read(pasteFlowProvider.notifier);

  test('a year-straddling plan dates January next year, not eleven months '
      'ago', () {
    flow().parse(newYearPlan);
    expect(
      read().days.every((d) => d.date == null),
      isTrue,
      reason: 'no year anywhere, so nothing binds before the answer',
    );

    flow().useYear(2026);

    final days = read().days;
    expect(days[0].date, DateTime(2026, 12, 30));
    expect(days[1].date, DateTime(2026, 12, 31));
    expect(
      days[2].date,
      DateTime(2027, 1, 1),
      reason:
          'the January day rolls forward past the year end; the old '
          '1 January seed dated it 1 January 2026',
    );
  });

  test('a mid-year plan is unchanged by the honest seed', () {
    flow().parse(
      '14 June - Tokyo\n- Senso-ji\n15 June - Kyoto\n- Fushimi '
      'Inari',
    );
    flow().useYear(2027);

    final days = read().days;
    expect(days[0].date, DateTime(2027, 6, 14));
    expect(days[1].date, DateTime(2027, 6, 15));
  });
}
