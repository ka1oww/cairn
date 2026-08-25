/// How much the parser trusts a piece of structure it produced.
///
/// The confirmation screen should treat these differently, not just show a
/// badge:
///
/// - [high]: the source line was unambiguous — an explicit `Day N` header
///   (even if no `tripStartDate` was given to turn it into a calendar
///   date), or a date header that resolved to a full calendar date. Prefill
///   and let the user glance past it.
/// - [medium]: the parser had to infer structure from a weaker signal, or
///   resolved the structure but not the date — a bare place name acting as
///   a header, a weekday with no day/month, or a date header missing a
///   year with no `tripStartDate` to resolve it against. Pre-fill, but the
///   confirmation UI should draw attention to it rather than let it slide
///   by unnoticed.
/// - [low]: the parser fell back to a guess it has little faith in (no
///   headers found anywhere, so it split on blank lines) or produced an
///   empty section. Do not let the user skip past this without looking —
///   surface it as needing review before the trip starts.
enum Confidence { low, medium, high }

/// Why a day's [Confidence] is not [Confidence.high].
///
/// The confirmation screen varies its copy and its ask by cause — a
/// weekday it wouldn't pin to a date gets a different question than a day
/// that parsed but came up empty — so the cause is part of the public
/// result, not something the UI should re-derive by re-parsing the header.
///
/// [ParsedDay.uncertainty] is null exactly when the day's confidence is
/// [Confidence.high].
enum DayUncertainty {
  /// The header names only a weekday (`Monday`). The parser never guesses
  /// which calendar occurrence of a bare weekday is meant, so the day's
  /// `date` is null.
  weekdayWithoutDate(
    'weekday-without-date',
    'The plan only calls this day a weekday, and which calendar date that '
        'weekday means is not guessed.',
  ),

  /// The header names a day and month but no year, and no `tripStartDate`
  /// was supplied to resolve the year against.
  dateWithoutYear(
    'date-without-year',
    'This day has a day and month but no year, and no trip start date was '
        'given to work the year out from.',
  ),

  /// The day was inferred from a bare place-name line acting as a header;
  /// nothing in the text explicitly marked it as a day.
  barePlaceName(
    'bare-place-name',
    'This day was read from a bare place name — nothing in the text '
        'explicitly marked it as a new day.',
  ),

  /// A header was found for this day, but no stops ended up under it.
  noStops(
    'no-stops',
    'The day itself was found, but nothing readable was under it.',
  ),

  /// No day headers were recognized anywhere in the paste, so this "day"
  /// is just one blank-line-separated block of text.
  headerlessBlock(
    'headerless-block',
    'No day headers were found anywhere in the paste, so this is just a '
        'block of lines split on blank space.',
  ),
  ;

  /// Stable, machine-readable identifier (also what `toJson` emits).
  final String slug;

  /// A person-showable sentence explaining the doubt: what the parser saw
  /// and what it refused to guess. Written so the user can check it
  /// against their own pasted text and act on it.
  final String explanation;

  const DayUncertainty(this.slug, this.explanation);
}

/// One line from the original pasted text, kept verbatim.
///
/// Every [Stop], every day header, and every unplaced line carries one of
/// these so the confirmation screen can always show "this is exactly what
/// you pasted" next to whatever the parser made of it.
class SourceLine {
  /// 1-based line number in the original input string.
  final int lineNumber;

  /// The raw line text, unmodified (not trimmed, not stripped of bullets).
  final String text;

  const SourceLine(this.lineNumber, this.text);

  Map<String, dynamic> toJson() => {'lineNumber': lineNumber, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is SourceLine &&
      other.lineNumber == lineNumber &&
      other.text == text;

  @override
  int get hashCode => Object.hash(lineNumber, text);

  @override
  String toString() => 'SourceLine($lineNumber, ${text.trim()})';
}

/// A clock time extracted from a stop line, always in 24-hour form.
///
/// This is the *only* thing that stars a stop: if [ParsedTime] is present
/// on a [Stop], the app should render a star; if it is absent, it should
/// not. There is no other star rule anywhere in this package.
class ParsedTime {
  /// 0-23.
  final int hour;

  /// 0-59.
  final int minute;

  const ParsedTime(this.hour, this.minute);

  /// `HH:MM`, zero-padded, 24-hour.
  String toIso() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {'hour': hour, 'minute': minute};

  @override
  bool operator ==(Object other) =>
      other is ParsedTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => toIso();
}

/// One activity within a day.
///
/// [text] is the stop line with its bullet marker (if any) stripped, but
/// otherwise left as-written — including any time text it contains — so
/// nothing is silently rewritten out from under the user. [time] is parsed
/// out separately for sorting/starring; it is not removed from [text].
class Stop {
  final String text;
  final ParsedTime? time;
  final SourceLine sourceLine;

  const Stop({required this.text, this.time, required this.sourceLine});

