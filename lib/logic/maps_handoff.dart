// LOGIC band (docs/architecture.md): pure decision cores — no Flutter/Riverpod/IO.
// The Maps handoff: which lines are places, and which search they open.
// See plan report §4 and screens.html.

const _maxQueryLen = 200;

enum MapsApp { googleMaps, appleMaps, waze }

enum StopLineKind { place, inert }

class ClassifiedStop {
  final StopLineKind kind;
  final String? mealLabel;
  final String query;
  final List<String> places;

  const ClassifiedStop({
    required this.kind,
    this.mealLabel,
    required this.query,
    required this.places,
  });
}

/// Regex lifted for cross-test pinning: traveller's `(near X)` / `(X area)` / `@ X`.
/// The parser package's extractor duplicates this; a cross-test keeps them honest.
final RegExp travellerAreaPattern = RegExp(
  r'(?:\(\s*near\s+(.+?)\s*\)|\(\s*(.+?)\s+area\s*\)|\@\s*(.+?))\s*$',
  caseSensitive: false,
);

String? extractTravellerArea(String text) {
  final m = travellerAreaPattern.firstMatch(text.trim());
  if (m == null) return null;
  for (var i = 1; i <= 3; i++) {
    final g = m.group(i);
    if (g != null && g.trim().isNotEmpty) return g.trim();
  }
  return null;
}

String stripTravellerArea(String text) {
  final m = travellerAreaPattern.firstMatch(text.trim());
  if (m == null) return text.trim();
  // Remove the matched suffix.
  final start = m.start;
  return text.substring(0, start).trim();
}

const _mealLabels = ['lunch', 'dinner', 'breakfast', 'brunch', 'supper'];

({String? mealLabel, String remainder}) _stripMealLabel(String text) {
  final trimmed = text.trimLeft();
  for (final label in _mealLabels) {
    if (trimmed.length >= label.length &&
        trimmed.substring(0, label.length).toLowerCase() == label) {
      final after = trimmed.substring(label.length).trimLeft();
      if (after.isEmpty) {
        return (mealLabel: _capitalize(label), remainder: '');
      }
      if (after.startsWith(':') || after.startsWith('-')) {
        return (
          mealLabel: _capitalize(label),
          remainder: after.substring(1).trimLeft(),
        );
      }
      // Bare meal label followed by nothing? handled above.
    }
  }
  return (mealLabel: null, remainder: text.trim());
}

String _capitalize(String s) => s[0].toUpperCase() + s.substring(1).toLowerCase();

// Inert detection
bool _isInertRemainder(String r) {
  if (r.trim().isEmpty) return true;
  final low = r.trim().toLowerCase();
  if (low == 'tbd' || low == 'tbc' || low == 'free time' || low == 'rest') {
    return true;
  }
  // Bare URL
  if (RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(r.trim())) {
    return true;
  }
  // No letters (incl CJK). If no letter/digit CJK, inert.
  // Check if contains any letter (A-Z) or CJK (U+4E00-9FFF, Hiragana, Katakana, Hangul)
  final hasLetter = RegExp(r'[A-Za-z\u4E00-\u9FFF\u3040-\u309F\u30A0-\u30FF\uAC00-\uD7AF]').hasMatch(r);
  if (!hasLetter) return true;
  // Wi-Fi / booking reference shapes — conservative fence
  final wifiPattern = RegExp(
    r'wi[\s-]*fi|password|pass\s*\d|booking\s*ref',
    caseSensitive: false,
  );
  // Only inert if line is short and looks like amenity blob? Use heuristic:
  // If contains wifi/password and no strong place signal, treat as inert.
  // Plan says "Wi-Fi blobs" are inert. Use broader: if contains wi-fi/password, inert.
  if (wifiPattern.hasMatch(r)) return true;
  return false;
}

