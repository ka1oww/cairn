// The corpus measurement run. `dart run tool/measure_plan_corpus.dart`.
//
// It exists because a blended figure over the whole corpus is not a
// measurement of anything a traveller experiences: the easiest genre is 42%
// of the labelled rows, so a number that averages the five documents moves
// when the easy genre moves and hides everything else. Every figure here is
// reported per genre, and the genres are the three kinds of document people
// actually paste:
//
//   handwritten   01-captain-tokyo      (a person's own notes)
//   ai-written    03/04/05              (a chat assistant's markdown)
//   wanderlog     02-wanderlog-japan    (a browser's print-to-PDF)
//
// What each figure measures, exactly, because a number whose meaning is
// unclear is worse than no number:
//
//   days      how many days `parseItinerary` returned, against how many the
//             document itself writes down (see `_writtenDays` for where each
//             expected count comes from — it is read off the document, never
//             off the parser).
//   stops     how many stops `parseItinerary` returned across all days. There
//             is no ground truth for this; it is reported so a segmentation
//             change that silently multiplies stops is visible.
//   areas     scored ONLY over the captain's hand-labelled ground-truth rows
//             (`test/fixtures/areas/gt/*.tsv`), four ways and never three:
//               sent-right   an area was sent and the label accepts it
//               sent-wrong   an area was sent and the label refuses it
//               none-right   no area was sent and the label says NONE is fine
//               none-wrong   no area was sent and the label wanted one
//             Wrong and missing are never added together. A wrong area is the
//             failure that sent a Japan traveller to Singapore; a missing one
//             is a search that is merely no better than the words typed.
//   taps      over EVERY parsed stop, not only the labelled ones, because the
//             affordance is drawn on every row the day page draws. Decided by
//             the app's own rule (`sendableSearchText`), called directly and
//             never copied:
//               distinct    a tap is offered and the line names a place that
//                           a maps app can find on its own words
//               ambiguous   a tap is offered and the line names a place whose
//                           name is not enough: the same name appears
//                           elsewhere in this plan under a different area
//               placeless   a tap is offered and the line names no place at
//                           all (`LUNCH: OUTLET`). The count Fix 4 drives to
//                           zero.
//               no-tap      no tap is offered. Notes, section labels,
//                           alternatives and multi-place rows live here, and
//                           this is the honest resting place for a placeless
//                           line too.
//             `ambiguous` is split again by whether an area is being sent
//             with it (`amb+area` / `amb-none`): a chain with no area is a
//             coin flip across every branch, and is what Fix 3 exists for.
//
// No blended number is printed anywhere, on purpose.
import 'dart:convert';
import 'dart:io';

import 'package:itinerary_parser/itinerary_parser.dart';

import 'package:cairn/logic/maps_handoff.dart';

const _corpusDir = 'packages/itinerary_parser/test/fixtures/areas/corpus';
const _gtDir = 'packages/itinerary_parser/test/fixtures/areas/gt';
const _gazetteerDir = 'assets/area_gazetteer';

/// The documents, in genre order.
const List<CorpusDoc> corpus = [
  CorpusDoc('01', '01-captain-tokyo', Genre.handwritten),
  CorpusDoc('03', '03-ai-kyoto-osaka', Genre.aiWritten),
  CorpusDoc('04', '04-ai-seoul', Genre.aiWritten),
  CorpusDoc('05', '05-ai-paris', Genre.aiWritten),
  CorpusDoc('02', '02-wanderlog-japan', Genre.wanderlog),
];

enum Genre { handwritten, aiWritten, wanderlog }

extension GenreName on Genre {
  String get label => switch (this) {
    Genre.handwritten => 'handwritten',
    Genre.aiWritten => 'ai-written',
    Genre.wanderlog => 'wanderlog',
  };
}

class CorpusDoc {
  final String key;
  final String name;
  final Genre genre;
  const CorpusDoc(this.key, this.name, this.genre);
}

