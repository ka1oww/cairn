// The Trail and the container it lives in, tested through the real stack: a
// plan pasted and accepted, then read back out of Drift onto the path.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app.
//
// Two things about the container shape these tests. Every tab stays alive in
// the tree (that is the point of the container), but the ones you are not
// looking at are *offstage*, and Flutter's finders skip offstage widgets —
// so a plain `find.byKey` sees only the tab you are standing on. Where a
// day page the Trail pushed has to be told apart from Today's on purpose,
// [pushedDay] does it through the back control only a pushed page draws.
// And tapping only reaches the selected tab, so every test walks through the
// tab bar rather than reaching in.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/screens/day_page.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days over four dates: 16 June is a gap the plan skips.
/// (14 June 2027 really is a Monday, 15 a Tuesday, 17 a Thursday.)
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- 09:30 Skytree

Tue 15 June 2027 - Kyoto
- 10:12 Train to Kyoto
- Fushimi Inari

Thu 17 June 2027 - Osaka
- Dotonbori
''';

/// One day, and that is the whole trip.
const oneDayPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
''';

/// Days with no dates anywhere: the plan is real, the calendar is open.
const dateOpenPaste = '''
Day 1 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

/// A dated first day and a second whose date was never given — the mixed
/// case, where one node is reachable by date and the other is not.
const halfDatedPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Day 2 - Kyoto
- Fushimi Inari
''';

DateTime day(int dayOfJune) => DateTime.utc(2027, 6, dayOfJune);

