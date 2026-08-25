// The read-back as an editor: the date a day's own title named, and the
// moves a person makes on the chips before accepting.
//
// Two halves on purpose. The model half drives `PasteFlow` through a bare
// `ProviderContainer` — reordering and setting aside are list arithmetic, and
// arithmetic is cheaper and clearer to pin without a widget tree. The screen
// half pumps the real app for the two things that are genuinely about the
// interface: the date sheet the captain approved, and that a chip removed
// through its menu lands in the set-aside rather than nowhere.
//
// closeStreamsSynchronously is load-bearing in the widget half — see the
// header of paste_confirm_flow_test.dart for why.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/app_state/paste_flow.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// The five-day sample the design mock draws, with the header that used to
/// lose its date: `Day 1 - Tokyo, 14 June`.
const fiveDaySample = '''
Tokyo + Kyoto, 5 days

Day 1 - Tokyo, 14 June
Land at Haneda, hotel in Shinjuku
- Meiji Shrine walk

Day 2 - Tokyo
- TeamLab Planets 11:00
- Golden Gai at night

Day 3 - Kyoto
- Fushimi Inari
- Kinkaku-ji

Day 4 - Osaka
- Dotonbori

Day 5 - Tokyo
- Fly home
''';

/// 14 June 2027 is a Monday. Pinned so the year the suggestion works out, and
/// the weekday it shows for it, do not depend on when the suite is run.
final _today = DateTime.utc(2027, 6, 14);

