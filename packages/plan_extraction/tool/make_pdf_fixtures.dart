// Slice B's fixtures, generated once and committed as binaries; this script
// is the record of how each was made (the import plan's test strategy §7).
// Run from inside packages/plan_extraction:
//
//   dart run tool/make_pdf_fixtures.dart
//
// Unlike `make_fixtures.dart`, this one is *not* self-contained: three of the
// four fixtures are made by real tools, deliberately, because a PDF this
// package hand-wrote would only ever prove that this package can read its own
// handwriting. It needs:
//
//   - Google Chrome, for print-to-PDF. A Wanderlog "export" *is* a browser
//     print — there is no PDF generator in the product, only `window.print()`
//     — so Chrome's print pipeline is not a stand-in for the real thing here,
//     it is the real thing.
//   - Ghostscript (`gs`), for the encrypted fixture. Nothing else on a stock
//     macOS box writes an encrypted PDF.
//   - Network, for the Wanderlog page itself.
//
// Re-running is therefore not byte-deterministic (Chrome stamps a creation
// date, and the live page changes). Regenerate only when a fixture needs to
// change, and read the diff of what the extractor produces rather than of the
// bytes.
import 'dart:convert';
import 'dart:io';

import 'make_fixtures.dart' show garbledPlan;

/// The public Wanderlog itinerary the flagship fixture is a print of, named
/// by the plan itself. Printing a *public* page is the only way to exercise
/// Wanderlog's real print stylesheets without somebody's private trip; the
/// plan verified the same stylesheets serve both.
const wanderlogUrl =
    'https://wanderlog.com/list/itinerary/1003/3-day-asahikawa-itinerary';

/// Chrome is asked to print without images. The saving is real (a 22-page,
/// 1.4 MB print becomes a 9-page one under a megabyte) and it costs the
/// fixture nothing that matters: an image carries no text layer, so every
/// line this package will ever read survives. Everything else about the file
/// — the print stylesheet, the fonts, the running header and footer, the
/// `10 min · 3.7 mi` dividers, the `View on map` buttons — is exactly what a
/// family's export carries.
const wanderlogImagesOff = true;

Future<void> main() async {
  final fixtures = Directory('test/fixtures');
  if (!fixtures.existsSync()) fixtures.createSync(recursive: true);
  final work = Directory.systemTemp.createTempSync('plan_extraction_fixtures');

  final chrome = _findChrome();

  // ---------------------------------------------------------------------
  // The shared garbled itinerary as a PDF of the very same text the .txt
  // carries. It is authored once, in `make_fixtures.dart`'s `garbledPlan`,
  // and every slice renders that one const into its own container, so the
  // extraction-equivalence tests have something to compare: the parser must
  // see one truth no matter which container the plan arrived in. This script
  // never writes the .txt itself -- `make_fixtures.dart` owns it.
  // ---------------------------------------------------------------------
  final garbledHtml = File('${work.path}/garbled.html')
    ..writeAsStringSync(_asPrintableHtml(garbledPlan));
  // No running header or footer: this is the "Save as PDF" a person gets from
  // an app rather than from a browser's print dialog, and the equivalence
  // test wants the two containers to differ in nothing but their container.
  // (A one-page print's header could not be stripped honestly anyway — the
  // furniture rule needs three pages before it will call anything repeated.)
  await _printToPdf(
    chrome,
    'file://${garbledHtml.path}',
    'test/fixtures/garbled-itinerary.pdf',
    headerFooter: false,
  );

  // ---------------------------------------------------------------------
  // The flagship: a genuine Wanderlog print.
  // ---------------------------------------------------------------------
  await _printToPdf(
    chrome,
    wanderlogUrl,
    'test/fixtures/wanderlog-print.pdf',
    // Left ON, because Chrome's print dialog leaves it on: a real family's
    // export carries the `<date>, <time> <page title>` header and the
    // `<url> N/M` footer on every page. Stripping those is precisely what
    // the repeated-furniture rule is for, and this fixture is its evidence.
    headerFooter: true,
    images: !wanderlogImagesOff,
    // The page loads its itinerary after first paint; without a virtual-time
    // budget Chrome prints the skeleton.
    virtualTimeBudget: const Duration(seconds: 15),
  );

  // ---------------------------------------------------------------------
  // Encrypted: the same garbled plan, behind a user password. Slice B never
  // asks for a password (the plan's risk 6), so what the fixture proves is
  // that the refusal is *typed* — passwordProtected, not unreadable.
  // ---------------------------------------------------------------------
  _encrypt(
    'test/fixtures/garbled-itinerary.pdf',
    'test/fixtures/password-protected.pdf',
  );

  // ---------------------------------------------------------------------
  // Image-only: one page, one bitmap, no text layer anywhere. This is the
  // one fixture written by hand, because "a PDF with an image and provably
  // not one character of text" is easier to guarantee by construction than
  // to coax out of a printer. It stands in for the scan or the photographed
  // printout, and it is the seam the OCR slice hangs its offer from.
  // ---------------------------------------------------------------------
  File('test/fixtures/image-only.pdf').writeAsBytesSync(_imageOnlyPdf());

  // ---------------------------------------------------------------------
  // Damaged: a real PDF with its body truncated. Opens as neither a plan nor
  // an honest refusal unless the extractor is careful.
  // ---------------------------------------------------------------------
  final whole = File('test/fixtures/garbled-itinerary.pdf').readAsBytesSync();
  File(
    'test/fixtures/truncated.pdf',
  ).writeAsBytesSync(whole.sublist(0, whole.length ~/ 3));

  work.deleteSync(recursive: true);
  stdout.writeln('PDF fixtures written under test/fixtures/');
}

