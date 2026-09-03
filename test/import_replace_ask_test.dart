// Two guards on the paste box's own content, both the same design rule.
//
// A file import used to replace a non-empty box silently — a typed half-plan,
// an earlier import, anything — with no way back, because pre-accept text is
// kept nowhere else. Now the one destructive landing asks first, in the box's
// own voice, and declining costs nothing. And the two starter pills, whose
// only job is to fill an empty box, are absent (not disabled) once the box
// holds anything — the same treatment the re-paste branch already gives them.
//
// Harness is import_flow_test.dart's: the picker and extraction seams bound
// to fakes, closeStreamsSynchronously load-bearing as ever.
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/area_gazetteer_loader.dart';
import 'package:cairn/app_state/file_picker_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:plan_extraction/plan_extraction.dart';

const importedPlan = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
''';

const typedPlan = 'Day 1 - Kyoto\n- Fushimi Inari';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

PickedBytes _txt(String text) =>
    PickedBytes(fileName: 'plan.txt', extension: 'txt', bytes: _bytes(text));

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
        today: DateTime.utc(2027, 6, 15),
        picker: FakeFilePicker(picks),
        gazetteer: (compressed) async => buildAreaGazetteer(compressed),
        extraction: (extractor, file) async => extractor.extract(file),
      ),
    );
    await tester.pump();
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
    await tester.pumpAndSettle();
  }

  testWidgets('an import into an empty box lands without asking', (
    tester,
  ) async {
    await launch(tester, picks: [_txt(importedPlan)]);

    await importAFile(tester);

    expect(find.byKey(const Key('import-replace-ask')), findsNothing);
    expect(boxText(tester), importedPlan);
  });

  testWidgets('declining the ask keeps the box and writes no draft', (
    tester,
  ) async {
    await launch(tester, picks: [_txt(importedPlan)]);
    await tester.enterText(find.byKey(const Key('paste-input')), typedPlan);

    await importAFile(tester);

    expect(find.byKey(const Key('import-replace-ask')), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-replace-keep')));
    await tester.pumpAndSettle();

    expect(boxText(tester), typedPlan,
        reason: 'declining must cost nothing — the typed plan stays');
    expect(await db.readPlanDraft(), isNull,
        reason: 'a declined import must not start a draft over typed text');
  });

  testWidgets('confirming replaces the box and starts the draft', (
    tester,
  ) async {
    await launch(tester, picks: [_txt(importedPlan)]);
    await tester.enterText(find.byKey(const Key('paste-input')), typedPlan);

    await importAFile(tester);
    await tester.tap(find.byKey(const Key('import-replace-confirm')));
    await tester.pumpAndSettle();

    expect(boxText(tester), importedPlan);
    expect(await db.readPlanDraft(), importedPlan);
  });

  testWidgets('a file saying exactly what the box says is not an ask', (
    tester,
  ) async {
    await launch(tester, picks: [_txt(typedPlan)]);
    await tester.enterText(find.byKey(const Key('paste-input')), typedPlan);

    await importAFile(tester);

    expect(find.byKey(const Key('import-replace-ask')), findsNothing,
        reason: 'nothing would be lost, so there is nothing to ask about');
    expect(boxText(tester), typedPlan);
  });

  testWidgets('the starter pills are absent once the box has content, and '
      'back once it is emptied', (tester) async {
    await launch(tester);

    expect(find.byKey(const Key('try-example')), findsOneWidget);
    expect(find.byKey(const Key('build-by-hand')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('paste-input')), typedPlan);
    await tester.pump();
    expect(find.byKey(const Key('try-example')), findsNothing);
    expect(find.byKey(const Key('build-by-hand')), findsNothing);

    await tester.enterText(find.byKey(const Key('paste-input')), '');
    await tester.pump();
    expect(find.byKey(const Key('try-example')), findsOneWidget);
    expect(find.byKey(const Key('build-by-hand')), findsOneWidget);
  });
}
