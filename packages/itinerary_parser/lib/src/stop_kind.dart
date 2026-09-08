/// Stop kind classification and placeText extraction.
///
/// Mirrors plan §6.1.
library;

import 'area_words.dart';
import 'area_annotations.dart';
import 'line_classifier.dart';
import 'models.dart';

class ClassifiedStop {
  final StopKind kind;
  final String? placeText;
  final List<String> places;
  const ClassifiedStop(
      {required this.kind, this.placeText, required this.places});
}

/// Classifies a stop and extracts its sendable placeText.
///
/// [isAreaHeading] — whether the assignment engine marked this line as a
/// marker (running area setter). [hasTime] — whether the line had a time.
/// [raw] — original line text.
ClassifiedStop classifyStop({
  required String raw,
  required bool isAreaHeading,
  required bool hasTime,
}) {
  final cleanResult = cleanStopText(raw);
  final clean = cleanResult.clean;
  final ws = areaTokens(clean);

  // A bare section label is structure even if the area engine happened to
  // read its title-like shape as a running heading. Keep it in the stop list,
  // but never offer it as a place query.
  if (isSectionLabelText(clean)) {
    return const ClassifiedStop(
        kind: StopKind.sectionLabel, placeText: null, places: []);
  }

  // areaHeading is decided by the assignment engine.
  if (isAreaHeading) {
    return const ClassifiedStop(
        kind: StopKind.areaHeading, placeText: null, places: []);
  }

  // A meal word with a payload is a labelled place. Bare `Food` was handled
  // as a section label above.
  if (ws.isNotEmpty && mealPrefixWords.contains(ws.first)) {
    // Extract payload after label separator : or -
    final payload = _mealPayload(raw, clean);
    if (payload == null || payload.trim().isEmpty) {
      return const ClassifiedStop(
          kind: StopKind.mealLabel, placeText: null, places: []);
    }
    // Check if payload is just TBD/nothing
    final payloadTokens = areaTokens(payload);
    if (payloadTokens.isEmpty ||
        (payloadTokens.length == 1 &&
            {'tbd', 'tba', 'none', 'n/a'}.contains(payloadTokens.first))) {
      return const ClassifiedStop(
          kind: StopKind.mealLabel, placeText: null, places: []);
    }
    final places = placesOnLinePayload(payload);
    return ClassifiedStop(
        kind: StopKind.mealLabel, placeText: payload.trim(), places: places);
  }

  // Commentary, fare deliberation and other non-place planning prose stays
  // visible as a note rather than falling through to the place default.
  if (_isPlanningNote(raw, clean) ||
      (!_hasCategoryAnnotation(cleanResult) && _isNote(raw, clean, ws))) {
    return const ClassifiedStop(
        kind: StopKind.note, placeText: null, places: []);
  }

  // Conditional branches are real plan content, but not committed stops.
  if (_isAlternative(clean)) {
    final places = _alternativePlaces(raw, clean);
    return ClassifiedStop(
      kind: StopKind.alternative,
      placeText: places.isEmpty ? null : places.join('; '),
      places: places,
    );
  }

  // `Return to X from Y` describes one intended destination even though it
  // mentions its origin too. Decide this before the general multi-place pass.
  final instructionPlace = _instructionPlace(clean);
  if (_startsWithReturnInstruction(clean) && instructionPlace != null) {
    return ClassifiedStop(
      kind: StopKind.placeInstruction,
      placeText: instructionPlace,
      places: [instructionPlace],
    );
  }

  final multiPlaces = _travelPlaceExpressions(cleanResult);
  if (multiPlaces.length > 1) {
    return ClassifiedStop(
      kind: StopKind.multiPlace,
      placeText: multiPlaces.join('; '),
      places: multiPlaces,
    );
  }

  if (instructionPlace != null) {
    return ClassifiedStop(
      kind: StopKind.placeInstruction,
      placeText: instructionPlace,
      places: [instructionPlace],
    );
  }

  // Ordinary place: strip bullet/time/annotation but keep the venue words.
  final placeText = _extractPlaceText(raw, clean);
  if (placeText == null || placeText.trim().isEmpty) {
    return const ClassifiedStop(
        kind: StopKind.note, placeText: null, places: []);
  }
  final places = placesOnLinePayload(placeText);
  return ClassifiedStop(
      kind: StopKind.place, placeText: placeText, places: places);
}

bool _isPlanningNote(String raw, String clean) {
  final lower = clean.toLowerCase();
  if (RegExp(r'^short day due to\b').hasMatch(lower) ||
      RegExp(r'^most likely going to cut\b').hasMatch(lower) ||
      RegExp(r'^on the way back for snacks\??$').hasMatch(lower)) {
    return true;
  }

  // The Rome corpus has a whole sentence comparing flexible return fares.
  // Brand names in that sentence do not turn the pricing deliberation into a
  // place. Requiring both fare vocabulary and deliberation keeps this narrow.
  final hasFare =
      RegExp(r'\b(?:fare|price|priced|expensive)\b', caseSensitive: false)
          .hasMatch(raw);
  final deliberates = RegExp(
          r'\b(?:allow|flexib|time changes?|trip options?|book a return)\b',
          caseSensitive: false)
      .hasMatch(raw);
  return hasFare && deliberates;
}

