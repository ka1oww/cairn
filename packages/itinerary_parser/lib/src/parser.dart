import 'area_assign.dart';
import 'area_vocab.dart';
import 'date_header.dart';
import 'gazetteer.dart';
import 'line_classifier.dart';
import 'models.dart';
import 'stop_kind.dart';
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
  AreaGazetteer? gazetteer,
}) {
  var rawLines =
      text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  // Paste-path furniture strip: blank provably repeated print furniture
  rawLines = _stripPasteFurniture(rawLines);
  final lines = <_Line>[
    for (var i = 0; i < rawLines.length; i++)
      _Line(
        i + 1,
        rawLines[i],
        stripWhatsAppPrefix(rawLines[i]) ?? rawLines[i],
        stripWhatsAppPrefix(rawLines[i]) != null,
      ),
  ];

  var classified = <_Classified>[
    for (var i = 0; i < lines.length; i++)
      _classifyLine(
        lines[i],
        lines,
        i,
        monthFirstNumericDates,
        allowBarePlaceHeaders: true,
      ),
  ];

  // A numbered day heading is explicit structure. Once a plan contains one,
  // bare proper-noun lines inside its days are stops, not competing inferred
  // headings. This matters for printed guides, whose place cards and wrapped
  // prose otherwise split one numbered day into dozens of invented ones.
  if (classified.any((line) => line.kind == _Kind.dayHeader)) {
    classified = <_Classified>[
      for (var i = 0; i < lines.length; i++)
        _classifyLine(
          lines[i],
          lines,
          i,
          monthFirstNumericDates,
          allowBarePlaceHeaders: false,
        ),
    ];
  }

  final headerFound = classified.any(
    (c) =>
        c.kind == _Kind.dayHeader ||
        c.kind == _Kind.dateHeader ||
        c.kind == _Kind.placeHeader,
  );

  final ParseResult base;
  if (!headerFound) {
    base = _buildFallbackResult(classified);
  } else {
    base = _buildHeaderModeResult(classified, tripStartDate);
  }
  return _annotateWithAreas(base, rawLines, gazetteer);
}

List<String> _stripPasteFurniture(List<String> lines) {
  final phRe = RegExp(r'^\s*\d{1,2}/\d{1,2}/\d{2},\s*\d{1,2}:\d{2}\s*[AP]M\b');
  final ufRe = RegExp(
    r'^\s*https?://\S+\s*(\d{1,3}/\d{1,3})?\s*$',
    caseSensitive: false,
  );
  var result = List<String>.from(lines);
  if (lines.where((l) => phRe.hasMatch(l)).length >= 3) {
    result = [for (final l in result) phRe.hasMatch(l) ? '' : l];
  }
  if (lines.where((l) => ufRe.hasMatch(l)).length >= 3) {
    result = [for (final l in result) ufRe.hasMatch(l) ? '' : l];
  }
  return result;
}

