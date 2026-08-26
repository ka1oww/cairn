// LOGIC (lib/README.md): the re-paste merge — the pure decision core of
// "edit after accept". The person has a plan saved on this phone and pastes a
// revised one; this file decides how the two become one plan without ever
// demolishing anything. A separate slice renders the result and persists it
// through the seam; nothing here touches IO, state, clocks or Riverpod, and
// the same inputs always produce the same output.
//
// The settled rules (firstmate brief, 2026-08-26), written once:
//
//  1. Match repasted days to current days by DATE first (when both sides have
//     dates), then by POSITION for undated days.
//  2. A matched day takes the repasted content; anything the revised plan no
//     longer contains *anywhere* goes to the set-aside, never silently
//     dropped. Survival is plan-wide: a stop the re-paste moved to another day
//     was moved, not displaced.
//  3. Days in the current plan with no repasted counterpart are kept,
//     untouched.
//  4. Repasted days with no current counterpart are appended as new days.
//  5. A day the merge leaves unchanged keeps its identity: it comes back as
//     the very same [ConfirmedDay] instance, with its number untouched, so
//     photos and other attachments stay associated with it.
//  6. Pure: no IO, no state, deterministic.
//
// Two readings of the model this merge depends on, both taken from the code
// rather than invented here:
//
//  - **The current plan is `ConfirmedDay`s**, not `cairn_model.TripDay`s —
//    `lib/repositories/trip_repository.dart` is explicit that a saved day may
//    carry its date still open and has no trip clock yet, which is part of why
//    TripDay "is deliberately not" what is stored. The merge therefore speaks
//    ConfirmedDay on the current side and `ParsedDay` on the repasted side.
//  - **A day's identity is its number.** Photos are assigned to day numbers,
//    and every surface reads them that way; the merge preserves the number of
//    every day that existed before, and numbers fresh days after the current
//    maximum. It never renumbers and never closes gaps.
import 'package:cairn_model/cairn_model.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

import '../repositories/trip_repository.dart';

/// What the set-aside says about a stop the revised plan left out. Spelled
/// once: it travels with the item, is shown next to it, and is asserted in
/// tests — the same pattern as paste_flow's `removedByYouExplanation`.
const displacedByRepasteExplanation =
    'Your updated plan no longer includes this — kept here, not deleted. '
    'Drag it back into a day to put it back.';

/// How a merged day came to be, which is the whole story the screen needs to
/// tell about it.
enum MergedDayOrigin {
  /// No repasted day claimed it: kept exactly as it was (rule 3).
  keptUnmatched,

  /// A repasted day with the same date took it over (rule 1, date pass).
  mergedByDate,

  /// An undated repasted day filled it by position (rule 1, position pass).
  mergedByPosition,

  /// A repasted day no current day claimed; appended after the existing ones
  /// (rule 4).
  ///
  /// An appended day is content **nobody has confirmed**, so it arrives
  /// carrying the parser's own verdict on it — [MergedDay.confidence],
  /// [MergedDay.uncertainty] and [MergedDay.headerWeekday] — and the screen
  /// asks about it exactly as it asks about a first paste. That asymmetry is
  /// the rule, not an oversight: see [MergedDay.uncertainty].
  appendedNew,
}

/// One day of the updated plan, in order.
///
/// Wraps the [day] itself rather than flattening its fields, so there is only
/// one shape of a saved day in the codebase and so an unchanged day can be
/// handed back as the *identical instance* — rule 5 made provable rather than
/// promised.
class MergedDay {
  /// The day as it now stands. For a [MergedDayOrigin.keptUnmatched] day —
  /// and for a matched day whose repasted content equals what was already
  /// there — this is the very [ConfirmedDay] instance that went in.
  final ConfirmedDay day;

  final MergedDayOrigin origin;

  /// True when nothing about this day changed: its content before the merge
  /// and after are value-equal, so anything attached to the day — photos
  /// above all — remains valid without churn.
  final bool unchanged;

