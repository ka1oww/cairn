/// Held-out validation: 2 AI itineraries hand-labelled before the extractor
/// was run against them, per plan §8.2. These rows never informed a threshold
/// or a fix in the GT-tuned corpus (test/fixtures/areas/corpus and gt), so
/// they are the intent's actual "does it generalise" evidence.
library;

import 'dart:io';
import 'package:test/test.dart';
import 'package:itinerary_parser/itinerary_parser.dart';

class GtRow {
  final int line;
  final List<String> accepts;
  final String note;
  const GtRow(this.line, this.accepts, this.note);
}

List<GtRow> _loadGt(String path) {
  final rows = <GtRow>[];
  for (final line in File(path).readAsLinesSync()) {
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split('\t');
    rows.add(GtRow(int.parse(parts[0]), parts[1].split('|'),
        parts.length > 2 ? parts[2] : ''));
  }
  return rows;
}

void main() {
  group('area held-out validation', () {
    final docs = {
      '06-london-heldout': 'London',
      '07-kyoto-heldout': 'Kyoto',
    };

    for (final entry in docs.entries) {
      test('${entry.value} held-out doc scores against its hand-labelled TSV',
          () {
        final corpusFile = File('test/fixtures/areas/heldout/${entry.key}.txt');
        final gt = _loadGt('test/fixtures/areas/heldout/${entry.key}.tsv');
        final result = parseItinerary(corpusFile.readAsStringSync());

        int correct = 0, wrong = 0, miss = 0, noneOk = 0;
        for (final row in gt) {
          String? assigned;
          for (final d in result.days) {
            for (final s in d.stops) {
              if (s.sourceLine.lineNumber == row.line) assigned = s.area?.text;
            }
          }
          final v = areaVerdict(assigned, row.accepts);
          if (v == 'correct') {
            correct++;
          } else if (v == 'wrong') {
            wrong++;
          } else if (v == 'miss') {
            miss++;
          } else if (v == 'none-ok') {
            noneOk++;
          }
        }
        final rowsOk = (correct + noneOk) / gt.length * 100;
        // ignore: avoid_print
        print(
            '${entry.value} held-out: correct=$correct wrong=$wrong miss=$miss noneOk=$noneOk '
            'rowsOK=${rowsOk.toStringAsFixed(1)}% (n=${gt.length})');

        // The corpus's own GT-pinned floor is 87.5% rowsOK (170/19 correct/wrong
        // over 237 rows). Held-out data was never tuned against, so the bar is
        // "generalises reasonably", not "matches the pinned corpus exactly":
        // at least half the rows must land correct or none-ok.
        expect(rowsOk, greaterThanOrEqualTo(50.0),
            reason:
                '${entry.value} held-out rowsOK should show the extractor generalises past the tuned corpus');
      });
    }
  });
}
