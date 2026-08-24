// APP STATE band: the one place person-facing date words are spelled, so the
// paste-and-confirm flow and the saved-trip surface cannot drift apart.
// Hand-rolled English rather than an intl dependency: the labels the design
// draws ("14 June", "Monday") need nothing more.

const _weekdayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// `Monday` for ISO weekday 1 … `Sunday` for 7 — the numbering
/// `DateTime.weekday` and `ParsedDay.headerWeekday` share.
String weekdayName(int isoWeekday) => _weekdayNames[isoWeekday - 1];

/// `Mon` for ISO weekday 1.
String weekdayAbbrev(int isoWeekday) => _weekdayNames[isoWeekday - 1].substring(0, 3);

/// `14 June` — the spelling design round 8 puts beside a day.
String dayMonthLabel(DateTime date) => '${date.day} ${_monthNames[date.month - 1]}';

/// `14th`, `1st`, `22nd` — for the round-8 ask chips ("It's the 18th").
String ordinal(int day) {
  if (day >= 11 && day <= 13) return '${day}th';
  return switch (day % 10) {
    1 => '${day}st',
    2 => '${day}nd',
    3 => '${day}rd',
    _ => '${day}th',
  };
}

/// `Wednesday, Kyoto` — the day page's spelling of a day's identity
/// (design surface 2f). The confirmation screen's day list spells the same
/// pair with a middot; the two surfaces are deliberately drawn differently
/// and are not shared.
String dayPageTitle({
  String? weekday,
  String? place,
  required int number,
}) =>
    switch ((weekday, place)) {
      (final w?, final p?) => '$w, $p',
      (final w?, null) => w,
      (null, final p?) => p,
      (null, null) => 'Day $number',
    };

const _countWords = [
  'One',
  'Two',
  'Three',
  'Four',
  'Five',
  'Six',
  'Seven',
  'Eight',
  'Nine',
  'Ten',
  'Eleven',
  'Twelve',
];

/// `Five` for 5 — the countdown is written out rather than set in digits
/// (surface 7c: "Five days to go"), because the one number this app sets in
/// digits is a starred stop's time. Falls back to digits past twelve, where
/// the word is longer than the thing it names.
String countWord(int count) =>
    count >= 1 && count <= _countWords.length ? _countWords[count - 1] : '$count';
