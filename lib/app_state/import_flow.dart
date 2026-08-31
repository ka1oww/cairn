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
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plan_extraction/plan_extraction.dart';

import 'area_gazetteer_loader.dart';
import 'file_picker_edge.dart';
import 'text_recognition_edge.dart';

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
  PdfExtractor(),
  DocxExtractor(),
  XlsxExtractor(),
];

/// The document formats this build reads: every extension some registered
/// extractor claims. Slices add extractors, not entries here.
Set<String> get documentImportExtensions => {
  for (final extractor in planExtractors) ...extractor.extensions,
};

/// What the real document picker may offer — the documents *and* the
/// pictures. A screenshot saved into Files is the same screenshot as one in
/// the photo library, and the person does not know or care which door they
/// are standing at (captain's decision, 2026-08-27), so the file door offers
/// both and [ImportFlow._read] routes a picked image to the very same
/// recognition path the photo door uses. `UTType(filenameExtension:)` on the
/// darwin side resolves each of these, so no UTType list is written out here.
Set<String> get supportedImportExtensions => {
  ...documentImportExtensions,
  ...imageImportExtensions,
};

/// The pill's honest sub-line: the document formats spelled out, then one
/// word for the pictures — naming all ten image extensions would bury the
/// formats a person actually looks for.
String get supportedFormatsLabel =>
    '${documentImportExtensions.map((e) => '.$e').join(' · ')} · pictures';

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
// The image route (slice D)
//
// Recognition is not an extractor — it is a platform call — so pictures
// never enter [planExtractors]. They are claimed here, by extension first
// and magic bytes second (a renamed screenshot still routes by its content),
// and read
// through [textRecognitionEdgeProvider] into the same [ExtractedText] shape
// every other format produces.
// ---------------------------------------------------------------------------

/// Extensions this build reads as pictures rather than as documents.
const Set<String> imageImportExtensions = {
  'png',
  'jpg',
  'jpeg',
  'heic',
  'heif',
  'webp',
  'gif',
  'bmp',
  'tif',
  'tiff',
};

/// True when [file] says *picture* — its claimed extension is one of
/// [imageImportExtensions], or, failing that, its leading bytes carry a known
/// image signature (so a `.dat`-renamed screenshot still finds the OCR
/// route). Note the precedence this creates: [ImportFlow._read] asks this
/// before [routeToExtractor], so an extension-based image claim pre-empts an
/// extractor's magic-byte match — a text file named `.png` goes to OCR.
bool claimsImage(PickedBytes file) {
  final ext = file.extension;
  if (ext != null && imageImportExtensions.contains(ext)) return true;
  return _imageMagic(file.bytes);
}

bool _imageMagic(Uint8List b) {
  if (b.length < 12) return false;
  bool startsWith(List<int> sig, [int at = 0]) {
    if (b.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[at + i] != sig[i]) return false;
    }
    return true;
  }

  if (startsWith([0x89, 0x50, 0x4E, 0x47])) return true; // PNG
  if (startsWith([0xFF, 0xD8, 0xFF])) return true; // JPEG
  if (startsWith('GIF8'.codeUnits)) return true; // GIF87a/89a
  if (startsWith('BM'.codeUnits)) return true; // BMP
  if (startsWith('II'.codeUnits) && b[2] == 42) return true; // TIFF LE
  if (startsWith('MM'.codeUnits) && b[3] == 42) return true; // TIFF BE
  if (startsWith('RIFF'.codeUnits) && startsWith('WEBP'.codeUnits, 8)) {
    return true; // WebP
  }
  // HEIC/HEIF: an ISO-BMFF box — 'ftyp' at offset 4 with a known brand.
  if (startsWith('ftyp'.codeUnits, 4)) {
    const brands = ['heic', 'heix', 'heim', 'heis', 'mif1', 'msf1'];
    final brand = String.fromCharCodes(b.sublist(8, 12)).toLowerCase();
    return brands.contains(brand);
  }
  return false;
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
/// [detail] replaces the file name while a multi-page read is under way
/// ("page 2 of 8" — OCR reports per page).
class ImportReading extends ImportState {
  final String fileName;
  final String? detail;

