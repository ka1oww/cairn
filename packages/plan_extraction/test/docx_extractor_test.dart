// DocxExtractor against committed .docx fixtures (tool/make_fixtures.dart).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:itinerary_parser/itinerary_parser.dart';
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
    test('paragraphs and table rows come out in document order, one line '
        'per row with its cells joined', () {
      final result = extractor.extract(fixture('tables.docx'));
      expect(result, isA<ExtractedText>());
      final lines = (result as ExtractedText).text.split('\n');
      expect(lines, [
        'Mon 14 June 2027 - Tokyo',
        // `[09:00][Senso-ji]` is one stop to a reader and one line here:
        // the time stays with the place the way the row model keeps a
        // typed spreadsheet's time with its own row.
        '09:00 Senso-ji',
        '12:00 Ramen in Asakusa',
        'Tue 15 June 2027 - Kyoto',
        // A row down to one filled cell is layout, not pairing.
        'Fushimi Inari at dawn',
      ]);
    });

    test('a two-column [time | stop] table gives one stop per row, and the '
        'parser reads the row as a starred stop (report W1)', () {
      final result = extractor.extract(fixture('kyoto-week.docx'));
      expect(result, isA<ExtractedText>());
      final parsed = parseItinerary((result as ExtractedText).text);

      expect(parsed.days, hasLength(3));
      expect(
        parsed.days.map((day) => day.stops.length),
        [3, 3, 2],
        reason: 'eight table rows are the eight stops a reader sees',
      );
      expect(parsed.days.expand((day) => day.stops).length, 8);

      final first = parsed.days.first.stops.first;
      expect(first.time, const ParsedTime(8, 30));
      expect(first.isStarred, isTrue);
      expect(first.text, contains('Fushimi Inari before the crowds'));

      // The soft break inside a cell still joins as a space, and the row's
      // time still leads the joined line.
      expect(
        parsed.days.first.stops.last.text,
        '16:00 Gion at dusk (walk from Yasaka)',
      );
      expect(parsed.days.first.stops.last.time, const ParsedTime(16, 0));
    });

    test('a single-column table keeps one line per paragraph', () {
      // Layout tables are common in Word; collapsing a column of stops into
      // one line would be worse than the bug the row rule fixes.
      final result = extractor.extract(fixture('tables.docx'));
      final text = (result as ExtractedText).text;
      expect(text, contains('Fushimi Inari at dawn'));
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
