// APP STATE band (docs/architecture.md): the trip's ending, in one place.
//
// A trip ends when its last day seals; it then spends `graceAfterATrip`
// taking nothing but late photographs; then it is the archive. The shape is
// `docs/decisions/2026-08-26-the-ending.md`, and **the rule is not written
// here**: it is `cairn_model`'s `tripStandingAt`, the same way the gate's
// rule is `GateState.decide` and this band only supplies its inputs
// (`day_gate.dart` says the same thing about itself, for the same reason).
//
// What this file supplies is the one input the domain cannot work out: *when
// the trip ends*, from a saved plan whose days carry bare calendar dates and
// no clock. That arithmetic used to sit inside `trip_settings.dart` because
// the code's expiry line was the only thing that needed it; three more
// callers need it now — capture, the paste flow and the sync — so it moved
// here rather than being reached for sideways.
//
// Two things worth knowing before changing anything in it:
//
//  - **A plan with no dates has not ended.** It is `underway`, deliberately,
//    and not "closed" or "unknown". Nothing here guesses a date, and a trip
//    takes its ending the moment its plan has one — the same answer
//    `TripInvite.standingAt` gives a null close.
//  - **The end is midnight on the trip's own clock, not UTC midnight.** The
//    same acknowledged approximation as `todayProvider` and
//    `tripUtcOffsetProvider`: one offset for the whole trip, read off the
//    device, because no trip clock is stored yet. It is why a trip that
//    crosses a border still closes on the evening its travellers lived, to
//    within the one offset this slice has; the server's half
//    (`trip_closes_at` in `0005_trip_invites.sql`) reads the trip's real zone
//    and has the same shape.
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'date_labels.dart';
import 'ping_schedule.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// The derivations, kept pure so the two instants can be read in one sitting.
// ---------------------------------------------------------------------------

/// The instant [plan]'s last day seals, or null while the plan has no dates
/// to end on.
///
/// A day's date is a bare calendar date carried at UTC midnight; the day
/// itself ends at the *next* midnight on the trip's clock. Undated days play
/// no part — they cannot be the end of anything, because nothing knows when
/// they are.
DateTime? tripEndsAtFor(TripPlan? plan, Duration utcOffset) {
  if (plan == null) return null;
  DateTime? last;
  for (final day in plan.days) {
    final date = day.date;
    if (date == null) continue;
    if (last == null || date.isAfter(last)) last = date;
  }
  if (last == null) return null;
  return last.add(const Duration(days: 1)).subtract(utcOffset);
}

/// The instant [plan] closes to new photos — and with it the instant its
/// codes die — or null while the plan has no dates to end on.
///
/// The rule is the domain's (`cairn_model`'s `tripClosesAt`: the trip's end
/// plus the grace) and is deliberately not spelled out again here. The book's
/// rule is not this one and never will be: it does not expire.
DateTime? tripCloseFor(TripPlan? plan, Duration utcOffset) {
  final endsAt = tripEndsAtFor(plan, utcOffset);
  return endsAt == null ? null : model.tripClosesAt(endsAt);
}

/// Where the trip stands at [now]. The whole of this file's answer.
model.TripStanding tripStandingFor(
  TripPlan? plan,
  Duration utcOffset,
  DateTime now,
) => model.tripStandingAt(now: now, endsAt: tripEndsAtFor(plan, utcOffset));

/// The one sentence that says where the trip's ending stands, or null while
/// the trip is still underway and has no ending to report.
///
/// Written once and read by both surfaces that say it — the day page's
/// post-trip announcement and the trip's own sheet — because a trip that is
/// over on one screen and closing on another is two answers to one question.
///
/// The grace line names the last day the door is open, not the instant it
/// shuts: [closesAt] is midnight *ending* that day, so the date said out loud
/// is the day before it, exactly as the code's expiry line does it.
String? tripEndingLine({
  required model.TripStanding standing,
  required DateTime? closesAt,
  required Duration utcOffset,
}) => switch (standing) {
  model.TripStanding.underway => null,
  model.TripStanding.grace =>
    closesAt == null
        ? 'Still open for anything you are holding.'
        : 'Still open for anything you are holding, until the end of '
              '${dayMonthLabel(closesAt.add(utcOffset).subtract(const Duration(days: 1)))}.',
  // No countdown and no invitation to act: the trip is closed, and the only
  // honest thing left to say is that what it holds is what it holds. The
  // book made from it is a later surface (travelapp-photo-handover) and is
  // deliberately not promised here.
  model.TripStanding.archived => 'Closed. What is in it is what it is.',
};

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

/// The instant the trip's last day seals, or null while its dates are open.
final tripEndsAtProvider = Provider<DateTime?>(
  (ref) => tripEndsAtFor(
    ref.watch(savedItineraryProvider).value,
    ref.watch(tripUtcOffsetProvider),
  ),
);

/// The instant the trip closes to new photographs and its codes die, or null
/// while its dates are open.
final tripClosesAtProvider = Provider<DateTime?>(
  (ref) => tripCloseFor(
    ref.watch(savedItineraryProvider).value,
    ref.watch(tripUtcOffsetProvider),
  ),
);

/// Where the trip stands right now.
///
/// **Every surface and every write path asks here.** Capture asks it before
/// keeping a frame, the paste flow asks it before replacing a plan, the trip
/// sheet asks it before offering a rename, and the sync asks it before
/// reaching for the network. A second comparison of dates anywhere above this
/// provider is the thing to refuse in review.
///
/// Read rather than ticked, for the reason `nowProvider` and `todayProvider`
/// are: nothing in this slice holds a timer, and every surface that reads it
/// is rebuilt by the things that would make it interesting.
final tripStandingProvider = Provider<model.TripStanding>(
  (ref) => model.tripStandingAt(
    now: ref.watch(nowProvider),
    endsAt: ref.watch(tripEndsAtProvider),
  ),
);

/// The trip's ending in one sentence, or null while it is still underway.
final tripEndingLineProvider = Provider<String?>(
  (ref) => tripEndingLine(
    standing: ref.watch(tripStandingProvider),
    closesAt: ref.watch(tripClosesAtProvider),
    utcOffset: ref.watch(tripUtcOffsetProvider),
  ),
);
