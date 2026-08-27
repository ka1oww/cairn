// CsvExtractor against committed .csv fixtures (tool/make_fixtures.dart):
// same row model and dialect as xlsx (the import plan's "freebie", §5).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:plan_extraction/plan_extraction.dart';

const extractor = CsvExtractor();

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
    test('claims csv', () => expect(extractor.extensions, {'csv'}));

    test('matches by extension, since csv carries no magic bytes', () {
      expect(
        extractor.matches(named('plan.csv', utf8.encode('Date,Plan'))),
        isTrue,
      );
    });

    test('does not match a file lacking the .csv extension', () {
      expect(
        extractor.matches(named('plan.txt', utf8.encode('Date,Plan'))),
        isFalse,
      );
    });

    test('refuses a mis-named container even though the extension claims '
        'it — a PDF/docx/xlsx renamed .csv reads as junk otherwise', () {
      final zip = named('plan.csv', [0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]);
      expect(extractor.matches(zip), isFalse);
      final pdf = named('plan.csv', utf8.encode('%PDF-1.7'));
      expect(extractor.matches(pdf), isFalse);
    });

    test('still claims a csv whose first field only looks like a magic — '
        'the ASCII prefixes of RIFF, Rar!, GIF8, %PDF- and 7z', () {
      for (final first in const [
        'Raffles Hotel,2027-06-14,check in',
        'RIVERSIDE,2027-06-14,walk',
        'GIles Street,2027-06-14,dinner',
        '%Portion of the day,2027-06-14,rest',
        '7zone bar,2027-06-14,drinks',
      ]) {
        final file = named('plan.csv', utf8.encode(first));
        expect(extractor.matches(file), isTrue, reason: first);
        expect(extractor.extract(file), isA<ExtractedText>(), reason: first);
      }
    });

    test('never throws, whatever the bytes', () {
      final shapes = <List<int>>[
        [],
        [0x00],
        [0x50, 0x4B, 0x03, 0x04],
        utf8.encode('Day 1'),
      ];
      for (final shape in shapes) {
        expect(() => extractor.matches(named('x.csv', shape)), returnsNormally);
        expect(() => extractor.extract(named('x.csv', shape)), returnsNormally);
      }
    });
  });

  group('an ISO date column takes the dialect path', () {
    test('dated headers, a quoted field keeps its comma', () {
      final result = extractor.extract(fixture('dated.csv'));
      expect(result, isA<ExtractedText>());
      final text = (result as ExtractedText).text;

      final parsed = parseItinerary(text);
      expect(parsed.days, hasLength(2));
      expect(parsed.days[0].date, DateTime(2027, 6, 14));
      expect(parsed.days[0].confidence, Confidence.high);
      expect(parsed.days[0].place, 'Tokyo');
      expect(
        parsed.days[0].stops.map((s) => s.text),
        ['Senso-ji at 9:00, then Ueno'],
      );
      expect(parsed.days[1].date, DateTime(2027, 6, 15));
      expect(parsed.days[1].place, 'Kyoto');
      expect(
        parsed.days[1].stops.map((s) => s.text),
        ['Fushimi Inari'],
      );
      // The label row is furniture, dropped rather than filed as lines
      // nobody could place.
      expect(parsed.unplacedLines, isEmpty);
    });
  });

  group('no ISO date column falls back to faithful lines', () {
    test('an ambiguous numeric date column stays text; the parser asks', () {
      final result = extractor.extract(fixture('plain.csv'));
      expect(result, isA<ExtractedText>());
      final text = (result as ExtractedText).text;
      expect(text.split('\n'), [
        'Day',
        'Place',
        'Notes',
        '1',
        'Kyoto',
        '3/11, Fushimi Inari early',
        '2',
        'Kyoto',
        'Bamboo grove',
      ]);
      expect(() => parseItinerary(text), returnsNormally);
    });
  });

  group('refusals', () {
    test('an empty file is refused as empty', () {
      final result = extractor.extract(named('empty.csv', const []));
      expect((result as ExtractionFailure).kind, ExtractionFailureKind.empty);
    });

    test('a whitespace-only csv is refused as empty', () {
      final result = extractor.extract(named('blank.csv', utf8.encode('\n\n')));
      expect((result as ExtractionFailure).kind, ExtractionFailureKind.empty);
    });

    test('an oversized file is refused before reading', () {
      final big = Uint8List(maxPlainBytes + 1);
      final result = extractor.extract(named('big.csv', big));
      expect((result as ExtractionFailure).explanation, contains('25 MB'));
    });
  });
}
