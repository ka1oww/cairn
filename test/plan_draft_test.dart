// The pending import, kept across launches — the import torture-test's R6.
//
// The reproduction it closes: import fills the box, the process dies before
// the person taps accept, and the whole read is gone. Every test here is a
// real relaunch — the widget tree is torn down to nothing and the app is
// built again over the *same* database, which is what a killed process does
// to a phone.
//
// The two CLAUDE.md widget-test traps this file is shaped around are the
// ones import_flow_test.dart names: `closeStreamsSynchronously`, and the
// extraction runner overridden to call the pure extractor directly (a real
// isolate under testWidgets' fake clock hangs silently).
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/area_gazetteer_loader.dart';
import 'package:cairn/app_state/file_picker_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:plan_extraction/plan_extraction.dart';

/// What the fake picker hands over: dated headers, so accepting it needs no
/// asks and the accept path can be walked in one tap.
const _importedPlan = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Ueno Park

Tue 15 June 2027 - Kyoto
- Fushimi Inari
''';

final _defaultToday = DateTime.utc(2027, 6, 15);

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

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

  Future<void> launch(
    WidgetTester tester, {
    List<PickedBytes?> picks = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: _defaultToday,
        picker: FakeFilePicker(picks),
        gazetteer: (compressed) async => buildAreaGazetteer(compressed),
        extraction: (extractor, file) async => extractor.extract(file),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  /// What a killed process does: the whole tree goes, the database stays.
  Future<void> relaunch(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await launch(tester);
    // One more frame than a cold start needs: the pending import is read off
    // the local row after the box is already on screen.
    await tester.pump();
  }

  String boxText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('paste-input')))
      .controller!
      .text;

  Future<void> importAFile(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-door-file')));
    await tester.pump();
    await tester.pump();
  }

  /// Lets the box's coalescing draft write land.
  Future<void> settleTheDraft(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 1));

  testWidgets('an import survives the process; the box opens as it was', (
    tester,
  ) async {
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(_importedPlan),
        ),
      ],
    );
    await importAFile(tester);
    expect(boxText(tester), _importedPlan);
    expect(await db.readPlanDraft(), _importedPlan);

    await relaunch(tester);

    expect(boxText(tester), _importedPlan);
  });

  testWidgets('accepting the plan forgets the draft', (tester) async {
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(_importedPlan),
        ),
      ],
    );
    await importAFile(tester);

    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    // The text is the trip now, so there is nothing left to keep.
    expect(await db.readPlanDraft(), isNull);
  });

  testWidgets('emptying the box discards the draft', (tester) async {
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(_importedPlan),
        ),
      ],
    );
    await importAFile(tester);
    expect(await db.readPlanDraft(), _importedPlan);

    await tester.enterText(find.byKey(const Key('paste-input')), '');
    await settleTheDraft(tester);
    expect(await db.readPlanDraft(), isNull);

    await relaunch(tester);
    expect(boxText(tester), '');
  });

  testWidgets('a fresh import replaces the last one', (tester) async {
    const second = 'Wed 16 June 2027 - Osaka\n- Dotonbori\n';
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(_importedPlan),
        ),
        PickedBytes(
          fileName: 'osaka.txt',
          extension: 'txt',
          bytes: _bytes(second),
        ),
      ],
    );
    await importAFile(tester);
    await importAFile(tester);
    await settleTheDraft(tester);

    expect(await db.readPlanDraft(), second);
    await relaunch(tester);
    expect(boxText(tester), second);
  });

  testWidgets('edits to imported text are what comes back, not the import', (
    tester,
  ) async {
    const edited = 'Mon 14 June 2027 - Tokyo\n- Senso-ji at dawn\n';
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(_importedPlan),
        ),
      ],
    );
    await importAFile(tester);

    // The draft tracks the box while it stands, so it can never be restored
    // over something the person has since typed by hand.
    await tester.enterText(find.byKey(const Key('paste-input')), edited);
    await settleTheDraft(tester);

    await relaunch(tester);
    expect(boxText(tester), edited);
  });

  testWidgets("'Try an example' does not overwrite a standing import draft", (
    tester,
  ) async {
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(_importedPlan),
        ),
      ],
    );
    await importAFile(tester);
    expect(await db.readPlanDraft(), _importedPlan);

    await tester.tap(find.byKey(const Key('try-example')));
    await settleTheDraft(tester);

    // The example is a programmatic fill, not an import: it must not
    // touch the standing draft, imported before it.
    expect(await db.readPlanDraft(), _importedPlan);

    await relaunch(tester);
    expect(boxText(tester), _importedPlan);
  });

  testWidgets('a box typed from scratch is not a draft', (tester) async {
    await launch(tester);

    await tester.enterText(
      find.byKey(const Key('paste-input')),
      'Day 1 - somewhere',
    );
    await settleTheDraft(tester);

    // Nothing was imported, so nothing is kept: the draft exists to defend
    // an expensive read, not to become a second autosaving notebook.
    expect(await db.readPlanDraft(), isNull);
    await relaunch(tester);
    expect(boxText(tester), '');
  });
}