bool _isAlternative(String clean) {
  final lower = clean.toLowerCase();
  return RegExp(r'^(?:if\b|perhaps\b|maybe\b|consider\b|alternatively\b)')
          .hasMatch(lower) ||
      RegExp(r'\bperhaps\b').hasMatch(lower) ||
      RegExp(r'\bon the way back for snacks\?\s*$').hasMatch(lower);
}

List<String> _alternativePlaces(String raw, String clean) {
  final out = <String>[];

  void addMatch(RegExp pattern, String text) {
    for (final match in pattern.allMatches(text)) {
      final candidate = _cleanExpression(match.group(1));
      if (candidate != null) out.add(candidate);
    }
  }

  addMatch(
    RegExp(r'\blove\s+(.+?)(?=\s+and\s+(?:weather|time)\b|[?.]|$)',
        caseSensitive: false),
    clean,
  );
  addMatch(
    RegExp(r'\bperhaps\s+(.+?)(?=\s+or\b|[?.]|$)', caseSensitive: false),
    clean,
  );
  addMatch(
    RegExp(r'\bor\s+(?:the\s+)?(.+?)(?=[?.]|$)', caseSensitive: false),
    clean,
  );
  addMatch(
    RegExp(r'^consider\s+(.+?)(?=\s+for\b|[?.]|$)', caseSensitive: false),
    clean,
  );
  addMatch(
    RegExp(
      r'^(?:maybe|perhaps)\s+(?:(?:catch|visit|see|go\s+to|stop\s+at)\s+)?(.+?)(?=\s+at\s+(?:night|morning|midday|noon|evening)\b|[?.]|$)',
      caseSensitive: false,
    ),
    clean,
  );
  addMatch(
    RegExp(r'^(.+?)\s+on the way back for snacks\?\s*$', caseSensitive: false),
    raw.trim(),
  );
  return _uniqueExpressions(out);
}

bool _startsWithReturnInstruction(String clean) =>
    RegExp(r'^return\s+(?:back\s+)?to\b', caseSensitive: false).hasMatch(clean);

String? _instructionPlace(String clean) {
  final patterns = [
    RegExp(
      r'^check\s+in\s+at\s+(.+?)(?=\s+at\s+\d{1,2}(?::|\.)\d{2}|[.]?$)',
      caseSensitive: false,
    ),
    RegExp(
      r'^return\s+(?:back\s+)?to\s+(.+?)(?=\s+from\b|\s+at\s+\d|\s+arriv\w*\b|[.]?$)',
      caseSensitive: false,
    ),
    RegExp(
      r'^(?:fly|flight|travel|train|take\s+(?:a\s+)?train|day\s+trip)\s+(?:back\s+)?to\s+(.+?)(?=\s+(?:arriv\w*|depart\w*)\b|[,.;]|$)',
      caseSensitive: false,
    ),
    RegExp(
      r'\bto\s+(.+?)(?=\s+(?:arriv\w*|depart\w*)\b|[,.;]|$)',
      caseSensitive: false,
    ),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(clean);
    final candidate = _cleanExpression(match?.group(1));
    if (candidate != null) return candidate;
  }
  return null;
}

List<String> _travelPlaceExpressions(CleanStopResult cleanResult) {
  final out = <String>[];
  for (final clause in cleanResult.clean.split(RegExp(r'[,.;]'))) {
    final match = RegExp(
      r'\b(?:to|in|from)\s+(.+?)(?=\s+(?:arriv\w*|depart\w*|and\s+back|then\b)|$)',
      caseSensitive: false,
    ).firstMatch(clause);
    final candidate = _cleanExpression(match?.group(1));
    if (candidate != null) out.add(candidate);
  }

  for (final parenthetical in cleanResult.parens) {
    if (_looksLikePlaceParenthetical(parenthetical)) {
      final candidate = _cleanExpression(parenthetical);
      if (candidate != null) out.add(candidate);
    }
  }
  return _uniqueExpressions(out);
}

bool _looksLikePlaceParenthetical(String text) {
  final words = areaTokens(text);
  if (words.isEmpty || words.length > 4) return false;
  if (words.every(_categoryWords.contains)) return false;
  return RegExp(r'^\p{Lu}', unicode: true).hasMatch(text.trim());
}

const _categoryWords = {
  'archery',
  'bar',
  'brunch',
  'burger',
  'cabaret',
  'cafe',
  'climbing',
  'coffee',
  'cookie',
  'market',
  'massage',
  'museum',
  'park',
  'shopping',
  'snacks',
  'thai',
  'viet',
};

bool _hasCategoryAnnotation(CleanStopResult result) => result.parens.any(
      (text) {
        final words = areaTokens(text);
        return words.isNotEmpty && words.every(_categoryWords.contains);
      },
    );

