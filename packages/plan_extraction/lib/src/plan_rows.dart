// The row model structured sources (xlsx, csv, and later ics) are lifted
// into before being said as plan text, plus the one renderer that says them.
//
// Import is not a second parser (the import plan §2.2): a spreadsheet or CSV
// reduces to the same text dialect `lib/logic/plan_text.dart` renders for
// re-paste — dated day `Mon 14 June 2027 - Tokyo`, undated day
// `Day N - Place`, stop `- <text>` with a leading `HH:MM ` when a definite
// time is known. This file cannot import `plan_text.dart` (an app file), so
// it carries its own tiny renderer for the dialect; the round-trip test
// (`plan_rows_round_trip_test.dart`) is what keeps the two honest — every
// shape this renders must come back from `parseItinerary` as the same days,
// dates and times. That test is the honesty guard; nothing here may change
// without it passing.
//
// Only a date-typed cell gives a day its date *for certain* — that is the
// whole value of a typed source over pasted text (`DateCellValue` in the
// xlsx case, an exact ISO-shaped string in the csv case). Anything else
// stays text and the parser's own grammar judges it; no second date grammar
// lives here.

/// One cell of a structured source, after its container's typing.
sealed class SourceCell {
  const SourceCell();
}

/// A date the source typed as a date — the only certain date there is.
class DateCell extends SourceCell {
  final DateTime date;

  const DateCell(this.date);

  /// The form the parser reads as an ISO date header (`2027-06-14`).
  String get iso =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

/// A time the source typed as a time.
class TimeCell extends SourceCell {
  final int hour;

  final int minute;

  const TimeCell(this.hour, this.minute)
      : assert(hour >= 0 && hour <= 23),
        assert(minute >= 0 && minute <= 59);

  /// The form the parser reads at a line's head (`09:30`).
  String get iso =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

/// Everything else: text as written. Numbers, booleans and formulas arrive
/// here already stringified by their extractor.
class TextCell extends SourceCell {
  final String text;

  const TextCell(this.text);
}

/// One row of the plan the cells say: either a day header or a stop line,
/// in document order.
sealed class PlanRow {
  const PlanRow();
}

/// A day's header. [date] wins when present (the dialect's dated form);
/// otherwise the undated `Day N` form needs [number]. [place] is optional
/// in both forms.
class DayRow extends PlanRow {
  final DateTime? date;

  final int? number;

  final String? place;

  const DayRow({this.date, this.number, this.place})
      : assert(
          date != null || number != null,
          'a DayRow must carry a date or a number — the dialect has no '
          'header form for a day with neither',
        );
}

/// One stop under the day opened before it. [text] is single-line (the
/// extractors split multi-line cells); [time] is a definite time from a
/// time-typed source cell, rendered as the leading `HH:MM ` that stars the
/// stop.
class StopRow extends PlanRow {
  final String text;

  final TimeCell? time;

  const StopRow(this.text, {this.time});
}

/// A line that came before any day — a sheet title, a column-label row.
/// Rendered bare, ahead of the first header, so the parser files it where
/// it files preamble: the visible set-aside, never silently dropped.
class PreambleRow extends PlanRow {
  final String text;

  const PreambleRow(this.text);
}

// ---------------------------------------------------------------------------
// Heuristic v1 (the import plan's risk 5): of a grid of source cells, if a
// column of date-typed cells exists, treat rows as days/stops and emit the
// dialect; otherwise every non-empty cell becomes a faithful line and the
// parser's ask flow does its work. The fallback can never be worse than
// pasting the same table as text — that is the floor.
// ---------------------------------------------------------------------------

/// A non-empty cell; empty cells never reach the row builder.
final class _Filled {
  final int column;

  final SourceCell cell;

  const _Filled(this.column, this.cell);
}

/// Turns a grid of typed cells (row-major, ragged rows welcome) into
/// [PlanRow]s under heuristic v1.
List<PlanRow> planRowsFromGrid(List<List<SourceCell?>> grid) {
  final filled = <List<_Filled>>[
    for (final row in grid)
      [
        for (var c = 0; c < row.length; c++)
          ...switch (row[c]) {
            null => const <_Filled>[],
            TextCell(:final text) => _filledTextCells(c, text),
            final other => [_Filled(c, other)],
          },
      ],
  ];

  final nonEmptyRows = [
    for (final row in filled)
      if (row.isNotEmpty) row,
  ];
  if (nonEmptyRows.isEmpty) return const [];

  final dateColumn = _findDateColumn(nonEmptyRows);
  if (dateColumn == null) {
    // Fallback: every non-empty cell row-major as faithful lines. A
    // date-typed cell still says itself as its ISO form, which the parser
    // reads as a date header on its own terms.
    return [
      for (final row in nonEmptyRows)
        for (final cell in row) PreambleRow(_textOf(cell.cell)),
    ];
  }

  return _rowsFromDatedGrid(nonEmptyRows, dateColumn);
}

/// A text cell may hold several lines; each becomes its own cell.
Iterable<_Filled> _filledTextCells(int column, String text) sync* {
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isNotEmpty) yield _Filled(column, TextCell(trimmed));
  }
}

