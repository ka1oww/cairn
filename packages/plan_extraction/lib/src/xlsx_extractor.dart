// The .xlsx extractor on the `excel` package (the import plan §3). The
// package's typed `CellValue` subtypes are the point: a date-typed cell is
// how the extractor knows a date *for certain* and can emit the
// high-confidence dialect header, with zero date asks downstream.
//
// Heuristic v1 (the import plan's risk 5): first non-empty sheet; if a
// column of date-typed cells exists, rows become days/stops in the dialect;
// otherwise every non-empty cell becomes a faithful line and the parser's
// ask flow does its work. The fallback floor: never worse than pasting the
// same table as text. The shared half lives in `plan_rows.dart`; this file
// only maps the container's cells onto the row model.
import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

import '../plan_extraction.dart';
import 'docx_extractor.dart' show isZipMagic;
import 'plan_rows.dart';

/// Cells above this count are refused before materialization: `sheet.rows`
/// builds the full dense grid, and no itinerary sheet is anywhere near
/// this (the plan's risk 7).
const int _maxSheetCells = 1 << 20;

class XlsxExtractor implements PlanTextExtractor {
  const XlsxExtractor();

  @override
  Set<String> get extensions => const {'xlsx'};

  @override
  bool matches(PickedBytes file) {
    if (!isZipMagic(file.bytes)) return false;
    // Distinguish from docx by content, so a mis-named file routes to
    // whichever extractor can honestly read it (the contract's magic-byte
    // rule). A workbook carries xl/workbook.xml.
    try {
      final archive = ZipDecoder().decodeBytes(file.bytes);
      return archive.any((entry) => entry.name == 'xl/workbook.xml');
    } on Object {
      return false;
    }
  }

  @override
  ExtractionResult extract(PickedBytes file) {
    if (file.bytes.isEmpty) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        emptyFileSentence,
      );
    }
    if (file.bytes.length > maxPlainBytes) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        oversizedFileSentence,
      );
    }

    final Excel workbook;
    try {
      workbook = Excel.decodeBytes(file.bytes);
    } on Object {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }

    for (final sheet in workbook.tables.values) {
      if (sheet.maxRows <= 0 || sheet.maxColumns <= 0) continue;
      if (sheet.maxRows * sheet.maxColumns > _maxSheetCells) {
        return const ExtractionFailure(
          ExtractionFailureKind.unreadable,
          'That spreadsheet is too large to read.',
        );
      }
      final grid = [
        for (final row in sheet.rows)
          [for (final cell in row) _sourceCell(cell?.value)],
      ];
      final text = renderPlanRows(planRowsFromGrid(grid));
      if (text.isEmpty) continue;
      return ExtractedText(
        text: text,
        notes: ['Read from the "${sheet.sheetName}" sheet'],
      );
    }

    return const ExtractionFailure(
      ExtractionFailureKind.empty,
      emptyFileSentence,
    );
  }

  /// One container cell mapped onto the row model's typed cells.
  static SourceCell? _sourceCell(CellValue? value) => switch (value) {
        null => null,
        DateCellValue(:final year, :final month, :final day) =>
          DateCell(DateTime(year, month, day)),
        // A combined date+time cell splits along the same line the row
        // model does: its calendar part is the certain date, its
        // time-of-day is dropped rather than smuggled in as a second date
        // fact — a sheet that wants the time typed separately already has
        // TimeCellValue for that.
        DateTimeCellValue(:final year, :final month, :final day) =>
          DateCell(DateTime(year, month, day)),
        TimeCellValue(:final hour, :final minute) => TimeCell(hour, minute),
        TextCellValue() => TextCell(value.toString()),
        IntCellValue() => TextCell(value.value.toString()),
        DoubleCellValue() => TextCell(_doubleAsText(value.value)),
        BoolCellValue() => TextCell(value.value ? 'TRUE' : 'FALSE'),
        // A formula's cached value isn't exposed by this package, and
        // pasting a range out of Excel yields values, not formulas — so a
        // formula cell contributes nothing rather than formula junk.
        FormulaCellValue() => null,
      };

  /// `14` stays `14`; only genuine fractions keep their decimal part
  /// (`14.5`). Dart renders `14.0` for a whole double, which would read as
  /// noise in an itinerary line.
  static String _doubleAsText(double d) =>
      d == d.roundToDouble() && d.abs() < 1e15
          ? d.toInt().toString()
          : d.toString();
}
