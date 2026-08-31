// LOGIC band (docs/architecture.md): pure decision cores — no Flutter, no
// Riverpod, no IO.
//
// The Maps handoff: what a tapped line searches for, and the one keyless URL
// that search opens. Everything here is a function of a stop's *stored* words
// and its *stored* area; nothing re-decides what a line is. `StopKind` and the
// area are settled by `itinerary_parser` at the paste and carried
// (`cairn_model.Stop`), because two classifiers drift.
//
// Three rules the composer will not break:
//   1. The handoff is always a text search. No stored pin, no coordinates, no
//      place id — the app has never looked a place up and must not pretend to.
//   2. An area is appended only when there is one. A miss sends the stop's own
//      words alone rather than a guessed neighbourhood (rule 3 of the plan).
//   3. A meal label is shown and never sent: `Lunch: Ichiran` searches for
//      `Ichiran`, because "Lunch" is not part of any restaurant's name.
library;

/// The maps app a search opens in. All three are keyless https links, so
/// nothing here needs an API key, a project or a billing account.
enum MapsApp { google, apple, waze }

/// Longest query any of the three apps is handed. Well past the longest real
/// stop line; the cap exists so a pathological paste cannot build a URL no
/// app will accept.
const int maxQueryLength = 200;

/// Above this many characters a multi-place row is drawn truncated with an
/// "N places" badge instead of in full. Length decides, never place count:
/// `Ueno Park and the museums` is two places and reads fine as written.
const int multiPlaceTruncationThreshold = 48;

/// The one composition rule: the stop's sendable words, then the area.
///
/// Returns null when there is nothing to search for — an inert line, or a
/// meal label with no restaurant on it.
String? mapsQueryFor({required String? searchText, required String? area}) {
  final text = searchText?.trim();
  if (text == null || text.isEmpty) return null;
  final where = area?.trim();
  final query = (where == null || where.isEmpty) ? text : '$text, $where';
  return _cap(query);
}

/// The keyless universal link for [query] in [app].
Uri mapsSearchUri(MapsApp app, String query) {
  final capped = _cap(query);
  switch (app) {
    case MapsApp.google:
      return Uri.https('www.google.com', '/maps/search/', {
        'api': '1',
        'query': capped,
      });
    case MapsApp.apple:
      return Uri.https('maps.apple.com', '/', {'q': capped});
    case MapsApp.waze:
      return Uri.https('waze.com', '/ul', {'q': capped});
  }
}

String _cap(String query) {
  final trimmed = query.trim();
  return trimmed.length <= maxQueryLength
      ? trimmed
      : trimmed.substring(0, maxQueryLength).trim();
}

/// The label a meal line shows, and the words after it.
///
/// `Lunch: Ichiran` is `(label: 'Lunch', rest: 'Ichiran')`; a bare `Lunch`
/// has no rest at all. The split is deliberately narrow — a leading meal word
/// followed by `:` or `-` — because the parser has already decided this line
/// *is* a meal label, and all that is left is where the label stops.
({String? label, String? rest}) mealLabelSplit(String text) {
  final trimmed = text.trim();
  for (final word in _mealWords) {
    if (trimmed.length < word.length) continue;
    if (trimmed.substring(0, word.length).toLowerCase() != word) continue;
    final after = trimmed.substring(word.length).trimLeft();
    final label = trimmed.substring(0, word.length);
    if (after.isEmpty) return (label: label, rest: null);
    if (after.startsWith(':') ||
        after.startsWith('-') ||
        after.startsWith('—')) {
      final rest = after.substring(1).trim();
      return (label: label, rest: rest.isEmpty ? null : rest);
    }
    return (label: label, rest: after);
  }
  return (label: null, rest: trimmed.isEmpty ? null : trimmed);
}

const _mealWords = ['breakfast', 'brunch', 'lunch', 'dinner', 'supper'];

/// Whether a line stands in for a place nobody has chosen yet.
///
/// `Lunch: TBD` is a plan saying "we'll decide", and searching a maps app for
/// "TBD" helps nobody — so it renders and does nothing, exactly like the
/// traveller's own note. The parser reads these the same way; this is the
/// display side of the same short list.
bool isPlaceholderText(String text) => const {
  'tbd',
  'tba',
  'none',
  'n/a',
  '?',
}.contains(text.trim().toLowerCase());

/// The individual places on one line, in the order they were written.
///
/// A single-place line comes back as a one-element list, which is what makes
/// "is this multi-place?" a length check rather than a second parse. The
/// separators are the ones people actually type between place names; a
/// segment that is empty, purely numeric, or long enough to be prose stops
/// the split, because splitting prose invents places that are not there.
List<String> placesOn(String text) {
  final whole = text.trim();
  if (whole.isEmpty) return const [];
  final parts = whole
      .split(RegExp(r'\s*[、,/·+&;]\s*|\s+and\s+', caseSensitive: false))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.length < 2) return [whole];
  for (final part in parts) {
    if (RegExp(r'^\d+$').hasMatch(part)) return [whole];
    if (part.split(RegExp(r'\s+')).length > 6) return [whole];
  }
  return parts;
}

/// Whether a multi-place row is drawn truncated with an "N places" badge.
///
/// Length-based, per the captain's decision: a row that fits is drawn as
/// written whatever it lists, and the badge only ever appears on a row that
/// genuinely names more than one place.
bool showsPlaceCountBadge(String text, List<String> places) =>
    places.length > 1 && text.trim().length > multiPlaceTruncationThreshold;
