// LOGIC band (docs/architecture.md): pure decision cores — no Flutter, no
// Riverpod, no IO.
//
// The one reading of what `itinerary_parser` says about a stop, said in the
// domain's words. It exists because two callers need it — the paste flow, and
// the re-paste merge — and a second copy of a vocabulary mapping is exactly
// the kind of thing that drifts.
library;

import 'package:cairn_model/cairn_model.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

/// What the parser decided a line is.
StopKind stopKindOf(ip.StopKind kind) => switch (kind) {
  ip.StopKind.place => StopKind.place,
  ip.StopKind.areaHeading => StopKind.areaHeading,
  ip.StopKind.mealLabel => StopKind.mealLabel,
  ip.StopKind.note => StopKind.note,
};

/// The tier an area's provenance belongs to.
///
/// The parser names seven provenances; the app keeps three, because what it
/// has to know is who may overwrite whom. The person's own words on the
/// pasted line — `(near Akihabara)`, `@ Shibuya`, a locality written into the
/// stop itself — are the traveller's, and outrank a correction made earlier.
/// Everything the extractor worked out by running a heading down a day is the
/// parser's, and anything may overwrite that.
AreaSource areaSourceOf(ip.AreaSource source) => switch (source) {
  ip.AreaSource.travellerDeclared ||
  ip.AreaSource.travellerProximity ||
  ip.AreaSource.inlineLocality => AreaSource.travellerOwn,
  ip.AreaSource.person => AreaSource.human,
  ip.AreaSource.runningHeading ||
  ip.AreaSource.hotelPrefix ||
  ip.AreaSource.trainDestination => AreaSource.parser,
};
