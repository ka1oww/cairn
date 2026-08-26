// Slice B's evidence. The fixtures are committed binaries made by
// `tool/make_pdf_fixtures.dart`; read that script's header before
// regenerating any of them.
//
// One thing to know before running this file: the first `dart test` on a
// fresh machine downloads PDFium (see the package README). It is a one-time
// dev-machine cost and never happens at app runtime.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:plan_extraction/plan_extraction.dart';
import 'package:test/test.dart';

const extractor = PdfExtractor();

PickedBytes fixture(String name) {
  final file = File('test/fixtures/$name');
  return PickedBytes(
    fileName: name,
    extension: name.split('.').last,
    bytes: file.readAsBytesSync(),
  );
}

Future<ExtractedText> readText(String name) async {
  final result = await extractor.extract(fixture(name));
  expect(
    result,
    isA<ExtractedText>(),
    reason: result is ExtractionFailure
        ? '${result.kind}: ${result.explanation}'
        : null,
  );
  return result as ExtractedText;
}

Future<ExtractionFailure> readFailure(String name) async {
  final result = await extractor.extract(fixture(name));
  expect(result, isA<ExtractionFailure>());
  return result as ExtractionFailure;
}

/// The page marker the shared garbled plan carries, and the one line the two
/// containers deliberately disagree about (see the equivalence test).
const printedPageMarker = 'Page 3 of 5';

List<String> contentLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