ParseResult _annotateWithAreas(
  ParseResult base,
  List<String> plines,
  AreaGazetteer? gazetteer,
) {
  if (base.days.isEmpty) return base;
  // Build anchor vocab inputs
  final dayInfos = [
    for (final d in base.days)
      ParsedDayInfo(
        headerText: d.headerSourceLine?.text,
        headerLine: d.headerSourceLine?.lineNumber ?? 0,
        place: d.place,
      ),
  ];
  final vocabResult = buildAnchorVocab(plines, dayInfos);
  final vocab = vocabResult.vocab;

  final assignmentIds = <Stop, int>{};
  var nextAssignmentId = 0;
  int assignmentIdFor(Stop stop) {
    final assignmentId = nextAssignmentId++;
    assignmentIds[stop] = assignmentId;
    return assignmentId;
  }

  // Build assignment inputs
  final areaDays = [
    for (final d in base.days)
      AreaDayInput(
        headerText: d.headerSourceLine?.text,
        place: d.place,
        stops: [
          for (final s in d.stops)
            AreaStopInput(
              assignmentId: assignmentIdFor(s),
              raw: _stopAnalysisText(d, s),
              hasTime: s.time != null,
              lineNumber: s.sourceLine.lineNumber,
            ),
        ],
      ),
  ];

  final assignments = anchorAssign(
    plines,
    areaDays,
    vocab,
    trainRule: true,
    gazetteerObj: gazetteer,
  );

  // Map assignment identities that were markers (areaHeading).
  final markerAssignments = <int>{};
  for (final entry in assignments.entries) {
    if (entry.value.source == 'runningHeading' ||
        entry.value.source == 'hotelPrefix' ||
        entry.value.source == 'trainDestination') {
      // Check if this line's clean text was exactly the marker — i.e. the
      // assignment set running to this line's candidate.
      // We mark it as heading if the assignment's setBy == line number
      // and the line is not a meal/venue line (handled in anchorAssign).
      // Simpler: if source is one of the three and setBy == lineNumber,
      // and the stop's raw doesn't contain a venue-like multi-place payload
      // We use the engine's own signal: assignedOwn was set on that line.
      // The engine sets running + assignedOwn on marker lines; we detect
      // by checking if setBy == lineNumber.
      if (entry.value.setByAssignmentId == entry.key) {
        markerAssignments.add(entry.key);
      }
    }
  }

  // Rebuild days with annotated stops
  final newDays = <ParsedDay>[];
  for (final d in base.days) {
    final newStops = <Stop>[];
    for (final s in d.stops) {
      final assignmentId = assignmentIds[s]!;
      final assignment = assignments[assignmentId];
      final isHeading = markerAssignments.contains(assignmentId);
      final classified = classifyStop(
        raw: _stopAnalysisText(d, s),
        isAreaHeading: isHeading,
        hasTime: s.time != null,
      );

      AreaHint? hint;
      if (assignment != null && assignment.text != null) {
        final src = _areaSourceFromString(assignment.source);
        if (isHeading) {
          hint = AreaHint(
            text: assignment.text!,
            source: src,
            setBy: s.sourceLine,
          );
        } else {
          final setByLine = assignment.setByLine;
          final setBy = setByLine != null &&
                  setByLine != s.sourceLine.lineNumber &&
                  setByLine > 0 &&
                  setByLine <= plines.length
              ? SourceLine(setByLine, plines[setByLine - 1])
              : null;
          hint = AreaHint(text: assignment.text!, source: src, setBy: setBy);
        }
      }

      // The classifier alone decides whether there is a safe place expression.
      String? placeText = classified.placeText;
      // But for place stops, ensure placeText is at least s.text stripped of bullet if classifier gave null
      if (classified.kind == StopKind.place && placeText == null) {
        placeText = s.text;
      }

      newStops.add(
        Stop(
          text: s.text,
          time: s.time,
          sourceLine: s.sourceLine,
          kind: classified.kind,
          area: hint,
          placeText: placeText,
        ),
      );
    }
    newDays.add(
      ParsedDay(
        index: d.index,
        date: d.date,
        place: d.place,
        stops: newStops,
        confidence: d.confidence,
        uncertainty: d.uncertainty,
        headerWeekday: d.headerWeekday,
        headerSourceLine: d.headerSourceLine,
        dateCandidate: d.dateCandidate,
      ),
    );
  }

  return ParseResult(
    days: newDays,
    unplacedLines: base.unplacedLines,
    overallConfidence: base.overallConfidence,
    usedHeaderlessFallback: base.usedHeaderlessFallback,
    firstAmbiguousNumericDate: base.firstAmbiguousNumericDate,
    firstYearlessDate: base.firstYearlessDate,
  );
}

String _stopAnalysisText(ParsedDay day, Stop stop) {
  final cameFromHeader = day.headerSourceLine == stop.sourceLine;
  return cameFromHeader ? stop.text : stop.sourceLine.text;
}

AreaSource _areaSourceFromString(String s) {
  switch (s) {
    case 'travellerDeclared':
      return AreaSource.travellerDeclared;
    case 'travellerProximity':
      return AreaSource.travellerProximity;
    case 'inlineLocality':
      return AreaSource.inlineLocality;
    case 'hotelPrefix':
      return AreaSource.hotelPrefix;
    case 'trainDestination':
      return AreaSource.trainDestination;
    case 'runningHeading':
    default:
      return AreaSource.runningHeading;
  }
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
    this.lineNumber,
    this.raw,
    this.effective,
    this.hadWhatsAppPrefix,
  );

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
  final List<int>? dayNumbers;
  final String? headerTrailing;

  /// The header's trailing text as written, before a date fragment was
  /// lifted out of it — what [DateCandidate.headerText] quotes back.
  final String? headerTitle;
  final DateFragment? headerDateFragment;
  final DateHeaderMatch? dateMatch;
  final String? placeText;
  final String? stopText;
  final ParsedTime? stopTime;
  final UnplacedReason? reason;

  const _Classified(
    this.kind,
    this.line, {
    this.dayNumbers,
    this.headerTrailing,
    this.headerTitle,
    this.headerDateFragment,
    this.dateMatch,
    this.placeText,
    this.stopText,
    this.stopTime,
    this.reason,
  });
}