/// How many days each document *writes down*, counted by hand off the
/// document itself and never off a parse:
///
///   01  five `DAY n` headers (`DAY 3` is written twice, at lines 106 and
///       159, and the parser is right to keep both — nothing here dedupes a
///       traveller's own claim).
///   02  eighteen dated headings, `Monday, November 30th` through
///       `Thursday, December 17th`, matching the trip range the page prints
///       at its top (`11/30 - 12/17`).
///   03  seven `## Day n:` headings.  04  five.  05  four.
const Map<String, int> writtenDays = {
  '01': 5,
  '02': 18,
  '03': 7,
  '04': 5,
  '05': 4,
};

// ---------------------------------------------------------------------------

class DocReport {
  final CorpusDoc doc;
  final int days;
  final int stops;
  int sentRight = 0, sentWrong = 0, noneRight = 0, noneWrong = 0;
  int tapDistinct = 0, tapAmbiguousWithArea = 0, tapAmbiguousNoArea = 0;
  int tapPlaceless = 0, noTap = 0;

  /// Tappable stops carrying no area at all — Fix 3's whole catchment.
  int tapNoArea = 0;
  final List<String> wrongRows = [];
  final List<String> placelessRows = [];
  final List<String> ambiguousRows = [];

  int get tapAmbiguous => tapAmbiguousWithArea + tapAmbiguousNoArea;
  DocReport(this.doc, this.days, this.stops);

  int get expectedDays => writtenDays[doc.key]!;
  int get gtRows => sentRight + sentWrong + noneRight + noneWrong;
}

/// One document's whole measurement.
DocReport measureDoc(CorpusDoc doc, {AreaGazetteer? gazetteer}) {
  final text = File('$_corpusDir/${doc.name}.txt').readAsStringSync();
  final result = parseItinerary(
    preprocessForDoc(doc.key, text),
    gazetteer: gazetteer,
  );

  final stops = result.days.fold<int>(0, (n, d) => n + d.stops.length);
  final report = DocReport(doc, result.days.length, stops);

  final byLine = <int, Stop>{};
  for (final day in result.days) {
    for (final stop in day.stops) {
      byLine[stop.sourceLine.lineNumber] = stop;
    }
  }
  final ambiguous = repeatedNamesUnderDifferentAreas(result);

  for (final row in loadGroundTruth('$_gtDir/${doc.name}.tsv')) {
    final stop = byLine[row.line];
    final assigned = stop?.area?.text;
    switch (areaVerdict(assigned, row.accepts)) {
      case 'correct':
        report.sentRight++;
      case 'wrong':
        report.sentWrong++;
        report.wrongRows.add(
          '${doc.name}:${row.line} sent "$assigned" '
          'want ${row.accepts.join("|")}',
        );
      case 'none-ok':
        report.noneRight++;
      default:
        report.noneWrong++;
    }
  }

  for (final day in result.days) {
    for (final stop in day.stops) {
      final search = tapSearchTextFor(stop);
      if (search != null && stop.area?.text == null) report.tapNoArea++;
      if (search == null) {
        report.noTap++;
      } else if (namesNoPlace(search)) {
        report.tapPlaceless++;
        report.placelessRows.add(
          '${doc.name}:${stop.sourceLine.lineNumber} "$search"',
        );
      } else if (ambiguous.contains(normalizedArea(search))) {
        if (stop.area?.text != null) {
          report.tapAmbiguousWithArea++;
        } else {
          report.tapAmbiguousNoArea++;
        }
        report.ambiguousRows.add(
          '${doc.name}:${stop.sourceLine.lineNumber} '
          '"$search" area=${stop.area?.text ?? "-"}',
        );
      } else {
        report.tapDistinct++;
      }
    }
  }
  return report;
}

