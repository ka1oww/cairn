/// Held-out validation: 3 itineraries hand-labelled before the extractor was
/// run against them, per plan §8.2 — two AI-written (06 London, 07 Kyoto) and
/// one captain-supplied held-out plan sourced online (08 Tokyo). These rows
/// never informed a threshold or a fix in the GT-tuned corpus
/// (test/fixtures/areas/corpus and gt), so they are the intent's actual
/// "does it generalise" evidence.
library;

import 'dart:io';
import 'package:test/test.dart';
import 'package:itinerary_parser/itinerary_parser.dart';

/// What a held-out doc's score must clear. The two AI docs share the generic
/// "generalises reasonably" bar; doc 08's whole value is refusal (all 25 rows
/// accept NONE), so it is pinned exactly instead — see the floors comment on
/// its entry below.
class Floors {
  final double minRowsOk;
  final int? maxWrong;
  final int? minRowsOkCount;
  const Floors({required this.minRowsOk, this.maxWrong, this.minRowsOkCount});
}

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
    // Held-out docs, keyed by fixture stem: (label, floors).
    final docs = {
      '06-london-heldout': ('London', const Floors(minRowsOk: 50.0)),
      '07-kyoto-heldout': ('Kyoto', const Floors(minRowsOk: 50.0)),
      // 08 is a captain-supplied held-out plan (sourced online): a real 5-day
      // Tokyo itinerary in which every one of the 25 labelled stops is a
      // uniquely-named landmark or is itself an area name, so NONE is in every
      // accept set. It measures the refusal half of the design and nothing
      // else — the engine assigns no area at all today, and a naive ungated
      // rule would get ~7 rows wrong. Hence exact floors rather than the 50%
      // bar: `wrong == 0`, and all 25 rows correct-or-none-ok. There is
      // deliberately NO ceiling on `assigned` — a future rule that correctly
      // assigns `shibuya` to Shibuya Sky moves a row from noneOk to correct
      // and still passes. The floor punishes wrongness, never new coverage.
      '08-captain-japan': (
        'Tokyo',
        const Floors(minRowsOk: 100.0, maxWrong: 0, minRowsOkCount: 25),
      ),
    };

    for (final entry in docs.entries) {
      final (label, floors) = entry.value;
      test('$label held-out doc scores against its hand-labelled TSV', () {
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
            '$label held-out: correct=$correct wrong=$wrong miss=$miss noneOk=$noneOk '
            'rowsOK=${rowsOk.toStringAsFixed(1)}% (n=${gt.length})');

        // The corpus's own GT-pinned floor is 87.5% rowsOK (170/19 correct/wrong
        // over 237 rows). Held-out data was never tuned against, so the generic
        // bar is "generalises reasonably", not "matches the pinned corpus
        // exactly": at least half the rows must land correct or none-ok.
        expect(rowsOk, greaterThanOrEqualTo(floors.minRowsOk),
            reason:
                '$label held-out rowsOK should show the extractor generalises past the tuned corpus');
        final maxWrong = floors.maxWrong;
        if (maxWrong != null) {
          expect(wrong, lessThanOrEqualTo(maxWrong),
              reason:
                  '$label held-out: a wrong area here is a regression in the refusal machinery');
        }
        final minRowsOkCount = floors.minRowsOkCount;
        if (minRowsOkCount != null) {
          expect(correct + noneOk, greaterThanOrEqualTo(minRowsOkCount),
              reason:
                  '$label held-out: every labelled row must land correct or none-ok');
        }
      });
    }
  });
}