  /// A date the repasted day's own title named that nobody has bound. Carried
  /// through from the parse so the screen can still ask about it; the merge
  /// never binds a candidate — reading a named date to find a day's twin is
  /// not binding it.
  final ip.DateCandidate? dateCandidate;

  /// How sure the parser was about this day, and why it was unsure — carried
  /// straight off [ip.ParsedDay] for a [MergedDayOrigin.appendedNew] day, and
  /// [ip.Confidence.high] with no [uncertainty] for every other day.
  ///
  /// **The asymmetry is the point.** A day the current plan already held was
  /// read, asked about and accepted before it was ever saved — re-asking
  /// would nag about a question the person has answered, and "leave the date
  /// open" is one of the answers. A day the re-paste *adds* has been through
  /// none of that: it is a fresh read, and the parser's doubt about it is the
  /// only thing standing between `Sat - Nara` and a day saved with its date
  /// silently open. So an appended day keeps [confidence], [uncertainty] and
  /// [headerWeekday]; a matched or kept one reports none.
  ///
  /// The merge itself never invents any of the three and never resolves them:
  /// working out which Saturday, like working out a year, is the screen's ask.
  final ip.Confidence confidence;

  /// Why [confidence] is below [ip.Confidence.high] — null exactly when it
  /// isn't. See [confidence] for which days carry it.
  final ip.DayUncertainty? uncertainty;

  /// The ISO weekday this day's header *named* without pinning a date
  /// (`Sat - Nara` → 6), for a [MergedDayOrigin.appendedNew] day. Null
  /// otherwise. It is what lets the screen check a named weekday against the
  /// date the day would land on, and it is quoted in the day's title until
  /// one is bound.
  final int? headerWeekday;

  const MergedDay({
    required this.day,
    required this.origin,
    required this.unchanged,
    this.dateCandidate,
    this.confidence = ip.Confidence.high,
    this.uncertainty,
    this.headerWeekday,
  });

  int get number => day.number;

  CalendarDate? get date => day.date;

  String? get place => day.place;

  List<Stop> get stops => day.stops;
}

/// A stop the revised plan displaced from a day it took over. Never deleted:
/// it carries everything needed to drag it back losslessly — text and time —
/// plus the day it came from.
class SetAsideItem {
  /// The number of the day the stop was displaced from (stable across the
  /// merge: it is the same number the day wears in [RepasteMergeResult.days]).
  final int fromDayNumber;

  /// The displaced stop, as it stood in the current plan.
  ///
  /// Its time rides along here, but only as far as the next save:
  /// `itinerary_set_asides` has no time column, so `PasteFlow.accept` writes
  /// the line's text and reason and drops its time, and dragging it back after
  /// a reopen restores it unstarred. Pre-existing — a stop the person removed
  /// by hand loses its time the same way — and closing it needs a schema
  /// change.
  final Stop stop;

  /// The person-showable reason ([displacedByRepasteExplanation]).
  final String explanation;

  const SetAsideItem({
    required this.fromDayNumber,
    required this.stop,
    this.explanation = displacedByRepasteExplanation,
  });
}

/// The two-part result of a re-paste merge: the updated plan, in order, and
/// everything the merge displaced — never deleted, only set aside.
class RepasteMergeResult {
  final List<MergedDay> days;
  final List<SetAsideItem> setAside;

  const RepasteMergeResult({required this.days, required this.setAside});
}

