// APP STATE band (docs/architecture.md): the file-import flow's state.
//
// Import is not a second parser — it is a second way to fill the paste box
// (the import plan §2.5). This file holds the extractor registry, routes one
// picked file to the extractor that claims it, runs that extraction off the
// UI thread, and reports a standing to the screen: reading, or a typed
// refusal with its person-showable sentence. The text itself goes straight
// into the existing paste box; `PasteFlow.parse()` needs zero new state or
// methods for any of this, which is what keeps the merge guard, the
// month-first flip and every re-read route out of this feature's blast
// radius. Over a running trip an import composes with them for free: the box
// fills, "Read it again" merges, displaced stops land in the set-aside.
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plan_extraction/plan_extraction.dart';

import 'file_picker_edge.dart';

// ---------------------------------------------------------------------------
// The registry — one line per format this build can read. Slices B/C/D add
// exactly one entry each; the picker filter and the pill's format list are
// derived from these claims, so nothing else on the import path edits when a
// new format lands.
// ---------------------------------------------------------------------------

// Slice C's csv sits ahead of plain text: both read decodable text, and
// only the extension can tell them apart, so csv must get the registry's
// extension-gated claim first (see csv_extractor.dart).
const List<PlanTextExtractor> planExtractors = [
  CsvExtractor(),
  PlainTextExtractor(),
  DocxExtractor(),
  XlsxExtractor(),
];

/// What the real document picker may offer: every extension some registered
/// extractor claims. Sorted so the UTType list is stable.
Set<String> get supportedImportExtensions => {
  for (final extractor in planExtractors) ...extractor.extensions,
};

/// The pill's honest sub-line: only the formats this build actually reads.
String get supportedFormatsLabel =>
    supportedImportExtensions.map((e) => '.$e').join(' · ');

/// Routes [file] to the extractor that claims it — magic bytes first, so a
/// mis-named file lands where its content belongs, then the named extension
/// as the tiebreak (the plan's risk 10: people rename files). Null when no
/// extractor claims it at all.
PlanTextExtractor? routeToExtractor(PickedBytes file) {
  for (final extractor in planExtractors) {
    if (extractor.matches(file)) return extractor;
  }
  for (final extractor in planExtractors) {
    if (extractor.extensions.contains(file.extension)) return extractor;
  }
  return null;
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

sealed class ImportState {
  const ImportState();
}

/// The pill, ready for another import.
class ImportIdle extends ImportState {
  const ImportIdle();
}

/// Progress, drawn inline in place of the pill. No modal, no blocked box.
class ImportReading extends ImportState {
  final String fileName;

  const ImportReading(this.fileName);
}

/// The error card above the paste box. Stays until dismissed; the box and
/// every other door stay usable underneath.
class ImportFailed extends ImportState {
  final ExtractionFailureKind kind;
  final String explanation;

  const ImportFailed(this.kind, this.explanation);
}

/// A success returned to the screen, which fills the paste box with [text]
/// and may show [notes] ("Read 3 pages") beside it. Partial reads land here
/// rather than in a refusal, because the person can fix a partial read in
/// the editor but can't fix a dead end.
class ImportSucceeded {
  final String text;
  final List<String> notes;

  const ImportSucceeded({required this.text, this.notes = const []});
}

// ---------------------------------------------------------------------------
// The notifier
// ---------------------------------------------------------------------------

/// How an extraction reaches a worker. Production hands the pure extractor
/// call to `Isolate.run`; tests inject the direct call, because a real
/// isolate under `testWidgets`' fake clock hangs silently (CLAUDE.md).
typedef ExtractionRunner = Future<ExtractionResult> Function(
  PlanTextExtractor extractor,
  PickedBytes file,
);

final extractionRunnerProvider = Provider<ExtractionRunner>((ref) {
  return (extractor, file) => Isolate.run(() => extractor.extract(file));
});

final importFlowProvider = NotifierProvider<ImportFlow, ImportState>(
  ImportFlow.new,
);

class ImportFlow extends Notifier<ImportState> {
  @override
  ImportState build() => const ImportIdle();

  /// One import: pick, read, extract. Returns the extracted text on success
  /// — the screen fills the box with it — and null otherwise, leaving the
  /// reason in [state]: a dismissal changes nothing, a refusal shows the
  /// error card.
  Future<ImportSucceeded?> pickAndExtract() async {
    if (state is ImportReading) return null;

    final PickedBytes? picked;
    try {
      picked = await ref
          .read(filePickerEdgeProvider)
          .pick(allowedExtensions: supportedImportExtensions);
    } catch (_) {
      // The picker itself declined — a platform quirk, not the person's
      // file. Same honest card, picker-specific words.
      state = const ImportFailed(
        ExtractionFailureKind.unreadable,
        "Couldn't open the file picker — try again.",
      );
      return null;
    }
    if (picked == null) return null; // dismissed; nothing happened

    state = ImportReading(picked.fileName);
    try {
      final result = await _read(picked);
      return switch (result) {
        ExtractedText(:final text, :final notes) => _deliver(text, notes),
        ExtractionFailure(:final kind, :final explanation) => _refuse(
          kind,
          explanation,
        ),
      };
    } catch (_) {
      // Extractors promise never to throw; this catches the ways the world
      // around one can still fail (a killed isolate, memory pressure).
      return _refuse(ExtractionFailureKind.unreadable, unreadableFileSentence);
    }
  }

  /// Clears the error card.
  void dismiss() {
    if (state is ImportFailed) state = const ImportIdle();
  }

  /// The pill comes back the moment the read lands; the box-filling is the
  /// screen's half, done with what this returns.
  ImportSucceeded? _deliver(String text, List<String> notes) {
    state = const ImportIdle();
    return ImportSucceeded(text: text, notes: notes);
  }

  /// Never leaves the flow mid-read: the outcome replaces the progress state
  /// before the caller sees it.
  ImportSucceeded? _refuse(ExtractionFailureKind kind, String explanation) {
    state = ImportFailed(kind, explanation);
    return null;
  }

  Future<ExtractionResult> _read(PickedBytes picked) async {
    final extractor = routeToExtractor(picked);
    if (extractor == null) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }
    return ref.read(extractionRunnerProvider)(extractor, picked);
  }
}