  /// True exactly when [time] is present. This is the star rule.
  bool get isStarred => time != null;

  Map<String, dynamic> toJson() => {
        'text': text,
        'time': time?.toJson(),
        'isStarred': isStarred,
        'sourceLine': sourceLine.toJson(),
      };

  @override
  String toString() => 'Stop(${time != null ? '${time!.toIso()} ' : ''}$text)';
}


/// A date the parser *recognized in a day's header but did not bind* to the
/// day.
///
/// `Day 1 - Tokyo, 14 June` names a date, but a `Day N` header takes its date
/// from where the day sits in the trip, not from a fragment in its title — so
/// the fragment used to be swallowed whole into [ParsedDay.place] and the day
/// then read "date open" while its own title said 14 June. It is neither bound
/// nor discarded now: it is surfaced here, for the confirmation screen to
/// offer as one tap.
///
/// [year] is null whenever the header did not spell one out; resolving it is
/// the caller's decision (this package never guesses a year), which is why
/// [resolved] returns null rather than picking one.
class DateCandidate {
  /// Day of month, 1-31.
  final int day;

  /// Month, 1-12.
  final int month;

  /// Four-digit year, when the header spelled one out.
  final int? year;

  /// The fragment exactly as written (`14 June`) — what the person can check
  /// against their own paste.
  final String text;

  /// The whole of the header that carried it, as written, minus the `Day N`
  /// part that made it a header (`Tokyo, 14 June`). The confirmation screen
  /// quotes this back, so the person is answering about their own words
  /// rather than about the parser's reading of them.
  final String headerText;

  /// True when this came from a numeric slash date that reads both ways
  /// round. Mirrors [ParseResult.hasAmbiguousNumericDates], which is set for
  /// the whole paste when any candidate or header is ambiguous.
  final bool ambiguousNumericOrder;

  const DateCandidate({
    required this.day,
    required this.month,
    this.year,
    required this.text,
    required this.headerText,
    this.ambiguousNumericOrder = false,
  });

  /// The concrete date, when the header spelled a year out; null otherwise.
  DateTime? get resolved => year == null ? null : DateTime(year!, month, day);

  /// The concrete date this candidate means in [year].
  DateTime inYear(int year) => DateTime(year, month, day);

  Map<String, dynamic> toJson() => {
        'day': day,
        'month': month,
        'year': year,
        'text': text,
        'headerText': headerText,
        'ambiguousNumericOrder': ambiguousNumericOrder,
      };

  @override
  bool operator ==(Object other) =>
      other is DateCandidate &&
      other.day == day &&
      other.month == month &&
      other.year == year &&
      other.text == text &&
      other.headerText == headerText &&
      other.ambiguousNumericOrder == ambiguousNumericOrder;

  @override
  int get hashCode =>
      Object.hash(day, month, year, text, headerText, ambiguousNumericOrder);

  @override
  String toString() => 'DateCandidate($text)';
}

/// One day of the trip: an optional date, an optional place, and its
/// ordered stops.
class ParsedDay {
  /// 1-based position of this day in the output. Not necessarily the same
  /// as a "Day N" number found in the text (e.g. blank-line fallback mode
  /// numbers days sequentially regardless of headers).
  final int index;

  /// Calendar date for this day, if the parser could resolve one. Date-only
  /// (time-of-day is always midnight). Null when the source gave no date
  /// information, or gave a date without a year and no `tripStartDate` was
  /// supplied to resolve it against.
  final DateTime? date;

  /// Place or city name for this day, if the header carried one.
  final String? place;

  final List<Stop> stops;

  final Confidence confidence;

  /// Why [confidence] is below [Confidence.high] — null exactly when it
  /// isn't. Carries a person-showable [DayUncertainty.explanation] so the
  /// confirmation screen can say what the parser was unsure of without
  /// re-parsing the header text itself.
  final DayUncertainty? uncertainty;

  /// ISO weekday (1 = Monday … 7 = Sunday) that this day's header *named*,
  /// if it named one — `Monday`, `Mon 3 Nov`. Null when the header carried
  /// no weekday word (a resolved [date]'s weekday is derivable from the
  /// date itself). For a [DayUncertainty.weekdayWithoutDate] day this is
  /// the only structured record of what the plan called the day, and it
  /// lets the UI check a named weekday against whatever date the day would
  /// land on.
  final int? headerWeekday;

  /// The source line that was recognized as this day's header, if any.
  /// Null in blank-line fallback mode, where a day is a text block rather
  /// than a header-introduced section.
  final SourceLine? headerSourceLine;

  /// A date this day's header named that the parser did not bind — see
  /// [DateCandidate]. Null when the header carried no such fragment, which
  /// includes every header whose date *was* bound to [date].
  final DateCandidate? dateCandidate;

