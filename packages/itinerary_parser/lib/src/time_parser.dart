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
ParsedTime? extractTime(String line) {
  final range = _rangeWithColon.firstMatch(line);
  if (range != null) {
    return _fromColonMatch(range);
  }

  final colon = _colonOrDot.firstMatch(line);
  if (colon != null) {
    return _fromColonMatch(colon);
  }

  final hourOnly = _hourWithMeridiem.firstMatch(line);
  if (hourOnly != null) {
    return _fromHourMeridiemMatch(hourOnly);
  }

  final military = _bareMilitary.firstMatch(line);
  if (military != null) {
    final text = military.group(0)!;
    if (!_looksLikeYear(text)) {
      final hour = int.parse(text.substring(0, 2));
      final minute = int.parse(text.substring(2, 4));
      if (hour <= 23 && minute <= 59) {
        return ParsedTime(hour, minute);
      }
    }
  }

  return null;
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
