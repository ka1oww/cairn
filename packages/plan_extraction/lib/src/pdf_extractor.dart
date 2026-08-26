// The PDF extractor: the text layer, page by page, in page order.
//
// The common case this exists for is not a PDF anybody generated as a PDF. A
// Wanderlog "export" is the browser's print-to-PDF of the trip page — there
// is no PDF generator in the product, only `window.print()` — so every
// genuine Wanderlog file carries a real, selectable text layer and needs no
// OCR at all. The same is true of the other artifacts a family actually
// shares: Google Docs exports, agency letters, Word's "Save as PDF". A PDF
// with *no* text layer is a scan or a photograph, and that is a different
// feature: this returns [ExtractionFailureKind.noTextLayer] and stops, which
// is the seam the OCR slice hangs its offer from.
//
// Three things about the engine are worth knowing before touching this file.
//
// **It is asynchronous all the way down, and that is not negotiable.** PDFium
// is not re-entrant, so `pdfrx_engine` serializes every call through one
// background worker isolate; there is no synchronous entry point to reach for.
// That is why the contract's `extract` returns a `FutureOr`.
//
// **PDFium is a native library, and on iOS it does not come from this
// package.** `pdfium_dart`'s build hook returns without emitting anything when
// the target OS is iOS; on Flutter/iOS the engine instead resolves PDFium with
// `DynamicLibrary.process()`, which only finds it if the app has linked the
// XCFramework. The app's root `pubspec.yaml` depends on `pdfium_flutter` for
// exactly that and nothing else. Under `dart test` the picture is the other
// way round: the build hook downloads a PDFium for the host machine once
// (see this package's README), and nothing is linked.
//
// **The worker isolate outlives the call unless it is stopped.** In
// production `extract` runs inside `Isolate.run`, which exits the moment the
// result is ready and would strand the worker it spawned. So the read stops
// the worker on its way out, in a `finally`; the engine re-creates it on the
// next call.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../plan_extraction.dart';
import 'text_cleanup.dart';

/// The plan's risk 7, the size half: extraction loads the whole file into
/// memory. An itinerary lives orders of magnitude under this.
const int maxPdfBytes = 25 * 1024 * 1024;

/// The plan's risk 7, the page half. A longer document is read up to here and
/// the read reports how much it took — partial success is success, because a
/// person can fix a partial read in the box and cannot fix a refusal.
const int maxPdfPages = 100;

/// §2.6's sentence for a PDF whose pages are pictures. Once the OCR slice
/// lands this is the kind that offers the camera's text recognition instead
/// of ending the road.
const String noTextLayerSentence =
    'This PDF has no readable text — it looks like a scan or photos. '
    'Paste the plan as text instead.';

/// §2.6 and risk 6: an honest sentence, never a password prompt. Asking for
/// the password in-app is scope creep the plan rules out by name.
const String passwordProtectedSentence =
    'That PDF is password-protected — remove the password and share it again.';

const String _oversizeSentence =
    'That PDF is larger than 25 MB — too big to read.';

class PdfExtractor implements PlanTextExtractor {
  const PdfExtractor();

  @override
  Set<String> get extensions => const {'pdf'};

  @override
  bool matches(PickedBytes file) => _headerOffset(file.bytes) != null;

  @override
  Future<ExtractionResult> extract(PickedBytes file) async {
    if (file.bytes.length > maxPdfBytes) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        _oversizeSentence,
      );
    }
    if (file.bytes.isEmpty) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        emptyFileSentence,
      );
    }
    if (_headerOffset(file.bytes) == null) {
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    }

    PdfDocument? document;
    try {
      document = await PdfDocument.openData(
        file.bytes,
        // Never prompt: an encrypted file is a typed refusal, so the one
        // empty-password attempt PDFium makes for free is the whole story.
        // (Plenty of "protected" PDFs are owner-password only and open on
        // that attempt; those read normally, which is right.)
        passwordProvider: null,
        firstAttemptByEmptyPassword: true,
        sourceName: file.fileName,
      );
      // `await`, and not merely `return`. In an async function a bare
      // `return future;` hands the future on and runs the `finally` *now* —
      // which would dispose the document and stop the worker while the pages
      // were still being read, and the read would come back holding page one
      // and eight empty pages. It looks right and it is silent.
      return await _readPages(document);
    } on PdfPasswordException {
      return const ExtractionFailure(
        ExtractionFailureKind.passwordProtected,
        passwordProtectedSentence,
      );
    } catch (_) {
      // The contract says an extractor never throws: a damaged file, a
      // truncated one, or a PDFium that could not be loaded at all all land
      // here as the same honest sentence.
      return const ExtractionFailure(
        ExtractionFailureKind.unreadable,
        unreadableFileSentence,
      );
    } finally {
      try {
        await document?.dispose();
      } catch (_) {
        // Disposal failing must not turn a good read into a refusal.
      }
      await _stopWorker();
    }
  }

  Future<ExtractionResult> _readPages(PdfDocument document) async {
    final total = document.pages.length;
    if (total == 0) {
      return const ExtractionFailure(
        ExtractionFailureKind.empty,
        emptyFileSentence,
      );
    }
    final read = total > maxPdfPages ? maxPdfPages : total;

    final pages = <List<String>>[];
    for (var i = 0; i < read; i++) {
      final text = await document.pages[i].loadText();
      final full = text?.fullText ?? '';
      pages.add(
        full.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n'),
      );
    }

    final cleaned = cleanPaginatedText(pages);
    if (cleaned.trim().isEmpty) {
      // Pages that opened fine and carry no characters are pictures of a
      // plan, not a plan. The OCR slice hangs its offer off this kind.
      return const ExtractionFailure(
        ExtractionFailureKind.noTextLayer,
        noTextLayerSentence,
      );
    }
    return ExtractedText(text: cleaned, notes: [_pagesNote(read, total)]);
  }

  String _pagesNote(int read, int total) {
    if (read < total) return 'Read the first $read of $total pages';
    return read == 1 ? 'Read 1 page' : 'Read $read pages';
  }

  /// See the file comment: `Isolate.run` exits the instant the result is
  /// ready, so a worker left running is a worker stranded for the life of the
  /// app. Stopping it also calls `FPDF_DestroyLibrary`; the engine
  /// re-initialises on the next open, which is what makes two reads in one
  /// process work.
  Future<void> _stopWorker() async {
    try {
      await PdfrxEntryFunctions.instance.stopBackgroundWorker();
    } catch (_) {
      // Not every backend has a worker to stop.
    }
  }
}

/// Where the `%PDF-` header sits, or null when there isn't one. The spec
/// tolerates junk before the header (and mail gateways add it), so the search
/// runs over the first kilobyte rather than only offset zero.
int? _headerOffset(Uint8List bytes) {
  const header = [0x25, 0x50, 0x44, 0x46, 0x2D]; // %PDF-
  final limit = bytes.length < 1024 ? bytes.length : 1024;
  outer:
  for (var start = 0; start + header.length <= limit; start++) {
    for (var i = 0; i < header.length; i++) {
      if (bytes[start + i] != header[i]) continue outer;
    }
    return start;
  }
  return null;
}
