// DocxExtractor against committed .docx fixtures (tool/make_fixtures.dart).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:plan_extraction/plan_extraction.dart';

const extractor = DocxExtractor();

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
    test('claims docx', () => expect(extractor.extensions, {'docx'}));

    test('matches a real docx by content', () {
      expect(extractor.matches(fixture('tables.docx')), isTrue);
    });

    test('does not match an xlsx wearing zip magic (both are zips)', () {
      // xlsx and docx are both zips; matches() must look inside, not just
      // check the zip magic, or a mis-named workbook would be claimed here.
      expect(extractor.matches(fixture('dated-sheet.xlsx')), isFalse);
    });

    test('does not match a plain-text file wearing the .docx extension', () {
      expect(extractor.matches(fixture('not-a-docx.docx')), isFalse);
    });

    test('never throws, whatever the bytes', () {
      final shapes = <List<int>>[
        [],
        [0x00],
        [0x50, 0x4B, 0x03, 0x04],
        utf8.encode('Day 1'),
      ];
      for (final shape in shapes) {
        expect(() => extractor.matches(named('x.docx', shape)), returnsNormally);
        expect(() => extractor.extract(named('x.docx', shape)), returnsNormally);
      }
    });
  });

  group('extraction', () {
    test('paragraphs and table cells come out in document order, '
        'cells read row-major', () {
      final result = extractor.extract(fixture('tables.docx'));
      expect(result, isA<ExtractedText>());
      final lines = (result as ExtractedText).text.split('\n');
      expect(lines, [
        'Mon 14 June 2027 - Tokyo',
        '09:00',
        'Senso-ji',
        '12:00',
        'Ramen in Asakusa',
        'Tue 15 June 2027 - Kyoto',
        'Fushimi Inari at dawn',
      ]);
    });

    test('a soft line break inside one cell joins as a space, not a '
        'second line', () {
      final result = extractor.extract(fixture('tables.docx'));
      final text = (result as ExtractedText).text;
      expect(text, contains('Fushimi Inari at dawn'));
      expect(text, isNot(contains('Fushimi Inari\nat dawn')));
    });

    test('the garbled itinerary as a docx: one paragraph per line, '
        'modulo whitespace', () {
      final result = extractor.extract(fixture('garbled-itinerary.docx'));
      expect(result, isA<ExtractedText>());
      final text = (result as ExtractedText).text;
      expect(text, contains('KYOTO & TOKYO - MARCH 2027 (draft v3)'));
      expect(text, contains('Day 1 - Kyoto, 3/11'));
      expect(text, contains('8:30 Fushimi Inari at dawn'));
      expect(text, contains('🍜 Ichiran for dinner, solo booth obviously'));
      expect(text, contains('Booking ref: PNX88K · K\'s House Kyoto'));
      expect(text, contains('Day 3 - Tokyo'));
    });

    test('a CFB container (encrypted Office) is refused as unreadable, '
        'never decoded as junk', () {
      final result = extractor.extract(fixture('encrypted.docx'));
      expect(result, isA<ExtractionFailure>());
      expect((result as ExtractionFailure).kind,
          ExtractionFailureKind.unreadable);
    });

    test('a plain-text file wearing .docx is refused as unreadable', () {
      final result = extractor.extract(fixture('not-a-docx.docx'));
      expect(result, isA<ExtractionFailure>());
      expect((result as ExtractionFailure).kind,
          ExtractionFailureKind.unreadable);
    });

    test('an empty file is refused as empty', () {
      final result = extractor.extract(named('empty.docx', const []));
      expect((result as ExtractionFailure).kind, ExtractionFailureKind.empty);
    });

    test('an oversized file is refused before reading', () {
      final big = Uint8List(maxPlainBytes + 1);
      final result = extractor.extract(named('big.docx', big));
      expect((result as ExtractionFailure).explanation, contains('25 MB'));
    });
  });
}