_Classified _classifyLine(
  _Line line,
  List<_Line> all,
  int index,
  bool monthFirstNumericDates, {
  required bool allowBarePlaceHeaders,
}) {
  if (isBlank(line.raw)) {
    return _Classified(_Kind.blank, line);
  }
  if (isDecorativeSeparator(line.effective)) {
    return _Classified(_Kind.decorative, line);
  }
  if (line.hadWhatsAppPrefix && isWhatsAppPlaceholder(line.effective)) {
    return _Classified(
      _Kind.whatsappPlaceholder,
      line,
      reason: UnplacedReason.whatsAppMediaPlaceholder,
    );
  }
  if (isSignatureLine(line.effective)) {
    return _Classified(
      _Kind.signature,
      line,
      reason: UnplacedReason.emailSignature,
    );
  }
  if (isHotelBookingReference(line.effective)) {
    return _Classified(
      _Kind.hotelBooking,
      line,
      reason: UnplacedReason.bookingReference,
    );
  }

  final urlResult = stripUrls(line.effective);
  if (urlResult.hadUrl &&
      (isTriviallyEmpty(urlResult.textWithoutUrl) ||
          isFolioAfterUrl(urlResult.textWithoutUrl))) {
    return _Classified(_Kind.urlOnly, line, reason: UnplacedReason.urlOnly);
  }
  final cleaned = urlResult.hadUrl ? urlResult.textWithoutUrl : line.effective;

  if (!startsWithBullet(cleaned)) {
    final dayMatch = tryParseDayNumberHeader(cleaned);
    if (dayMatch != null) {
      // `Day 1 - Tokyo, 14 June`: the date in the title is recognized and
      // lifted out of the place, but never bound here — a `Day N` header's
      // date comes from the trip's start. It travels as a candidate the
      // confirmation screen can offer in one tap.
      final trailing = dayMatch.trailingText;
      final fragment = trailing == null
          ? null
          : findDateFragment(
              trailing,
              monthFirstNumericDates: monthFirstNumericDates,
            );
      return _Classified(
        _Kind.dayHeader,
        line,
        dayNumbers: dayMatch.dayNumbers,
        headerTrailing: fragment == null
            ? trailing
            : textWithoutFragment(trailing!, fragment),
        headerTitle: trailing,
        headerDateFragment: fragment,
      );
    }

    final dateMatch = tryParseDateHeader(
      cleaned.trim(),
      monthFirstNumericDates: monthFirstNumericDates,
    );
    if (dateMatch != null) {
      // A numeric range names no single day. Keep it as an ordinary line
      // rather than binding its first half and inventing a day from search
      // controls or opening hours such as `9/9 - 9/10`.
      final isNumericRange = dateMatch.trailingText != null &&
          RegExp(r'^\d{1,2}/\d{1,2}(?:/\d{2,4})?$')
              .hasMatch(dateMatch.trailingText!.trim());
      if (!isNumericRange) {
        return _Classified(_Kind.dateHeader, line, dateMatch: dateMatch);
      }
    }

    if (allowBarePlaceHeaders &&
        looksLikeProperNounHeader(cleaned) &&
        _nextNonBlankLooksLikeListItem(all, index)) {
      return _Classified(_Kind.placeHeader, line, placeText: cleaned.trim());
    }
  }

  final stopText = stripBullet(cleaned);
  if (isTriviallyEmpty(stopText)) {
    return _Classified(_Kind.empty, line);
  }
  return _Classified(
    _Kind.stop,
    line,
    stopText: stopText,
    stopTime: extractTime(stopText),
  );
}

class _DayHeaderParts {
  final String? place;
  final List<String> stops;
  const _DayHeaderParts({this.place, this.stops = const []});
}

final RegExp _inlineDayListSeparator = RegExp(r'\s+(?:[-–—+•])\s+');

