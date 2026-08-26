// The extractor contract: the one shape every file-import slice codes
// against. Import is not a second parser — every format reduces to one
// `String` of lines that `PasteFlow.parse()` already understands, so this
// package's whole deliverable is *bytes in, honest lines of text out*.
//
// The two failures the parser never sees — a file that could not be read at
// all, and a file with no text in it — are typed here alongside the success,
// each carrying a sentence a person could read (the CameraRefused pattern).
// Extraction doubt needs no new ask UI: noisy extraction becomes unplaced
// lines and low-confidence days, which the confirm screen already knows how
// to ask about.
//
// Slices land as one extractor and one registry line each:
//
//   A  plain text (.txt)      B  PDF        C  docx / xlsx / csv
//   D  OCR via Apple Vision (a platform edge beside app state, not an
//      extractor — recognition is a platform call, not a pure function)
//
// Every extractor is synchronous, pure, and never throws; the app wraps the
// call in `Isolate.run` in production and calls it directly in tests (real
// isolates hang silently under the project's fake-clock widget tests).
library;

import 'dart:typed_data';

export 'src/plain_text_extractor.dart'
    show
        PlainTextExtractor,
        maxPlainBytes,
        unreadableFileSentence,
        emptyFileSentence;
export 'src/docx_extractor.dart' show DocxExtractor;
export 'src/xlsx_extractor.dart' show XlsxExtractor;
export 'src/csv_extractor.dart' show CsvExtractor;

/// One picked file, already read into memory by the app's picker edge.
/// The package never does IO: bytes in, text out.
class PickedBytes {
  /// For error copy and provenance (`Wanderlog.pdf`).
  final String fileName;

  /// Lowercased, no dot; null when the name has none.
  final String? extension;

  final Uint8List bytes;

  const PickedBytes({
    required this.fileName,
    this.extension,
    required this.bytes,
  });
}

/// What reading a picked file produced.
sealed class ExtractionResult {
  const ExtractionResult();
}

/// Text on its way to PasteFlow.parse(). [notes] is provenance a screen may
/// show ("Read 3 pages"), never something the parser sees.
class ExtractedText extends ExtractionResult {
  final String text;
  final List<String> notes;

  const ExtractedText({required this.text, this.notes = const []});
}

/// Why a read refused, at the two-plus-two granularities the pipeline can't
/// discover on its own.
enum ExtractionFailureKind {
  /// Damaged, or not a format any extractor can honestly read.
  unreadable,

  /// Read fine, but held no text at all.
  empty,

  /// Encrypted; asking for the password in-app is out of scope.
  passwordProtected,

  /// A PDF whose pages are images — the seam to the OCR route once slice D
  /// lands; until then an honest error card.
  noTextLayer,
}

/// The failures the parser never sees, each carrying a person-showable
/// sentence (the CameraRefused pattern — see camera_source.dart:41).
class ExtractionFailure extends ExtractionResult {
  final ExtractionFailureKind kind;

  /// A sentence a person could read.
  final String explanation;

  const ExtractionFailure(this.kind, this.explanation);
}

abstract interface class PlanTextExtractor {
  /// Extensions this extractor claims ('pdf'); the registry also probes magic
  /// bytes via [matches] so a mis-named file routes correctly.
  Set<String> get extensions;

  /// A cheap sniff, bounded to a prefix of the bytes however large the file
  /// is: routing runs on the UI thread, before the extraction hops to an
  /// isolate, so this must never do [extract]'s work over a whole file.
  bool matches(PickedBytes file);

  /// Synchronous, pure, never throws.
  ExtractionResult extract(PickedBytes file);
}
