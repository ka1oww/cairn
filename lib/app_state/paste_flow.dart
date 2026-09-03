// APP STATE band (docs/architecture.md): the paste-and-confirm flow's state.
//
// This file is the flow's whole brain: it owns the pasted text, runs the
// parser (the DOMAIN band — screens never name it), holds the person's
// editable draft of what it read, and persists the accepted itinerary through
// the seam. The screens render the view models defined here and call the
// notifier's methods; every type they see is declared in this band.
//
// The shape of what gets shown is design round 8's
// (docs/design/2026-08-22-round8-handoff.zip): the confident read, the doubt
// surfaced per day with cause-specific copy, the one-tap month-first re-read,
// the kept-aside lines with reasons, and the paste that could not be read.
//
// **The read-back is an editor.** The parse is a first draft, not a verdict:
// every stop can be reworded, timed, reordered inside its day, moved to
// another day, or set aside, and every day can be renamed and dated — all of
// it before the plan is accepted. Two rules hold the whole thing together:
//
//  - **Nothing is ever demolished.** Removing a stop moves it to the
//    set-aside with a reason, exactly where the parser's own unplaced lines
//    sit, and dragging it back into a day restores it. There is no delete.
//  - **A date the plan named is offered, never assumed.** A `Day N` header
//    that says `Tokyo, 14 June` carries that date as a *candidate*
//    (`ip.DateCandidate`); this layer works it up into a [DateSuggestion] the
//    date sheet can draw, and only a tap binds it.
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

import '../logic/parsed_areas.dart';
import '../logic/plan_text.dart';
import '../logic/repaste_merge.dart' as merge;
import '../repositories/trip_repository.dart';
import 'area_gazetteer_loader.dart';
import 'date_labels.dart';
import 'day_view.dart';
import 'ping_schedule.dart';
import 'plan_draft.dart';
import 'trip_lifecycle.dart';
import 'trip_providers.dart';

/// The reason a set-aside line carries when the person took it out of a day
/// themselves. Spelled once: it is persisted with the accepted plan, shown in
/// the set-aside tile, and asserted in tests.
const removedByYouExplanation =
    'Removed by you — kept here, not deleted. Drag it back into a day to '
    'put it back.';

/// The set-aside reasons that came from the person rather than from the
/// parser: they took the stop out of a day themselves, or their own re-paste
/// displaced it. Written once, because both the accepted plan being read back
/// ([PasteFlow.editLivePlan]) and the merge itself have to agree on it —
/// string comparisons in two places drift apart the moment a third reason is
/// written. Every reason the merge can file a line under belongs here.
const _personOriginatedAsideExplanations = <String>{
  removedByYouExplanation,
  merge.displacedByRepasteExplanation,
};

/// Whether a set-aside line got there by the person's own hand. Drives the
/// tray's title — "set aside" for these, "couldn't place" for the parser's
/// own unplaced lines — and survives a save and a reopen because it is
/// derived from the reason that was persisted with the line.
bool setAsideCameFromThePerson(String explanation) =>
    _personOriginatedAsideExplanations.contains(explanation);

// ---------------------------------------------------------------------------
// View models — everything a screen may see, spoken in screen terms.
// ---------------------------------------------------------------------------

/// How sure the read of one day is, as the layout treats it. Mirrors the
/// parser's `Confidence` but is deliberately this band's own type: screens
/// never import the parser.
enum DayConfidence { high, medium, low }

/// Why a day is doubted — drives which copy and which ask the screen shows.
enum DayDoubtCause {
  weekdayWithoutDate,
  dateWithoutYear,
  barePlaceName,
  noStops,
}

/// One stop as the confirmation screen shows it: the text as it now stands,
/// and a time label exactly when there is a time — the star rule, which the
/// parser sets on the first read and the person can set or clear afterwards.
///
/// [id] is how a tap or a drag names this stop back to the notifier. It is
/// stable for as long as the draft lives, and a re-read of the whole paste
/// mints new ones, because a re-read makes different stops.
class ReviewStop {
  final String id;
  final String text;
  final String? timeLabel;

  /// What the parser decided this line is. The editor draws an area heading
  /// and a note differently from a place, and never re-decides which it is.
  final model.StopKind kind;

  /// The area in force, and whose it is. A person's edit here is
  /// [model.AreaSource.human] and outranks the parser from then on.
  final String? area;
  final model.AreaSource? areaSource;

  const ReviewStop({
    required this.id,
    required this.text,
    this.timeLabel,
    this.kind = model.StopKind.place,
    this.area,
    this.areaSource,
  });

  bool get isStarred => timeLabel != null;
}

/// A date this day's own title named, worked up into everything the date
/// sheet draws — `"Tokyo, 14 June" · 14 June · Sunday · day 1`.
///
/// Present only while the date is genuinely open: binding it, clearing it by
/// hand, or leaving it open all put the suggestion away. Working out the year
/// is this layer's one piece of arithmetic over the parser's refusal to guess
/// one; the rule is written on `PasteFlow._resolveCandidate`.
class DateSuggestion {
  /// The day's title as the person wrote it (`Tokyo, 14 June`).
  final String headerText;

  /// The date-shaped part of it (`14 June`) — the part to draw emphasized.
  final String fragment;

  /// The date one tap would bind.
  final DateTime date;

  /// `14 June`.
  final String dateLabel;

  /// `Sunday`.
  final String weekdayLabel;

  final int dayNumber;

  /// True when the title spelled the year out, so no year had to be worked
  /// out at all.
  final bool yearWasNamed;

  const DateSuggestion({
    required this.headerText,
    required this.fragment,
    required this.date,
    required this.dateLabel,
    required this.weekdayLabel,
    required this.dayNumber,
    required this.yearWasNamed,
  });
}

/// What tapping an ask chip does. Screens switch on this and call the
/// matching [PasteFlow] method; the actions carry only core types.
sealed class AskAction {
  const AskAction();
}

/// Set this day's date to a concrete candidate (call [PasteFlow.setDayDate]).
class UseDate extends AskAction {
  final DateTime date;
  const UseDate(this.date);
}

/// Let the person pick the date themselves (a platform date picker, then
/// [PasteFlow.setDayDate]).
class PickDate extends AskAction {
  final DateTime? initial;
  const PickDate({this.initial});
}

/// Read the whole paste against this year (call [PasteFlow.useYear]) — one
/// answer for every year-less date, because a plan speaks one year the same
/// way it speaks one date dialect.
class UseYear extends AskAction {
  final int year;
  const UseYear(this.year);
}

/// Accept the day as it stands (call [PasteFlow.confirmDay]).
class ConfirmAsIs extends AskAction {
  const ConfirmAsIs();
}

/// Add a stop to this day (collect the text, call [PasteFlow.addStop]).
class AddStop extends AskAction {
  const AddStop();
}

class DayAskOption {
  final String label;
  final AskAction action;

  const DayAskOption(this.label, this.action);
}

/// A day's surfaced doubt: the parser's own explanation, the cause-specific
/// question, and the one-tap answers.
class DayDoubt {
  final DayDoubtCause cause;

  /// The parser's person-showable sentence — what it saw and refused to guess.
  final String explanation;

  /// The cause-specific ask, worded per design round 8.
  final String ask;

  final List<DayAskOption> options;