  const ImportReading(this.fileName, {this.detail});
}

/// The error card above the paste box. Stays until dismissed; the box and
/// every other door stay usable underneath. When [canTryTextRecognition]
/// is set the card carries the one-tap OCR route (the scanned-PDF door:
/// the file read fine but its pages are pictures, and recognition can read
/// those).
class ImportFailed extends ImportState {
  final ExtractionFailureKind kind;
  final String explanation;
  final bool canTryTextRecognition;

  const ImportFailed(
    this.kind,
    this.explanation, {
    this.canTryTextRecognition = false,
  });
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

  /// True from the moment the picker is asked for until the read has landed.
  /// [state] cannot carry this: it stays [ImportIdle] while the document
  /// picker is on screen, so a second tap of the pill would present a second
  /// picker — which iOS refuses, and the refusal reads as the person's file
  /// being unopenable when nothing went wrong. It guards every door into
  /// [_import], the photo library's included.
  bool _running = false;

  /// The bytes of the last pick refused as `noTextLayer`, kept so the
  /// card's one-tap OCR route can re-read them through the recognition
  /// edge. Cleared once the route is taken (or a new import begins).
  PickedBytes? _scanCandidate;

  /// One import from the document picker: pick, read, extract. Returns the
  /// extracted text on success — the screen fills the box with it — and
  /// null otherwise, leaving the reason in [state]: a dismissal changes
  /// nothing, a refusal shows the error card.
  Future<ImportSucceeded?> pickAndExtract() => _import(
    () => ref
        .read(filePickerEdgeProvider)
        .pick(allowedExtensions: supportedImportExtensions),
  );

  /// One import from the photo library: the screenshots-and-photos door.
  /// Same pipeline after the pick — an image routes to recognition exactly
  /// as it would from anywhere else.
  Future<ImportSucceeded?> pickAndReadPhoto() =>
      _import(() => ref.read(filePickerEdgeProvider).pickImage());

  /// Clears the error card.
  void dismiss() {
    _scanCandidate = null;
    if (state is ImportFailed) state = const ImportIdle();
  }

  /// The scanned-PDF door's one tap: re-reads the refused file through the
  /// recognition edge. Only offered while its card stands; any other state
  /// means there is nothing to retry.
  Future<ImportSucceeded?> readScanWithRecognition() async {
    final candidate = _scanCandidate;
    if (candidate == null || state is! ImportFailed) return null;
    _scanCandidate = null;
    return _runRead(candidate, viaOcrRoute: true);
  }

  Future<ImportSucceeded?> _import(Future<PickedBytes?> Function() pick) async {
    if (_running || state is ImportReading) return null;
    _running = true;
    try {
      return await _pick(pick);
    } finally {
      _running = false;
    }
  }