void main() {
  group('the model: the moves on a draft', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer(
        overrides: [todayProvider.overrideWithValue(_today)],
      );
      addTearDown(container.dispose);
    });

    ItineraryReview read() =>
        (container.read(pasteFlowProvider) as PasteReview).review;

    PasteFlow flow() => container.read(pasteFlowProvider.notifier);

    ReviewDay dayNumbered(int n) =>
        read().days.firstWhere((d) => d.number == n);

    List<String> textsOfDay(int n) =>
        [for (final stop in dayNumbered(n).stops) stop.text];

    void paste([String text = fiveDaySample]) => flow().parse(text);

    test('a stop moves up and down inside its day', () {
      paste();
      expect(textsOfDay(3), ['Fushimi Inari', 'Kinkaku-ji']);

      // Kinkaku-ji to the front.
      flow().moveStop(dayNumbered(3).stops[1].id, toDayNumber: 3, toIndex: 0);
      expect(textsOfDay(3), ['Kinkaku-ji', 'Fushimi Inari']);

      // And back down to the end.
      flow().moveStop(dayNumbered(3).stops[0].id, toDayNumber: 3, toIndex: 2);
      expect(textsOfDay(3), ['Fushimi Inari', 'Kinkaku-ji']);
    });

    test('a slot the stop already sits at is not a move', () {
      paste();
      final before = textsOfDay(1);
      final first = dayNumbered(1).stops.first.id;

      flow().moveStop(first, toDayNumber: 1, toIndex: 0);
      flow().moveStop(first, toDayNumber: 1, toIndex: 1);

      expect(textsOfDay(1), before);
    });

    test('a stop moves to another day, at the slot it was dropped on', () {
      paste();
      final golden = dayNumbered(2).stops[1];
      expect(golden.text, 'Golden Gai at night');

      flow().moveStop(golden.id, toDayNumber: 3, toIndex: 1);

      expect(textsOfDay(2), ['TeamLab Planets 11:00']);
      expect(textsOfDay(3), ['Fushimi Inari', 'Golden Gai at night',
        'Kinkaku-ji']);
    });

    test('a moved stop keeps its time, and so keeps its star', () {
      paste();
      final teamLab = dayNumbered(2).stops.first;
      expect(teamLab.timeLabel, '11:00');

      flow().moveStop(teamLab.id, toDayNumber: 4);

      final moved = dayNumbered(4).stops.last;
      expect(moved.text, 'TeamLab Planets 11:00');
      expect(moved.timeLabel, '11:00');
      expect(moved.isStarred, isTrue);
    });

    test('removing a stop sets it aside — it is never deleted', () {
      paste();
      final meiji = dayNumbered(1).stops[1];
      expect(meiji.text, 'Meiji Shrine walk');
      final asideBefore = read().keptAside.length;

      flow().removeStop(meiji.id);

      expect(textsOfDay(1), ['Land at Haneda, hotel in Shinjuku']);
      expect(read().keptAside, hasLength(asideBefore + 1));
      final set = read().keptAside.last;
      expect(set.text, 'Meiji Shrine walk');
      expect(set.removedByPerson, isTrue);
      expect(set.explanation, contains('Removed by you'));
      expect(read().anyRemovedByPerson, isTrue);
    });

    test('a set-aside line drags back into a day', () {
      paste();
      // The preamble line the parser could not place.
      final preamble = read().keptAside.first;
      expect(preamble.text, 'Tokyo + Kyoto, 5 days');
      expect(preamble.removedByPerson, isFalse);

      flow().restoreAside(preamble.id, toDayNumber: 1, toIndex: 0);

      expect(textsOfDay(1).first, 'Tokyo + Kyoto, 5 days');
      expect(read().keptAside, isEmpty);
    });

    test('a removed stop put back is the stop it was, time and all', () {
      paste();
      final teamLab = dayNumbered(2).stops.first;
      flow().removeStop(teamLab.id);
      expect(dayNumbered(2).stops, hasLength(1));

      flow().restoreAside(read().keptAside.last.id, toDayNumber: 2, toIndex: 0);

      final back = dayNumbered(2).stops.first;
      expect(back.text, 'TeamLab Planets 11:00');
      expect(back.timeLabel, '11:00');
    });

    test('a restored line loses the bullet it was pasted with', () {
      paste('Day 1 - Tokyo\n- Senso-ji\n- https://tabelog.com/en/kyoto/\n');
      final url = read().keptAside.single;
      expect(url.text, startsWith('- '));

      flow().restoreAside(url.id, toDayNumber: 1);

      expect(dayNumbered(1).stops.last.text, 'https://tabelog.com/en/kyoto/');
    });

    test('a stop can be reworded and timed, and the time can come off', () {
      paste();
      final id = dayNumbered(4).stops.single.id;

      flow().editStopText(id, '  Dotonbori at night  ');
      expect(dayNumbered(4).stops.single.text, 'Dotonbori at night');
      expect(dayNumbered(4).stops.single.isStarred, isFalse);

      flow().setStopTime(id, 19, 30);
      expect(dayNumbered(4).stops.single.timeLabel, '19:30');
      expect(dayNumbered(4).stops.single.isStarred, isTrue);

      flow().clearStopTime(id);
      expect(dayNumbered(4).stops.single.timeLabel, isNull);
    });

    test('an empty rewording is not an edit', () {
      paste();
      final id = dayNumbered(4).stops.single.id;

      flow().editStopText(id, '   ');

      expect(dayNumbered(4).stops.single.text, 'Dotonbori');
    });

    test('a day can be renamed, and unnamed', () {
      paste();
      expect(dayNumbered(4).title, 'Osaka');

      flow().renameDay(4, 'Osaka + Nara');
      expect(dayNumbered(4).title, 'Osaka + Nara');
      expect(dayNumbered(4).place, 'Osaka + Nara');

      flow().renameDay(4, '  ');
      expect(dayNumbered(4).place, isNull);
      expect(dayNumbered(4).title, 'Day 4');
    });

    test('an empty day stops asking once something lands in it', () {
      paste('Day 1 - Tokyo\n- Senso-ji\n\nDay 2 - Hakone\n');
      expect(dayNumbered(2).doubt?.cause, DayDoubtCause.noStops);

      flow().moveStop(dayNumbered(1).stops.single.id, toDayNumber: 2);

      expect(dayNumbered(2).doubt, isNull);
    });

    test(
      'a day answered "leave it empty" asks again once emptied again',
      () {
        paste('Day 1 - Tokyo\n- Senso-ji\n\nDay 2 - Hakone\n');
        expect(dayNumbered(2).doubt?.cause, DayDoubtCause.noStops);

        flow().confirmDay(2);
        expect(dayNumbered(2).doubt, isNull);

        flow().addStop(2, 'Onsen');
        expect(dayNumbered(2).doubt, isNull);

        flow().removeStop(dayNumbered(2).stops.single.id);
        expect(dayNumbered(2).doubt?.cause, DayDoubtCause.noStops);
      },
    );

    group('the date a title named', () {
      test('is offered, not bound', () {
        paste();
        final day = dayNumbered(1);

        expect(day.date, isNull);
        expect(day.dateLabel, isNull);
        expect(day.dateSuggestion, isNotNull);
        expect(day.dateSuggestion!.dateLabel, '14 June');
        expect(day.dateSuggestion!.weekdayLabel, 'Monday');
        expect(day.dateSuggestion!.headerText, 'Tokyo, 14 June');
        expect(day.dateSuggestion!.fragment, '14 June');
        expect(day.dateSuggestion!.date, DateTime(2027, 6, 14));
        // And the place is the place, not the whole title.
        expect(day.title, 'Tokyo');
      });

      test('one tap binds it, and the offer is done', () {
        paste();

        flow().useDateSuggestion(1);

        expect(dayNumbered(1).date, DateTime(2027, 6, 14));
        expect(dayNumbered(1).dateLabel, '14 June');
        expect(dayNumbered(1).title, 'Monday · Tokyo');
        expect(dayNumbered(1).dateSuggestion, isNull);
      });

      test('leaving it open is an answer too — it is not asked again', () {
        paste();

        flow().leaveDateOpen(1);

        expect(dayNumbered(1).date, isNull);
        expect(dayNumbered(1).dateSuggestion, isNull);
      });

      test('dating the day another way puts the offer away', () {
        paste();

        flow().setDayDate(1, DateTime(2027, 7, 1));

        expect(dayNumbered(1).dateLabel, '1 July');
        expect(dayNumbered(1).dateSuggestion, isNull);
      });

      test('a year the title spelled out is used as written', () {
        paste('Day 1 - Tokyo, 14 June 2029\n- Senso-ji\n');

        final suggestion = dayNumbered(1).dateSuggestion!;
        expect(suggestion.yearWasNamed, isTrue);
        expect(suggestion.date, DateTime(2029, 6, 14));
      });

      test('a year-less date takes the year the plan is already in', () {
        // Day 1 is dated by its own header, in a year that is not this one;
        // day 2's title-date follows the plan rather than the device.
        paste('Mon 14 June 2029 - Tokyo\n'
            '- Senso-ji\n'
            '\n'
            'Day 2 - Kyoto, 15 June\n'
            '- Fushimi Inari\n');

        expect(dayNumbered(2).dateSuggestion!.date, DateTime(2029, 6, 15));
      });

      test('a date long past the reference means next year', () {
        // Nothing in the plan is dated, so the device's date answers — and
        // 14 January, read on 14 June, is the January still to come.
        paste('Day 1 - Tokyo, 14 January\n- Senso-ji\n');

        expect(dayNumbered(1).dateSuggestion!.date, DateTime(2028, 1, 14));
      });

      test('a title with no date offers nothing', () {
        paste();

        expect(dayNumbered(2).dateSuggestion, isNull);
      });
    });
  });

  group('the screen', () {
    late AppDatabase db;

    setUp(
      () => db = AppDatabase(
        DatabaseConnection(
          NativeDatabase.memory(),
          closeStreamsSynchronously: true,
        ),
      ),
    );
    tearDown(() => db.close());

    Future<void> launch(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(bootstrapApp(database: db, today: _today));
      await tester.pump();
      await tester.pump();
    }

    Future<void> paste(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const Key('paste-input')), text);
      await tester.tap(find.byKey(const Key('read-button')));
      await tester.pump();
    }

    testWidgets(
      'a date in a day title is offered on the sheet, and one tap binds it',
      (tester) async {
        await launch(tester);
        await paste(tester, fiveDaySample);

        // The day reads by its place, and the date it named is a quiet prompt
        // rather than a silent loss.
        expect(find.text('Tokyo'), findsWidgets);
        expect(find.byKey(const Key('date-prompt-1')), findsOneWidget);

        await tester.tap(find.byKey(const Key('date-prompt-1')));
        await tester.pumpAndSettle();

        // The captain-approved sheet.
        expect(
          find.text('This day has a date in its title.'),
          findsOneWidget,
        );
        expect(find.textContaining('want me to use it?'), findsOneWidget);
        expect(find.text('14 June'), findsOneWidget);
        expect(find.text('Monday · day 1'), findsOneWidget);
        expect(find.text('Use it ›'), findsOneWidget);
        expect(find.text('Pick another date'), findsOneWidget);
        expect(find.text('Leave it open'), findsOneWidget);

        await tester.tap(find.byKey(const Key('date-sheet-use-it')));
        await tester.pumpAndSettle();

        // Bound: the header carries the date, the title carries its weekday,
        // and there is nothing left to ask.
        expect(find.byKey(const Key('date-prompt-1')), findsNothing);
        expect(find.text('14 June'), findsOneWidget);
        expect(find.text('Monday · Tokyo'), findsOneWidget);

        await tester.tap(find.byKey(const Key('accept-button')));
        await tester.pump();
        await tester.pump();

        // And the accepted trip shows it — no more "date open".
        expect(find.text('Monday, Tokyo'), findsOneWidget);
        expect(find.text('14 June'), findsOneWidget);
        expect(find.text('date open'), findsNothing);
      },
    );

    testWidgets('leaving the date open is a legitimate answer', (tester) async {
      await launch(tester);
      await paste(tester, fiveDaySample);

      await tester.tap(find.byKey(const Key('date-prompt-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('date-sheet-leave-open')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('date-prompt-1')), findsNothing);
      expect(find.text('Tokyo'), findsWidgets);
    });

    testWidgets('a chip removed through its menu lands in the set-aside', (
      tester,
    ) async {
      await launch(tester);
      await paste(tester, fiveDaySample);

      expect(find.text('Meiji Shrine walk'), findsOneWidget);
      expect(find.text("1 line I couldn't place"), findsOneWidget);

      await tester.tap(find.text('Meiji Shrine walk'));
      await tester.pumpAndSettle();

      // The mock's little menu.
      expect(find.text('Edit the words'), findsOneWidget);
      expect(find.text('Give it a time'), findsOneWidget);
      expect(find.text('Move to another day'), findsOneWidget);

      await tester.tap(find.byKey(const Key('stop-menu-remove')));
      await tester.pumpAndSettle();

      // Gone from its day, kept in the tile — and the tile stops claiming it
      // could not place them.
      expect(find.text('2 lines set aside'), findsOneWidget);

      await tester.tap(find.byKey(const Key('set-aside-tile')));
      await tester.pumpAndSettle();

      expect(find.text('Meiji Shrine walk'), findsOneWidget);
      expect(find.textContaining('Removed by you'), findsOneWidget);
    });

    testWidgets('a chip can be reworded through its menu', (tester) async {
      await launch(tester);
      await paste(tester, fiveDaySample);

      await tester.tap(find.text('Dotonbori'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stop-menu-edit')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('edit-stop-input')),
        'Dotonbori at night',
      );
      await tester.tap(find.byKey(const Key('edit-stop-save')));
      await tester.pumpAndSettle();

      expect(find.text('Dotonbori at night'), findsOneWidget);
      expect(find.text('Dotonbori'), findsNothing);
    });

    testWidgets('a day header renames the day', (tester) async {
      await launch(tester);
      await paste(tester, fiveDaySample);

      // Day 2's title named no date, so its header opens the day editor.
      await tester.tap(find.byKey(const Key('day-header-2')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('rename-day-input')),
        'Tokyo, slowly',
      );
      await tester.tap(find.byKey(const Key('rename-day-save')));
      await tester.pumpAndSettle();

      expect(find.text('Tokyo, slowly'), findsOneWidget);
    });

    testWidgets('a stop moves to another day without a drag', (tester) async {
      await launch(tester);
      await paste(tester, fiveDaySample);

      await tester.tap(find.text('Fly home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stop-menu-move')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('move-to-day-4')));
      await tester.pumpAndSettle();

      // Day 5 is empty now, and says so rather than looking finished.
      expect(
        find.textContaining('Found the day, nothing in it'),
        findsOneWidget,
      );

      // Day 4 has both stops. A day asking a question collapses the clean
      // days to slim rows, so day 4 is counted there rather than drawn as
      // chips — the count is what the screen shows, so the count is what
      // this asserts.
      expect(
        find.descendant(
          of: find.byKey(const Key('day-card-4')),
          matching: find.text('2 stops'),
        ),
        findsOneWidget,
      );
    });
  });
}
