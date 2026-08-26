// XlsxExtractor against committed .xlsx fixtures (tool/make_fixtures.dart):
// heuristic v1 (the import plan's risk 5) — a date-typed column drives the
// dialect path; otherwise every non-empty cell becomes a faithful line.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:plan_extraction/plan_extraction.dart';

const extractor = XlsxExtractor();

PickedBytes named(String fileName, List<int> bytes) => PickedBytes(
      fileName: fileName,
      extension: fileName.contains('.')
          ? fileName.split('.').last.toLowerCase()
          : null,
      bytes: Uint8List.fromList(bytes),
    );

PickedBytes fixture(String name) =>
    named(name, File('test/fixtures/$name').readAsBytesSync());

void main() {
  group('routing contract', () {
    test('claims xlsx', () => expect(extractor.extensions, {'xlsx'}));

    test('matches a real workbook by content', () {
      expect(extractor.matches(fixture('dated-sheet.xlsx')), isTrue);
    });

    test('does not match a docx (both are zips)', () {
      expect(extractor.matches(fixture('tables.docx')), isFalse);
    });

    test('never throws, whatever the bytes', () {
      final shapes = <List<int>>[
        [],
        [0x00],
        [0x50, 0x4B, 0x03, 0x04],
        utf8.encode('Day 1'),
      ];
      for (final shape in shapes) {
        expect(() => extractor.matches(named('x.xlsx', shape)), returnsNormally);
        expect(() => extractor.extract(named('x.xlsx', shape)), returnsNormally);
      }
    });
  });

  group('date-typed column takes the dialect path', () {
    test('dated headers, multi-line cells split, a time stars its row', () {
      final result = extractor.extract(fixture('dated-sheet.xlsx'));
      expect(result, isA<ExtractedText>());
      final extracted = result as ExtractedText;
      expect(extracted.notes.single, contains('Sheet1'));

      final parsed = parseItinerary(extracted.text);
      expect(parsed.days, hasLength(2));
      expect(parsed.days[0].date, DateTime(2027, 6, 14));
      expect(parsed.days[0].confidence, Confidence.high);
      expect(parsed.days[0].stops.map((s) => s.text),
          ['Tokyo', 'Senso-ji at 9:00', 'Ueno Park picnic']);
      expect(parsed.days[1].date, DateTime(2027, 6, 15));
      expect(parsed.days[1].stops.last.isStarred, isTrue);
      expect(parsed.days[1].stops.last.time, const ParsedTime(9, 30));
      // The column-label row is preamble, filed visibly rather than
      // dropped.
      expect(
        parsed.unplacedLines.map((u) => u.sourceLine.text.trim()),
        ['Date', 'City', 'Plan'],
      );
    });
  });

  group('no date-typed column falls back to faithful lines', () {
    test('textual date cells still parse — never worse than the paste '
        'floor', () {
      final result = extractor.extract(fixture('text-sheet.xlsx'));
      expect(result, isA<ExtractedText>());
      final text = (result as ExtractedText).text;
      expect(text.split('\n'), [
        'Date',
        'City',
        'Plan',
        '14 June',
        'Tokyo',
        'Senso-ji at 9:00',
        '15 June',
        'Kyoto',
        'Fushimi Inari',
      ]);
      expect(() => parseItinerary(text), returnsNormally);
    });
  });

  group('refusals', () {
    test('a workbook with no non-empty sheet is refused as empty', () {
      final result = extractor.extract(fixture('empty.xlsx'));
      expect((result as ExtractionFailure).kind, ExtractionFailureKind.empty);
    });

    test('an empty file is refused as empty', () {
      final result = extractor.extract(named('empty.xlsx', const []));
      expect((result as ExtractionFailure).kind, ExtractionFailureKind.empty);
    });

    test('garbage wearing .xlsx is refused as unreadable', () {
      final result = extractor.extract(named('junk.xlsx', utf8.encode('not a workbook')));
      expect((result as ExtractionFailure).kind,
          ExtractionFailureKind.unreadable);
    });

    test('an oversized file is refused before reading', () {
      final big = Uint8List(maxPlainBytes + 1);
      final result = extractor.extract(named('big.xlsx', big));
      expect((result as ExtractionFailure).explanation, contains('25 MB'));
    });
  });
}
