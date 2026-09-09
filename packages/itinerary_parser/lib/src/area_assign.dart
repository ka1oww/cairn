/// Running-area state machine — C7t rules.
///
/// Ported from scorer.py `anchor_assign` (lines 513-609).
library;

import 'area_words.dart';
import 'area_annotations.dart';
import 'area_vocab.dart';
import 'gazetteer.dart';
import 'place_content.dart';

/// One stop as seen by the assignment engine.
class AreaStopInput {
  final int assignmentId;
  final String raw;
  final bool hasTime;
  final int lineNumber;
  const AreaStopInput({
    required this.assignmentId,
    required this.raw,
    required this.hasTime,
    required this.lineNumber,
  });
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
  final int? setByAssignmentId;
  const AreaAssignment({
    this.text,
    required this.source,
    this.setByLine,
    this.setByAssignmentId,
  });
}

/// Assigns areas to all stops. Grew out of scorer's `anchor_assign` with
/// `train_rule=True` (C7t). When [gazetteer] is non-null, enables C10
/// validator behaviour (seed must be gazetteer-listed, bare parenthetical)
/// and upgrades the two evidence rules stated in the package README:
/// stop-line self-evidence runs in both modes (against the gazetteer where
/// there is one, the plan's own anchor vocabulary where there is not), and
/// the train-route continuation line needs a gazetteer. Results are
/// keyed by [AreaStopInput.assignmentId], which stays distinct when several
/// stops were derived from one source line.
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
  // What counts as a known area, in the two modes. With a gazetteer the
  // window has to be an entry, and any word may sit inside one. Without a
  // gazetteer the plan's own anchor vocabulary is the evidence, so a window
  // qualifies exactly when every word of it is a vocabulary word -- which
  // makes `mayJoin` the whole test and lets the window walk stop at the
  // first word the plan has not corroborated.
  bool gazNames(List<String> ws) => gazContains(ws.join(' '));
  bool anyWord(String _) => true;
  bool anyWindow(List<String> ws) => ws.isNotEmpty;

  // The two passes read the same lines, so the tokenizer runs over each
  // segment once rather than twice.
  final segmentTokens = <String, List<String>>{};

  final out = <int, AreaAssignment>{};
  String? running;
  int? runningSetBy;
  int? runningSetByAssignmentId;

  // An area the plan declares about a stop of its own is evidence about the
  // whole plan, not only about the lines after it. The set was per day and
  // filled in reading order, so `SKY CAFE HAKUBA` taught the engine `hakuba`
  // at the sixth stop of the day and the first and second -- `Hakuba Happo
  // Bus Terminal`, `Hakuba Happo-One Snow Resort` -- had already been sent to
  // Nagano, sixty miles away. So it is plan-wide, and the whole assignment
  // runs twice: the second pass starts knowing everything the first one
  // learned. Trust is still earned the same way, from a name the mode's
  // evidence knows (the gazetteer, or the anchor vocabulary without one)
  // that is the only area its own line can be read as; only when it counts
  // has changed.
  final trustedSelfAreas = <String>{};

  for (var pass = 0; pass < 2; pass++) {
    running = null;
    runningSetBy = null;
    runningSetByAssignmentId = null;
    for (final day in days) {
      var routeContinuation = false;
      final kind = headerKind(day.headerText);
      final seed = _seedForDay(day.place, vocab, gazetteer, gazetteerObj);
      if (kind == 'daynum' || kind == 'date' || kind == 'none') {
        running = seed;
        runningSetBy = seed != null ? -1 : null; // day boundary
        runningSetByAssignmentId = null;
      } else if (seed != null) {
        running = seed;
        runningSetBy = -1;
        runningSetByAssignmentId = null;
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
        int? assignedSetByAssignmentId;

        // marker check
        final isHotelLine = hotelWordRegExp.hasMatch(raw);
        final isTransitLeg =
            ws.isNotEmpty && transitLeadWords.contains(ws.first);
        if (!isMeal &&
            !s.hasTime &&
            clean.isNotEmpty &&
            !isHotelLine &&
            !isTransitLeg) {
          final content = [
            for (final w in ws)
              if (!genericStopWords.contains(w)) w,
          ];
          if (content.isNotEmpty && content.length <= 5) {
            final leftover = [
              for (final w in ws)
                if (!genericStopWords.contains(w) &&
                    !venueGenericWords.contains(w) &&
                    !furnitureWords.contains(w) &&
                    !vocab.contains(w))
                  w,
            ];
            final cands = vocabRuns(clean, vocab);
            if (leftover.isEmpty && cands.length == 1) {
              running = cands.first;
              runningSetBy = s.lineNumber;
              runningSetByAssignmentId = s.assignmentId;
              assignedOwn = cands.first;
              assignedSource = 'runningHeading';
              assignedSetBy = s.lineNumber;
              assignedSetByAssignmentId = s.assignmentId;
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
              runningSetByAssignmentId = s.assignmentId;
              assignedOwn = running;
              assignedSource = 'hotelPrefix';
              assignedSetBy = s.lineNumber;
              assignedSetByAssignmentId = s.assignmentId;
            }
          }
        }

        // train-route destination (C7t)
        final isTrainRoute = RegExp(
          r'^\s*(?:train\s+)?route\b',
          caseSensitive: false,
        ).hasMatch(clean);
        final hadRouteContinuation = routeContinuation;
        if (trainRule &&
            assignedOwn == null &&
            (isTrainRoute || hadRouteContinuation)) {
          final dests = <String>[];
          for (final m in stationRegExp.allMatches(
            raw.replaceAll(RegExp(r'https?://\S+'), ' '),
          )) {
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
            runningSetByAssignmentId = s.assignmentId;
            assignedOwn = running;
            assignedSource = 'trainDestination';
            assignedSetBy = s.lineNumber;
            assignedSetByAssignmentId = s.assignmentId;
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

        // stop-line self-evidence: a unique known area named by the line
        // itself beats the running heading. What counts as known is the
        // gazetteer where there is one and the plan's own anchor vocabulary
        // where there is not.
        if (assignedOwn == null) {
          final selfArea = _gazetteerAreaInStop(
            clean,
            trustedSelfAreas,
            hasGaz() ? gazNames : anyWindow,
            hasGaz() ? anyWord : vocab.contains,
            segmentTokens,
          );
          if (selfArea != null) {
            assignedOwn = selfArea;
            assignedSource = hasGaz() ? 'travellerDeclared' : 'selfEvidence';
            trustedSelfAreas.add(joinedAreaWords(selfArea));
          }
        }

        String? assigned = assignedOwn ?? running;
        String? source =
            assignedSource ?? (assigned != null ? 'runningHeading' : 'none');
        int? setBy = assignedSetBy ?? runningSetBy;
        int? setByAssignmentId =
            assignedSetByAssignmentId ?? runningSetByAssignmentId;
        // For inlineLocality, source is inlineLocality even when via assignedOwn
        // For running fallback, source is runningHeading

        // Determine effective source for running fallback
        if (assignedOwn == null && assigned != null) {
          source = 'runningHeading';
          setBy = runningSetBy;
          setByAssignmentId = runningSetByAssignmentId;
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
            setByAssignmentId = null;
            overridden = true;
            break;
          }
        }
        // A bare parenthetical the evidence knows as a place is the
        // traveller saying where the line is: `Ogawa coffee laboratory
        // (SHIMOKITAZAWA)`. What counts as known is the gazetteer where
        // there is one and the plan's own anchor vocabulary where there is
        // not, exactly as for the stop-line self-evidence above.
        if (!overridden) {
          for (final p in parens) {
            final pws = [
              for (final w in areaTokens(p))
                if (!genericStopWords.contains(w) &&
                    !venueGenericWords.contains(w))
                  w,
            ];
            // One word, not three, when the vocabulary is the only evidence.
            // A gazetteer can confirm that a phrase is a real place name;
            // the vocabulary cannot, and a plan that writes
            // `MOUMOU TEI (BEEF BOWL)` twice corroborates `beef` and `bowl`
            // exactly as it corroborates a district. A multi-word
            // parenthetical is a description far more often than an address,
            // and a single corroborated word is the tightest this evidence
            // gets.
            if (pws.isNotEmpty &&
                (hasGaz()
                    ? pws.length <= 3 && gazContains(pws.join(' '))
                    : pws.length == 1 && vocab.contains(pws.single))) {
              assigned = pws.join(' ');
              source = 'travellerProximity';
              setBy = null;
              setByAssignmentId = null;
              break;
            }
          }
        }

        // Normalize: if assigned is empty/furniture-like with no content, keep null run semantics
        // But scorer assigns the raw capture — we keep it.

        out[s.assignmentId] = AreaAssignment(
          text: assigned,
          source: source!,
          setByLine: setBy,
          setByAssignmentId: setByAssignmentId,
        );
      }
    }
  }
  return out;
}