void main() {
  group('routing', () {
    test('claims the pdf extension', () {
      expect(extractor.extensions, {'pdf'});
    });

    test('matches on the header, not on the name', () {
      final pdf = fixture('garbled-itinerary.pdf');
      expect(extractor.matches(pdf), isTrue);
      // A .pdf that is really a text file must not be claimed, so the
      // registry's magic-bytes-first routing hands it to plain text instead
      // (the plan's risk 10: people rename files).
      expect(
        extractor.matches(
          PickedBytes(
            fileName: 'plan.pdf',
            extension: 'pdf',
            bytes: fixture('garbled-itinerary.txt').bytes,
          ),
        ),
        isFalse,
      );
    });

    test('tolerates junk before the header, as the spec does', () {
      final real = fixture('garbled-itinerary.pdf').bytes;
      final padded = Uint8List.fromList([...utf8.encode('\n\n  '), ...real]);
      expect(
        extractor.matches(
          PickedBytes(fileName: 'p.pdf', extension: 'pdf', bytes: padded),
        ),
        isTrue,
      );
    });
  });

  group('the garbled itinerary', () {
    test('reads every line the .txt of the same plan carries', () async {
      final fromPdf = await readText('garbled-itinerary.pdf');
      final fromTxt = const PlainTextExtractor().extract(
        fixture('garbled-itinerary.txt'),
      );

      // The extraction-equivalence promise (the plan's §7): the parser sees
      // one truth no matter which container the plan arrived in. Blank lines
      // are the one thing a PDF cannot carry -- a text layer has no concept
      // of an empty line -- so the comparison is over content lines. The one
      // deliberate difference is the shared plan's `Page 3 of 5`: a line that
      // says it is a page number is furniture a *print* carries, and only the
      // PDF read has a page-furniture rule to strip it with.
      expect(
        contentLines(fromPdf.text),
        contentLines(
          (fromTxt as ExtractedText).text,
        ).where((line) => line != printedPageMarker),
      );
    });

    test('parses to the same itinerary from either container', () async {
      final fromPdf = parseItinerary(
        (await readText('garbled-itinerary.pdf')).text,
      );
      final fromTxt = parseItinerary(
        (const PlainTextExtractor().extract(fixture('garbled-itinerary.txt'))
                as ExtractedText)
            .text,
      );

      String shape(ParseResult r) => [
        for (final day in r.days)
          '${day.date} | ${day.place} | '
              '${day.stops.map((s) => '${s.time}:${s.text}').join(', ')}',
      ].join('\n');

      // Same days, same stops, same times — bar the page marker the print
      // furniture rule strips, which lands as one more unplaced line in the
      // .txt read.
      expect(
        shape(fromPdf),
        shape(fromTxt).replaceAll(', null:$printedPageMarker', ''),
      );
      expect(fromPdf.days, hasLength(3));
      expect(fromPdf.hasAmbiguousNumericDates, isTrue);
    });

    test('keeps the bare 1900 that is a year and not a page number', () async {
      final text = (await readText('garbled-itinerary.pdf')).text;
      expect(text, contains('1900 yen dinner budget'));
    });

    test('reports how much it read', () async {
      expect((await readText('garbled-itinerary.pdf')).notes, ['Read 1 page']);
    });
  });

  group('the Wanderlog print', () {
    late String text;

    setUpAll(() async {
      text = (await readText('wanderlog-print.pdf')).text;
    });

    test('reads every page', () async {
      // The regression this pins is a real one and it was silent: an
      // un-awaited `return` inside the try/finally disposed the document
      // while the pages were still loading, and the read came back holding
      // page one and eight empty ones.
      expect((await readText('wanderlog-print.pdf')).notes, ['Read 9 pages']);
      expect(contentLines(text).length, greaterThan(400));
    });

    test('keeps the days in the order the plan prints them', () {
      final lines = contentLines(text);
      final one = lines.indexOf('Day 1');
      final two = lines.indexOf('Day 2');
      final three = lines.indexOf('Day 3');
      expect(one, isNonNegative);
      expect(one, lessThan(two));
      expect(two, lessThan(three));
    });

    test("strips the browser's running header and footer", () {
      // Chrome's print dialog leaves headers and footers on, so a real
      // export carries a date/time/title line and a url/page-number line on
      // every page. Both repeat on nine pages, which is what makes them
      // provable furniture rather than a guess.
      expect(text, isNot(contains('3-Day Asahikawa Itinerary\n')));
      expect(text, isNot(contains('wanderlog.com/list/itinerary')));
      expect(text, isNot(matches(RegExp(r'^\d+/9$', multiLine: true))));
    });

    test('strips the print furniture the plan names', () {
      expect(text, isNot(contains('View on map')));
      expect(text, isNot(matches(RegExp(r'\d+ min · [\d.]+ mi'))));
      expect(text, isNot(contains('Google review')));
    });

    test('keeps the places, the notes and the addresses', () {
      // Address and phone lines stay deliberately: they are real information
      // somebody may want, and the parser already files what it cannot place
      // into the visible set-aside.
      expect(text, contains('Asahiyama Zoo'));
      expect(text, contains('Asahikawa Ramen Village'));
      expect(text, contains('Hokkaido'));
    });

    test('never joins two lines into one', () {
      // Every line of the read is a line PDFium handed over, trimmed. If the
      // cleanup ever started stitching wrapped lines back together, a stop
      // would silently absorb its neighbour.
      for (final line in contentLines(text)) {
        expect(line, isNot(contains('\n')));
      }
    });
  });

  group('the refusals', () {
    test(
      'a password-protected PDF is refused by name, not asked about',
      () async {
        final failure = await readFailure('password-protected.pdf');
        expect(failure.kind, ExtractionFailureKind.passwordProtected);
        expect(failure.explanation, passwordProtectedSentence);
      },
    );

    test('a PDF with no text layer is the OCR seam', () async {
      final failure = await readFailure('image-only.pdf');
      expect(failure.kind, ExtractionFailureKind.noTextLayer);
      expect(failure.explanation, noTextLayerSentence);
    });

    test('a damaged PDF is unreadable, not a crash', () async {
      final failure = await readFailure('truncated.pdf');
      expect(failure.kind, ExtractionFailureKind.unreadable);
      expect(failure.explanation, unreadableFileSentence);
    });

    test('an empty file is empty', () async {
      final result = await extractor.extract(
        PickedBytes(
          fileName: 'nothing.pdf',
          extension: 'pdf',
          bytes: Uint8List(0),
        ),
      );
      expect(
        result,
        isA<ExtractionFailure>().having(
          (f) => f.kind,
          'kind',
          ExtractionFailureKind.empty,
        ),
      );
    });

    test('bytes that are not a PDF at all are unreadable', () async {
      final result = await extractor.extract(
        PickedBytes(
          fileName: 'plan.pdf',
          extension: 'pdf',
          bytes: Uint8List.fromList(utf8.encode('Mon 14 June 2027 - Tokyo')),
        ),
      );
      expect(
        result,
        isA<ExtractionFailure>().having(
          (f) => f.kind,
          'kind',
          ExtractionFailureKind.unreadable,
        ),
      );
    });

    test('an oversized file is refused before it is opened', () async {
      final result = await extractor.extract(
        PickedBytes(
          fileName: 'huge.pdf',
          extension: 'pdf',
          bytes: Uint8List(maxPdfBytes + 1),
        ),
      );
      expect(
        result,
        isA<ExtractionFailure>().having(
          (f) => f.explanation,
          'explanation',
          contains('25 MB'),
        ),
      );
    });
  });

  group('past the page cap', () {
    // Risk 7's cap is a *partial success*, not a refusal: a person can fix a
    // partial read in the box and cannot fix a dead end. No committed fixture
    // is this long -- 100 pages of Chrome print is megabytes -- so the plan
    // is built here, one day per page, which is also the shape the
    // furniture rule must survive (a `Day N` header repeats on every page
    // and must never be mistaken for a running header).
    final long = PickedBytes(
      fileName: 'long-plan.pdf',
      extension: 'pdf',
      bytes: _manyPagePdf(120),
    );

    test('reads what it can and says how much, rather than refusing', () async {
      final result = await extractor.extract(long);
      expect(
        result,
        isA<ExtractedText>(),
        reason: result is ExtractionFailure
            ? '${result.kind}: ${result.explanation}'
            : null,
      );
      final read = result as ExtractedText;
      expect(read.notes, ['Read the first $maxPdfPages of 120 pages']);

      final lines = contentLines(read.text);
      expect(lines, hasLength(maxPdfPages));
      // In order, from the first page to the hundredth, and every day header
      // still there: the furniture rule needs a phrase, so a per-page day
      // marker survives however often it repeats.
      expect(lines.first, 'Day 1 - Stop 1');
      expect(lines[maxPdfPages - 1], 'Day $maxPdfPages - Stop $maxPdfPages');
      expect(lines, isNot(contains('Day 101 - Stop 101')));
    });
  });

  group('the engine never hangs', () {
    // The failure this stands for is a PDFium that cannot be loaded at all:
    // `pdfrx_engine` throws that inside its worker isolate, so the future
    // `extract` awaits never resolves and the read spins forever. It is
    // exactly what happens under `flutter_tester`, which carries no PDFium
    // native asset — and it cannot be staged against a working engine, so
    // the stand-in below is an open that never answers.
    const stalled = _StalledExtractor();

    test('an engine that never answers is a typed refusal', () async {
      final result = await stalled
          .extract(fixture('wanderlog-print.pdf'))
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail('extract() hung instead of refusing'),
          );
      expect(
        result,
        isA<ExtractionFailure>()
            .having((f) => f.kind, 'kind', ExtractionFailureKind.unreadable)
            .having(
              (f) => f.explanation,
              'explanation',
              pdfEngineUnavailableSentence,
            ),
      );
      // Loud and by name: a reader that did not answer must not read as a
      // damaged file, and must never come back as text.
      expect(result, isNot(isA<ExtractedText>()));
      expect(
        (result as ExtractionFailure).explanation,
        isNot(unreadableFileSentence),
      );
    });

    test('a timed-out read leaves the engine usable', () async {
      // Cleanup has to stay correct on the timeout path, or a timed-out
      // import strands a worker isolate for the life of the app.
      await stalled.extract(fixture('garbled-itinerary.pdf'));
      final after = await readText('garbled-itinerary.pdf');
      expect(after.text, contains('Kyoto'));
    });

    test('the default bound is generous, not a performance budget', () {
      expect(
        pdfEngineTimeout,
        greaterThanOrEqualTo(const Duration(minutes: 1)),
      );
    });
  });

  test('two reads in one process both work', () async {
    // Each read stops the engine's background worker on its way out, because
    // in production it runs inside an `Isolate.run` that would otherwise
    // strand it. This is the assertion that the engine really does come back
    // for the next file.
    final first = await readText('garbled-itinerary.pdf');
    final second = await readText('garbled-itinerary.pdf');
    expect(second.text, first.text);
  });
}

