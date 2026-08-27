# plan_extraction

The Cairn file-import extraction band: **bytes in, honest lines of plan text
out**. Import is not a second parser — every format reduces to one `String`
of lines that `PasteFlow.parse()` already understands
(`lib/app_state/paste_flow.dart`); this package holds the one contract every
import slice codes against and one extractor per format.

- The contract (`lib/plan_extraction.dart`): `PickedBytes`, the sealed
  `ExtractionResult` (`ExtractedText` / `ExtractionFailure`), and the
  `PlanTextExtractor` interface — pure, never throws, and returning a
  `FutureOr<ExtractionResult>` so that a synchronous format still answers
  directly while PDF, which cannot, still fits the one contract (see below).
- The registry is a `const` list in `lib/app_state/import_flow.dart`, not
  here; each slice adds exactly one line to it.
- The extractors, one per format: `PlainTextExtractor` (slice A) and
  `DocxExtractor` / `XlsxExtractor` / `CsvExtractor` (slice C).
- `DocxExtractor` says a table **one line per row**, its filled cells joined
  in column order, so `[08:30 | Fushimi Inari]` reaches the box as the one
  stop a reader sees and the parser reads its leading time. A row down to a
  single filled cell keeps its paragraphs as separate lines: a one-column
  table is layout, not pairing. This is the row model's rule reached the
  other way round — WordprocessingML types no cell, so `plan_rows.dart`
  has nothing to pair, and giving it a time grammar over text cells would
  change xlsx and csv too.
- `src/plan_rows.dart` is what xlsx and csv share: a row model
  (`DateCell`/`TimeCell`/`TextCell` → `DayRow`/`StopRow`/`PreambleRow`) and
  the one renderer that says those rows back in the plan-text dialect. Only a
  *typed* date cell (or, in csv, an exact ISO-shaped string) dates a day for
  certain; no second date grammar lives here. Where no date column exists the
  extractor falls back to faithful row-major lines — never worse than pasting
  the same table as text. The renderer cannot import the app's
  `lib/logic/plan_text.dart`, so it carries its own tiny copy of the dialect;
  `test/plan_rows_round_trip_test.dart` is what keeps the two honest, feeding
  every shape the renderer emits back through the real `parseItinerary`.
  That is why `itinerary_parser` is a **dev-only** path dependency here, and
  it must never become a runtime one.
- OCR (slice D) is deliberately *not* an extractor: recognition is a platform
  call (Apple Vision), so it lives behind a `TextRecognitionEdge` beside app
  state, shaped like `camera_source.dart`.

Pure Dart: no Flutter, no network, and nothing here opens a file — the app's
picker edge reads the bytes and hands them over. The runtime dependencies are
the container readers alone — `archive` + `xml` (docx), `excel` (xlsx), `csv`,
and `pdfrx_engine` (pdf). Test with `dart test` from inside this directory.
Fixtures under `test/fixtures/` are committed binaries;
`tool/make_fixtures.dart` and `tool/make_pdf_fixtures.dart` document how each
was generated.

## PDF, and the two places PDFium comes from

`PdfExtractor` reads a PDF's text layer through `pdfrx_engine`, which is pure
Dart over PDFium. PDFium itself is a native library, and it arrives by two
different routes that are easy to confuse:

- **`dart test` / `dart run` on a dev machine or CI.** `pdfium_dart`'s build
  hook downloads a PDFium build for the host platform **once** and caches it
  under `~/.pub-cache`. So the first `dart test` after a fresh checkout needs
  the network and takes a few seconds longer; every run after that does not.
  Nothing about this reaches app runtime. If CI is ever air-gapped, pre-seed
  that cache or set `PDFIUM_PATH` to a PDFium the image already carries.
- **The iOS app.** The very same build hook returns without emitting anything
  when the target is iOS, and on Flutter/iOS the engine resolves PDFium with
  `DynamicLibrary.process()` instead — it expects the symbols to be *already
  linked into the app*. That is why the repository's root `pubspec.yaml`
  depends on `pdfium_flutter`, which links the PDFium XCFramework via
  CocoaPods. Nothing in `lib/` imports it and no test would fail without it;
  what fails without it is reading a PDF on a phone. Check for
  `Runner.app/Frameworks/PDFium.framework` after a build if that is ever in
  doubt.

`extract` is therefore asynchronous for PDF, and the contract's return type is
a `FutureOr` — PDFium is not re-entrant, so `pdfrx_engine` serializes every
call through a background worker isolate and offers no synchronous entry point
at all. The synchronous extractors are unaffected: `PlainTextExtractor.extract`
still returns its result directly.
