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

import '../repositories/trip_repository.dart';
import 'date_labels.dart';
import 'day_view.dart';
import 'ping_schedule.dart';
import 'trip_providers.dart';

/// The reason a set-aside line carries when the person took it out of a day
/// themselves. Spelled once: it is persisted with the accepted plan, shown in
/// the set-aside tile, and asserted in tests.
const removedByYouExplanation =
    'Removed by you — kept here, not deleted. Drag it back into a day to '
    'put it back.';

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

  const ReviewStop({required this.id, required this.text, this.timeLabel});

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

/// Everything the confirmation screen renders.
class ItineraryReview {
  final List<ReviewDay> days;
  final List<KeptAsideLine> keptAside;

  /// Whether the one-tap date-dialect re-read is worth offering at all —
  /// true only when some recognized numeric date genuinely changes under
  /// the flip.
  final bool offerMonthFirstFix;

  /// The dialect the paste is currently read in.
  final bool readMonthFirst;

  /// True when no day headers were found anywhere — the round-8
  /// "paste that wouldn't parse" state. [keptLines] then carries the pasted
  /// lines, shown kept rather than thrown away.
  final bool nothingRead;
  final List<String> keptLines;

  const ItineraryReview({
    required this.days,
    required this.keptAside,
    required this.offerMonthFirstFix,
    required this.readMonthFirst,
    required this.nothingRead,
    required this.keptLines,
  });

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
  /// Refilled when the person comes back via "Paste something else", so the
  /// paste is visibly kept rather than thrown away.
  final String initialText;

  const PasteEditing({this.initialText = ''});
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
  });

  final String id;
  String text;
  model.ClockTime? time;

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

/// **Temporary.** True while the person has asked to paste a different plan
/// from the day page, which is the only way back to the paste box once an
/// itinerary is saved. The real container — the Trail, the Pool and the tab
/// bar between them — arrives with those slices and takes this over; until
/// then the root screen watches this alongside the saved itinerary.
final repasteRequestedProvider = NotifierProvider<RepasteRequest, bool>(
  RepasteRequest.new,
);

class RepasteRequest extends Notifier<bool> {
  @override
  bool build() => false;

  void request() => state = true;

  void clear() => state = false;
}

class PasteFlow extends Notifier<PasteFlowState> {
  String _text = '';
  bool _monthFirst = false;

  /// Set by [useYear]: the parser resolves every year-less date against this,
  /// so one answer fixes the whole paste consistently.
  DateTime? _tripStartHint;

  ip.ParseResult? _result;

  /// The read as it is being edited. Rebuilt from scratch by anything that
  /// re-reads the whole paste ([readMonthFirst], [useYear]): a re-read makes
  /// different stops, so the edits made to the old ones have nothing left to
  /// hold on to.
  _Draft? _draft;

  var _nextId = 0;

  @override
  PasteFlowState build() => const PasteEditing();

  void parse(String text) {
    if (text.trim().isEmpty) return;
    _text = text;
    _monthFirst = false;
    _tripStartHint = null;
    _reparse();
  }

  /// The round-8 FixingIt one-tap: re-read the whole paste in the other date
  /// dialect. One flip for everything — a plan doesn't change dialect halfway
  /// through.
  void readMonthFirst(bool monthFirst) {
    _monthFirst = monthFirst;
    _reparse();
  }

  /// One answer to "which year?": re-read with a trip-start hint so the
  /// parser itself resolves every year-less date, rather than this layer
  /// second-guessing it.
  void useYear(int year) {
    _tripStartHint = DateTime(year, 1, 1);
    _reparse();
  }

  // -- editing a day -------------------------------------------------------

  void setDayDate(int dayNumber, DateTime date) {
    final day = _dayNumbered(dayNumber);
    if (day == null) return;
    day.date = DateTime(date.year, date.month, date.day);
    day.candidateAnswered = true;
    _rebuildReview();
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

  // -- leaving -------------------------------------------------------------

  /// Back to the paste box, the current paste kept.
  void startOver() {
    state = PasteEditing(initialText: _text);
  }

  /// **Temporary**, until a trip can be re-read without being thrown away:
  /// the one way back to the paste box. Hands the person an empty paste box;
  /// accepting there replaces the saved plan.
  void pasteAnother() {
    _forgetThePaste();
    ref.read(repasteRequestedProvider.notifier).request();
  }

  /// The trip has been deleted, so the flow that made it starts again from
  /// nothing. Deliberately not [startOver], which keeps the paste: deleting
  /// is the one act that means gone, and handing back the plan somebody
  /// just deleted would be the app arguing with them.
  void forget() {
    _forgetThePaste();
    ref.read(repasteRequestedProvider.notifier).clear();
  }

  void _forgetThePaste() {
    _text = '';
    _monthFirst = false;
    _tripStartHint = null;
    _result = null;
    _draft = null;
    state = const PasteEditing();
  }

  /// Persists the confirmation through the seam — the draft as the person
  /// left it, not the parse it started as. The itinerary is local-only in
  /// this slice; syncing it as a shared fact is later work
  /// (docs/decisions/2026-08-22-grill-round-one.md §2).
  Future<void> accept() async {
    final draft = _draft;
    if (draft == null) return;
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
                model.Stop(text: stop.text, time: stop.time),
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
          starter: model.MemberId(localMemberId),
          starterDisplayName: localMemberName,
          now: ref.read(nowProvider),
        );
    ref.read(repasteRequestedProvider.notifier).clear();
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

  void _reparse() {
    final result = ip.parseItinerary(
      _text,
      tripStartDate: _tripStartHint,
      monthFirstNumericDates: _monthFirst,
    );
    _result = result;
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
    final result = _result;
    final draft = _draft;
    if (result == null || draft == null) return;
    final nothingRead = result.usedHeaderlessFallback || result.days.isEmpty;
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
        offerMonthFirstFix: result.hasAmbiguousNumericDates,
        readMonthFirst: _monthFirst,
        nothingRead: nothingRead,
        keptLines: nothingRead
            ? [
                for (final line in _text.split('\n'))
                  if (line.trim().isNotEmpty) line.trim(),
              ]
            : const [],
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
    if (day.confirmed) return null;

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
