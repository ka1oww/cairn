// Editing a trip that is already running — design round 4's screen 3, tested
// through the real stack: a plan pasted and accepted into Drift, the same
// editor opened back over it from the trip sheet, and the change either saved
// onto the live trip or dropped without touching it.
//
// The claim under all of these is that **nothing here destroys anything.**
// The hatch that used to live on this sheet ("Paste a different plan") could
// only change a running trip's plan by throwing the trip away, and it is gone;
// what replaced it edits and merges. So each test below asserts not only that
// the new thing works but that the old plan, its set-aside lines and its
// photographs are all still where they were.
//
// closeStreamsSynchronously is load-bearing here for the same reason it is in
// paste_confirm_flow_test.dart; read that file's header before writing any
// test that pumps the app. The container's offstage rule matters too: every
// walk in goes through the tab bar, because a finder only sees the tab you
// are standing on.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Three dated days. (14 June 2027 really is a Monday, 15 a Tuesday, 16 a
/// Wednesday — the parser trusts a named weekday, so the fixture must too.)
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Ueno Park

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Wed 16 June 2027 - Osaka
- Dotonbori
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

  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: day(15),
        now: day(15),
        utcOffset: Duration.zero,
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> accept(WidgetTester tester, [String paste = tripPaste]) async {
    await tester.enterText(find.byKey(const Key('paste-input')), paste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();
  }

  Future<void> openEditor(WidgetTester tester) async {
    await openSheet(tester);
    await tester.tap(find.byKey(const Key('trip-edit-plan')));
    await tester.pumpAndSettle();
  }

  /// The plan as Drift holds it, flattened to one comparable shape.
  Future<List<String>> storedPlan() async {
    // Read, never watch: awaiting a drift stream inside testWidgets never
    // completes under the faked clock (see this project's CLAUDE.md).
    final days = await db.readItineraryDays();
    final stops = await db.readItineraryStops();
    return [
      for (final d in days)
        '${d.number}|${d.dateIso}|${d.place}|'
            '${stops.where((s) => s.dayNumber == d.number).map((s) => s.stopText).join(',')}',
    ];
  }

  Future<List<String>> storedSetAside() async =>
      (await db.readItinerarySetAsides()).map((l) => l.lineText).toList();

  String pasteBoxText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('paste-input')))
      .controller!
      .text;

  // -------------------------------------------------------------------------

  testWidgets('the way into the editor exists only once a trip is accepted', (
    tester,
  ) async {
    await launch(tester);

    // Before a plan is accepted the app is the paste box, and there is no
    // trip to hang an editor off: no sheet, and so no entry.
    expect(find.byKey(const Key('paste-input')), findsOneWidget);
    expect(find.byKey(const Key('trip-sheet-open')), findsNothing);
    expect(find.byKey(const Key('trip-edit-plan')), findsNothing);
    expect(find.byKey(const Key('trip-repaste')), findsNothing);

    await accept(tester);
    await openSheet(tester);

    expect(find.byKey(const Key('trip-edit-plan')), findsOneWidget);
    expect(find.byKey(const Key('trip-repaste')), findsOneWidget);
  });

  testWidgets('the destructive path is gone from the trip sheet', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await openSheet(tester);

    expect(find.byKey(const Key('start-over')), findsNothing);
    expect(find.text('Paste a different plan'), findsNothing);
    // Deleting stays — as a choice, never as the only path to a change.
    expect(find.byKey(const Key('trip-delete')), findsOneWidget);
  });

  testWidgets('the editor opens over the live plan, as it stands', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await openEditor(tester);

    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    expect(find.byKey(const Key('day-card-3')), findsOneWidget);
    expect(find.text('Senso-ji'), findsOneWidget);
    expect(find.text('Dotonbori'), findsOneWidget);

    // The foot says what this editor is: a save over a running trip, a way
    // out that costs nothing, and the re-paste.
    expect(find.text('Save changes'), findsOneWidget);
    expect(find.byKey(const Key('cancel-plan-edit')), findsOneWidget);
    expect(find.byKey(const Key('repaste-plan')), findsOneWidget);
  });

  testWidgets('saving applies the edit to the live trip', (tester) async {
    await launch(tester);
    await accept(tester);
    final before = await storedPlan();
    await openEditor(tester);

    // Rename day 2 through the day editor the read-back already had.
    await tester.tap(find.byKey(const Key('day-header-2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-day-input')), 'Nara');
    await tester.tap(find.byKey(const Key('rename-day-save')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // Back on the trip, and the trip is the edited one.
    expect(find.byKey(const Key('tab-today')), findsOneWidget);
    final after = await storedPlan();
    expect(after, isNot(before));
    expect(after[1], contains('Nara'));
    expect(after[0], before[0]);
    expect(after[2], before[2]);
  });

  testWidgets('cancelling leaves the live trip exactly as it was', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    final before = await storedPlan();
    await openEditor(tester);

    await tester.tap(find.byKey(const Key('day-header-2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-day-input')), 'Nara');
    await tester.tap(find.byKey(const Key('rename-day-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nara'), findsWidgets);

    await tester.tap(find.byKey(const Key('cancel-plan-edit')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('tab-today')), findsOneWidget);
    expect(await storedPlan(), before);
  });

  testWidgets('the re-paste opens the box pre-filled with the current plan', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await openEditor(tester);

    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();

    final text = pasteBoxText(tester);
    expect(text, contains('Mon 14 June 2027 - Tokyo'));
    expect(text, contains('Senso-ji'));
    expect(text, contains('Fushimi Inari'));
    expect(text, contains('Dotonbori'));
    // It is the plan's own box, not the front door's: the first-timer's two
    // pills would either clobber it or answer a question nobody asked.
    expect(find.byKey(const Key('try-example')), findsNothing);
    expect(find.byKey(const Key('build-by-hand')), findsNothing);
    expect(find.byKey(const Key('cancel-repaste')), findsOneWidget);
  });

  testWidgets('reading the pre-filled text back round-trips the plan', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    final before = await storedPlan();
    await openEditor(tester);

    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();

    // Nothing changed, so nothing was displaced.
    expect(find.text('Senso-ji'), findsOneWidget);
    expect(find.text('Dotonbori'), findsOneWidget);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(await storedPlan(), before);
    expect(await storedSetAside(), isEmpty);
  });

  testWidgets('an edited re-paste is merged into the live trip', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();

    // One line added to day 3; days 1 and 2 untouched.
    await tester.enterText(
      find.byKey(const Key('paste-input')),
      '${pasteBoxText(tester)}\nOsaka Castle',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final after = await storedPlan();
    expect(after.length, 3);
    expect(after[0], '1|2027-06-14|Tokyo|Senso-ji,Ueno Park');
    expect(after[1], '2|2027-06-15|Kyoto|Fushimi Inari');
    expect(after[2], '3|2027-06-16|Osaka|Dotonbori,Osaka Castle');
    // A merge, not a replacement: nothing had to be displaced to make room.
    expect(await storedSetAside(), isEmpty);
  });

  testWidgets('what the re-paste dropped shows in the set-aside, not a bin', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('paste-input')),
      pasteBoxText(tester).replaceAll('Ueno Park\n', ''),
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();

    // The tray says so before anything is saved. It is an expansion tile, so
    // the count is on its face and the lines are one tap in.
    expect(find.text('1 line set aside'), findsOneWidget);
    await tester.tap(find.byKey(const Key('set-aside-tile')));
    await tester.pumpAndSettle();
    expect(find.text('Ueno Park'), findsOneWidget);
    expect(find.textContaining('kept here, not deleted'), findsWidgets);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final after = await storedPlan();
    expect(after[0], '1|2027-06-14|Tokyo|Senso-ji');
    expect(await storedSetAside(), ['Ueno Park']);
  });

  testWidgets('a second read in the other dialect still merges, never replaces', (
    tester,
  ) async {
    // The trap this pins: a re-read is asked for twice. The first comes out of
    // the paste box and obviously merges; the second is the month-first card's
    // one tap, from the confirm screen, and a version that routed it by "is
    // the paste box open" would fall through to a plain parse — throwing the
    // merge away and, on save, overwriting the trip with the two lines of text
    // that happened to be in the box.
    await launch(tester);
    await accept(tester);
    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('paste-input')),
      '3/11/2027 - Tokyo\nSenso-ji',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();

    // The merge names a day the plan does not have — read day-first, 3/11 is
    // 3 November — so the plan keeps its three days and the re-paste's day is
    // appended as a fourth. A replacing read would have left one day and
    // nothing else.
    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    expect(find.byKey(const Key('day-card-4')), findsOneWidget);

    await tester.tap(find.byKey(const Key('month-first-fix')));
    await tester.pumpAndSettle();

    // Still the merge: the trip's own days are still there, and the flip
    // re-merged the same two things rather than merging into its own answer.
    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    expect(find.byKey(const Key('day-card-4')), findsOneWidget);
    expect(find.byKey(const Key('day-card-5')), findsNothing);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(await storedPlan(), [
      '1|2027-06-14|Tokyo|Senso-ji,Ueno Park',
      '2|2027-06-15|Kyoto|Fushimi Inari',
      '3|2027-06-16|Osaka|Dotonbori',
      '4|2027-03-11|Tokyo|Senso-ji',
    ]);
    expect(await storedSetAside(), isEmpty);
  });

  testWidgets('photos stay on the days a merge leaves alone', (tester) async {
    await launch(tester);
    await accept(tester);

    // A photograph on day 2, filed the way capture files one.
    await db.insertPhoto((
      id: 'photo-on-day-2',
      dayNumber: 2,
      contributorId: 'me',
      takenAtUtcIso: '2027-06-15T09:00:00.000Z',
      origin: 'capture',
      word: null,
      filePath: '/nowhere/day2.jpg',
    ));

    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('paste-input')),
      '${pasteBoxText(tester)}\nOsaka Castle',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final photos = await db.readPhotos();
    expect(photos.single.id, 'photo-on-day-2');
    expect(photos.single.dayNumber, 2);
  });
}
