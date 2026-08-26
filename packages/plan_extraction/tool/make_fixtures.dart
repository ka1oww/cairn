// Fixture generation for every extractor, committed as binaries under
// test/fixtures/; this script is the record of how each was made (the
// import plan's test strategy §7). Run from inside packages/plan_extraction:
//
//   dart run tool/make_fixtures.dart
//
// Everything here is deterministic: re-running rewrites byte-identical
// fixtures.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

/// The tidy itinerary shared by the encoding fixtures: dated headers parse
/// high-confidence, so any decode mistake shows up immediately in the
/// extractor round-trip.
const tidyPlan = '''
Mon 14 June 2027 - Tokyo
- Senso-ji at 9:00
- Ueno Park picnic
- Caf\u00e9 stop on the way

Tue 15 June 2027 - Kyoto
- Fushimi Inari at dawn
''';

/// The garbled itinerary the captain will stress-test with (the plan's §7):
/// authored ONCE here as text, then rendered into every container. Mixed
/// date dialects (`3/11` vs `11/3`, both ambiguous), a bare `1900` that
/// must stay a year and not become a time, hedged times that must not
/// star, emoji bullets, banter, a booking reference, an email signature and
/// page-footer noise. Slices B/C/D render this same const into their own
/// formats and assert extraction equivalence against [garbledPlanLines].
const garbledPlan = '''KYOTO & TOKYO - MARCH 2027 (draft v3)

Day 1 - Kyoto, 3/11
- 8:30 Fushimi Inari at dawn
- maybe 11:00 tea ceremony?
\u2022 Nishiki Market lunch crawl
\u{1F35C} Ichiran for dinner, solo booth obviously
Ken owes me \u00a5400 for the locker lol

Day 2 - Kyoto, 11/3
- Arashiyama bamboo grove around 9am-ish
- 1900 yen dinner budget, cheap izakaya by the station
Booking ref: PNX88K \u00b7 K's House Kyoto

Day 3 - Tokyo
- Shinkansen 10:12 to Tokyo
- teamLab Planets 14:00, tickets on my phone
Sent from my iPhone

Page 3 of 5
Kyoto & Tokyo itinerary \u2014 do not distribute
''';

final List<String> garbledPlanLines = garbledPlan
    .split('\n')
    .map((l) => l.replaceAll(RegExp(r'\s+'), ' ').trim())
    .where((l) => l.isNotEmpty)
    .toList();

