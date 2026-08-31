// The area gazetteer's *when*, which is the whole of the phase-2 decision
// that could go wrong invisibly (the tap-to-Maps plan §9).
//
// The gazetteer is ~430 KB of asset and 77k names once inflated. Nothing
// about that is dangerous except loading it at the wrong moment, and every
// wrong moment is silent: an app that reads it at launch is simply a little
// slower to open, and one that reads it on the day page is a little slower
// to draw. So the rule is pinned here rather than trusted — null until an
// import asks, and never before.
//
// The runner is injected exactly as `extractionRunnerProvider` is
// (bootstrap.dart), because a real `Isolate.run` under testWidgets' fake
// clock hangs silently. What that costs this file is the one thing it
// cannot prove: that production's default really is an isolate. The
// measurement of the load off the UI thread is reported in the PR instead.
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/area_gazetteer_loader.dart';
import 'package:cairn/app_state/file_picker_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:plan_extraction/plan_extraction.dart';

const _plan = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
''';

final _today = DateTime.utc(2027, 6, 15);

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

  /// How many times the runner was actually asked to inflate the assets —
  /// the load is once per launch, not once per import.
  var runs = 0;

  Future<ProviderContainer> launch(
    WidgetTester tester, {
    List<PickedBytes?> picks = const [],
  }) async {
    runs = 0;
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = bootstrapApp(
      database: db,
      today: _today,
      picker: FakeFilePicker(picks),
      gazetteer: (compressed) async {
        runs++;
        return buildAreaGazetteer(compressed);
      },
      extraction: (extractor, file) async => extractor.extract(file),
    );
    await tester.pumpWidget(app);
    await tester.pump();
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  Future<void> importAFile(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-door-file')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('launching the app loads no gazetteer at all', (tester) async {
    final container = await launch(tester);
    // The app is open on the paste box and not one byte has been read.
    expect(container.read(areaGazetteerProvider), isNull);
    expect(runs, 0);
  });

  testWidgets('an import loads it, once', (tester) async {
    final container = await launch(
      tester,
      picks: [
        PickedBytes(fileName: 'a.txt', bytes: _bytes(_plan)),
        PickedBytes(fileName: 'b.txt', bytes: _bytes(_plan)),
      ],
    );
    expect(container.read(areaGazetteerProvider), isNull);

    await importAFile(tester);
    final loaded = container.read(areaGazetteerProvider);
    expect(loaded, isNotNull, reason: 'the import is what loads it');
    expect(runs, 1);
    // A real gazetteer, not an empty one: the assets really reached the
    // bundle and really inflated.
    expect(loaded!.contains('shibuya'), isTrue);
    // ...and the hamlet filter's two casualties are still dead in the
    // bytes the app actually ships (packages/itinerary_parser scores them).
    expect(loaded.contains('unagi'), isFalse);
    expect(loaded.contains('udon'), isFalse);

    // A second import re-uses the load rather than inflating again.
    await importAFile(tester);
    expect(runs, 1);
  });

  testWidgets('a load that fails leaves phase-1 behaviour, not a broken '
      'import', (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: _today,
        picker: FakeFilePicker([
          PickedBytes(fileName: 'a.txt', bytes: _bytes(_plan)),
        ]),
        gazetteer: (_) async => throw StateError('no assets in this build'),
        extraction: (extractor, file) async => extractor.extract(file),
      ),
    );
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );

    await importAFile(tester);

    // The import still landed its text in the box — the gazetteer is an
    // improvement to the areas, never a precondition for reading a plan.
    expect(container.read(areaGazetteerProvider), isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('paste-input')))
          .controller!
          .text,
      contains('Senso-ji'),
    );
  });
}
