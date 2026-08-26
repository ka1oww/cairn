// Slice D of the file-import feature: pictures and scanned PDFs reach the
// paste box through Apple Vision behind TextRecognitionEdge — exercised
// here only through the fake edge.
//
// **The evidence rule** (the import plan §8 risk 8, verbatim from the
// camera path's rule): the fake makes the flow walkable on the Simulator;
// a green simulator run is NO evidence OCR works. Real recognition quality
// is judged on a device with a manual corpus (a chat screenshot, a
// Wanderlog screenshot, a photographed printout). Nothing in this file — or
// anywhere automated — verifies Vision itself.
//
// Shape notes inherited from import_flow_test.dart: the extraction runs
// through an injected direct call (a real isolate under the fake clock
// hangs silently), closeStreamsSynchronously is load-bearing, and every
// seam comes in through bootstrapApp.
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cairn/app_state/file_picker_edge.dart';
import 'package:cairn/app_state/import_flow.dart';
import 'package:cairn/app_state/text_recognition_edge.dart';
import 'package:cairn/bootstrap.dart';
import 'package:cairn/storage/drift/app_database.dart';
import 'package:plan_extraction/plan_extraction.dart';

/// What the fake edge answers for the family chat screenshot: a two-day
/// plan whose lines parse without asks once they land in the box.
const recognizedScreenshot = [
  'Day 1 - Tokyo',
  '- Senso-ji',
  '',
  'Day 2 - Kyoto',
  '- Fushimi Inari',
];

/// Bytes whose leading signature says PNG, so the claim is made on content
/// even though the payload is nonsense — the fake never decodes it.
Uint8List pngBytes({int fill = 0xAB}) => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
      ...List<int>.filled(32, fill),
    ]);

