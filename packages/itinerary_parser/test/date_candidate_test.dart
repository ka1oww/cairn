// The date a day header *names in its own title* — `Day 1 - Tokyo, 14 June`.
//
// A `Day N` header takes its date from where the day sits in the trip, so the
// parser will not bind a date from the title. Before this it swallowed the
// whole tail into `place`, and the day then read "date open" beside a title
// that said 14 June. The rule these tests pin is the third option: recognized,
// lifted out of the place, offered as a candidate, never bound and never
// dropped.
import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

ParsedDay firstDayOf(String header, {bool monthFirst = false}) => parseItinerary(
      '$header\n- Senso-ji\n',
      monthFirstNumericDates: monthFirst,
    ).days.first;

void main() {
  group('a date in a Day N title becomes a candidate', () {
    test('day-first, named month: the place keeps only the place', () {
      final day = firstDayOf('Day 1 - Tokyo, 14 June');

      expect(day.place, 'Tokyo');
      expect(day.date, isNull, reason: 'a candidate is offered, never bound');
      expect(day.dateCandidate?.day, 14);
      expect(day.dateCandidate?.month, 6);
      expect(day.dateCandidate?.year, isNull);
      expect(day.dateCandidate?.text, '14 June');
      expect(day.dateCandidate?.headerText, 'Tokyo, 14 June',
          reason: 'the sheet quotes the title back as the person wrote it');
    });

    test('month-first, named month', () {
      final day = firstDayOf('Day 3: June 16 - Kyoto');

      expect(day.place, 'Kyoto');
      expect(day.dateCandidate?.day, 16);
      expect(day.dateCandidate?.month, 6);
      expect(day.dateCandidate?.text, 'June 16');
    });

    test('numeric, read day-first by default', () {
      final day = firstDayOf('Day 4 - Osaka 17/6');

      expect(day.place, 'Osaka');
      expect(day.dateCandidate?.day, 17);
      expect(day.dateCandidate?.month, 6);
    });

    test('numeric follows the paste-wide month-first flip', () {
      final day = firstDayOf('Day 4 - Osaka 3/11', monthFirst: true);

      expect(day.dateCandidate?.day, 11);
      expect(day.dateCandidate?.month, 3);
      expect(day.dateCandidate?.ambiguousNumericOrder, isTrue);
    });

    test('an ambiguous candidate makes the month-first re-read worth offering',
        () {
      final result = parseItinerary('Day 1 - Osaka 3/11\n- Dotonbori\n');

      expect(result.hasAmbiguousNumericDates, isTrue);
    });

    test('an ISO date in the title', () {
      final day = firstDayOf('Day 7 - Nara, 2027-06-20');

      expect(day.place, 'Nara');
      expect(day.dateCandidate?.year, 2027);
      expect(day.dateCandidate?.month, 6);
      expect(day.dateCandidate?.day, 20);
    });

    test('a year in the title resolves the candidate on its own', () {
      final day = firstDayOf('Day 5 - 14 June 2027');

      expect(day.place, isNull,
          reason: 'a date is not a place name, even when it is all there was');
      expect(day.dateCandidate?.resolved, DateTime(2027, 6, 14));
    });

    test('without a year the candidate stays unresolved', () {
      expect(firstDayOf('Day 1 - Tokyo, 14 June').dateCandidate?.resolved,
          isNull);
      expect(firstDayOf('Day 1 - Tokyo, 14 June').dateCandidate?.inYear(2027),
          DateTime(2027, 6, 14));
    });

    test('an en-dash header reads the same as a hyphen one', () {
      expect(firstDayOf('Day 1 – Tokyo, 14 June').dateCandidate?.text,
          '14 June');
    });
  });

  group('what is not a date candidate', () {
    test('a title with no date at all', () {
      final day = firstDayOf('Day 2: Kyoto');

      expect(day.place, 'Kyoto');
      expect(day.dateCandidate, isNull);
    });

    test('a number beside a word that is not a month', () {
      final day = firstDayOf('Day 6 - 5 temples');

      expect(day.place, '5 temples');
      expect(day.dateCandidate, isNull);
    });

    test('a count of nights is not a date', () {
      final day = firstDayOf('Day 8 - Kyoto 3 nights');

      expect(day.place, 'Kyoto 3 nights');
      expect(day.dateCandidate, isNull);
    });

    test('a date header that resolved its own date carries no candidate', () {
      final day = parseItinerary('Sat 14 June 2027 - Tokyo\n- Senso-ji\n')
          .days
          .first;

      expect(day.date, DateTime(2027, 6, 14));
      expect(day.dateCandidate, isNull);
    });

    test('a day whose date the trip start resolved still names its candidate',
        () {
      // The date is bound (from the trip's start), and the title's own date is
      // still reported — the two can disagree, and only the person can say
      // which is right.
      final day = parseItinerary(
        'Day 1 - Tokyo, 14 June\n- Senso-ji\n',
        tripStartDate: DateTime(2027, 6, 20),
      ).days.first;

      expect(day.date, DateTime(2027, 6, 20));
      expect(day.dateCandidate?.day, 14);
    });
  });
}
