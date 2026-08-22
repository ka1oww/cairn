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
  r'^([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?\s+([A-Za-z]+)\.?(?:\s+(\d{4}))?\s*(?:[-:–—]\s*(.+))?$',
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
    final month = _month(m.group(3)!);
    if (weekday != null && month != null) {
      return DateHeaderMatch(
        weekday: weekday,
        day: int.parse(m.group(2)!),
        month: month,
        year: m.group(4) != null ? int.parse(m.group(4)!) : null,
        trailingText: _cleanTrailing(m.group(5)),
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
