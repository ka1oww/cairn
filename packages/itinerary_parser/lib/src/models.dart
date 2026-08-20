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

  /// The source line that was recognized as this day's header, if any.
  /// Null in blank-line fallback mode, where a day is a text block rather
  /// than a header-introduced section.
  final SourceLine? headerSourceLine;

  const ParsedDay({
    required this.index,
    this.date,
    this.place,
    required this.stops,
    required this.confidence,
    this.headerSourceLine,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'date': date == null ? null : _formatDate(date!),
        'place': place,
        'stops': stops.map((s) => s.toJson()).toList(),
        'confidence': confidence.name,
        'headerSourceLine': headerSourceLine?.toJson(),
      };

  @override
  String toString() =>
      'ParsedDay(#$index, date: $date, place: $place, ${stops.length} stops, $confidence)';
}

/// A source line the parser could not confidently place into any day.
///
/// Nothing from the input is ever dropped silently: if a line isn't a
/// header and isn't a stop under some day, it ends up here instead of
/// vanishing.
class UnplacedLine {
  final SourceLine sourceLine;

  /// Short machine-readable-ish explanation of why this line was not
  /// placed (e.g. `'preamble'`, `'url'`, `'hotel-booking-reference'`).
  /// Intended for debugging and for the confirmation screen to explain
  /// itself, not for programmatic branching.
  final String reason;

  const UnplacedLine({required this.sourceLine, required this.reason});

  Map<String, dynamic> toJson() => {
        'sourceLine': sourceLine.toJson(),
        'reason': reason,
      };

  @override
  String toString() => 'UnplacedLine($reason: ${sourceLine.text.trim()})';
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

  const ParseResult({
    required this.days,
    required this.unplacedLines,
    required this.overallConfidence,
    required this.usedHeaderlessFallback,
  });

  Map<String, dynamic> toJson() => {
        'days': days.map((d) => d.toJson()).toList(),
        'unplacedLines': unplacedLines.map((u) => u.toJson()).toList(),
        'overallConfidence': overallConfidence.name,
        'usedHeaderlessFallback': usedHeaderlessFallback,
      };

  @override
  String toString() =>
      'ParseResult(${days.length} days, ${unplacedLines.length} unplaced, $overallConfidence)';
}

String _formatDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