void main() {
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

  Future<void> launch(WidgetTester tester, {required DateTime today}) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(database: db, today: today));
    await tester.pump();
    await tester.pump();
  }

  Future<void> accept(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openTrail(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
  }

  Future<void> openToday(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tab-today')));
    await tester.pumpAndSettle();
  }

  /// Paste, accept, and stand on the Trail.
  Future<void> arriveOnTrail(
    WidgetTester tester, {
    required DateTime today,
    String paste = tripPaste,
  }) async {
    await launch(tester, today: today);
    await accept(tester, paste);
    await openTrail(tester);
  }

  /// Something inside the day page the Trail pushed, told apart from Today's
  /// — the back control exists only on a pushed one.
  Finder pushedDay(Key key) => find.descendant(
    of: find.ancestor(
      of: find.byKey(const Key('day-back')),
      matching: find.byType(DayPage),
    ),
    matching: find.byKey(key),
  );

  String textIn(Finder finder) =>
      (find
                  .descendant(
                    of: finder,
                    matching: find.byType(Text),
                    matchRoot: true,
                  )
                  .evaluate()
                  .first
                  .widget
              as Text)
          .data!;

  String textOf(Key key) => textIn(find.byKey(key));

  testWidgets(
    'one node per day of the plan, in itinerary order down the path',
    (tester) async {
      await arriveOnTrail(tester, today: day(15));

      expect(find.byKey(const Key('trail-node-1')), findsOneWidget);
      expect(find.byKey(const Key('trail-node-2')), findsOneWidget);
      expect(find.byKey(const Key('trail-node-3')), findsOneWidget);
      expect(find.byKey(const Key('trail-node-4')), findsNothing);

      // Down the screen in plan order, and alternating sides — the winding is
      // the screen, not decoration.
      final centres = [
        for (final n in [1, 2, 3])
          tester.getCenter(find.byKey(Key('trail-node-$n'))),
      ];
      expect(centres[0].dy, lessThan(centres[1].dy));
      expect(centres[1].dy, lessThan(centres[2].dy));
      expect(centres[0].dx, lessThan(centres[1].dx));
      expect(centres[2].dx, lessThan(centres[1].dx));
    },
  );

  testWidgets('the flag sits on today, and the header counts the day', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(15));

    expect(textOf(const Key('trail-headline')), 'Day 2 of 3');
    expect(find.byKey(const Key('trail-flag')), findsOneWidget);

    // The flag is over today's node and no other: it is nearer day 2 than
    // either neighbour, and above it.
    final flag = tester.getCenter(find.byKey(const Key('trail-flag')));
    final today = tester.getCenter(find.byKey(const Key('trail-node-2')));
    expect(flag.dy, lessThan(today.dy));
    expect((flag.dx - today.dx).abs(), lessThan(4));
    expect(find.byKey(const Key('trail-today-word')), findsOneWidget);
  });

  testWidgets('past, today and ahead are drawn as three different things', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(15));

    expect(find.byKey(const Key('trail-node-1-past')), findsOneWidget);
    expect(find.byKey(const Key('trail-node-2-today')), findsOneWidget);
    expect(find.byKey(const Key('trail-node-3-ahead')), findsOneWidget);

    // The states are sizes as well as marks: today is the largest node on
    // the path, as it is drawn.
    final sizes = {
      for (final n in [1, 2, 3])
        n: tester.getSize(find.byKey(Key('trail-node-$n'))).width,
    };
    expect(sizes[2], greaterThan(sizes[1]!));
    expect(sizes[2], greaterThan(sizes[3]!));
  });

  testWidgets('tapping a node opens the day page for that day', (tester) async {
    await arriveOnTrail(tester, today: day(15));

    await tester.tap(find.byKey(const Key('trail-node-3')));
    await tester.pumpAndSettle();

    expect(textIn(pushedDay(const Key('day-eyebrow'))), 'DAY 3 OF 3');
    expect(textIn(pushedDay(const Key('day-title'))), 'Thursday, Osaka');
    expect(textIn(pushedDay(const Key('day-date'))), '17 June');
    expect(find.text('Dotonbori'), findsOneWidget);

    // No second day surface: what the Trail opened is the day page itself.
    // One, not two — Today's copy is offstage behind the tab, and finders
    // skip offstage widgets by default.
    expect(find.byType(DayPage), findsOneWidget);

    await tester.tap(find.byKey(const Key('day-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('trail-node-3')), findsOneWidget);
  });

  testWidgets('a past day opens in the past tense, as Today renders it', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(15));

    await tester.tap(find.byKey(const Key('trail-node-1')));
    await tester.pumpAndSettle();

    expect(textIn(pushedDay(const Key('day-eyebrow'))), 'DAY 1 OF 3');
    expect(find.text('was 09:30'), findsOneWidget);
  });

  testWidgets(
    "a date-open day's node opens its day page, its date still open",
    (tester) async {
      // The whole plan is undated: no node can be reached by any date, and the
      // path is the only way to any of them.
      await arriveOnTrail(tester, today: day(15), paste: dateOpenPaste);

      expect(textOf(const Key('trail-headline')), '2 days planned');
      expect(find.byKey(const Key('trail-flag')), findsNothing);

      await tester.tap(find.byKey(const Key('trail-node-2')));
      await tester.pumpAndSettle();

      // Day two — which Today can never show, because no date selects it.
      expect(textIn(pushedDay(const Key('day-eyebrow'))), 'DAY 2 OF 2');
      expect(textIn(pushedDay(const Key('day-title'))), 'Kyoto');
      expect(textIn(pushedDay(const Key('day-date'))), 'date open');
    },
  );

  testWidgets('a date-open day beside dated ones is reachable too', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(14), paste: halfDatedPaste);

    expect(find.byKey(const Key('trail-node-1-today')), findsOneWidget);
    expect(find.byKey(const Key('trail-node-2-ahead')), findsOneWidget);

    await tester.tap(find.byKey(const Key('trail-node-2')));
    await tester.pumpAndSettle();

    expect(textIn(pushedDay(const Key('day-eyebrow'))), 'DAY 2 OF 2');
    expect(textIn(pushedDay(const Key('day-date'))), 'date open');
  });

  testWidgets('before the trip: every node ahead, and no flag', (tester) async {
    await arriveOnTrail(tester, today: day(10));

    expect(textOf(const Key('trail-headline')), 'Starts Monday');
    expect(textOf(const Key('trail-detail')), '3 days planned');
    expect(find.byKey(const Key('trail-flag')), findsNothing);

    for (final n in [1, 2, 3]) {
      expect(find.byKey(Key('trail-node-$n-ahead')), findsOneWidget);
    }
    // Day one alone wears its weekday, as surface 2b draws it.
    expect(find.text('MON'), findsOneWidget);
  });

  testWidgets('after the trip: every node past, and no flag', (tester) async {
    await arriveOnTrail(tester, today: day(20));

    expect(textOf(const Key('trail-headline')), 'The trip is walked.');
    expect(textOf(const Key('trail-detail')), '3 days, ending 17 June.');
    expect(find.byKey(const Key('trail-flag')), findsNothing);

    for (final n in [1, 2, 3]) {
      expect(find.byKey(Key('trail-node-$n-past')), findsOneWidget);
    }
  });

  testWidgets('a one-day trip is a path of one node, flagged', (tester) async {
    await arriveOnTrail(tester, today: day(14), paste: oneDayPaste);

    expect(textOf(const Key('trail-headline')), 'Day 1 of 1');
    expect(find.byKey(const Key('trail-node-1-today')), findsOneWidget);
    expect(find.byKey(const Key('trail-node-2')), findsNothing);
    expect(find.byKey(const Key('trail-flag')), findsOneWidget);
  });

  testWidgets('a date the plan skips gets no node, and no flag', (
    tester,
  ) async {
    // 16 June is inside the trip and belongs to no day of the plan. The
    // drawings number the path over the plan's own days, so there is nothing
    // for the flag to sit on and the header takes the gap day's voice.
    await arriveOnTrail(tester, today: day(16));

    expect(find.byKey(const Key('trail-node-3')), findsOneWidget);
    expect(find.byKey(const Key('trail-node-4')), findsNothing);
    expect(find.byKey(const Key('trail-flag')), findsNothing);
    expect(textOf(const Key('trail-headline')), 'Wednesday');
  });

  testWidgets('switching tabs keeps each tab where it was', (tester) async {
    await arriveOnTrail(tester, today: day(15));

    await tester.tap(find.byKey(const Key('trail-node-1')));
    await tester.pumpAndSettle();
    expect(find.text('Senso-ji'), findsOneWidget);

    // Today, then back. Day one is still open where we left it — the
    // container never throws away where you were inside a tab.
    await openToday(tester);
    expect(textOf(const Key('day-eyebrow')), 'DAY 2 OF 3');

    await openTrail(tester);
    expect(find.byKey(const Key('day-back')), findsOneWidget);
    expect(textIn(pushedDay(const Key('day-eyebrow'))), 'DAY 1 OF 3');
  });

  testWidgets('tapping the tab you are on returns it to its root', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(15));

    await tester.tap(find.byKey(const Key('trail-node-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day-back')), findsOneWidget);

    await openTrail(tester);
    expect(find.byKey(const Key('day-back')), findsNothing);
    expect(find.byKey(const Key('trail-node-1')), findsOneWidget);
  });

  testWidgets('the container holds three destinations and no fourth', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(15));

    // Surface 2e's whole structure, now that the Pool exists. Trip-level
    // actions still hang off the Trail's title rather than becoming a
    // fourth tab (6e), which is what the count here pins.
    expect(find.byKey(const Key('tab-today')), findsOneWidget);
    expect(find.byKey(const Key('tab-trail')), findsOneWidget);
    expect(find.byKey(const Key('tab-pool')), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
  });

  testWidgets('the way back to the plan hangs off the trip, not off a day', (
    tester,
  ) async {
    await arriveOnTrail(tester, today: day(15));

    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();

    // The destructive hatch is gone: the sheet's plan entries edit the trip,
    // they never offer to replace it. See paste_edit_after_accept_test.dart
    // for what each of them does.
    expect(find.byKey(const Key('start-over')), findsNothing);
    expect(find.byKey(const Key('trip-edit-plan')), findsOneWidget);

    await tester.tap(find.byKey(const Key('trip-repaste')));
    await tester.pumpAndSettle();

    final input = tester.widget<TextField>(
      find.byKey(const Key('paste-input')),
    );
    expect(input.controller!.text, isNot(''));
  });
}
