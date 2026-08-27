// The honesty guard named in plan_rows.dart's header comment: every shape
// the dialect renderer emits must come back from `parseItinerary` as the
// same days, dates, times and stars. This is a dev-only dependency on
// itinerary_parser (see pubspec.yaml) — the package itself never imports
// it at runtime.
import 'package:test/test.dart';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:plan_extraction/src/plan_rows.dart';

void main() {
  group('dated days round-trip through the parser at high confidence', () {
    test('two dated days, one place, mixed stops and a starred stop', () {
      final rows = <PlanRow>[
        DayRow(date: DateTime(2027, 6, 14), place: 'Tokyo'),
        const StopRow('Senso-ji'),
        const StopRow('Ramen in Asakusa', time: TimeCell(12, 30)),
        DayRow(date: DateTime(2027, 6, 15), place: 'Kyoto'),
        const StopRow('Fushimi Inari at dawn'),
      ];
      final text = renderPlanRows(rows);
      final result = parseItinerary(text);

      expect(result.overallConfidence, Confidence.high);
      expect(result.usedHeaderlessFallback, isFalse);
      expect(result.unplacedLines, isEmpty);
      expect(result.days, hasLength(2));

      final day1 = result.days[0];
      expect(day1.date, DateTime(2027, 6, 14));
      expect(day1.confidence, Confidence.high);
      // Stop.text keeps the leading time text as-written (the parser strips
      // only the bullet marker), so a starred stop's text carries its own
      // time prefix alongside the separately-parsed ParsedTime.
      expect(day1.stops.map((s) => s.text),
          ['Senso-ji', '12:30 Ramen in Asakusa']);
      expect(day1.stops[0].isStarred, isFalse);
      expect(day1.stops[1].isStarred, isTrue);
      expect(day1.stops[1].time, const ParsedTime(12, 30));

      final day2 = result.days[1];
      expect(day2.date, DateTime(2027, 6, 15));
      expect(day2.stops.single.text, 'Fushimi Inari at dawn');
    });

    test('a dated day with no place still binds its date', () {
      final rows = <PlanRow>[
        DayRow(date: DateTime(2027, 1, 1)),
        const StopRow('Countdown at the shrine'),
      ];
      final result = parseItinerary(renderPlanRows(rows));
      expect(result.days.single.date, DateTime(2027, 1, 1));
      expect(result.days.single.confidence, Confidence.high);
    });
  });

  group('undated days round-trip as Day N, unbound until a trip start', () {
    test('two undated days keep their order and stops', () {
      final rows = <PlanRow>[
        const DayRow(number: 1, place: 'Kyoto'),
        const StopRow('Arrive, check in'),
        const DayRow(number: 2, place: 'Kyoto'),
        const StopRow('Bamboo grove'),
      ];
      final result = parseItinerary(renderPlanRows(rows));
      expect(result.days, hasLength(2));
      expect(result.days[0].date, isNull);
      expect(result.days[1].date, isNull);
      expect(result.days[0].stops.single.text, 'Arrive, check in');
      expect(result.days[1].stops.single.text, 'Bamboo grove');
    });

    test('given a trip start date, Day N resolves to a real calendar date',
        () {
      final rows = <PlanRow>[
        const DayRow(number: 1, place: 'Kyoto'),
        const StopRow('Arrive'),
        const DayRow(number: 3, place: 'Tokyo'),
        const StopRow('Depart'),
      ];
      final result = parseItinerary(
        renderPlanRows(rows),
        tripStartDate: DateTime(2027, 6, 14),
      );
      expect(result.days[0].date, DateTime(2027, 6, 14));
      expect(result.days[1].date, DateTime(2027, 6, 16));
    });
  });

  group('preamble rows are visible, not silently dropped', () {
    test('a leading title/column-label line lands in unplacedLines', () {
      final rows = <PlanRow>[
        const PreambleRow('Date'),
        const PreambleRow('City'),
        DayRow(date: DateTime(2027, 6, 14), place: 'Tokyo'),
        const StopRow('Senso-ji'),
      ];
      final result = parseItinerary(renderPlanRows(rows));
      expect(
        result.unplacedLines.map((u) => u.sourceLine.text.trim()),
        ['Date', 'City'],
      );
      expect(result.days.single.stops.single.text, 'Senso-ji');
    });
  });

  group('planRowsFromGrid heuristic v1 (the import plan risk 5)', () {
    test('a date-typed column drives the dialect path end to end', () {
      final grid = <List<SourceCell?>>[
        [const TextCell('Date'), const TextCell('City'), const TextCell('Plan')],
        [
          DateCell(DateTime(2027, 6, 14)),
          const TextCell('Tokyo'),
          const TextCell('Senso-ji at 9:00\nUeno Park picnic'),
        ],
        [
          DateCell(DateTime(2027, 6, 15)),
          const TextCell('Kyoto'),
          const TimeCell(9, 30),
          const TextCell('Fushimi Inari'),
        ],
      ];
      final text = renderPlanRows(planRowsFromGrid(grid));
      final result = parseItinerary(text);

      expect(result.days, hasLength(2));
      expect(result.days[0].date, DateTime(2027, 6, 14));
      // The place column folds into the header, not a bare stop under it.
      expect(result.days[0].place, 'Tokyo');
      expect(result.days[0].stops.map((s) => s.text),
          ['Senso-ji at 9:00', 'Ueno Park picnic']);
      expect(result.days[1].date, DateTime(2027, 6, 15));
      expect(result.days[1].place, 'Kyoto');
      // The time-typed cell stars the first text line of its own row.
      final kyotoStops = result.days[1].stops;
      expect(kyotoStops.map((s) => s.text), ['09:30 Fushimi Inari']);
      expect(kyotoStops.last.isStarred, isTrue);
      expect(kyotoStops.last.time, const ParsedTime(9, 30));
      // The label row is furniture: dropped, not reported as lines nobody
      // could place.
      expect(result.unplacedLines, isEmpty);
    });

    test('a labelled sheet with no place column keeps its stops as stops',
        () {
      final grid = <List<SourceCell?>>[
        [const TextCell('Date'), const TextCell('Plan')],
        [
          DateCell(DateTime(2027, 6, 14)),
          const TextCell('Senso-ji'),
        ],
        [
          DateCell(DateTime(2027, 6, 15)),
          const TextCell('Fushimi Inari'),
        ],
      ];
      final result = parseItinerary(renderPlanRows(planRowsFromGrid(grid)));

      expect(result.unplacedLines, isEmpty);
      expect(result.days, hasLength(2));
      expect(result.days[0].stops.single.text, 'Senso-ji');
      expect(result.days[1].stops.single.text, 'Fushimi Inari');
    });

    test('a sheet whose first row is real data keeps that row', () {
      final grid = <List<SourceCell?>>[
        [
          DateCell(DateTime(2027, 6, 14)),
          const TextCell('Lisbon'),
          const TextCell('Alfama wander'),
        ],
        [
          DateCell(DateTime(2027, 6, 15)),
          const TextCell('Sintra'),
          const TextCell('Pena Palace'),
        ],
      ];
      final result = parseItinerary(renderPlanRows(planRowsFromGrid(grid)));

      expect(result.days, hasLength(2));
      // With no labels there is no place column, so the place stays a stop
      // rather than being guessed into the header — but the row survives.
      expect(result.days[0].stops.map((s) => s.text),
          ['Lisbon', 'Alfama wander']);
      expect(result.days[1].stops.map((s) => s.text),
          ['Sintra', 'Pena Palace']);
    });

    test('a first row of two plain words is not mistaken for labels', () {
      final grid = <List<SourceCell?>>[
        [const TextCell('Porto trip'), const TextCell('prepared by Ana')],
        [
          DateCell(DateTime(2027, 6, 14)),
          const TextCell('Livraria Lello'),
        ],
      ];
      final result = parseItinerary(renderPlanRows(planRowsFromGrid(grid)));

      // Nothing names the date column, so the row is kept and filed
      // visibly, exactly as before.
      expect(
        result.unplacedLines.map((u) => u.sourceLine.text.trim()),
        ['Porto trip', 'prepared by Ana'],
      );
      expect(result.days.single.stops.single.text, 'Livraria Lello');
    });

    test('the place repeats down a day\'s rows without repeating as a stop',
        () {
      final grid = <List<SourceCell?>>[
        [const TextCell('Date'), const TextCell('City'), const TextCell('Plan')],
        [
          DateCell(DateTime(2027, 9, 14)),
          const TextCell('Zermatt'),
          const TextCell('Gornergrat railway'),
        ],
        [
          DateCell(DateTime(2027, 9, 14)),
          const TextCell('Zermatt'),
          const TextCell('Fondue in the old village'),
        ],
        [
          DateCell(DateTime(2027, 9, 15)),
          const TextCell('Zermatt'),
          const TextCell('Matterhorn glacier paradise'),
        ],
        [
          DateCell(DateTime(2027, 9, 15)),
          const TextCell('Tasch'),
          const TextCell('Drive down, drop the car'),
        ],
      ];
      final result = parseItinerary(renderPlanRows(planRowsFromGrid(grid)));

      expect(result.unplacedLines, isEmpty);
      expect(result.days, hasLength(2));
      expect(result.days[0].place, 'Zermatt');
      expect(result.days[0].stops.map((s) => s.text),
          ['Gornergrat railway', 'Fondue in the old village']);
      expect(result.days[1].place, 'Zermatt');
      // A place that *changes* mid-day is content, and stays visible.
      expect(result.days[1].stops.map((s) => s.text), [
        'Matterhorn glacier paradise',
        'Tasch',
        'Drive down, drop the car',
      ]);
    });

    test('no date-typed column falls back to faithful row-major lines '
        'that still parse — the floor the plan promises', () {
      final grid = <List<SourceCell?>>[
        [const TextCell('Day'), const TextCell('Place'), const TextCell('Notes')],
        [
          const TextCell('1'),
          const TextCell('Kyoto'),
          const TextCell('3/11, Fushimi Inari early'),
        ],
      ];
      final text = renderPlanRows(planRowsFromGrid(grid));
      // Every cell became a bare line; nothing threw, and the parser can
      // still be asked to make sense of it (headerless fallback is an
      // acceptable floor here, not a failure of this test).
      expect(text.split('\n'), [
        'Day',
        'Place',
        'Notes',
        '1',
        'Kyoto',
        '3/11, Fushimi Inari early',
      ]);
      expect(() => parseItinerary(text), returnsNormally);
    });

    test('a time column to the right of the description still stars it', () {
      final grid = <List<SourceCell?>>[
        [
          DateCell(DateTime(2027, 6, 14)),
          const TextCell('Ramen in Asakusa'),
          const TimeCell(12, 30),
        ],
        [
          DateCell(DateTime(2027, 6, 15)),
          const TextCell('Fushimi Inari'),
          const TimeCell(6, 0),
        ],
      ];
      final result = parseItinerary(renderPlanRows(planRowsFromGrid(grid)));

      expect(result.days, hasLength(2));
      final first = result.days[0].stops.single;
      expect(first.text, '12:30 Ramen in Asakusa');
      expect(first.isStarred, isTrue);
      expect(first.time, const ParsedTime(12, 30));
      final second = result.days[1].stops.single;
      expect(second.text, '06:00 Fushimi Inari');
      expect(second.time, const ParsedTime(6, 0));
    });

    test('an empty grid renders to nothing', () {
      expect(planRowsFromGrid(const []), isEmpty);
      expect(planRowsFromGrid([[], []]), isEmpty);
    });
  });
}
