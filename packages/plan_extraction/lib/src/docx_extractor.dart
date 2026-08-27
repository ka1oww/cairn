// The .docx extractor: hand-rolled over `archive` + `xml` (the import plan
// §3). A docx is a zip; its text is `word/document.xml` in WordprocessingML.
// A depth-first walk gives faithful line order in ~a hundred lines:
//
//   w:p                one output line per paragraph
//   w:t                a text run inside a paragraph
//   w:br / w:cr / w:tab    a break or tab, joined as a space
//   w:tbl > w:tr > w:tc    one output line per *row*, cells joined
//
// The row rule is the row model's rule, arrived at the other way round. A
// spreadsheet says `[08:30 | Fushimi Inari]` as one starred stop because
// its cells are typed and `plan_rows.dart` pairs them; a Word table is
// laid out the same way by the same people but carries no typing at all,
// so nothing in that file could pair its cells — it would fall through to
// the untyped path and emit one line per cell, which is the bug. A row is
// therefore said as one line here, in column order, and the *parser's*
// own grammar reads the leading `08:30` exactly as it reads the rendered
// dialect's `- 08:30 Fushimi Inari`. What is deliberately not done is
// teach `plan_rows.dart` a second time grammar over text cells: that file
// says in its own head that no such grammar lives there, and it would
// change what xlsx and csv already do.
//
// A row with only one filled cell keeps its paragraphs as separate lines.
// Single-column tables are layout, not pairing — a day whose stops are
// paragraphs inside one cell must not collapse into a single stop.
//
// `word/header*.xml` / `footer*.xml` are skipped deliberately: we only ever
// open document.xml. Legacy binary `.doc` and encrypted OOXML (both CFB
// containers, not zips) are not claimed by [matches] at all, so they fall to
// the registry's honest refusal rather than pretending to be readable.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../plan_extraction.dart';

/// The zip local-file-header magic every OOXML container starts with.
const List<int> _zipMagic = [0x50, 0x4B, 0x03, 0x04];

/// True when [bytes] start with the zip magic — the first gate every
/// OOXML sibling (docx, xlsx) shares before looking inside.
bool isZipMagic(List<int> bytes) => _startsWith(bytes, _zipMagic);

class DocxExtractor implements PlanTextExtractor {
  const DocxExtractor();

  @override
  Set<String> get extensions => const {'docx'};

  @override
  bool matches(PickedBytes file) {
    if (!isZipMagic(file.bytes)) return false;
    return _documentXml(file.bytes) != null;
  }

  @override
  ExtractionResult extract(PickedBytes file) {
    if (file.bytes.isEmpty) {
      return const ExtractionFailure(ExtractionFailureKind.empty, emptyFileSentence);
    }
    if (file.bytes.length > maxPlainBytes) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        oversizedFileSentence,
      );
    }
    final document = _documentXml(file.bytes);
    if (document == null) {
      // Not a zip, or a zip with no word/document.xml: damaged, or not a
      // Word file however it was named.
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }

    final XmlDocument xml;
    try {
      xml = XmlDocument.parse(utf8.decode(document));
    } on Object {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }

    final lines = _documentLines(xml);
    if (lines.isEmpty) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        emptyFileSentence,
      );
    }
    return ExtractedText(text: lines.join('\n'));
  }

  /// The bytes of `word/document.xml`, or null when this zip has none.
  static Uint8List? _documentXml(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object {
      return null;
    }
    for (final entry in archive) {
      if (entry.name != 'word/document.xml') continue;
      try {
        final content = entry.content;
        if (content is Uint8List) return content;
        return Uint8List.fromList((content as List<int>).toList());
      } on Object {
        return null;
      }
    }
    return null;
  }

  /// Depth-first over the body: paragraphs become lines, a table row
  /// becomes one line with its cells joined (each cell recursed first, so
  /// nested tables and their own rows land in order), and anything else
  /// with children is descended into (content controls, textboxes).
  static List<String> _documentLines(XmlDocument xml) {
    final body = xml.children
        .whereType<XmlElement>()
        .expand(
          (node) => node.name.local == 'body'
              ? node.children.whereType<XmlElement>()
              : [node],
        );
    return _linesOf(body);
  }

  /// The lines [elements] say, in document order.
  static List<String> _linesOf(Iterable<XmlElement> elements) {
    final out = <String>[];
    for (final element in elements) {
      switch (element.name.local) {
        case 'p':
          final line = _collapse(_paragraphText(element));
          if (line.isNotEmpty) out.add(line);
        case 'tbl':
          out.addAll(_tableLines(element));
        default:
          out.addAll(_linesOf(element.children.whereType<XmlElement>()));
      }
    }
    return out;
  }

  /// One line per row: the filled cells of a row, each said as its own
  /// lines and then joined in column order, so `[08:30][Fushimi Inari]`
  /// arrives as the one stop a reader sees. A row down to a single filled
  /// cell is layout rather than pairing and keeps its lines apart.
  static List<String> _tableLines(XmlElement table) {
    final out = <String>[];
    for (final row in table.children.whereType<XmlElement>()) {
      if (row.name.local != 'tr') continue;
      final cells = <List<String>>[
        for (final cell in row.children.whereType<XmlElement>())
          if (cell.name.local == 'tc')
            _linesOf(cell.children.whereType<XmlElement>()),
      ]..removeWhere((lines) => lines.isEmpty);
      if (cells.length <= 1) {
        out.addAll(cells.expand((lines) => lines));
      } else {
        out.add(_collapse(cells.map((lines) => lines.join(' ')).join(' ')));
      }
    }
    return out;
  }

  /// The visible text of one paragraph: text runs concatenated in order,
  /// breaks and tabs as spaces. Field instruction text and tracked
  /// deletions are machinery, not content; they contribute nothing.
  static String _paragraphText(XmlElement paragraph) {
    final buffer = StringBuffer();
    void walk(XmlElement element) {
      switch (element.name.local) {
        case 't':
          buffer.write(element.innerText);
        case 'br' || 'cr' || 'tab':
          buffer.write(' ');
        case 'instrText' || 'delText':
          break;
        default:
          for (final child in element.children.whereType<XmlElement>()) {
            walk(child);
          }
      }
    }

    for (final child in paragraph.children.whereType<XmlElement>()) {
      walk(child);
    }
    return buffer.toString();
  }
}

bool _startsWith(List<int> bytes, List<int> magic) {
  if (bytes.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[i] != magic[i]) return false;
  }
  return true;
}

/// Runs of whitespace collapse to single spaces: breaks and tabs were
/// joined as spaces above, and Word splits runs mid-word harmlessly. This
/// keeps one line per paragraph literally true.
String _collapse(String raw) =>
    raw.replaceAll(RegExp(r'\s+'), ' ').trim();
