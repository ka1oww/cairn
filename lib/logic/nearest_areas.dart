// LOGIC band (docs/architecture.md): pure decision core, no Flutter, no IO.

/// The nearest area either side of [index] in [areas], nearer first, with a
/// duplicate dropped.
///
/// One rule, two surfaces: the day page offers these as search hints
/// ("nearest to Shibuya") and the confirm screen's add-area fallback offers
/// the same two first among its candidates. The before side leads because it
/// is the area the run was walking in when the parser fell silent; the after
/// side follows; and when both sides name the same place it is offered once.
///
/// [areas] is a day's stops in plan order, each stop's own area or null.
/// An [index] outside the list answers with nothing.
List<String> nearestAreas(List<String?> areas, int index) {
  if (index < 0 || index >= areas.length) return const [];
  String? before;
  for (var i = index - 1; i >= 0; i--) {
    if (areas[i] != null) {
      before = areas[i];
      break;
    }
  }
  String? after;
  for (var i = index + 1; i < areas.length; i++) {
    if (areas[i] != null) {
      after = areas[i];
      break;
    }
  }
  return [?before, if (after != null && after != before) after];
}
