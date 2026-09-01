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
    var routeContinuation = false;
    final trustedSelfAreas = <String>{};
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
      final isTrainRoute =
          RegExp(r'^\s*(?:train\s+)?route\b', caseSensitive: false)
              .hasMatch(clean);
      final hadRouteContinuation = routeContinuation;
      if (trainRule &&
          assignedOwn == null &&
          (isTrainRoute || hadRouteContinuation)) {
        final dests = <String>[];
        for (final m in stationRegExp
            .allMatches(raw.replaceAll(RegExp(r'https?://\S+'), ' '))) {
          final d = m.group(1)!;
          final dws = areaTokens(d);
          final isAnchorArea = dws.every((w) => vocab.contains(w));
          final isGazetteerArea =
              hasGaz() && _destinationInGazetteer(dws, gazContains);
          if (dws.isNotEmpty &&
              ((isTrainRoute && isAnchorArea) || isGazetteerArea)) {
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
      if (isTrainRoute) {
        routeContinuation = true;
      } else if (hadRouteContinuation) {
        routeContinuation = false;
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

      if (assignedOwn == null && hasGaz()) {
        final selfArea =
            _gazetteerAreaInStop(clean, trustedSelfAreas, gazContains);
        if (selfArea != null) {
          assignedOwn = selfArea;
          assignedSource = 'travellerDeclared';
          trustedSelfAreas.add(joinedAreaWords(selfArea));
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

bool _destinationInGazetteer(
  List<String> dws,
  bool Function(String normalizedName) contains,
) {
  final filtered = [
    for (final w in dws)
      if (!genericStopWords.contains(w)) w
  ];
  if (filtered.isEmpty) return false;
  final candidates = <String>{filtered.join(' ')};
  if (filtered.length >= 2) {
    final last = filtered.last;
    final withoutLast = filtered.sublist(0, filtered.length - 1);
    if (withoutLast.join() == last) {
      candidates.add(withoutLast.join(' '));
      candidates.add(last);
    }
  }
  return candidates.any(contains);
}

String? _gazetteerAreaInStop(
  String clean,
  Set<String> trustedSelfAreas,
  bool Function(String normalizedName) contains,
) {
  final matches = <String, String>{};
  for (final segment in clean.split(RegExp(r'[/,+&;]'))) {
    final words = areaTokens(segment);
    for (var start = 0; start < words.length; start++) {
      for (var end = start; end < words.length && end < start + 5; end++) {
        final candidateWords = words.sublist(start, end + 1);
        final candidate = candidateWords.join(' ');
        if (areaWords(candidate).isEmpty) continue;
        final precededByDescriptor = start > 0 &&
            (venueGenericWords.contains(words[start - 1]) ||
                mealPrefixWords.contains(words[start - 1]) ||
                furnitureWords.contains(words[start - 1]));
        final isStandalone = start == 0 && end == words.length - 1;
        final isHyphenatedSuffix = RegExp(
                r'(^|\s)' + RegExp.escape(candidate) + r'\s*[-–—](?:\s|$)',
                caseSensitive: false)
            .hasMatch(segment);
        final isPreviouslyTrusted =
            trustedSelfAreas.contains(joinedAreaWords(candidate));
        if (!precededByDescriptor &&
            !isStandalone &&
            !isHyphenatedSuffix &&
            !isPreviouslyTrusted) {
          continue;
        }
        if (venueGenericWords.contains(candidateWords.last) ||
            furnitureWords.contains(candidateWords.last)) {
          continue;
        }
        if (contains(candidate)) {
          matches[joinedAreaWords(candidate)] = candidate;
        }
      }
    }
  }
  if (matches.length != 1) return null;
  return matches.values.single;
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
  // The in-tail grammar is the traveller's own words ("Art & Eats in Le
  // Marais") and is trusted without gazetteer validation — the scorer's
  // `seed_for` validates only the vocabulary-run candidate below.
  final t = inTail(place);
  if (t != null) return t;
  final cands = vocabRuns(place, vocab);
  if (cands.length != 1) return null;
  if (hasGaz() && !contains(areaTokens(cands.first).join(' '))) {
    return null;
  }
  return cands.first;
}
