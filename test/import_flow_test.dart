// The import flow, end to end through the real stack: a picked file read
// behind the fake picker edge, its text landed in the existing paste box,
// the same green button reading it, and the accepted itinerary persisted
// into Drift — the plan §7 flow test, on slice A's plain-text path.
//
// The two CLAUDE.md widget-test traps this file is shaped around:
//
//  - the extraction runs through `extractionRunnerProvider`, overridden to
//    call the pure extractor directly. Production uses `Isolate.run`; a real
//    isolate inside testWidgets' fake-async zone hangs silently.
//  - closeStreamsSynchronously is load-bearing, exactly as the header of
//    paste_confirm_flow_test.dart explains: without it, teardown waits
//    forever on a drift stream shutdown that can never fire.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/file_picker_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:plan_extraction/plan_extraction.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cairn/screens/paste_screen.dart';

/// What the fake picker hands over for "a tidy plan somebody texted as a
/// .txt": dated headers parse high-confidence, so acceptance needs no asks.
const tidyImport = '''
Mon 14 June 2027 - Tokyo
- Senso-ji
- Ueno Park

Tue 15 June 2027 - Kyoto
- Fushimi Inari
''';

/// The date every test reads as today; day 2 sits on it.
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

  /// Launches the app with the import seams bound to fakes: [picks] are the
  /// picker's answers in order (null = dismissal), and extraction calls the
  /// pure extractor directly rather than through an isolate.
  Future<FakeFilePicker> launch(
    WidgetTester tester, {
    List<PickedBytes?> picks = const [],
    Size size = const Size(800, 2600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final picker = FakeFilePicker(picks);
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: _defaultToday,
        picker: picker,
        extraction: (extractor, file) async => extractor.extract(file),
      ),
    );
    await tester.pump();
    await tester.pump();
    return picker;
  }

  String boxText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('paste-input')))
      .controller!
      .text;

  testWidgets('an imported txt fills the box, parses, accepts into Drift', (
    tester,
  ) async {
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'japan-trip.txt',
          extension: 'txt',
          bytes: _bytes(tidyImport),
        ),
      ],
    );

    // One tap on the pill; the box now holds what the file said.
    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pump();
    expect(boxText(tester), tidyImport);
    // The pill came back for another import once the read landed.
    expect(find.byKey(const Key('import-pill')), findsOneWidget);

    // The same green button reads it; no new ask was needed because the
    // fixture's dates carry years and weekdays.
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    expect(find.textContaining('2 days'), findsOneWidget);
    expect(find.text('Monday · Tokyo'), findsOneWidget);
    expect(find.byKey(const Key('accept-button')), findsOneWidget);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    // The launch surface switched on its own — today (15 June) is day 2,
    // so the app opens on that day's page — and the itinerary is in Drift,
    // read back through the store rather than off the screen.
    expect(find.byKey(const Key('paste-input')), findsNothing);
    expect(find.text('Tuesday, Kyoto'), findsOneWidget);
    expect(find.text('Fushimi Inari'), findsOneWidget);
    final stops = await db.readItineraryStops();
    expect(
      stops.map((s) => s.stopText),
      containsAll(['Senso-ji', 'Fushimi Inari']),
    );
    expect(await db.readTripFacts(), isNotNull);
  });

  testWidgets('the progress label shows while the file is being read', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Hold the extraction open so the in-between state is observable: the
    // runner answers only when this test completes it.
    final held = Completer<ExtractionResult>();
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: _defaultToday,
        picker: FakeFilePicker([
          PickedBytes(
            fileName: 'Wanderlog.txt',
            extension: 'txt',
            bytes: _bytes(tidyImport),
          ),
        ]),
        extraction: (_, _) => held.future,
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pump();

    // Inline, in place of the pill — no modal anywhere.
    expect(find.byKey(const Key('import-progress')), findsOneWidget);
    expect(find.text('Reading Wanderlog.txt…'), findsOneWidget);

    held.complete(const ExtractedText(text: tidyImport));
    await tester.pump();

    expect(find.byKey(const Key('import-progress')), findsNothing);
    expect(boxText(tester), tidyImport);
  });

  testWidgets('dismissing the picker changes nothing', (tester) async {
    final picker = await launch(tester, picks: [null]);

    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pump();

    expect(boxText(tester), '');
    expect(find.byKey(const Key('import-error')), findsNothing);
    expect(find.byKey(const Key('import-pill')), findsOneWidget);
    expect(picker.lastAllowedExtensions, {'txt'});
  });

  testWidgets('unreadable bytes refuse into the error card, box untouched', (
    tester,
  ) async {
    final junk = List<int>.generate(256, (i) => i * 37 % 256);
    junk[0] = 0x00;
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'mystery.txt',
          extension: 'txt',
          bytes: Uint8List.fromList(junk),
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pump();

    expect(find.byKey(const Key('import-error')), findsOneWidget);
    expect(find.textContaining("Couldn't read that file"), findsOneWidget);
    expect(boxText(tester), '');

    // Dismissing clears the card; the doors all stay usable.
    await tester.tap(find.byKey(const Key('import-error-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('import-error')), findsNothing);
    await tester.enterText(find.byKey(const Key('paste-input')), tidyImport);
    expect(boxText(tester), tidyImport);
  });

  testWidgets("a file with no text gets the honest empty-file sentence", (
    tester,
  ) async {
    await launch(
      tester,
      picks: [
        PickedBytes(
          fileName: 'blank.txt',
          extension: 'txt',
          bytes: Uint8List(0),
        ),
      ],
    );

    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pump();

    expect(find.text("That file didn't contain any text."), findsOneWidget);
    expect(boxText(tester), '');
  });

  testWidgets('the re-paste box over a running trip carries the pill too', (
    tester,
  ) async {
    // The screen alone, in its repasting mode: the point is only that the
    // door exists where the two first-timer pills are hidden.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          filePickerEdgeProvider.overrideWithValue(FakeFilePicker([])),
        ],
        child: const MaterialApp(home: PasteScreen(repastingLivePlan: true)),
      ),
    );
    await tester.pump();

    expect(find.byKey(const Key('import-pill')), findsOneWidget);
    expect(find.byKey(const Key('try-example')), findsNothing);
    expect(find.byKey(const Key('build-by-hand')), findsNothing);
  });

  testWidgets('the ghost sample never paints outside the box, in any state', (
    tester,
  ) async {
    // The pill row shortens the box enough on a real phone that the 25-line
    // ghost sample no longer fits, and InputDecorator vertically centres a
    // hint taller than its field: the first lines used to paint ABOVE the
    // green border, over the subhead and over the error card. A phone-sized
    // view is what makes that reproducible — the other tests run tall.
    final junk = List<int>.generate(256, (i) => i * 37 % 256);
    junk[0] = 0x00;
    await launch(
      tester,
      size: const Size(402, 874),
      picks: [
        PickedBytes(
          fileName: 'mystery.txt',
          extension: 'txt',
          bytes: Uint8List.fromList(junk),
        ),
      ],
    );

    void expectHintInsideBox() {
      final box = tester.getRect(find.byKey(const Key('paste-input')));
      final hint = tester.getRect(find.text(sampleItinerary));
      expect(hint.top, greaterThanOrEqualTo(box.top));
      expect(hint.bottom, lessThanOrEqualTo(box.bottom));
    }

    expectHintInsideBox();

    // And again with the refusal card taking another band off the box.
    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pump();
    expect(find.byKey(const Key('import-error')), findsOneWidget);
    expectHintInsideBox();
  });

  testWidgets('with nothing to say, the box keeps its gap under the subhead', (
    tester,
  ) async {
    // The import feedback takes the place of the screen's original spacer,
    // so the idle state has to still hold it: without the gap the box border
    // abuts the subhead and the ghost sample overlaps it.
    await launch(tester);

    final subhead = tester.getRect(find.byKey(const Key('paste-subhead')));
    final box = tester.getRect(find.byKey(const Key('paste-input')));
    expect(box.top - subhead.bottom, 16.0);
  });
}
