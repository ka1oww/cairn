import 'date_header.dart';
import 'line_classifier.dart';
import 'models.dart';
import 'time_parser.dart';

/// Parses [text] — one block of pasted, unstructured trip-plan text — into
/// an ordered list of days and stops.
///
/// [tripStartDate] is optional. When given, it lets the parser resolve:
///  - `Day N` headers into actual calendar dates (`Day 3` becomes
///    `tripStartDate + 2 days`)
///  - date headers that name a day and month but no year (`3 November`,
///    `Nov 3`), rolling into the following year if that date would
///    otherwise fall more than 30 days before the trip starts
///
/// Without it, `Day N` headers and year-less dates are still recognized as
/// headers (so days are still split out correctly), but their `date` field
/// is left null rather than guessed.
///
/// [monthFirstNumericDates] flips how numeric slash dates (`3/11`) are
/// read: day-first (3 November) by default, month-first (March 11th) when
/// true. It exists so a confirmation screen can offer "these are
/// month-first dates" as a single tap that re-parses the whole paste
/// consistently; `ParseResult.hasAmbiguousNumericDates` says whether that
/// offer is worth making.
///
/// This function never throws on malformed input and never calls out to a
/// network or a model — it is a pure, deterministic function of its
/// arguments. See the package README for a list of paste shapes it does
/// not handle well.
ParseResult parseItinerary(
  String text, {
  DateTime? tripStartDate,
  bool monthFirstNumericDates = false,
}) {
  final rawLines =
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final lines = <_Line>[
    for (var i = 0; i < rawLines.length; i++)
      _Line(i + 1, rawLines[i], stripWhatsAppPrefix(rawLines[i]) ?? rawLines[i],
          stripWhatsAppPrefix(rawLines[i]) != null),
  ];

  final classified = <_Classified>[
    for (var i = 0; i < lines.length; i++)
      _classifyLine(lines[i], lines, i, monthFirstNumericDates),
  ];

  final headerFound = classified.any(
    (c) =>
        c.kind == _Kind.dayHeader ||
        c.kind == _Kind.dateHeader ||
        c.kind == _Kind.placeHeader,
  );

  if (!headerFound) {
    return _buildFallbackResult(classified);
  }
  return _buildHeaderModeResult(classified, tripStartDate);
}

/// A thin, style-alternative entry point wrapping [parseItinerary]. Prefer
/// calling `parseItinerary(...)` directly; this exists for callers who
/// prefer an explicit type to import and call a static method on.
abstract final class ItineraryParser {
  static ParseResult parse(
    String text, {
    DateTime? tripStartDate,
    bool monthFirstNumericDates = false,
  }) =>
      parseItinerary(
        text,
        tripStartDate: tripStartDate,
        monthFirstNumericDates: monthFirstNumericDates,
      );
}

class _Line {
  final int lineNumber;
  final String raw;
  final String effective;
  final bool hadWhatsAppPrefix;
  const _Line(
      this.lineNumber, this.raw, this.effective, this.hadWhatsAppPrefix);

  SourceLine get sourceLine => SourceLine(lineNumber, raw);
}

enum _Kind {
  blank,
  decorative,
  whatsappPlaceholder,
  signature,
  hotelBooking,
  urlOnly,
  dayHeader,
  dateHeader,
  placeHeader,
  stop,
  empty,
}

class _Classified {
  final _Kind kind;
  final _Line line;
  final int? dayNumber;
  final String? headerTrailing;
  final DateHeaderMatch? dateMatch;
  final String? placeText;
  final String? stopText;
  final ParsedTime? stopTime;
  final UnplacedReason? reason;

  const _Classified(
    this.kind,
    this.line, {
    this.dayNumber,
    this.headerTrailing,
    this.dateMatch,
    this.placeText,
    this.stopText,
    this.stopTime,
    this.reason,
  });
}

