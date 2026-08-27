// The import flow, end to end through the real stack: a picked file read
// behind the fake picker edge, its text landed in the existing paste box,
// the same green button reading it, and the accepted itinerary persisted
// into Drift — the plan §7 flow test, over slice A's plain-text path and
// slice C's docx/xlsx/csv fixtures.
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
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/file_picker_edge.dart';
import 'package:cairn/app_state/import_flow.dart';
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

  /// The pill opens the two-door import sheet (slice D: documents, or the
  /// photo library). Every test in this file goes through the file door.
  Future<void> importAFile(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-door-file')));
    await tester.pump();
    await tester.pump();
  }

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
    await importAFile(tester);
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

    await importAFile(tester);

    // Inline, in place of the pill — no modal anywhere.
    expect(find.byKey(const Key('import-progress')), findsOneWidget);
    expect(find.text('Reading Wanderlog.txt…'), findsOneWidget);

    held.complete(const ExtractedText(text: tidyImport));
    await tester.pump();

    expect(find.byKey(const Key('import-progress')), findsNothing);
    expect(boxText(tester), tidyImport);
  });

  testWidgets('a PDF whose engine never loads refuses instead of spinning', (
    tester,
  ) async {
    // `flutter_tester` genuinely has no PDFium native asset, so the engine
    // throws inside `pdfrx_engine`'s worker isolate and the read never
    // resolves on its own. That is the very condition being exercised: the
    // real registry routes these bytes to the real `PdfExtractor`, and only
    // its timeout gets the person off the progress label. Without it this
    // test would hang with no error at all — which is why the PDF path could
    // not be covered here before.
    final pdf = File(
      'packages/plan_extraction/test/fixtures/garbled-itinerary.pdf',
    ).readAsBytesSync();
    await launch(
      tester,
      picks: [PickedBytes(fileName: 'plan.pdf', extension: 'pdf', bytes: pdf)],
    );

    await importAFile(tester);
    expect(find.text('Reading plan.pdf…'), findsOneWidget);

    // Past the engine's liveness bound, and the screen moves.
    await tester.pump(pdfEngineTimeout + const Duration(seconds: 1));
    await tester.pump();

    expect(find.byKey(const Key('import-progress')), findsNothing);
    expect(find.byKey(const Key('import-error')), findsOneWidget);
    expect(find.textContaining('did not respond'), findsOneWidget);
    expect(boxText(tester), '');
    // The pill is back: the flow's re-entry guard cleared with the read.
    await tester.tap(find.byKey(const Key('import-error-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('import-pill')), findsOneWidget);
  });

  testWidgets('dismissing the picker changes nothing', (tester) async {
    final picker = await launch(tester, picks: [null]);

    await importAFile(tester);

    expect(boxText(tester), '');
    expect(find.byKey(const Key('import-error')), findsNothing);
    expect(find.byKey(const Key('import-pill')), findsOneWidget);
    // Every extension some registered extractor claims, plus the pictures
    // the file door also accepts (import_flow.dart says why). The document
    // half stays derived from the registry, so it holds as each format
    // slice lands rather than needing an edit per slice.
    expect(picker.lastAllowedExtensions, supportedImportExtensions);
    expect(documentImportExtensions, {'csv', 'txt', 'pdf', 'docx', 'xlsx'});
    expect(
      picker.lastAllowedExtensions,
      {...documentImportExtensions, ...imageImportExtensions},
    );
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

    await importAFile(tester);

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

    await importAFile(tester);

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
    await importAFile(tester);
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

  // --- slice C: the three formats the registry gained --------------------
  //
  // These drive the *committed binary fixtures* through the same door as the
  // plain-text test above: the pill, the real registry's routing, the real
  // extractor, the box, and the same green button. What the box holds is the
  // person-visible half of slice C, so it is asserted literally.

  PickedBytes fixture(String name) => PickedBytes(
    fileName: name,
    extension: name.split('.').last,
    bytes: Uint8List.fromList(
      File('packages/plan_extraction/test/fixtures/$name').readAsBytesSync(),
    ),
  );

  testWidgets('an imported docx fills the box, parses, accepts into Drift', (
    tester,
  ) async {
    await launch(tester, picks: [fixture('tables.docx')]);

    await importAFile(tester);

    // One line per WordprocessingML paragraph; the table's cells row-major.
    expect(
      boxText(tester),
      'Mon 14 June 2027 - Tokyo\n'
      '09:00\n'
      'Senso-ji\n'
      '12:00\n'
      'Ramen in Asakusa\n'
      'Tue 15 June 2027 - Kyoto\n'
      'Fushimi Inari at dawn',
    );

    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    expect(find.textContaining('2 days'), findsOneWidget);
    expect(find.text('Monday · Tokyo'), findsOneWidget);

    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();

    final stops = await db.readItineraryStops();
    expect(
      stops.map((s) => s.stopText),
      containsAll(['Senso-ji', 'Fushimi Inari at dawn']),
    );
  });

  testWidgets('an imported xlsx with a date column lands in the dialect', (
    tester,
  ) async {
    await launch(tester, picks: [fixture('dated-sheet.xlsx')]);

    await importAFile(tester);

    // The date-typed column drove the heuristic: dated headers, dash stops.
    expect(boxText(tester), contains('Mon 14 June 2027'));
    expect(boxText(tester), contains('- Senso-ji at 9:00'));
    expect(boxText(tester), contains('Tue 15 June 2027'));

    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    expect(find.textContaining('2 days'), findsOneWidget);
  });

  testWidgets('an xlsx with no date column still lands as faithful lines', (
    tester,
  ) async {
    await launch(tester, picks: [fixture('text-sheet.xlsx')]);

    await importAFile(tester);

    // The floor: never worse than pasting the same table as text.
    expect(boxText(tester), contains('Senso-ji at 9:00'));
    expect(boxText(tester), contains('Kyoto'));
    expect(find.byKey(const Key('import-error')), findsNothing);
  });

  testWidgets('an imported csv with an ISO date column reads as two days', (
    tester,
  ) async {
    await launch(tester, picks: [fixture('dated.csv')]);

    await importAFile(tester);

    expect(boxText(tester), contains('Mon 14 June 2027'));
    expect(boxText(tester), contains('- Senso-ji at 9:00, then Ueno'));

    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    expect(find.textContaining('2 days'), findsOneWidget);
  });

  testWidgets('a password-protected docx refuses honestly, box untouched', (
    tester,
  ) async {
    await launch(tester, picks: [fixture('encrypted.docx')]);

    await importAFile(tester);

    expect(find.byKey(const Key('import-error')), findsOneWidget);
    expect(
      find.textContaining('damaged or password-protected'),
      findsOneWidget,
    );
    expect(boxText(tester), '');
  });
}
