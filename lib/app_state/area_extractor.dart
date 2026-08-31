import 'package:itinerary_parser/itinerary_parser.dart' as ip;

class AreaAssignment {
  final String? area;
  final bool travellerOwn;
  const AreaAssignment({this.area, this.travellerOwn = false});
}

/// Stub seam per plan §3 — parser task replaces this with real implementation.
List<List<AreaAssignment>> assignRunningAreas(ip.ParseResult result) {
  return List.generate(result.days.length, (di) => List.generate(result.days[di].stops.length, (_) => const AreaAssignment()));
}
