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

/// The candidates an add-area dialog offers, in the order both of them offer
/// them: [nearest] first — the silent run's own neighbouring areas, as
/// [nearestAreas] ordered them — then every area [planAreas] names that is
/// not already among them, in plan order, each named once. Nulls in
/// [planAreas] are stops the parser stayed silent on and carry nothing to
/// offer. Empty only when the plan names no area at all, and then the dialog
/// is the blank field it has always been.
///
/// One rule, two dialogs: the confirm screen's `+ Add an area` and the day
/// page's. Each passes its own draft or saved plan as [planAreas]; the
/// ordering itself is written once, here.
List<String> addAreaCandidates({
  required List<String> nearest,
  required Iterable<String?> planAreas,
}) {
  final ordered = List<String>.of(nearest);
  final seen = ordered.toSet();
  for (final area in planAreas) {
    if (area != null && seen.add(area)) ordered.add(area);
  }
  return ordered;
}