  const DayDoubt({
    required this.cause,
    required this.explanation,
    required this.ask,
    required this.options,
  });
}

class ReviewDay {
  final int number;

  /// `Monday · Tokyo`, `"Thursday" · Kyoto` (quoted when the weekday is only
  /// what the plan *called* the day), `Kyoto`, or `Day 3`.
  final String title;

  /// The place alone, as the day editor puts it in a text field. Null when
  /// the header named none.
  final String? place;

  /// `14 June`, or null while the date is open.
  final String? dateLabel;

  /// The bound date, or null while it is open.
  final DateTime? date;

  /// The date this day's own title named and nobody has answered about yet.
  /// Null the rest of the time.
  final DateSuggestion? dateSuggestion;

  final List<ReviewStop> stops;
  final DayConfidence confidence;

  /// Null when the day reads clean — including when the person has already
  /// answered this day's ask.
  final DayDoubt? doubt;

  const ReviewDay({
    required this.number,
    required this.title,
    this.place,
    this.dateLabel,
    this.date,
    this.dateSuggestion,
    required this.stops,
    required this.confidence,
    this.doubt,
  });

  bool get needsEye => doubt != null;
}

/// A line kept out of the days — one the parser could not place, or one the
/// person took out of a day themselves. Both are the same promise: nothing
/// pasted is thrown away, and everything here can be dragged into a day.
class KeptAsideLine {
  final String id;
  final String text;
  final String explanation;

  /// True when this line is here because the person removed it, rather than
  /// because the parser could not place it.
  final bool removedByPerson;

  const KeptAsideLine({
    required this.id,
    required this.text,
    required this.explanation,
    this.removedByPerson = false,
  });
}

/// The person's own ambiguous date, spelled both ways, for the month-first
/// flip card to teach with.
///
/// The words are settled here rather than on the screen because this band is
/// where person-facing date spelling lives ([monthName], [ordinal]); the
/// screen arranges them and never re-derives one. A parse with no ambiguous
/// date has no example, and the card is not offered at all — which is the
/// same condition that used to be a separate `offerMonthFirstFix` flag, now
/// derived so the two cannot disagree.
class MonthFirstExample {
  /// `12/11` — the pair exactly as the person wrote it.
  final String asWritten;

  /// `12 November` — what [asWritten] means read day-first.
  final String dayFirstReading;

  /// `December 11th` — what it means read month-first.
  final String monthFirstReading;

  const MonthFirstExample({
    required this.asWritten,
    required this.dayFirstReading,
    required this.monthFirstReading,
  });
}

/// Everything the confirmation screen renders.
class ItineraryReview {
  final List<ReviewDay> days;
  final List<KeptAsideLine> keptAside;

  /// The plan's own first date that reads both ways round, or null when it
  /// has none. Its presence is the whole condition for offering the one-tap
  /// date-dialect re-read: only a date that genuinely changes under the flip
  /// makes the flip worth offering, and it is also the example the card
  /// teaches with.
  final MonthFirstExample? monthFirstExample;

  /// Whether the one-tap date-dialect re-read is worth offering at all.
  bool get offerMonthFirstFix => monthFirstExample != null;

  /// The dialect the paste is currently read in.
  final bool readMonthFirst;

  /// True when no day headers were found anywhere — the round-8
  /// "paste that wouldn't parse" state. [keptLines] then carries the pasted
  /// lines, shown kept rather than thrown away.
  final bool nothingRead;
  final List<String> keptLines;

  /// Why this read cannot be accepted, or null — the usual — when it can.
  ///
  /// One reason exists: the trip has closed, and its plan is half of the
  /// record it closed with (`docs/decisions/2026-08-26-the-ending.md`). The
  /// read itself is still shown in full, because there is nothing wrong with
  /// it and hiding what somebody just pasted would be the app arguing with
  /// them; what is absent is the accept, which is this project's treatment
  /// for anything that cannot fire.
  final String? refusal;

  /// True when this editor is open over a trip that is already running,
  /// rather than over a plan on its way in for the first time. The screen
  /// says "Save changes" instead of "Looks right", offers a cancel that
  /// leaves the live trip untouched, and offers the re-paste.
  final bool editingLivePlan;

  const ItineraryReview({
    required this.days,
    required this.keptAside,
    required this.monthFirstExample,
    required this.readMonthFirst,
    required this.nothingRead,
    required this.keptLines,
    this.refusal,
    this.editingLivePlan = false,
  });

  /// Whether "Looks right" is offered at all.
  bool get canAccept => refusal == null;

  int get totalStops => days.fold(0, (sum, day) => sum + day.stops.length);

  int get unsureCount => days.where((d) => d.needsEye).length;

  int get cleanCount => days.length - unsureCount;

  /// True once the person has taken something out of a day — the set-aside
  /// tile stops being only "lines I couldn't place" and has to say so.
  bool get anyRemovedByPerson => keptAside.any((l) => l.removedByPerson);
}

sealed class PasteFlowState {
  const PasteFlowState();
}

/// The paste screen: a text area and a parse action, nothing clever.
class PasteEditing extends PasteFlowState {
  /// Refilled when the person comes back via "Back to the paste", so the
  /// paste is visibly kept rather than thrown away — and pre-filled with the
  /// live plan said back as text on a re-paste.
  final String initialText;

  /// True when this box was opened over a running trip, holding that trip's
  /// own plan as text. Reading it merges rather than replaces, so the screen
  /// says so and offers the way back to the editor instead of the doors a
  /// first-time paste offers.
  final bool repastingLivePlan;

  const PasteEditing({this.initialText = '', this.repastingLivePlan = false});
}

/// The confirmation screen, showing what the parser understood.
class PasteReview extends PasteFlowState {
  final ItineraryReview review;

  const PasteReview(this.review);
}

// ---------------------------------------------------------------------------
// The draft — the read as the person is editing it, before it is accepted.
//
// Deliberately mutable and deliberately private: it is the one place an edit
// lands, and every [ItineraryReview] is built fresh from it, so no screen can
// hold a stale half of it.
// ---------------------------------------------------------------------------

class _DraftStop {
  _DraftStop({
    required this.id,
    required this.text,
    this.time,
    required this.sourceLineNumber,
    this.kind = model.StopKind.place,
    this.area,
    this.areaSource,
  });

  final String id;
  String text;
  model.ClockTime? time;
  model.StopKind kind;
  String? area;
  model.AreaSource? areaSource;

  /// Where this came from in the paste, or 0 for a stop the person typed.
  /// Carried so a stop set aside again lands back in the kept list with the
  /// line number it was pasted on.
  final int sourceLineNumber;
}

class _DraftDay {
  _DraftDay({
    required this.number,
    this.place,
    this.date,
    this.candidate,
    required this.confidence,
    this.uncertainty,
    this.headerWeekday,
    required this.stops,
  });

  final int number;
  String? place;
  DateTime? date;

  /// The date the day's own title named, as the parser reported it.
  final ip.DateCandidate? candidate;

  /// True once the person has answered about [candidate] — by binding it, by
  /// dating the day some other way, or by saying leave it open. The
  /// suggestion is offered once, not nagged.
  bool candidateAnswered = false;

  final ip.Confidence confidence;
  final ip.DayUncertainty? uncertainty;
  final int? headerWeekday;
  final List<_DraftStop> stops;

