// APP STATE band (docs/architecture.md): the trip's ending, in one place.
//
// A trip ends when its last day seals; it then spends `graceAfterATrip`
// taking nothing but late photographs; then it is the archive. The shape is
// `docs/decisions/2026-08-26-the-ending.md`, and **the rule is not written
// here**: it is `cairn_model`'s `tripStandingAt`, the same way the gate's
// rule is `GateState.decide` and this band only supplies its inputs
// (`day_gate.dart` says the same thing about itself, for the same reason).
//
// What this file supplies is the one input the domain cannot work out for
// itself: *when the trip ends*, read off a saved plan whose days carry bare
// calendar dates and no clock. The arithmetic over those dates is the
// domain's too (`cairn_model`'s `tripEndsAtInTimeZone`) and is deliberately
// not restated here — the sync's `_endsAt` calls the same function from the
// other side of the seam, and a rule written on both sides is a rule that
// drifts.
// What is left here is reading the plan and handing it over in plan order.
//
// Two things worth knowing before changing anything in it:
//
//  - **A trip ends at the end of its last day, and a plan whose last day has
//    no date has not ended.** It is `underway`, deliberately, and not
//    "closed" or "unknown" — an undated tail is an end nobody knows yet, and
//    ending on the last *dated* day instead would archive a trip whose
//    travellers are still on it. Nothing here guesses a date, and a trip
//    takes its ending the moment its plan's last day has one — the same
//    answer `TripInvite.standingAt` gives a null close.
//  - **The end is midnight on the trip's own clock, not UTC midnight.** A
//    saved destination IANA zone turns that calendar boundary into an instant
//    through the same DST rules as pings. Without one, the ending stays
//    unknown rather than borrowing the phone's clock.
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trip_moments/trip_moments.dart' as tm;

import 'date_labels.dart';
import 'ping_schedule.dart';
import 'trip_providers.dart';

// ---------------------------------------------------------------------------
// The derivations, kept pure so the two instants can be read in one sitting.
// ---------------------------------------------------------------------------

/// The instant [plan]'s last day seals, or null while that end is not known.
///
/// The rule is the domain's — [model.tripEndsAtInTimeZone] for a persisted
/// destination zone, with [model.tripEndsAtFrom] retained only for legacy
/// fixed-offset callers. The sync's own `_endsAt` makes the same choice, so
/// the ending cannot be one thing on screen and another on the wire. What this
/// supplies is the plan's day dates in plan order, nulls kept, since which day
/// is *last* is the whole of the question.
DateTime? tripEndsAtFor(
  TripPlan? plan,
  Duration? utcOffset, {
  String? timeZone,
}) {
  if (plan == null) return null;
  final days = plan.days.toList()..sort((a, b) => a.number.compareTo(b.number));
  final dates = [for (final day in days) day.date];
  if (timeZone != null) {
    return model.tripEndsAtInTimeZone(
      dayDatesInPlanOrder: dates,
      timeZone: timeZone,
    );
  }
  if (utcOffset == null) return null;
  return model.tripEndsAtFrom(dayDatesInPlanOrder: dates, utcOffset: utcOffset);
}

/// The instant [plan] closes to new photos — and with it the instant its
/// codes die — or null while the plan has no known ending.
///
/// The rule is the domain's (`cairn_model`'s `tripClosesAt`: the trip's end
/// plus the grace) and is deliberately not spelled out again here. The book's
/// rule is not this one and never will be: it does not expire.
DateTime? tripCloseFor(
  TripPlan? plan,
  Duration? utcOffset, {
  String? timeZone,
}) {
  final endsAt = tripEndsAtFor(plan, utcOffset, timeZone: timeZone);
  return endsAt == null ? null : model.tripClosesAt(endsAt);
}

/// Where the trip stands at [now]. The whole of this file's answer.
model.TripStanding tripStandingFor(
  TripPlan? plan,
  Duration? utcOffset,
  DateTime now, {
  String? timeZone,
}) => model.tripStandingAt(
  now: now,
  endsAt: tripEndsAtFor(plan, utcOffset, timeZone: timeZone),
);

/// The one sentence that says where the trip's ending stands, or null while
/// the trip is still underway and has no ending to report.
///
/// Written once and read by both surfaces that say it — the day page's
/// post-trip announcement and the trip's own sheet — because a trip that is
/// over on one screen and closing on another is two answers to one question.
///
String? tripClosingLabel({
  required DateTime closesAt,
  required Duration? utcOffset,
  String? timeZone,
}) {
  final localTime = timeZone == null
      ? utcOffset == null
            ? null
            : Duration(
                hours: closesAt.toUtc().add(utcOffset).hour,
                minutes: closesAt.toUtc().add(utcOffset).minute,
              )
      : model.timeOfDayInTimeZone(closesAt, timeZone);
  if (localTime == null) return null;
  final localDate = timeZone == null
      ? closesAt.toUtc().add(utcOffset!)
      : tm.dateInTimeZone(closesAt, timeZone);
  final date = localTime == Duration.zero
      ? localDate.subtract(const Duration(days: 1))
      : localDate;
  final day = dayMonthLabel(date);
  if (localTime == Duration.zero) return 'the end of $day';
  final hour = localTime.inHours.toString().padLeft(2, '0');
  final minute = (localTime.inMinutes % Duration.minutesPerHour)
      .toString()
      .padLeft(2, '0');
  return '$hour:$minute on $day';
}

String? tripEndingLine({
  required model.TripStanding standing,
  required DateTime? closesAt,
  required Duration? utcOffset,
  String? timeZone,
}) {
  if (standing == model.TripStanding.underway) return null;
  if (standing == model.TripStanding.archived) {
    return 'Closed. What is in it is what it is.';
  }
  if (closesAt == null) return 'Still open for anything you are holding.';
  final label = tripClosingLabel(
    closesAt: closesAt,
    utcOffset: utcOffset,
    timeZone: timeZone,
  );
  return label == null
      ? 'Still open for anything you are holding.'
      : 'Still open for anything you are holding, until $label.';
}

// ---------------------------------------------------------------------------
// Providers.
// ---------------------------------------------------------------------------

/// The instant the trip's last day seals, or null while its last day's date
/// is still open.
final tripEndsAtProvider = Provider<DateTime?>(
  (ref) => tripEndsAtFor(
    ref.watch(savedItineraryProvider).value,
    null,
    timeZone: ref.watch(tripTimeZoneProvider),
  ),
);

/// The instant the trip closes to new photographs and its codes die, or null
/// while its last day's date is still open.
final tripClosesAtProvider = Provider<DateTime?>(
  (ref) => tripCloseFor(
    ref.watch(savedItineraryProvider).value,
    null,
    timeZone: ref.watch(tripTimeZoneProvider),
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
/// Derived on demand and cached until something rebuilds it. The clock it
/// asks is live (`nowProvider` says why), so this is as fresh as the last
/// time it was built — nothing in this slice pushes a new answer at a
/// surface, and a trip's ending is a boundary hours wide rather than the
/// two-minute one the capture screen keeps its own second hand for.
final tripStandingProvider = Provider<model.TripStanding>(
  (ref) => model.tripStandingAt(
    now: ref.watch(nowProvider)(),
    endsAt: ref.watch(tripEndsAtProvider),
  ),
);

/// The trip's ending in one sentence, or null while it is still underway.
final tripEndingLineProvider = Provider<String?>(
  (ref) => tripEndingLine(
    standing: ref.watch(tripStandingProvider),
    closesAt: ref.watch(tripClosesAtProvider),
    utcOffset: null,
    timeZone: ref.watch(tripTimeZoneProvider),
  ),
);
