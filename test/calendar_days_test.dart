// `calendarPlusDays` exists because `DateTime.add(Duration(days: n))` is
// elapsed-time arithmetic: across a daylight-saving fall-back the sum lands
// at 23:00 the previous calendar day, and anything reading the date off it
// is a day early. The constructor form normalises components instead, so it
// is exact on every backend — these tests pin the calendar behaviour the
// date chips depend on.
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/logic/calendar_days.dart';

void main() {
  test('moves forward on the calendar', () {
    expect(calendarPlusDays(DateTime(2027, 6, 14), 1), DateTime(2027, 6, 15));
    expect(calendarPlusDays(DateTime(2027, 6, 14), 10), DateTime(2027, 6, 24));
  });

  test('moves backward when negative', () {
    expect(calendarPlusDays(DateTime(2027, 6, 14), -1), DateTime(2027, 6, 13));
    expect(calendarPlusDays(DateTime(2027, 6, 14), -14), DateTime(2027, 5, 31));
  });

  test('rolls across month and year ends', () {
    expect(calendarPlusDays(DateTime(2026, 12, 30), 2), DateTime(2027, 1, 1));
    expect(calendarPlusDays(DateTime(2027, 1, 1), -1), DateTime(2026, 12, 31));
  });

  test('knows a leap day', () {
    expect(calendarPlusDays(DateTime(2028, 2, 28), 1), DateTime(2028, 2, 29));
    expect(calendarPlusDays(DateTime(2027, 2, 28), 1), DateTime(2027, 3, 1));
  });

  test('zero is the same date', () {
    expect(calendarPlusDays(DateTime(2027, 6, 14), 0), DateTime(2027, 6, 14));
  });

  test('the result sits at local midnight whatever the input carried', () {
    final afternoon = DateTime(2027, 6, 14, 15, 30);
    final moved = calendarPlusDays(afternoon, 1);
    expect(moved, DateTime(2027, 6, 15));
    expect(moved.hour, 0);
  });
}
