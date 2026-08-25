// APP STATE band (docs/architecture.md): the paste-and-confirm flow's state.
//
// This file is the flow's whole brain: it owns the pasted text, runs the
// parser (the DOMAIN band — screens never name it), applies the person's
// corrections, and persists the accepted itinerary through the seam. The
// screens render the view models defined here and call the notifier's
// methods; every type they see is declared in this band.
//
// The shape of what gets shown is design round 8's
// (docs/design/2026-08-22-round8-handoff.zip): the confident read, the doubt
// surfaced per day with cause-specific copy, the one-tap month-first re-read,
// the kept-aside lines with reasons, and the paste that could not be read.
import 'package:cairn_model/cairn_model.dart' as model;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:itinerary_parser/itinerary_parser.dart' as ip;

import '../repositories/trip_repository.dart';
import 'date_labels.dart';
import 'ping_schedule.dart';
import 'trip_providers.dart';

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

/// One stop as the confirmation screen shows it: the text as pasted, and a
/// time label exactly when the parser starred it (the star rule — a found,
/// unhedged clock time — lives in the parser and is only echoed here).
class ReviewStop {
  final String text;
  final String? timeLabel;

  const ReviewStop({required this.text, this.timeLabel});

  bool get isStarred => timeLabel != null;
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

  /// `14 June`, or null while the date is open.
  final String? dateLabel;

  final List<ReviewStop> stops;
  final DayConfidence confidence;

  /// Null when the day reads clean — including when the person has already
  /// answered this day's ask.
  final DayDoubt? doubt;

  const ReviewDay({
    required this.number,
    required this.title,
    this.dateLabel,
    required this.stops,
    required this.confidence,
    this.doubt,
  });

  bool get needsEye => doubt != null;
}

class KeptAsideLine {
  final String text;
  final String explanation;

  const KeptAsideLine({required this.text, required this.explanation});
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

  /// The person's per-day answers, keyed by the parser's 1-based day index.
  /// Cleared by anything that re-reads the whole paste ([readMonthFirst],
  /// [useYear]): a re-read moves the ground the answers stood on.
  final Map<int, DateTime> _pickedDates = {};
  final Set<int> _confirmedDays = {};
  final Map<int, List<String>> _addedStops = {};

  @override
  PasteFlowState build() => const PasteEditing();

  void parse(String text) {
    if (text.trim().isEmpty) return;
    _text = text;
    _monthFirst = false;
    _tripStartHint = null;
    _clearAnswers();
    _reparse();
  }

  /// The round-8 FixingIt one-tap: re-read the whole paste in the other date
  /// dialect. One flip for everything — a plan doesn't change dialect halfway
  /// through.
  void readMonthFirst(bool monthFirst) {
    _monthFirst = monthFirst;
    _clearAnswers();
    _reparse();
  }

  /// One answer to "which year?": re-read with a trip-start hint so the
  /// parser itself resolves every year-less date, rather than this layer
  /// second-guessing it.
  void useYear(int year) {
    _tripStartHint = DateTime(year, 1, 1);
    _clearAnswers();
    _reparse();
  }

  void setDayDate(int dayNumber, DateTime date) {
    _pickedDates[dayNumber] = DateTime(date.year, date.month, date.day);
    _rebuildReview();
  }

  void confirmDay(int dayNumber) {
    _confirmedDays.add(dayNumber);
    _rebuildReview();
  }