  /// True once the person has said this day reads right as it stands.
  bool confirmed = false;

  /// The stop count [confirmed] was last true for. A day whose stop count
  /// has since moved away from this is no longer answered for — emptiness is
  /// live state, not a verdict the parser or the person handed down once.
  int confirmedStopCount = 0;
}

class _DraftAside {
  _DraftAside({
    required this.id,
    required this.text,
    required this.explanation,
    required this.sourceLineNumber,
    this.time,
    this.removedByPerson = false,
  });

  final String id;
  final String text;
  final String explanation;
  final int sourceLineNumber;

  /// Kept so putting a removed stop back is lossless — its time comes with
  /// it.
  final model.ClockTime? time;
  final bool removedByPerson;
}

class _Draft {
  _Draft({required this.days, required this.aside});

  final List<_DraftDay> days;
  final List<_DraftAside> aside;
}

class _FoundStop {
  const _FoundStop(this.day, this.stop);
  final _DraftDay day;
  final _DraftStop stop;
}

// ---------------------------------------------------------------------------
// The notifier.
// ---------------------------------------------------------------------------

final pasteFlowProvider = NotifierProvider<PasteFlow, PasteFlowState>(
  PasteFlow.new,
);

/// True while the whole-plan editor is open over a trip that is already
/// running. The root screen watches it alongside the saved itinerary: with a
/// trip saved it draws the trip, unless this says the editor is over it.
///
/// This replaced the destructive hatch that used to live here. There is no
/// "paste a different plan" any more: the way to change a running trip's plan
/// is to edit it, and the way to re-read its text is to re-paste it, and
/// neither throws the trip away
/// (`data/cairn-ux/design-mock.html`, screen 3).
final planEditorProvider = NotifierProvider<PlanEditorOpen, bool>(
  PlanEditorOpen.new,
);

class PlanEditorOpen extends Notifier<bool> {
  @override
  bool build() => false;

  void open() => state = true;

  void close() => state = false;
}

class PasteFlow extends Notifier<PasteFlowState> {
  String _text = '';
  bool _monthFirst = false;

  /// Set by [useYear]: the parser resolves every year-less date against this,
  /// so one answer fixes the whole paste consistently.
  DateTime? _tripStartHint;

  /// The last read's two whole-paste verdicts, kept rather than the whole
  /// [ip.ParseResult]: a draft can also come from a live plan, which never
  /// had a parse result at all.
  bool _nothingRead = false;
  MonthFirstExample? _monthFirstExample;

  /// The read as it is being edited. Rebuilt from scratch by anything that
  /// re-reads the whole paste ([readMonthFirst], [useYear]): a re-read makes
  /// different stops, so the edits made to the old ones have nothing left to
  /// hold on to.
  _Draft? _draft;

  /// True while this editor is open over a trip that is already running.
  /// [accept] then applies the draft to the live trip and [cancelPlanEdit]
  /// drops it; the trip is untouched either way until the save.
  bool _editingLivePlan = false;

  /// True while the paste box is holding the live plan's own text. The next
  /// [parse] merges into the plan instead of replacing it.
  bool _repastingLivePlan = false;

  /// The plan the merge is against, frozen when the re-paste was asked for.
  /// Frozen rather than re-read so that flipping the date dialect re-merges
  /// the same two things instead of merging into its own last answer.
  List<ConfirmedDay>? _mergeBaseline;

  /// The set-aside tray as it stood when the re-paste was asked for. It is
  /// not written into the text (`renderPlanText` says why), so it is carried
  /// across the merge here — a re-paste displaces content, it never empties
  /// the tray.
  List<_DraftAside>? _mergeBaselineAside;

  var _nextId = 0;

  @override
  PasteFlowState build() => const PasteEditing();

  void parse(String text) {
    if (text.trim().isEmpty) return;
    _text = text;
    _monthFirst = false;
    _tripStartHint = null;
    // Over a running trip there is no such thing as a replacing read. If some
    // later route reaches the box without freezing a baseline, freeze one now
    // so the fall-through below is a merge and never an overwrite.
    if (_editingLivePlan && _mergeBaseline == null) _freezeMergeBaseline();
    if (_mergesInsteadOfReplacing) {
      _mergeReparse();
    } else {
      _reparse();
    }
  }

  /// **The one guard that keeps the destructive hatch shut.** While a running
  /// trip's plan is being edited, every read is a merge into that plan — not
  /// only the first one out of the paste box. A second read (the month-first
  /// flip, the year answer) that fell through to [_reparse] would replace the
  /// draft with a bare parse, and saving that would overwrite the trip and
  /// empty its set-aside: exactly the destruction this slice removed. The
  /// baseline is what makes it answerable, so the condition is the baseline
  /// and not the mode the paste box happens to be in.
  bool get _mergesInsteadOfReplacing =>
      _editingLivePlan && _mergeBaseline != null;

  /// The round-8 FixingIt one-tap: re-read the whole paste in the other date
  /// dialect. One flip for everything — a plan doesn't change dialect halfway
  /// through.
  void readMonthFirst(bool monthFirst) {
    _monthFirst = monthFirst;
    _readAgain();
  }

  /// One answer to "which year?": re-read with a trip-start hint so the
  /// parser itself resolves every year-less date, rather than this layer
  /// second-guessing it.
  void useYear(int year) {
    _tripStartHint = DateTime(year, 1, 1);
    _readAgain();
  }

  // -- editing a day -------------------------------------------------------

  /// Give a day its date.
  ///
  /// **Dating the first day dates the whole plan.** A trip's days are
  /// consecutive far more often than not, and the person who has just told
  /// the phone when day one is has already told it when every other day is;
  /// asking again, once per day, is asking a question that has an answer.
  /// So the first day's date runs down the plan — day two the day after, and
  /// so on — through [_fillDatesFromFirstDay].
  ///
  /// Every later day stays individually adjustable afterwards, and setting
  /// one of *those* changes only that day. The trade-off is deliberate and
  /// worth knowing: setting the first day's date **again** re-runs the fill,
  /// so it overwrites a later day someone had adjusted by hand. Day one is
  /// the anchor; moving the anchor moves the plan.
  void setDayDate(int dayNumber, DateTime date) {
    final day = _dayNumbered(dayNumber);
    if (day == null) return;
    day.date = DateTime(date.year, date.month, date.day);
    day.candidateAnswered = true;
    if (identical(day, _draft?.days.firstOrNull)) _fillDatesFromFirstDay();
    _rebuildReview();
  }

  /// Consecutive dates down the plan from the first day's.
  ///
  /// `DateTime` is what does the arithmetic, so a plan that runs off the end
  /// of a month or a year needs nothing said about it here. What is *not*
  /// done here is marking the days answered: the first day's date is not an
  /// answer to a later day's own question, and a day whose title named a date
  /// keeps that candidate. It simply stops being asked, the way any dated day
  /// does.
  void _fillDatesFromFirstDay() {
    final days = _draft?.days ?? const <_DraftDay>[];
    final first = days.firstOrNull?.date;
    if (first == null) return;
    for (final (offset, day) in days.indexed.skip(1)) {
      day.date = DateTime(first.year, first.month, first.day + offset);
    }
  }

