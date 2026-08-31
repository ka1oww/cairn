/// Stop kind classification and placeText extraction.
///
/// Mirrors plan §6.1.
library;

import 'area_words.dart';
import 'area_annotations.dart';
import 'models.dart';

class ClassifiedStop {
  final StopKind kind;
  final String? placeText;
  final List<String> places;
  const ClassifiedStop({required this.kind, this.placeText, required this.places});
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
  // 1. areaHeading — decided by engine
  if (isAreaHeading) {
    return const ClassifiedStop(kind: StopKind.areaHeading, placeText: null, places: []);
  }

  final cleanResult = cleanStopText(raw);
  final clean = cleanResult.clean;
  final ws = areaTokens(clean);

  // 2. mealLabel
  if (ws.isNotEmpty && mealPrefixWords.contains(ws.first)) {
    // Extract payload after label separator : or -
    final payload = _mealPayload(raw, clean);
    if (payload == null || payload.trim().isEmpty) {
      return const ClassifiedStop(kind: StopKind.mealLabel, placeText: null, places: []);
    }
    // Check if payload is just TBD/nothing
    final payloadTokens = areaTokens(payload);
    if (payloadTokens.isEmpty ||
        (payloadTokens.length == 1 && {'tbd', 'tba', 'none', 'n/a'}.contains(payloadTokens.first))) {
      return const ClassifiedStop(kind: StopKind.mealLabel, placeText: null, places: []);
    }
    final places = placesOnLinePayload(payload);
    return ClassifiedStop(kind: StopKind.mealLabel, placeText: payload.trim(), places: places);
  }

  // 3. note — furniture-only, Wi-Fi blob, bare time/duration
  if (_isNote(raw, clean, ws)) {
    return const ClassifiedStop(kind: StopKind.note, placeText: null, places: []);
  }

  // 4. place
  // placeText: strip bullet/time/annotation but keep the venue words
  final placeText = _extractPlaceText(raw, clean);
  if (placeText == null || placeText.trim().isEmpty) {
    return const ClassifiedStop(kind: StopKind.note, placeText: null, places: []);
  }
  final places = placesOnLinePayload(placeText);
  return ClassifiedStop(kind: StopKind.place, placeText: placeText, places: places);
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
  if (RegExp(r'^\s*\d{1,2}[:.]\d{2}\s*(?:am|pm)?\s*$', caseSensitive: false).hasMatch(clean) ||
      RegExp(r'^\s*\d+\s*(?:min|mins|minute|minutes|hr|hrs|hour|hours)\s*$', caseSensitive: false).hasMatch(clean)) {
    return true;
  }
  // All-furniture check (using clean text)
  final content = [for (final w in ws) if (!genericStopWords.contains(w)) w];
  if (content.isNotEmpty &&
      content.every((w) => furnitureWords.contains(w) || venueGenericWords.contains(w))) {
    return true;
  }
  // Wi-Fi / amenities blob without vocab word
  if (RegExp(r'wifi|wi-fi|amenit|check-in|check-out', caseSensitive: false).hasMatch(raw)) {
    // If no vocab word in the line, it's junk
    // We can't check vocab here without passing it; use heuristic: if it
    // contains a venue word that's not furniture, keep it
    // For now: Wi-Fi lines are notes unless they also contain a place-like word
    // Simple: if raw has wifi and is longer than 30 chars with no obvious venue, mark note
    final hasVenue = venueGenericWords.any((v) => RegExp(r'\b' + v + r'\b', caseSensitive: false).hasMatch(raw));
    if (!hasVenue || clean.length > 40) {
      // Check if it's a pure amenities blob
      if (RegExp(r'wifi|password|amenit', caseSensitive: false).hasMatch(clean)) {
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
  final parts = placeText.split(RegExp(r'[/,+&;]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
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