_Classified _classifyLine(
    _Line line, List<_Line> all, int index, bool monthFirstNumericDates) {
  if (isBlank(line.raw)) {
    return _Classified(_Kind.blank, line);
  }
  if (isDecorativeSeparator(line.effective)) {
    return _Classified(_Kind.decorative, line);
  }
  if (line.hadWhatsAppPrefix && isWhatsAppPlaceholder(line.effective)) {
    return _Classified(_Kind.whatsappPlaceholder, line,
        reason: UnplacedReason.whatsAppMediaPlaceholder);
  }
  if (isSignatureLine(line.effective)) {
    return _Classified(_Kind.signature, line,
        reason: UnplacedReason.emailSignature);
  }
  if (isHotelBookingReference(line.effective)) {
    return _Classified(_Kind.hotelBooking, line,
        reason: UnplacedReason.bookingReference);
  }

  final urlResult = stripUrls(line.effective);
  if (urlResult.hadUrl && isTriviallyEmpty(urlResult.textWithoutUrl)) {
    return _Classified(_Kind.urlOnly, line, reason: UnplacedReason.urlOnly);
  }
  final cleaned = urlResult.hadUrl ? urlResult.textWithoutUrl : line.effective;

  if (!startsWithBullet(cleaned)) {
    final dayMatch = tryParseDayNumberHeader(cleaned);
    if (dayMatch != null) {
      return _Classified(
        _Kind.dayHeader,
        line,
        dayNumber: dayMatch.dayNumber,
        headerTrailing: dayMatch.trailingText,
      );
    }

    final dateMatch = tryParseDateHeader(cleaned.trim(),
        monthFirstNumericDates: monthFirstNumericDates);
    if (dateMatch != null) {
      return _Classified(_Kind.dateHeader, line, dateMatch: dateMatch);
    }

    if (looksLikeProperNounHeader(cleaned) &&
        _nextNonBlankLooksLikeListItem(all, index)) {
      return _Classified(_Kind.placeHeader, line, placeText: cleaned.trim());
    }
  }

  final stopText = stripBullet(cleaned);
  if (isTriviallyEmpty(stopText)) {
    return _Classified(_Kind.empty, line);
  }
  return _Classified(_Kind.stop, line,
      stopText: stopText, stopTime: extractTime(stopText));
}

bool _nextNonBlankLooksLikeListItem(List<_Line> lines, int fromIndex) {
  for (var j = fromIndex + 1; j < lines.length; j++) {
    final eff = lines[j].effective;
    if (isBlank(eff) || isDecorativeSeparator(eff)) continue;
    return startsWithBullet(eff) || extractTime(eff) != null;
  }
  return false;
}

DateTime? _resolveDateHeaderDate(DateHeaderMatch m, DateTime? tripStartDate) {
  if (!m.hasFullDate) return null;
  final int year;
  var rolledForward = false;
  if (m.year != null) {
    year = m.year!;
  } else if (tripStartDate != null) {
    year = tripStartDate.year;
    rolledForward = true;
  } else {
    return null;
  }
  var date = DateTime(year, m.month!, m.day!);
  if (rolledForward) {
    final start =
        DateTime(tripStartDate!.year, tripStartDate.month, tripStartDate.day);
    if (date.difference(start).inDays < -30) {
      date = DateTime(year + 1, m.month!, m.day!);
    }
  }
  return date;
}

class _OpenDay {
  final int index;
  final DateTime? date;
  final String? place;
  final Confidence headerConfidence;
  final DayUncertainty? headerUncertainty;
  final int? headerWeekday;
  final SourceLine? headerSourceLine;
  final List<Stop> stops = [];

  _OpenDay({
    required this.index,
    this.date,
    this.place,
    required this.headerConfidence,
    this.headerUncertainty,
    this.headerWeekday,
    this.headerSourceLine,
  });

  ParsedDay close() {
    // An empty day is low confidence whatever its header said, and the
    // emptiness is then the doubt worth showing the user.
    final empty = stops.isEmpty;
    return ParsedDay(
      index: index,
      date: date,
      place: place,
      stops: List.unmodifiable(stops),
      confidence: empty ? Confidence.low : headerConfidence,
      uncertainty: empty ? DayUncertainty.noStops : headerUncertainty,
      headerWeekday: headerWeekday,
      headerSourceLine: headerSourceLine,
    );
  }
}