  Future<ImportSucceeded?> _pick(Future<PickedBytes?> Function() pick) async {
    _scanCandidate = null;

    final PickedBytes? picked;
    try {
      picked = await pick();
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

    return _runRead(picked);
  }

  /// Reads [picked] and settles on the outcome. Never leaves the flow
  /// mid-read: the outcome replaces the progress state before the caller
  /// sees it.
  Future<ImportSucceeded?> _runRead(
    PickedBytes picked, {
    bool viaOcrRoute = false,
  }) async {
    state = ImportReading(picked.fileName);
    // The area gazetteer's one load (the tap-to-Maps plan §9), started here
    // and nowhere else: an import is the only act slow enough to hide it,
    // and it must never happen at launch or on the day/trail path. It is
    // started rather than awaited so that it overlaps the extraction and
    // costs the import only whatever is left of it, and it is awaited
    // before the text reaches the box so that the parse that follows sees
    // it. It cannot fail the import — a load that goes wrong leaves the
    // gazetteer null, which is phase-1 behaviour (see the loader).
    final gazetteerLoad = ref
        .read(areaGazetteerProvider.notifier)
        .ensureLoaded();
    try {
      // The one-tap route reads the bytes with recognition whatever they
      // claim to be: it is offered precisely because the extractor that
      // owns that format already said the pages are pictures.
      final result = viaOcrRoute
          ? await _recognize(picked)
          : await _read(picked);
      await gazetteerLoad;
      return switch (result) {
        ExtractedText(:final text, :final notes) => _deliver(text, notes),
        ExtractionFailure(:final kind, :final explanation) when viaOcrRoute =>
          _refuse(kind, explanation),
        ExtractionFailure(kind: ExtractionFailureKind.noTextLayer) =>
          _offerTheOcrRoute(picked),
        ExtractionFailure(:final kind, :final explanation) => _refuse(
          kind,
          explanation,
        ),
      };
    } on RecognitionRefused catch (e) {
      // Two flavours, and confusing them is the whole of the import
      // torture-test's R5: a device that cannot recognize text at all is
      // honestly the device's problem and says so, but a picture
      // recognition read perfectly well and found no text in is the
      // *picture's*, and blaming the phone for it reads as a broken phone.
      // A picture with nothing in it therefore lands on exactly the
      // sentence an empty answer already gets, from the one place that
      // sentence is written.
      return switch (e.kind) {
        RecognitionRefusalKind.noTextFound => _refuse(
          ExtractionFailureKind.empty,
          noReadableTextInPictureSentence,
        ),
        // Anything else carries its own person-showable sentence from the
        // edge, and reaches the card verbatim.
        RecognitionRefusalKind.unavailable => _refuse(
          ExtractionFailureKind.unreadable,
          e.reason,
        ),
      };
    } catch (_) {
      // Extractors promise never to throw, and other recognition failures
      // are typed; this catches the ways the world around them can still
      // fail (a killed isolate, memory pressure).
      return _refuse(ExtractionFailureKind.unreadable, unreadableFileSentence);
    }
  }

  /// A PDF whose pages are pictures: refuse with the honest sentence *and*
  /// keep the bytes, so the same card can offer reading them with text
  /// recognition instead.
  ImportSucceeded? _offerTheOcrRoute(PickedBytes scanned) {
    _scanCandidate = scanned;
    state = const ImportFailed(
      ExtractionFailureKind.noTextLayer,
      noReadableTextLayerSentence,
      canTryTextRecognition: true,
    );
    return null;
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
    // Routing itself is real work — every `matches` decodes or unzips the
    // whole file, on this isolate — so the size refusal has to come before
    // it, not only inside the extraction the runner carries away.
    if (picked.bytes.length > maxPlainBytes) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        oversizedFileSentence,
      );
    }
    // Pictures next: they are claimed by content, not by the extractor
    // registry, because recognition is a platform call and cannot be a pure
    // extractor (the import plan §2.4).
    if (claimsImage(picked)) return _recognize(picked);

    final extractor = routeToExtractor(picked);
    if (extractor == null) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }
    return ref.read(extractionRunnerProvider)(extractor, picked);
  }

  /// One picture (or scanned PDF), recognized into the shape every other
  /// format produces. An empty answer is honest — a photograph of a wall
  /// contains no text — but still a dead end for this flow, so it refuses
  /// with the empty-kind words rather than filling the box with nothing.
  Future<ExtractionResult> _recognize(PickedBytes picked) async {
    final scan = await ref
        .read(textRecognitionEdgeProvider)
        .recognize(
          picked.bytes,
          onPage: (page, of) {
            if (state is ImportReading) {
              state = ImportReading(
                picked.fileName,
                detail: 'page $page of $of',
              );
            }
          },
        );
    final text = scan.lines.join('\n').trim();
    if (text.isEmpty) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        noReadableTextInPictureSentence,
      );
    }
    return ExtractedText(
      text: text,
      notes: ['Read ${scan.pageCount} page${scan.pageCount == 1 ? '' : 's'}'],
    );
  }
}

/// The sentences this flow authors itself (the rest come from extractors or
/// the recognition edge).
const unreadableFileSentence =
    "Couldn't read that file — it may be damaged or password-protected.";
const noReadableTextInPictureSentence =
    "Couldn't find any readable text in that picture.";
const noReadableTextLayerSentence =
    "This PDF has no readable text — it looks like a scan or photos. Read it "
    "with text recognition instead?";