  const ParsedDay({
    required this.index,
    this.date,
    this.place,
    required this.stops,
    required this.confidence,
    this.uncertainty,
    this.headerWeekday,
    this.headerSourceLine,
    this.dateCandidate,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'date': date == null ? null : _formatDate(date!),
        'place': place,
        'stops': stops.map((s) => s.toJson()).toList(),
        'confidence': confidence.name,
        'uncertainty': uncertainty?.slug,
        'headerWeekday': headerWeekday,
        'headerSourceLine': headerSourceLine?.toJson(),
        'dateCandidate': dateCandidate?.toJson(),
      };

  @override
  String toString() =>
      'ParsedDay(#$index, date: $date, place: $place, ${stops.length} stops, $confidence)';
}

/// Why a source line was set aside instead of placed into a day.
///
/// Each value carries a person-showable [explanation]: a falsifiable
/// sentence the confirmation screen can put next to the kept line, stating
/// what the parser saw so the user can check it against their own paste
/// and place the line by hand if the parser was wrong. The [slug] is the
/// stable identifier for tests and serialization.
enum UnplacedReason {
  /// A stop-shaped line that appeared before the first day header, so
  /// there was no day to attach it to.
  precedesFirstHeader(
    'preamble',
    'This line came before the first day I could find, so there was no '
        'day to put it under.',
  ),

  /// After stripping its URL, nothing meaningful remained on the line.
  urlOnly(
    'url',
    'This line was only a web link, with no other text to keep as a stop.',
  ),

  /// A WhatsApp export placeholder (`<Media omitted>`, `image omitted`, …)
  /// standing in for an attachment that isn't in the text.
  whatsAppMediaPlaceholder(
    'whatsapp-media',
    "This is WhatsApp's stand-in for an omitted photo, video or other "
        'attachment — the thing itself is not in the pasted text.',
  ),

  /// An email-client signature line (`Sent from my iPhone`, …).
  emailSignature(
    'signature-line',
    'This looked like an email signature, not part of the plan.',
  ),

  /// A hotel/flight booking-reference line (`Booking ref: …`, `PNR …`).
  bookingReference(
    'hotel-booking-reference',
    'This looked like a booking confirmation reference, not a stop.',
  ),
  ;

  /// Stable, machine-readable identifier (also what `toJson` emits).
  final String slug;

  /// A person-showable sentence explaining why the line was set aside.
  final String explanation;

  const UnplacedReason(this.slug, this.explanation);
}

/// A source line the parser could not confidently place into any day.
///
/// Nothing from the input is ever dropped silently: if a line isn't a
/// header and isn't a stop under some day, it ends up here instead of
/// vanishing.
class UnplacedLine {
  final SourceLine sourceLine;

  /// Why this line was set aside. `reason.explanation` is written to be
  /// shown to the user next to the kept line, not just logged.
  final UnplacedReason reason;

  const UnplacedLine({required this.sourceLine, required this.reason});

  Map<String, dynamic> toJson() => {
        'sourceLine': sourceLine.toJson(),
        'reason': reason.slug,
      };

  @override
  String toString() =>
      'UnplacedLine(${reason.slug}: ${sourceLine.text.trim()})';
}

/// The full result of parsing one pasted itinerary.
class ParseResult {
  final List<ParsedDay> days;

  /// Lines the parser saw but could not place under any day. Always shown
  /// to the user rather than dropped.
  final List<UnplacedLine> unplacedLines;

  /// The weakest confidence signal driving the whole result. See
  /// [Confidence] for what the UI should do at each level.
  final Confidence overallConfidence;

  /// True when no day headers were recognized anywhere in the input and
  /// the parser fell back to treating each blank-line-separated block of
  /// text as one day. This always implies `overallConfidence == low`.
  final bool usedHeaderlessFallback;

  /// True when at least one recognized numeric date header (`3/11`) could
  /// also be read the other way round (both components were 1-12 and
  /// differ) — i.e. re-parsing with the opposite `monthFirstNumericDates`
  /// setting would genuinely change a date. The confirmation screen uses
  /// this to decide whether to offer the "these are month-first dates"
  /// one-tap re-read at all.
  final bool hasAmbiguousNumericDates;

  const ParseResult({
    required this.days,
    required this.unplacedLines,
    required this.overallConfidence,
    required this.usedHeaderlessFallback,
    this.hasAmbiguousNumericDates = false,
  });

  Map<String, dynamic> toJson() => {
        'days': days.map((d) => d.toJson()).toList(),
        'unplacedLines': unplacedLines.map((u) => u.toJson()).toList(),
        'overallConfidence': overallConfidence.name,
        'usedHeaderlessFallback': usedHeaderlessFallback,
        'hasAmbiguousNumericDates': hasAmbiguousNumericDates,
      };

  @override
  String toString() =>
      'ParseResult(${days.length} days, ${unplacedLines.length} unplaced, $overallConfidence)';
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
