// The paste-and-confirm flow, tested through the real stack: pasted text
// parsed on the phone, doubt surfaced per day, corrections applied in a tap,
// and the accepted itinerary persisted into Drift and read back — the same
// end-to-end claim the retired stack_wiring_test made for the scaffold, now
// made by the first real screens.
//
// closeStreamsSynchronously is load-bearing, not a nicety. When the widget
// tree unmounts at the end of a testWidgets body, the provider's stream
// subscription detaches inside the test's fake-async zone; without this
// flag drift defers the stream's shutdown by one event-loop timer, which is
// scheduled in that zone and can never fire once the test body returns —
// and tearDown's db.close() then waits on it forever. This hang is silent
// (0% CPU, no timeout: testWidgets ignores --timeout) and was found the
// hard way; drift documents the flag for exactly this situation.
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';

/// Every day dated and placed, one stop starred by its unhedged time.
/// (14 June 2027 really is a Monday; the parser trusts the named weekday,
/// so the fixture must too.)
const cleanPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Ueno Park

Tue 15 June 2027 - Kyoto
- 10:12 Train to Kyoto
- Fushimi Inari

Wed 16 June 2027 - Kyoto
- Kinkaku-ji
''';

/// Day 2 is only what the plan calls it — a weekday with no date. Where it
/// sits it would be 15 June 2027, a Tuesday, not the named Thursday.
const unsureWeekdayPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Thursday - Kyoto
- Fushimi Inari
''';

/// Numeric slash dates that read both ways round: 3/11 is 3 November
/// day-first, March 11th month-first.
const ambiguousDatesPaste = '''
3/11/2027 - Tokyo
- Senso-ji

4/11/2027 - Kyoto
- Fushimi Inari
''';

/// Three lines the parser sets aside: preamble chat, a bare URL, a booking
/// reference. None may be silently dropped.
const setAsidePaste = '''
sooo excited!!
Mon 14 June 2027 - Tokyo
- Senso-ji
- https://tabelog.com/en/kyoto/
Booking ref: ABC123
''';

/// A found day with nothing under it.
const noStopsPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji

Tue 15 June 2027 - Hakone
''';

/// No day headers anywhere — the paste that wouldn't parse.
const banterPaste = '''
sooo excited!!
remember yen cash + passports
see everyone at changi, gate B5
''';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase(DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      )));
  tearDown(() => db.close());

  Future<void> launch(WidgetTester tester) async {
    // Tall viewport so the whole confirmation ListView builds without
    // scroll choreography in every test.
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(bootstrapApp(database: db));
    await tester.pump();
    await tester.pump();
  }

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
  }

  testWidgets('a phone with nothing saved opens on the paste box',
      (tester) async {
    await launch(tester);

    expect(find.byKey(const Key('paste-input')), findsOneWidget);
    expect(find.byKey(const Key('read-button')), findsOneWidget);
  });

  testWidgets('a confident parse reads as a glance, stars only found times',
      (tester) async {
    await launch(tester);
    await paste(tester, cleanPaste);

    expect(find.text('3 days, 5 stops.'), findsOneWidget);
    // One star: the one stop whose line carried an unhedged clock time.
    expect(find.byIcon(Icons.star), findsOneWidget);
    expect(find.text('10:12'), findsOneWidget);
    // Every day shown in full, dated, no doubt copy anywhere.
    expect(find.text('Monday · Tokyo'), findsOneWidget);
    expect(find.text('14 June'), findsOneWidget);
    expect(find.textContaining('your eye'), findsNothing);
    expect(find.byKey(const Key('accept-button')), findsOneWidget);
  });

  testWidgets(
      'a weekday with no date is asked about, and one tap answers it',
      (tester) async {
    await launch(tester);
    await paste(tester, unsureWeekdayPaste);

    // The doubt is surfaced, cause-specific: the header named Thursday, the
    // slot it sits in would be Tuesday the 15th.
    expect(find.textContaining('One needs your eye'), findsOneWidget);
    expect(
      find.textContaining('The plan calls this one Thursday'),
      findsOneWidget,
    );
    expect(find.textContaining("it'd be the 15th — a Tuesday"), findsOneWidget);
    expect(find.text('date open'), findsOneWidget);
    // The quoted title: only what the plan called the day.
    expect(find.text('"Thursday" · Kyoto'), findsOneWidget);
    // Both round-8 answers offered: where it sits, or the named weekday.
    expect(find.text("It's the 15th"), findsOneWidget);
    expect(find.text('Move it to Thu the 17th'), findsOneWidget);

    await tester.tap(find.text("It's the 15th"));
    await tester.pump();

    // Answered: no doubt left, the day is dated and titled by its real
    // weekday.
    expect(find.text('2 days, 2 stops.'), findsOneWidget);
    expect(find.text('Tuesday · Kyoto'), findsOneWidget);
    expect(find.text('15 June'), findsOneWidget);
    expect(find.text('date open'), findsNothing);
  });

  testWidgets('ambiguous numeric dates offer the one-tap month-first re-read',
      (tester) async {
    await launch(tester);
    await paste(tester, ambiguousDatesPaste);

    // Read day-first: 3/11 is 3 November.
    expect(find.text('3 November'), findsOneWidget);
    expect(find.text('4 November'), findsOneWidget);

    await tester.tap(find.byKey(const Key('month-first-fix')));
    await tester.pump();

    // One tap re-read the whole paste month-first.
    expect(find.text('11 March'), findsOneWidget);
    expect(find.text('11 April'), findsOneWidget);
    expect(find.text('3 November'), findsNothing);
    // And the door back is open.
    expect(find.text('Read day-first instead'), findsOneWidget);
  });

  testWidgets('set-aside lines are shown kept, each with its reason',
      (tester) async {
    await launch(tester);
    await paste(tester, setAsidePaste);

    expect(find.text("3 lines I couldn't place"), findsOneWidget);

    await tester.tap(find.byKey(const Key('set-aside-tile')));
    await tester.pumpAndSettle();

    // Each kept line beside the parser's person-showable reason.
    expect(find.text('sooo excited!!'), findsOneWidget);
    expect(find.textContaining('before the first day'), findsOneWidget);
    expect(find.textContaining('only a web link'), findsOneWidget);
    expect(find.text('Booking ref: ABC123'), findsOneWidget);
    expect(find.textContaining('booking confirmation'), findsOneWidget);
  });

  testWidgets('a day with no stops asks, and may be left empty on purpose',
      (tester) async {
    await launch(tester);
    await paste(tester, noStopsPaste);

    expect(find.textContaining('Found the day, nothing in it'), findsOneWidget);

    await tester.tap(find.text('leave it empty'));
    await tester.pump();

    expect(find.text('2 days, 1 stop.'), findsOneWidget);
    expect(find.textContaining('Found the day'), findsNothing);
  });

  testWidgets('a paste with no findable days is a kept dead end, not an error',
      (tester) async {
    await launch(tester);
    await paste(tester, banterPaste);

    expect(
      find.text('No days in this one — that I could find.'),
      findsOneWidget,
    );
    // The lines are visibly kept.
    expect(find.text('remember yen cash + passports'), findsOneWidget);
    expect(find.byKey(const Key('accept-button')), findsNothing);

    await tester.tap(find.byKey(const Key('paste-something-else')));
    await tester.pump();

    // Back at the paste box with the paste still there — nothing thrown away.
    final input = tester.widget<TextField>(
      find.byKey(const Key('paste-input')),
    );
    expect(input.controller!.text, banterPaste);
  });

  testWidgets(
      'accepting persists through the seam into Drift and survives a relaunch',
      (tester) async {
    await launch(tester);
    await paste(tester, setAsidePaste);
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    // The launch surface switched on its own: the itinerary is the app's
    // home now, read back from the store.
    expect(find.text('The plan is on this phone.'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('saved-summary'))).data,
      '1 day · 1 stop',
    );
    expect(find.text('3 lines kept aside, with reasons.'), findsOneWidget);

    // Relaunch: a fresh widget tree and fresh providers over the same
    // database file stand in for killing and reopening the app.
    await tester.pumpWidget(bootstrapApp(database: db));
    await tester.pump();
    await tester.pump();

    expect(find.text('The plan is on this phone.'), findsOneWidget);
    expect(find.text('Monday · Tokyo'), findsOneWidget);
    expect(find.textContaining('14 June'), findsOneWidget);
  });

  testWidgets('an answered doubt is what gets persisted', (tester) async {
    await launch(tester);
    await paste(tester, unsureWeekdayPaste);
    await tester.tap(find.text("It's the 15th"));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    expect(find.text('The plan is on this phone.'), findsOneWidget);
    // The picked date came back out of the store, not just the screen.
    expect(find.text('Tuesday · Kyoto'), findsOneWidget);
    expect(find.textContaining('15 June'), findsOneWidget);
  });
}