  /// The date sheet's one-tap yes: bind the date the day's own title named.
  void useDateSuggestion(int dayNumber) {
    final day = _dayNumbered(dayNumber);
    final suggestion = day == null ? null : _suggestionFor(day);
    if (suggestion == null) return;
    setDayDate(dayNumber, suggestion.date);
  }

  /// The date sheet's quiet other answer, and the day editor's way to undate
  /// a day: the date goes back to open, and the suggestion is not offered
  /// again. An open date is a legitimate state — never a contradiction with
  /// a title that named one.
  void leaveDateOpen(int dayNumber) {
    final day = _dayNumbered(dayNumber);
    if (day == null) return;
    day.date = null;
    day.candidateAnswered = true;
    _rebuildReview();
  }

  /// Rename the day. An empty name is no name, not a day called "".
  void renameDay(int dayNumber, String? place) {
    final day = _dayNumbered(dayNumber);
    if (day == null) return;
    final trimmed = place?.trim();
    day.place = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    _rebuildReview();
  }

  void confirmDay(int dayNumber) {
    final day = _dayNumbered(dayNumber);
    if (day == null) return;
    day.confirmed = true;
    day.confirmedStopCount = day.stops.length;
    _rebuildReview();
  }

  /// Re-words the whole run of stops the area at [firstStopId] governs.
  ///
  /// A run is the stops from that one down to the next stop with a different
  /// area — which is the run the editor drew under one subheading, so
  /// correcting `Shinjuku` corrects everything the reader saw it standing
  /// over and nothing else.
  void setAreaRun(String firstStopId, String? area) {
    final found = _findStop(firstStopId);
    if (found == null) return;
    final day = found.day;
    final index = day.stops.indexWhere((s) => s.id == firstStopId);
    if (index < 0) return;
    final was = day.stops[index].area;
    for (var i = index; i < day.stops.length; i++) {
      if (day.stops[i].area != was) break;
      day.stops[i].area = area;
      day.stops[i].areaSource = area == null ? null : model.AreaSource.human;
    }
    _rebuildReview();
  }

  /// Sets one stop's area, and only that one. Null is an answer: it means
  /// "search for the words alone", not "nobody has said yet".
  void setStopArea(String stopId, String? area) {
    final found = _findStop(stopId);
    if (found == null) return;
    found.stop.area = area;
    found.stop.areaSource = area == null ? null : model.AreaSource.human;
    _rebuildReview();
  }

  // -- editing a stop ------------------------------------------------------

  void addStop(int dayNumber, String text) {
    final day = _dayNumbered(dayNumber);
    if (day == null) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    day.stops.add(
      _DraftStop(id: _mintId('stop'), text: trimmed, sourceLineNumber: 0),
    );
    _rebuildReview();
  }

  void editStopText(String stopId, String text) {
    final found = _findStop(stopId);
    final trimmed = text.trim();
    if (found == null || trimmed.isEmpty) return;
    found.stop.text = trimmed;
    _rebuildReview();
  }

  /// Give a stop a time, or take it away — which is also what stars it and
  /// unstars it, because a time is the only star rule there is.
  void setStopTime(String stopId, int hour, int minute) {
    final found = _findStop(stopId);
    if (found == null) return;
    found.stop.time = model.ClockTime(hour, minute);
    _rebuildReview();
  }

  void clearStopTime(String stopId) {
    final found = _findStop(stopId);
    if (found == null) return;
    found.stop.time = null;
    _rebuildReview();
  }

  /// Put [stopId] at position [toIndex] of day [toDayNumber].
  ///
  /// One method for both gestures on purpose: rearranging inside a day and
  /// moving to another day are the same drag, and the caller does not have to
  /// know which one it just made. [toIndex] is a slot in the day's list *as
  /// it stands now* — slot 0 is before the first stop, slot `length` is after
  /// the last — so a within-day move accounts for the stop leaving its old
  /// place first. Null means the end.
  void moveStop(String stopId, {required int toDayNumber, int? toIndex}) {
    final found = _findStop(stopId);
    final target = _dayNumbered(toDayNumber);
    if (found == null || target == null) return;
    final fromIndex = found.day.stops.indexOf(found.stop);
    var index = toIndex ?? target.stops.length;
    if (identical(found.day, target)) {
      if (index > fromIndex) index -= 1;
      if (index == fromIndex) return;
    }
    found.day.stops.removeAt(fromIndex);
    target.stops.insert(index.clamp(0, target.stops.length), found.stop);
    _rebuildReview();
  }

  /// Take a stop out of its day. **Never a delete**: it lands in the
  /// set-aside beside the lines the parser could not place, with its reason,
  /// and dragging it back into a day puts it back exactly as it was.
  void removeStop(String stopId) {
    final found = _findStop(stopId);
    if (found == null) return;
    found.day.stops.remove(found.stop);
    _draft!.aside.add(
      _DraftAside(
        id: _mintId('aside'),
        text: found.stop.text,
        explanation: removedByYouExplanation,
        sourceLineNumber: found.stop.sourceLineNumber,
        time: found.stop.time,
        removedByPerson: true,
      ),
    );
    _rebuildReview();
  }

  /// The other direction: a kept line becomes a stop of day [toDayNumber].
  /// The bullet a pasted line was written with is stripped the same way the
  /// parser strips one, so a restored line reads like every other stop.
  void restoreAside(String asideId, {required int toDayNumber, int? toIndex}) {
    final draft = _draft;
    final target = _dayNumbered(toDayNumber);
    if (draft == null || target == null) return;
    final index = draft.aside.indexWhere((l) => l.id == asideId);
    if (index < 0) return;
    final line = draft.aside.removeAt(index);
    target.stops.insert(
      (toIndex ?? target.stops.length).clamp(0, target.stops.length),
      _DraftStop(
        id: _mintId('stop'),
        text: ip.stripBullet(line.text),
        time: line.time,
        sourceLineNumber: line.sourceLineNumber,
      ),
    );
    _rebuildReview();
  }

  // -- editing a trip that is already running ------------------------------

  /// Opens this same editor over the live trip's plan
  /// (`data/cairn-ux/design-mock.html`, screen 3: "Edit the whole plan").
  ///
  /// **Nothing is written here.** The plan is copied into a draft, and the
  /// trip goes on being exactly what it was until [accept] saves the draft
  /// over it; [cancelPlanEdit] closes the editor and the trip never knew.
  void editLivePlan() {
    final plan = ref.read(savedItineraryProvider).value;
    if (plan == null) return;
    _text = '';
    _monthFirst = false;
    _tripStartHint = null;
    _repastingLivePlan = false;
    _nothingRead = false;
    _monthFirstExample = null;
    _nextId = 0;
    _editingLivePlan = true;
    _draft = _Draft(
      days: [
        for (final day in plan.days)
          _DraftDay(
            number: day.number,
            place: day.place,
            date: switch (day.date) {
              null => null,
              // The plan carries a bare calendar date at UTC midnight; the
              // draft speaks local wall dates, so it is read back field by
              // field rather than converted.
              final d => DateTime(d.year, d.month, d.day),
            },
            // A saved plan carries no parser doubt: every question it had was
            // answered before it was accepted. What it can still be is empty,
            // and `_emptiedDoubt` asks about that on its own.
            confidence: ip.Confidence.high,
            stops: [
              for (final stop in day.stops)
                _DraftStop(
                  id: _mintId('stop'),
                  text: stop.text,
                  time: _timeOf(stop.timeLabel),
                  sourceLineNumber: 0,
                  kind: stop.kind,
                  area: stop.area,
                  areaSource: stop.areaSource,
                ),
            ],
          ),
      ],
      aside: [
        for (final line in plan.keptAside)
          _DraftAside(
            id: _mintId('aside'),
            text: line.text,
            explanation: line.explanation,
            sourceLineNumber: line.sourceLineNumber,
            removedByPerson: setAsideCameFromThePerson(line.explanation),
          ),
      ],
    );
    ref.read(planEditorProvider.notifier).open();
    _rebuildReview();
  }