/// Merges a revised paste into the current plan by the six settled rules.
///
/// Matching runs in two passes. The **date pass** walks [repasted] in order;
/// a day whose date is known — bound by the parser, or spelled out fully
/// (with a year) in a title fragment the parser left as a
/// [ip.ParsedDay.dateCandidate] whose reading is unambiguous — claims the
/// earliest not-yet-claimed current day wearing that date. A candidate the
/// parser flagged [ip.DateCandidate.ambiguousNumericOrder] (5/6/2027: is that
/// May or June?) is undated for matching and falls through to the position
/// pass; it still rides on the [MergedDay] for the screen to ask about. The **position pass** then pairs remaining
/// *undated* repasted days, in order, with remaining unclaimed current days,
/// in order. A dated repasted day whose date no current day wears is never
/// position-matched: it names a day the current plan does not have, and is
/// appended (rule 4).
///
/// On a matched day the repasted content wins wholesale — place and stops.
/// Survival is decided over the *whole* revised plan, not the day alone: a
/// current stop whose text still appears anywhere in the re-paste (same
/// spelling up to case and whitespace) was moved and is kept; only a stop the
/// revised plan no longer says at all becomes a [SetAsideItem]. Times are not
/// part of survival, because re-timing a stop is keeping it.
///
/// Appended days take their date only when the parser itself bound one; a
/// title-carried candidate stays a candidate, carried on the [MergedDay] for
/// the screen to ask about, because the app offers dates and never assumes
/// them. An appended day also carries the rest of the parser's verdict on it
/// — [MergedDay.confidence], [MergedDay.uncertainty] and
/// [MergedDay.headerWeekday] — because nobody has confirmed it yet; a matched
/// or kept day carries none, because the person answered for it before the
/// plan was saved. [MergedDay.confidence] holds the whole reasoning.
RepasteMergeResult mergeRepaste({
  required List<ConfirmedDay> current,
  required List<ip.ParsedDay> repasted,
}) {
  // Claim bookkeeping: index-addressed lists, so nothing depends on map
  // iteration order and the walk below reads straight off these.
  final currentClaimed = List.filled(current.length, false);
  final pairedCurrentOf = List<int?>.filled(repasted.length, null);

  // -- pass 1: date ---------------------------------------------------------
  for (var r = 0; r < repasted.length; r++) {
    final effective = _effectiveDate(repasted[r]);
    if (effective == null) continue;
    for (var c = 0; c < current.length; c++) {
      if (currentClaimed[c]) continue;
      if (current[c].date == effective) {
        currentClaimed[c] = true;
        pairedCurrentOf[r] = c;
        break;
      }
    }
  }

  // -- pass 2: position, undated repasted days only -------------------------
  final freeCurrents = <int>[
    for (var c = 0; c < current.length; c++)
      if (!currentClaimed[c]) c,
  ];
  var nextFree = 0;
  for (var r = 0; r < repasted.length; r++) {
    if (pairedCurrentOf[r] != null) continue;
    if (_effectiveDate(repasted[r]) != null) continue;
    if (nextFree >= freeCurrents.length) break;
    final c = freeCurrents[nextFree++];
    currentClaimed[c] = true;
    pairedCurrentOf[r] = c;
  }

  // -- assemble -------------------------------------------------------------
  var maxNumber = 0;
  for (final day in current) {
    if (day.number > maxNumber) maxNumber = day.number;
  }
  var appendedCount = 0;

  // Survival is plan-wide: every stop the revised plan still says, anywhere.
  final repastedTexts = <String>{
    for (final day in repasted)
      for (final stop in day.stops) _normalize(stop.text),
  };

  final days = <MergedDay>[];
  final setAside = <SetAsideItem>[];

  // Existing days first, in the order they were given, numbers untouched:
  // this ordering is what keeps every surviving day reachable exactly where
  // it was.
  for (var c = 0; c < current.length; c++) {
    final r = pairedCurrentOf.indexOf(c);
    if (r < 0) {
      days.add(
        MergedDay(
          day: current[c],
          origin: MergedDayOrigin.keptUnmatched,
          unchanged: true,
        ),
      );
      continue;
    }
    days.add(_mergeMatched(current[c], repasted[r], repastedTexts, setAside));
  }

  // Then whatever the revised plan brings that the current plan has no day
  // for, numbered after everything that exists.
  for (var r = 0; r < repasted.length; r++) {
    if (pairedCurrentOf[r] != null) continue;
    appendedCount += 1;
    final parsed = repasted[r];
    days.add(
      MergedDay(
        day: ConfirmedDay(
          number: maxNumber + appendedCount,
          date: parsed.date == null
              ? null
              : CalendarDate.fromDateTimeIgnoringZone(parsed.date!),
          place: parsed.place,
          stops: _convertStops(parsed.stops),
        ),
        origin: MergedDayOrigin.appendedNew,
        unchanged: false,
        dateCandidate: parsed.dateCandidate,
        // An appended day is an unconfirmed read: the parser's verdict rides
        // with it so the screen can ask, exactly as it asks about a first
        // paste. See [MergedDay.confidence] for why matched days do not.
        confidence: parsed.confidence,
        uncertainty: parsed.uncertainty,
        headerWeekday: parsed.headerWeekday,
      ),
    );
  }

  return RepasteMergeResult(days: days, setAside: setAside);
}

