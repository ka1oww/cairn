/// Result of recognizing a line as a date-shaped (not `Day N`-shaped) day
/// header.
class DateHeaderMatch {
  /// Day of month, 1-31, if the line named a specific date.
  final int? day;

  /// Month, 1-12, if the line named a specific date.
  final int? month;

  /// Four-digit year, if the line spelled one out.
  final int? year;

  /// ISO weekday, 1 (Monday) - 7 (Sunday), if the line named a weekday.
  /// Informational only: this package never guesses which calendar
  /// occurrence of "Monday" is meant, so a weekday alone does not resolve
  /// to a date.
  final int? weekday;

  /// Text trailing a separator after the date part, e.g. the `Kyoto` in
  /// `Mon 3 Nov - Kyoto`.
  final String? trailingText;

  /// True when this match came from a numeric slash date (`3/11`) that
  /// would also have been valid — and different — read the other way
  /// round, i.e. both components were in 1-12 and not equal. Named month
  /// and ISO forms are never ambiguous.
  final bool ambiguousNumericOrder;

  const DateHeaderMatch({
    this.day,
    this.month,
    this.year,
    this.weekday,
    this.trailingText,
    this.ambiguousNumericOrder = false,
  });

  bool get hasFullDate => day != null && month != null;
}

const Map<String, int> _months = {
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

const Map<String, int> _weekdays = {
  'mon': 1,
  'monday': 1,
  'tue': 2,
  'tues': 2,
  'tuesday': 2,
  'wed': 3,
  'weds': 3,
  'wednesday': 3,
  'thu': 4,
  'thur': 4,
  'thurs': 4,
  'thursday': 4,
  'fri': 5,
  'friday': 5,
  'sat': 6,
  'saturday': 6,
  'sun': 7,
  'sunday': 7,
};

final RegExp _weekdayDayMonth = RegExp(
  r'^([A-Za-z]+)\.?(,)?\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)\.?(?:\s+(\d{4}))?\s*(?:[-:–—]\s*(.+))?$',
  caseSensitive: false,
);

// Weekday-then-month-day order (`Sat Jun 14`, `Saturday, June 14th`), the
// `ddd, MMM Do` family US-style plans and Wanderlog prints use. Kept apart
// from [_weekdayDayMonth] rather than folded into one alternation so each
// shape's groups stay named by position.
final RegExp _weekdayMonthDay = RegExp(
  r'^([A-Za-z]+)\.?,?\s+([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\s*(?:[-:–—]\s*(.+))?$',
  caseSensitive: false,
);

final RegExp _dayMonth = RegExp(
  r'^(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)\.?(?:\s+(\d{4}))?\s*(?:[-:–—]\s*(.+))?$',
  caseSensitive: false,
);

final RegExp _monthDay = RegExp(
  r'^([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\s*(?:[-:–—]\s*(.+))?$',
  caseSensitive: false,
);

final RegExp _numericDayMonth = RegExp(
  r'^(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\s*(?:[-:–—]\s*(.+))?$',
);

final RegExp _isoDate = RegExp(
  r'^(\d{4})-(\d{1,2})-(\d{1,2})\s*(?:[-:–—]\s*(.+))?$',
);

final RegExp _weekdayOnly = RegExp(
  r'^([A-Za-z]+)\.?\s*(?:[-:–—]\s*(.+))?$',
  caseSensitive: false,
);

int? _month(String s) => _months[s.toLowerCase()];
int? _weekday(String s) => _weekdays[s.toLowerCase()];

String? _cleanTrailing(String? s) {
  if (s == null) return null;
  final t = s.trim();
  return t.isEmpty ? null : t;
}

int _fullYear(int y) {
  if (y >= 100) return y;
  return y >= 70 ? 1900 + y : 2000 + y;
}

// The far end of a range: an optional weekday word followed by a day and a
// named month in either order. Anchored at the start of the trailing text
// and deliberately a shape test rather than a second pass of the whole
// matcher, so a chain of three dates is refused exactly as a pair is.
final RegExp _dateRunPrefix = RegExp(
  r'^(?:([A-Za-z]+)\.?,?\s+)?'
  r'(?:(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)'
  r'|([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?)\b',
  caseSensitive: false,
);

/// True when [text] opens with a date run rather than a place name, i.e. it
/// is the far end of a range like `Sat, Jun 14th - Wed, Jun 18th`. A line
/// naming two dates names no single day, so the shapes this slice widened
/// decline it and it stays an ordinary line.
bool _beginsWithDateRun(String? text) {
  if (text == null) return false;
  final m = _dateRunPrefix.firstMatch(text);
  if (m == null) return false;
  final lead = m.group(1);
  if (lead != null && _weekday(lead) == null) return false;
  if (m.group(2) != null) return _month(m.group(3)!) != null;
  return _month(m.group(4)!) != null;
}

/// Tries each recognized date-header shape against [line] (already
/// trimmed, and already known not to be a `Day N` header or a bulleted
/// stop). Returns null if none match.
///
/// [monthFirstNumericDates] controls how a numeric slash date (`3/11`) is
/// read: day-first by default, month-first when true. Either way, when
/// only one reading is valid (`25/12` has no month 25), the valid reading
/// is used regardless of the setting. Named-month and ISO forms are
/// unaffected.
DateHeaderMatch? tryParseDateHeader(
  String line, {
  bool monthFirstNumericDates = false,
}) {
  var m = _weekdayDayMonth.firstMatch(line);
  if (m != null) {
    final weekday = _weekday(m.group(1)!);
    final month = _month(m.group(4)!);
    final trailing = _cleanTrailing(m.group(6));
    final afterAComma = m.group(2) != null;
    if (weekday != null &&
        month != null &&
        !(afterAComma && _beginsWithDateRun(trailing))) {
      return DateHeaderMatch(
        weekday: weekday,
        day: int.parse(m.group(3)!),
        month: month,
        year: m.group(5) != null ? int.parse(m.group(5)!) : null,
        trailingText: trailing,
      );
    }
  }

  m = _weekdayMonthDay.firstMatch(line);
  if (m != null) {
    final weekday = _weekday(m.group(1)!);
    final month = _month(m.group(2)!);
    final trailing = _cleanTrailing(m.group(5));
    if (weekday != null && month != null && !_beginsWithDateRun(trailing)) {
      return DateHeaderMatch(
        weekday: weekday,
        month: month,
        day: int.parse(m.group(3)!),
        year: m.group(4) != null ? int.parse(m.group(4)!) : null,
        trailingText: trailing,
      );
    }
  }

  m = _dayMonth.firstMatch(line);
  if (m != null) {
    final month = _month(m.group(2)!);
    if (month != null) {
      return DateHeaderMatch(
        day: int.parse(m.group(1)!),
        month: month,
        year: m.group(3) != null ? int.parse(m.group(3)!) : null,
        trailingText: _cleanTrailing(m.group(4)),
      );
    }
  }

  m = _monthDay.firstMatch(line);
  if (m != null) {
    final month = _month(m.group(1)!);
    if (month != null) {
      return DateHeaderMatch(
        day: int.parse(m.group(2)!),
        month: month,
        year: m.group(3) != null ? int.parse(m.group(3)!) : null,
        trailingText: _cleanTrailing(m.group(4)),
      );
    }
  }

  m = _isoDate.firstMatch(line);
  if (m != null) {
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      return DateHeaderMatch(
        day: day,
        month: month,
        year: int.parse(m.group(1)!),
        trailingText: _cleanTrailing(m.group(4)),
      );
    }
  }

  m = _numericDayMonth.firstMatch(line);
  if (m != null) {
    final first = int.parse(m.group(1)!);
    final second = int.parse(m.group(2)!);
    final dayFirstValid =
        first >= 1 && first <= 31 && second >= 1 && second <= 12;
    final monthFirstValid =
        first >= 1 && first <= 12 && second >= 1 && second <= 31;
    final ambiguous = dayFirstValid && monthFirstValid && first != second;
    final bool readMonthFirst;
    if (monthFirstNumericDates) {
      readMonthFirst = monthFirstValid;
    } else {
      readMonthFirst = !dayFirstValid && monthFirstValid;
    }
    if (dayFirstValid || monthFirstValid) {
      return DateHeaderMatch(
        day: readMonthFirst ? second : first,
        month: readMonthFirst ? first : second,
        year: m.group(3) != null ? _fullYear(int.parse(m.group(3)!)) : null,
        trailingText: _cleanTrailing(m.group(4)),
        ambiguousNumericOrder: ambiguous,
      );
    }
  }

  m = _weekdayOnly.firstMatch(line);
  if (m != null) {
    final weekday = _weekday(m.group(1)!);
    if (weekday != null) {
      return DateHeaderMatch(
        weekday: weekday,
        trailingText: _cleanTrailing(m.group(2)),
      );
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// Date fragments inside a header that is not itself a date header.
//
// `Day 1 - Tokyo, 14 June` is a `Day N` header, so the whole tail used to
// become the day's place and the date in it was lost — the day then read
// "date open" while its own title said otherwise. The parser still refuses to
// bind it (a `Day N` header's date comes from the trip's start, not from a
// fragment nobody confirmed), so instead it *surfaces* the fragment: the
// confirmation screen offers it as one tap. Recognized, never silently bound
// and never silently discarded.
// ---------------------------------------------------------------------------

/// A date-shaped run of characters found inside a header's trailing text.
///
/// [start]/[end] are offsets into the string that was searched, so a caller
/// can lift the fragment out of the text and keep the rest as the place name.
class DateFragment {
  /// Day of month, 1-31.
  final int day;

  /// Month, 1-12.
  final int month;

  /// Four-digit year, when the fragment spelled one out.
  final int? year;

  /// The fragment exactly as it was written (`14 June`), for showing the
  /// person what was recognized.
  final String text;

  /// True when this came from a numeric slash date that would also have been
  /// valid — and different — read the other way round. Mirrors
  /// [DateHeaderMatch.ambiguousNumericOrder].
  final bool ambiguousNumericOrder;

  final int start;
  final int end;

  const DateFragment({
    required this.day,
    required this.month,
    this.year,
    required this.text,
    required this.start,
    required this.end,
    this.ambiguousNumericOrder = false,
  });
}

final RegExp _fragmentDayMonth = RegExp(
  r'\b(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]{3,9})\.?(?:,?\s+(\d{4}))?\b',
  caseSensitive: false,
);

final RegExp _fragmentMonthDay = RegExp(
  r'\b([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b',
  caseSensitive: false,
);

final RegExp _fragmentIso = RegExp(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b');

final RegExp _fragmentNumeric = RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b');

bool _validDay(int d) => d >= 1 && d <= 31;

/// Finds the first date-shaped fragment anywhere in [text], or null when
/// there is none.
///
/// Only shapes that name a **day and a month** count: a bare year, a bare
/// weekday or a lone number is not a date this can offer, and a month word
/// has to be a real month, so `Day 2 - 5 temples` finds nothing.
///
/// [monthFirstNumericDates] reads a numeric slash fragment (`3/11`) the same
/// way [tryParseDateHeader] reads a whole numeric header, so one flip on the
/// confirmation screen moves every date in the paste together.
DateFragment? findDateFragment(
  String text, {
  bool monthFirstNumericDates = false,
}) {
  final found = <DateFragment>[];

  for (final m in _fragmentIso.allMatches(text)) {
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    if (month < 1 || month > 12 || !_validDay(day)) continue;
    found.add(DateFragment(
      day: day,
      month: month,
      year: int.parse(m.group(1)!),
      text: m.group(0)!,
      start: m.start,
      end: m.end,
    ));
    break;
  }

  for (final m in _fragmentDayMonth.allMatches(text)) {
    final month = _month(m.group(2)!);
    final day = int.parse(m.group(1)!);
    if (month == null || !_validDay(day)) continue;
    found.add(DateFragment(
      day: day,
      month: month,
      year: m.group(3) != null ? int.parse(m.group(3)!) : null,
      text: m.group(0)!,
      start: m.start,
      end: m.end,
    ));
    break;
  }

  for (final m in _fragmentMonthDay.allMatches(text)) {
    final month = _month(m.group(1)!);
    final day = int.parse(m.group(2)!);
    if (month == null || !_validDay(day)) continue;
    found.add(DateFragment(
      day: day,
      month: month,
      year: m.group(3) != null ? int.parse(m.group(3)!) : null,
      text: m.group(0)!,
      start: m.start,
      end: m.end,
    ));
    break;
  }

  for (final m in _fragmentNumeric.allMatches(text)) {
    final first = int.parse(m.group(1)!);
    final second = int.parse(m.group(2)!);
    final dayFirstValid = _validDay(first) && second >= 1 && second <= 12;
    final monthFirstValid = first >= 1 && first <= 12 && _validDay(second);
    if (!dayFirstValid && !monthFirstValid) continue;
    final readMonthFirst = monthFirstNumericDates
        ? monthFirstValid
        : (!dayFirstValid && monthFirstValid);
    found.add(DateFragment(
      day: readMonthFirst ? second : first,
      month: readMonthFirst ? first : second,
      year: m.group(3) != null ? _fullYear(int.parse(m.group(3)!)) : null,
      text: m.group(0)!,
      start: m.start,
      end: m.end,
      ambiguousNumericOrder:
          dayFirstValid && monthFirstValid && first != second,
    ));
    break;
  }

  if (found.isEmpty) return null;
  found.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    return (b.end - b.start).compareTo(a.end - a.start);
  });
  return found.first;
}

final RegExp _edgeSeparators = RegExp(r'^[\s\-–—:,·|/]+|[\s\-–—:,·|/]+$');
final RegExp _doubledSeparators = RegExp(r'\s*[,·|]\s*(?=[,·|])');

/// [text] with [fragment] lifted out and the punctuation that joined them
/// tidied away — `Tokyo, 14 June` becomes `Tokyo`, `14 June - Tokyo` becomes
/// `Tokyo`, and `14 June` on its own becomes null rather than a place named
/// after a date.
String? textWithoutFragment(String text, DateFragment fragment) {
  final rest =
      text.substring(0, fragment.start) + text.substring(fragment.end);
  final tidied = rest
      .replaceAll(_doubledSeparators, '')
      .replaceAll(_edgeSeparators, '')
      .trim();
  return tidied.isEmpty ? null : tidied;
}
