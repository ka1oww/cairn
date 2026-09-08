import 'dart:io';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:plan_extraction/plan_extraction.dart';
import 'package:test/test.dart';

void main() {
  test('the flagship Wanderlog print remains a three-day plan', () async {
    final file = File('test/fixtures/wanderlog-print.pdf');
    final extracted = await const PdfExtractor().extract(
      PickedBytes(
        fileName: 'wanderlog-print.pdf',
        extension: 'pdf',
        bytes: file.readAsBytesSync(),
      ),
    );
    expect(extracted, isA<ExtractedText>());

    final parsed = parseItinerary((extracted as ExtractedText).text);

    expect(extracted.text, isNot(contains(' Save\n')));
    expect(extracted.text, isNot(contains('9/9 – 9/10')));
    expect(parsed.days.map((day) => day.headerSourceLine?.text), [
      'Day 1',
      'Day 2',
      'Day 3',
    ]);
    expect(parsed.days, hasLength(3));
  });
}