String _asPrintableHtml(String plan) =>
    '<!doctype html><meta charset="utf-8">'
    '<style>body{margin:24px;font-family:Helvetica,Arial,sans-serif;'
    'font-size:12pt}pre{white-space:pre-wrap;font-family:inherit}</style>'
    '<pre>${_escape(plan)}</pre>';

String _escape(String text) => const HtmlEscape().convert(text);

String _findChrome() {
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }
  throw StateError('Chrome not found; see the header comment.');
}

Future<void> _printToPdf(
  String chrome,
  String url,
  String output, {
  required bool headerFooter,
  bool images = true,
  Duration? virtualTimeBudget,
}) async {
  final result = await Process.run(chrome, [
    '--headless',
    '--disable-gpu',
    if (!headerFooter) '--no-pdf-header-footer',
    if (!images) '--blink-settings=imagesEnabled=false',
    if (virtualTimeBudget != null)
      '--virtual-time-budget=${virtualTimeBudget.inMilliseconds}',
    '--print-to-pdf=$output',
    url,
  ]);
  if (!File(output).existsSync()) {
    throw StateError('Chrome wrote no PDF for $url: ${result.stderr}');
  }
  stdout.writeln('  $output  (${File(output).lengthSync()} bytes)');
}

/// The password the encrypted fixture is locked with. Written down because
/// nothing in the product ever uses it — the test's whole assertion is that
/// the read refuses, by name.
const encryptedFixturePassword = 'cairn-secret';

void _encrypt(String input, String output) {
  final result = Process.runSync('gs', [
    '-q',
    '-dNOPAUSE',
    '-dBATCH',
    '-sDEVICE=pdfwrite',
    '-sOwnerPassword=cairn-owner',
    '-sUserPassword=$encryptedFixturePassword',
    '-dEncryptionR=3',
    '-dKeyLength=128',
    '-dPermissions=-4',
    '-sOutputFile=$output',
    input,
  ]);
  if (!File(output).existsSync()) {
    throw StateError('Ghostscript wrote no PDF: ${result.stderr}');
  }
  stdout.writeln('  $output  (${File(output).lengthSync()} bytes)');
}

/// A minimal, hand-assembled PDF: one page whose only content is a 4×4
/// greyscale bitmap scaled to fill it. Five objects and an xref table, with
/// every offset counted as the bytes are appended — which is the whole reason
/// this is built by hand rather than templated.
List<int> _imageOnlyPdf() {
  const pixels = <int>[
    0x00, 0x40, 0x80, 0xC0, //
    0x40, 0x80, 0xC0, 0xFF,
    0x80, 0xC0, 0xFF, 0xC0,
    0xC0, 0xFF, 0xC0, 0x80,
  ];
  const content = 'q 400 0 0 400 96 200 cm /Im0 Do Q\n';

  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>',
    '<< /Length ${content.length} >>\nstream\n$content\nendstream',
    '<< /Type /XObject /Subtype /Image /Width 4 /Height 4 '
        '/ColorSpace /DeviceGray /BitsPerComponent 8 '
        '/Length ${pixels.length} >>\nstream\n',
  ];

  final out = <int>[];
  void write(String s) => out.addAll(latin1.encode(s));

  write('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    write('${i + 1} 0 obj\n${objects[i]}');
    if (i == objects.length - 1) {
      // The image stream's bytes are not text and cannot go through `write`.
      out.addAll(pixels);
      write('\nendstream');
    }
    write('\nendobj\n');
  }

  final xref = out.length;
  write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return out;
}
