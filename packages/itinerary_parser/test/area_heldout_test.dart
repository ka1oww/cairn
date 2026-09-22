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

bool _isUpperAscii(String token) {
  if (token.isEmpty) return false;
  final c = token.codeUnitAt(0);
  return c >= 0x41 && c <= 0x5A;
}

/// A label row's note names the venue it labels — the authority a re-anchored
/// line number is checked against. Every one of these hand-written notes
/// opens with the venue name, so this takes the note's *first* maximal run of
/// capitalized tokens (a run breaks at the first lowercase word, e.g.
/// "near"/"under"/"name") and tries every contiguous window of it, longest
/// first, down to length 2 (a run that is itself only one word is used
/// as-is). Two things are load-bearing. Sliding the window matters: a note
/// like "Portobello Road Market Notting Hill" has no internal lowercase word
/// to break the run before the day's area name, so the venue phrase
/// ("Portobello Road Market") is a *sub*-window of the run, not the whole of
/// it. And stopping at the first run matters just as much: a note like
/// "Brick Lane Market under Shoreditch heading" has a second run
/// ("Shoreditch") that is the day's area, not the venue, and every stop on
/// that day mentions it — accepting it as a fallback candidate would let a
/// label drifted onto a wrong neighbouring stop match anyway, exactly the
/// silent failure this check exists to catch. The floor of length 2 for a
/// multi-word run (never shrinking a real run down to one generic word) is
/// the other half of that same guard.
bool _noteAnchorsLine(String note, String lineText) {
  final tokens = note.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final run = <String>[];
  for (final t in tokens) {
    if (_isUpperAscii(t)) {
      run.add(t);
    } else {
      break;
    }
  }
  if (run.isEmpty) return false;
  if (run.length == 1) return lineText.contains(run[0]);

  for (var len = run.length; len >= 2; len--) {
    for (var start = 0; start + len <= run.length; start++) {
      final candidate = run.sublist(start, start + len).join(' ');
      if (lineText.contains(candidate)) return true;
    }
  }
  return false;
}

void main() {
  group('area held-out validation', () {
    // 06 and 07 are AI-written docs whose labels were re-anchored by hand
    // (see git history) after the underlying documents drifted out from
    // under stale line numbers. The text-anchor guard below is the check
    // that a resolved line still names the note's venue, not just any line;
    // it applies to these two because they are the ones the drift actually
    // hit. 08 is a captain-supplied document whose numbering was verified
    // consistent with its labels and needed no repair.
    final textAnchoredDocs = {'06-london-heldout', '07-kyoto-heldout'};

    // Held-out docs, keyed by fixture stem: (label, floors).
    //
    // London and Kyoto's floors were ratcheted on 2026-09-22 after the label
    // rows were re-anchored to the lines that actually hold the venues they
    // name (they had drifted after the documents were edited without
    // renumbering the labels) and the text-anchor guard above was added.
    // Before the repair, most rows silently failed to resolve at all and
    // fell through to a trivial none-ok agreement, inflating the reported
    // figure (London 66.7%, Kyoto 62.5%). With every row now resolving
    // against the venue its note actually names, the honest figures are
    // London 88.9% (8/9 rows correct-or-none-ok, exactly 800/9) and Kyoto
    // 87.5% (7/8). Both floors below sit fractionally under the exact
    // measured value only for floating-point safety, not as a padded
    // margin, and `minRowsOkCount` pins the same floor as an exact integer.
    // `maxWrong` is new: neither document had one before, and a `wrong`
    // verdict here is a composed-Maps-query defect, so it gets a ceiling at
    // the count this measurement actually found (0 for London, 1 for
    // Kyoto's remaining miss).
    final docs = {
      '06-london-heldout': (
        'London',
        const Floors(minRowsOk: 88.8, maxWrong: 0, minRowsOkCount: 8),
      ),
      '07-kyoto-heldout': (
        'Kyoto',
        const Floors(minRowsOk: 87.5, maxWrong: 1, minRowsOkCount: 7),
      ),
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
      '08-tokyo-heldout': (
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
        final checkTextAnchor = textAnchoredDocs.contains(entry.key);

        int correct = 0, wrong = 0, miss = 0, noneOk = 0;
        // A label row must point at a line the parser actually returned a stop
        // for. A stale line number (label written against an earlier revision
        // of the document) resolves to nothing, and scoring that as an
        // unassigned stop lets a broken fixture pass on NONE agreement — so an
        // unresolved row is collected here and fails the test outright below.
        final unresolved = <String>[];
        // A label row can also drift onto a *different real stop* rather than
        // onto nothing — the unresolved guard alone is silent about that, and
        // it was the majority of the corruption this corpus actually had. So
        // a resolved row is also checked against the note's own venue text.
        final misanchored = <String>[];
        for (final row in gt) {
          String? assigned;
          String? lineText;
          var resolved = false;
          for (final d in result.days) {
            for (final s in d.stops) {
              if (s.sourceLine.lineNumber == row.line) {
                assigned = s.area?.text;
                lineText = s.sourceLine.text;
                resolved = true;
              }
            }
          }
          if (!resolved) {
            unresolved.add('line ${row.line} (${row.note})');
            continue;
          }
          if (checkTextAnchor && !_noteAnchorsLine(row.note, lineText!)) {
            misanchored.add('line ${row.line}: note "${row.note}" not found '
                'in resolved stop text "$lineText"');
            continue;
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

        expect(unresolved, isEmpty,
            reason: '$label held-out: these label rows point at a line no '
                'longer held by a stop, so they cannot be scored: '
                '${unresolved.join('; ')}');

        expect(misanchored, isEmpty,
            reason: '$label held-out: these label rows resolved to a line '
                "that doesn't hold the venue they name, so they scored "
                'against the wrong stop: ${misanchored.join('; ')}');

        // This figure is per *document*, which is the only level at which a
        // combined percentage still means something: the tuned corpus's own
        // floors are per genre (area_ground_truth_test.dart) precisely
        // because averaging five documents of three different kinds measured
        // nothing. Held-out data was never tuned against, so the bar is
        // "generalises reasonably", not "matches the tuned corpus" — see the
        // per-document floor comments above for what each one now requires.
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