final _defaultToday = DateTime.utc(2027, 6, 15);

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

  /// Launches the app with all three import seams faked: the picker (with
  /// its scripted document and image picks), the recognition edge, and a
  /// direct-call extraction runner.
  Future<(FakeFilePicker, FakeTextRecognition)> launch(
    WidgetTester tester, {
    List<PickedBytes?> documentPicks = const [],
    List<PickedBytes?> imagePicks = const [],
    List<Object> recognitionAnswers = const [],
    Future<void> Function(RecognitionProgress report)? beforeNextAnswer,
    ExtractionRunner? extraction,
  }) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final picker = FakeFilePicker(documentPicks, imageAnswers: imagePicks);
    final recognition = FakeTextRecognition(recognitionAnswers)
      ..beforeNextAnswer = beforeNextAnswer;
    await tester.pumpWidget(
      bootstrapApp(
        database: db,
        today: _defaultToday,
        picker: picker,
        extraction: extraction ?? (extractor, file) async => extractor.extract(file),
        textRecognition: recognition,
      ),
    );
    await tester.pump();
    await tester.pump();
    return (picker, recognition);
  }

  String boxText(WidgetTester tester) => tester.widget<TextField>(
        find.byKey(const Key('paste-input')),
      ).controller!.text;

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('import-pill')));
    await tester.pumpAndSettle();
  }

  testWidgets('claimsImage routes by extension and by content', (_) async {
    bool claim(String name, String? ext, Uint8List bytes) =>
        claimsImage(PickedBytes(fileName: name, extension: ext, bytes: bytes));

    expect(claim('shot.png', 'png', pngBytes()), isTrue);
    expect(claim('shot.jpg', 'jpg', Uint8List(64)), isTrue);
    expect(claim('scan.heic', 'heic', Uint8List(64)), isTrue);
    expect(claim('plan.txt', 'txt', Uint8List(64)), isFalse);
    expect(claim('plan.pdf', 'pdf', Uint8List.fromList(utf8.encode('%PDF-1.4'))),
        isFalse);

    // Content over name: a renamed screenshot still finds the OCR route…
    expect(claim('mystery.dat', null, pngBytes()), isTrue);
    expect(
      claim(
        'photo.jpg.renamed',
        'renamed',
        Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List<int>.filled(32, 0)]),
      ),
      isTrue,
    );
    // …and a renamed *document* is not dragged into it.
    expect(
      claim(
        'plan.txt.renamed',
        'renamed',
        Uint8List.fromList(List<int>.filled(64, 0x20)),
      ),
      isFalse,
    );
  });

  testWidgets('a photo-library pick is recognized into the box, and parses', (
    tester,
  ) async {
    final (_, recognition) = await launch(
      tester,
      imagePicks: [
        PickedBytes(fileName: 'chat-screenshot.png', extension: 'png', bytes: pngBytes()),
      ],
      recognitionAnswers: [
        RecognizedScan(lines: recognizedScreenshot, pageCount: 1),
      ],
    );

    await openSheet(tester);
    expect(find.byKey(const Key('import-door-photo')), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-door-photo')));
    await tester.pump();

    // The recognized lines landed visibly in the box, joined in reading
    // order, with the provenance note beside them.
    expect(boxText(tester), recognizedScreenshot.join('\n'));
    expect(find.byKey(const Key('import-note')), findsOneWidget);
    expect(find.text('Read 1 page'), findsOneWidget);
    expect(recognition.received, hasLength(1));

    // And the same green button reads them — OCR output feeds the ordinary
    // pipeline end to end.
    await tester.tap(find.byKey(const Key('read-button')));
    await tester.pump();
    expect(find.textContaining('2 days'), findsOneWidget);
    await tester.tap(find.byKey(const Key('accept-button')));
    await tester.pump();
    await tester.pump();
    final stops = await db.readItineraryStops();
    expect(stops.map((s) => s.stopText), containsAll(['Senso-ji', 'Fushimi Inari']));
  });

  testWidgets('multi-page reads report their progress per page', (tester) async {
    final held = Completer<void>();
    await launch(
      tester,
      imagePicks: [
        PickedBytes(fileName: 'scanned.pdf.png', extension: 'png', bytes: pngBytes()),
      ],
      recognitionAnswers: [
        RecognizedScan(lines: ['Mon 14 June 2027 - Tokyo'], pageCount: 3),
      ],
      beforeNextAnswer: (report) {
        report(1, 3);
        report(2, 3);
        return held.future;
      },
    );

    await openSheet(tester);
    await tester.tap(find.byKey(const Key('import-door-photo')));
    await tester.pump();
    await tester.pump();

    // Inline progress, page replacing the file name — no modal anywhere.
    expect(find.byKey(const Key('import-progress')), findsOneWidget);
    expect(find.text('Reading page 2 of 3…'), findsOneWidget);

    held.complete();
    await tester.pump();
    expect(find.byKey(const Key('import-progress')), findsNothing);
    expect(boxText(tester), 'Mon 14 June 2027 - Tokyo');
    expect(find.text('Read 3 pages'), findsOneWidget);
  });

  testWidgets('a refusal shows the honest card and leaves the box alone', (
    tester,
  ) async {
    await launch(
      tester,
      imagePicks: [
        PickedBytes(fileName: 'wall.jpg', extension: 'jpg', bytes: pngBytes(fill: 0x11)),
      ],
      recognitionAnswers: [
        const RecognitionRefused("That picture couldn't be read."),
      ],
    );

    await openSheet(tester);
    await tester.tap(find.byKey(const Key('import-door-photo')));
    await tester.pump();

    expect(find.byKey(const Key('import-error')), findsOneWidget);
    expect(find.text("That picture couldn't be read."), findsOneWidget);
    expect(boxText(tester), '');
    // No OCR route on a plain refusal — the door belongs to scans only.
    expect(find.byKey(const Key('import-ocr-offer')), findsNothing);

    await tester.tap(find.byKey(const Key('import-error-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('import-error')), findsNothing);
  });

  testWidgets("a picture holding no text gets the honest empty answer", (
    tester,
  ) async {
    await launch(
      tester,
      imagePicks: [
        PickedBytes(fileName: 'dog.png', extension: 'png', bytes: pngBytes()),
      ],
      recognitionAnswers: [
        const RecognizedScan(lines: [], pageCount: 1),
      ],
    );

    await openSheet(tester);
    await tester.tap(find.byKey(const Key('import-door-photo')));
    await tester.pump();

    expect(
      find.text("Couldn't find any readable text in that picture."),
      findsOneWidget,
    );
    expect(boxText(tester), '');
  });

  testWidgets('a scan refused by the reader offers one-tap OCR off the card', (
    tester,
  ) async {
    // The bytes the reader refused. What matters is that *these* bytes go
    // back through recognition — not what format they claim to be, since
    // the only registered extractor on this branch is the plain-text one
    // (see the runner stand-in below).
    final refusedBytes =
        Uint8List.fromList(utf8.encode('a scanned plan with no text layer'));
    final (_, recognition) = await launch(
      tester,
      documentPicks: [
        PickedBytes(
          fileName: 'Wanderlog.txt',
          extension: 'txt',
          bytes: refusedBytes,
        ),
      ],
      recognitionAnswers: [
        RecognizedScan(lines: ['Sat, Jun 14th - Tokyo', '- Senso-ji'], pageCount: 1),
      ],
      // Slice B's PDF extractor standing in at its exact seam: the runner
      // this file sits behind answers noTextLayer for the picked file.
      // Until B lands, nothing else can produce that kind.
      extraction: (extractor, file) async => const ExtractionFailure(
        ExtractionFailureKind.noTextLayer,
        'placeholder — the flow composes the offer sentence itself',
      ),
    );

    await openSheet(tester);
    await tester.tap(find.byKey(const Key('import-door-file')));
    await tester.pump();

    // The scan-or-photos diagnosis, with the one-tap route attached.
    expect(find.byKey(const Key('import-error')), findsOneWidget);
    expect(find.textContaining('looks like a scan'), findsOneWidget);
    expect(find.byKey(const Key('import-ocr-offer')), findsOneWidget);
    expect(boxText(tester), '');

    await tester.tap(find.byKey(const Key('import-ocr-offer')));
    await tester.pump();

    // The very bytes that were refused went back through recognition, and
    // what came out landed in the box.
    expect(recognition.received.single, refusedBytes);
    expect(boxText(tester), 'Sat, Jun 14th - Tokyo\n- Senso-ji');
    expect(find.byKey(const Key('import-error')), findsNothing);
    expect(find.text('Read 1 page'), findsOneWidget);
  });

  testWidgets('cancelling the sheet imports nothing', (tester) async {
    final (picker, recognition) = await launch(tester);

    await openSheet(tester);
    expect(find.byKey(const Key('import-door-file')), findsOneWidget);
    expect(find.byKey(const Key('import-door-photo')), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-door-cancel')));
    await tester.pumpAndSettle();

    expect(boxText(tester), '');
    expect(picker.documentPicks, 0);
    expect(picker.imagePicks, 0);
    expect(recognition.received, isEmpty);
    expect(find.byKey(const Key('import-pill')), findsOneWidget);
  });
}