/// The words one stop's tap would search for, decided by the app's own rule.
String? tapSearchTextFor(Stop stop) {
  final meal = stop.kind == StopKind.mealLabel
      ? mealLabelSplit(stop.text)
      : (label: null, rest: stop.text.trim());
  return sendableSearchText(
    isPlace: stop.kind == StopKind.place,
    isMealLabel: stop.kind == StopKind.mealLabel,
    placeText: stop.placeText,
    placeCandidates: stop.placeCandidates,
    mealRest: meal.rest,
  );
}

/// Names this plan uses more than once under more than one area.
///
/// The structural half of "is this name enough on its own", and it needs no
/// list of chains: a plan that writes `Ichiran` in Shibuya and `Ichiran` in
/// Namba has said, by writing it twice in two places, that the name alone
/// does not locate anything. The captain's corpus contains five such
/// collisions, two of them genuinely different Shiraito Waterfalls in one
/// Japan trip.
Set<String> repeatedNamesUnderDifferentAreas(ParseResult result) {
  final areasPerName = <String, Set<String>>{};
  for (final day in result.days) {
    for (final stop in day.stops) {
      final search = tapSearchTextFor(stop);
      if (search == null || namesNoPlace(search)) continue;
      final key = normalizedArea(search);
      if (key.isEmpty) continue;
      areasPerName
          .putIfAbsent(key, () => <String>{})
          .add(normalizedArea(stop.area?.text ?? ''));
    }
  }
  return {
    for (final entry in areasPerName.entries)
      if (entry.value.length > 1) entry.key,
  };
}

// ---------------------------------------------------------------------------
// Ground truth loading. Read only; nothing here ever writes a fixture.
// ---------------------------------------------------------------------------

class GtRow {
  final int line;
  final List<String> accepts;
  final String note;
  const GtRow(this.line, this.accepts, this.note);
}

List<GtRow> loadGroundTruth(String path) => [
  for (final line in File(path).readAsLinesSync())
    if (line.isNotEmpty && !line.startsWith('#'))
      () {
        final parts = line.split('\t');
        return GtRow(
          int.parse(parts[0]),
          parts[1].split('|'),
          parts.length > 2 ? parts[2] : '',
        );
      }(),
];

/// The per-document preprocessing the ground-truth harness has always used.
///
/// It stands in for what the *import* layer does to a real file before the
/// paste box sees it: doc 02's corpus text is the raw PDF text layer with the
/// travel-time column still glued to the right of the day heading, and docs
/// 03-05 are markdown a chat assistant emitted. Keeping it here, verbatim,
/// is what makes the tool and the ground-truth test measure the same parse.
String preprocessForDoc(String docKey, String text) {
  var lines = text.split('\n');
  if (docKey == '02') {
    final trailer = RegExp(
      r'^<?\s*\d[\d\s,.·]*\s*(days?|hrs?|hr|mins?|min)\b',
      caseSensitive: false,
    );
    lines = [
      for (final l in lines)
        () {
          final m = RegExp(r'^(.*\S)\s{8,}(\S.*)$').firstMatch(l);
          if (m != null && trailer.hasMatch(m.group(2)!)) return m.group(1)!;
          return l;
        }(),
    ];
  }
  if (docKey == '03') {
    for (var i = 0; i < 11 && i < lines.length; i++) {
      lines[i] = '';
    }
  }
  if (docKey == '03' || docKey == '04' || docKey == '05') {
    lines = [
      for (final l in lines)
        l.replaceAll(RegExp(r'^\s*#{1,6}\s*'), '').replaceAll('**', ''),
    ];
  }
  return lines.join('\n');
}

/// The committed gazetteer assets, inflated the way the app's import path
/// does it. Returns null when they are not where this tool expects them.
AreaGazetteer? loadCommittedGazetteer({String dir = _gazetteerDir}) {
  final d = Directory(dir);
  if (!d.existsSync()) return null;
  final texts = [
    for (final f in d.listSync().whereType<File>())
      if (f.path.endsWith('.txt.gz'))
        utf8.decode(gzip.decode(f.readAsBytesSync())),
  ];
  if (texts.isEmpty) return null;
  return SortedListAreaGazetteer.fromAssetTexts(texts);
}

