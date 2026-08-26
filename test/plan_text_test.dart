// The plan said back as text, and read again — the round trip
// `lib/logic/plan_text.dart` exists to survive.
//
// Pure by design: rendering is a function of days, re-reading is the parser,
// and the merge is a function of both, so nothing here needs a database or a
// widget tree. What it pins is the pair of ways the round trip used to lose
// something on the way out: a bare proper-noun stop re-read as a day header,
// and a time the person set by hand read back off the words instead.
import 'package:cairn/logic/plan_text.dart';
import 'package:cairn/logic/repaste_merge.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/app_state/paste_flow.dart';

RepasteMergeResult reread(List<ConfirmedDay> plan) => mergeRepaste(
  current: plan,
  repasted: ip.parseItinerary(renderPlanText(plan)).days,
);

void main() {
  test('a bare proper-noun stop above a timed one is still a stop', () {
    // The exact trap: unbulleted, `Ueno Park` is every-word-capitalized with
    // a timed line under it, which is how the parser recognizes a bare place
    // name acting as a day header. Rendered without a bullet it opened a
    // second day, emptied day 1 and stranded day 1's photographs.
    final plan = [
      ConfirmedDay(
        number: 1,
        place: 'Tokyo',
        stops: [
          Stop(text: 'Ueno Park'),
          Stop(text: '10:00 Coffee', time: ClockTime(10, 0)),
        ],
      ),
    ];

    final read = ip.parseItinerary(renderPlanText(plan));

    expect(read.days, hasLength(1));
    expect(read.days.single.place, 'Tokyo');
    expect(
      [for (final s in read.days.single.stops) s.text],
      ['Ueno Park', '10:00 Coffee'],
    );

    final merged = reread(plan);
    expect(merged.days, hasLength(1));
    expect(merged.days.single.day, same(plan.single));
    expect(merged.setAside, isEmpty);
  });

  test(
    'a time set by hand is what the text says, not the words it contradicts',
    () {
      // The shape `setStopTime` leaves behind: the words are the person's, the
      // time is not in them. Rendering only the times the words lacked wrote
      // this line back unchanged, so the re-read bound 12:00 and quietly undid
      // the edit.
      final plan = [
        ConfirmedDay(
          number: 1,
          place: 'Tokyo',
          stops: [Stop(text: 'Lunch at 12pm', time: ClockTime(13, 0))],
        ),
      ];

      expect(renderPlanText(plan), 'Day 1 - Tokyo\n- 13:00 Lunch at 12pm');

      final read = ip.parseItinerary(renderPlanText(plan));
      final stop = read.days.single.stops.single;
      expect(stop.time?.hour, 13);
      expect(stop.time?.minute, 0);

      // The hand edit survives the round trip, which is the point. The cost is
      // in the same breath: the words changed, so the merge reads the day as
      // changed and files the wording it replaced in the set-aside — kept and
      // draggable back, never deleted.
      final merged = reread(plan);
      expect(merged.days.single.origin, MergedDayOrigin.mergedByPosition);
      expect(merged.days.single.stops.single.text, '13:00 Lunch at 12pm');
      expect(merged.days.single.stops.single.time, ClockTime(13, 0));
      expect([for (final a in merged.setAside) a.stop.text], ['Lunch at 12pm']);
    },
  );

  test(
    'setStopTime leaves the words alone, which is why the above is the shape',
    () {
      final container = ProviderContainer(
        overrides: [todayProvider.overrideWithValue(DateTime.utc(2027, 6, 14))],
      );
      addTearDown(container.dispose);

      final flow = container.read(pasteFlowProvider.notifier);
      flow.parse('Day 1 - Tokyo\n- Lunch at 12pm\n');

      ReviewDay dayOne() => ((container.read(pasteFlowProvider) as PasteReview)
          .review
          .days
          .firstWhere((d) => d.number == 1));

      flow.setStopTime(dayOne().stops.single.id, 13, 0);

      expect(dayOne().stops.single.text, 'Lunch at 12pm');
      expect(dayOne().stops.single.timeLabel, '13:00');
    },
  );
}
