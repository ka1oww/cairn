/// Deterministic, offline parser that turns pasted free-text trip plans
/// into structured days and stops.
///
/// Entry point: [parseItinerary]. See [ParseResult] for the shape it
/// returns and [Confidence] for what each confidence level means for the
/// UI built on top of this package.
library;

export 'src/area_words.dart';
export 'src/gazetteer.dart';
export 'src/line_classifier.dart' show stripBullet;
export 'src/models.dart';
export 'src/parser.dart' show parseItinerary, ItineraryParser;
