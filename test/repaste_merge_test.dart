// Unit tests for lib/logic/repaste_merge.dart — the re-paste merge.
//
// These are pure unit tests by design: the merge is a pure function over
// `ConfirmedDay`s and parser output, so every test builds its inputs directly
// (`ParsedDay` values are constructed, not parsed) and asserts on the result
// shapes. No database, no clocks, no widgets — the merge must be provable
// without any of them (rule 6).
//
// The one rule under everything here: nothing the person had is ever deleted.
// A stop the revised plan leaves out lands in the set-aside with the day it
// came from; a day with no counterpart is kept untouched as the very same
// instance; a new day is appended rather than squeezing the old ones out.
import 'package:cairn/logic/repaste_merge.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

// ---------------------------------------------------------------------------
// Builders — terse on purpose, so each test reads as its scenario.
// ---------------------------------------------------------------------------

Stop mStop(String text, {ClockTime? time}) => Stop(text: text, time: time);

ConfirmedDay day(
  int number, {
  CalendarDate? date,
  String? place,
  List<Stop> stops = const [],
}) => ConfirmedDay(number: number, date: date, place: place, stops: stops);

ip.SourceLine srcLine(int number, String text) => ip.SourceLine(number, text);

ip.Stop pStop(String text, {int? hour, int minute = 0, int line = 1}) =>
    ip.Stop(
      text: text,
      time: hour == null ? null : ip.ParsedTime(hour, minute),
      sourceLine: srcLine(line, text),
    );

ip.ParsedDay pDay(
  int index, {
  DateTime? date,
  String? place,
  List<ip.Stop> stops = const [],
  ip.DateCandidate? candidate,
}) => ip.ParsedDay(
  index: index,
  date: date,
  place: place,
  stops: stops,
  confidence: ip.Confidence.high,
  dateCandidate: candidate,
);

final jun14 = CalendarDate(2027, 6, 14);
final jun15 = CalendarDate(2027, 6, 15);
final jun16 = CalendarDate(2027, 6, 16);