List<String> _splitPlaces(String query) {
  // Split on 、 , / · & and " and " only when conditions hold.
  // Conditions: >=2 segments, each <=6 words, none purely numeric.
  final pattern = RegExp(r'\s*[、,/\·&]\s*|\s+and\s+', caseSensitive: false);
  // Quick check: does split yield >=2?
  final raw = query.split(pattern);
  if (raw.length < 2) return [query];
  // Filter out segments that empty after trim
  final segments = [for (final s in raw) s.trim()].where((s) => s.isNotEmpty).toList();
  if (segments.length < 2) return [query];
  for (final seg in segments) {
    final words = seg.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length > 6) return [query];
    if (words.isEmpty) return [query];
    // Purely numeric segment?
    if (RegExp(r'^\d+$').hasMatch(seg)) return [query];
  }
  // Guard for " and " splits: both sides must start with capital or CJK
  // If split was on " and ", require both sides start with capital or CJK.
  // We check if query contains " and " and any segment starts lowercase -> no split.
  if (RegExp(r'\s+and\s+', caseSensitive: false).hasMatch(query)) {
    for (final seg in segments) {
      final first = seg.trim().characters.isEmpty ? '' : seg.trim()[0];
      if (first.isEmpty) return [query];
      final isCapOrCjk = RegExp(r'[A-Z\u4E00-\u9FFF\u3040-\u309F\u30A0-\u30FF\uAC00-\uD7AF]').hasMatch(first);
      if (!isCapOrCjk) return [query];
    }
  }
  return segments;
}

extension _Chars on String {
  Iterable<String> get characters => split('');
}

ClassifiedStop classifyStopLine(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) {
    return const ClassifiedStop(kind: StopLineKind.inert, query: '', places: []);
  }

  // Extract meal label
  final meal = _stripMealLabel(trimmed);
  final mealLabel = meal.mealLabel;
  var remainder = meal.remainder;

  // Extract traveller area off remainder (so query doesn't include it)
  var travellerArea = extractTravellerArea(remainder);
  if (travellerArea != null) {
    remainder = stripTravellerArea(remainder);
  }

  // After stripping, check inert
  if (_isInertRemainder(remainder)) {
    // If meal label existed but remainder inert, whole row inert
    // But still keep mealLabel for rendering
    return ClassifiedStop(
      kind: StopLineKind.inert,
      mealLabel: mealLabel,
      query: remainder,
      places: [],
    );
  }

  // Remainder is place query
  final query = remainder.trim();
  if (query.isEmpty) {
    return ClassifiedStop(kind: StopLineKind.inert, mealLabel: mealLabel, query: '', places: []);
  }
  final places = _splitPlaces(query);
  return ClassifiedStop(
    kind: StopLineKind.place,
    mealLabel: mealLabel,
    query: _capQuery(query),
    places: places.map(_capQuery).toList(),
  );
}

String _capQuery(String q) {
  final trimmed = q.trim();
  if (trimmed.length > _maxQueryLen) return trimmed.substring(0, _maxQueryLen).trim();
  return trimmed;
}

// ----- URL composition -----

Uri? mapsSearchUri({
  required ClassifiedStop stop,
  String? area,
  MapsApp app = MapsApp.googleMaps,
}) {
  if (stop.kind == StopLineKind.inert) return null;
  final rawQuery = stop.query.trim();
  if (rawQuery.isEmpty) return null;
  final effectiveArea = area?.trim();
  final query = (effectiveArea != null && effectiveArea.isNotEmpty) ? '$rawQuery, $effectiveArea' : rawQuery;
  final capped = query.length > _maxQueryLen ? query.substring(0, _maxQueryLen).trim() : query;
  return _buildUri(capped, app);
}

Uri areaSearchUri({required String area, MapsApp app = MapsApp.googleMaps}) {
  final capped = area.trim().length > _maxQueryLen ? area.trim().substring(0, _maxQueryLen) : area.trim();
  return _buildUri(capped, app);
}

Uri placeSearchUri({required String place, String? area, MapsApp app = MapsApp.googleMaps}) {
  final p = place.trim();
  final a = area?.trim();
  final q = (a != null && a.isNotEmpty) ? '$p, $a' : p;
  final capped = q.length > _maxQueryLen ? q.substring(0, _maxQueryLen).trim() : q;
  return _buildUri(capped, app);
}

Uri _buildUri(String query, MapsApp app) {
  switch (app) {
    case MapsApp.googleMaps:
      return Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': query});
    case MapsApp.appleMaps:
      return Uri.https('maps.apple.com', '/', {'q': query});
    case MapsApp.waze:
      return Uri.https('waze.com', '/ul', {'q': query});
  }
}

// Length-based truncation helper for multi-place row display.
// Returns true when should truncate + show badge.
bool shouldTruncateMultiPlace(String text, {int threshold = 48}) {
  return text.length > threshold;
}

int placeCount(ClassifiedStop stop) => stop.places.length;