/// Separates a `Day N` tail into its optional location label and content.
///
/// A short name alone remains the day label it was before this split. Strong
/// list punctuation is representation evidence, though: in `Rome: - Trevi -
/// Pantheon`, `Rome` is the label and the dashed items are stops. When no
/// label can be identified confidently, every chunk stays visible as a stop
/// and [place] stays null rather than promoting prose into a location fact.
_DayHeaderParts _splitDayHeaderParts(
  String? trailing, {
  required bool hasFollowingStops,
}) {
  if (trailing == null) return const _DayHeaderParts();
  final text = trailing.trim();
  if (text.isEmpty) return const _DayHeaderParts();

  // A parenthesised dashed list is present in the field corpus as
  // `Venice (- Rialto bridge - ...)`.
  final parenthesised =
      RegExp(r'^(.*?)\s*\(\s*-\s*(.+)\)\s*$').firstMatch(text);
  if (parenthesised != null) {
    final prefix = parenthesised.group(1)!.trim();
    final items = _splitInlineDayStops(parenthesised.group(2)!);
    if (_isPlainDayLabel(prefix)) {
      return _DayHeaderParts(place: prefix, stops: items);
    }
    return _DayHeaderParts(stops: [_cleanDayStop(prefix), ...items]);
  }

  // The colon must be followed by whitespace, so the colon in `07:00`
  // cannot be mistaken for the boundary between a city and its list.
  final colon = RegExp(r'\s*:\s+(?=\S)').firstMatch(text);
  if (colon != null) {
    final prefix = text.substring(0, colon.start).trim();
    final rest = text.substring(colon.end).trim();
    final items = _splitInlineDayStops(rest);
    if (_isPlainDayLabel(prefix)) {
      return _DayHeaderParts(place: prefix, stops: items);
    }
    return _DayHeaderParts(
      stops: [if (prefix.isNotEmpty) _cleanDayStop(prefix), ...items],
    );
  }

  if (_inlineDayListSeparator.hasMatch(text)) {
    return _DayHeaderParts(stops: _splitInlineDayStops(text));
  }

  // Existing multi-line plans use the whole Day tail as their label, even
  // when it is prose-like (`Arrival & Gion (Kyoto)`). If actual stop lines
  // follow, preserve that established interpretation. An inline list above
  // was still split first, so mixed headers do not hide their own stops.
  if (hasFollowingStops || _isPlainDayLabel(text)) {
    return _DayHeaderParts(place: text);
  }

  // No trustworthy boundary exists. Preserve the whole tail as one stop;
  // later stop classification remains responsible for what kind of stop it
  // is. Keeping one uncertain unit is quieter than inventing smaller facts.
  return _DayHeaderParts(stops: [text]);
}

List<String> _splitInlineDayStops(String text) {
  final cleaned = text.replaceFirst(RegExp(r'^\s*[-–—+•]\s*'), '');
  return cleaned
      .split(_inlineDayListSeparator)
      .map(_cleanDayStop)
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
}

String _cleanDayStop(String text) =>
    text.trim().replaceAll(RegExp(r'^[-–—+•:\s]+|[-–—+•:\s]+$'), '').trim();

bool _isPlainDayLabel(String text) {
  final trimmed = text.trim();
  final labelShape = trimmed.replaceFirst(RegExp(r':$'), '').trim();
  if (looksLikeProperNounHeader(labelShape)) return true;
  if (RegExp(r'^[\p{L}\p{M}]+$', unicode: true).hasMatch(labelShape)) {
    return true;
  }

  // Preserve two established title shapes whose numbers are descriptions,
  // not list content or dates (`5 temples`, `Kyoto 3 nights`).
  if (RegExp(
    r'^\d{1,3}\s+[\p{L}\p{M}]+$',
    unicode: true,
  ).hasMatch(labelShape)) {
    return true;
  }
  return RegExp(
    r'^[\p{L}\p{M}\s\x27.]+\s+\d{1,3}\s+nights?$',
    caseSensitive: false,
    unicode: true,
  ).hasMatch(labelShape);
}