  /// The editor's other door: the paste box again, pre-filled with the plan
  /// as it now stands, said back as the text a person could have pasted.
  /// Reading it merges into the plan rather than replacing it.
  void repasteCurrentPlan() {
    if (_draft == null) return;
    _freezeMergeBaseline();
    _repastingLivePlan = true;
    _monthFirst = false;
    _tripStartHint = null;
    state = PasteEditing(
      initialText: renderPlanText(_mergeBaseline!),
      repastingLivePlan: true,
    );
  }

  /// The plan as it stands, frozen as the thing a re-read merges into. It is
  /// the *draft*, not the stored plan: edits made in the editor before asking
  /// for the text back are part of what the merge preserves, and a second
  /// read in the other date dialect re-merges these same two things rather
  /// than merging into its own last answer.
  ///
  /// **A degenerate draft never becomes the baseline.** A read that found no
  /// days at all leaves a draft with nothing in it, and freezing *that* would
  /// leave an empty plan to merge into — a replacement wearing a merge's
  /// clothes, which is the hatch this slice removed. The last real plan is
  /// kept instead.
  void _freezeMergeBaseline() {
    final draft = _draft;
    if (draft == null) return;
    final frozen = _asConfirmedDays(draft);
    if (frozen.isEmpty && _mergeBaseline != null) return;
    _mergeBaseline = frozen;
    _mergeBaselineAside = List.of(draft.aside);
  }

  /// Out of the paste box and back into the editor, the plan as it was before
  /// the re-paste was asked for. Nothing has been merged, so there is nothing
  /// to undo.
  ///
  /// The frozen baseline stays frozen: while a live plan is being edited,
  /// once there is a baseline there is always a baseline, so every read from
  /// here on is a merge whichever door it came through.
  void cancelRepaste() {
    if (!_repastingLivePlan) return;
    _repastingLivePlan = false;
    _rebuildReview();
  }

  /// Closes the whole-plan editor without saving. The live trip is exactly
  /// what it was; this is the promise the entry on the trip sheet makes.
  void cancelPlanEdit() {
    _editingLivePlan = false;
    _repastingLivePlan = false;
    _mergeBaseline = null;
    _mergeBaselineAside = null;
    _forgetThePaste();
    ref.read(planEditorProvider.notifier).close();
  }

  // -- leaving -------------------------------------------------------------

  /// Back to the paste box, the current paste kept.
  ///
  /// Over a running trip there is no such thing as a fresh paste, so this is
  /// the re-paste: the box comes back holding the plan, and reading it merges.
  /// **This is load-bearing.** Every route from the editor back to the paste
  /// box goes through here or through [repasteCurrentPlan], and if one of them
  /// left the flow in replace mode, reading again would overwrite the trip —
  /// which is exactly the hatch this slice removed.
  void startOver() {
    if (_editingLivePlan) {
      repasteCurrentPlan();
      return;
    }
    state = PasteEditing(initialText: _text);
  }

  /// The way out of the nothing-read state: the box again, holding the text
  /// that was just read rather than the plan said back.
  ///
  /// Over a running trip this is the one route that must *not* re-freeze the
  /// baseline. The draft that produced a nothing-read has no days in it, so
  /// re-freezing would hand back an empty box and an empty plan to merge
  /// into; the baseline the re-paste froze is still the right one, and the
  /// text the person is being given back is the one that failed to read.
  void backToTheText() {
    if (!_editingLivePlan) {
      state = PasteEditing(initialText: _text);
      return;
    }
    if (_mergeBaseline == null) _freezeMergeBaseline();
    _repastingLivePlan = true;
    state = PasteEditing(initialText: _text, repastingLivePlan: true);
  }

  /// The trip has been deleted, so the flow that made it starts again from
  /// nothing. Deliberately not [startOver], which keeps the paste: deleting
  /// is the one act that means gone, and handing back the plan somebody
  /// just deleted would be the app arguing with them.
  void forget() {
    _editingLivePlan = false;
    _repastingLivePlan = false;
    _mergeBaseline = null;
    _mergeBaselineAside = null;
    _forgetThePaste();
    ref.read(planEditorProvider.notifier).close();
  }

  void _forgetThePaste() {
    _text = '';
    _monthFirst = false;
    _tripStartHint = null;
    _nothingRead = false;
    _monthFirstExample = null;
    _draft = null;
    state = const PasteEditing();
  }

  /// Persists the confirmation through the seam — the draft as the person
  /// left it, not the parse it started as. The itinerary is local-only in
  /// this slice; syncing it as a shared fact is later work
  /// (docs/decisions/2026-08-22-grill-round-one.md §2).
  ///
  /// One thing the draft holds that the store does not: a set-aside line's
  /// time. `itinerary_set_asides` has no time column, so a starred stop that
  /// was set aside — by hand or by a re-paste displacing it — keeps its time
  /// until this save and no further; dragging it back after a reopen restores
  /// it unstarred. Pre-existing, and deliberately left for the schema change
  /// that closes it.
  Future<void> accept() async {
    final draft = _draft;
    if (draft == null) return;
    // An archived trip's plan is fixed. Accepting here would call
    // `saveItinerary`, which replaces the saved plan wholesale, so this is
    // the write the read-only archive is actually protecting — the paste box
    // being unreachable is how it usually never comes up.
    if (ref.read(tripStandingProvider).isReadOnly) return;
    final itinerary = ConfirmedItinerary(
      days: [
        for (final day in draft.days)
          ConfirmedDay(
            number: day.number,
            date: switch (day.date) {
              null => null,
              final d => model.CalendarDate.fromDateTimeIgnoringZone(d),
            },
            place: day.place,
            stops: [
              for (final stop in day.stops)
                model.Stop(
                  text: stop.text,
                  time: stop.time,
                  kind: stop.kind,
                  area: stop.area,
                  areaSource: stop.areaSource,
                ),
            ],
          ),
      ],
      keptAside: [
        for (final line in draft.aside)
          KeptLine(
            sourceLineNumber: line.sourceLineNumber,
            text: line.text,
            explanation: line.explanation,
          ),
      ],
    );
    // Who the trip is started under is [_tripStarter]'s one decision: a
    // stand-in launch whose account has answered by now adopts it here
    // rather than writing a roster the account is not on. Asked before the
    // first write, so its bounded wait never sits between the saved plan
    // and the roster that goes with it.
    final starter = await _tripStarter();
    await ref.read(tripRepositoryProvider).saveItinerary(itinerary);
    // Accepting the plan is what starts the trip: it is the only door, and
    // the person who accepted it is its starter — a fact about the trip
    // rather than a rank on them (docs/decisions/2026-08-22-last-calls.md
    // §1). It is idempotent, so pasting a different plan replaces the
    // itinerary without starting a second trip or minting a second code.
    // Nothing here names the trip's id: the store mints one where it writes
    // the row (docs/decisions/2026-08-25-the-trip-mints-its-own-id.md), so
    // accepting a plan with the phone in flight mode still produces a trip
    // with a real, durable id.
    await ref
        .read(membershipStoreProvider)
        .startTrip(
          starter: starter,
          starterDisplayName: localMemberName,
          now: ref.read(nowProvider),
        );
    // The pending import has become the trip: there is nothing left for it
    // to protect, and a draft that outlived its accept would be offered back
    // the next time the box opened empty (`plan_draft.dart`).
    await ref.read(planDraftProvider).forget();
    _editingLivePlan = false;
    _repastingLivePlan = false;
    _mergeBaseline = null;
    _mergeBaselineAside = null;
    ref.read(planEditorProvider.notifier).close();
  }