/// True when a station destination's tokens name a gazetteer entry. A
/// hyphenated station's `areaTokens` end with the joined duplicate
/// ("kotake-mukaihara" -> [kotake, mukaihara, kotakemukaihara]), so all
/// three spellings — split, space-joined, concatenated — are tried.
bool _destinationInGazetteer(
  List<String> dws,
  bool Function(String normalizedName) contains,
) {
  final filtered = [
    for (final w in dws)
      if (!genericStopWords.contains(w)) w,
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

/// A known area the stop line names about itself, or null — known meaning the
/// gazetteer where there is one and the plan's own anchor vocabulary where
/// there is not. A candidate only counts in a position where it reads as a
/// locality — after a venue/meal/furniture word, standing alone, as a
/// `Name -` prefix, or already in [trustedSelfAreas], which is plan-wide and
/// accumulates across both assignment passes — and the line must name exactly
/// one distinct area: two candidates, or none, is designed silence, never a
/// pick.
final RegExp _segmentSplit = RegExp(r'[/,+&;]');

String? _gazetteerAreaInStop(
  String clean,
  Set<String> trustedSelfAreas,
  bool Function(List<String> normalizedWords) names,
  bool Function(String word) mayJoin,
  Map<String, List<String>> tokenCache,
) {
  final matches = <String, String>{};
  for (final segment in clean.split(_segmentSplit)) {
    final words = tokenCache.putIfAbsent(segment, () => areaTokens(segment));
    for (var start = 0; start < words.length; start++) {
      // `Hotel Courtland` names the hotel Courtland. Lodging is the one venue
      // word English (and a Japan plan's English) puts *before* the
      // establishment's own name, which is why `hotelPrefixRegExp` reads the
      // locality on the other side of it; a word after it is a name, never a
      // district, and `Courtland` is written five times in one plan and
      // capitalised every time, so the anchor vocabulary cannot tell on its
      // own.
      final afterLodging = start > 0 && lodgingWords.contains(words[start - 1]);
      final precededByDescriptor = start > 0 &&
          !afterLodging &&
          (venueGenericWords.contains(words[start - 1]) ||
              mealPrefixWords.contains(words[start - 1]) ||
              furnitureWords.contains(words[start - 1]));
      for (var end = start; end < words.length && end < start + 5; end++) {
        // A word the evidence has never heard of cannot appear inside a name
        // the evidence knows, so no longer window from this start can work
        // either. Without the anchor vocabulary to say so this was five
        // windows built and discarded per word of every line of the plan,
        // twice over, and it is what the parse budget actually measures.
        if (!mayJoin(words[end])) break;
        if (venueGenericWords.contains(words[end]) ||
            furnitureWords.contains(words[end])) {
          continue;
        }
        final candidateWords = words.sublist(start, end + 1);
        // The order of the tests below is the parse budget. This runs over
        // every window of every stop of a plan, twice, and doc 02 alone is
        // 855 stops: asking whether the words name anything at all rejects
        // almost every window for a handful of set lookups, where building
        // the joined strings first cost eleven seconds against a budget of
        // two. `areaWords` and `joinedAreaWords` are said inline for the
        // same reason -- these words are already `areaTokens` output, so
        // running the tokenizer over them again buys nothing.
        if (!names(candidateWords)) continue;
        var contentWords = 0;
        final buffer = StringBuffer();
        for (final w in candidateWords) {
          if (genericStopWords.contains(w) || venueGenericWords.contains(w)) {
            continue;
          }
          buffer.write(w);
          if (w.length >= 2) contentWords++;
        }
        if (contentWords == 0) continue;
        final joined = buffer.toString();
        final isStandalone = start == 0 && end == words.length - 1;
        if (!precededByDescriptor &&
            !isStandalone &&
            !trustedSelfAreas.contains(joined)) {
          final candidate = candidateWords.join(' ');
          final isHyphenatedSuffix = RegExp(
            r'(^|\s)' +
                RegExp.escape(candidate) +
                r'\s*[-\u2013\u2014](?:\s|$)',
            caseSensitive: false,
          ).hasMatch(segment);
          if (!isHyphenatedSuffix) continue;
        }
        matches[joined] = candidateWords.join(' ');
      }
    }
  }
  if (matches.length != 1) return null;
  return matches.values.single;
}

String? _seedForDay(
  String? place,
  Set<String> vocab,
  Set<String>? gazetteer,
  AreaGazetteer? gazObj,
) {
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
  // A run through the anchor vocabulary is an inference about the heading,
  // and an inference has to survive the same question the tap rule asks of a
  // stop: does this text name a place at all? `## Day 4: Local Gems` runs
  // `local` -- a word the corroboration pass admits because the plan writes
  // it twice and capitalises it once -- and then sends four stops to a
  // search for `local`. The gazetteer already refused it, which is the same
  // refusal one measurement later; this is the phase-1 half of it, so a plan
  // read without a gazetteer is not the only one that pays.
  if (namesNoPlace(cands.first)) return null;
  if (hasGaz() && !contains(areaTokens(cands.first).join(' '))) {
    return null;
  }
  return cands.first;
}
