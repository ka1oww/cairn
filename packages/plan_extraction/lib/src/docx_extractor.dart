// The .docx extractor: hand-rolled over `archive` + `xml` (the import plan
// §3). A docx is a zip; its text is `word/document.xml` in WordprocessingML.
// A depth-first walk gives faithful line order in ~a hundred lines:
//
//   w:p                one output line per paragraph
//   w:t                a text run inside a paragraph
//   w:br / w:cr / w:tab    a break or tab, joined as a space
//   w:tbl > w:tr > wtc cells hold ordinary paragraphs, read row-major
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
        'That file is larger than 25 MB — too big to read.',
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

  /// Depth-first over the body: paragraphs become lines, tables are walked
  /// row-major (each cell recursed, so nested tables land in order), and
  /// anything else with children is descended into (content controls,
  /// textboxes).
  static List<String> _documentLines(XmlDocument xml) {
    final out = <String>[];
    void visit(XmlElement element) {
      switch (element.name.local) {
        case 'p':
          final line = _collapse(_paragraphText(element));
          if (line.isNotEmpty) out.add(line);
        case 'tbl':
          for (final row in element.children.whereType<XmlElement>()) {
            if (row.name.local != 'tr') continue;
            for (final cell in row.children.whereType<XmlElement>()) {
              if (cell.name.local != 'tc') continue;
              for (final child in cell.children.whereType<XmlElement>()) {
                visit(child);
              }
            }
          }
        default:
          for (final child in element.children.whereType<XmlElement>()) {
            visit(child);
          }
      }
    }

    for (final node in xml.children.whereType<XmlElement>()) {
      if (node.name.local == 'body') {
        for (final child in node.children.whereType<XmlElement>()) {
          visit(child);
        }
      } else {
        visit(node);
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
