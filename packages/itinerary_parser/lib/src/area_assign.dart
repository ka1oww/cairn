/// Running-area state machine — C7t rules.
///
/// Ported from scorer.py `anchor_assign` (lines 513-609).
library;

import 'area_words.dart';
import 'area_annotations.dart';
import 'area_vocab.dart';
import 'gazetteer.dart';

/// One stop as seen by the assignment engine.
class AreaStopInput {
  final String raw;
  final bool hasTime;
  final int lineNumber;
  const AreaStopInput(
      {required this.raw, required this.hasTime, required this.lineNumber});
}

/// One day as seen by the assignment engine.
class AreaDayInput {
  final String? headerText;
  final String? place;
  final List<AreaStopInput> stops;
  const AreaDayInput({this.headerText, this.place, required this.stops});
}

/// Result for one stop: assigned area text (or null).
class AreaAssignment {
  final String? text;
  final String source; // AreaSource name
  final int? setByLine;
  const AreaAssignment({this.text, required this.source, this.setByLine});
}

/// Assigns areas to all stops. Mirrors scorer's `anchor_assign` with
/// `train_rule=True` (C7t). When [gazetteer] is non-null, enables C10
/// validator behaviour (seed must be gazetteer-listed, bare parenthetical).
Map<int, AreaAssignment> anchorAssign(
  List<String> plines,
  List<AreaDayInput> days,
  Set<String> vocab, {
  bool trainRule = true,
  Set<String>? gazetteer,
  AreaGazetteer? gazetteerObj,
}) {
  bool gazContains(String s) {
    if (gazetteerObj != null) return gazetteerObj.contains(s);
    if (gazetteer != null) return gazetteer.contains(s);
    return false;
  }

  bool hasGaz() => gazetteerObj != null || gazetteer != null;
  final out = <int, AreaAssignment>{};
  String? running;
  int? runningSetBy;

  for (final day in days) {
    final kind = headerKind(day.headerText);
    final seed = _seedForDay(day.place, vocab, gazetteer, gazetteerObj);
    if (kind == 'daynum' || kind == 'date' || kind == 'none') {
      running = seed;
      runningSetBy = seed != null ? -1 : null; // day boundary
    } else if (seed != null) {
      running = seed;
      runningSetBy = -1;
    }
    // unqualified placeHeader: running continues

    for (final s in day.stops) {
      final raw = s.raw;
      final cleanResult = cleanStopText(raw);
      final clean = cleanResult.clean;
      final parens = cleanResult.parens;
      final ws = areaTokens(clean);
      final isMeal = ws.isNotEmpty && mealPrefixWords.contains(ws.first);
      String? assignedOwn;
      String? assignedSource;
      int? assignedSetBy;

      // marker check
      final isHotelLine = hotelWordRegExp.hasMatch(raw);
      final isTransitLeg = ws.isNotEmpty && transitLeadWords.contains(ws.first);
      if (!isMeal &&
          !s.hasTime &&
          clean.isNotEmpty &&
          !isHotelLine &&
          !isTransitLeg) {
        final content = [
          for (final w in ws)
            if (!genericStopWords.contains(w)) w
        ];
        if (content.isNotEmpty && content.length <= 5) {
          final leftover = [
            for (final w in ws)
              if (!genericStopWords.contains(w) &&
                  !venueGenericWords.contains(w) &&
                  !furnitureWords.contains(w) &&
                  !vocab.contains(w))
                w
          ];
          final cands = vocabRuns(clean, vocab);
          if (leftover.isEmpty && cands.length == 1) {
            running = cands.first;
            runningSetBy = s.lineNumber;
            assignedOwn = cands.first;
            assignedSource = 'runningHeading';
            assignedSetBy = s.lineNumber;
          }
        }
      }

      // hotel-prefix rule
      if (assignedOwn == null && !s.hasTime) {
        final m = hotelPrefixRegExp.firstMatch(raw);
        if (m != null) {
          final pw = areaTokens(m.group(1)!);
          if (pw.isNotEmpty && pw.every((w) => vocab.contains(w))) {
            running = pw.join(' ');
            runningSetBy = s.lineNumber;
            assignedOwn = running;
            assignedSource = 'hotelPrefix';
            assignedSetBy = s.lineNumber;
          }
        }
      }

      // train-route destination (C7t)
      if (trainRule && assignedOwn == null) {
        if (RegExp(r'^\s*(?:train\s+)?route\b', caseSensitive: false)
            .hasMatch(clean)) {
          final dests = <String>[];
          for (final m in stationRegExp
              .allMatches(raw.replaceAll(RegExp(r'https?://\S+'), ' '))) {
            final d = m.group(1)!;
            if (areaTokens(d).every((w) => vocab.contains(w))) {
              dests.add(d);
            }
          }
          if (dests.isNotEmpty) {
            running = dests.last;
            runningSetBy = s.lineNumber;
            assignedOwn = running;
            assignedSource = 'trainDestination';
            assignedSetBy = s.lineNumber;
          }
        }
      }

      // in-tail locality (this stop only)
      if (assignedOwn == null && !isTransitLeg) {
        final t = inTail(clean);
        if (t != null) {
          assignedOwn = t;
          assignedSource = 'inlineLocality';
          // running unchanged
        }
      }

      String? assigned = assignedOwn ?? running;
      String? source =
          assignedSource ?? (assigned != null ? 'runningHeading' : 'none');
      int? setBy = assignedSetBy ?? runningSetBy;
      // For inlineLocality, source is inlineLocality even when via assignedOwn
      // For running fallback, source is runningHeading

      // Determine effective source for running fallback
      if (assignedOwn == null && assigned != null) {
        source = 'runningHeading';
        setBy = runningSetBy;
      }

      // overrides: traveller annotation beats context
      var overridden = false;
      for (final ann in travellerAnnotations(raw)) {
        if (ann.kind == 'declared' ||
            areaTokens(ann.capture).any((w) => vocab.contains(w))) {
          assigned = ann.capture;
          source = ann.kind == 'declared'
              ? 'travellerDeclared'
              : 'travellerProximity';
          setBy = null; // own-line source
          overridden = true;
          break;
        }
      }
      if (!overridden && hasGaz()) {
        for (final p in parens) {
          final pws = [
            for (final w in areaTokens(p))
              if (!genericStopWords.contains(w) &&
                  !venueGenericWords.contains(w))
                w
          ];
          if (pws.isNotEmpty && pws.length <= 3 && gazContains(pws.join(' '))) {
            assigned = pws.join(' ');
            source = 'travellerProximity';
            setBy = null;
            break;
          }
        }
      }

      // Normalize: if assigned is empty/furniture-like with no content, keep null run semantics
      // But scorer assigns the raw capture — we keep it.

      out[s.lineNumber] =
          AreaAssignment(text: assigned, source: source!, setByLine: setBy);
    }
  }
  return out;
}

String? _seedForDay(String? place, Set<String> vocab, Set<String>? gazetteer,
    AreaGazetteer? gazObj) {
  bool contains(String s) {
    if (gazObj != null) return gazObj.contains(s);
    if (gazetteer != null) return gazetteer.contains(s);
    return false;
  }

  bool hasGaz() => gazObj != null || gazetteer != null;
  if (place == null || isFurniture(place)) return null;
  final t = inTail(place);
  if (t != null) {
    if (hasGaz() && !contains(areaTokens(t).join(' '))) {
      return null;
    }
    return t;
  }
  final cands = vocabRuns(place, vocab);
  if (cands.length != 1) return null;
  if (hasGaz() && !contains(areaTokens(cands.first).join(' '))) {
    return null;
  }
  return cands.first;
}
