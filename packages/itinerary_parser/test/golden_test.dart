import 'dart:convert';
import 'dart:io';

import 'package:itinerary_parser/itinerary_parser.dart';
import 'package:test/test.dart';

/// Runs every `test/fixtures/*.input.txt` through [parseItinerary] and
/// compares the result against the matching `*.expected.json`.
///
/// A fixture may optionally have a `*.meta.json` sidecar with a
/// `tripStartDate` (`YYYY-MM-DD`) to pass through as the parser's
/// `tripStartDate` argument.
void main() {
  final fixturesDir = Directory('test/fixtures');
  final inputFiles = fixturesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.input.txt'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('at least 12 golden fixtures are present', () {
    expect(
      inputFiles.length,
      greaterThanOrEqualTo(12),
      reason: 'expected at least 12 golden fixtures in test/fixtures/',
    );
  });

  for (final inputFile in inputFiles) {
    final base = inputFile.path
        .substring(0, inputFile.path.length - '.input.txt'.length);
    final name = base.split(Platform.pathSeparator).last;

    test('golden: $name', () {
      final input = inputFile.readAsStringSync();

      final metaFile = File('$base.meta.json');
      DateTime? tripStartDate;
      if (metaFile.existsSync()) {
        final meta =
            jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
        final raw = meta['tripStartDate'] as String?;
        if (raw != null) {
          tripStartDate = DateTime.parse(raw);
        }
      }

      final result = parseItinerary(input, tripStartDate: tripStartDate);

      final expectedFile = File('$base.expected.json');
      expect(
        expectedFile.existsSync(),
        isTrue,
        reason: 'missing golden file: ${expectedFile.path}',
      );
      final expected = jsonDecode(expectedFile.readAsStringSync());

      final actualJson = jsonDecode(jsonEncode(result.toJson()));
      expect(actualJson, equals(expected));
    });
  }
}