  /// Who the trip about to be started belongs to.
  ///
  /// Usually just who this launch is — but a launch that began as the
  /// stand-in on a build whose backend simply had not answered yet
  /// (`lateAccountResolverProvider` is bound exactly then) gets one bounded
  /// last chance here, at the only moment adoption is still free: **before
  /// any trip exists**, so nothing has been credited to anybody and no
  /// roster can disagree with the new identity. If the account has landed,
  /// the launch adopts it (`launchIdentityProvider`) and the trip is started
  /// under it, so the stand-in roster is never written at all. If it has
  /// not — offline, or no backend — the trip starts under the stand-in
  /// exactly as before, and the composition root's heal repairs it on the
  /// next launch. Once a trip holds an identity, this never runs again for
  /// the life of the trip: the launch stays coherent with the roster it has.
  Future<model.MemberId> _tripStarter() async {
    final starter = ref.read(localMemberIdProvider);
    if (starter != localMemberId) return model.MemberId(starter);
    final resolve = ref.read(lateAccountResolverProvider);
    if (resolve == null) return model.MemberId(starter);
    if (await ref.read(membershipStoreProvider).hasTrip()) {
      return model.MemberId(starter);
    }
    final landed = await resolve();
    if (landed == null || landed.isEmpty || landed == localMemberId) {
      return model.MemberId(starter);
    }
    ref.read(launchIdentityProvider.notifier).adopt(landed);
    return model.MemberId(landed);
  }

  // -- internals -----------------------------------------------------------

  String _mintId(String prefix) => '$prefix-${_nextId++}';

  _DraftDay? _dayNumbered(int number) {
    for (final day in _draft?.days ?? const <_DraftDay>[]) {
      if (day.number == number) return day;
    }
    return null;
  }

  _FoundStop? _findStop(String id) {
    for (final day in _draft?.days ?? const <_DraftDay>[]) {
      for (final stop in day.stops) {
        if (stop.id == id) return _FoundStop(day, stop);
      }
    }
    return null;
  }

  /// A whole-paste re-read, in whichever of the two modes is running: a first
  /// paste replaces the draft, a re-paste of a live plan merges into it.
  void _readAgain() {
    // A draft built from the store came from no text at all, so there is
    // nothing to read again — and a fall-through to [_reparse] here would
    // throw that draft away.
    if (_editingLivePlan && _mergeBaseline == null) return;
    if (_mergesInsteadOfReplacing) {
      _mergeReparse();
    } else {
      _reparse();
    }
  }

  /// Spells the parse's own ambiguous date both ways round, or null when the
  /// paste had none. `12/11` becomes `12 November` day-first and
  /// `December 11th` month-first — the two readings the flip moves between.
  MonthFirstExample? _exampleFrom(ip.AmbiguousNumericDate? date) {
    if (date == null) return null;
    return MonthFirstExample(
      asWritten: date.asWritten,
      dayFirstReading: '${date.dayFirstDay} ${monthName(date.dayFirstMonth)}',
      monthFirstReading:
          '${monthName(date.monthFirstMonth)} ${ordinal(date.monthFirstDay)}',
    );
  }

  ip.ParseResult _parseText() {
    final result = ip.parseItinerary(
      _text,
      tripStartDate: _tripStartHint,
      monthFirstNumericDates: _monthFirst,
      // The C10 validator, when there is one to validate against. It is
      // null until an import has loaded it (area_gazetteer_loader.dart holds
      // the whole rule), and null is not a degraded case to guard against:
      // it is phase-1 behaviour exactly, which is what a plan typed by hand
      // has always got and what the parser's C7t floors are pinned to.
      gazetteer: ref.read(areaGazetteerProvider),
    );
    _nothingRead = result.usedHeaderlessFallback || result.days.isEmpty;
    _monthFirstExample = _exampleFrom(result.firstAmbiguousNumericDate);
    return result;
  }

  /// The re-paste's one act: hand the plan and the re-read to
  /// [merge.mergeRepaste] and build the draft from what comes back.
  ///
  /// **Every merge decision is inside that call** — which day keeps which
  /// number, what a day inherits when the text did not say it, and what is
  /// displaced. Nothing here re-decides any of it; this end carries the
  /// answer into the draft and carries the tray across, so swapping the
  /// module underneath is a file replacement.
  ///
  /// The parse's doubt has to survive the merge, for the days that never had
  /// it answered. A day the re-paste **adds** is an unconfirmed read: its
  /// title-named date ([merge.MergedDay.dateCandidate]), and equally the
  /// parser's [merge.MergedDay.confidence], [merge.MergedDay.uncertainty] and
  /// [merge.MergedDay.headerWeekday], all ride across so the phone asks about
  /// it exactly as it would on a first paste — dropping them draws `Nara, 17
  /// June` or `Sat - Nara` as a clean day and saves it with its date silently
  /// open. A day the plan already held carries none of it, because the person
  /// answered for that day before it was accepted; the merge is what draws
  /// that line.
  ///
  /// All four are read off the merged day and never off `result.days` by
  /// index: the merge returns the current plan's days first and the appended
  /// ones after, so the two lists do not line up.
  void _mergeReparse() {
    final baseline = _mergeBaseline;
    if (baseline == null) return;
    final result = _parseText();
    final merged = merge.mergeRepaste(current: baseline, repasted: result.days);
    _nextId = 0;
    _draft = _Draft(
      days: [
        for (final day in merged.days)
          _DraftDay(
            number: day.number,
            place: day.place,
            date: _asDateTime(day.date),
            candidate: day.dateCandidate,
            // The parser's verdict, as the merge reports it per day: real for
            // a day the re-paste *added* (nobody has confirmed it, so `Sat -
            // Nara` must be asked about rather than drawn clean and saved
            // date-open), and high-with-no-doubt for a day the plan already
            // held, which was answered before it was ever accepted. The merge
            // decides which is which — `merge.MergedDay.confidence` carries
            // the reasoning — and nothing here re-decides it.
            confidence: day.confidence,
            uncertainty: day.uncertainty,
            headerWeekday: day.headerWeekday,
            stops: [
              for (final stop in day.stops)
                _DraftStop(
                  id: _mintId('stop'),
                  text: stop.text,
                  time: stop.time,
                  sourceLineNumber: 0,
                ),
            ],
          ),
      ],
      aside: [
        // The tray as it stood, then what the merge displaced, then what the
        // re-read itself could not place. Three sources, one promise.
        for (final line in _mergeBaselineAside ?? const <_DraftAside>[])
          _DraftAside(
            id: _mintId('aside'),
            text: line.text,
            explanation: line.explanation,
            sourceLineNumber: line.sourceLineNumber,
            time: line.time,
            removedByPerson: line.removedByPerson,
          ),
        for (final line in merged.setAside)
          _DraftAside(
            id: _mintId('aside'),
            text: line.stop.text,
            explanation: line.explanation,
            sourceLineNumber: 0,
            time: line.stop.time,
            removedByPerson: setAsideCameFromThePerson(line.explanation),
          ),
        for (final line in result.unplacedLines)
          _DraftAside(
            id: _mintId('aside'),
            text: line.sourceLine.text.trim(),
            explanation: line.reason.explanation,
            sourceLineNumber: line.sourceLine.lineNumber,
          ),
      ],
    );
    _repastingLivePlan = false;
    _rebuildReview();
  }

