# plan_extraction

The Cairn file-import extraction band: **bytes in, honest lines of plan text
out**. Import is not a second parser — every format reduces to one `String`
of lines that `PasteFlow.parse()` already understands
(`lib/app_state/paste_flow.dart`); this package holds the one contract every
import slice codes against and one extractor per format.

- The contract (`lib/plan_extraction.dart`): `PickedBytes`, the sealed
  `ExtractionResult` (`ExtractedText` / `ExtractionFailure`), and the
  `PlanTextExtractor` interface — synchronous, pure, never throws.
- The registry is a `const` list in `lib/app_state/import_flow.dart`, not
  here; each slice adds exactly one line to it.
- The extractors, one per format: `PlainTextExtractor` (slice A) and
  `DocxExtractor` / `XlsxExtractor` / `CsvExtractor` (slice C).
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

Pure Dart: no Flutter, no network, no I/O. The runtime dependencies are the
container readers alone — `archive` + `xml` (docx), `excel` (xlsx), `csv`.
Test with `dart test` from inside this directory. Fixtures under
`test/fixtures/` are committed binaries; `tool/make_fixtures.dart` documents
how each was generated.
