/// Deterministic, offline parser that turns pasted free-text trip plans
/// into structured days and stops.
///
/// Entry point: [parseItinerary]. See [ParseResult] for the shape it
/// returns and [Confidence] for what each confidence level means for the
/// UI built on top of this package.
library;

export 'src/models.dart';
export 'src/parser.dart' show parseItinerary, ItineraryParser;
