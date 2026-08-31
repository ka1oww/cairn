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

  /// Builds one gazetteer from the decompressed text of one or more
  /// `tool/build_area_gazetteer.dart` assets: `#`-prefixed header lines are
  /// attribution, every other non-empty line is one already-normalised name.
  /// Each asset arrives sorted, but the union of several is not, so the
  /// names are deduped and re-sorted here; the package never touches the
  /// compressed bytes — inflating the asset is the caller's (the app's)
  /// business, which is what keeps this package dependency-free.
  factory SortedListAreaGazetteer.fromAssetTexts(Iterable<String> texts) {
    final names = <String>{};
    for (final text in texts) {
      for (final line in text.split('\n')) {
        if (line.isEmpty || line.startsWith('#')) continue;
        names.add(line);
      }
    }
    return SortedListAreaGazetteer(names.toList()..sort());
  }

  /// How many names this gazetteer holds (for logging a measured load).
  int get length => _sorted.length;

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