ParseResult _buildHeaderModeResult(
    List<_Classified> classified, DateTime? tripStartDate) {
  final days = <ParsedDay>[];
  final unplaced = <UnplacedLine>[];
  _OpenDay? current;
  var contentLineCount = 0;
  var sawAmbiguousNumericDate = false;

  void closeCurrent() {
    if (current != null) {
      days.add(current!.close());
      current = null;
    }
  }

  for (final c in classified) {
    switch (c.kind) {
      case _Kind.blank:
      case _Kind.decorative:
      case _Kind.empty:
        break;
      case _Kind.whatsappPlaceholder:
      case _Kind.signature:
      case _Kind.hotelBooking:
      case _Kind.urlOnly:
        contentLineCount++;
        unplaced.add(
            UnplacedLine(sourceLine: c.line.sourceLine, reason: c.reason!));
      case _Kind.dayHeader:
        contentLineCount++;
        closeCurrent();
        current = _OpenDay(
          index: days.length + 1,
          date: tripStartDate == null
              ? null
              : _dateOnly(tripStartDate.add(Duration(days: c.dayNumber! - 1))),
          place: c.headerTrailing,
          headerConfidence: Confidence.high,
          headerSourceLine: c.line.sourceLine,
        );
      case _Kind.dateHeader:
        contentLineCount++;
        closeCurrent();
        final m = c.dateMatch!;
        if (m.ambiguousNumericOrder) sawAmbiguousNumericDate = true;
        final resolvedDate = _resolveDateHeaderDate(m, tripStartDate);
        final DayUncertainty? uncertainty;
        if (resolvedDate != null) {
          uncertainty = null;
        } else if (m.hasFullDate) {
          uncertainty = DayUncertainty.dateWithoutYear;
        } else {
          uncertainty = DayUncertainty.weekdayWithoutDate;
        }
        current = _OpenDay(
          index: days.length + 1,
          date: resolvedDate,
          place: m.trailingText,
          headerConfidence:
              resolvedDate != null ? Confidence.high : Confidence.medium,
          headerUncertainty: uncertainty,
          headerWeekday: m.weekday,
          headerSourceLine: c.line.sourceLine,
        );
      case _Kind.placeHeader:
        contentLineCount++;
        closeCurrent();
        current = _OpenDay(
          index: days.length + 1,
          place: c.placeText,
          headerConfidence: Confidence.medium,
          headerUncertainty: DayUncertainty.barePlaceName,
          headerSourceLine: c.line.sourceLine,
        );
      case _Kind.stop:
        contentLineCount++;
        if (current == null) {
          unplaced.add(UnplacedLine(
              sourceLine: c.line.sourceLine,
              reason: UnplacedReason.precedesFirstHeader));
        } else {
          current!.stops.add(
            Stop(
                text: c.stopText!,
                time: c.stopTime,
                sourceLine: c.line.sourceLine),
          );
        }
    }
  }
  closeCurrent();

  final overall =
      _combineOverall(days, unplaced, contentLineCount, fallback: false);
  return ParseResult(
    days: days,
    unplacedLines: unplaced,
    overallConfidence: overall,
    usedHeaderlessFallback: false,
    hasAmbiguousNumericDates: sawAmbiguousNumericDate,
  );
}

ParseResult _buildFallbackResult(List<_Classified> classified) {
  final days = <ParsedDay>[];
  final unplaced = <UnplacedLine>[];
  var blockStops = <Stop>[];

  void flushBlock() {
    if (blockStops.isNotEmpty) {
      days.add(
        ParsedDay(
          index: days.length + 1,
          stops: List.unmodifiable(blockStops),
          confidence: Confidence.low,
          uncertainty: DayUncertainty.headerlessBlock,
        ),
      );
    }
    blockStops = [];
  }

  for (final c in classified) {
    switch (c.kind) {
      case _Kind.blank:
        flushBlock();
      case _Kind.decorative:
      case _Kind.empty:
        break;
      case _Kind.whatsappPlaceholder:
      case _Kind.signature:
      case _Kind.hotelBooking:
      case _Kind.urlOnly:
        unplaced.add(
            UnplacedLine(sourceLine: c.line.sourceLine, reason: c.reason!));
      case _Kind.dayHeader:
      case _Kind.dateHeader:
      case _Kind.placeHeader:
        // headerFound was false for the whole document, so this branch is
        // unreachable; kept only for exhaustiveness.
        break;
      case _Kind.stop:
        blockStops.add(Stop(
            text: c.stopText!,
            time: c.stopTime,
            sourceLine: c.line.sourceLine));
    }
  }
  flushBlock();

  return ParseResult(
    days: days,
    unplacedLines: unplaced,
    overallConfidence: days.isEmpty ? Confidence.low : Confidence.low,
    usedHeaderlessFallback: true,
  );
}

Confidence _combineOverall(
  List<ParsedDay> days,
  List<UnplacedLine> unplaced,
  int totalContentLines, {
  required bool fallback,
}) {
  if (fallback || days.isEmpty) return Confidence.low;
  var overall = Confidence.high;
  for (final d in days) {
    if (d.confidence == Confidence.low) {
      overall = Confidence.low;
      break;
    }
    if (d.confidence == Confidence.medium && overall == Confidence.high) {
      overall = Confidence.medium;
    }
  }
  if (overall != Confidence.low && totalContentLines > 0) {
    final ratio = unplaced.length / totalContentLines;
    if (ratio > 0.4) {
      overall = Confidence.low;
    } else if (ratio > 0.15 && overall == Confidence.high) {
      overall = Confidence.medium;
    }
  }
  return overall;
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
