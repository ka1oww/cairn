// APP STATE band (docs/architecture.md): the Trail's whole brain.
//
// The Trail is the trip's front door — the cairn is the trip's *portrait*,
// not its door (design-calls §6). It draws one node per day of the plan,
// winding down the screen in itinerary order, with a flag on today.
//
// It derives from `savedItineraryProvider` and `todayProvider`, the same two
// sources the day page uses, and adds no read of its own: the Trail and
// Today must never be able to disagree about which day it is.
//
// Deliberately absent, because nothing in the app has them yet: photo counts,
// the past-with-photos node, the cat (parked — see
// docs/decisions/2026-08-22-cat-deferred.md), the long-trip chapters and the
// dot scrubber, and the trip title the design draws as the header's eyebrow
// (no trip row is stored, and this layer invents nothing).
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'date_labels.dart';
import 'day_view.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// View models — everything a screen may see, spoken in screen terms.
// ---------------------------------------------------------------------------

/// How one node is drawn.
///
/// **The drawn taxonomy has four states and this enum has three.** The
/// design's fourth is *past-with-photos* — the filled sticker print that is
/// the whole reward of the screen (surface 2a, "a filled day is the only
/// full-colour circle on the trail"). Photos do not exist anywhere in the app
/// yet, so that state is left out entirely rather than stubbed as empty
/// chrome, which is the principle the Today slice followed for the photo
/// timeline. [past] here is the design's *past-empty* node: an outline, never
/// a failure state.
enum TrailNodeState {
  /// The day is behind us.
  past,

  /// The day is today. Exactly one node at most is ever in this state, and
  /// it is the only one that wears the flag.
  today,

  /// The day has not happened yet — the dashed "not yet" mark. A day whose
  /// date is still open lands here too: it is not behind us and it is not
  /// today, and the node says so in words (its [dateLabel] is null) rather
  /// than by wearing a date nobody gave it.
  ahead,
}

/// One day of the plan, as the Trail draws it.
class TrailNode {
  /// 1-based, as the plan was pasted — the numeral inside the node, and the
  /// key the Trail opens the day page with.
  final int number;

  /// `Kyoto`, or null when the plan named no place. Drawn under the node the
  /// design labels: today, and day one before the trip starts.
  final String? place;

  /// `14 June`, or null when this day's date is still open.
  final String? dateLabel;

  /// `Mon` — drawn only under the pre-trip head (surface 2b: "day 1 alone
  /// wears a solid ring and its weekday").
  final String? weekdayLabel;

  final TrailNodeState state;

  /// The trip has not started and this is its first dated day. Surface 2b
  /// gives it a solid ring while every other node stays dashed — it is still
  /// [TrailNodeState.ahead]; this only changes how it is drawn.
  final bool isNextUp;

  const TrailNode({
    required this.number,
    this.place,
    this.dateLabel,
    this.weekdayLabel,
    required this.state,
    this.isNextUp = false,
  });

  bool get isToday => state == TrailNodeState.today;

  /// The day was accepted with its date still open. Such a day is unreachable
  /// by date and reachable only here, by its position on the path.
  bool get dateIsOpen => dateLabel == null;
}

/// The whole screen.
class TrailView {
  /// `Day 4 of 8`, `Starts Saturday`, `The trip is walked.`
  final String headline;

  /// `8 days planned`, or null where the headline says it all.
  final String? detail;

  /// One per day of the plan, in itinerary order.
  final List<TrailNode> nodes;

  const TrailView({required this.headline, this.detail, required this.nodes});
}

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

/// The Trail, or null while no plan is saved.
final trailViewProvider = Provider<AsyncValue<TrailView?>>((ref) {
  final today = ref.watch(todayProvider);
  return ref
      .watch(savedItineraryProvider)
      .whenData((plan) => trailViewFor(plan, today));
});

// ---------------------------------------------------------------------------
// The derivation, kept a pure function so it can be read in one sitting.
// ---------------------------------------------------------------------------

/// The Trail for [plan] with [today] deciding the flag and nothing else.
///
/// **One node per day of the plan, and no others.** A date the plan skips
/// gets a day page (`GapDay`) when you are standing in it, but no node: the
/// drawings number the path 1…n over the plan's own days and the header
/// counts the same n ("Day 4 of 8"). No surface ever drew a node for a date
/// the plan does not claim.
TrailView? trailViewFor(TripPlan? plan, DateTime today) {
  if (plan == null || plan.days.isEmpty) return null;

  final dayCount = plan.days.length;
  final daysWord = dayCount == 1 ? 'day' : 'days';
  final dated = [
    for (final day in plan.days)
      if (day.date != null) day,
  ];

  // Nothing was pinned to the calendar, so there is no today to flag and no
  // day is behind us. Every node is ahead and the header counts the plan.
  if (dated.isEmpty) {
    return TrailView(
      headline: '$dayCount $daysWord planned',
      nodes: [for (final day in plan.days) _node(day, today, nextUp: null)],
    );
  }

  final earliest = dated.reduce((a, b) => a.date!.isBefore(b.date!) ? a : b);
  final latest = dated.reduce((a, b) => a.date!.isAfter(b.date!) ? a : b);

  final beforeTheTrip = today.isBefore(earliest.date!);
  final nodes = [
    for (final day in plan.days)
      _node(day, today, nextUp: beforeTheTrip ? earliest.number : null),
  ];

  if (beforeTheTrip) {
    // Surface 2b: the header names the day it starts, not a countdown — the
    // countdown belongs to the day page (7c). The flag does not exist yet.
    return TrailView(
      headline: 'Starts ${weekdayName(earliest.date!.weekday)}',
      detail: '$dayCount $daysWord planned',
      nodes: nodes,
    );
  }

  if (today.isAfter(latest.date!)) {
    // No Trail header was ever drawn for a finished trip — the design's
    // post-trip surface is the shelf and the book, both after the first
    // release. So this borrows the day page's own words for the same fact.
    return TrailView(
      headline: 'The trip is walked.',
      detail: '$dayCount $daysWord, ending ${dayMonthLabel(latest.date!)}.',
      nodes: nodes,
    );
  }

  for (final day in dated) {
    if (day.date == today) {
      return TrailView(
        headline: 'Day ${day.number} of $dayCount',
        nodes: nodes,
      );
    }
  }

  // Inside the trip's span, on a date the plan does not claim. Nothing drew
  // this either; it takes the gap day's own voice — the weekday, and no
  // "Day n of m", because today is not one of the numbered days.
  return TrailView(
    headline: weekdayName(today.weekday),
    detail: '$dayCount $daysWord planned',
    nodes: nodes,
  );
}

TrailNode _node(PlanDay day, DateTime today, {required int? nextUp}) {
  final date = day.date;
  return TrailNode(
    number: day.number,
    place: day.place,
    dateLabel: date == null ? null : dayMonthLabel(date),
    weekdayLabel: date == null ? null : weekdayAbbrev(date.weekday),
    state: switch (date) {
      null => TrailNodeState.ahead,
      final d when d == today => TrailNodeState.today,
      final d when d.isBefore(today) => TrailNodeState.past,
      _ => TrailNodeState.ahead,
    },
    isNextUp: nextUp == day.number,
  );
}
