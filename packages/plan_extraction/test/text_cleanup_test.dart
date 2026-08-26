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
