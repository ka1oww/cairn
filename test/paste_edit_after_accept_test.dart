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
///
/// Day 3's last two lines are the round trip's hard case, and they are here on
/// purpose: `Nara Park` is a bare proper noun with a timed line under it, which
/// is exactly what the parser reads as a day header when it arrives without a
/// bullet. A rendering that dropped the bullets splits day 3 here.
const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Ueno Park

Tue 15 June 2027 - Kyoto
- Fushimi Inari

Wed 16 June 2027 - Osaka
- Dotonbori
- Nara Park
- 10:00 Coffee
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

    // Nothing changed, so nothing was displaced — and day 3 is still one day
    // rather than two, which is the bullet doing its work.
    expect(find.text('Senso-ji'), findsOneWidget);
    expect(find.text('Dotonbori'), findsOneWidget);
    expect(find.byKey(const Key('day-card-3')), findsOneWidget);
    expect(find.byKey(const Key('day-card-4')), findsNothing);

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
    expect(
      after[2],
      '3|2027-06-16|Osaka|Dotonbori,Nara Park,10:00 Coffee,Osaka Castle',
    );
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
      pasteBoxText(tester).replaceAll('- Ueno Park\n', ''),
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
      '3|2027-06-16|Osaka|Dotonbori,Nara Park,10:00 Coffee',
      '4|2027-03-11|Tokyo|Senso-ji',
    ]);
    expect(await storedSetAside(), isEmpty);
  });

  testWidgets('a day the re-paste adds still gets asked about its date', (
    tester,
  ) async {
    // The merge does not carry a date a day's own title only *named* — the
    // parser hands that back as a candidate, and the phone asks. A merge that
    // pinned every day to Confidence.high and dropped the candidate would draw
    // the new day clean and save it with its date silently open.
    await launch(tester);
    await accept(tester);
    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('paste-input')),
      '${pasteBoxText(tester)}\nDay 4 - Nara, 17 June\n- Todai-ji',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();

    // The offer is on day 4's header, and only on day 4's: the other three
    // were dated before the trip started.
    expect(find.byKey(const Key('date-prompt-4')), findsOneWidget);
    expect(find.byKey(const Key('date-prompt-1')), findsNothing);

    await tester.tap(find.byKey(const Key('date-prompt-4')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('date-sheet-use-it')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final after = await storedPlan();
    expect(after.length, 4);
    expect(after[3], '4|2027-06-17|Nara|Todai-ji');
  });

  testWidgets('"Back to the text" gives the text back, and still merges', (
    tester,
  ) async {
    // The nothing-read state over a running trip: the person emptied the box
    // down to something with no days in it. The way out must hand back the
    // text they just read — and must not re-freeze the merge baseline from
    // that dayless draft, or the next read would merge into nothing, which is
    // a replacement wearing a merge's clothes.
    await launch(tester);
    await accept(tester);
    final before = await storedPlan();
    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('paste-input')),
      'just some words about the trip',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('paste-something-else')), findsOneWidget);

    await tester.tap(find.byKey(const Key('paste-something-else')));
    await tester.pumpAndSettle();

    // The text is back, not an empty box, and this is still the re-paste door.
    expect(pasteBoxText(tester), 'just some words about the trip');
    expect(find.byKey(const Key('cancel-repaste')), findsOneWidget);

    // And a good read from here merges into the ORIGINAL plan: a text saying
    // only day 1, and saying it without Ueno Park, takes day 1 over and
    // displaces that one line while days 2 and 3 stay exactly as they were.
    // Merged into an empty baseline there would be no day 1 to take over,
    // nothing to displace, and the trip would have been quietly replaced.
    await tester.enterText(
      find.byKey(const Key('paste-input')),
      'Mon 14 June 2027 - Tokyo\n- Senso-ji\n',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    expect(find.text('1 line set aside'), findsOneWidget);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(before, hasLength(3));
    expect(await storedPlan(), [
      '1|2027-06-14|Tokyo|Senso-ji',
      '2|2027-06-15|Kyoto|Fushimi Inari',
      '3|2027-06-16|Osaka|Dotonbori,Nara Park,10:00 Coffee',
    ]);
    expect(await storedSetAside(), ['Ueno Park']);
  });

  testWidgets('a line the re-paste displaced still reads "set aside" after a '
      'save and a reopen', (tester) async {
    await launch(tester);
    await accept(tester);
    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('paste-input')),
      pasteBoxText(tester).replaceAll('- Ueno Park\n', ''),
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    await openEditor(tester);
    await tester.tap(find.byKey(const Key('set-aside-tile')));
    await tester.pumpAndSettle();

    // The person's own re-paste displaced it, so the tray owns it as theirs.
    expect(find.text('Ueno Park'), findsOneWidget);
    expect(find.textContaining('set aside'), findsWidgets);
    expect(find.textContaining("couldn't place"), findsNothing);
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

  testWidgets('a re-paste of a bare place name above a timed line keeps its '
      'day, and its photographs', (tester) async {
    // The whole round trip on the shape that used to break it: a bulleted
    // proper-noun stop with a timed stop under it. Rendered without a bullet,
    // `Ueno Park` came back as a day of its own — day 1 was emptied, the line
    // was filed in the set-aside as displaced, and day 1's photographs stayed
    // on a day that no longer said anything.
    await launch(tester);
    await accept(tester, 'Day 1 - Tokyo\n- Ueno Park\n- 10:00 Coffee\n');

    await db.insertPhoto((
      id: 'photo-on-day-1',
      dayNumber: 1,
      contributorId: 'me',
      takenAtUtcIso: '2027-06-15T09:00:00.000Z',
      origin: 'capture',
      word: null,
      filePath: '/nowhere/day1.jpg',
    ));

    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    expect(find.byKey(const Key('day-card-2')), findsNothing);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(await storedPlan(), ['1|null|Tokyo|Ueno Park,10:00 Coffee']);
    expect(await storedSetAside(), isEmpty);

    final photos = await db.readPhotos();
    expect(photos.single.dayNumber, 1);
  });
}