/// The leftmost column holding at least two date-typed cells. Two, not one:
/// a lone stray date must not restructure the whole sheet, and a table with
/// exactly one dated row falls back harmlessly.
int? _findDateColumn(List<List<_Filled>> rows) {
  int? bestColumn;
  var bestCount = 1; // a column qualifies only above this
  final counts = <int, int>{};
  for (final row in rows) {
    for (final cell in row) {
      if (cell.cell is! DateCell) continue;
      final count = (counts[cell.column] ?? 0) + 1;
      counts[cell.column] = count;
      // Strictly greater keeps the leftmost column on ties.
      if (count > bestCount) {
        bestCount = count;
        bestColumn = cell.column;
      }
    }
  }
  return bestColumn;
}

/// Dialect mode: a run of rows sharing the date column's value is one day;
/// a different (or absent) date opens the next. Cells from the date column
/// become headers; every other cell in the run becomes a stop line, with a
/// time-typed cell starring the first line of its own row.
List<PlanRow> _rowsFromDatedGrid(List<List<_Filled>> rows, int dateColumn) {
  final out = <PlanRow>[];
  DateTime? currentDate;

  for (final row in rows) {
    DateCell? rowDate;
    final rest = <SourceCell>[];
    for (final cell in row) {
      if (cell.column == dateColumn && cell.cell is DateCell) {
        rowDate ??= cell.cell as DateCell;
      } else {
        rest.add(cell.cell);
      }
    }

    if (rowDate == null) {
      if (currentDate == null) {
        // Before the first day: sheet furniture, kept visibly.
        out.addAll([for (final cell in rest) PreambleRow(_textOf(cell))]);
      } else {
        out.addAll(_stopsFor(rest));
      }
      continue;
    }

    if (currentDate != rowDate.date) {
      currentDate = rowDate.date;
      out.add(DayRow(date: rowDate.date));
    }
    out.addAll(_stopsFor(rest));
  }
  return out;
}

/// One line per cell; a time-typed cell stars the first text line of its
/// own row rather than standing alone (it annotates that row's plan).
List<StopRow> _stopsFor(List<SourceCell> cells) {
  final stops = <StopRow>[];
  TimeCell? pendingTime;
  for (final cell in cells) {
    switch (cell) {
      case TimeCell():
        pendingTime ??= cell;
      case TextCell(:final text):
        stops.add(StopRow(text, time: pendingTime));
        pendingTime = null;
      case DateCell(:final iso):
        // A second date column is content, not structure: say it as its
        // ISO text and let the parser judge.
        stops.add(StopRow(iso));
    }
  }
  // A row whose only cell was a time keeps the time visible rather than
  // dropping it.
  if (pendingTime != null && stops.isEmpty) {
    stops.add(StopRow(pendingTime.iso, time: pendingTime));
  }
  return stops;
}

String _textOf(SourceCell cell) => switch (cell) {
      TextCell(:final text) => text,
      DateCell(:final iso) => iso,
      TimeCell(:final iso) => iso,
    };

// ---------------------------------------------------------------------------
// The dialect renderer.
// ---------------------------------------------------------------------------

const List<String> _months = [
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

const List<String> _weekdays = [
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
];

/// Renders [rows] as paste-dialect text: one header per day, one line per
/// stop, days separated by a blank line. The round-trip test pins every
/// shape this emits against `parseItinerary`.
String renderPlanRows(List<PlanRow> rows) {
  final blocks = <List<String>>[];
  final leading = <String>[]; // preamble and stray stops before any day

  void addLine(String line) {
    if (blocks.isEmpty) {
      leading.add(line);
    } else {
      blocks.last.add(line);
    }
  }

  for (final row in rows) {
    switch (row) {
      case PreambleRow(:final text):
        addLine(text);
      case DayRow():
        blocks.add([_dayHeader(row)]);
      case StopRow():
        addLine(_stopLine(row));
    }
  }

  // Leading lines stay ahead of the first header: that ordering is what
  // makes the parser file them as preamble instead of scattering them.
  return [
    leading.join('\n'),
    for (final block in blocks) block.join('\n'),
  ].where((part) => part.isNotEmpty).join('\n\n');
}

String _dayHeader(DayRow row) {
  final date = row.date;
  if (date != null) {
    final weekday = DateTime.utc(date.year, date.month, date.day).weekday;
    final head =
        '${_weekdays[weekday - 1]} ${date.day} '
        '${_months[date.month - 1]} ${date.year}';
    return _withPlace(head, row.place);
  }
  final number = row.number!;
  return _withPlace('Day $number', row.place);
}

String _withPlace(String head, String? place) {
  final trimmed = place?.trim() ?? '';
  return trimmed.isEmpty ? head : '$head - $trimmed';
}

String _stopLine(StopRow row) =>
    '- ${row.time == null ? '' : '${row.time!.iso} '}${_oneLine(row.text)}';

/// Stops are single lines by construction; this defends the invariant
/// against whatever a container smuggled through (tabs, soft breaks).
String _oneLine(String text) => text.replaceAll(RegExp(r'\s+'), ' ').trim();
