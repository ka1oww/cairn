// APP STATE band (docs/architecture.md): the day page's whole brain.
//
// One derivation serves every date. That is the point rather than a
// convenience: Cairn has no separate "day detail" screen — the day page for
// today *is* the day page for any day (design surface 2f, "Today / day
// detail"), so Today is `DayPage(today)` and the Trail will later open the
// same component on any other date without a second surface existing.
//
// The structure and states are the design's: the identity block and the flat
// ordered stop list of 2f, the "nothing planned" sentence of 3g, the
// past-tense star of 3i (outline, and "was 16:40"), and the countdown of 7c
// before the trip starts.
//
// Deliberately absent, because the decision record rejects them: progress
// tracking, morning/afternoon segmentation, and any "we're up to here" mark.
// The list is the plan, in order, as pasted.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'date_labels.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// View models — everything a screen may see, spoken in screen terms.
// ---------------------------------------------------------------------------

/// One stop as the day page shows it: the text as pasted, and a time label
/// exactly when the stop is starred.
///
/// **The star rule is the only rule**: a stop is starred because the plan
/// gave it an unhedged clock time, never because anything judged it
/// important. It lives in `cairn_model.Stop.isStarred` and `itinerary_parser`
/// and is only echoed here. A stop the parser refused to star carries no
/// time at all, which is why an unstarred row can show none: there is
/// nothing to show, not a rule suppressing it.
class DayStop {
  /// 1-based position in the day, counted across every stop. A starred stop
  /// keeps its position even though the star takes the number's place in the
  /// gutter (surface 2f numbers 01, 02, then stars the third).
  final int position;

  final String text;

  /// `16:40`, or null when the stop is not starred.
  final String? timeLabel;

  const DayStop({
    required this.position,
    required this.text,
    this.timeLabel,
  });

  bool get isStarred => timeLabel != null;
}

/// What the day page renders for one date. Four shapes, each drawn.
sealed class DayView {
  const DayView();
}

/// A day of the trip: its identity, and its stops in pasted order.
///
/// [stops] may be empty — that is design surface 3g's written state ("Nothing
/// planned. The best day of most trips."), not an error and not a skeleton.
class PlannedDay extends DayView {
  /// Which day of the trip this is, as pasted — the `4` of "Day 4 of 8".
  final int number;

  /// How many days the plan holds — the `8`.
  final int dayCount;

  /// `Wednesday, Kyoto`, `Kyoto`, or `Day 4`.
  final String title;

  /// `16 June`, or null while the date is still open. A whole plan pasted
  /// without dates lands here with every [dateLabel] null.
  final String? dateLabel;

  final List<DayStop> stops;

  /// True once the day is behind the trip. The star then loses its fill and
  /// its time reads "was 16:40" — surface 3i, which holds no opinion about
  /// what did not happen. Never a strikethrough, never red.
  final bool isOver;

  const PlannedDay({
    required this.number,
    required this.dayCount,
    required this.title,
    this.dateLabel,
    required this.stops,
    required this.isOver,
  });
}

/// A date inside the trip's span that no day of the plan claims.
///
/// It reads as 3g does — nothing planned is a written state, not an empty
/// list — but it carries no "Day n of m", because it is not one of the
/// numbered days.
class GapDay extends DayView {
  /// `Wednesday`.
  final String title;

  /// `16 June`.
  final String dateLabel;

  const GapDay({required this.title, required this.dateLabel});
}

/// The trip has not started. Surface 7c: how far away it is, at display
/// size, and the day that is next up.
class BeforeTheTrip extends DayView {
  /// `Five days to go.` — the countdown, written out rather than counted in
  /// digits, because the one number this app sets in digits is a starred
  /// stop's time.
  final String headline;

  /// `8 days planned`.
  final String detail;

  final PlannedDay nextUp;

  const BeforeTheTrip({
    required this.headline,
    required this.detail,
    required this.nextUp,
  });
}

/// The trip is behind us.
///
/// No day-page state was ever drawn for this: the design's post-trip surface
/// is the shelf and the book (7b), and both are after the first release. So
/// this is the plainest honest treatment — say the trip is over, and show
/// the last day, which by the gate decision belongs to everyone who was
/// there (grill round one §1).
class AfterTheTrip extends DayView {
  final String headline;