// ---------------------------------------------------------------------------

void main(List<String> args) {
  final verbose = args.contains('--rows');
  final gazetteer = loadCommittedGazetteer();
  stdout.writeln(
    gazetteer == null
        ? 'gazetteer: NOT LOADED (phase-1 behaviour)'
        : 'gazetteer: committed assets loaded',
  );
  stdout.writeln('');
  _table('WITHOUT the gazetteer', null, verbose);
  stdout.writeln('');
  _table('WITH the committed gazetteer', gazetteer, verbose);
}

void _table(String title, AreaGazetteer? gazetteer, bool verbose) {
  stdout.writeln('== $title ==');
  stdout.writeln(
    'genre        document              days(want)  stops  '
    'sent-right sent-wrong none-right none-wrong  '
    'distinct amb+area amb-none placeless no-tap  tap-no-area',
  );
  final reports = [
    for (final doc in corpus) measureDoc(doc, gazetteer: gazetteer),
  ];
  Genre? last;
  for (final r in reports) {
    final genre = r.doc.genre == last ? '' : r.doc.genre.label;
    last = r.doc.genre;
    final dayCell =
        '${r.days}(${r.expectedDays})'
        '${r.days == r.expectedDays ? ' ' : '!'}';
    stdout.writeln(
      '${genre.padRight(13)}${r.doc.name.padRight(22)}'
      '${dayCell.padRight(12)}${r.stops.toString().padRight(7)}'
      '${r.sentRight.toString().padRight(11)}'
      '${r.sentWrong.toString().padRight(11)}'
      '${r.noneRight.toString().padRight(11)}'
      '${r.noneWrong.toString().padRight(12)}'
      '${r.tapDistinct.toString().padRight(9)}'
      '${r.tapAmbiguousWithArea.toString().padRight(9)}'
      '${r.tapAmbiguousNoArea.toString().padRight(9)}'
      '${r.tapPlaceless.toString().padRight(10)}'
      '${r.noTap.toString().padRight(7)}'
      '${r.tapNoArea}',
    );
  }
  for (final genre in Genre.values) {
    final inGenre = reports.where((r) => r.doc.genre == genre);
    if (inGenre.length < 2) continue;
    int sum(int Function(DocReport) f) =>
        inGenre.fold<int>(0, (n, r) => n + f(r));
    stdout.writeln(
      '${'  ${genre.label} total'.padRight(35)}'
      '${' '.padRight(12)}${sum((r) => r.stops).toString().padRight(7)}'
      '${sum((r) => r.sentRight).toString().padRight(11)}'
      '${sum((r) => r.sentWrong).toString().padRight(11)}'
      '${sum((r) => r.noneRight).toString().padRight(11)}'
      '${sum((r) => r.noneWrong).toString().padRight(12)}'
      '${sum((r) => r.tapDistinct).toString().padRight(9)}'
      '${sum((r) => r.tapAmbiguousWithArea).toString().padRight(9)}'
      '${sum((r) => r.tapAmbiguousNoArea).toString().padRight(9)}'
      '${sum((r) => r.tapPlaceless).toString().padRight(10)}'
      '${sum((r) => r.noTap).toString().padRight(7)}'
      '${sum((r) => r.tapNoArea)}',
    );
  }
  if (!verbose) return;
  for (final r in reports) {
    for (final row in r.wrongRows) {
      stdout.writeln('  WRONG  $row');
    }
    for (final row in r.placelessRows) {
      stdout.writeln('  PLACELESS  $row');
    }
    for (final row in r.ambiguousRows) {
      stdout.writeln('  AMBIGUOUS  $row');
    }
  }
}
