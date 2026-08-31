/// Pure re-derivation of running areas over an edited draft/day.
///
/// Renaming a heading re-flows downstream stops whose source is runningHeading
/// and which the person has not corrected.
library;

class AreaEditRow {
  final String id;
  final String kind; // 'areaHeading' | 'place' | ...
  final String? area;
  final String? source; // AreaSource.name | 'person'
  final bool corrected;
  const AreaEditRow({
    required this.id,
    required this.kind,
    this.area,
    this.source,
    this.corrected = false,
  });
}

/// Re-derives running areas for one day's ordered rows.
List<String?> rederiveRunningAreas(List<AreaEditRow> day) {
  String? running;
  final out = <String?>[];
  for (final row in day) {
    if (row.kind == 'areaHeading') {
      running = row.area;
      out.add(row.area);
    } else if (row.corrected ||
        (row.source != null &&
            row.source != 'runningHeading' &&
            row.source != 'hotelPrefix' &&
            row.source != 'trainDestination')) {
      out.add(row.area);
    } else {
      out.add(running);
    }
  }
  return out;
}
