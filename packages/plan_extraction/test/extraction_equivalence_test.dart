// The garbled itinerary (the plan's §7 "captain will stress-test with")
// is authored once as text and rendered into every container by
// tool/make_fixtures.dart. This test pins the real promise: whatever
// container the plan arrived in, extraction gives the parser one truth.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:plan_extraction/plan_extraction.dart';

import '../tool/make_fixtures.dart' show garbledPlanLines;

PickedBytes fixture(String name, String extension) => PickedBytes(
      fileName: name,
      extension: extension,
      bytes: Uint8List.fromList(File('test/fixtures/$name').readAsBytesSync()),
    );

/// Normalizes extracted text the same way [garbledPlanLines] was built:
/// collapse internal whitespace, trim, drop blank lines. What differs
/// between containers is layout (blank-line spacing, cell splitting), not
/// content — this is the modulo-whitespace comparison the plan calls for.
List<String> normalizedLines(String text) => text
    .split('\n')
    .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
    .where((l) => l.isNotEmpty)
    .toList();

void main() {
  test('txt and docx extraction of the shared garbled itinerary normalize '
      'to the same lines', () {
    const plainText = PlainTextExtractor();
    const docx = DocxExtractor();

    final fromTxt = plainText.extract(fixture('garbled-itinerary.txt', 'txt'));
    final fromDocx = docx.extract(fixture('garbled-itinerary.docx', 'docx'));

    expect(fromTxt, isA<ExtractedText>());
    expect(fromDocx, isA<ExtractedText>());

    final txtLines = normalizedLines((fromTxt as ExtractedText).text);
    final docxLines = normalizedLines((fromDocx as ExtractedText).text);

    expect(txtLines, garbledPlanLines);
    expect(docxLines, garbledPlanLines);
  });

  test('both containers parse identically — the parser sees one truth no '
      'matter which container the plan arrived in', () {
    const plainText = PlainTextExtractor();
    const docx = DocxExtractor();

    final txt =
        (plainText.extract(fixture('garbled-itinerary.txt', 'txt')) as ExtractedText)
            .text;
    final fromDocx =
        (docx.extract(fixture('garbled-itinerary.docx', 'docx')) as ExtractedText)
            .text;

    final parsedTxt = parseItinerary(txt);
    final parsedDocx = parseItinerary(fromDocx);

    expect(parsedDocx.days.length, parsedTxt.days.length);
    expect(parsedDocx.usedHeaderlessFallback, parsedTxt.usedHeaderlessFallback);
    for (var i = 0; i < parsedTxt.days.length; i++) {
      final a = parsedTxt.days[i];
      final b = parsedDocx.days[i];
      expect(b.date, a.date, reason: 'day $i date');
      expect(b.stops.map((s) => s.text), a.stops.map((s) => s.text),
          reason: 'day $i stop text');
      expect(b.stops.map((s) => s.time), a.stops.map((s) => s.time),
          reason: 'day $i stop times');
    }
  });
}
