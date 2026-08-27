import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

/// Proves the inputs the round-8 confirmation screens consume are actually
/// available on the public API: a per-day confidence with a *cause* the UI
/// can branch on, a person-showable explanation for every set-aside line,
/// and the one-tap month-first re-read.
void main() {
  group('per-day uncertainty cause', () {
    test('is null exactly when confidence is high', () {
      final result = parseItinerary('Day 1 - Kyoto\n- Fushimi Inari\n');
      final day = result.days.single;
      expect(day.confidence, Confidence.high);
      expect(day.uncertainty, isNull);
    });

    test('weekday-only header: weekdayWithoutDate, with the weekday kept', () {
      final result = parseItinerary(
        'Monday - Kyoto\n- Fushimi Inari\n',
        tripStartDate: DateTime(2026, 6, 14),
      );
      final day = result.days.single;
      expect(day.confidence, Confidence.medium);
      expect(day.uncertainty, DayUncertainty.weekdayWithoutDate);
      expect(day.date, isNull, reason: 'a bare weekday is never guessed');
      expect(day.headerWeekday, 1,
          reason: 'the UI needs what the plan called the day to render '
              '"Monday" and to check it against a candidate date');
    });

    test('day+month, no year, no tripStartDate: dateWithoutYear', () {
      final result = parseItinerary('3 November - Kyoto\n- Fushimi Inari\n');
      final day = result.days.single;
      expect(day.confidence, Confidence.medium);
      expect(day.uncertainty, DayUncertainty.dateWithoutYear);
      expect(day.date, isNull);
    });

    test('bare place-name header: barePlaceName', () {
      final result = parseItinerary('Kyoto\n- Fushimi Inari\n');
      final day = result.days.single;
      expect(day.confidence, Confidence.medium);
      expect(day.uncertainty, DayUncertainty.barePlaceName);
    });

    test('a found-but-empty day: noStops', () {
      final result = parseItinerary('Day 1 - Kyoto\n- Fushimi Inari\n\n'
          'Day 2 - Hakone\n');
      final day2 = result.days[1];
      expect(day2.confidence, Confidence.low);
      expect(day2.uncertainty, DayUncertainty.noStops);
    });

    test('headerless fallback blocks: headerlessBlock', () {
      final result = parseItinerary('fushimi inari\nkaiseki dinner\n');
      expect(result.usedHeaderlessFallback, isTrue);
      final day = result.days.single;
      expect(day.confidence, Confidence.low);
      expect(day.uncertainty, DayUncertainty.headerlessBlock);
    });
  });

  group('person-showable explanations', () {
    test('every DayUncertainty explains itself in a real sentence', () {
      for (final u in DayUncertainty.values) {
        expect(u.explanation, isNot(u.slug));
        expect(u.explanation.split(' ').length, greaterThan(4),
            reason: '${u.slug} must carry a sentence a person can act on, '
                'not a label');
      }
    });

    test('every UnplacedReason explains itself in a real sentence', () {
      for (final r in UnplacedReason.values) {
        expect(r.explanation, isNot(r.slug));
        expect(r.explanation.split(' ').length, greaterThan(4));
      }
    });

    test('an unplaced line carries its reason and explanation', () {
      final result = parseItinerary('remember passports\n'
          'Day 1 - Kyoto\n- Fushimi Inari\n');
      final line = result.unplacedLines.single;
      expect(line.reason, UnplacedReason.precedesFirstHeader);
      expect(line.reason.explanation, contains('before the first day'));
      expect(line.sourceLine.text, 'remember passports');
    });
  });

  group('month-first numeric dates', () {
    test('default read is day-first and reports the ambiguity', () {
      final result = parseItinerary('3/11/2026 - Arrival\n- Land at KIX\n');
      expect(result.days.single.date, DateTime(2026, 11, 3));
      expect(result.hasAmbiguousNumericDates, isTrue);
    });

    test('the one-tap flip re-reads the same paste month-first', () {
      final result = parseItinerary(
        '3/11/2026 - Arrival\n- Land at KIX\n',
        monthFirstNumericDates: true,
      );
      expect(result.days.single.date, DateTime(2026, 3, 11));
    });

    test('an unambiguous numeric date reads the same either way', () {
      for (final monthFirst in [false, true]) {
        final result = parseItinerary(
          '25/12/2026 - Christmas\n- Market\n',
          monthFirstNumericDates: monthFirst,
        );
        expect(result.days.single.date, DateTime(2026, 12, 25));
        expect(result.hasAmbiguousNumericDates, isFalse);
      }
    });

    test('named-month dates never count as ambiguous', () {
      final result = parseItinerary('3 November 2026 - Arrival\n- Land\n');
      expect(result.hasAmbiguousNumericDates, isFalse);
      expect(result.firstAmbiguousNumericDate, isNull);
    });

    test('the first ambiguous date comes back as the person wrote it', () {
      for (final monthFirst in [false, true]) {
        final result = parseItinerary(
          '12/11 - Porto\n- Livraria Lello\n11/12 - Porto\n- Douro walk\n',
          monthFirstNumericDates: monthFirst,
        );
        final example = result.firstAmbiguousNumericDate!;
        // The pair as written, not as this parse chose to read it: the
        // confirmation screen quotes the person's own date back either way.
        expect(example.asWritten, '12/11');
        expect(example.dayFirstDay, 12);
        expect(example.dayFirstMonth, 11);
        expect(example.monthFirstMonth, 12);
        expect(example.monthFirstDay, 11);
      }
    });

    test('a date inside a day title is an ambiguous example too', () {
      final result = parseItinerary('Day 1 - Porto, 4/9\n- Livraria Lello\n');
      expect(result.firstAmbiguousNumericDate?.asWritten, '4/9');
    });

    test('ItineraryParser.parse accepts the same flag', () {
      final result = ItineraryParser.parse(
        '3/11/2026 - Arrival\n- Land at KIX\n',
        monthFirstNumericDates: true,
      );
      expect(result.days.single.date, DateTime(2026, 3, 11));
    });
  });
}