bool _nextNonBlankLooksLikeListItem(List<_Line> lines, int fromIndex) {
  for (var j = fromIndex + 1; j < lines.length; j++) {
    final eff = lines[j].effective;
    if (isBlank(eff) || isDecorativeSeparator(eff)) continue;
    if (startsWithBullet(eff) || extractTime(eff) != null) return true;
    // Wanderlog widening: travel-leg shape "< 1 hr, 10 min"
    if (RegExp(
      r'^<?\s*\d[\d\s,.·]*\s*(days?|hrs?|hr|mins?|min)\b',
      caseSensitive: false,
    ).hasMatch(eff.trim())) {
      return true;
    }
    return false;
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
  // A date that does not exist in the year it lands in is refused, never
  // slid: `DateTime(2027, 6, 31)` would quietly answer 1 July, and a
  // confident neighbour is exactly the guess this parser exists to refuse.
  var date = _realDateOrNull(year, m.month!, m.day!);
  if (date == null) return null;
  if (rolledForward) {
    final start = DateTime(
      tripStartDate!.year,
      tripStartDate.month,
      tripStartDate.day,
    );
    if (date.difference(start).inDays < -30) {
      date = _realDateOrNull(year + 1, m.month!, m.day!);
    }
  }
  return date;
}

/// `DateTime(year, month, day)` when that calendar day really exists, null
/// when `DateTime` would have slid it into a neighbouring day or month.
DateTime? _realDateOrNull(int year, int month, int day) {
  final date = DateTime(year, month, day);
  final real = date.year == year && date.month == month && date.day == day;
  return real ? date : null;
}

class _OpenDay {
  final int index;
  final DateTime? date;
  final String? place;
  final Confidence headerConfidence;
  final DayUncertainty? headerUncertainty;
  final int? headerWeekday;
  final SourceLine? headerSourceLine;
  final DateCandidate? dateCandidate;
  final List<Stop> stops = [];

  _OpenDay({
    required this.index,
    this.date,
    this.place,
    required this.headerConfidence,
    this.headerUncertainty,
    this.headerWeekday,
    this.headerSourceLine,
    this.dateCandidate,
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
      dateCandidate: dateCandidate,
    );
  }
}

bool _hasFollowingStops(List<_Classified> lines, int headerIndex) {
  for (var index = headerIndex + 1; index < lines.length; index++) {
    switch (lines[index].kind) {
      case _Kind.dayHeader:
      case _Kind.dateHeader:
      case _Kind.placeHeader:
        return false;
      case _Kind.stop:
        return true;
      case _Kind.blank:
      case _Kind.decorative:
      case _Kind.whatsappPlaceholder:
      case _Kind.signature:
      case _Kind.hotelBooking:
      case _Kind.urlOnly:
      case _Kind.empty:
        break;
    }
  }
  return false;
}

ParseResult _buildHeaderModeResult(
  List<_Classified> classified,
  DateTime? tripStartDate,
) {
  final days = <ParsedDay>[];
  final unplaced = <UnplacedLine>[];
  var current = <_OpenDay>[];
  var contentLineCount = 0;
  AmbiguousNumericDate? firstAmbiguousNumericDate;
  YearlessDate? firstYearlessDate;

  void closeCurrent() {
    days.addAll(current.map((day) => day.close()));
    current = [];
  }

  for (var classifiedIndex = 0;
      classifiedIndex < classified.length;
      classifiedIndex++) {
    final c = classified[classifiedIndex];
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
          UnplacedLine(sourceLine: c.line.sourceLine, reason: c.reason!),
        );
      case _Kind.dayHeader:
        contentLineCount++;
        closeCurrent();
        final fragment = c.headerDateFragment;
        firstAmbiguousNumericDate ??= fragment?.numericAsWritten;
        final parts = _splitDayHeaderParts(
          c.headerTrailing,
          hasFollowingStops: _hasFollowingStops(classified, classifiedIndex),
        );
        // A range becomes one ParsedDay per claimed number. Its inline and
        // following content is copied to every claimed day because the source
        // associates the block with the whole range and offers no truthful way
        // to allocate individual items. Duplicate or overlapping numbers are
        // kept as separate entries in source order: merging them would silently
        // discard the later claim and choosing a winner belongs to the person.
        for (final dayNumber in c.dayNumbers!) {
          final openDay = _OpenDay(
            index: days.length + current.length + 1,
            // Calendar arithmetic, not Duration arithmetic: adding 24-hour
            // blocks to a local midnight lands at 23:00 the previous day
            // across a daylight-saving fall-back, and the truncation then
            // dates the day a day early.
            date: tripStartDate == null
                ? null
                : DateTime(
                    tripStartDate.year,
                    tripStartDate.month,
                    tripStartDate.day + dayNumber - 1,
                  ),
            place: parts.place,
            headerConfidence: Confidence.high,
            headerSourceLine: c.line.sourceLine,
            dateCandidate: fragment == null
                ? null
                : DateCandidate(
                    day: fragment.day,
                    month: fragment.month,
                    year: fragment.year,
                    text: fragment.text,
                    headerText: c.headerTitle!,
                    ambiguousNumericOrder: fragment.ambiguousNumericOrder,
                  ),
          );
          for (final stopText in parts.stops) {
            openDay.stops.add(
              Stop(
                text: stopText,
                time: extractTime(stopText),
                sourceLine: c.line.sourceLine,
              ),
            );
          }
          current.add(openDay);
        }
      case _Kind.dateHeader:
        contentLineCount++;
        closeCurrent();
        final m = c.dateMatch!;
        firstAmbiguousNumericDate ??= m.numericAsWritten;
        // `31 June` names a day its month never has, in any year. The date
        // stays open and the doubt says why — sliding to 1 July would be a
        // confident guess the person never made.
        final impossible =
            m.hasFullDate && !dayExistsInMonth(m.day!, m.month!, m.year);
        if (m.hasFullDate && m.year == null && !impossible) {
          firstYearlessDate ??= YearlessDate(day: m.day!, month: m.month!);
        }
        final resolvedDate =
            impossible ? null : _resolveDateHeaderDate(m, tripStartDate);
        // A named weekday beside a resolved date is checked, not trusted
        // blind: on a disagreement the date is kept (numbers are harder to
        // mistype than a weekday word) and the doubt is surfaced so the
        // confirmation screen asks instead of the parser correcting anyone.
        final weekdayDisagrees = resolvedDate != null &&
            m.weekday != null &&
            resolvedDate.weekday != m.weekday;
        final DayUncertainty? uncertainty;
        if (impossible) {
          uncertainty = DayUncertainty.impossibleDate;
        } else if (weekdayDisagrees) {
          uncertainty = DayUncertainty.weekdayDisagrees;
        } else if (resolvedDate != null) {
          uncertainty = null;
        } else if (m.hasFullDate) {
          uncertainty = DayUncertainty.dateWithoutYear;
        } else {
          uncertainty = DayUncertainty.weekdayWithoutDate;
        }
        current = [
          _OpenDay(
            index: days.length + 1,
            date: resolvedDate,
            place: m.trailingText,
            headerConfidence:
                uncertainty == null ? Confidence.high : Confidence.medium,
            headerUncertainty: uncertainty,
            headerWeekday: m.weekday,
            headerSourceLine: c.line.sourceLine,
          ),
        ];
      case _Kind.placeHeader:
        contentLineCount++;
        closeCurrent();
        current = [
          _OpenDay(
            index: days.length + 1,
            place: c.placeText,
            headerConfidence: Confidence.medium,
            headerUncertainty: DayUncertainty.barePlaceName,
            headerSourceLine: c.line.sourceLine,
          ),
        ];
      case _Kind.stop:
        contentLineCount++;
        if (current.isEmpty) {
          unplaced.add(
            UnplacedLine(
              sourceLine: c.line.sourceLine,
              reason: UnplacedReason.precedesFirstHeader,
            ),
          );
        } else {
          for (final day in current) {
            day.stops.add(
              Stop(
                text: c.stopText!,
                time: c.stopTime,
                sourceLine: c.line.sourceLine,
              ),
            );
          }
        }
    }
  }
  closeCurrent();

  final overall = _combineOverall(
    days,
    unplaced,
    contentLineCount,
    fallback: false,
  );
  return ParseResult(
    days: days,
    unplacedLines: unplaced,
    overallConfidence: overall,
    usedHeaderlessFallback: false,
    firstAmbiguousNumericDate: firstAmbiguousNumericDate,
    firstYearlessDate: firstYearlessDate,
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
          UnplacedLine(sourceLine: c.line.sourceLine, reason: c.reason!),
        );
      case _Kind.dayHeader:
      case _Kind.dateHeader:
      case _Kind.placeHeader:
        // headerFound was false for the whole document, so this branch is
        // unreachable; kept only for exhaustiveness.
        break;
      case _Kind.stop:
        blockStops.add(
          Stop(
            text: c.stopText!,
            time: c.stopTime,
            sourceLine: c.line.sourceLine,
          ),
        );
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
