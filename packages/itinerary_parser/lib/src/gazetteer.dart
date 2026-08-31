/// Gazetteer interface for C10 validator (phase 2).
///
/// Phase 1: parser is called with `gazetteer: null` (C7t behaviour).
library;

abstract interface class AreaGazetteer {
  bool contains(String normalizedName);
}

class SortedListAreaGazetteer implements AreaGazetteer {
  final List<String> _sorted;
  SortedListAreaGazetteer(List<String> sortedNormalizedNames)
      : _sorted = List.unmodifiable(sortedNormalizedNames);

  @override
  bool contains(String normalizedName) {
    var lo = 0;
    var hi = _sorted.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final cmp = _sorted[mid].compareTo(normalizedName);
      if (cmp == 0) return true;
      if (cmp < 0) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return false;
  }
}