void main() {
  group('matching by date', () {
    test('a same-date repasted day takes its current day over', () {
      final current = [
        day(1, date: jun14, place: 'Tokyo', stops: [mStop('Senso-ji')]),
        day(2, date: jun15, place: 'Kyoto', stops: [mStop('Fushimi Inari')]),
      ];
      final repasted = [
        pDay(
          1,
          date: DateTime(2027, 6, 14),
          place: 'Tokyo',
          stops: [pStop('Senso-ji'), pStop('Ueno park')],
        ),
        pDay(
          2,
          date: DateTime(2027, 6, 15),
          place: 'Kyoto',
          stops: [pStop('Fushimi Inari')],
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days, hasLength(2));
      expect(result.days[0].number, 1);
      expect(result.days[0].origin, MergedDayOrigin.mergedByDate);
      expect(result.days[0].unchanged, isFalse);
      expect(result.days[0].stops.map((s) => s.text), [
        'Senso-ji',
        'Ueno park',
      ]);
      // Day 2's content is value-equal to what was there: handed back
      // untouched.
      expect(result.days[1].origin, MergedDayOrigin.mergedByDate);
      expect(result.days[1].unchanged, isTrue);
      expect(identical(result.days[1].day, current[1]), isTrue);
      expect(result.setAside, isEmpty);
    });

    test('dates match regardless of position in either list', () {
      final current = [
        day(1, date: jun14, place: 'Tokyo'),
        day(2, date: jun15, place: 'Kyoto'),
        day(3, date: jun16, place: 'Osaka'),
      ];
      final repasted = [
        pDay(
          1,
          date: DateTime(2027, 6, 15),
          place: 'Kyoto v2',
          stops: [pStop('Kinkaku-ji')],
        ),
        pDay(
          2,
          date: DateTime(2027, 6, 14),
          place: 'Tokyo v2',
          stops: [pStop('Tsukiji')],
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      // Repasted order does not become plan order: days stay in current-plan
      // order, matched by date wherever they sit.
      expect(result.days.map((d) => d.number), [1, 2, 3]);
      expect(result.days[0].place, 'Tokyo v2');
      expect(result.days[0].stops.single.text, 'Tsukiji');
      expect(result.days[1].place, 'Kyoto v2');
      expect(result.days[2].origin, MergedDayOrigin.keptUnmatched);
      expect(identical(result.days[2].day, current[2]), isTrue);
    });

    test('a full-year title candidate counts as a date for matching, but is '
        'still not bound', () {
      // "Day 3 - Kyoto, 14 June 2027": the parser binds no date and lifts the
      // fragment into a candidate instead.
      final current = [
        day(1, date: jun14, place: 'Tokyo'),
        day(2, date: jun15, place: 'Kyoto', stops: [mStop('Gion')]),
      ];
      final repasted = [
        pDay(
          1,
          date: DateTime(2027, 6, 14),
          place: 'Tokyo',
          stops: [pStop('Senso-ji')],
        ),
        pDay(
          2,
          place: 'Kyoto',
          stops: [pStop('Gion')],
          candidate: ip.DateCandidate(
            day: 15,
            month: 6,
            year: 2027,
            text: '15 June 2027',
            headerText: 'Kyoto, 15 June 2027',
          ),
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days[1].origin, MergedDayOrigin.mergedByDate);
      // The date stays exactly what the current plan carries — reading the
      // named date to find the day's twin did not bind it.
      expect(result.days[1].date, jun15);
      expect(identical(result.days[1].day, current[1]), isTrue);
      expect(result.days[1].unchanged, isTrue);
      // ...and the question still belongs to the screen, so the candidate
      // travels.
      expect(result.days[1].dateCandidate, isNotNull);
    });

    test('two current days wearing one date: the earliest claims it, the '
        'other is kept untouched', () {
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
        day(2, date: jun14, stops: [mStop('B')]),
      ];
      final repasted = [
        pDay(1, date: DateTime(2027, 6, 14), stops: [pStop('New')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days[0].origin, MergedDayOrigin.mergedByDate);
      expect(result.days[0].stops.single.text, 'New');
      expect(result.days[1].origin, MergedDayOrigin.keptUnmatched);
      expect(result.days[1].stops.single.text, 'B');
    });

    test('an ambiguous numeric candidate does not claim a day by date: it '
        'pairs by position and the question stays the screen\'s', () {
      // "Day 2 - Osaka, 5/6/2027": a full year, but is that 5 June or 5 May?
      // The merge refuses to read it, so it matches like any undated day.
      final current = [
        day(
          1,
          date: CalendarDate(2027, 6, 5),
          place: 'Tokyo',
          stops: [mStop('A')],
        ),
        day(
          2,
          date: CalendarDate(2027, 5, 5),
          place: 'Osaka',
          stops: [mStop('B')],
        ),
      ];
      final ambiguous = ip.DateCandidate(
        day: 5,
        month: 6,
        year: 2027,
        text: '5/6/2027',
        headerText: 'Osaka, 5/6/2027',
        ambiguousNumericOrder: true,
      );
      final repasted = [
        pDay(
          1,
          place: 'Osaka',
          stops: [pStop('Revised')],
          candidate: ambiguous,
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      // Day 1 wears 5 June — the reading the candidate would have taken — and
      // is not claimed by date; the position pass pairs it instead.
      expect(result.days[0].origin, MergedDayOrigin.mergedByPosition);
      expect(result.days[0].stops.single.text, 'Revised');
      expect(result.days[0].date, CalendarDate(2027, 6, 5));
      // The candidate still travels, so the date sheet can offer it.
      expect(result.days[0].dateCandidate, ambiguous);
      expect(result.days[1].origin, MergedDayOrigin.keptUnmatched);
    });

    test('two repasted days naming one date: the first claims it, the second '
        'is appended', () {
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
      ];
      final repasted = [
        pDay(1, date: DateTime(2027, 6, 14), stops: [pStop('First')]),
        pDay(2, date: DateTime(2027, 6, 14), stops: [pStop('Second')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days[0].stops.single.text, 'First');
      expect(result.days[1].origin, MergedDayOrigin.appendedNew);
      expect(result.days[1].number, 2);
      expect(result.days[1].date, jun14);
    });
  });

  group('matching by position (undated)', () {
    test('undated repasted days pair with unclaimed current days in order', () {
      final current = [
        day(1, place: 'Tokyo', stops: [mStop('Fish market')]),
        day(2, place: 'Kyoto', stops: [mStop('Temple')]),
      ];
      final repasted = [
        pDay(1, place: 'Tokyo', stops: [pStop('Fish market'), pStop('Tower')]),
        pDay(2, place: 'Kyoto', stops: [pStop('Bamboo grove')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days.map((d) => d.origin), [
        MergedDayOrigin.mergedByPosition,
        MergedDayOrigin.mergedByPosition,
      ]);
      expect(result.days[1].stops.single.text, 'Bamboo grove');
      expect(result.setAside.map((s) => s.stop.text), ['Temple']);
      expect(result.setAside.single.fromDayNumber, 2);
    });

    test('mixed dated and undated: dates claim theirs first, undated fill '
        'the remaining slots in order', () {
      final current = [
        day(1, date: jun14, place: 'Tokyo', stops: [mStop('A')]),
        day(2, date: jun15, place: 'Kyoto', stops: [mStop('B')]),
        day(3, place: 'Osaka', stops: [mStop('C')]), // undated
      ];
      final repasted = [
        pDay(1, date: DateTime(2027, 6, 15), stops: [pStop('Kyoto new')]),
        pDay(2, stops: [pStop('Undated one')]),
        pDay(3, stops: [pStop('Undated two')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      // The dated repasted day takes day 2 by date...
      expect(result.days[1].origin, MergedDayOrigin.mergedByDate);
      expect(result.days[1].stops.single.text, 'Kyoto new');
      // ...and the two undated ones fill the free slots — day 1 then day 3 —
      // in repasted order, not by their own indices.
      expect(result.days[0].origin, MergedDayOrigin.mergedByPosition);
      expect(result.days[0].stops.single.text, 'Undated one');
      expect(result.days[2].origin, MergedDayOrigin.mergedByPosition);
      expect(result.days[2].stops.single.text, 'Undated two');
    });

    test('an undated repasted day never steals a dated day by position when '
        'its own slot arithmetic runs out', () {
      // One current day, dated. One undated repasted day. The date pass has
      // nothing to do; the position pass pairs them — an undated revision of
      // the trip's only day is that day's revision.
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
      ];
      final repasted = [
        pDay(1, stops: [pStop('Revised A')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days.single.origin, MergedDayOrigin.mergedByPosition);
      // The date survives the merge untouched: matching without a date never
      // un-dates a day.
      expect(result.days.single.date, jun14);
    });
  });

  group('displaced content goes to the set-aside, never deleted', () {
    test('a stop the revised plan leaves out is filed with its day, text and '
        'time intact', () {
      final current = [
        day(
          2,
          date: jun15,
          place: 'Kyoto',
          stops: [
            mStop('Fushimi Inari'),
            mStop('Tea ceremony', time: ClockTime(15, 30)),
          ],
        ),
      ];
      final repasted = [
        pDay(
          1,
          date: DateTime(2027, 6, 15),
          place: 'Kyoto',
          stops: [pStop('Fushimi Inari')],
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.setAside, hasLength(1));
      final item = result.setAside.single;
      expect(item.fromDayNumber, 2);
      expect(item.stop.text, 'Tea ceremony');
      expect(item.stop.time, ClockTime(15, 30));
      expect(item.explanation, displacedByRepasteExplanation);
    });

    test('re-timing a stop keeps it — times are not part of survival', () {
      final current = [
        day(1, stops: [mStop('Breakfast', time: ClockTime(8, 0))]),
      ];
      final repasted = [
        pDay(1, stops: [pStop('Breakfast', hour: 9, minute: 15)]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.setAside, isEmpty);
      expect(result.days.single.stops.single.time, ClockTime(9, 15));
      expect(result.days.single.unchanged, isFalse);
    });

    test(
      'a stop the re-paste moved to another day is moved, not displaced',
      () {
        final current = [
          day(1, place: 'Kyoto', stops: [mStop('Gion'), mStop('Nishiki')]),
          day(2, place: 'Nara', stops: [mStop('Deer park')]),
        ];
        final repasted = [
          pDay(1, place: 'Kyoto', stops: [pStop('Nishiki')]),
          pDay(2, place: 'Nara', stops: [pStop('Deer park'), pStop('Gion')]),
        ];

        final result = mergeRepaste(current: current, repasted: repasted);

        // 'Gion' left day 1 but the revised plan still says it, on day 2.
        expect(result.setAside, isEmpty);
        expect(result.days[1].stops.map((s) => s.text), ['Deer park', 'Gion']);
      },
    );

    test('a stop absent from the whole revised plan is filed, however many '
        'times it was said', () {
      final current = [
        day(1, stops: [mStop('Lunch'), mStop('Lunch'), mStop('Lunch')]),
        day(2, stops: [mStop('Dinner')]),
      ];
      final repasted = [
        pDay(1, stops: [pStop('Lunch')]),
        pDay(2, stops: [pStop('Lunch')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      // 'Lunch' still appears in the revised plan, so no copy of it is
      // displaced; 'Dinner' has vanished from it entirely, so it is filed.
      expect(result.setAside.map((s) => s.stop.text), ['Dinner']);
      expect(result.setAside.single.fromDayNumber, 2);
      expect(result.days[0].stops, hasLength(1));
    });

    test('spelling up to case and whitespace is still the same stop', () {
      final current = [
        day(1, stops: [mStop('  Fushimi   Inari ')]),
      ];
      final repasted = [
        pDay(1, stops: [pStop('fushimi inari')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.setAside, isEmpty);
    });
  });

  group('identity stability (rule 5)', () {
    test('unchanged days come back as the identical instance with their '
        'number untouched', () {
      final untouched = day(
        1,
        date: jun14,
        place: 'Tokyo',
        stops: [
          mStop('A'),
          mStop('B', time: ClockTime(10, 0)),
        ],
      );
      final changed = day(2, date: jun15, place: 'Kyoto', stops: [mStop('C')]);
      final kept = day(3, place: 'Osaka', stops: [mStop('D')]);

      final result = mergeRepaste(
        current: [untouched, changed, kept],
        repasted: [
          pDay(
            1,
            date: DateTime(2027, 6, 14),
            place: 'Tokyo',
            stops: [pStop('A'), pStop('B', hour: 10)],
          ),
          pDay(
            2,
            date: DateTime(2027, 6, 15),
            place: 'Kyoto',
            stops: [pStop('C2')],
          ),
        ],
      );

      expect(identical(result.days[0].day, untouched), isTrue);
      expect(result.days[0].number, 1);
      expect(result.days[0].unchanged, isTrue);
      // The rewritten day keeps the number it wore before — photos assigned
      // to day 2 stay assigned to day 2.
      expect(result.days[1].number, 2);
      expect(result.days[1].unchanged, isFalse);
      expect(identical(result.days[2].day, kept), isTrue);
      expect(result.days[2].number, 3);
      expect(result.days[2].unchanged, isTrue);
    });

    test('numbers are never renumbered, even across gaps', () {
      final current = [
        day(2, date: jun14, stops: [mStop('A')]),
        day(5, date: jun15, stops: [mStop('B')]),
      ];

      final result = mergeRepaste(
        current: current,
        repasted: [
          pDay(1, date: DateTime(2027, 6, 14), stops: [pStop('New')]),
        ],
      );

      expect(result.days.map((d) => d.number), [2, 5]);
    });
  });

  group('kept and appended days (rules 3 and 4)', () {
    test('empty current plan: every repasted day is appended from day 1', () {
      final result = mergeRepaste(
        current: const [],
        repasted: [
          pDay(
            1,
            date: DateTime(2027, 6, 14),
            place: 'Tokyo',
            stops: [pStop('A')],
          ),
          pDay(2, place: 'Kyoto', stops: [pStop('B')]),
        ],
      );

      expect(result.days, hasLength(2));
      expect(result.days.map((d) => d.number), [1, 2]);
      expect(
        result.days.every((d) => d.origin == MergedDayOrigin.appendedNew),
        isTrue,
      );
      // The undated appended day keeps its date open — appending is not
      // dating.
      expect(result.days[1].date, isNull);
      expect(result.setAside, isEmpty);
    });

    test('empty repaste: every current day is kept, nothing displaced', () {
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
        day(2, stops: [mStop('B')]),
      ];

      final result = mergeRepaste(current: current, repasted: const []);

      expect(result.days, hasLength(2));
      expect(
        result.days.every((d) => identical(d.day, current[d.number - 1])),
        isTrue,
      );
      expect(result.setAside, isEmpty);
    });

    test('both empty: an empty plan comes back', () {
      final result = mergeRepaste(current: const [], repasted: const []);
      expect(result.days, isEmpty);
      expect(result.setAside, isEmpty);
    });

    test('repaste shorter than current: leftovers are kept untouched', () {
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
        day(2, date: jun15, stops: [mStop('B')]),
        day(3, date: jun16, stops: [mStop('C')]),
      ];
      final repasted = [
        pDay(1, date: DateTime(2027, 6, 14), stops: [pStop('A2')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days, hasLength(3));
      expect(result.days[0].stops.single.text, 'A2');
      expect(identical(result.days[1].day, current[1]), isTrue);
      expect(identical(result.days[2].day, current[2]), isTrue);
      expect(result.setAside.single.fromDayNumber, 1);
    });

    test('repaste longer than current: extras append after the highest '
        'existing number, dated only where the parser bound a date', () {
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
      ];
      final repasted = [
        pDay(1, date: DateTime(2027, 6, 14), stops: [pStop('A')]),
        pDay(
          2,
          date: DateTime(2027, 6, 18),
          place: 'Nara',
          stops: [pStop('Deer park')],
        ),
        pDay(
          3,
          place: 'Kobe',
          stops: [pStop('Harbour')],
          candidate: ip.DateCandidate(
            day: 20,
            month: 6,
            year: null,
            text: '20 June',
            headerText: 'Kobe, 20 June',
          ),
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days.map((d) => d.number), [1, 2, 3]);
      final nara = result.days[1];
      final kobe = result.days[2];
      expect(nara.origin, MergedDayOrigin.appendedNew);
      expect(nara.date, CalendarDate(2027, 6, 18));
      // The year-less candidate names a date nobody has bound: the appended
      // day stays open-dated and the candidate rides along for the screen.
      expect(kobe.date, isNull);
      expect(kobe.dateCandidate, isNotNull);
      expect(kobe.stops.single.text, 'Harbour');
    });

    test('a dated repasted day with no counterpart appends even when free '
        'current slots exist — position matching is for undated days', () {
      final current = [
        day(1, date: jun14, stops: [mStop('A')]),
        day(2, place: 'Spare', stops: [mStop('B')]), // undated, unclaimed
      ];
      final repasted = [
        pDay(
          1,
          date: DateTime(2027, 7, 1),
          place: 'Hokkaido',
          stops: [pStop('New leg')],
        ),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days[0].origin, MergedDayOrigin.keptUnmatched);
      expect(result.days[1].origin, MergedDayOrigin.keptUnmatched);
      expect(result.days[2].origin, MergedDayOrigin.appendedNew);
      expect(result.days[2].number, 3);
      expect(result.days[2].date, CalendarDate(2027, 7, 1));
    });
  });

  group('content replacement on a matched day', () {
    test(
      'place and stops are replaced wholesale; the number and date stay',
      () {
        final current = [
          day(4, date: jun15, place: 'Old name', stops: [mStop('Old stop')]),
        ];
        final repasted = [
          pDay(
            1,
            date: DateTime(2027, 6, 15),
            place: 'New name',
            stops: [pStop('New stop')],
          ),
        ];

        final result = mergeRepaste(current: current, repasted: repasted);

        final merged = result.days.single;
        expect(merged.number, 4);
        expect(merged.date, jun15);
        expect(merged.place, 'New name');
        expect(merged.stops.single.text, 'New stop');
        expect(result.setAside.single.stop.text, 'Old stop');
      },
    );

    test('an emptied repasted day empties its counterpart — and files what '
        'was there', () {
      final current = [
        day(1, date: jun14, stops: [mStop('Only thing')]),
      ];
      final repasted = [pDay(1, date: DateTime(2027, 6, 14))];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days.single.stops, isEmpty);
      expect(result.setAside.single.stop.text, 'Only thing');
    });

    test('a repasted header with no place replaces a named place with none — '
        'the literal reading of "takes the repasted content"', () {
      final current = [
        day(1, place: 'Tokyo', stops: [mStop('A')]),
      ];
      final repasted = [
        pDay(1, stops: [pStop('A')]),
      ];

      final result = mergeRepaste(current: current, repasted: repasted);

      expect(result.days.single.place, isNull);
      expect(result.days.single.unchanged, isFalse);
      expect(result.setAside, isEmpty);
    });
  });

  group('purity and determinism (rule 6)', () {
    test('same inputs, same outputs — twice in a row', () {
      final current = [
        day(1, date: jun14, place: 'Tokyo', stops: [mStop('A')]),
        day(2, place: 'Kyoto', stops: [mStop('B'), mStop('C')]),
      ];
      final repasted = [
        pDay(
          1,
          date: DateTime(2027, 6, 14),
          place: 'Tokyo',
          stops: [pStop('A2')],
        ),
        pDay(2, stops: [pStop('B')]),
      ];

      String describe(RepasteMergeResult r) => [
        for (final d in r.days)
          'day ${d.number} [${d.origin.name}] date=${d.date?.iso} '
              'place=${d.place} unchanged=${d.unchanged} '
              'stops=[${d.stops.map((s) => '${s.text}@${s.time?.iso}').join('|')}]',
        for (final s in r.setAside)
          'aside from ${s.fromDayNumber}: ${s.stop.text}',
      ].join('\n');

      final first = mergeRepaste(current: current, repasted: repasted);
      final second = mergeRepaste(current: current, repasted: repasted);

      expect(describe(second), describe(first));
    });

    test('the inputs are not mutated', () {
      final currentStops = [mStop('A')];
      final current = [
        day(1, date: jun14, place: 'Tokyo', stops: currentStops),
      ];
      final parsedStops = [pStop('B')];
      final repasted = [
        pDay(1, date: DateTime(2027, 6, 14), stops: parsedStops),
      ];
      final currentBefore = current[0].stops.toList();
      final repastedBefore = repasted[0].stops.toList();

      mergeRepaste(current: current, repasted: repasted);

      expect(current[0].stops.toList(), currentBefore);
      expect(repasted[0].stops.toList(), repastedBefore);
    });
  });
}
