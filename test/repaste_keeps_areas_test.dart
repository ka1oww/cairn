// A stop's area is a fact about the stop, and the person outranks the parser
// — so an area correction made on the phone must survive the plan being
// edited and re-pasted. The path that used to lose it: opening the editor
// froze the merge baseline through a conversion that built each stop from
// its text and time alone, so every `kind`, `area` and `areaSource` fell off
// before the merge could carry them, and Save wrote the plan back stripped.
//
// Same real-stack harness as paste_edit_after_accept_test.dart; its header
// explains closeStreamsSynchronously and the offstage rule.
import 'package:cairn_model/cairn_model.dart';
import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/bootstrap.dart';
import 'package:cairn/repositories/trip_repository.dart';
import 'package:cairn/storage/drift/app_database.dart';

const tripPaste = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Ueno Park

Tue 15 June 2027 - Kyoto
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

  Future<void> accept(WidgetTester tester) async {
    await tester.enterText(find.byKey(const Key('paste-input')), tripPaste);
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
  }

  Future<void> openEditor(WidgetTester tester) async {
    // Settle first: the correction just written stamps its day and the
    // trip's streams re-emit, so the tab bar may be mid-rebuild.
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('tab-trail')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-sheet-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trip-edit-plan')));
    await tester.pumpAndSettle();
    // The editor really opened — every assertion after a save depends on the
    // save having actually run, so the walk in may not silently miss.
    expect(find.text('Save changes'), findsOneWidget);
  }

  Future<ItineraryStop> storedStop(String text) async =>
      (await db.readItineraryStops()).firstWhere((s) => s.stopText == text);

  testWidgets("a person's area correction survives an unchanged re-paste", (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);

    // The correction, written the way the maps sheet writes one.
    await TripRepository(db).setStopAreas(
      dayNumber: 1,
      positions: [0],
      area: 'Asakusa',
      areaSource: AreaSource.human,
      at: day(15),
    );

    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('day-card-1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    // Back on the trip: the save genuinely ran.
    expect(find.byKey(const Key('paste-input')), findsNothing);

    final corrected = await storedStop('Senso-ji');
    expect(corrected.areaText, 'Asakusa',
        reason: 'the merge baseline must carry the stored area — a baseline '
            'built from text and time alone strips it on Save');
    expect(corrected.areaSource, 'human');
  });

  testWidgets('the correction also survives a re-paste that changes another '
      'day', (tester) async {
    await launch(tester);
    await accept(tester);
    await TripRepository(db).setStopAreas(
      dayNumber: 1,
      positions: [1],
      area: 'Ueno',
      areaSource: AreaSource.human,
      at: day(15),
    );

    await openEditor(tester);
    await tester.tap(find.byKey(const Key('repaste-plan')));
    await tester.pumpAndSettle();
    final box = tester
        .widget<TextField>(find.byKey(const Key('paste-input')))
        .controller!
        .text;
    await tester.enterText(
      find.byKey(const Key('paste-input')),
      '$box\nKiyomizu-dera',
    );
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final corrected = await storedStop('Ueno Park');
    expect(corrected.areaText, 'Ueno');
    expect(corrected.areaSource, 'human');
    // And the added line really landed, so this was a genuine merge.
    expect((await db.readItineraryStops()).map((s) => s.stopText),
        contains('Kiyomizu-dera'));
  });

  testWidgets('a plain editor save keeps areas too, without any re-paste', (
    tester,
  ) async {
    await launch(tester);
    await accept(tester);
    await TripRepository(db).setStopAreas(
      dayNumber: 2,
      positions: [0],
      area: 'Fushimi',
      areaSource: AreaSource.human,
      at: day(15),
    );

    await openEditor(tester);
    // A real edit, so the assertion below can only pass if the save wrote:
    // renaming the corrected stop's own day rewrites that day's stops.
    await tester.tap(find.byKey(const Key('day-header-2')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-day-input')), 'Nara');
    await tester.tap(find.byKey(const Key('rename-day-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    final days = await db.readItineraryDays();
    expect(days.firstWhere((d) => d.number == 2).place, 'Nara',
        reason: 'the rename proves the save rewrote day 2');
    final corrected = await storedStop('Fushimi Inari');
    expect(corrected.areaText, 'Fushimi');
    expect(corrected.areaSource, 'human');
  });
}
