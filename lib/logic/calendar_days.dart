// LOGIC band (docs/architecture.md): pure decision core, no Flutter, no IO.

/// [date] moved [days] forward on the calendar (backward when negative),
/// staying at local midnight.
///
/// This exists because `date.add(Duration(days: n))` is elapsed-time
/// arithmetic, not calendar arithmetic: across a daylight-saving fall-back
/// the sum lands at 23:00 the previous calendar day, and anything that then
/// reads the date is a day early. `DateTime`'s own constructor normalises an
/// out-of-range day-of-month instead, which is exact on every backend — so
/// every app-side "n days later" over a date-only value goes through here,
/// written once.
DateTime calendarPlusDays(DateTime date, int days) =>
    DateTime(date.year, date.month, date.day + days);
