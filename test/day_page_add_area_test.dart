// The day page's add-area door for a stop the parser stayed silent on: the
// confirm screen's "+ Add an area", drawn once at the head of the silent
// run where a heading would stand, over the same dialog with the plan's own
// areas nearest first. An answer is written as the person's — it outranks
// the parser, rides re-paste, and syncs like any other correction.
//
// Seeded plans use the same real-stack harness as maps_sheet_test.dart; the
// re-paste test pastes through the real screens the way add_area_fallback_test
// does. See paste_confirm_flow_test.dart's header for why the database is
// opened with `closeStreamsSynchronously`.
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/day_view.dart';
import 'package:cairn/app_state/link_opener_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:cairn_model/cairn_model.dart';

/// The day every seeded test lands on: the plan's own first day.
final _today = DateTime.utc(2027, 6, 14);

/// A silent stop between two stops whose areas the plan states — the same
/// shape the confirm screen's fallback is tested against.
const silentBetweenPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji in Asakusa
- Standing sushi bar
- Ueno Park in Ueno
''';

void main() {
  late AppDatabase db;
  late RecordingLinkOpener opener;

  setUp(() {
    db = AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
    opener = RecordingLinkOpener();
  });
  tearDown(() => db.close());

  /// The walkthrough day: an Asakusa run, a stop with no area, a Ueno run.
  Future<void> seed([List<Stop>? stops]) => TripRepository(db).saveItinerary(
    ConfirmedItinerary(
      days: [
        ConfirmedDay(
          number: 1,
          date: CalendarDate(2027, 6, 14),
          place: 'Tokyo',
          stops:
              stops ??
              [
                Stop(
                  text: 'Senso-ji',
                  area: 'Asakusa',
                  areaSource: AreaSource.parser,
                ),
                Stop(text: 'Standing sushi bar (the cheap good one)'),
                Stop(
                  text: 'Ueno Park and the museums',
                  area: 'Ueno',
                  areaSource: AreaSource.parser,
                ),
              ],
        ),
      ],
    ),
  );

  Future<void> openTheDay(
    WidgetTester tester, {
    Size size = const Size(900, 2000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(database: db, today: _today, linkOpener: opener),
    );
    await tester.pump();
    await tester.pump();
  }

  /// The pasted plan, accepted, landing on the same day page.
  Future<void> pasteAndAccept(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('paste-input')), text);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  /// Day 1 as the view model derives it — the state under the screen.
  PlannedDay dayOne(WidgetTester tester) {
    final container = ProviderScope.containerOf(
      tester.element(find.byKey(const Key('stop-1'))),
    );
    return container.read(planDayViewProvider(1)).value! as PlannedDay;
  }

  testWidgets('a silent run is offered the confirm screen\'s affordance, '
      'and only at the run\'s head', (tester) async {
    await seed();
    await openTheDay(tester);

    // The one silent run gets one door, at the head — where a heading would
    // stand. The headed runs either side get their headings, not doors.
    expect(find.byKey(const Key('add-area-1-2')), findsOneWidget);
    expect(find.text('+ Add an area'), findsOneWidget);
    expect(find.byKey(const Key('add-area-1-1')), findsNothing);
    expect(find.byKey(const Key('add-area-1-3')), findsNothing);

    // The state behind it: every stop starts a run here (areas never
    // repeat adjacently), only the silent one is asked, and its candidates
    // are its neighbours nearest first.
    final day = dayOne(tester);
    expect(day.stops.map((s) => s.startsAreaRun), [true, true, true]);
    expect(day.stops[1].areaCandidates, ['Asakusa', 'Ueno']);
    expect(day.stops[0].areaCandidates, isEmpty);
    expect(day.stops[2].areaCandidates, isEmpty);
  });

  testWidgets('a day where every stop has an area offers no door', (
    tester,
  ) async {
    await seed([
      Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
      Stop(text: 'Ueno Park', area: 'Ueno', areaSource: AreaSource.parser),
    ]);
    await openTheDay(tester);

    expect(find.text('+ Add an area'), findsNothing);
    expect(find.byKey(const Key('area-heading-1-Asakusa')), findsOneWidget);
    expect(find.byKey(const Key('area-heading-2-Ueno')), findsOneWidget);
  });

  testWidgets('one tap answers the silent run as the person', (tester) async {
    await seed();
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('add-area-1-2')));
    await tester.pumpAndSettle();

    // The confirm screen's dialog, keys and all: nearest first on screen.
    expect(find.text('Add an area'), findsOneWidget);
    expect(find.byKey(const Key('add-area-input')), findsOneWidget);
    expect(find.byKey(const Key('add-area-choice-Asakusa')), findsOneWidget);
    expect(find.byKey(const Key('add-area-choice-Ueno')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('add-area-choice-Asakusa'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('add-area-choice-Ueno'))).dy,
      ),
    );

    await tester.tap(find.byKey(const Key('add-area-choice-Asakusa')));
    await tester.pumpAndSettle();

    // The door is gone — the run now has an area — and the stop searches
    // with it.
    expect(find.text('+ Add an area'), findsNothing);
    await tester.tap(find.byKey(const Key('stop-tap-2')));
    await tester.pump();
    expect(
      opener.lastUri!.queryParameters['query'],
      'Standing sushi bar (the cheap good one), Asakusa',
    );

    // Stored as the person's, which is what outranks the parser.
    final stored = await db.readItineraryStops();
    expect(stored[1].areaText, 'Asakusa');
    expect(stored[1].areaSource, 'human');
    expect(stored[0].areaSource, 'parser');
    expect(stored[2].areaText, 'Ueno');
  });

  testWidgets('one affordance answers a run of two silent stops', (
    tester,
  ) async {
    await seed([
      Stop(text: 'Senso-ji', area: 'Asakusa', areaSource: AreaSource.parser),
      Stop(text: 'Standing sushi bar'),
      Stop(text: 'Yanaka Ginza shopping street'),
      Stop(
        text: 'Ueno Park and the museums',
        area: 'Ueno',
        areaSource: AreaSource.parser,
      ),
    ]);
    await openTheDay(tester);

    // One door for the whole run, at its head — stop 3 is inside the run,
    // not the start of a new one.
    expect(find.byKey(const Key('add-area-1-2')), findsOneWidget);
    expect(find.byKey(const Key('add-area-1-3')), findsNothing);

    await tester.tap(find.byKey(const Key('add-area-1-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-area-choice-Asakusa')));
    await tester.pumpAndSettle();

    expect(find.text('+ Add an area'), findsNothing);
    await tester.tap(find.byKey(const Key('stop-tap-3')));
    await tester.pump();
    expect(
      opener.lastUri!.queryParameters['query'],
      'Yanaka Ginza shopping street, Asakusa',
    );

    // Both silent stops answered as the person's; either side untouched.
    final stored = await db.readItineraryStops();
    expect(stored[1].areaText, 'Asakusa');
    expect(stored[1].areaSource, 'human');
    expect(stored[2].areaText, 'Asakusa');
    expect(stored[2].areaSource, 'human');
    expect(stored[0].areaSource, 'parser');
    expect(stored[3].areaText, 'Ueno');
    expect(stored[3].areaSource, 'parser');
  });

  testWidgets('the field names somewhere the plan never does', (tester) async {
    await seed();
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('add-area-1-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('add-area-input')),
      'Nakameguro',
    );
    await tester.tap(find.byKey(const Key('add-area-save')));
    await tester.pumpAndSettle();

    // A heading appears over the answered run, as for any other area.
    expect(find.byKey(const Key('area-heading-2-Nakameguro')), findsOneWidget);
    final stored = await db.readItineraryStops();
    expect(stored[1].areaText, 'Nakameguro');
    expect(stored[1].areaSource, 'human');
  });

  testWidgets('the keyboard alone answers the field', (tester) async {
    await seed();
    await openTheDay(tester);

    await tester.tap(find.byKey(const Key('add-area-1-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('add-area-input')),
      '  Nakameguro  ',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('area-heading-2-Nakameguro')), findsOneWidget);
    final stored = await db.readItineraryStops();
    expect(stored[1].areaText, 'Nakameguro');
    expect(stored[1].areaSource, 'human');
  });

  testWidgets('an inert line with no area gets the door, and a plan naming '
      'no area keeps the blank field', (tester) async {
    await seed([
      Stop(text: 'Hotel Wi-Fi: SakuraInn-5G, pass 8811', kind: StopKind.note),
    ]);
    await openTheDay(tester);

    // A line that opens no maps search still has a way to be given an area.
    expect(find.byKey(const Key('add-area-1-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-area-1-1')));
    await tester.pumpAndSettle();

    // The plan names no area anywhere: no candidates, just the field —
    // exactly the dialog the confirm screen shows in the same case.
    expect(find.text('Add an area'), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(TextButton)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(FilledButton)),
      findsOneWidget,
    );
    expect(find.byKey(const Key('add-area-input')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('add-area-input')),
      'Shinagawa',
    );
    await tester.tap(find.byKey(const Key('add-area-save')));
    await tester.pumpAndSettle();

    final stored = await db.readItineraryStops();
    expect(stored.single.areaText, 'Shinagawa');
    expect(stored.single.areaSource, 'human');
  });

  testWidgets('candidates reach across the plan, in plan order, after the '
      'day\'s own nearest', (tester) async {
    await TripRepository(db).saveItinerary(
      ConfirmedItinerary(
        days: [
          ConfirmedDay(
            number: 1,
            date: CalendarDate(2027, 6, 14),
            place: 'Tokyo',
            // One stop, no area either side: nothing near, so only the
            // rest of the plan can be offered.
            stops: [Stop(text: 'Standing sushi bar')],
          ),
          ConfirmedDay(
            number: 2,
            date: CalendarDate(2027, 6, 15),
            place: 'Osaka',
            stops: [
              Stop(
                text: 'Senso-ji',
                area: 'Asakusa',
                areaSource: AreaSource.travellerOwn,
              ),
              Stop(
                text: 'Ueno Park',
                area: 'Ueno',
                areaSource: AreaSource.travellerOwn,
              ),
            ],
          ),
        ],
      ),
    );
    await openTheDay(tester);

    final day = dayOne(tester);
    expect(day.stops.single.startsAreaRun, isTrue);
    expect(day.stops.single.areaCandidates, ['Asakusa', 'Ueno']);
  });

  testWidgets('the answer survives a re-paste that stays silent', (
    tester,
  ) async {
    await openTheDay(tester, size: const Size(800, 2600));
    await pasteAndAccept(tester, silentBetweenPaste);

    // The door on the day page this time, not the confirm screen's twin.
    await tester.tap(find.byKey(const Key('add-area-1-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-area-choice-Asakusa')));
    await tester.pumpAndSettle();

    // The editor round trip over the unchanged plan text: the re-parse
    // stays silent on the stop, exactly as the first one did.
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-edit-plan')));
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('paste-input')), findsNothing);

    final stored = await db.readItineraryStops();
    final answered = stored.firstWhere(
      (s) => s.stopText == 'Standing sushi bar',
    );
    expect(
      answered.areaText,
      'Asakusa',
      reason:
          'a later parse staying silent must not overwrite the person\'s '
          'answer with nothing',
    );
    expect(answered.areaSource, 'human');
  });
}
