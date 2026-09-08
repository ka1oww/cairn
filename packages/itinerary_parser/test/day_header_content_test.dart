import 'dart:io';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

String _fixture(String name) =>
    File('test/fixtures/day_headers/$name.input.txt').readAsStringSync();

void main() {
  group('content carried by a Day header', () {
    test('keeps Rome as the place and extracts the five dashed stops', () {
      final result = parseItinerary(
        'Day 3 Rome: - Trevi Fountain - Galleria Doria Pamphilj - '
        'San Luigi dei Francesi - pantheon - Spanish Steps',
      );

      expect(result.days, hasLength(1));
      expect(result.days.single.place, 'Rome');
      expect(result.days.single.stops.map((stop) => stop.text), [
        'Trevi Fountain',
        'Galleria Doria Pamphilj',
        'San Luigi dei Francesi',
        'pantheon',
        'Spanish Steps',
      ]);
      expect(
        result.days.single.stops.map((stop) => stop.sourceLine.text).toSet(),
        {
          'Day 3 Rome: - Trevi Fountain - Galleria Doria Pamphilj - '
              'San Luigi dei Francesi - pantheon - Spanish Steps',
        },
        reason: 'every derived stop still points back to the verbatim line',
      );
    });

    test('plus signs split a real one-line Bangkok day', () {
      final day = parseItinerary(
        'Day 3: Chinatown + Temple tour + Madame Tussads',
      ).days.single;

      expect(day.stops.map((stop) => stop.text), [
        'Chinatown',
        'Temple tour',
        'Madame Tussads',
      ]);
    });

    test('a genuine label followed by stops behaves as before', () {
      final day = parseItinerary(
        'Day 1: Kyoto\n'
        '- Fushimi Inari\n'
        '- Nishiki Market',
      ).days.single;

      expect(day.place, 'Kyoto');
      expect(day.stops.map((stop) => stop.text), [
        'Fushimi Inari',
        'Nishiki Market',
      ]);
      expect(day.confidence, Confidence.high);
      expect(day.uncertainty, isNull);
    });

    test('a label-only day remains the same empty low-confidence day', () {
      final day = parseItinerary('Day 1: Kyoto').days.single;

      expect(day.place, 'Kyoto');
      expect(day.stops, isEmpty);
      expect(day.confidence, Confidence.low);
      expect(day.uncertainty, DayUncertainty.noStops);
    });

    test('a trailing-colon label still owns following-line stops', () {
      final day = parseItinerary('Day 1 Rome:\n- Trevi Fountain').days.single;

      expect(day.place, 'Rome:');
      expect(day.stops.single.text, 'Trevi Fountain');
    });

    test('inline stops retain their individual area assignments', () {
      final day = parseItinerary(
        'Trip to Rome\n'
        'Day 1 - Rome: - Colosseum - Coffee in Trastevere',
      ).days.single;

      expect(day.stops[0].area?.text, 'rome');
      expect(day.stops[1].area?.text, 'Trastevere');
    });

    test('only the inline area setter becomes an area heading', () {
      final day = parseItinerary(
        'Tokyo\n'
        'Day 1 - Rome: - Tokyo - Coffee',
      ).days.single;

      expect(day.stops[0].kind, StopKind.areaHeading);
      expect(day.stops[1].kind, StopKind.mealLabel);
    });
  });

  group('day ranges and repeated claims', () {
    test('a two-endpoint dash expands inclusively', () {
      final result = parseItinerary(
        'Day 2-5: Edinburgh (5 nights)',
        tripStartDate: DateTime(2026, 1, 1),
      );

      expect(result.days, hasLength(4));
      expect(result.days.map((day) => day.date), [
        DateTime(2026, 1, 2),
        DateTime(2026, 1, 3),
        DateTime(2026, 1, 4),
        DateTime(2026, 1, 5),
      ]);
      for (final day in result.days) {
        expect(day.stops.single.text, 'Edinburgh (5 nights)');
      }
    });

    test('multi-number dashes and plus signs preserve written numbers', () {
      final dashed = parseItinerary(
        'Day 4-5-6: Take a train to Florence',
        tripStartDate: DateTime(2026, 1, 1),
      );
      final plus = parseItinerary(
        'Day 6 + 7: cinque terre',
        tripStartDate: DateTime(2026, 1, 1),
      );

      expect(dashed.days.map((day) => day.date?.day), [4, 5, 6]);
      expect(plus.days.map((day) => day.date?.day), [6, 7]);
    });

    test('a range shares its following-line stop with every claimed day', () {
      final result = parseItinerary(
        'Day 2-3: Edinburgh\n'
        '- Edinburgh Castle',
      );

      expect(result.days, hasLength(2));
      for (final day in result.days) {
        expect(day.place, 'Edinburgh');
        expect(day.stops.single.text, 'Edinburgh Castle');
      }
    });

    test('duplicate and overlapping claims remain distinct source entries', () {
      final result = parseItinerary(
        'Day 16: Day trip to Ghent from Bruges\n'
        'Day 16: Antwerp (1 night)\n'
        'Day 30-31: Füssen (2 nights)\n'
        'Day 31-32: Munich (2 nights)',
        tripStartDate: DateTime(2026, 1, 1),
      );

      expect(result.days, hasLength(6));
      expect(result.days.map((day) => day.date?.day), [16, 16, 30, 31, 31, 1]);
      expect(result.days.map((day) => day.headerSourceLine?.text), [
        'Day 16: Day trip to Ghent from Bruges',
        'Day 16: Antwerp (1 night)',
        'Day 30-31: Füssen (2 nights)',
        'Day 30-31: Füssen (2 nights)',
        'Day 31-32: Munich (2 nights)',
        'Day 31-32: Munich (2 nights)',
      ]);
      expect(result.days.map((day) => day.stops.single.text), [
        'Day trip to Ghent from Bruges',
        'Antwerp (1 night)',
        'Füssen (2 nights)',
        'Füssen (2 nights)',
        'Munich (2 nights)',
        'Munich (2 nights)',
      ]);
    });
  });

  group('real one-line itinerary corpus', () {
    final samples = <String, ({String input, int days, int stops})>{
      'Bangkok': (input: _fixture('bangkok'), days: 5, stops: 9),
      'Europe': (input: _fixture('europe'), days: 35, stops: 35),
      'Paris to Italy': (
        input: _fixture('paris_to_italy'),
        days: 14,
        stops: 14,
      ),
      'Italy 12-day': (
        input: _fixture('italy_twelve_day'),
        days: 12,
        stops: 12,
      ),
      'Italy compressed': (
        input: _fixture('italy_compressed'),
        days: 10,
        stops: 31,
      ),
      'Spain': (input: _fixture('spain'), days: 10, stops: 10),
    };

    for (final entry in samples.entries) {
      test('${entry.key} produces its declared day entries and stops', () {
        final result = parseItinerary(entry.value.input);

        expect(result.days, hasLength(entry.value.days));
        expect(
          result.days.expand((day) => day.stops),
          hasLength(entry.value.stops),
        );
      });
    }
  });
}