/// An extractor whose engine never answers, with a bound short enough to
/// prove it rather than to sit through it.
class _StalledExtractor extends PdfExtractor {
  const _StalledExtractor()
    : super(engineTimeout: const Duration(milliseconds: 50));

  @override
  Future<PdfDocument> openDocument(PickedBytes file) =>
      Completer<PdfDocument>().future;
}

/// A minimal, uncompressed [pageCount]-page PDF whose page *n* carries the
/// single line `Day n - Stop n`. Hand-built rather than committed: the cap
/// this exercises is 100 pages, and a real print that long is megabytes of
/// binary for one assertion.
Uint8List _manyPagePdf(int pageCount) {
  final out = BytesBuilder();
  final offsets = <int>[];
  void obj(int n, String body) {
    offsets.add(out.length);
    out.add(ascii.encode('$n 0 obj\n$body\nendobj\n'));
  }

  out.add(ascii.encode('%PDF-1.4\n'));
  // 1 = catalog, 2 = the page tree, 3 = the font, then a page/content pair.
  final kids = [
    for (var i = 0; i < pageCount; i++) '${4 + i * 2} 0 R',
  ].join(' ');
  obj(1, '<< /Type /Catalog /Pages 2 0 R >>');
  obj(2, '<< /Type /Pages /Count $pageCount /Kids [$kids] >>');
  obj(3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  for (var i = 0; i < pageCount; i++) {
    final page = 4 + i * 2;
    final content = page + 1;
    obj(
      page,
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 3 0 R >> >> /Contents $content 0 R >>',
    );
    final stream =
        'BT /F1 12 Tf 72 700 Td (Day ${i + 1} - Stop ${i + 1}) Tj ET';
    obj(content, '<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  }

  final startxref = out.length;
  final size = offsets.length + 1;
  final trailer = StringBuffer('xref\n0 $size\n0000000000 65535 f \n');
  for (final offset in offsets) {
    trailer.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  trailer.write(
    'trailer\n<< /Size $size /Root 1 0 R >>\nstartxref\n$startxref\n%%EOF\n',
  );
  out.add(ascii.encode(trailer.toString()));
  return out.toBytes();
}