void main() {
  final fixtures = Directory('test/fixtures');
  if (!fixtures.existsSync()) fixtures.createSync(recursive: true);

  void write(String name, List<int> bytes) =>
      File('test/fixtures/$name').writeAsBytesSync(bytes);

  // --- Slice A: plain text encodings --------------------------------------

  // UTF-8 without BOM — the overwhelming default.
  write('tidy-utf8.txt', utf8.encode(tidyPlan));

  // UTF-8 with BOM — what plenty of Windows editors still write.
  write('tidy-utf8-bom.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode(tidyPlan)]);

  // Windows line endings: CRLF is what Notepad has always produced.
  write('tidy-crlf.txt', utf8.encode(tidyPlan.replaceAll('\n', '\r\n')));

  // UTF-16 LE with BOM — Windows' "Unicode" save.
  write('tidy-utf16le-bom.txt', [
    0xFF,
    0xFE,
    ..._utf16CodeUnits(tidyPlan, littleEndian: true),
  ]);

  // UTF-16 BE with BOM — rare, but PowerTools and network tools emit it.
  write('tidy-utf16be-bom.txt', [
    0xFE,
    0xFF,
    ..._utf16CodeUnits(tidyPlan, littleEndian: false),
  ]);

  // Latin-1 / Windows-1252: the same plan with é as one byte (0xE9), which
  // strict UTF-8 decoding would refuse and the ladder must catch.
  write(
    'cafe-latin1.txt',
    tidyPlan.codeUnits.map((u) => u > 0xFF ? 0x3F : u).toList(),
  );

  // Empty and whitespace-only files: the honest empty-file sentence.
  write('empty.txt', const []);
  write('blank.txt', utf8.encode('\n   \n\t\n'));

  // --- Slice B's ground truth ---------------------------------------------

  // The garbled itinerary as text: the source every other container is
  // rendered FROM, and the equivalence baseline its tests read back.
  write('garbled-itinerary.txt', utf8.encode(garbledPlan));

  // --- Slice C: docx --------------------------------------------------------

  // A tidy itinerary laid out partly as Word tables: paragraphs and table
  // cells interleaved, cells read row-major, a soft line break (w:br)
  // joined as a space inside one cell.
  write(
    'tables.docx',
    _docx([
      _p('Mon 14 June 2027 - Tokyo'),
      _table([
        [_p('09:00'), _p('Senso-ji')],
        [_p('12:00'), _p('Ramen in Asakusa')],
      ]),
      _p('Tue 15 June 2027 - Kyoto'),
      _table([
        [
          _pRuns([
            _t('Fushimi Inari'),
            _raw('<w:br/>'),
            _t('at dawn'),
          ]),
        ],
      ]),
    ]),
  );

  // The shared garbled itinerary as a Word document: one paragraph per
  // line, which is what extraction must give back (modulo whitespace).
  write(
    'garbled-itinerary.docx',
    _docx([for (final line in garbledPlan.split('\n')) _p(line)]),
  );

  // An encrypted Office file is a CFB container, not a zip: refused as
  // unreadable, never decoded as junk. Bytes are just the 8-byte magic.
  write('encrypted.docx', [
    0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0xAE, 0x1A,
    ...List.filled(64, 0),
  ]);

  // Not a docx at all: a plain-text file wearing the extension. Neither
  // OOXML sibling may claim it.
  write('not-a-docx.docx', utf8.encode('Mon 14 June 2027 - Tokyo'));

  // --- Slice C: xlsx --------------------------------------------------------

  // Agency layout with genuinely date-typed cells in the first column and
  // a time-typed cell: the dialect path. The label row lands ahead of the
  // first day; the multi-line cell splits into two stops; the time stars
  // the first stop of its own row.
  final dated = Excel.createExcel();
  final datedSheet = dated['Sheet1'];
  void datedRow(List<CellValue?> cells) => datedSheet.appendRow(cells);
  datedRow([
    TextCellValue('Date'),
    TextCellValue('City'),
    TextCellValue('Plan'),
  ]);
  datedRow([
    DateCellValue(year: 2027, month: 6, day: 14),
    TextCellValue('Tokyo'),
    TextCellValue('Senso-ji at 9:00\nUeno Park picnic'),
  ]);
  datedRow([
    DateCellValue(year: 2027, month: 6, day: 15),
    TextCellValue('Kyoto'),
    TimeCellValue(hour: 9, minute: 30),
    TextCellValue('Fushimi Inari'),
  ]);
  write('dated-sheet.xlsx', dated.save()!);

  // The same table with the dates as TEXT strings: no typed date column,
  // so heuristic v1 falls back to faithful row-major lines and lets the
  // parser ask.
  final textual = Excel.createExcel();
  final textualSheet = textual['Sheet1'];
  textualSheet.appendRow([
    TextCellValue('Date'),
    TextCellValue('City'),
    TextCellValue('Plan'),
  ]);
  textualSheet.appendRow([
    TextCellValue('14 June'),
    TextCellValue('Tokyo'),
    TextCellValue('Senso-ji at 9:00'),
  ]);
  textualSheet.appendRow([
    TextCellValue('15 June'),
    TextCellValue('Kyoto'),
    TextCellValue('Fushimi Inari'),
  ]);
  write('text-sheet.xlsx', textual.save()!);

  // A workbook whose only sheet holds no values: the honest empty-file
  // sentence.
  final blank = Excel.createExcel();
  write('empty.xlsx', blank.save()!);

  // --- Slice C: csv ---------------------------------------------------------

  // An ISO date column takes the dialect path; a quoted field keeps its
  // comma; the header labels land ahead of the first day.
  write(
    'dated.csv',
    utf8.encode('''
Date,City,Plan
2027-06-14,Tokyo,"Senso-ji at 9:00, then Ueno"
2027-06-15,Kyoto,Fushimi Inari
'''),
  );

  // No ISO dates anywhere: faithful lines, parser asks.
  write(
    'plain.csv',
    utf8.encode('''
Day,Place,Notes
1,Kyoto,"3/11, Fushimi Inari early"
2,Kyoto,Bamboo grove
'''),
  );

  stdout.writeln('fixtures written under test/fixtures/');
}

List<int> _utf16CodeUnits(String text, {required bool littleEndian}) {
  final bytes = <int>[];
  for (final unit in text.codeUnits) {
    final hi = unit >> 8;
    final lo = unit & 0xFF;
    bytes.addAll(littleEndian ? [lo, hi] : [hi, lo]);
  }
  return bytes;
}

// ---------------------------------------------------------------------------
// A minimal OOXML (docx) writer: enough of the container for Word to open
// it and for the extractor (and any other WordprocessingML reader) to walk
// it. Deterministic by construction — no timestamps go into the zip.
// ---------------------------------------------------------------------------

String _escape(String raw) => raw
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String _t(String text) => '<w:r><w:t xml:space="preserve">'
    '${_escape(text)}</w:t></w:r>';

String _p(String text) =>
    '<w:p>${text.isEmpty ? '' : _t(text)}</w:p>';

String _pRuns(List<String> runs) => '<w:p>${runs.join()}</w:p>';

String _raw(String xml) => xml;

String _table(List<List<String>> rowsInXml) => '<w:tbl>'
    '${[
      for (final row in rowsInXml)
        '<w:tr>${[
          for (final cell in row) '<w:tc>$cell</w:tc>',
        ].join()}</w:tr>',
    ].join()}</w:tbl>';

List<int> _docx(List<String> bodyChildrenXml) {
  const xmlDeclaration =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
  final document = '$xmlDeclaration'
      '<w:document '
      'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>${bodyChildrenXml.join()}<w:sectPr/></w:body></w:document>';
  const contentTypes = '$xmlDeclaration'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/'
      'content-types">'
      '<Default Extension="rels" ContentType="application/vnd.'
      'openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.'
      'openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>';
  const rels = '$xmlDeclaration'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/'
      'relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/'
      'officeDocument/2006/relationships/officeDocument" '
      'Target="word/document.xml"/></Relationships>';

  final archive = Archive()
    ..addFile(_stored('[Content_Types].xml', contentTypes))
    ..addFile(_stored('_rels/.rels', rels))
    ..addFile(_stored('word/document.xml', document));
  return ZipEncoder().encode(archive)!;
}

ArchiveFile _stored(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}
