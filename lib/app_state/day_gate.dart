// APP STATE band (docs/architecture.md): the gate, once, for every surface
// that draws a photograph.
//
// **The rule is not written here.** It is `cairn_model.GateState.decide`, the
// same four lines `Trip.gateFor` answers with and the same rule
// `day_page_is_open` keeps in SQL (docs/architecture.md, invariant 2). This
// file only supplies that rule its two inputs from what this phone actually
// has: where a day of the plan stands against today, and whether the person
// holding the phone has put something into it. A third copy of the rule — one
// in the Pool, one on the day page, one on the Trail — is the thing to refuse
// in review, which is why they all come here instead.
//
// What the gate is, in one line: **today's page stays shut to you until you
// have contributed to it, and every day that is over is already open to
// everyone who was on the trip**
// (`docs/decisions/2026-08-22-grill-round-one.md` §1,
// `docs/decisions/2026-08-22-last-calls.md` §3).
//
// Two seams here are deliberately narrow, and both close in Phase 2:
//
//  - **The viewer is `localMemberId`.** No roster exists — no member table, no
//    accounts — so "you" is the one id this phone credits its own photos to
//    (`ping_schedule.dart`). Every gate answer in the app flows through
//    [viewerProvider], so a real roster arrives by binding that to the signed-in
//    member and nothing else in this file moves.
//  - **"Have I contributed" is read off the photos that are still there.** The
//    server keeps the answer as its own fact, in `day_unlocks`, precisely
//    because deleting your photo must not shut a day you had already opened
//    (`0007_day_unlocks.sql`, and the same trap in `cairn_model`'s README under
//    `DayPool.of`). This phone has no such table and no way to delete a photo
//    either, so the two answers cannot yet disagree — but they will the moment
//    deletion lands, and that is when the local unlock fact has to exist.
import 'package:cairn_model/cairn_model.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/photo_repository.dart';
import 'day_view.dart';
import 'ping_schedule.dart';
import 'trip_providers.dart';

/// Who the gate is being answered for.
///
/// The roster's slot. See the file header — today this is the one id this
/// phone credits its own photos to.
final viewerProvider = Provider<MemberId>((ref) => MemberId(localMemberId));

/// Whether day [number] of the plan is open to the person holding this phone,
/// and why.
///
/// Keyed by the plan's own day number rather than by date, because that is
/// what a photo carries (`PhotoRef.dayNumber`) and what the Trail and the Pool
/// both index a day by. A day whose date is still open is reachable this way
/// and by nothing else, exactly as on the day page.
final dayGateProvider = Provider.family<GateState, int>((ref, number) {
  final plan = ref.watch(savedItineraryProvider).value;
  return gateForPlanDay(
    number: number,
    planDay: planDayOf(plan, number),
    today: ref.watch(todayProvider),
    photos: ref.watch(tripPhotosProvider).value ?? const [],
    viewer: ref.watch(viewerProvider),
  );
});

/// Day [number] of [plan], or null when the plan has no such day.
///
/// A photo can carry a day number the plan no longer claims — the Pool says so
/// too — so this returns null rather than assuming every day number is one of
/// the plan's.
PlanDay? planDayOf(TripPlan? plan, int number) {
  if (plan == null) return null;
  for (final day in plan.days) {
    if (day.number == number) return day;
  }
  return null;
}

/// The gate for one day of the plan, answered from what this phone holds.
GateState gateForPlanDay({
  required int number,
  required PlanDay? planDay,
  required DateTime today,
  required List<PooledPhoto> photos,
  required MemberId viewer,
}) {
  // `DayPool` rather than a scan of the list, so "has contributed" means what
  // the domain says it means and not what this layer guesses it means.
  final pool = DayPool.of(number, [
    for (final photo in photos)
      if (photo.ref.dayNumber == number) photo.ref,
  ]);
  return GateState.decide(
    standing: standingOfPlanDay(planDay, today),
    hasContributed: pool.hasContributed(viewer),
  );
}

/// Where a day of the plan stands against [today].
///
/// The app's answer to the question `cairn_model.TripDay.standingAt` answers
/// for a real trip. It is asked of the plan's dates because that is all this
/// phone has: no trip row is stored, so there is no trip clock and no day
/// windows to read an instant against — the same acknowledged approximation
/// `todayProvider` documents, and it closes in the same place.
///
/// **A day whose date is still open is walked.** Not a guess about the
/// calendar: the gate is about the day you are living, today has a date, so a
/// day with none is certainly not it — and the gate has no business shutting
/// any other day. Nothing can put a photograph on such a day either (a ping
/// needs an instant, and capture only ever writes to today), so what this
/// governs is a day the plan has since stopped claiming, whose photographs are
/// already in the past.
DayStanding standingOfPlanDay(PlanDay? planDay, DateTime today) {
  final date = planDay?.date;
  if (date == null) return DayStanding.walked;
  if (date.isBefore(today)) return DayStanding.walked;
  if (date.isAfter(today)) return DayStanding.notYet;
  return DayStanding.inProgress;
}
