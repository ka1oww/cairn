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
- OCR (slice D) is deliberately *not* an extractor: recognition is a platform
  call (Apple Vision), so it lives behind a `TextRecognitionEdge` beside app
  state, shaped like `camera_source.dart`.

Pure Dart: no Flutter, no network, no I/O. Test with `dart test` from inside
this directory. Fixtures under `test/fixtures/` are committed binaries;
`tool/make_fixtures.dart` documents how each was generated.