  /// `8 days, ending 21 June. Every one of them is still here.`
  final String detail;

  final PlannedDay lastDay;

  const AfterTheTrip({
    required this.headline,
    required this.detail,
    required this.lastDay,
  });
}

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

/// Today, as the day page reads it.
///
/// **This is an acknowledged approximation.** A trip has one clock and it
/// follows the itinerary's leg (`docs/decisions/2026-08-22-last-calls.md`
/// §4), but no trip clock is stored yet — nothing creates a trip row. So
/// this slice reads the *device's* date and keeps only its calendar fields.
/// That is right for everyone standing in the trip's own timezone and can be
/// a day out for a phone set elsewhere; when the trip clock lands, this
/// provider is the one place that changes.
///
/// Read once per app launch rather than ticking: the day advances by the
/// clock, never by completing anything, and a relaunch is soon enough for
/// that in this slice. Tests override it to pin a date.
final todayProvider = Provider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime.utc(now.year, now.month, now.day);
});

/// The day page's view model for one date, or null while no plan is saved.
///
/// The family key is a plain `DateTime` at UTC midnight, not a domain date:
/// screens may name nothing below this band, so no `cairn_model` type
/// reaches them.
final dayViewProvider = Provider.family<AsyncValue<DayView?>, DateTime>(
  (ref, date) {
    final today = ref.watch(todayProvider);
    return ref
        .watch(savedItineraryProvider)
        .whenData((plan) => dayViewFor(plan, date, today));
  },
);

// ---------------------------------------------------------------------------
// The derivation, kept a pure function so it can be read in one sitting.
// ---------------------------------------------------------------------------

/// Which view [date] gets, against [plan], with [today] deciding only whether
/// a day is already over.
///
/// Days are matched to dates and never inferred from position: the parser
/// does not guess dates and neither does this layer. A day the person
/// accepted with its date still open is therefore not reachable *by date*,
/// which is why a plan with no dates at all is handled separately below.
DayView? dayViewFor(TripPlan? plan, DateTime date, DateTime today) {
  if (plan == null || plan.days.isEmpty) return null;

  final dated = [for (final day in plan.days) if (day.date != null) day];
  if (dated.isEmpty) {
    // Nothing was pinned to the calendar, so no date can select a day. Day
    // one is what there is to show, and it shows its date as open rather
    // than inventing one.
    return _planned(plan, plan.days.first, isOver: false);
  }

  final earliest = dated.reduce((a, b) => a.date!.isBefore(b.date!) ? a : b);
  final latest = dated.reduce((a, b) => a.date!.isAfter(b.date!) ? a : b);

  final dayCount = plan.days.length;
  final daysWord = dayCount == 1 ? 'day' : 'days';

  if (date.isBefore(earliest.date!)) {
    final until = earliest.date!.difference(date).inDays;
    return BeforeTheTrip(
      headline: until == 1 ? 'Tomorrow.' : '${countWord(until)} days to go.',
      detail: '$dayCount $daysWord planned',
      nextUp: _planned(plan, earliest, isOver: false),
    );
  }
  if (date.isAfter(latest.date!)) {
    return AfterTheTrip(
      headline: 'The trip is walked.',
      detail: '$dayCount $daysWord, ending ${dayMonthLabel(latest.date!)}. '
          'Every one of them is still here.',
      lastDay: _planned(plan, latest, isOver: true),
    );
  }

  for (final day in dated) {
    if (day.date == date) {
      return _planned(plan, day, isOver: date.isBefore(today));
    }
  }

  return GapDay(
    title: weekdayName(date.weekday),
    dateLabel: dayMonthLabel(date),
  );
}

PlannedDay _planned(TripPlan plan, PlanDay day, {required bool isOver}) {
  final date = day.date;
  return PlannedDay(
    number: day.number,
    dayCount: plan.days.length,
    title: dayPageTitle(
      weekday: date == null ? null : weekdayName(date.weekday),
      place: day.place,
      number: day.number,
    ),
    dateLabel: date == null ? null : dayMonthLabel(date),
    stops: [
      for (final (index, stop) in day.stops.indexed)
        DayStop(
          position: index + 1,
          text: stop.text,
          timeLabel: stop.timeLabel,
        ),
    ],
    isOver: isOver,
  );
}
