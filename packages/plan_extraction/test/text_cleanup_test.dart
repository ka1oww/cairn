// What the cleanup will and will not take away. The PDF fixtures prove it on
// a real file; this proves the rule, including the cases a real fixture is a
// bad way to argue about — a coincidence that looks like furniture, and a
// number that looks like a page.
import 'package:plan_extraction/src/text_cleanup.dart';
import 'package:test/test.dart';

List<String> clean(List<List<String>> pages) =>
    cleanPaginatedText(pages).split('\n');

void main() {
  group('repeated furniture', () {
    test('a day marker is never furniture, however often it repeats', () {
      // `Day 1` and `Day 2` differ only in a digit, and the furniture rule is
      // deliberately blind to digits. A plan that prints one day per page
      // would lose every day header to that blindness, so a line has to read
      // as a phrase before it can be called furniture at all.
      final pages = [
        for (var i = 1; i <= 6; i++) ['Day $i', 'breakfast', 'a museum'],
      ];
      final out = clean(pages);
      for (var i = 1; i <= 6; i++) {
        expect(out, contains('Day $i'));
      }
    });

    test('a header on every page goes', () {
      final pages = [
        for (var i = 1; i <= 4; i++) ['Kyoto trip', 'Day $i', 'lunch'],
      ];
      expect(clean(pages), isNot(contains('Kyoto trip')));
      expect(clean(pages), contains('Day 1'));
    });

    test('a footer whose only difference is its number still goes', () {
      final pages = [
        for (var i = 1; i <= 4; i++)
          ['Day $i', 'lunch', 'Kyoto itinerary — page $i of 4'],
      ];
      expect(clean(pages).where((l) => l.contains('Kyoto itinerary')), isEmpty);
    });

    test('two pages are never enough to prove furniture', () {
      final pages = [
        ['Kyoto trip', 'Day 1'],
        ['Kyoto trip', 'Day 2'],
      ];
      expect(clean(pages).where((l) => l == 'Kyoto trip'), hasLength(2));
    });

    test('three coincidences in a long document are not furniture', () {
      // `Breakfast` heads three of ten pages. Three repeats clears the
      // count, but not the half-the-document bar — and it should not, because
      // this is somebody's plan, not a running header.
      final pages = [
        for (var i = 1; i <= 10; i++)
          [if (i <= 3) 'Breakfast' else 'Day $i', 'something'],
      ];
      expect(clean(pages).where((l) => l == 'Breakfast'), hasLength(3));
    });

    test('the same words in the middle of a page are somebody\'s stop', () {
      final pages = [
        for (var i = 1; i <= 4; i++)
          ['Kyoto trip', 'morning', 'Kyoto trip', 'evening', 'Kyoto trip'],
      ];
      // The top and bottom occurrences are furniture; the one in the middle
      // is content, and stays.
      expect(clean(pages).where((l) => l == 'Kyoto trip'), hasLength(4));
    });
  });

  group('page numbers', () {
    test('a bare number a page could be goes', () {
      final pages = [
        for (var i = 1; i <= 4; i++) ['Day $i', 'lunch', '$i'],
      ];
      expect(clean(pages).where((l) => RegExp(r'^\d$').hasMatch(l)), isEmpty);
    });

    test('a bare number no page could be stays', () {
      // The guard the garbled fixture exists for: `1900` is a year, a price,
      // a room number — anything but page 1900 of a four-page print.
      final pages = [
        for (var i = 1; i <= 4; i++) ['Day $i', '1900'],
      ];
      expect(clean(pages).where((l) => l == '1900'), hasLength(4));
    });

    test('a number that says it is a page number goes whatever it says', () {
      final pages = [
        for (var i = 1; i <= 4; i++) ['Day $i', 'lunch', 'Page 900 of 1200'],
      ];
      expect(clean(pages).where((l) => l.startsWith('Page')), isEmpty);
    });

    test("a browser's `n of total` footer goes", () {
      final pages = [
        for (var i = 1; i <= 4; i++) ['Day $i', 'lunch', '$i/4'],
      ];
      expect(clean(pages).where((l) => l.endsWith('/4')), isEmpty);
    });

    test('a bare numeric date at a page edge stays', () {
      // `14/6` and `3-11` are date headers, and a numeric date header is the
      // one line the parser most needs. No page of a four-page print is 14.
      final pages = [
        for (var i = 1; i <= 4; i++) ['14/6', 'lunch', '3-11'],
      ];
      final out = clean(pages);
      expect(out.where((l) => l == '14/6'), hasLength(4));
      expect(out.where((l) => l == '3-11'), hasLength(4));
    });

    test('a page number in the middle of a page is not touched', () {
      final pages = [
        for (var i = 1; i <= 4; i++)
          ['Day $i', 'breakfast', '2', 'lunch', 'dinner', 'a nightcap'],
      ];
      expect(clean(pages).where((l) => l == '2'), hasLength(4));
    });
  });

  group('the print furniture Wanderlog draws between stops', () {
    test('travel-time dividers go', () {
      final out = clean([
        [
          'Fushimi Inari',
          '10 min · 3.7 mi',
          'Nishiki Market',
          '1 hr 5 min • 84 km',
        ],
      ]);
      expect(out, ['Fushimi Inari', 'Nishiki Market']);
    });

    test('a stop that merely mentions a distance stays', () {
      final out = clean([
        ['walk 10 min to the station, about 1 km along the river'],
      ]);
      expect(out, ['walk 10 min to the station, about 1 km along the river']);
    });

    test('rating chips and map buttons go', () {
      final out = clean([
        ['Asahiyama Zoo', '★★★★½ 4.5 (28336)', 'View on map', 'penguins at 11'],
      ]);
      expect(out, ['Asahiyama Zoo', 'penguins at 11']);
    });

    test('a short starred stop somebody wrote stays', () {
      // The sentence guard is 60 characters, so it saves none of these: what
      // makes the chip a chip is the rating number after the stars.
      final out = clean([
        ['★ Fushimi Inari at dawn', '⭐ Asahiyama Zoo', '½ day in Otaru'],
      ]);
      expect(out, [
        '★ Fushimi Inari at dawn',
        '⭐ Asahiyama Zoo',
        '½ day in Otaru',
      ]);
    });

    test('a sentence somebody wrote survives a stray star', () {
      const line =
          '★ the one thing we absolutely must do is the penguin parade, '
          'so be there early';
      expect(
        clean([
          [line],
        ]),
        [line],
      );
    });
  });

  group("the header and footer a browser prints on a page that is the whole "
      'document', () {
    // The commonest print of all is one page long, so repetition can never
    // be proved on it. Chrome's default header and footer therefore used to
    // import as two stops, and the timestamp as a *starred* 01:55.
    List<String> romePrint() => clean([
      [
        '8/27/26, 1:55 AM',
        'Rome in four days',
        'Day 1 - Rome',
        '09:00 Colosseum before the queues',
        '13:00 Lunch in Monti',
        'Day 2 - Rome',
        '10:00 Vatican Museums',
        'file:///Users/someone/plans/rome.html 1/1',
      ],
    ]);

    test("the browser's timestamp and address are not stops", () {
      final out = romePrint();
      expect(out, isNot(contains('8/27/26, 1:55 AM')));
      expect(
        out.where((l) => l.contains('rome.html')),
        isEmpty,
        reason: 'the footer carries its folio on the same line as the address',
      );
      expect(out, contains('Day 1 - Rome'));
      expect(out, contains('09:00 Colosseum before the queues'));
      expect(out, contains('Rome in four days'));
    });

    test('a stop that merely mentions an address keeps it', () {
      final out = clean([
        [
          '10:00 Tickets at https://colosseo.it/en/visit',
          'Day 1 - Rome',
          'Booked through www.example-hotels.com, ref 88213',
        ],
      ]);
      expect(out, hasLength(3));
    });

    test('a lone date or a lone clock is never the print stamp', () {
      // Both halves are required. A date on its own heading a one-page plan
      // is the line the parser most needs; a bare clock is a stop.
      final out = clean([
        ['14/6', 'breakfast', '19:30'],
      ]);
      expect(out, ['14/6', 'breakfast', '19:30']);
    });

    test('an ISO date and time is left alone', () {
      final out = clean([
        ['2027-06-14 09:00', 'Day 1 - Rome'],
      ]);
      expect(out, contains('2027-06-14 09:00'));
    });

    test('the rule reaches the page edge only', () {
      // Two filled lines at each end are the edge; an address in the body of
      // the page is somebody's stop wherever it came from.
      final out = clean([
        [
          'Day 1 - Rome',
          '09:00 Colosseum',
          'https://colosseo.it/en/visit',
          '13:00 Lunch in Monti',
          'Day 2 - Rome',
          '10:00 Vatican Museums',
        ],
      ]);
      expect(out, contains('https://colosseo.it/en/visit'));
    });

    test('a genuine one-page plan is untouched', () {
      final plan = [
        'Rome, three days',
        'Day 1 - Rome',
        '09:00 Colosseum',
        'Day 2 - Rome',
        '10:00 Vatican Museums',
        'Day 3 - Rome',
        'Trastevere, no plan',
      ];
      expect(clean([plan]), plan);
    });

    test('a multi-page print is judged by repetition, exactly as before', () {
      // Two pages cannot prove repetition and the lone-page rule does not
      // reach them, so both footers stay — the behaviour this change was
      // required to leave alone.
      final out = clean([
        ['Day 1 - Rome', 'file:///Users/someone/plans/rome.html 1/2'],
        ['Day 2 - Rome', 'file:///Users/someone/plans/rome.html 2/2'],
      ]);
      expect(out.where((l) => l.contains('rome.html')), hasLength(2));
    });
  });

  group('the two rules above all the others', () {
    test('line order is preserved', () {
      final out = clean([
        ['one', 'two'],
        ['three', 'four'],
      ]);
      expect(out, ['one', 'two', '', 'three', 'four']);
    });

    test('lines are never joined', () {
      // A hard-wrapped stop stays two lines. Two stops the person can fix in
      // the box beats one stop silently corrupted (the plan's risk 3).
      final out = clean([
        ['dinner at the place by the river with the', 'red lanterns outside'],
      ]);
      expect(out, hasLength(2));
    });
  });

  group('invisible characters', () {
    test('non-breaking and zero-width spaces become ordinary ones', () {
      expect(normalizeLine('9:00 Fushimi​Inari'), '9:00 FushimiInari');
    });

    test('trailing and doubled whitespace is trimmed', () {
      expect(normalizeLine('  breakfast   at  eight  '), 'breakfast at eight');
    });
  });
}