  void addStop(int dayNumber, String text) {
    if (text.trim().isEmpty) return;
    _addedStops.putIfAbsent(dayNumber, () => []).add(text.trim());
    _rebuildReview();
  }

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
    _clearAnswers();
    state = const PasteEditing();
  }

  /// Persists the confirmation through the seam. The itinerary is local-only
  /// in this slice; syncing it as a shared fact is later work
  /// (docs/decisions/2026-08-22-grill-round-one.md §2).
  Future<void> accept() async {
    final result = _result;
    if (result == null) return;
    final itinerary = ConfirmedItinerary(
      days: [
        for (final day in result.days)
          ConfirmedDay(
            number: day.index,
            date: switch (_effectiveDate(day)) {
              null => null,
              final d => model.CalendarDate.fromDateTimeIgnoringZone(d),
            },
            place: day.place,
            stops: [
              for (final stop in day.stops)
                model.Stop(
                  text: stop.text,
                  time: switch (stop.time) {
                    null => null,
                    final t => model.ClockTime(t.hour, t.minute),
                  },
                ),
              for (final added in _addedStops[day.index] ?? const <String>[])
                model.Stop(text: added),
            ],
          ),
      ],
      keptAside: [
        for (final line in result.unplacedLines)
          KeptLine(
            sourceLineNumber: line.sourceLine.lineNumber,
            text: line.sourceLine.text.trim(),
            explanation: line.reason.explanation,
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

  void _clearAnswers() {
    _pickedDates.clear();
    _confirmedDays.clear();
    _addedStops.clear();
  }

  void _reparse() {
    _result = ip.parseItinerary(
      _text,
      tripStartDate: _tripStartHint,
      monthFirstNumericDates: _monthFirst,
    );
    _rebuildReview();
  }

  void _rebuildReview() {
    final result = _result;
    if (result == null) return;
    state = PasteReview(_buildReview(result));
  }

  DateTime? _effectiveDate(ip.ParsedDay day) =>
      _pickedDates[day.index] ?? day.date;

  ItineraryReview _buildReview(ip.ParseResult result) {
    final nothingRead = result.usedHeaderlessFallback || result.days.isEmpty;
    return ItineraryReview(
      days: nothingRead
          ? const []
          : [for (final day in result.days) _buildDay(day, result.days)],
      keptAside: [
        for (final line in result.unplacedLines)
          KeptAsideLine(
            text: line.sourceLine.text.trim(),
            explanation: line.reason.explanation,
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
    );
  }

  ReviewDay _buildDay(ip.ParsedDay day, List<ip.ParsedDay> allDays) {
    final date = _effectiveDate(day);
    final doubt = _doubtFor(day, allDays, date);
    return ReviewDay(
      number: day.index,
      title: _titleFor(day, date),
      dateLabel: date == null ? null : dayMonthLabel(date),
      stops: [
        for (final stop in day.stops)
          ReviewStop(text: stop.text, timeLabel: stop.time?.toIso()),
        for (final added in _addedStops[day.index] ?? const <String>[])
          ReviewStop(text: added),
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

  String _titleFor(ip.ParsedDay day, DateTime? date) {
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
    return 'Day ${day.index}';
  }

  /// The surfaced doubt for a day, or null when it reads clean — either the
  /// parser was sure, or the person has answered.
  DayDoubt? _doubtFor(
    ip.ParsedDay day,
    List<ip.ParsedDay> allDays,
    DateTime? effectiveDate,
  ) {
    final uncertainty = day.uncertainty;
    if (uncertainty == null) return null;
    if (_confirmedDays.contains(day.index)) return null;

    switch (uncertainty) {
      case ip.DayUncertainty.weekdayWithoutDate:
      case ip.DayUncertainty.dateWithoutYear:
        // A date answered — picked directly, or resolved by a whole-paste
        // year re-read — closes the question.
        if (effectiveDate != null) return null;
      case ip.DayUncertainty.noStops:
        if (_addedStops[day.index]?.isNotEmpty ?? false) return null;
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
        allDays,
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
      ip.DayUncertainty.noStops => DayDoubt(
        cause: DayDoubtCause.noStops,
        explanation: uncertainty.explanation,
        ask:
            'Found the day, nothing in it. A rest day — or lines I '
            "couldn't read?",
        options: const [
          DayAskOption('+ Add a stop', AddStop()),
          DayAskOption('leave it empty', ConfirmAsIs()),
        ],
      ),
      // Unreachable: mapped to the nothing-read state above.
      ip.DayUncertainty.headerlessBlock => null,
    };
  }

  DayDoubt _weekdayDoubt(
    ip.ParsedDay day,
    List<ip.ParsedDay> allDays,
    String explanation,
  ) {
    final named = day.headerWeekday!;
    final candidate = _candidateDateFor(day, allDays);

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
    final thisYear = DateTime.now().year;
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
  DateTime? _candidateDateFor(ip.ParsedDay day, List<ip.ParsedDay> allDays) {
    final position = allDays.indexOf(day);
    for (var i = position - 1; i >= 0; i--) {
      final date = _effectiveDate(allDays[i]);
      if (date != null) return date.add(Duration(days: position - i));
    }
    for (var i = position + 1; i < allDays.length; i++) {
      final date = _effectiveDate(allDays[i]);
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