String? _cleanExpression(String? value) {
  if (value == null) return null;
  var clean = value.trim();
  clean = clean.replaceAll(
      RegExp(
          r'\s+(?:at\s+\d{1,2}(?::|\.)\d{2}.*|arriv\w*\s+.*|\d{1,2}(?::|\.)\d{2}\s*(?:am|pm)?)$',
          caseSensitive: false),
      '');
  clean = clean.replaceAll(RegExp(r'^[\s,:;.!?\-–—]+|[\s,:;.!?\-–—]+$'), '');
  return clean.isEmpty ? null : clean;
}

List<String> _uniqueExpressions(Iterable<String> values) {
  final seen = <String>{};
  return [
    for (final value in values)
      if (seen.add(value.toLowerCase())) value,
  ];
}

String? _mealPayload(String raw, String clean) {
  // Find the meal prefix in raw, then take everything after : or -
  final m = RegExp(
    r'^\s*(?:[-*•–—]+|\d+[.)]|\d+\s+)?\s*(?:breakfast|lunch|dinner|brunch|supper|snack|snacks|dessert|desert|coffee|drinks|drink|cafe|food)\b\s*[:\-–—]?\s*',
    caseSensitive: false,
  ).firstMatch(raw);
  if (m == null) return clean;
  var payload = raw.substring(m.end).trim();
  // Strip leading separators
  payload = payload.replaceAll(RegExp(r'^[:\-–—\s]+'), '').trim();
  if (payload.isEmpty) return null;
  // Clean the payload: remove parenthetical annotations but keep venue
  // We keep it simple: strip annotations handled by placeText extraction
  return payload;
}

bool _isNote(String raw, String clean, List<String> ws) {
  if (clean.isEmpty) return true;
  // Bare time/duration line
  if (RegExp(r'^\s*\d{1,2}[:.]\d{2}\s*(?:am|pm)?\s*$', caseSensitive: false)
          .hasMatch(clean) ||
      RegExp(r'^\s*\d+\s*(?:min|mins|minute|minutes|hr|hrs|hour|hours)\s*$',
              caseSensitive: false)
          .hasMatch(clean)) {
    return true;
  }
  // All-furniture check (using clean text)
  final content = [
    for (final w in ws)
      if (!genericStopWords.contains(w)) w
  ];
  if (content.isNotEmpty &&
      content.every(
          (w) => furnitureWords.contains(w) || venueGenericWords.contains(w))) {
    return true;
  }
  // Wi-Fi / amenities blob without vocab word
  if (RegExp(r'wifi|wi-fi|amenit|check-in|check-out', caseSensitive: false)
      .hasMatch(raw)) {
    // If no vocab word in the line, it's junk
    // We can't check vocab here without passing it; use heuristic: if it
    // contains a venue word that's not furniture, keep it
    // For now: Wi-Fi lines are notes unless they also contain a place-like word
    // Simple: if raw has wifi and is longer than 30 chars with no obvious venue, mark note
    final hasVenue = venueGenericWords.any(
        (v) => RegExp(r'\b' + v + r'\b', caseSensitive: false).hasMatch(raw));
    if (!hasVenue || clean.length > 40) {
      // Check if it's a pure amenities blob
      if (RegExp(r'wifi|password|amenit', caseSensitive: false)
          .hasMatch(clean)) {
        return true;
      }
    }
  }
  // URL remnant / folio line
  if (RegExp(r'^\d{1,3}/\d{1,3}$').hasMatch(clean.trim())) {
    return true;
  }
  return false;
}

String? _extractPlaceText(String raw, String clean) {
  // clean already has bullet/time stripped. Now strip annotations:
  // Remove parenthetical content and inline "near X" etc — but keep the
  // venue name. Simplest: use clean as placeText (annotations already
  // extracted separately for area). This keeps venue words.
  // For multi-place rows, splitting is done separately.
  if (clean.trim().isEmpty) return null;
  return clean.trim();
}

/// Splits a placeText into individual places. Mirrors scorer's run-breaking
/// punctuation: / , + & ;
List<String> placesOnLinePayload(String placeText) {
  final parts = placeText
      .split(RegExp(r'[/,+&;]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  // Strip parenthetical annotations from each
  final cleaned = <String>[];
  for (final p in parts) {
    var c = p.replaceAll(RegExp(r'\([^)]*\)'), '').trim();
    c = c.replaceAll(RegExp(r'\s+'), ' ').trim();
    // Strip leading/trailing separators
    c = c.replaceAll(RegExp(r'^[:\-–—\s]+|[:\-–—\s]+$'), '').trim();
    if (c.isNotEmpty) cleaned.add(c);
  }
  if (cleaned.isEmpty) return [placeText.trim()];
  return cleaned;
}

/// Public: individual places on a stop line.
List<String> placesOnLineForRaw(String raw) {
  final clean = cleanStopText(raw).clean;
  if (clean.isEmpty) return [];
  return placesOnLinePayload(clean);
}