/// Builds the merged replacement for [currentDay] out of [parsed], filing
/// everything that disappeared into [setAside]. When the repasted content is
/// value-equal to what was already there, hands back the original day
/// untouched.
MergedDay _mergeMatched(
  ConfirmedDay currentDay,
  ip.ParsedDay parsed,
  Set<String> repastedTexts,
  List<SetAsideItem> setAside,
) {
  final newStops = _convertStops(parsed.stops);

  // Which current stops survive? Anything the revised plan still says, on any
  // of its days: a stop that moved to another day was moved, not displaced.
  for (final stop in currentDay.stops) {
    if (repastedTexts.contains(_normalize(stop.text))) continue;
    setAside.add(SetAsideItem(fromDayNumber: currentDay.number, stop: stop));
  }

  final placeChanged = currentDay.place != parsed.place;
  final stopsChanged = !_stopListsEqual(currentDay.stops, newStops);
  final origin = parsed.date != null || _candidateDate(parsed) != null
      ? MergedDayOrigin.mergedByDate
      : MergedDayOrigin.mergedByPosition;

  if (!placeChanged && !stopsChanged) {
    return MergedDay(
      day: currentDay,
      origin: origin,
      unchanged: true,
      dateCandidate: parsed.dateCandidate,
    );
  }

  // The repasted content wins wholesale. The day keeps its number (identity)
  // and its date — a merged day is never re-dated here: the date pass only
  // ever pairs equal dates, and the position pass only pairs days the parse
  // gave no date to.
  return MergedDay(
    day: ConfirmedDay(
      number: currentDay.number,
      date: currentDay.date,
      place: parsed.place,
      stops: newStops,
    ),
    origin: origin,
    unchanged: false,
    dateCandidate: parsed.dateCandidate,
  );
}

List<Stop> _convertStops(List<ip.Stop> stops) => List.unmodifiable([
  for (final stop in stops)
    Stop(
      text: stop.text,
      time: switch (stop.time) {
        null => null,
        final t => ClockTime(t.hour, t.minute),
      },
    ),
]);

/// The date a repasted day effectively carries for matching: the parser-bound
/// date, or a title-named candidate whose header spelled a full year out and
/// read only one way. A year-less candidate resolves against nothing here, and
/// neither does one whose numeric order is ambiguous — working out years, and
/// choosing between 5 June and 5 May, is the screen's ask, never the merge's
/// guess.
CalendarDate? _effectiveDate(ip.ParsedDay day) {
  final bound = day.date;
  if (bound != null) return CalendarDate.fromDateTimeIgnoringZone(bound);
  return _candidateDate(day);
}

CalendarDate? _candidateDate(ip.ParsedDay day) {
  final candidate = day.dateCandidate;
  if (candidate == null || candidate.ambiguousNumericOrder) return null;
  final resolved = candidate.resolved;
  return resolved == null
      ? null
      : CalendarDate.fromDateTimeIgnoringZone(resolved);
}

/// Case- and whitespace-insensitive text identity: the same stop retyped with
/// a stray double space or a shifted capital is still the same stop.
String _normalize(String text) =>
    text.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');

bool _stopListsEqual(List<Stop> a, List<Stop> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
