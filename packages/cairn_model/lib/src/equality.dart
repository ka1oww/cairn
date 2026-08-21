/// Element-by-element equality for the unmodifiable lists this package's value
/// types hold, so two equal trips built separately compare equal.
///
/// Written here rather than pulled from `package:collection` to keep this
/// package dependency-free, as the other three packages under `packages/` are.
bool listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Order-independent equality for the unmodifiable sets this package holds.
bool setEquals<T>(Set<T> a, Set<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  return a.containsAll(b);
}
