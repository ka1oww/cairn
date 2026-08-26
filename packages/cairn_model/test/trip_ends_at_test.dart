// When a trip ends, worked out from a plan of bare calendar dates.
//
// The rule is one sentence and every case here is that sentence: a trip ends
// at the end of its *last* day. The last day, not the last dated one -- an
// undated tail is an end nobody knows yet, and reading it as "ends on day 3"
// would archive a half-dated plan while its travellers were still on it.
import 'package:cairn_model/cairn_model.dart';
import 'package:test/test.dart';

void main() {
  DateTime june(int day) => DateTime.utc(2026, 6, day);
  const tokyo = Duration(hours: 9);

  group('a trip ends at the end of its last day', () {
    test('the last day plus a day, on the trip\'s clock', () {
      expect(
        tripEndsAtFrom(
          dayDatesInPlanOrder: [june(14), june(15), june(16)],
          utcOffset: tokyo,
        ),
        DateTime.utc(2026, 6, 16, 15),
        reason: 'midnight ending 16 June in Tokyo is 15:00 UTC',
      );
      expect(
        tripEndsAtFrom(
          dayDatesInPlanOrder: [june(14), june(15), june(16)],
          utcOffset: Duration.zero,
        ),
        june(17),
      );
    });

    test('it is the last day, not the latest date', () {
      // A plan whose dates run backwards is somebody's mistake, not a longer
      // trip: the plan's own order is what says which day is last.
      expect(
        tripEndsAtFrom(
          dayDatesInPlanOrder: [june(20), june(15)],
          utcOffset: Duration.zero,
        ),
        june(16),
      );
    });

    test('an undated last day is an ending nobody knows', () {
      expect(
        tripEndsAtFrom(
          dayDatesInPlanOrder: [june(14), june(15), null],
          utcOffset: Duration.zero,
        ),
        isNull,
        reason: 'ending on the last dated day would archive it mid-trip',
      );
      expect(
        tripStandingAt(
          now: DateTime.utc(2040),
          endsAt: tripEndsAtFrom(
            dayDatesInPlanOrder: [june(14), june(15), null],
            utcOffset: Duration.zero,
          ),
        ),
        TripStanding.underway,
        reason: 'however late it is asked',
      );
    });

    test('a plan with no dates, and a plan with no days, end at nothing', () {
      expect(
        tripEndsAtFrom(
          dayDatesInPlanOrder: [null, null, null],
          utcOffset: tokyo,
        ),
        isNull,
      );
      expect(
        tripEndsAtFrom(dayDatesInPlanOrder: const [], utcOffset: tokyo),
        isNull,
      );
    });

    test('a gap earlier in the plan does not shorten it', () {
      expect(
        tripEndsAtFrom(
          dayDatesInPlanOrder: [june(14), null, june(16)],
          utcOffset: Duration.zero,
        ),
        june(17),
      );
    });
  });
}