  /// The draft as the merge reads a plan. The one place the two vocabularies
  /// meet: the merge speaks [ConfirmedDay], the same shape the repository
  /// saves, so nothing here invents a third.
  List<ConfirmedDay> _asConfirmedDays(_Draft draft) => [
    for (final day in draft.days)
      ConfirmedDay(
        number: day.number,
        date: _asCalendarDate(day.date),
        place: day.place,
        stops: [
          for (final stop in day.stops)
            model.Stop(text: stop.text, time: stop.time),
        ],
      ),
  ];

  static model.CalendarDate? _asCalendarDate(DateTime? date) =>
      date == null ? null : model.CalendarDate.fromDateTimeIgnoringZone(date);

  static DateTime? _asDateTime(model.CalendarDate? date) =>
      date == null ? null : DateTime(date.year, date.month, date.day);

  static model.ClockTime? _timeOf(String? iso) {
    if (iso == null) return null;
    final parts = iso.split(':');
    return model.ClockTime(int.parse(parts[0]), int.parse(parts[1]));
  }

  void _reparse() {
    final result = _parseText();
    _nextId = 0;
    _draft = _Draft(
      days: [
        for (final day in result.days)
          _DraftDay(
            number: day.index,
            place: day.place,
            date: day.date,
            candidate: day.dateCandidate,
            confidence: day.confidence,
            uncertainty: day.uncertainty,
            headerWeekday: day.headerWeekday,
            stops: [
              for (final stop in day.stops)
                _DraftStop(
                  id: _mintId('stop'),
                  text: stop.text,
                  time: switch (stop.time) {
                    null => null,
                    final t => model.ClockTime(t.hour, t.minute),
                  },
                  sourceLineNumber: stop.sourceLine.lineNumber,
                  kind: stopKindOf(stop.kind),
                  area: stop.area?.text,
                  areaSource: stop.area == null
                      ? null
                      : areaSourceOf(stop.area!.source),
                ),
            ],
          ),
      ],
      aside: [
        for (final line in result.unplacedLines)
          _DraftAside(
            id: _mintId('aside'),
            text: line.sourceLine.text.trim(),
            explanation: line.reason.explanation,
            sourceLineNumber: line.sourceLine.lineNumber,
          ),
      ],
    );
    _rebuildReview();
  }

  void _rebuildReview() {
    final draft = _draft;
    if (draft == null) return;
    final nothingRead = _nothingRead;
    state = PasteReview(
      ItineraryReview(
        days: nothingRead
            ? const []
            : [for (final day in draft.days) _buildDay(day, draft)],
        keptAside: [
          for (final line in draft.aside)
            KeptAsideLine(
              id: line.id,
              text: line.text,
              explanation: line.explanation,
              removedByPerson: line.removedByPerson,
            ),
        ],
        monthFirstExample: _monthFirstExample,
        readMonthFirst: _monthFirst,
        nothingRead: nothingRead,
        keptLines: nothingRead
            ? [
                for (final line in _text.split('\n'))
                  if (line.trim().isNotEmpty) line.trim(),
              ]
            : const [],
        refusal: ref.read(tripStandingProvider).isReadOnly
            ? 'This trip has closed, so its plan cannot be replaced — what '
                  'it holds is the record it closed with. The paste is here '
                  'if you want to read it back.'
            : null,
        editingLivePlan: _editingLivePlan,
      ),
    );
  }

  ReviewDay _buildDay(_DraftDay day, _Draft draft) {
    final doubt = _doubtFor(day, draft);
    return ReviewDay(
      number: day.number,
      title: _titleFor(day),
      place: day.place,
      dateLabel: day.date == null ? null : dayMonthLabel(day.date!),
      date: day.date,
      dateSuggestion: _suggestionFor(day),
      stops: [
        for (final stop in day.stops)
          ReviewStop(
            id: stop.id,
            text: stop.text,
            timeLabel: stop.time?.iso,
            kind: stop.kind,
            area: stop.area,
            areaSource: stop.areaSource,
          ),
      ],
      confidence: doubt == null
          ? DayConfidence.high
          : switch (day.confidence) {
              ip.Confidence.high => DayConfidence.high,
              ip.Confidence.medium => DayConfidence.medium,
              ip.Confidence.low => DayConfidence.low,
            },
      doubt: doubt,
    );
  }

  String _titleFor(_DraftDay day) {
    final date = day.date;
    final String? weekdayPart;
    if (date != null) {
      weekdayPart = weekdayName(date.weekday);
    } else if (day.headerWeekday != null) {
      // Quoted: this is only what the plan *called* the day.
      weekdayPart = '"${weekdayName(day.headerWeekday!)}"';
    } else {
      weekdayPart = null;
    }
    final place = day.place;
    if (weekdayPart != null && place != null) return '$weekdayPart · $place';
    if (weekdayPart != null) return weekdayPart;
    if (place != null) return place;
    return 'Day ${day.number}';
  }

  /// The one-tap date offer for a day whose own title named a date, or null
  /// when there is nothing to offer: no candidate, a date already bound, or
  /// the person has already answered about it.
  DateSuggestion? _suggestionFor(_DraftDay day) {
    final candidate = day.candidate;
    if (candidate == null || day.candidateAnswered || day.date != null) {
      return null;
    }
    final date = _resolveCandidate(candidate);
    return DateSuggestion(
      headerText: candidate.headerText,
      fragment: candidate.text,
      date: date,
      dateLabel: dayMonthLabel(date),
      weekdayLabel: weekdayName(date.weekday),
      dayNumber: day.number,
      yearWasNamed: candidate.year != null,
    );
  }

  /// **The year rule.** The parser will not guess a year, and neither does
  /// this: `14 June` is offered in the year the rest of the plan is already
  /// in — the first date bound anywhere in it — and only when *nothing* in
  /// the plan is dated does the device's own date answer instead. A date
  /// that would then sit more than a month behind that reference means next
  /// year's one, which is the rolling rule the parser applies to a year-less
  /// date header.
  ///
  /// The sheet shows the weekday it worked out, so a year worked out wrong is
  /// visible before it is bound rather than after.
  DateTime _resolveCandidate(ip.DateCandidate candidate) {
    if (candidate.year != null) return candidate.inYear(candidate.year!);
    final reference = _yearReference();
    final inReferenceYear = candidate.inYear(reference.year);
    return inReferenceYear.difference(reference).inDays < -30
        ? candidate.inYear(reference.year + 1)
        : inReferenceYear;
  }

