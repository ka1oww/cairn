// The app's acknowledgements: the third-party data Cairn ships inside the
// bundle and the licence each one is shipped under.
//
// This is a licence obligation, not a nicety. The area gazetteer assets
// under `assets/area_gazetteer/` are built from the GeoNames gazetteer,
// which is CC-BY 4.0: attribution has to reach the person using the app,
// not merely the person reading the repository. It is written twice on
// purpose and never a third time — once in each asset's own header (so the
// bytes carry their own provenance, wherever they end up) and once here (so
// the app says it out loud). `tool/build_area_gazetteer.dart` writes the
// first; `lib/screens/trip_sheet.dart` draws the second.
//
// Plain data, no Flutter: a screen renders it, nothing decides anything
// from it.
library;

/// One piece of third-party work the app ships.
class Acknowledgement {
  final String what;
  final String source;
  final String licence;

  const Acknowledgement({
    required this.what,
    required this.source,
    required this.licence,
  });

  /// The single line a surface draws.
  String get line => '$what — $source, $licence.';
}

const List<Acknowledgement> acknowledgements = [
  Acknowledgement(
    what: 'Place names used to check the areas read out of a plan',
    source: 'the GeoNames geographical database (geonames.org), modified',
    licence: 'CC BY 4.0',
  ),
];
