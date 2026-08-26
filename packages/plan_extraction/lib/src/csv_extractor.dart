// The .csv extractor: the same row model and dialect renderer as xlsx (the
// import plan calls it the freebie — §5). CSV carries no types, so nothing
// here knows a date *for certain* except one narrow literal shape: a cell
// that is exactly an ISO date (`2027-06-14`) is lifted as a DateCell,
// keeping csv symmetric with xlsx's `DateCellValue.toString()`. Anything
// else stays text for the parser's own grammar to judge — no second date
// grammar lives here, and an ambiguous numeric CSV column (`3/11`) falls
// back to faithful lines the parser asks about exactly as if pasted.
//
// Routing: plain text (slice A) claims any decodable bytes on the
// registry's content pass, so two text formats cannot be told apart by
// content alone. This extractor therefore claims on its *extension* first
// in the registry list, refuses known binary magics, and re-checks them in
// [extract] — a PDF renamed `.csv` is refused honestly, never mojibake.
import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';

import '../plan_extraction.dart';
import 'plan_rows.dart';

class CsvExtractor implements PlanTextExtractor {
  const CsvExtractor();

  @override
  Set<String> get extensions => const {'csv'};

  @override
  bool matches(PickedBytes file) {
    if (file.extension != 'csv') return false;
    return !startsWithBinaryMagic(file.bytes);
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
    // The self-guard: whatever the name said, real container bytes are not
    // a CSV, and decoding them as text would only fill the box with junk.
    if (startsWithBinaryMagic(file.bytes)) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }

    final text = _decode(file.bytes);

    List<List<dynamic>> table;
    try {
      // dynamicTyping stays false: a phone number or price keeps its own
      // digits verbatim as text, as the class comment promises.
      table = const CsvDecoder().convert(text);
    } on Object {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }

    final grid = [
      for (final row in table)
        [
          // Raw strings only (`shouldParseNumbers: false`): a phone number
          // or price keeps its own digits verbatim.
          for (final cell in row)
            if (cell != null) _cell(cell.toString()),
        ],
    ];

    final rendered = renderPlanRows(planRowsFromGrid(grid));
    if (rendered.isEmpty) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        emptyFileSentence,
      );
    }
    return ExtractedText(text: rendered);
  }

  /// UTF-8 first (BOM stripped), Latin-1 as the never-fails fallback — a
  /// narrow version of slice A's ladder; agency CSVs are one or the other.
  static String _decode(Uint8List bytes) {
    var payload = bytes;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      payload = Uint8List.sublistView(bytes, 3);
    }
    try {
      return utf8.decode(payload);
    } on FormatException {
      return latin1.decode(payload, allowInvalid: true);
    }
  }
}

/// The container magics a mis-named file might carry. Narrow by design:
/// this gates a *claim*, it is not a format detector. Every signature is
/// written out in full — a two-byte prefix of an ASCII magic (`RI`, `Ra`,
/// `GI`, `%P`, `7z`) is also how an ordinary CSV's first field can begin,
/// and refusing `Raffles Hotel,2027-06-14` would drop the file through to
/// plain text and lose its date column.
bool startsWithBinaryMagic(List<int> bytes) => [
      [0x50, 0x4B, 0x03, 0x04], // zip (docx/xlsx)
      [0x50, 0x4B, 0x05, 0x06], // empty zip
      [0x50, 0x4B, 0x07, 0x08], // spanned zip
      [0x25, 0x50, 0x44, 0x46, 0x2D], // %PDF-
      [0x89, 0x50, 0x4E, 0x47], // PNG
      [0x47, 0x49, 0x46, 0x38], // GIF8
      [0xFF, 0xD8, 0xFF], // JPEG
      [0x52, 0x49, 0x46, 0x46], // RIFF
      [0xD0, 0xCF, 0x11, 0xE0], // legacy Office CFB
      [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], // 7z
      [0x52, 0x61, 0x72, 0x21], // Rar!
    ].any((magic) => _hasPrefix(bytes, magic));

bool _hasPrefix(List<int> bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

/// One CSV cell: exactly an ISO-shaped whole-cell date becomes a typed
/// date; everything else arrives as its written text.
SourceCell _cell(String raw) {
  final text = raw.trim();
  final m = _isoShape.firstMatch(text);
  if (m != null) {
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    // DateTime rolls overflow silently (Feb 30 → Mar 2); requiring the
    // components to survive the round trip keeps `2027-02-30` honest text.
    final date = DateTime(year, month, day);
    if (date.year == year && date.month == month && date.day == day) {
      return DateCell(date);
    }
  }
  return TextCell(text);
}

final RegExp _isoShape = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$');