  DateTime _yearReference() {
    for (final day in _draft?.days ?? const <_DraftDay>[]) {
      final date = day.date;
      if (date != null) return DateTime(date.year, date.month, date.day);
    }
    final today = ref.read(todayProvider);
    return DateTime(today.year, today.month, today.day);
  }

  /// The surfaced doubt for a day, or null when it reads clean — either the
  /// parser was sure, or the person has answered.
  DayDoubt? _doubtFor(_DraftDay day, _Draft draft) {
    if (day.confirmed) {
      if (day.stops.length == day.confirmedStopCount) return null;
      final doubt = _emptiedDoubt(day);
      if (doubt == null) day.confirmedStopCount = day.stops.length;
      return doubt;
    }

    final uncertainty = day.uncertainty;
    if (uncertainty == null) return _emptiedDoubt(day);

    switch (uncertainty) {
      case ip.DayUncertainty.weekdayWithoutDate:
      case ip.DayUncertainty.dateWithoutYear:
        // A date answered — picked directly, or resolved by a whole-paste
        // year re-read — closes the question.
        if (day.date != null) return _emptiedDoubt(day);
      case ip.DayUncertainty.noStops:
        // Anything in the day answers it, however it got there: typed in, or
        // dragged in from another day or from the set-aside.
        if (day.stops.isNotEmpty) return null;
        return _emptyDayDoubt(ip.DayUncertainty.noStops.explanation);
      case ip.DayUncertainty.barePlaceName:
        break;
      case ip.DayUncertainty.headerlessBlock:
        // Handled at review level as the nothing-read state; a per-day ask
        // would be asking the wrong question.
        return null;
    }

    return switch (uncertainty) {
      ip.DayUncertainty.weekdayWithoutDate => _weekdayDoubt(
        day,
        draft,
        uncertainty.explanation,
      ),
      ip.DayUncertainty.dateWithoutYear => _yearDoubt(uncertainty.explanation),
      ip.DayUncertainty.barePlaceName => DayDoubt(
        cause: DayDoubtCause.barePlaceName,
        explanation: uncertainty.explanation,
        ask:
            'Nothing in the text marked '
            '${day.place == null ? 'this line' : '"${day.place}"'} as its '
            'own day — it read like one from where it sits. Your call:',
        options: const [DayAskOption("It's a day", ConfirmAsIs())],
      ),
      // Answered above, either way.
      ip.DayUncertainty.noStops => null,
      // Unreachable: mapped to the nothing-read state above.
      ip.DayUncertainty.headerlessBlock => null,
    };
  }

  /// A day the person emptied asks the same question a day that arrived empty
  /// asks. Emptiness is a live state, not a verdict the parser handed down, so
  /// a day whose last stop was dragged onto another day says so rather than
  /// sitting there looking finished.
  DayDoubt? _emptiedDoubt(_DraftDay day) => day.stops.isEmpty
      ? _emptyDayDoubt('Nothing is under this day now.')
      : null;

  DayDoubt _emptyDayDoubt(String explanation) => DayDoubt(
    cause: DayDoubtCause.noStops,
    explanation: explanation,
    ask:
        'Found the day, nothing in it. A rest day — or does something '
        'belong here?',
    options: const [
      DayAskOption('+ Add a stop', AddStop()),
      DayAskOption('leave it empty', ConfirmAsIs()),
    ],
  );

  DayDoubt _weekdayDoubt(_DraftDay day, _Draft draft, String explanation) {
    final named = day.headerWeekday!;
    final candidate = _candidateDateFor(day, draft);

    if (candidate == null) {
      return DayDoubt(
        cause: DayDoubtCause.weekdayWithoutDate,
        explanation: explanation,
        ask:
            'The plan calls this one ${weekdayName(named)}, and no date '
            "nearby pins down which ${weekdayName(named)} — I don't guess "
            'dates. Your call:',
        options: const [DayAskOption('Pick the date', PickDate())],
      );
    }

    if (candidate.weekday == named) {
      // The named weekday agrees with where the day sits — the sanity check
      // headerWeekday exists for. Offer the candidate; leave the door open.
      return DayDoubt(
        cause: DayDoubtCause.weekdayWithoutDate,
        explanation: explanation,
        ask:
            'The plan calls this one ${weekdayName(named)}. Where it sits, '
            "that's ${dayMonthLabel(candidate)} — and it is a "
            "${weekdayName(named)}. I still don't guess dates. Your call:",
        options: [
          DayAskOption(
            "It's the ${ordinal(candidate.day)}",
            UseDate(candidate),
          ),
          DayAskOption('A different date', PickDate(initial: candidate)),
        ],
      );
    }

    // Mismatch — round 8's drawn case: offer where it sits, and the nearest
    // date that actually is the named weekday.
    final moved = _nearestWeekday(candidate, named);
    return DayDoubt(
      cause: DayDoubtCause.weekdayWithoutDate,
      explanation: explanation,
      ask:
          'The plan calls this one ${weekdayName(named)}. Where it sits, '
          "it'd be the ${ordinal(candidate.day)} — a "
          "${weekdayName(candidate.weekday)} — and I don't guess dates. "
          'Your call:',
      options: [
        DayAskOption("It's the ${ordinal(candidate.day)}", UseDate(candidate)),
        DayAskOption(
          'Move it to ${weekdayAbbrev(named)} the ${ordinal(moved.day)}',
          UseDate(moved),
        ),
      ],
    );
  }

  DayDoubt _yearDoubt(String explanation) {
    final thisYear = ref.read(todayProvider).year;
    return DayDoubt(
      cause: DayDoubtCause.dateWithoutYear,
      explanation: explanation,
      ask:
          'The plan gives a day and a month but never a year, and I '
          "don't guess years. One answer covers every date in the paste:",
      options: [
        DayAskOption("It's $thisYear", UseYear(thisYear)),
        DayAskOption("It's ${thisYear + 1}", UseYear(thisYear + 1)),
      ],
    );
  }

  /// Where the day would land if the days run consecutively: counted off the
  /// nearest neighbour that has a date. Offered as a chip, never assumed.
  DateTime? _candidateDateFor(_DraftDay day, _Draft draft) {
    final position = draft.days.indexOf(day);
    for (var i = position - 1; i >= 0; i--) {
      final date = draft.days[i].date;
      if (date != null) return date.add(Duration(days: position - i));
    }
    for (var i = position + 1; i < draft.days.length; i++) {
      final date = draft.days[i].date;
      if (date != null) return date.subtract(Duration(days: i - position));
    }
    return null;
  }

  /// The occurrence of [isoWeekday] nearest to [around] (never [around]
  /// itself; callers only ask on a mismatch).
  DateTime _nearestWeekday(DateTime around, int isoWeekday) {
    final forward = (isoWeekday - around.weekday + 7) % 7;
    final backward = (around.weekday - isoWeekday + 7) % 7;
    return forward <= backward
        ? around.add(Duration(days: forward))
        : around.subtract(Duration(days: backward));
  }
}
