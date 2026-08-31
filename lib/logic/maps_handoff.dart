/// Maps handoff composer: one query, three keyless URLs.
///
/// Priority (§3.3): travellerDeclared/travellerProximity/inlineLocality
/// > person > running > nothing. The composer just joins searchText + area;
/// priority is already decided by the parser/store.
library;

enum MapsApp { google, apple, waze }

Uri mapsSearchUri(MapsApp app, String query) {
  final encoded = Uri.encodeComponent(query);
  switch (app) {
    case MapsApp.google:
      return Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded');
    case MapsApp.apple:
      return Uri.parse('https://maps.apple.com/?q=$encoded');
    case MapsApp.waze:
      return Uri.parse('https://waze.com/ul?q=$encoded');
  }
}

/// The one composition rule. Returns null for inert row.
String? mapsQueryFor({required String? searchText, required String? area}) {
  if (searchText == null || searchText.trim().isEmpty) return null;
  if (area == null || area.trim().isEmpty) return searchText.trim();
  return '${searchText.trim()}, ${area.trim()}';
}
