import 'models.dart';

/// Finds the first clock time mentioned in [line] and returns it, or null
/// if none is found.
///
/// Recognizes, in this priority order:
///  - a time range (`14:00-16:00`, `2pm-4pm`): only the start time is used
///  - `H:MM` / `H.MM` with optional am/pm (`16:40`, `16.40`, `4:40pm`,
///    `4.40 PM`)
///  - `H` with am/pm and no minutes (`4pm`, `4 PM`)
///  - a bare 4-digit military time (`1640`)
///
/// The bare 4-digit form deliberately excludes anything that reads as a
/// calendar year (1900-2099), since pasted itineraries very often contain a
/// year and almost never contain a genuine 19xx/20xx military time. This is
/// a known, documented limitation rather than an oversight.
///
/// A *hedged* time is not extracted at all: `maybe 4pm?`, `around 4.40 PM`,
/// `~7pm`, `7pm-ish`, `2pm or 3pm` all return null. An extracted time is
/// the only thing that stars a stop, and a star must mean a real
/// commitment, not a guess — so when the surrounding words hedge the time,
/// the parser deliberately keeps no time. The rule is conservative on
/// purpose: a hedge word anywhere in the same comma-separated clause
/// *before* the time, or `ish`/`?`/`or so`/`or <another time>` right after
/// it, suppresses extraction. See [_isHedged] for the vocabulary.
ParsedTime? extractTime(String line) {
  final range = _rangeWithColon.firstMatch(line);
  if (range != null) {
    if (_isHedged(line, range)) return null;
    return _fromColonMatch(range);
  }

  final colon = _colonOrDot.firstMatch(line);
  if (colon != null) {
    if (_isHedged(line, colon)) return null;
    return _fromColonMatch(colon);
  }

  final hourOnly = _hourWithMeridiem.firstMatch(line);
  if (hourOnly != null) {
    if (_isHedged(line, hourOnly)) return null;
    return _fromHourMeridiemMatch(hourOnly);
  }

  final military = _bareMilitary.firstMatch(line);
  if (military != null) {
    final text = military.group(0)!;
    if (!_looksLikeYear(text)) {
      final hour = int.parse(text.substring(0, 2));
      final minute = int.parse(text.substring(2, 4));
      if (hour <= 23 && minute <= 59) {
        if (_isHedged(line, military)) return null;
        return ParsedTime(hour, minute);
      }
    }
  }

  return null;
}

/// Words that, appearing in the same clause before a time, mark it as an
/// estimate rather than a commitment. Kept as whole words so e.g. the
/// place name "Roundabout" does not hedge anything.
final RegExp _hedgeWordBefore = RegExp(
  r'\b(maybe|might|perhaps|probably|possibly|hopefully|likely|around|about|'
  r'roughly|approx|approximately|sometime|circa|ideally|tbc|tbd)\b',
  caseSensitive: false,
);

/// Hedging that immediately follows the time: `-ish`, a question mark,
/// `or so`, or an alternative introduced by `or`.
final RegExp _hedgeSuffix = RegExp(
  r'^\s*(?:[-–—]?\s*ish\b|\?|or\b)',
  caseSensitive: false,
);

/// Clause boundaries: hedging is only read within the comma/period/
/// semicolon-separated clause the time itself sits in, so `Dinner 7pm,
/// maybe karaoke after` still stars the dinner.
final RegExp _clauseBreak = RegExp(r'[,;.!·()]');

/// True when the words around [match] hedge the time it found. Errs toward
/// hedged: an unstarred real appointment is a small loss, a starred guess
/// devalues every star in the trip.
bool _isHedged(String line, RegExpMatch match) {
  var before = line.substring(0, match.start);
  final lastBreak = before.lastIndexOf(_clauseBreak);
  if (lastBreak >= 0) before = before.substring(lastBreak + 1);
  if (_hedgeWordBefore.hasMatch(before)) return true;
  if (before.trimRight().endsWith('~')) return true;

  var after = line.substring(match.end);
  final nextBreak = after.indexOf(_clauseBreak);
  if (nextBreak >= 0) after = after.substring(0, nextBreak);
  if (_hedgeSuffix.hasMatch(after)) return true;

  return false;
}

final RegExp _rangeWithColon = RegExp(
  r'\b(\d{1,2})[:.](\d{2})\s*(am|pm)?\s*[-–]\s*\d{1,2}[:.]\d{2}\s*(?:am|pm)?\b',
  caseSensitive: false,
);

final RegExp _colonOrDot = RegExp(
  r'\b(\d{1,2})[:.](\d{2})\s*(am|pm)?\b',
  caseSensitive: false,
);

final RegExp _hourWithMeridiem = RegExp(
  r'\b(\d{1,2})\s*(am|pm)\b',
  caseSensitive: false,
);

final RegExp _bareMilitary = RegExp(r'\b([01]\d|2[0-3])([0-5]\d)\b');

ParsedTime? _fromColonMatch(RegExpMatch m) {
  var hour = int.parse(m.group(1)!);
  final minute = int.parse(m.group(2)!);
  final meridiem = m.group(3)?.toLowerCase();
  if (minute > 59) return null;
  if (meridiem != null) {
    if (hour < 1 || hour > 12) return null;
    hour = _to24Hour(hour, meridiem);
  } else if (hour > 23) {
    return null;
  }
  return ParsedTime(hour, minute);
}

ParsedTime? _fromHourMeridiemMatch(RegExpMatch m) {
  final hour = int.parse(m.group(1)!);
  final meridiem = m.group(2)!.toLowerCase();
  if (hour < 1 || hour > 12) return null;
  return ParsedTime(_to24Hour(hour, meridiem), 0);
}

int _to24Hour(int hour12, String meridiem) {
  if (meridiem == 'am') {
    return hour12 == 12 ? 0 : hour12;
  }
  return hour12 == 12 ? 12 : hour12 + 12;
}

bool _looksLikeYear(String fourDigits) {
  final n = int.parse(fourDigits);
  return n >= 1900 && n <= 2099;
}
