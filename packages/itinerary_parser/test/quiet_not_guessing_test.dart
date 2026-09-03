// The design rule under test: when the parser is unsure, it goes quiet
// rather than guessing confidently. Each group pins one way it used to
// guess — an impossible date sliding to a neighbour, a dotted time read as
// a numbered bullet, a price or a room number starred as a time, a named
// weekday silently ignored beside a date it contradicts, and a year answer
// seeding a trip start the plan never named.
import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

ParsedDay firstDayOf(String text, {DateTime? tripStartDate}) =>
    parseItinerary(text, tripStartDate: tripStartDate).days.first;

ParsedTime? timeOfOnlyStop(String line) {
  final day = firstDayOf('Day 1 - Tokyo\n$line');
  expect(day.stops, hasLength(1), reason: 'expected one stop for "$line"');
  return day.stops.single.time;
}

void main() {
  group('an impossible day-of-month goes quiet instead of sliding', () {
    test('31 June with a year binds no date and says why', () {
      final day = firstDayOf('31 June 2027 - Osaka\n- Dotonbori');
      expect(day.date, isNull,
          reason: 'DateTime would have slid 31 June to 1 July');
      expect(day.uncertainty, DayUncertainty.impossibleDate);
      expect(day.confidence, Confidence.medium);
      expect(day.place, 'Osaka');
      expect(day.stops.single.text, 'Dotonbori');
    });

    test('29 February in a non-leap year is refused, in a leap year kept',
        () {
      final refused = firstDayOf('29 February 2027 - Sapporo\n- Snow');
      expect(refused.date, isNull);
      expect(refused.uncertainty, DayUncertainty.impossibleDate);

      final kept = firstDayOf('29 February 2028 - Sapporo\n- Snow');
      expect(kept.date, DateTime(2028, 2, 29));
      expect(kept.uncertainty, isNull);
    });

    test('a year-less impossible date is refused whatever the trip start',
        () {
      final day = firstDayOf('31 June - Osaka\n- Dotonbori',
          tripStartDate: DateTime(2027, 6, 1));
      expect(day.date, isNull);
      expect(day.uncertainty, DayUncertainty.impossibleDate);
    });

    test('an impossible title fragment is never offered as a candidate', () {
      final day = firstDayOf('Day 1 - Tokyo, 31 June\n- Meiji Shrine');
      expect(day.dateCandidate, isNull,
          reason: 'a candidate that cannot exist must not be offered');
    });

    test('a candidate whose named year makes it impossible resolves to null',
        () {
      // 29 February exists in some year, so it stays a candidate — but
      // resolved against its own non-leap year it must answer null, not
      // 1 March.
      final day = firstDayOf('Day 1 - Sapporo, 29 February 2027\n- Snow');
      expect(day.dateCandidate, isNull,
          reason: '29 Feb 2027 does not exist and is not offered');

      final leap = firstDayOf('Day 1 - Sapporo, 29 February 2028\n- Snow');
      expect(leap.dateCandidate?.resolved, DateTime(2028, 2, 29));
    });
  });

  group('a dotted time at the start of a line is a time, not a bullet', () {
    test('9.30 Breakfast keeps its text and its time', () {
      final day = firstDayOf('Day 1 - Tokyo\n9.30 Breakfast');
      final stop = day.stops.single;
      expect(stop.text, '9.30 Breakfast',
          reason: 'the line must not be read as numbered bullet 9');
      expect(stop.time, const ParsedTime(9, 30));
    });

    test('a real numbered list keeps its bullets', () {
      final day = firstDayOf('Day 1 - Tokyo\n1. Meiji Shrine\n2. 30 min walk');
      expect(day.stops[0].text, 'Meiji Shrine');
      expect(day.stops[1].text, '30 min walk',
          reason: 'a space after the dot is a bullet, not a time');
    });

    test('a decimal number is still a bullet-stripped item, not a time', () {
      final day = firstDayOf('Day 1 - Tokyo\n12.50pm lunch at market');
      expect(day.stops.single.time, const ParsedTime(12, 50));
    });
  });

  group('prices and labelled numbers are not times', () {
    test('a currency symbol before the number refuses the star', () {
      expect(timeOfOnlyStop(r'Lunch $12.50 at the market'), isNull);
      expect(timeOfOnlyStop(r'Souvenirs S$14.20'), isNull);
      expect(timeOfOnlyStop('Museum €10.30 entry'), isNull);
    });

    test('a currency code after the number refuses the star', () {
      expect(timeOfOnlyStop('Kaiseki dinner 120.50 SGD'), isNull);
      expect(timeOfOnlyStop('Taxi 45.00 usd shared'), isNull);
    });

    test('a priced 4-digit number refuses the bare military form', () {
      expect(timeOfOnlyStop('Lunch ¥1200'), isNull);
      expect(timeOfOnlyStop('1200 JPY entry'), isNull);
      expect(timeOfOnlyStop('Check in 1400'), const ParsedTime(14, 0),
          reason: 'an ordinary bare military time still stars');
      expect(timeOfOnlyStop('Lunch ¥1200, walk over by 1400'),
          const ParsedTime(14, 0),
          reason: 'a later real time on the same line still counts');
    });

    test('a labelled 4-digit number refuses the bare military form', () {
      expect(timeOfOnlyStop('Hotel check-in, Room 1204'), isNull);
      expect(timeOfOnlyStop('Gate 2130 at Changi'), isNull);
      expect(timeOfOnlyStop('Flight 0845 to Osaka'), isNull);
      expect(timeOfOnlyStop('Platform 1330 departure'), isNull);
      expect(timeOfOnlyStop('bus 1230 from the station'), isNull);
      expect(timeOfOnlyStop('Locker no. 1930'), isNull);
      expect(timeOfOnlyStop('Booth #1730 at the fair'), isNull);
    });

    test('a real time on the same line still stars the stop', () {
      expect(timeOfOnlyStop(r'Lunch $12.50, table booked 13:00'),
          const ParsedTime(13, 0));
    });

    test('ordinary times keep working', () {
      expect(timeOfOnlyStop('Dinner 19:30'), const ParsedTime(19, 30));
      expect(timeOfOnlyStop('Check in 1400'), const ParsedTime(14, 0));
      expect(timeOfOnlyStop('Ferry 9.30am'), const ParsedTime(9, 30));
    });
  });

  group('a named weekday beside a full date is checked, not ignored', () {
    // 14 June 2027 really is a Monday.
    test('a disagreeing weekday keeps the date but surfaces the doubt', () {
      final day = firstDayOf('Tue 14 June 2027 - Tokyo\n- Senso-ji');
      expect(day.date, DateTime(2027, 6, 14),
          reason: 'the date is kept — quiet, not corrected');
      expect(day.confidence, Confidence.medium);
      expect(day.uncertainty, DayUncertainty.weekdayDisagrees);
      expect(day.headerWeekday, 2);
    });

    test('an agreeing weekday stays high confidence', () {
      final day = firstDayOf('Mon 14 June 2027 - Tokyo\n- Senso-ji');
      expect(day.date, DateTime(2027, 6, 14));
      expect(day.confidence, Confidence.high);
      expect(day.uncertainty, isNull);
    });

    test('a weekday resolved through the trip start is checked too', () {
      // With a 2027 start, `Tue 14 June` resolves to 14 June 2027 — a
      // Monday — so the disagreement must surface before anything binds.
      final day = firstDayOf('Tue 14 June - Tokyo\n- Senso-ji',
          tripStartDate: DateTime(2027, 6, 1));
      expect(day.date, DateTime(2027, 6, 14));
      expect(day.uncertainty, DayUncertainty.weekdayDisagrees);
    });
  });

  group('the year answer gets a real trip start, not 1 January', () {
    const newYearPlan = '30 December - Osaka\n'
        '- Dotonbori\n'
        '31 December - Osaka\n'
        '- Countdown\n'
        '1 January - Kyoto\n'
        '- Hatsumode at Fushimi Inari';

    test('the first year-less date is reported for the year chip to seed',
        () {
      final result = parseItinerary(newYearPlan);
      expect(result.firstYearlessDate,
          const YearlessDate(day: 30, month: 12));
      expect(result.days.every((d) => d.date == null), isTrue,
          reason: 'no year anywhere, so nothing binds yet');
    });

    test('seeded with the plan\'s own first date, January rolls forward', () {
      final result = parseItinerary(newYearPlan,
          tripStartDate: DateTime(2026, 12, 30));
      expect(result.days[0].date, DateTime(2026, 12, 30));
      expect(result.days[1].date, DateTime(2026, 12, 31));
      expect(result.days[2].date, DateTime(2027, 1, 1),
          reason: 'the January day is next year, not eleven months ago');
    });

    test('a dated plan reports no year-less date', () {
      final result = parseItinerary('14 June 2027 - Tokyo\n- Senso-ji');
      expect(result.firstYearlessDate, isNull);
    });

    test('an impossible year-less date does not become the seed', () {
      final result = parseItinerary(
          '31 June - Osaka\n- Dotonbori\n3 July - Kyoto\n- Fushimi Inari');
      expect(result.firstYearlessDate, const YearlessDate(day: 3, month: 7));
    });
  });
}
